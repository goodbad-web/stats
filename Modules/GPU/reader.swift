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

public struct device {
    public let vendor: String?
    public let model: String
    public let pci: String
    public var used: Bool
}

let vendors: [Data: String] = [
    Data.init([0x02, 0x10, 0x00, 0x00]): "AMD"
]

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

internal class InfoReader: Reader<GPUs>, @unchecked Sendable {
    private nonisolated(unsafe) var gpus: GPUs = GPUs()
    private nonisolated(unsafe) var displays: [gpu_s] = []
    private nonisolated(unsafe) var devices: [device] = []

    private nonisolated(unsafe) var powerChannels: CFMutableDictionary? = nil
    private nonisolated(unsafe) var powerSubscription: IOReportSubscriptionRef? = nil
    private nonisolated(unsafe) var previousPowerEnergy: [String: Double] = [:]
    private nonisolated(unsafe) var previousPowerRead: Date? = nil
    private nonisolated(unsafe) var aneMaxPower: Double = 8.0

    private nonisolated(unsafe) var framesChannels: CFMutableDictionary? = nil
    private nonisolated(unsafe) var framesSubscription: IOReportSubscriptionRef? = nil
    private nonisolated(unsafe) var previousFramesCount: Int64 = 0
    private nonisolated(unsafe) var previousFramesTime: CFAbsoluteTime = 0
    
    public override func setup() {
        if let list = SystemKit.shared.device.info.gpu {
            self.displays = list
        }
        
        guard let PCIdevices = fetchIOService("IOPCIDevice") else {
            return
        }
        let devices = PCIdevices.filter{ $0.object(forKey: "IOName") as? String == "display" }
        
        self.aneMaxPower = maxANEPower(for: SystemKit.shared.device.platform)
        self.setupPower()
        self.setupFrames()

        devices.forEach { (dict: NSDictionary) in
            guard let deviceID = dict["device-id"] as? Data, let vendorID = dict["vendor-id"] as? Data else {
                error("device-id or vendor-id not found", log: self.log)
                return
            }
            let pci = "0x" + Data([deviceID[1], deviceID[0], vendorID[1], vendorID[0]]).map { String(format: "%02hhX", $0) }.joined().lowercased()
            
            guard let modelData = dict["model"] as? Data, let modelName = String(data: modelData, encoding: .ascii) else {
                error("GPU model not found", log: self.log)
                return
            }
            let model = modelName.replacingOccurrences(of: "\0", with: "")
            
            var vendor: String? = nil
            if let v = vendors.first(where: { $0.key == vendorID }) {
                vendor = v.value
            }
            
            self.devices.append(device(
                vendor: vendor,
                model: model,
                pci: pci,
                used: false
            ))
        }
    }
    
    @MainActor public override func terminate() {
        self.powerChannels = nil
        self.powerSubscription = nil
        self.framesChannels = nil
        self.framesSubscription = nil
    }
    
    nonisolated public override func read() {
        Task { @MainActor in
            let updatedGPUs = await Task.detached(priority: .userInitiated) {
                guard let accelerators = fetchIOService(kIOAcceleratorClassName) else {
                    return self.gpus
                }
                
                let vramTotal = Int64(ProcessInfo.processInfo.physicalMemory)
                
                for (index, accelerator) in accelerators.enumerated() {
                    guard let IOClass = accelerator.object(forKey: "IOClass") as? String else {
                        continue
                    }
                    
                    guard let stats = accelerator["PerformanceStatistics"] as? [String: Any] else {
                        continue
                    }
                    
                    var id: String = ""
                    var vendor: String? = nil
                    var model: String = ""
                    var cores: Int? = nil
                    let accMatch = (accelerator["IOPCIMatch"] as? String ?? accelerator["IOPCIPrimaryMatch"] as? String ?? "").lowercased()
                    
                    for (i, device) in self.devices.enumerated() {
                        if accMatch.range(of: device.pci) != nil && !device.used {
                            model = device.model
                            vendor = device.vendor
                            id = "\(model) #\(index)"
                            self.devices[i].used = true
                            break
                        }
                    }
                    
                    let ioClass = IOClass.lowercased()
                    var predictModel = ""
                    var type: GPU_types = .unknown
                    
                    let utilization: Int? = stats["Device Utilization %"] as? Int ?? stats["GPU Activity(%)"] as? Int ?? nil
                    let renderUtilization: Int? = stats["Renderer Utilization %"] as? Int ?? nil
                    let tilerUtilization: Int? = stats["Tiler Utilization %"] as? Int ?? nil
                    var temperature: Int? = stats["Temperature(C)"] as? Int ?? nil
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
                    
                    if ioClass == "nvaccelerator" || ioClass.contains("nvidia") { // nvidia
                        predictModel = "Nvidia Graphics"
                        type = .discrete
                    } else if ioClass.contains("amd") { // amd
                        predictModel = "AMD Graphics"
                        type = .discrete
                        
                        if temperature == nil || temperature == 0 {
                            if let tmp = SMC.shared.getValue("TGDD"), tmp != 128 {
                                temperature = Int(tmp)
                            }
                        }
                    } else if ioClass.contains("agx") { // apple
                        predictModel = stats["model"] as? String ?? "Apple Graphics"
                        if let display = self.displays.first(where: { $0.vendor == "sppci_vendor_Apple" }) {
                            if let name = display.name {
                                predictModel = name
                            }
                            if let num = display.cores {
                                cores = num
                            }
                        }
                        type = .integrated
                    } else {
                        predictModel = "Unknown"
                        type = .unknown
                    }
                    
                    if model == "" {
                        model = predictModel
                    }
                    if let v = vendor {
                        model = model.removedRegexMatches(pattern: v, replaceWith: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    
                    if self.gpus.list.first(where: { $0.id == id }) == nil {
                        self.gpus.list.append(GPU_Info(
                            id: id,
                            type: type.rawValue,
                            IOClass: IOClass,
                            vendor: vendor,
                            model: model,
                            cores: cores
                        ))
                        if self.gpus.list.last?.id == id {
                            self.gpus.list[self.gpus.list.count - 1].vramTotal = vramTotal
                        }
                    }
                    guard let idx = self.gpus.list.firstIndex(where: { $0.id == id }) else {
                        continue
                    }
                    
                    if let value = vramUsed, let total = self.gpus.list[idx].vramTotal, total != 0 {
                        self.gpus.list[idx].vramUsed = Double(value) / Double(total)
                    }
                    self.gpus.list[idx].topProcesses = topProcesses
                    
                    if let agcInfo = accelerator["AGCInfo"] as? [String: Int], let state = agcInfo["poweredOffByAGC"] {
                        self.gpus.list[idx].state = state == 0
                    }
                    
                    if var value = utilization {
                        if value > 100 {
                            value = 100
                        }
                        self.gpus.list[idx].utilization = Double(value)/100
                    }
                    if var value = renderUtilization {
                        if value > 100 {
                            value = 100
                        }
                        self.gpus.list[idx].renderUtilization = Double(value)/100
                    }
                    if var value = tilerUtilization {
                        if value > 100 {
                            value = 100
                        }
                        self.gpus.list[idx].tilerUtilization = Double(value)/100
                    }
                    if let value = temperature {
                        self.gpus.list[idx].temperature = Double(value)
                    }
                    if let value = fanSpeed {
                        self.gpus.list[idx].fanSpeed = value
                    }
                    if let value = coreClock {
                        self.gpus.list[idx].coreClock = value
                    }
                    if let value = memoryClock {
                        self.gpus.list[idx].memoryClock = value
                    }
                }
                
                let power = self.readPower()
                let anePower = power["ANE"] ?? 0
                let gpuPower = power["GPU"] ?? 0
                let aneUtil = anePower / self.aneMaxPower
                let fpsValue = self.readFrames()
                
                for i in self.gpus.list.indices where self.gpus.list[i].IOClass.lowercased().contains("agx") {
                    self.gpus.list[i].aneUtilization = min(1, max(0, aneUtil))
                    self.gpus.list[i].gpuPower = gpuPower
                    self.gpus.list[i].fps = fpsValue
                }
                
                self.gpus.list.sort{ !$0.state && $1.state }
                return self.gpus
            }.value
            
            self.callback(updatedGPUs)
        }
    }
    
    // MARK: - FPS
    
    private func setupFrames() {
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
        
        guard let merged, let dict = (merged as AnyObject) as? [String: Any], dict["IOReportChannels"] != nil else { return }
        
        self.framesChannels = merged
        var sub: Unmanaged<CFMutableDictionary>?
        self.framesSubscription = IOReportCreateSubscription(nil, merged, &sub, 0, nil)
        sub?.release()
    }
    
    nonisolated private func readFrames() -> Double? {
        guard let subscription = self.framesSubscription,
              let channels = self.framesChannels,
              let sample = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue(),
              let dict = (sample as AnyObject) as? [String: Any],
              let items = dict["IOReportChannels"] as? NSArray else {
            return nil
        }
        
        var total: Int64 = 0
        for i in 0..<items.count {
            let item = items[i] as! CFDictionary
            guard let group = IOReportChannelGetGroup(item)?.takeUnretainedValue() as? String,
                  group.hasPrefix("DCP"),
                  let sub = IOReportChannelGetSubGroup(item)?.takeUnretainedValue() as? String,
                  sub == "swap" else { continue }
            total += IOReportSimpleGetIntegerValue(item, 0)
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
    
    // MARK: - Power
    
    private func setupPower() {
        guard let channel = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return }
        
        let size = CFDictionaryGetCount(channel)
        guard let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, size, channel),
              let dict = (mutable as AnyObject) as? [String: Any], dict["IOReportChannels"] != nil else { return }
        
        self.powerChannels = mutable
        var sub: Unmanaged<CFMutableDictionary>?
        self.powerSubscription = IOReportCreateSubscription(nil, mutable, &sub, 0, nil)
        sub?.release()
    }
    
    nonisolated private func readPower() -> [String: Double] {
        guard let subscription = self.powerSubscription,
              let channels = self.powerChannels,
              let reportSample = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue(),
              let dict = (reportSample as AnyObject) as? [String: Any],
              let items = dict["IOReportChannels"] as? NSArray else {
            return [:]
        }
        
        var energies: [String: Double] = [:]
        for i in 0..<items.count {
            let item = items[i] as! CFDictionary
            
            guard let group = IOReportChannelGetGroup(item)?.takeUnretainedValue() as? String,
                  group == "Energy Model",
                  let channel = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as? String else { continue }
            
            let key: String
            if channel.starts(with: "ANE") {
                key = "ANE"
            } else if channel.starts(with: "GPU") {
                key = "GPU"
            } else {
                continue
            }
            
            let raw = Double(IOReportSimpleGetIntegerValue(item, 0))
            let unit = (IOReportChannelGetUnitLabel(item)?.takeUnretainedValue() as? String)?
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
