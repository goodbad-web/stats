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
import os
@preconcurrency import Kit
import IOKit.ps

private actor BatteryReaderWorker {
    private let service: io_connect_t
    private var lastPowerSource: String? = nil
    private var lastUsage: Battery_Usage? = nil
    
    init() {
        let matching = IOServiceMatching("AppleSmartBattery")
        self.service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    }
    
    deinit {
        IOObjectRelease(self.service)
    }
    
    func read(currentUsage: Battery_Usage) async -> Battery_Usage? {
        guard let psInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let psList = IOPSCopyPowerSourcesList(psInfo)?.takeRetainedValue() as? [CFTypeRef],
              !psList.isEmpty else {
            return nil
        }
        
        for ps in psList {
            if let list = IOPSGetPowerSourceDescription(psInfo, ps)?.takeUnretainedValue() as? [String: Any] {
                var usage = currentUsage
                let oldUsage = usage
                
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
                
                if usage.powerSource == "AC Power" {
                    if self.lastPowerSource != "AC Power" {
                        usage.timeOnACPower = Date()
                    } else {
                        usage.timeOnACPower = oldUsage.timeOnACPower
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
                usage.powerBusAmperage = usage.amperage
                if let telemetry = IORegistryEntryCreateCFProperty(self.service, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0) {
                    if let dict = telemetry.takeRetainedValue() as? [String: Any] {
                        let batteryPowerMW = dict["BatteryPower"] as? Int ?? (dict["BatteryPower"] as? Double).map{ Int($0) }
                        if let power = batteryPowerMW, power == 0 && abs(usage.amperage) < 50 && !usage.isBatteryPowered {
                            usage.amperage = 0
                        }
                    }
                }
                usage.voltage = self.getVoltage() ?? 0
                usage.temperature = self.getTemperature() ?? 0
                usage.systemPower = abs(usage.voltage * Double(usage.amperage) / 1000.0)
                
                var ACwatts: Int = 0
                if let ACDetails = IOPSCopyExternalPowerAdapterDetails() {
                    if let ACList = ACDetails.takeRetainedValue() as? [String: Any] {
                        if let watts = ACList[kIOPSPowerAdapterWattsKey] as? Int {
                            ACwatts = watts
                        }
                    }
                }
                usage.ACwatts = ACwatts
                
                if let adapterDetails = IORegistryEntryCreateCFProperty(self.service, "AdapterDetails" as CFString, kCFAllocatorDefault, 0) {
                    if let dict = adapterDetails.takeRetainedValue() as? [String: Any] {
                        usage.adapterMaxCurrent = dict["Current"] as? Int ?? 0
                        usage.adapterMaxVoltage = dict["AdapterVoltage"] as? Int ?? 0
                        if let watts = dict["Watts"] as? Int {
                            usage.ACwatts = watts
                        }
                    }
                }
                
                if let chargerData = self.getChargerData() {
                    usage.chargingCurrent = chargerData["ChargingCurrent"] as? Int ?? 0
                    usage.chargingVoltage = chargerData["ChargingVoltage"] as? Int ?? 0
                }
                
                if usage == oldUsage {
                    return nil
                }
                
                self.lastPowerSource = usage.powerSource
                self.lastUsage = usage
                return usage
            }
        }
        
        return nil
    }
    
    func getTopProcesses(limit: Int) async -> [TopProcess] {
        return await ProcessMonitor.shared.getTopProcesses(limit: limit, category: "Power")
    }
    
    private func getBoolValue(_ forIdentifier: CFString) -> Bool? {
        if let value = IORegistryEntryCreateCFProperty(self.service, forIdentifier, kCFAllocatorDefault, 0) {
            return value.takeRetainedValue() as? Bool
        }
        return nil
    }
    
    private func getIntValue(_ identifier: CFString) -> Int? {
        if let value = IORegistryEntryCreateCFProperty(self.service, identifier, kCFAllocatorDefault, 0) {
            return value.takeRetainedValue() as? Int
        }
        return nil
    }
    
    private func getNumberValue(_ identifier: CFString) -> Double? {
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
    
    private func getVoltage() -> Double? {
        if let value = self.getNumberValue("Voltage" as CFString) {
            return value / 1000.0
        }
        return nil
    }
    
    private func getTemperature() -> Double? {
        if let value = self.getNumberValue("Temperature" as CFString) {
            return value / 100.0
        }
        return nil
    }
    
    private func getChargerData() -> [String: Any]? {
        if let chargerData = IORegistryEntryCreateCFProperty(service, "ChargerData" as CFString, kCFAllocatorDefault, 0) {
            return chargerData.takeRetainedValue() as? [String: Any]
        }
        return nil
    }
}

internal class UsageReader: Reader<Battery_Usage>, @unchecked Sendable {
    private var source: CFRunLoopSource?
    private var loop: CFRunLoop?
    private let worker = BatteryReaderWorker()
    
    private struct UsageState {
        var usage: Battery_Usage = Battery_Usage()
        var isReading: Bool = false
    }
    private let usageState = OSAllocatedUnfairLock(initialState: UsageState())
    
    nonisolated private var isReading: Bool {
        get { self.usageState.withLock { $0.isReading } }
        set { self.usageState.withLock { $0.isReading = newValue } }
    }
    
    nonisolated private var usage: Battery_Usage {
        get { self.usageState.withLock { $0.usage } }
        set { self.usageState.withLock { $0.usage = newValue } }
    }
    
    public override func start() {
        guard !self.active else { return }
        self.active = true
        
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        self.source = IOPSNotificationCreateRunLoopSource({ (context) in
            guard let ctx = context else { return }
            let watcher = Unmanaged<UsageReader>.fromOpaque(ctx).takeUnretainedValue()
            if watcher.active {
                watcher.read()
            }
        }, context).takeRetainedValue()
        
        if let source = self.source {
            self.loop = RunLoop.current.getCFRunLoop()
            CFRunLoopAddSource(self.loop, source, .defaultMode)
        }
        
        self.read()
    }
    
    public override func stop() {
        guard self.active, let runLoop = loop, let source = source else {
            return
        }
        
        self.active = false
        CFRunLoopRemoveSource(runLoop, source, .defaultMode)
        self.source = nil
        self.loop = nil
    }
    
    public override func terminate() {
        self.stop()
    }
    
    nonisolated public override func read() {
        let isReading = self.isReading
        guard !isReading else { return }
        self.isReading = true
        
        let currentUsage = self.usage
        let worker = self.worker
        
        Task {
            defer { self.isReading = false }
            if let usage = await worker.read(currentUsage: currentUsage) {
                self.usage = usage
                self.callback(usage)
            }
        }
    }
}

public class ProcessReader: Reader<[TopProcess]>, @unchecked Sendable {
    private let worker = BatteryReaderWorker()
    
    private nonisolated var numberOfProcesses: Int {
        get { Store.shared.int(key: "Battery_processes", defaultValue: 8) }
    }
    
    public override func setup() {
        self.popup = true
        self.defaultInterval = 5
    }
    
    private let readLock = OSAllocatedUnfairLock(initialState: false)
    
    nonisolated public override func read() {
        let isReading = self.readLock.withLock { $0 }
        guard !isReading else { return }
        self.readLock.withLock { $0 = true }
        
        let worker = self.worker
        let limit = self.numberOfProcesses
        
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
