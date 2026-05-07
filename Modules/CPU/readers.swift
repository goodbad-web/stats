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

private struct LoadState {
    var cpuInfo: processor_info_array_t?
    var prevCpuInfo: processor_info_array_t?
    var numCpuInfo: mach_msg_type_number_t = 0
    var numPrevCpuInfo: mach_msg_type_number_t = 0
    var previousInfo = host_cpu_load_info()
    var response = CPU_Load()
    var usagePerCore: [Double] = []
}

private struct CPUInfoWrapper: @unchecked Sendable {
    let info: processor_info_array_t?
}

internal class LoadReader: Reader<CPU_Load>, @unchecked Sendable {
    private let loadLock = OSAllocatedUnfairLock(initialState: LoadState())
    private var numCPUs: uint = 0
    private var hasHyperthreadingCores = false
    private var cores: [core_s]? = nil
    
    public override func setup() {
        self.hasHyperthreadingCores = sysctlByName("hw.physicalcpu") != sysctlByName("hw.logicalcpu")
        [CTL_HW, HW_NCPU].withUnsafeBufferPointer { mib in
            var sizeOfNumCPUs: size_t = MemoryLayout<uint>.size
            let status = sysctl(processor_info_array_t(mutating: mib.baseAddress), 2, &numCPUs, &sizeOfNumCPUs, nil, 0)
            if status != 0 {
                self.numCPUs = 1
            }
        }
        self.cores = SystemKit.shared.device.info.cpu?.cores
    }
    
    nonisolated public override func read() {
        Task { @MainActor in
            let localNumCPUs = self.numCPUs
            let hasHT = self.hasHyperthreadingCores
            let localCores = self.cores
            
            var numCPUsU: natural_t = 0
            var cpuInfo: processor_info_array_t?
            var numCpuInfo: mach_msg_type_number_t = 0
            let result: kern_return_t = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUsU, &cpuInfo, &numCpuInfo)
            
            let capturedCpuInfo = CPUInfoWrapper(info: cpuInfo)
            let capturedNumCpuInfo = numCpuInfo
            let cpuInfoData = self.hostCPULoadInfo()
            
            let showHyperthratedCores = Store.shared.bool(key: "CPU_hyperhreading", defaultValue: false)
            
            let updatedResponse = await Task.detached(priority: .userInitiated) {
                return self.loadLock.withLock { state in
                    if result == KERN_SUCCESS, let cpuInfo = capturedCpuInfo.info {
                        state.usagePerCore = []
                        
                        for i in 0 ..< Int32(localNumCPUs) {
                            var inUse: Int32
                            var total: Int32
                            if let prevCpuInfo = state.prevCpuInfo {
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
                                state.usagePerCore.append(Double(inUse) / Double(total))
                            }
                        }
                        
                        if showHyperthratedCores || !hasHT {
                            state.response.usagePerCore = state.usagePerCore
                        } else {
                            var i = 0
                            state.response.usagePerCore = []
                            while i < Int(state.usagePerCore.count/2) {
                                let a = i * 2
                                if state.usagePerCore.indices.contains(a) && state.usagePerCore.indices.contains(a+1) {
                                    state.response.usagePerCore.append((state.usagePerCore[a] + state.usagePerCore[a+1]) / 2)
                                }
                                i += 1
                            }
                        }
                        
                        if let prevCpuInfo = state.prevCpuInfo {
                            let prevCpuInfoSize: size_t = MemoryLayout<integer_t>.stride * Int(state.numPrevCpuInfo)
                            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prevCpuInfo), vm_size_t(prevCpuInfoSize))
                        }
                        
                        state.prevCpuInfo = capturedCpuInfo.info
                        state.numPrevCpuInfo = capturedNumCpuInfo
                    }
                    
                    if let cpuInfoData = cpuInfoData {
                        let userDiff = Double(cpuInfoData.cpu_ticks.0 &- state.previousInfo.cpu_ticks.0)
                        let sysDiff  = Double(cpuInfoData.cpu_ticks.1 &- state.previousInfo.cpu_ticks.1)
                        let idleDiff = Double(cpuInfoData.cpu_ticks.2 &- state.previousInfo.cpu_ticks.2)
                        let niceDiff = Double(cpuInfoData.cpu_ticks.3 &- state.previousInfo.cpu_ticks.3)
                        let totalTicks = sysDiff + userDiff + niceDiff + idleDiff
                        
                        let system = sysDiff / totalTicks
                        let user = userDiff / totalTicks
                        let idle = idleDiff / totalTicks
                        
                        if !system.isNaN { state.response.systemLoad = system }
                        if !user.isNaN { state.response.userLoad = user }
                        if !idle.isNaN { state.response.idleLoad = idle }
                        
                        state.previousInfo = cpuInfoData
                        state.response.totalUsage = state.response.systemLoad + state.response.userLoad
                        
                        if let cores = localCores {
                            let eCoresList: [Double] = cores.filter({ $0.type == .efficiency }).enumerated().compactMap { (i, c) -> Double? in
                                if state.response.usagePerCore.indices.contains(Int(c.id)) {
                                    return state.response.usagePerCore[Int(c.id)]
                                }
                                return i < state.usagePerCore.count ? state.usagePerCore[i] : 0
                            }
                            let pCoresList: [Double] = cores.filter({ $0.type == .performance }).enumerated().compactMap { (i, c) -> Double? in
                                if state.response.usagePerCore.indices.contains(Int(c.id)) {
                                    return state.response.usagePerCore[Int(c.id)]
                                }
                                return i < state.usagePerCore.count ? state.usagePerCore[i] : 0
                            }
                            let sCoresList: [Double] = cores.filter({ $0.type == .super }).enumerated().compactMap { (i, c) -> Double? in
                                if state.response.usagePerCore.indices.contains(Int(c.id)) {
                                    return state.response.usagePerCore[Int(c.id)]
                                }
                                return i < state.usagePerCore.count ? state.usagePerCore[i] : 0
                            }
                            
                            if !eCoresList.isEmpty {
                                state.response.usageECores = eCoresList.reduce(0, +)/Double(eCoresList.count)
                            }
                            if !pCoresList.isEmpty {
                                state.response.usagePCores = pCoresList.reduce(0, +)/Double(pCoresList.count)
                            }
                            if !sCoresList.isEmpty {
                                state.response.usageSCores = sCoresList.reduce(0, +)/Double(sCoresList.count)
                            }
                        }
                    }
                    return state.response
                }
            }.value
            
            self.callback(updatedResponse)
        }
    }
    
    nonisolated private func hostCPULoadInfo() -> host_cpu_load_info? {
        let count = MemoryLayout<host_cpu_load_info>.stride/MemoryLayout<integer_t>.stride
        var size = mach_msg_type_number_t(count)
        var cpuLoadInfo = host_cpu_load_info()
        
        let result: kern_return_t = withUnsafeMutablePointer(to: &cpuLoadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: count) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        if result != KERN_SUCCESS {
            return nil
        }
        
        return cpuLoadInfo
    }
    
    deinit {
        self.loadLock.withLock { state in
            if let prevCpuInfo = state.prevCpuInfo {
                let prevCpuInfoSize: size_t = MemoryLayout<integer_t>.stride * Int(state.numPrevCpuInfo)
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prevCpuInfo), vm_size_t(prevCpuInfoSize))
            }
        }
    }
}

public class ProcessReader: Reader<[TopProcess]>, @unchecked Sendable {
    private let title: String = "CPU"
    private let readLock = OSAllocatedUnfairLock(initialState: false)
    
    private var numberOfProcesses: Int {
        get { Store.shared.int(key: "\(self.title)_processes", defaultValue: 8) }
    }
    
    public override func setup() {
        self.popup = true
        self.setInterval(Store.shared.int(key: "\(self.title)_updateTopInterval", defaultValue: 1))
    }
    
    nonisolated public override func read() {
        let isReading = self.readLock.withLock { $0 }
        guard !isReading else { return }
        self.readLock.withLock { $0 = true }
        
        Task { @MainActor in
            if self.numberOfProcesses == 0 {
                return
            }
            
            let limit = self.numberOfProcesses
            let processes = await Task.detached(priority: .background) {
                let output = syncShell("/bin/ps -Aceo pid,pcpu,comm -r")
                guard !output.isEmpty else { return [TopProcess]() }
                
                var index = 0
                var list: [TopProcess] = []
                output.enumerateLines { (line, stop) in
                    if index != 0 {
                        let str = line.trimmingCharacters(in: .whitespaces)
                        let pidFind = str.findAndCrop(pattern: "^\\d+")
                        let usageFind = pidFind.remain.findAndCrop(pattern: "^[0-9,.]+ ")
                        let command = usageFind.remain.trimmingCharacters(in: .whitespaces)
                        let pid = Int(pidFind.cropped) ?? 0
                        let usage = Double(usageFind.cropped.replacingOccurrences(of: ",", with: ".")) ?? 0
                        
                        var name: String = command
                        if let app = NSRunningApplication(processIdentifier: pid_t(pid)), let n = app.localizedName {
                            name = n
                        }
                        if command.contains("com.apple.Virtua") && name.contains("Docker") {
                            name = "Docker"
                        }
                        
                        list.append(TopProcess(pid: pid, name: name, usage: usage))
                    }
                    
                    if index == limit { stop = true }
                    index += 1
                }
                return list
            }.value
            
            self.callback(processes)
            self.readLock.withLock { $0 = false }
        }
    }
}

public class TemperatureReader: Reader<Double>, @unchecked Sendable {
    nonisolated(unsafe) var list: [String] = []
    
    public override func setup() {
        self.popup = true
        switch SystemKit.shared.device.platform {
        case .m1, .m1Pro, .m1Max, .m1Ultra:
            self.list = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
        case .m2, .m2Pro, .m2Max, .m2Ultra:
            self.list = ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
        case .m3, .m3Pro, .m3Max, .m3Ultra:
            self.list = ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
        case .m4, .m4Pro, .m4Max, .m4Ultra:
            self.list = ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        case .m5, .m5Pro, .m5Max, .m5Ultra:
            self.list = ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
        default: break
        }
    }
    
    nonisolated public override func read() {
        Task { @MainActor in
            let temp = await Task.detached(priority: .background) {
                var temperature: Double? = nil
                
                if let value = SMC.shared.getValue("TC0D"), value < 110 {
                    temperature = value
                } else if let value = SMC.shared.getValue("TC0E"), value < 110 {
                    temperature = value
                } else if let value = SMC.shared.getValue("TC0F"), value < 110 {
                    temperature = value
                } else if let value = SMC.shared.getValue("TC0P"), value < 110 {
                    temperature = value
                } else if let value = SMC.shared.getValue("TC0H"), value < 110 {
                    temperature = value
                } else {
                    var total: Double = 0
                    var counter: Double = 0
                    self.list.forEach { (key: String) in
                        if let value = SMC.shared.getValue(key) {
                            total += value
                            counter += 1
                        }
                    }
                    if total != 0 && counter != 0 {
                        temperature = total / counter
                    }
                }
                return temperature
            }.value
            
            self.callback(temp)
        }
    }
}

private struct FrequencyState {
    var isReading: Bool = false
    var prev: Sample? = nil
}

private struct Sample: @unchecked Sendable {
    let samples: CFDictionary
    let time: TimeInterval
}

public class FrequencyReader: Reader<CPU_Frequency>, @unchecked Sendable {
    private nonisolated(unsafe) var eCoreFreqs: [Int32] = []
    private nonisolated(unsafe) var pCoreFreqs: [Int32] = []
    private nonisolated(unsafe) var sCoreFreqs: [Int32] = []
    private nonisolated(unsafe) var eCoreCount: Double = 0
    private nonisolated(unsafe) var pCoreCount: Double = 0
    private nonisolated(unsafe) var sCoreCount: Double = 0
    
    private nonisolated(unsafe) var channels: CFMutableDictionary? = nil
    private nonisolated(unsafe) var subscription: IOReportSubscriptionRef? = nil
    
    private let measurementCount: Int = 4
    private let freqLock = OSAllocatedUnfairLock(initialState: FrequencyState())
    
    private struct IOSample {
        let group: String
        let subGroup: String
        let channel: String
        let unit: String
        let delta: CFDictionary
    }
    
    public override func setup() {
        self.popup = true
        self.preview = true
        self.eCoreFreqs = SystemKit.shared.device.info.cpu?.eCoreFrequencies ?? []
        self.pCoreFreqs = SystemKit.shared.device.info.cpu?.pCoreFrequencies ?? []
        self.sCoreFreqs = SystemKit.shared.device.info.cpu?.sCoreFrequencies ?? []
        self.eCoreCount = Double(SystemKit.shared.device.info.cpu?.eCores ?? 0)
        self.pCoreCount = Double(SystemKit.shared.device.info.cpu?.pCores ?? 0)
        self.sCoreCount = Double(SystemKit.shared.device.info.cpu?.sCores ?? 0)
        self.channels = self.getChannels()
        var dict: Unmanaged<CFMutableDictionary>?
        self.subscription = IOReportCreateSubscription(nil, self.channels, &dict, 0, nil)
        dict?.release()
    }
    
    @MainActor public override func terminate() {
        self.channels = nil
        self.subscription = nil
    }
    
    nonisolated public override func read() {
        Task { @MainActor in
            let isAlreadyReading = self.freqLock.withLock { $0.isReading }
            guard !isAlreadyReading, (!self.eCoreFreqs.isEmpty || !self.sCoreFreqs.isEmpty) && !self.pCoreFreqs.isEmpty, self.channels != nil, self.subscription != nil else { return }
            
            self.freqLock.withLock { $0.isReading = true }
            
            let minECoreFreq = Double(self.eCoreFreqs.min() ?? 0)
            let minPCoreFreq = Double(self.pCoreFreqs.min() ?? 0)
            let minSCoreFreq = Double(self.sCoreFreqs.min() ?? 0)
            
            Task.detached(priority: .background) {
                var eCores: [Double] = []
                var sCores: [Double] = []
                var pCores: [Double] = []
                
                for (samples, _) in await self.getSamples() {
                    var eCore: [Double] = []
                    var pCore: [Double] = []
                    var sCore: [Double] = []
                    
                    for sample in samples {
                        guard sample.group == "CPU Stats" else { continue }
                        if sample.channel.contains("ECPU") {
                            eCore.append(self.calculateFrequencies(dict: sample.delta, freqs: self.eCoreFreqs))
                        }
                        if sample.channel.contains(self.sCoreCount == 0 ? "PCPU" : "MCPU") {
                            pCore.append(self.calculateFrequencies(dict: sample.delta, freqs: self.pCoreFreqs))
                        }
                        if self.sCoreCount != 0 {
                            if sample.channel.contains("PCPU") {
                                sCore.append(self.calculateFrequencies(dict: sample.delta, freqs: self.sCoreFreqs))
                            }
                        }
                    }
                    
                    if !eCore.isEmpty {
                        eCores.append(max(eCore.reduce(0.0, +) / Double(eCore.count), minECoreFreq))
                    }
                    if !pCore.isEmpty {
                        pCores.append(max(pCore.reduce(0.0, +) / Double(pCore.count), minPCoreFreq))
                    }
                    if !sCore.isEmpty {
                        sCores.append(max(sCore.reduce(0.0, +) / Double(sCore.count), minSCoreFreq))
                    }
                }
                
                let eFreq: Double? = eCores.isEmpty ? nil : eCores.reduce(0, +) / Double(self.measurementCount)
                let pFreq: Double? = pCores.isEmpty ? nil : pCores.reduce(0, +) / Double(self.measurementCount)
                let sFreq: Double? = sCores.isEmpty ? nil : sCores.reduce(0, +) / Double(self.measurementCount)
                
                var activeCores: Double = 0
                var totalFreq: Double = 0
                
                if let freq = eFreq {
                    activeCores += self.eCoreCount
                    totalFreq += freq * self.eCoreCount
                }
                if let freq = pFreq {
                    activeCores += self.pCoreCount
                    totalFreq += freq * self.pCoreCount
                }
                if let freq = sFreq {
                    activeCores += self.sCoreCount
                    totalFreq += freq * self.sCoreCount
                }
                let value: Double? = activeCores > 0 ? totalFreq / activeCores : nil
                
                let result = CPU_Frequency(value: value, eCore: eFreq, pCore: pFreq, sCore: sFreq)
                await MainActor.run {
                    self.callback(result)
                    self.freqLock.withLock { $0.isReading = false }
                }
            }
        }
    }
    
    nonisolated private func calculateFrequencies(dict: CFDictionary, freqs: [Int32]) -> Double {
        let items = self.getResidencies(dict: dict)
        guard let offset = items.firstIndex(where: { $0.0 != "IDLE" && $0.0 != "DOWN" && $0.0 != "OFF" }) else { return 0 }
        let usage = items.dropFirst(offset).reduce(0.0) { $0 + Double($1.f) }
        let count = freqs.count
        var avgFreq: Double = 0
        
        for i in 0..<count {
            let key = i + offset
            if !items.indices.contains(key) { continue }
            let percent = usage == 0 ? 0 : Double(items[key].f) / usage
            avgFreq += percent * Double(freqs[i])
        }
        
        return avgFreq
    }
    
    nonisolated private func getResidencies(dict: CFDictionary) -> [(ns: String, f: Int64)] {
        let count = IOReportStateGetCount(dict)
        var res: [(String, Int64)] = []
        for i in 0..<count {
            let name = IOReportStateGetNameForIndex(dict, i)?.takeUnretainedValue() ?? ("" as CFString)
            let val = IOReportStateGetResidency(dict, i)
            res.append((name as String, val))
        }
        return res
    }
    
    nonisolated private func getChannels() -> CFMutableDictionary? {
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
              let dict = mutableCopy as? [String: Any], dict["IOReportChannels"] != nil else {
            return nil
        }
        return mutableCopy
    }
    
    nonisolated private func getSamples() async -> [([IOSample], TimeInterval)] {
        let duration = 500
        let step = UInt64(duration / self.measurementCount)
        var samples = [([IOSample], TimeInterval)]()
        guard let initialSample = self.getSample() else { return samples }
        
        var prev = self.freqLock.withLock { $0.prev } ?? initialSample
        
        for _ in 0..<self.measurementCount {
            try? await Task.sleep(nanoseconds: UInt64(step) * 1_000_000)
            guard let next = self.getSample() else { continue }
            if let diffCF = IOReportCreateSamplesDelta(prev.samples, next.samples, nil) {
                let diff = diffCF.takeRetainedValue()
                let elapsed = next.time - prev.time
                samples.append((self.collectIOSamples(data: diff), max(elapsed, TimeInterval(1))))
            }
            prev = next
        }
        let finalPrev = prev
        self.freqLock.withLock { $0.prev = finalPrev }
        return samples
    }
    
    nonisolated private func getSample() -> Sample? {
        guard let sample = IOReportCreateSamples(self.subscription, self.channels, nil)?.takeRetainedValue() else {
            return nil
        }
        return Sample(samples: sample, time: Date().timeIntervalSince1970)
    }
    
    nonisolated private func collectIOSamples(data: CFDictionary) -> [IOSample] {
        guard let items = (data as? [String: Any])?["IOReportChannels"] as? NSArray else { return [] }
        let itemSize = items.count
        var samples = [IOSample]()
        for index in 0..<itemSize {
            let itemDict = items[index]
            let item = unsafeBitCast(itemDict, to: CFDictionary.self)
            let group = IOReportChannelGetGroup(item)?.takeUnretainedValue() ?? ("" as CFString)
            let subGroup = IOReportChannelGetSubGroup(item)?.takeUnretainedValue() ?? ("" as CFString)
            let channel = IOReportChannelGetChannelName(item)?.takeUnretainedValue() ?? ("" as CFString)
            let unit = IOReportChannelGetUnitLabel(item)?.takeUnretainedValue() ?? ("" as CFString)
            samples.append(IOSample(group: group as String, subGroup: subGroup as String, channel: channel as String, unit: unit as String, delta: item))
        }
        return samples
    }
}

public class LimitReader: Reader<CPU_Limit>, @unchecked Sendable {
    private var limits: CPU_Limit = CPU_Limit()
    
    nonisolated public override func read() {
        Task { @MainActor in
            let limit = await Task.detached(priority: .background) {
                var res = CPU_Limit()
                let output = syncShell("/usr/bin/pmset -g therm")
                var lines = output.split(separator: "\n")
                if lines.count > 3 {
                    lines.removeFirst(3)
                    lines.forEach { (line: Substring) in
                        guard let value = Int(line.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) else { return }
                        if line.contains("Scheduler") {
                            res.scheduler = value
                        } else if line.contains("CPUs") {
                            res.cpus = value
                        } else if line.contains("Speed") {
                            res.speed = value
                        }
                    }
                }
                return res
            }.value
            self.limits = limit
            self.callback(self.limits)
        }
    }
}

public class AverageLoadReader: Reader<CPU_AverageLoad>, @unchecked Sendable {
    private let title: String = "CPU"
    private let loadLock = OSAllocatedUnfairLock(initialState: CPU_AverageLoad())
    
    public override func setup() {
        self.popup = false
        self.setInterval(15)
    }
    
    nonisolated public override func read() {
        Task { @MainActor in
            let result = await Task.detached(priority: .background) {
                let output = syncShell("/usr/bin/uptime")
                guard let line = output.split(separator: "\n").first else { return nil as [Double]? }
                let str = String(line).trimmingCharacters(in: .whitespaces)
                let strFind = str.findAndCrop(pattern: "(\\d+(.|,)\\d+ *){3}$")
                let strArr = strFind.cropped.split(separator: " ")
                guard strArr.count == 3 else { return nil }
                return strArr.compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
            }.value
            
            if let list = result, list.count == 3 {
                self.loadLock.withLock { load in
                    load.load1 = list[0]
                    load.load5 = list[1]
                    load.load15 = list[2]
                    self.callback(load)
                }
            }
        }
    }
}
