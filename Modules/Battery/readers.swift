//
//  readers.swift
//  Battery
//
//  Created by Serhiy Mytrovtsiy on 06/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
@preconcurrency import Kit
import IOKit.ps

internal class UsageReader: Reader<Battery_Usage>, @unchecked Sendable {
    nonisolated private let service: io_connect_t = {
        let matching = IOServiceMatching("AppleSmartBattery")
        return IOServiceGetMatchingService(kIOMainPortDefault, matching)
    }()
    
    private var source: CFRunLoopSource?
    private var loop: CFRunLoop?
    
    private var usage: Battery_Usage = Battery_Usage()
    private var lastPowerSource: String? = nil
    
    deinit {
        IOObjectRelease(self.service)
    }
    
    public override func start() {
        self.active = true
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        self.source = IOPSNotificationCreateRunLoopSource({ (context) in
            guard let ctx = context else {
                return
            }
            
            let watcher = Unmanaged<UsageReader>.fromOpaque(ctx).takeUnretainedValue()
            if watcher.active {
                watcher.read()
            }
        }, context).takeRetainedValue()
        
        self.loop = RunLoop.current.getCFRunLoop()
        CFRunLoopAddSource(self.loop, source, .defaultMode)
        
        self.read()
    }
    
    public override func stop() {
        guard let runLoop = loop, let source = source else {
            return
        }
        
        self.active = false
        CFRunLoopRemoveSource(runLoop, source, .defaultMode)
    }
    
    nonisolated public override func read() {
        Task.detached(priority: .background) {
            let psInfo = IOPSCopyPowerSourcesInfo().takeRetainedValue()
            let psList = IOPSCopyPowerSourcesList(psInfo).takeRetainedValue() as [CFTypeRef]
            
            if psList.isEmpty {
                return
            }
            
            for ps in psList {
                if let list = IOPSGetPowerSourceDescription(psInfo, ps).takeUnretainedValue() as? [String: Any] {
                    var usage = await MainActor.run { self.usage }
                    
                    usage.powerSource = list[kIOPSPowerSourceStateKey] as? String ?? "AC Power"
                    usage.isBatteryPowered = usage.powerSource == "Battery Power"
                    usage.isCharged = list[kIOPSIsChargedKey] as? Bool ?? false
                    usage.isCharging = self.getBoolValue("IsCharging" as CFString) ?? false
                    usage.optimizedChargingEngaged = list["Optimized Battery Charging Engaged"] as? Int == 1
                    usage.level = Double(list[kIOPSCurrentCapacityKey] as? Int ?? 0) / 100
                    
                    if let time = list[kIOPSTimeToEmptyKey] as? Int {
                        usage.timeToEmpty = Int(time)
                    }
                    if let time = list[kIOPSTimeToFullChargeKey] as? Int {
                        usage.timeToCharge = Int(time)
                    }
                    
                    let lastPowerSource = await MainActor.run { self.lastPowerSource }
                    if usage.powerSource == "AC Power" {
                        if lastPowerSource != "AC Power" {
                            usage.timeOnACPower = Date()
                        }
                    } else {
                        usage.timeOnACPower = nil
                    }
                    
                    usage.cycles = self.getIntValue("CycleCount" as CFString) ?? 0
                    usage.currentCapacity = self.getIntValue("AppleRawCurrentCapacity" as CFString) ?? 0
                    usage.designedCapacity = self.getIntValue("DesignCapacity" as CFString) ?? 1
                    if usage.designedCapacity == 0 {
                        usage.designedCapacity = 1
                    }
                    usage.maxCapacity = self.getIntValue("AppleRawMaxCapacity" as CFString) ?? 1
                    usage.state = list[kIOPSBatteryHealthKey] as? String
                    usage.health = Int((Double(100 * usage.maxCapacity) / Double(usage.designedCapacity)).rounded(.toNearestOrEven))
                    
                    usage.amperage = self.getIntValue("Amperage" as CFString) ?? self.getIntValue("InstantAmperage" as CFString) ?? 0
                    usage.voltage = self.getVoltage() ?? 0
                    usage.temperature = self.getTemperature() ?? 0
                    usage.systemPower = SMC.shared.getValue("PSTR") ?? 0
                    
                    var ACwatts: Int = 0
                    if let ACDetails = IOPSCopyExternalPowerAdapterDetails() {
                        if let ACList = ACDetails.takeRetainedValue() as? [String: Any] {
                            if let watts = ACList[kIOPSPowerAdapterWattsKey] as? Int {
                                ACwatts = watts
                            }
                        }
                    }
                    usage.ACwatts = ACwatts
                    
                    if let chargerData = self.getChargerData() {
                        usage.chargingCurrent = chargerData["ChargingCurrent"] as? Int ?? 0
                        usage.chargingVoltage = chargerData["ChargingVoltage"] as? Int ?? 0
                    }
                    
                    let powerSource = usage.powerSource
                    let finalUsage = usage
                    await MainActor.run {
                        self.usage = finalUsage
                        self.lastPowerSource = powerSource
                        self.callback(finalUsage)
                    }
                }
            }
        }
    }
    
    nonisolated private func getBoolValue(_ forIdentifier: CFString) -> Bool? {
        if let value = IORegistryEntryCreateCFProperty(self.service, forIdentifier, kCFAllocatorDefault, 0) {
            return value.takeRetainedValue() as? Bool
        }
        return nil
    }
    
    nonisolated private func getIntValue(_ identifier: CFString) -> Int? {
        if let value = IORegistryEntryCreateCFProperty(self.service, identifier, kCFAllocatorDefault, 0) {
            return value.takeRetainedValue() as? Int
        }
        return nil
    }
    
    nonisolated private func getNumberValue(_ identifier: CFString) -> Double? {
        if let value = IORegistryEntryCreateCFProperty(self.service, identifier, kCFAllocatorDefault, 0) {
            let unwrapped = value.takeRetainedValue()
            if let double = unwrapped as? Double {
                return double
            } else if let int = unwrapped as? Int {
                return Double(int)
            }
        }
        return nil
    }
    
    nonisolated private func getVoltage() -> Double? {
        if let value = self.getNumberValue("Voltage" as CFString) {
            return value / 1000.0
        }
        return nil
    }
    
    nonisolated private func getTemperature() -> Double? {
        if let value = self.getNumberValue("Temperature" as CFString) {
            return value / 100.0
        }
        return nil
    }
    
    nonisolated private func getChargerData() -> [String: Any]? {
        if let chargerData = IORegistryEntryCreateCFProperty(service, "ChargerData" as CFString, kCFAllocatorDefault, 0) {
            return chargerData.takeRetainedValue() as? [String: Any]
        }
        return nil
    }
}

public class ProcessReader: Reader<[TopProcess]>, @unchecked Sendable {
    private var numberOfProcesses: Int {
        get {
            return Store.shared.int(key: "Battery_processes", defaultValue: 8)
        }
    }
    
    public override func setup() {
        self.popup = true
    }
    
    nonisolated public override func read() {
        Task { @MainActor in
            let limit = self.numberOfProcesses
            let log = self.log
            
            if limit == 0 {
                return
            }
            
            Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                let task = Process()
            task.launchPath = "/usr/bin/top"
            task.arguments = ["-o", "power", "-l", "2", "-n", "\(limit)", "-stats", "pid,command,power"]
            
            let outputPipe = Pipe()
            task.standardOutput = outputPipe
            
            do {
                try task.run()
            } catch let err {
                error("error read ps: \(err.localizedDescription)", log: log)
                return
            }
            
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            outputPipe.fileHandleForReading.closeFile()
            if outputData.isEmpty {
                return
            }
            
            let output = String(data: outputData.advanced(by: outputData.count/2), encoding: .utf8)
            guard let output, !output.isEmpty else { return }
            
            var processes: [TopProcess] = []
            output.enumerateLines { (line, _) in
                if line.matches("^\\d+ *[^(\\d)]*\\d+\\.*\\d* *$") {
                    let str = line.trimmingCharacters(in: .whitespaces)
                    let pidFind = str.findAndCrop(pattern: "^\\d+")
                    let usageFind = pidFind.remain.findAndCrop(pattern: " +[0-9]+.*[0-9]*$")
                    let command = usageFind.remain.trimmingCharacters(in: .whitespaces)
                    let pid = Int(pidFind.cropped) ?? 0
                    guard let usage = Double(usageFind.cropped.filter("01234567890.".contains)) else {
                        return
                    }
                    
                    var name: String = command
                    if let app = NSRunningApplication(processIdentifier: pid_t(pid)), let n = app.localizedName {
                        name = n
                    }
                    
                    processes.append(TopProcess(pid: pid, name: name, usage: usage))
                }
            }
            
            let result = Array(processes.suffix(limit).sorted(by: { $0.usage > $1.usage }))
            await MainActor.run {
                self.callback(result)
            }
        }
        }
    }
}
