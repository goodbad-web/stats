//
//  readers.swift
//  CPU
//
//  Created by Serhiy Mytrovtsiy on 10/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
@preconcurrency import Kit
import os
import IOKit.pwr_mgt
import Darwin

private typealias IOPMFindPowerManagementFn = @convention(c) (mach_port_t, UnsafeMutablePointer<io_connect_t>) -> kern_return_t
private typealias IOPMCopyCPUProcessorLimitsFn = @convention(c) (io_connect_t, UnsafeMutablePointer<Unmanaged<CFDictionary>?>) -> kern_return_t

private enum PowerManagementSymbols {
    private static func resolve<T>(_ name: String, as _: T.Type) -> T? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            return nil
        }
        return unsafeBitCast(sym, to: T.self)
    }

    static let findPM: IOPMFindPowerManagementFn? = {
        resolve("IOPMFindPowerManagement", as: IOPMFindPowerManagementFn.self)
    }()
    static let copyLimits: IOPMCopyCPUProcessorLimitsFn? = {
        resolve("IOPMCopyCPUProcessorLimits", as: IOPMCopyCPUProcessorLimitsFn.self)
    }()
}

private struct Sample: @unchecked Sendable {
    let samples: CFDictionary
    let time: TimeInterval
}

private actor CPUReaderWorker {
    private var prevCpuInfo: processor_info_array_t?
    private var numPrevCpuInfo: mach_msg_type_number_t = 0
    private var previousInfo = host_cpu_load_info()
    private var usagePerCore: [Double] = []
    
    private var channels: CFMutableDictionary?
    private var subscription: IOReportSubscriptionRef?
    private var prevSample: Sample?
    
    private let numCPUs: uint
    private let hasHT: Bool
    private let cores: [core_s]
    
    private let eCoreFreqs: [Int32]
    private let pCoreFreqs: [Int32]
    private let sCoreFreqs: [Int32]
    private let eCoreCount: Double
    private let pCoreCount: Double
    private let sCoreCount: Double
    
    init() {
        self.hasHT = sysctlByName("hw.physicalcpu") != sysctlByName("hw.logicalcpu")
        var ncpus: uint = 1
        [CTL_HW, HW_NCPU].withUnsafeBufferPointer { mib in
            var sizeOfNumCPUs: size_t = MemoryLayout<uint>.size
            let status = sysctl(processor_info_array_t(mutating: mib.baseAddress), 2, &ncpus, &sizeOfNumCPUs, nil, 0)
            if status != 0 { ncpus = 1 }
        }
        self.numCPUs = ncpus
        self.cores = SystemKit.shared.device.info.cpu?.cores ?? []
        
        self.eCoreFreqs = SystemKit.shared.device.info.cpu?.eCoreFrequencies ?? []
        self.pCoreFreqs = SystemKit.shared.device.info.cpu?.pCoreFrequencies ?? []
        self.sCoreFreqs = SystemKit.shared.device.info.cpu?.sCoreFrequencies ?? []
        self.eCoreCount = Double(SystemKit.shared.device.info.cpu?.eCores ?? 0)
        self.pCoreCount = Double(SystemKit.shared.device.info.cpu?.pCores ?? 0)
        self.sCoreCount = Double(SystemKit.shared.device.info.cpu?.sCores ?? 0)
    }
    
    deinit {
        if let prevCpuInfo = self.prevCpuInfo {
            prevCpuInfo.deallocate()
        }
    }
    
    func readLoad(scope: CPULoadReadScope) async -> CPU_Load? {
        var numCPUsU: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        let result: kern_return_t = scope.needsPerCore || scope.needsClusterUsage ?
            host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUsU, &cpuInfo, &numCpuInfo) :
            KERN_FAILURE
        
        let cpuInfoData = self.hostCPULoadInfo()
        let showHyperthratedCores = Store.shared.bool(key: "CPU_hyperhreading", defaultValue: false)
        
        var response = CPU_Load()
        
        if result == KERN_SUCCESS, let cpuInfo = cpuInfo {
            defer {
                let size: size_t = MemoryLayout<integer_t>.stride * Int(numCpuInfo)
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(size))
            }
            
            self.usagePerCore = []
            for i in 0 ..< Int32(self.numCPUs) {
                var inUse: Int32
                var total: Int32
                if let prevCpuInfo = self.prevCpuInfo {
                    inUse = cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_USER)]
                        - prevCpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_USER)]
                        + cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_SYSTEM)]
                        - prevCpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_SYSTEM)]
                        + cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_NICE)]
                        - prevCpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_NICE)]
                    total = inUse + (cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_IDLE)]
                        - prevCpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_IDLE)])
                } else {
                    inUse = cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_USER)]
                        + cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_SYSTEM)]
                        + cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_NICE)]
                    total = inUse + cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_IDLE)]
                }
                
                if total != 0 {
                    let usage = Double(inUse) / Double(total)
                    if usage.isFinite {
                        self.usagePerCore.append(usage)
                    }
                }
            }
            
            if showHyperthratedCores || !self.hasHT {
                response.usagePerCore = self.usagePerCore
            } else {
                var i = 0
                response.usagePerCore = []
                while i < Int(self.usagePerCore.count/2) {
                    let a = i * 2
                    if self.usagePerCore.indices.contains(a) && self.usagePerCore.indices.contains(a+1) {
                        let averaged = (self.usagePerCore[a] + self.usagePerCore[a+1]) / 2
                        if averaged.isFinite {
                            response.usagePerCore.append(averaged)
                        }
                    }
                    i += 1
                }
            }
            
            if let prevCpuInfo = self.prevCpuInfo {
                prevCpuInfo.deallocate()
            }
            
            _ = MemoryLayout<integer_t>.stride * Int(numCpuInfo)
            let newPrev = UnsafeMutablePointer<integer_t>.allocate(capacity: Int(numCpuInfo))
            newPrev.initialize(from: cpuInfo, count: Int(numCpuInfo))
            self.prevCpuInfo = newPrev
            self.numPrevCpuInfo = numCpuInfo
        }
        
        if let cpuInfoData = cpuInfoData {
            let userDiff = Double(cpuInfoData.cpu_ticks.0 &- self.previousInfo.cpu_ticks.0)
            let sysDiff  = Double(cpuInfoData.cpu_ticks.1 &- self.previousInfo.cpu_ticks.1)
            let idleDiff = Double(cpuInfoData.cpu_ticks.2 &- self.previousInfo.cpu_ticks.2)
            let niceDiff = Double(cpuInfoData.cpu_ticks.3 &- self.previousInfo.cpu_ticks.3)
            let totalTicks = sysDiff + userDiff + niceDiff + idleDiff
            
            if totalTicks.isFinite && totalTicks > 0 {
                let system = sysDiff / totalTicks
                let user = userDiff / totalTicks
                let idle = idleDiff / totalTicks
                
                if system.isFinite { response.systemLoad = system }
                if user.isFinite { response.userLoad = user }
                if idle.isFinite { response.idleLoad = idle }
            }
            
            self.previousInfo = cpuInfoData
            let totalUsage = response.systemLoad + response.userLoad
            if totalUsage.isFinite {
                response.totalUsage = totalUsage
            }
            
            if scope.needsClusterUsage {
                let eCoresList: [Double] = self.cores.filter({ $0.type == .efficiency }).enumerated().compactMap { (i, c) -> Double? in
                    if response.usagePerCore.indices.contains(Int(c.id)) {
                        return response.usagePerCore[Int(c.id)]
                    }
                    return i < self.usagePerCore.count ? self.usagePerCore[i] : 0
                }
                let pCoresList: [Double] = self.cores.filter({ $0.type == .performance }).enumerated().compactMap { (i, c) -> Double? in
                    if response.usagePerCore.indices.contains(Int(c.id)) {
                        return response.usagePerCore[Int(c.id)]
                    }
                    return i < self.usagePerCore.count ? self.usagePerCore[i] : 0
                }
                let sCoresList: [Double] = self.cores.filter({ $0.type == .super }).enumerated().compactMap { (i, c) -> Double? in
                    if response.usagePerCore.indices.contains(Int(c.id)) {
                        return response.usagePerCore[Int(c.id)]
                    }
                    return i < self.usagePerCore.count ? self.usagePerCore[i] : 0
                }
                
                if !eCoresList.isEmpty {
                    let usage = eCoresList.reduce(0, +)/Double(eCoresList.count)
                    if usage.isFinite { response.usageECores = usage }
                }
                if !pCoresList.isEmpty {
                    let usage = pCoresList.reduce(0, +)/Double(pCoresList.count)
                    if usage.isFinite { response.usagePCores = usage }
                }
                if !sCoresList.isEmpty {
                    let usage = sCoresList.reduce(0, +)/Double(sCoresList.count)
                    if usage.isFinite { response.usageSCores = usage }
                }
            }
        }
        
        return response
    }
    
    func readFrequency() async -> CPU_Frequency? {
        if self.channels == nil || self.subscription == nil {
            self.channels = Self.getChannels()
            if let channels = self.channels {
                var dict: Unmanaged<CFMutableDictionary>?
                self.subscription = IOReportCreateSubscription(nil, channels, &dict, 0, nil)
                dict?.release()
            }
        }
        
        guard (!self.eCoreFreqs.isEmpty || !self.sCoreFreqs.isEmpty) && !self.pCoreFreqs.isEmpty,
              let subscription = self.subscription, let channels = self.channels else { return nil }
        
        guard let nextSampleData = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        let next = Sample(samples: nextSampleData, time: Date().timeIntervalSince1970)
        
        let prev = self.prevSample
        self.prevSample = next
        
        guard let prev = prev, let diffCF = IOReportCreateSamplesDelta(prev.samples, next.samples, nil) else { return nil }
        let diff = diffCF.takeRetainedValue()
        
        guard let items = (diff as? [String: Any])?["IOReportChannels"] as? NSArray else { return nil }
        
        var eCore: [Double] = []
        var pCore: [Double] = []
        var sCore: [Double] = []
        
        for i in 0..<items.count {
            guard let item = items[i] as? NSDictionary else { continue }
            let channelInfo = item as CFDictionary
            guard let group = IOReportChannelGetGroup(channelInfo)?.takeUnretainedValue() as? String,
                  group == "CPU Stats",
                  let channel = IOReportChannelGetChannelName(channelInfo)?.takeUnretainedValue() as? String else { continue }
            
            if channel.contains("ECPU") {
                eCore.append(self.calculateFrequencies(dict: channelInfo, freqs: self.eCoreFreqs))
            }
            if channel.contains(self.sCoreCount == 0 ? "PCPU" : "MCPU") {
                pCore.append(self.calculateFrequencies(dict: channelInfo, freqs: self.pCoreFreqs))
            }
            if self.sCoreCount != 0 && channel.contains("PCPU") {
                sCore.append(self.calculateFrequencies(dict: channelInfo, freqs: self.sCoreFreqs))
            }
        }
        
        let minECoreFreq = Double(self.eCoreFreqs.min() ?? 0)
        let minPCoreFreq = Double(self.pCoreFreqs.min() ?? 0)
        let minSCoreFreq = Double(self.sCoreFreqs.min() ?? 0)
        
        let eFreq: Double? = eCore.isEmpty ? nil : max(eCore.reduce(0.0, +) / Double(eCore.count), minECoreFreq)
        let pFreq: Double? = pCore.isEmpty ? nil : max(pCore.reduce(0.0, +) / Double(pCore.count), minPCoreFreq)
        let sFreq: Double? = sCore.isEmpty ? nil : max(sCore.reduce(0.0, +) / Double(sCore.count), minSCoreFreq)
        
        var activeCores: Double = 0
        var totalFreq: Double = 0
        if let freq = eFreq { activeCores += self.eCoreCount; totalFreq += freq * self.eCoreCount }
        if let freq = pFreq { activeCores += self.pCoreCount; totalFreq += freq * self.pCoreCount }
        if let freq = sFreq { activeCores += self.sCoreCount; totalFreq += freq * self.sCoreCount }
        let value: Double? = activeCores > 0 ? totalFreq / activeCores : nil
        
        return CPU_Frequency(value: value, eCore: eFreq, pCore: pFreq, sCore: sFreq)
    }
    
    func readTemperature(list: [String]) async -> Double? {
        let smcValues = await SMC.shared.getValues(list)
        let values = smcValues.values.filter { $0 != 0 }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    
    func readLimits() async -> CPU_Limit {
        var res = CPU_Limit()
        if #available(macOS 12.0, *) {
            var service: io_connect_t = 0
            if let findPM = PowerManagementSymbols.findPM, let copyLimits = PowerManagementSymbols.copyLimits, findPM(kIOMainPortDefault, &service) == KERN_SUCCESS {
                var dict: Unmanaged<CFDictionary>?
                if copyLimits(service, &dict) == KERN_SUCCESS, let limits = dict?.takeRetainedValue() as? [String: Any] {
                    if let scheduler = limits["CPU_Scheduler_Limit"] as? Int { res.scheduler = scheduler }
                    if let cpus = limits["CPU_Available_CPUs"] as? Int { res.cpus = cpus }
                    if let speed = limits["CPU_Speed_Limit"] as? Int { res.speed = speed }
                }
                IOServiceClose(service)
            }
        }
        return res
    }
    
    func readAverageLoad() async -> CPU_AverageLoad? {
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        return CPU_AverageLoad(load1: load[0], load5: load[1], load15: load[2])
    }
    
    func getTopProcesses(limit: Int) async -> [TopProcess] {
        return await ProcessMonitor.shared.getTopProcesses(limit: limit, category: "CPU")
    }
    
    private func hostCPULoadInfo() -> host_cpu_load_info? {
        let count = MemoryLayout<host_cpu_load_info>.stride/MemoryLayout<integer_t>.stride
        var size = mach_msg_type_number_t(count)
        var cpuLoadInfo = host_cpu_load_info()
        let result: kern_return_t = withUnsafeMutablePointer(to: &cpuLoadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: count) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        return result == KERN_SUCCESS ? cpuLoadInfo : nil
    }
    
    private func calculateFrequencies(dict: CFDictionary, freqs: [Int32]) -> Double {
        let count = IOReportStateGetCount(dict)
        var items: [(String, Int64)] = []
        for i in 0..<count {
            let name = IOReportStateGetNameForIndex(dict, i)?.takeUnretainedValue() as String? ?? ""
            let val = IOReportStateGetResidency(dict, i)
            items.append((name, val))
        }
        
        guard let offset = items.firstIndex(where: { $0.0 != "IDLE" && $0.0 != "DOWN" && $0.0 != "OFF" }) else { return 0 }
        let usage = items.dropFirst(offset).reduce(0.0) { $0 + Double($1.1) }
        let freqCount = freqs.count
        var avgFreq: Double = 0
        for i in 0..<freqCount {
            let key = i + offset
            if !items.indices.contains(key) { continue }
            let percent = usage == 0 ? 0 : Double(items[key].1) / usage
            avgFreq += percent * Double(freqs[i])
        }
        return avgFreq
    }
    
    static private func getChannels() -> CFMutableDictionary? {
        let channelNames = [
            ("CPU Stats", "CPU Complex Performance States"),
            ("CPU Stats", "CPU Core Performance States")
        ]
        var channels: [CFDictionary] = []
        for (gname, sname) in channelNames {
            if let channel = IOReportCopyChannelsInGroup(gname as CFString?, sname as CFString?, 0, 0, 0)?.takeRetainedValue() {
                channels.append(channel)
            }
        }
        guard !channels.isEmpty else { return nil }
        let chan = channels[0]
        for i in 1..<channels.count {
            IOReportMergeChannels(chan, channels[i], nil)
        }
        let size = CFDictionaryGetCount(chan)
        guard let mutableCopy = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, size, chan),
              let dict = mutableCopy as? [String: Any], dict["IOReportChannels"] != nil else { return nil }
        return mutableCopy
    }
}

internal struct CPULoadReadScope: Equatable, Sendable {
    var needsPerCore: Bool
    var needsClusterUsage: Bool

    static let totalOnly = CPULoadReadScope(needsPerCore: false, needsClusterUsage: false)
    static let full = CPULoadReadScope(needsPerCore: true, needsClusterUsage: true)
}

internal class LoadReader: Reader<CPU_Load>, @unchecked Sendable {
    private let worker = CPUReaderWorker()
    private let scopeLock = OSAllocatedUnfairLock(initialState: CPULoadReadScope.totalOnly)
    
    public override func setup() {}

    internal func setReadScope(_ scope: CPULoadReadScope) {
        self.scopeLock.withLock { $0 = scope }
    }
    
    public override func readAsync() async -> CPU_Load? {
        let scope = self.scopeLock.withLock { $0 }
        return await self.worker.readLoad(scope: scope)
    }
}

public class ProcessReader: Reader<[TopProcess]>, @unchecked Sendable {
    private let title: String = "CPU"
    private let worker = CPUReaderWorker()
    private let readLock = OSAllocatedUnfairLock(initialState: false)
    
    private nonisolated var numberOfProcesses: Int {
        get { Store.shared.int(key: "\(self.title)_processes", defaultValue: 8) }
    }
    
    public override func setup() {
        self.popup = true
        self.defaultInterval = 5
        self.setInterval(Store.shared.int(key: "\(self.title)_updateTopInterval", defaultValue: 5))
    }
    
    nonisolated public override func read() {
        let isReading = self.readLock.withLock { $0 }
        guard !isReading else { return }
        self.readLock.withLock { $0 = true }

        let limit = self.numberOfProcesses
        let worker = self.worker

        Task {
            defer { self.readLock.withLock { $0 = false } }

            if limit == 0 { return }

            let processes = await worker.getTopProcesses(limit: limit)

            if let old = self.value, old == processes {
                return
            }

            self.callback(processes)
        }
    }
}

public class TemperatureReader: Reader<Double>, @unchecked Sendable {
    private static let list: [String] = {
        switch SystemKit.shared.device.platform {
        case .m1, .m1Pro, .m1Max, .m1Ultra:
            return ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
        case .m2, .m2Pro, .m2Max, .m2Ultra:
            return ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
        case .m3, .m3Pro, .m3Max, .m3Ultra:
            return ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
        case .m4, .m4Pro, .m4Max, .m4Ultra:
            return ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        case .m5, .m5Pro, .m5Max, .m5Ultra:
            return ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
        default: return []
        }
    }()
    
    private let worker = CPUReaderWorker()
    
    public override func setup() {
        self.popup = true
    }
    
    public override func readAsync() async -> Double? {
        return await self.worker.readTemperature(list: Self.list)
    }
}

public class FrequencyReader: Reader<CPU_Frequency>, @unchecked Sendable {
    private let worker = CPUReaderWorker()
    
    public override func setup() {
        self.popup = true
        self.preview = true
    }
    
    public override func terminate() {}
    
    public override func readAsync() async -> CPU_Frequency? {
        return await self.worker.readFrequency()
    }
}

public class LimitReader: Reader<CPU_Limit>, @unchecked Sendable {
    private let worker = CPUReaderWorker()
    
    public override func readAsync() async -> CPU_Limit? {
        return await self.worker.readLimits()
    }
}

public class AverageLoadReader: Reader<CPU_AverageLoad>, @unchecked Sendable {
    private let worker = CPUReaderWorker()
    
    public override func setup() {
        self.popup = false
        self.setInterval(15)
    }
    
    public override func readAsync() async -> CPU_AverageLoad? {
        return await self.worker.readAverageLoad()
    }
}
