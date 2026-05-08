//
//  reader.swift
//  GPU
//
//  Created by Serhiy Mytrovtsiy on 17/08/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
@preconcurrency import Kit
import os

public struct device {
    public let vendor: String?
    public let model: String
    public let pci: String
    public var used: Bool
}

private func maxANEPower(for platform: Platform?) -> Double {
    switch platform {
    case .m1, .m1Pro, .m1Max:       return 2.0
    case .m1Ultra:                  return 4.0
    case .m2, .m2Pro, .m2Max:       return 2.5
    case .m2Ultra:                  return 5.0
    case .m3, .m3Pro, .m3Max:       return 3.0
    case .m3Ultra:                  return 6.0
    case .m4, .m4Pro, .m4Max:       return 6.0
    case .m4Ultra:                  return 12.0
    case .m5, .m5Pro, .m5Max:       return 8.0
    case .m5Ultra:                  return 16.0
    default:                        return 8.0
    }
}

private actor GPUReaderWorker {
    private var powerChannels: CFMutableDictionary?
    private var powerSubscription: IOReportSubscriptionRef?
    private var previousPowerEnergy: [String: Double] = [:]
    private var previousPowerRead: Date? = nil
    
    private var framesChannels: CFMutableDictionary?
    private var framesSubscription: IOReportSubscriptionRef?
    private var previousFramesCount: Int64 = 0
    private var previousFramesTime: CFAbsoluteTime = 0
    
    private let aneMaxPower: Double
    private var displays: [gpu_s] = []
    
    init() {
        self.aneMaxPower = maxANEPower(for: SystemKit.shared.device.platform)
        if let list = SystemKit.shared.device.info.gpu {
            self.displays = list
        }
        
        let (pc, ps) = Self.initializePower()
        self.powerChannels = pc
        self.powerSubscription = ps
        
        let (fc, fs) = Self.initializeFrames()
        self.framesChannels = fc
        self.framesSubscription = fs
    }
    
    static private func initializePower() -> (CFMutableDictionary?, IOReportSubscriptionRef?) {
        guard let channel = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return (nil, nil) }
        
        let size = CFDictionaryGetCount(channel)
        guard let dict = channel as? [String: Any],
              let items = dict["IOReportChannels"] as? [[String: Any]] else { return (nil, nil) }
        
        var filteredItems: [[String: Any]] = []
        for item in items {
            if let name = item["IOReportChannelName"] as? String {
                if name.hasPrefix("ANE") || name.hasPrefix("GPU") || 
                   name.hasSuffix("Media Energy") || name.hasPrefix("VCP") || name.hasPrefix("DCP") {
                    filteredItems.append(item)
                }
            }
        }
        
        if filteredItems.isEmpty { return (nil, nil) }
        
        var mutableDict = dict
        mutableDict["IOReportChannels"] = filteredItems
        guard let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, size, mutableDict as CFDictionary) else { return (nil, nil) }
        
        var sub: Unmanaged<CFMutableDictionary>?
        let subscription = IOReportCreateSubscription(nil, mutable, &sub, 0, nil)
        sub?.release()
        return (mutable, subscription)
    }
    
    static private func initializeFrames() -> (CFMutableDictionary?, IOReportSubscriptionRef?) {
        let groups = ["DCP", "DCPEXT0", "DCPEXT1", "DCPEXT2", "DCPEXT3"]
        var merged: CFMutableDictionary? = nil
        for group in groups {
            guard let channel = IOReportCopyChannelsInGroup(group as CFString, "swap" as CFString, 0, 0, 0)?.takeRetainedValue() else { continue }
            if merged == nil {
                merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channel)
            } else {
                IOReportMergeChannels(merged, channel, nil)
            }
        }
        guard let merged, let dict = (merged as AnyObject) as? [String: Any], dict["IOReportChannels"] != nil else { return (nil, nil) }
        var sub: Unmanaged<CFMutableDictionary>?
        let subscription = IOReportCreateSubscription(nil, merged, &sub, 0, nil)
        sub?.release()
        return (merged, subscription)
    }
    
    func read(currentGPUs: GPUs) async -> GPUs {
        guard let accelerators = fetchIOService(kIOAcceleratorClassName) else {
            return currentGPUs
        }
        
        let updatedGPUs = currentGPUs
        let vramTotal = Int64(ProcessInfo.processInfo.physicalMemory)
        
        for (index, accelerator) in accelerators.enumerated() {
            guard let IOClass = accelerator.object(forKey: "IOClass") as? String else {
                continue
            }
            
            guard let stats = accelerator["PerformanceStatistics"] as? [String: Any] else {
                continue
            }
            
            var vendor: String? = nil
            var model: String = ""
            var cores: Int? = nil
            
            let ioClass = IOClass.lowercased()
            var type: GPU_types = .unknown
            
            let utilization: Int? = stats["Device Utilization %"] as? Int ?? stats["GPU Activity(%)"] as? Int ?? nil
            let renderUtilization: Int? = stats["Renderer Utilization %"] as? Int ?? nil
            let tilerUtilization: Int? = stats["Tiler Utilization %"] as? Int ?? nil
            let temperature: Int? = stats["Temperature(C)"] as? Int ?? nil
            let fanSpeed: Int? = stats["Fan Speed(%)"] as? Int ?? nil
            let coreClock: Int? = stats["Core Clock(MHz)"] as? Int ?? nil
            let memoryClock: Int? = stats["Memory Clock(MHz)"] as? Int ?? nil
            
            let vramUsed: Int64? = stats["In use system memory"] as? Int64 ?? stats["vramUsedBytes"] as? Int64 ?? nil
            
            var topProcesses: [TopProcess] = []
            if let clients = accelerator["Clients"] as? NSArray {
                for client in clients {
                    guard let clientDict = client as? NSDictionary else { continue }
                    
                    let pid = (clientDict["ProcessID"] as? NSNumber)?.intValue ?? (clientDict["pid"] as? NSNumber)?.intValue ?? 0
                    let name = (clientDict["ProcessName"] as? String) ?? (clientDict["ExecutableName"] as? String) ?? "Unknown"
                    guard pid != 0 && name != "Unknown" else { continue }
                    
                    var usage: Double = 0
                    if let stats = clientDict["PerformanceStatistics"] as? NSDictionary {
                        usage = (stats["Device Utilization %"] as? NSNumber)?.doubleValue ?? (stats["GPU Activity(%)"] as? NSNumber)?.doubleValue ?? 0
                    } else if let u = clientDict["Device Utilization %"] as? NSNumber {
                        usage = u.doubleValue
                    }
                    
                    topProcesses.append(TopProcess(pid: pid, name: name, usage: usage))
                }
            }
            topProcesses.sort { $0.usage > $1.usage }
            
            if ioClass.contains("agx") { // apple
                model = stats["model"] as? String ?? "Apple Graphics"
                if let display = self.displays.first(where: { $0.vendor == "sppci_vendor_Apple" }) {
                    if let name = display.name {
                        model = name
                    }
                    if let num = display.cores {
                        cores = num
                    }
                }
                vendor = "Apple"
                type = .integrated
            } else {
                model = "Unknown"
                type = .unknown
            }
            
            let id = "\(model) #\(index)"
            
            if updatedGPUs.list.first(where: { $0.id == id }) == nil {
                updatedGPUs.list.append(GPU_Info(
                    id: id,
                    type: type.rawValue,
                    IOClass: IOClass,
                    vendor: vendor,
                    model: model,
                    cores: cores
                ))
                if updatedGPUs.list.last?.id == id {
                    updatedGPUs.list[updatedGPUs.list.count - 1].vramTotal = vramTotal
                }
            }
            guard let idx = updatedGPUs.list.firstIndex(where: { $0.id == id }) else {
                continue
            }
            
            if let value = vramUsed, let total = updatedGPUs.list[idx].vramTotal, total != 0 {
                updatedGPUs.list[idx].vramUsed = Double(value) / Double(total)
            }
            updatedGPUs.list[idx].topProcesses = topProcesses
            
            if let agcInfo = accelerator["AGCInfo"] as? [String: Int], let state = agcInfo["poweredOffByAGC"] {
                updatedGPUs.list[idx].state = state == 0
            }
            
            if var value = utilization {
                if value > 100 {
                    value = 100
                }
                updatedGPUs.list[idx].utilization = Double(value)/100
            }
            if var value = renderUtilization {
                if value > 100 {
                    value = 100
                }
                updatedGPUs.list[idx].renderUtilization = Double(value)/100
            }
            if var value = tilerUtilization {
                if value > 100 {
                    value = 100
                }
                updatedGPUs.list[idx].tilerUtilization = Double(value)/100
            }
            if let value = temperature {
                updatedGPUs.list[idx].temperature = Double(value)
            }
            if let value = fanSpeed {
                updatedGPUs.list[idx].fanSpeed = value
            }
            if let value = coreClock {
                updatedGPUs.list[idx].coreClock = value
            }
            if let value = memoryClock {
                updatedGPUs.list[idx].memoryClock = value
            }
        }
        
        let power = self.readPower()
        let anePower = power["ANE"] ?? 0
        let gpuPower = power["GPU"] ?? 0
        let mediaPower = power["Media"] ?? 0
        let aneUtil = anePower / self.aneMaxPower
        let mediaUtil = mediaPower / 1.0 // Estimate for now, or use maxMediaPower
        let fpsValue = self.readFrames()
        
        for i in updatedGPUs.list.indices where updatedGPUs.list[i].IOClass.lowercased().contains("agx") {
            updatedGPUs.list[i].aneUtilization = min(1, max(0, aneUtil))
            updatedGPUs.list[i].mediaUtilization = min(1, max(0, mediaUtil))
            updatedGPUs.list[i].gpuPower = gpuPower
            updatedGPUs.list[i].fps = fpsValue
        }
        
        updatedGPUs.list.sort{ !$0.state && $1.state }
        return updatedGPUs
    }
    
    private func readFrames() -> Double? {
        guard let subscription = self.framesSubscription,
              let channels = self.framesChannels,
              let sample = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue(),
              let dict = (sample as AnyObject) as? [String: Any],
              let items = dict["IOReportChannels"] as? NSArray else {
            return nil
        }
        
        var total: Int64 = 0
        for i in 0..<items.count {
            guard let item = items[i] as? NSDictionary else { continue }
            let channelInfo = item as CFDictionary
            guard let group = IOReportChannelGetGroup(channelInfo)?.takeUnretainedValue() as? String,
                  group.hasPrefix("DCP"),
                  let sub = IOReportChannelGetSubGroup(channelInfo)?.takeUnretainedValue() as? String,
                  sub == "swap" else { continue }
            total += IOReportSimpleGetIntegerValue(channelInfo, 0)
        }
        
        let now = CFAbsoluteTimeGetCurrent()
        defer {
            self.previousFramesCount = total
            self.previousFramesTime = now
        }
        
        guard self.previousFramesTime != 0 else { return nil }
        let elapsed = now - self.previousFramesTime
        guard elapsed > 0 else { return nil }
        let delta = total - self.previousFramesCount
        guard delta >= 0 else { return nil }
        return Double(delta) / elapsed
    }
    
    private func readPower() -> [String: Double] {
        guard let subscription = self.powerSubscription,
              let channels = self.powerChannels,
              let reportSample = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue(),
              let dict = (reportSample as AnyObject) as? [String: Any],
              let items = dict["IOReportChannels"] as? NSArray else {
            return [:]
        }
        
        var energies: [String: Double] = [:]
        for i in 0..<items.count {
            guard let item = items[i] as? NSDictionary else { continue }
            let channelInfo = item as CFDictionary
            
            guard let group = IOReportChannelGetGroup(channelInfo)?.takeUnretainedValue() as? String,
                  group == "Energy Model",
                  let channel = IOReportChannelGetChannelName(channelInfo)?.takeUnretainedValue() as? String else { continue }
            
            let key: String
            if channel.starts(with: "ANE") {
                key = "ANE"
            } else if channel.starts(with: "GPU") {
                key = "GPU"
            } else if channel.hasSuffix("Media Energy") || channel.starts(with: "VCP") || channel.starts(with: "DCP") {
                key = "Media"
            } else {
                continue
            }
            
            let raw = Double(IOReportSimpleGetIntegerValue(channelInfo, 0))
            let unit = (IOReportChannelGetUnitLabel(channelInfo)?.takeUnretainedValue() as? String)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            
            let joules: Double
            switch unit.lowercased() {
            case "mj":       joules = raw / 1e3
            case "uj", "µj": joules = raw / 1e6
            case "nj":       joules = raw / 1e9
            case "pj":       joules = raw / 1e12
            default:         joules = raw / 1e9
            }
            
            energies[key] = (energies[key] ?? 0) + joules
        }
        
        let now = Date()
        defer {
            for (k, v) in energies {
                self.previousPowerEnergy[k] = v
            }
            self.previousPowerRead = now
        }
        
        guard let previousRead = self.previousPowerRead else { return [:] }
        let elapsed = now.timeIntervalSince(previousRead)
        guard elapsed > 0 else { return [:] }
        
        var result: [String: Double] = [:]
        for (k, v) in energies {
            if let prev = self.previousPowerEnergy[k] {
                result[k] = (v - prev) / elapsed
            }
        }
        return result
    }
}

internal class InfoReader: Reader<GPUs>, @unchecked Sendable {
    private let worker = GPUReaderWorker()
    private let usageState = OSAllocatedUnfairLock(initialState: GPUs())
    
    nonisolated private var gpus: GPUs {
        get { self.usageState.withLock { $0 } }
        set { self.usageState.withLock { $0 = newValue } }
    }
    
    public override func setup() {}
    
    public override func terminate() {}
    
    private let readLock = OSAllocatedUnfairLock(initialState: false)
    
    nonisolated public override func read() {
        let isReading = self.readLock.withLock { $0 }
        guard !isReading else { return }
        self.readLock.withLock { $0 = true }
        
        let currentGPUs = self.gpus
        let worker = self.worker
        
        Task(priority: .background) {
            defer { self.readLock.withLock { $0 = false } }
            let updatedGPUs = await worker.read(currentGPUs: currentGPUs)
            
            if let old = self.value, old == updatedGPUs {
                return
            }
            
            self.gpus = updatedGPUs
            self.callback(updatedGPUs)
        }
    }
}
