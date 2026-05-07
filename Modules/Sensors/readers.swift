//
//  readers.swift
//  Sensors
//
//  Created by Serhiy Mytrovtsiy on 17/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
@preconcurrency import Kit
import IOKit.ps
import os

internal class SensorsReader: Reader<Sensors_List>, @unchecked Sendable {
    nonisolated static let HIDtypes: [SensorType] = [.temperature, .voltage]
    
    internal nonisolated(unsafe) var list: Sensors_List = Sensors_List()
    
    private nonisolated(unsafe) var lastRead: Date = Date()
    private let firstRead: Date = Date()
    private nonisolated(unsafe) var lastIOSensorsRead: Date? = nil
    
    private var hidState: Bool {
        Store.shared.bool(key: "Sensors_hid", defaultValue: false)
    }
    private var unknownSensorsState: Bool
    
    private nonisolated(unsafe) var channels: CFMutableDictionary? = nil
    private nonisolated(unsafe) var subscription: IOReportSubscriptionRef? = nil
    private nonisolated(unsafe) var powers: (CPU: Double, GPU: Double, ANE: Double, RAM: Double, PCI: Double) = (0.0, 0.0, 0.0, 0.0, 0.0)
    
    @MainActor init(callback: @escaping (T?) -> Void = {_ in }) {
        self.unknownSensorsState = Store.shared.bool(key: "Sensors_unknown", defaultValue: false)
        super.init(.sensors, callback: callback)
        
        self.channels = self.getChannels()
        var dict: Unmanaged<CFMutableDictionary>?
        self.subscription = IOReportCreateSubscription(nil, self.channels, &dict, 0, nil)
        dict?.release()
        
        self.list.sensors = self.sensors()
    }
    
    private func sensors() -> [Sensor_p] {
        var available: [String] = SMC.shared.getAllKeys()
        var list: [Sensor_p] = []
        var sensorsList = SensorsList
        
        if let platform = SystemKit.shared.device.platform {
            sensorsList = sensorsList.filter({ $0.platforms.contains(platform) })
        }
        
        if let count = SMC.shared.getValue("FNum") {
            list += self.loadFans(Int(count))
        }
        
        available = available.filter({ (key: String) -> Bool in
            switch key.prefix(1) {
            case "T", "V", "P", "I": return true
            default: return false
            }
        })
        
        sensorsList.forEach { (s: Sensor) in
            if let idx = available.firstIndex(where: { $0 == s.key }) {
                list.append(s)
                available.remove(at: idx)
            }
        }
        sensorsList.filter{ $0.key.contains("%") }.forEach { (s: Sensor) in
            var index = 1
            for i in 0..<10 {
                let key = s.key.replacingOccurrences(of: "%", with: "\(i)")
                if let idx = available.firstIndex(where: { $0 == key }) {
                    var sensor = s.copy()
                    sensor.key = key
                    sensor.name = s.name.replacingOccurrences(of: "%", with: "\(index)")
                    
                    list.append(sensor)
                    available.remove(at: idx)
                    index += 1
                }
            }
        }
        available.forEach { (key: String) in
            var type: SensorType? = nil
            switch key.prefix(1) {
            case "T": type = .temperature
            case "V": type = .voltage
            case "P": type = .power
            case "I": type = .current
            default: type = nil
            }
            if let t = type {
                list.append(Sensor(key: key, name: key, group: .unknown, type: t, platforms: []))
            }
        }
        
        for sensor in list {
            if let newValue = SMC.shared.getValue(sensor.key) {
                if let idx = list.firstIndex(where: { $0.key == sensor.key }) {
                    list[idx].value = newValue
                }
            }
        }
        
        var results: [Sensor_p] = []
        results += list.filter({ (s: Sensor_p) -> Bool in
            if s.type == .temperature && (s.value == 0 || s.value > 110) {
                return false
            } else if s.type == .current && s.value > 100 {
                return false
            }
            return true
        })
        
        if self.hidState {
            results += self.initHIDSensors()
        }
        results += self.initIOSensors()
        results += self.initCalculatedSensors(results)
        results.append(Sensor(key: "battery_amperage", name: "Battery", group: .sensor, type: .current, platforms: Platform.all))
        results.append(Sensor(key: "battery_power", name: "Battery", group: .sensor, type: .power, platforms: Platform.all))
        
        return results
    }
    
    nonisolated private func getBatteryData() -> (raw: Int, corrected: Int, voltage: Int) {
        var raw: Int = 0
        var corrected: Int = 0
        var voltage: Int = 0
        
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            if let amperage = IORegistryEntryCreateCFProperty(service, "Amperage" as CFString, kCFAllocatorDefault, 0) {
                raw = (amperage.takeRetainedValue() as? Int ?? 0)
            } else if let amperage = IORegistryEntryCreateCFProperty(service, "InstantAmperage" as CFString, kCFAllocatorDefault, 0) {
                raw = (amperage.takeRetainedValue() as? Int ?? 0)
            }
            
            if let v = IORegistryEntryCreateCFProperty(service, "Voltage" as CFString, kCFAllocatorDefault, 0) {
                voltage = (v.takeRetainedValue() as? Int ?? 0)
            }
            
            corrected = raw
            if let telemetry = IORegistryEntryCreateCFProperty(service, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0) {
                if let dict = telemetry.takeRetainedValue() as? [String: Any] {
                    let batteryPowerMW = dict["BatteryPower"] as? Int ?? (dict["BatteryPower"] as? Double).map{ Int($0) }
                    if let power = batteryPowerMW, power == 0 && abs(raw) < 50 {
                        corrected = 0
                    }
                }
            }
            IOObjectRelease(service)
        }
        return (raw, corrected, voltage)
    }
    
    private let readLock = OSAllocatedUnfairLock(initialState: false)
    
    nonisolated public override func read() {
        let isReading = self.readLock.withLock { $0 }
        guard !isReading else { return }
        self.readLock.withLock { $0 = true }
        
        Task { @MainActor in
            let localUnknownSensorsState = self.unknownSensorsState
            let localHidState = self.hidState
            let localSensors = self.list.sensors
            let localLastRead = self.lastRead
            let localFirstRead = self.firstRead
            
            let updatedSensors = await Task.detached(priority: .background) {
                var sensors = localSensors
                for i in sensors.indices {
                    guard sensors[i].group != .hid && !sensors[i].isComputed else { continue }
                    if !localUnknownSensorsState && sensors[i].group == .unknown { continue }
                    
                    var newValue: Double = 0
                    if sensors[i].key == "battery_amperage" || sensors[i].key == "battery_power" {
                        let batteryData = self.getBatteryData()
                        if sensors[i].key == "battery_amperage" {
                            newValue = Double(abs(batteryData.corrected)) / 1000.0
                        } else if sensors[i].key == "battery_power" {
                            newValue = (Double(abs(batteryData.corrected)) / 1000.0) * (Double(batteryData.voltage) / 1000.0)
                        }
                    } else {
                        newValue = SMC.shared.getValue(sensors[i].key) ?? 0
                    }
                    
                    if sensors[i].type == .temperature && (newValue < 0 || newValue > 125) {
                        newValue = sensors[i].value
                    }
                    sensors[i].value = newValue
                }
                
                var cpuSensors = sensors.filter({ $0.group == .CPU && $0.type == .temperature && $0.average }).map{ $0.value }
                var gpuSensors = sensors.filter({ $0.group == .GPU && $0.type == .temperature && $0.average }).map{ $0.value }
                let fanSensors = sensors.filter({ $0.type == .fan && !$0.isComputed })
                
                if localHidState {
                    for typ in SensorsReader.HIDtypes {
                        let (page, usage, type) = self.m1Preset(type: typ)
                        AppleSiliconSensors(page, usage, type).forEach { (key, value) in
                            guard let key = key as? String, let value = value as? Double, value < 300 && value >= 0 else {
                                return
                            }
                            
                            if let idx = sensors.firstIndex(where: { $0.group == .hid && $0.key == key }) {
                                sensors[idx].value = value
                            }
                        }
                    }
                    
                    cpuSensors += sensors.filter({ $0.key.hasPrefix("pACC MTR Temp") || $0.key.hasPrefix("eACC MTR Temp") }).map{ $0.value }
                    gpuSensors += sensors.filter({ $0.key.hasPrefix("GPU MTR Temp") }).map{ $0.value }
                    
                    let socSensors = sensors.filter({ $0.key.hasPrefix("SOC MTR Temp") }).map{ $0.value }
                    if !socSensors.isEmpty {
                        if let idx = sensors.firstIndex(where: { $0.key == "Average SOC" }) {
                            sensors[idx].value = socSensors.reduce(0, +) / Double(socSensors.count)
                        }
                        if let idx = sensors.firstIndex(where: { $0.key == "Hottest SOC" }) {
                            sensors[idx].value = socSensors.max() ?? 0
                        }
                    }
                }
                
                if !cpuSensors.isEmpty {
                    if let idx = sensors.firstIndex(where: { $0.key == "Average CPU" }) {
                        sensors[idx].value = cpuSensors.reduce(0, +) / Double(cpuSensors.count)
                    }
                    if let idx = sensors.firstIndex(where: { $0.key == "Hottest CPU" }) {
                        sensors[idx].value = cpuSensors.max() ?? 0
                    }
                }
                if !gpuSensors.isEmpty {
                    if let idx = sensors.firstIndex(where: { $0.key == "Average GPU" }) {
                        sensors[idx].value = gpuSensors.reduce(0, +) / Double(gpuSensors.count)
                    }
                    if let idx = sensors.firstIndex(where: { $0.key == "Hottest GPU" }) {
                        sensors[idx].value = gpuSensors.max() ?? 0
                    }
                }
                
                if !fanSensors.isEmpty {
                    if let idx = sensors.firstIndex(where: { $0.key == "Average Fan" }) {
                        sensors[idx].value = fanSensors.map{ $0.value }.reduce(0, +) / Double(fanSensors.count)
                    }
                    if let idx = sensors.firstIndex(where: { $0.key == "Fastest Fan" }) {
                        sensors[idx].value = fanSensors.map{ $0.value }.max() ?? 0
                    }
                }
                
                if let PSTRSensor = sensors.first(where: { $0.key == "PSTR"}), PSTRSensor.value > 0 {
                    let now = Date()
                    let sinceLastRead = now.timeIntervalSince(localLastRead)
                    let sinceFirstRead = now.timeIntervalSince(localFirstRead)
                    
                    if let totalIdx = sensors.firstIndex(where: {$0.key == "Total System Consumption"}), sinceLastRead > 0 {
                        sensors[totalIdx].value += PSTRSensor.value * sinceLastRead / 3600
                        if let avgIdx = sensors.firstIndex(where: {$0.key == "Average System Total"}), sinceFirstRead > 0 {
                            sensors[avgIdx].value = sensors[totalIdx].value * 3600 / sinceFirstRead
                        }
                    }
                }
                
                if let idx = sensors.firstIndex(where: { $0.key == "VD0R" }), sensors[idx].value < 0.4 {
                    sensors[idx].value = 0
                }
                if let idx = sensors.firstIndex(where: { $0.key == "ID0R" }), sensors[idx].value < 0.05 {
                    sensors[idx].value = 0
                }
                return sensors
            }.value
            
            self.list.sensors = updatedSensors
            self.lastRead = Date()
            
            let safetyState = Store.shared.bool(key: "Sensors_fanSafety", defaultValue: true)
            if safetyState {
                let hottest = updatedSensors.filter{ $0.type == .temperature && ($0.group == .CPU || $0.group == .GPU || $0.group == .hid) }.map{ $0.value }.max() ?? 0
                if hottest > 95 {
                    if updatedSensors.filter({ $0 is Fan }).contains(where: { ($0 as? Fan)?.mode == .forced }) {
                        SMCHelper.shared.resetFanControl()
                        NotificationCenter.default.post(name: .fanControlOverride, object: nil, userInfo: ["reason": "high_temp"])
                    }
                }
            }
            
            let batteryAutoState = Store.shared.bool(key: "Sensors_fanBatteryAuto", defaultValue: false)
            if batteryAutoState && !self.isAC() {
                if updatedSensors.filter({ $0 is Fan }).contains(where: { ($0 as? Fan)?.mode == .forced }) {
                    SMCHelper.shared.resetFanControl()
                    NotificationCenter.default.post(name: .fanControlOverride, object: nil, userInfo: ["reason": "battery"])
                }
            }
            if let (cpu, gpu, ane, ram, pci) = self.IOSensors() {
                if let idx = self.list.sensors.firstIndex(where: { $0.key == "CPU Power" }) {
                    self.list.sensors[idx].value = cpu
                }
                if let idx = self.list.sensors.firstIndex(where: { $0.key == "GPU Power" }) {
                    self.list.sensors[idx].value = gpu
                }
                if let idx = self.list.sensors.firstIndex(where: { $0.key == "ANE Power" }) {
                    self.list.sensors[idx].value = ane
                }
                if let idx = self.list.sensors.firstIndex(where: { $0.key == "RAM Power" }) {
                    self.list.sensors[idx].value = ram
                }
                if let idx = self.list.sensors.firstIndex(where: { $0.key == "PCI Power" }) {
                    self.list.sensors[idx].value = pci
                }
            }
            let newList = Sensors_List()
            newList.sensors = updatedSensors
            
            if let old = self.value, old == newList {
                self.readLock.withLock { $0 = false }
                return
            }
            
            self.list.sensors = updatedSensors
            self.callback(self.list)
            self.readLock.withLock { $0 = false }
        }
    }
    
    private func initCalculatedSensors(_ sensors: [Sensor_p]) -> [Sensor_p] {
        var list: [Sensor_p] = []
        
        var cpuSensors = sensors.filter({ $0.group == .CPU && $0.type == .temperature && $0.average }).map{ $0.value }
        var gpuSensors = sensors.filter({ $0.group == .GPU && $0.type == .temperature && $0.average }).map{ $0.value }
        
        if self.hidState {
            cpuSensors += sensors.filter({ $0.key.hasPrefix("pACC MTR Temp") || $0.key.hasPrefix("eACC MTR Temp") }).map{ $0.value }
            gpuSensors += sensors.filter({ $0.key.hasPrefix("GPU MTR Temp") }).map{ $0.value }
        }
        
        let fanSensors = sensors.filter({ $0.type == .fan && !$0.isComputed })
        
        if !cpuSensors.isEmpty {
            let value = cpuSensors.reduce(0, +) / Double(cpuSensors.count)
            list.append(Sensor(key: "Average CPU", name: "Average CPU", value: value, group: .CPU, type: .temperature, platforms: Platform.all, isComputed: true))
            if let max = cpuSensors.max() {
                list.append(Sensor(key: "Hottest CPU", name: "Hottest CPU", value: max, group: .CPU, type: .temperature, platforms: Platform.all, isComputed: true))
            }
        }
        if !gpuSensors.isEmpty {
            let value = gpuSensors.reduce(0, +) / Double(gpuSensors.count)
            list.append(Sensor(key: "Average GPU", name: "Average GPU", value: value, group: .GPU, type: .temperature, platforms: Platform.all, isComputed: true))
            if let max = gpuSensors.max() {
                list.append(Sensor(key: "Hottest GPU", name: "Hottest GPU", value: max, group: .GPU, type: .temperature, platforms: Platform.all, isComputed: true))
            }
        }
        if !fanSensors.isEmpty && fanSensors.count > 1 {
            if let f = fanSensors.max(by: { $0.value < $1.value }) as? Fan {
                list.append(Fan(id: -1, key: "Fastest fan", name: "Fastest fan", minSpeed: f.minSpeed, maxSpeed: f.maxSpeed, value: f.value, mode: .automatic, isComputed: true))
            }
        }
        
        if sensors.contains(where: { $0.key == "PSTR"}) {
            list.append(Sensor(key: "Total System Consumption", name: "Total System Consumption", value: 0, group: .sensor, type: .energy, platforms: Platform.all, isComputed: true))
            list.append(Sensor(key: "Average System Total", name: "Average System Total", value: 0, group: .sensor, type: .power, platforms: Platform.all, isComputed: true))
        }
        
        return list.filter({ (s: Sensor_p) -> Bool in
            switch s.type {
            case .temperature:
                return s.value < 110 && s.value >= 0
            case .voltage:
                return s.value < 300 && s.value >= 0
            case .current:
                return s.value < 100 && s.value >= 0
            default: return true
            }
        }).sorted { $0.key.lowercased() < $1.key.lowercased() }
    }
    
    public func unknownCallback() {
        self.unknownSensorsState = Store.shared.bool(key: "Sensors_unknown", defaultValue: false)
    }
    
    public override func terminate() {
        self.subscription = nil
        self.channels = nil
        super.terminate()
    }
}

// MARK: - Fans

extension SensorsReader {
    private func loadFans(_ count: Int) -> [Sensor_p] {
        var list: [Fan] = []
        for i in 0..<Int(count) {
            var name = SMC.shared.getStringValue("F\(i)ID")
            
            if name == nil && count == 2 {
                switch i {
                case 0:
                    name = localizedString("Left fan")
                case 1:
                    name = localizedString("Right fan")
                default: break
                }
            }
            
            let mode = self.getFanMode(i)
            
            list.append(Fan(
                id: i,
                key: "F\(i)Ac",
                name: name ?? "\(localizedString("Fan")) #\(i)",
                minSpeed: SMC.shared.getValue("F\(i)Mn") ?? 1,
                maxSpeed: SMC.shared.getValue("F\(i)Mx") ?? 1,
                value: SMC.shared.getValue("F\(i)Ac") ?? 0,
                mode: mode
            ))
        }
        
        return list
    }
    
    private func getFanMode(_ id: Int) -> FanMode {
        let modeValue = Int(SMC.shared.getValue(SMC.shared.fanModeKey(id)) ?? 0)
        return modeValue == 1 ? .forced : .automatic
    }
    
    nonisolated private func isAC() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return true
        }
        
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
                if let type = description[kIOPSTypeKey] as? String, type == kIOPSInternalBatteryType {
                    if let powerSource = description[kIOPSPowerSourceStateKey] as? String {
                        return powerSource == kIOPSACPowerValue
                    }
                }
            }
        }
        
        return true
    }
}

// MARK: - HID sensors

extension SensorsReader {
    nonisolated private func m1Preset(type: SensorType) -> (Int32, Int32, Int32) {
        var page: Int32 = 0
        var usage: Int32 = 0
        var eventType: Int32 = kIOHIDEventTypeTemperature
        
        switch type {
        case .temperature:
            page = 0xff00
            usage = 0x0005
            eventType = kIOHIDEventTypeTemperature
        case .current:
            page = 0xff08
            usage = 0x0002
            eventType = kIOHIDEventTypePower
        case .voltage:
            page = 0xff08
            usage = 0x0003
            eventType = kIOHIDEventTypePower
        case .power, .energy, .fan: break
        }
        
        return (page, usage, eventType)
    }
    
    private func initHIDSensors() -> [Sensor] {
        var list: [Sensor] = []
        
        for typ in SensorsReader.HIDtypes {
            let (page, usage, type) = self.m1Preset(type: typ)
            if let sensors = AppleSiliconSensors(page, usage, type) {
                sensors.forEach { (key, value) in
                    guard let key = key as? String, let value = value as? Double else {
                        return
                    }
                    var name: String = key
                    
                    HIDSensorsList.forEach { (s: Sensor) in
                        if s.key.contains("%") {
                            var index = 1
                            for i in 0..<64 {
                                if s.key.replacingOccurrences(of: "%", with: "\(i)") == key {
                                    name = s.name.replacingOccurrences(of: "%", with: "\(index)")
                                }
                                index += 1
                            }
                        } else if s.key == key {
                            name = s.name
                        }
                    }
                    
                    list.append(Sensor(
                        key: key,
                        name: name,
                        value: value,
                        group: .hid,
                        type: typ,
                        platforms: Platform.all
                    ))
                }
            }
        }
        
        let socSensors = list.filter({ $0.key.hasPrefix("SOC MTR Temp") }).map{ $0.value }
        if !socSensors.isEmpty {
            let value = socSensors.reduce(0, +) / Double(socSensors.count)
            list.append(Sensor(key: "Average SOC", name: "Average SOC", value: value, group: .hid, type: .temperature, platforms: Platform.all))
            if let max = socSensors.max() {
                list.append(Sensor(key: "Hottest SOC", name: "Hottest SOC", value: max, group: .hid, type: .temperature, platforms: Platform.all))
            }
        }
        
        return list.filter({ (s: Sensor_p) -> Bool in
            switch s.type {
            case .temperature:
                return s.value < 110 && s.value >= 0
            case .voltage:
                return s.value < 300 && s.value >= 0
            case .current:
                return s.value < 100 && s.value >= 0
            default: return true
            }
        }).sorted { $0.key.lowercased() < $1.key.lowercased() }
    }
    
    public func HIDCallback() {
        if self.hidState {
            self.list.sensors += self.initHIDSensors()
        } else {
            self.list.sensors = self.list.sensors.filter({ $0.group != .hid })
        }
    }
}

// MARK: - Apple Silicon power sensors

extension SensorsReader {
    private func getChannels() -> CFMutableDictionary? {
        let channelNames: [(String, String?)] = [("Energy Model", nil)]
        
        var channels: [CFDictionary] = []
        for (gname, sname) in channelNames {
            let channel = IOReportCopyChannelsInGroup(gname as CFString?, sname as CFString?, 0, 0, 0)
            guard let channel = channel?.takeRetainedValue() else { continue }
            channels.append(channel)
        }
        
        if channels.isEmpty { return nil }
        let chan = channels[0]
        for i in 1..<channels.count {
            IOReportMergeChannels(chan, channels[i], nil)
        }
        
        let size = CFDictionaryGetCount(chan)
        guard let channel = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, size, chan),
              let chanDict = (channel as AnyObject) as? [String: Any], chanDict["IOReportChannels"] != nil else {
            return nil
        }
        
        return channel
    }
    
    private func initIOSensors() -> [Sensor] {
        guard let (cpu, gpu, ane, ram, pci) = self.IOSensors() else { return [] }
        return [
            Sensor(key: "CPU Power", name: "CPU Power", value: cpu, group: .CPU, type: .power, platforms: Platform.apple, isComputed: true),
            Sensor(key: "GPU Power", name: "GPU Power", value: gpu, group: .GPU, type: .power, platforms: Platform.apple, isComputed: true),
            Sensor(key: "ANE Power", name: "ANE Power", value: ane, group: .system, type: .power, platforms: Platform.apple, isComputed: true),
            Sensor(key: "RAM Power", name: "RAM Power", value: ram, group: .system, type: .power, platforms: Platform.apple, isComputed: true),
            Sensor(key: "PCI Power", name: "PCI Power", value: pci, group: .system, type: .power, platforms: Platform.apple, isComputed: true)
        ]
    }
    
    private static func appleSiliconPower(currentEnergy: Double, previousEnergy: Double, elapsed: TimeInterval) -> Double {
        guard elapsed > 0 else { return 0 }
        return (currentEnergy - previousEnergy) / elapsed
    }

    private func IOSensors() -> (Double, Double, Double, Double, Double)? {
        guard let reportSample = IOReportCreateSamples(self.subscription, self.channels, nil)?.takeRetainedValue(),
              let dict = (reportSample as AnyObject) as? [String: Any] else {
            return nil
        }
        guard let items = dict["IOReportChannels"] as? NSArray else {
            return nil
        }
        let now = Date()
        
        let prevCPU = self.powers.CPU
        let prevGPU = self.powers.GPU
        let prevANE = self.powers.ANE
        let prevRAM = self.powers.RAM
        let prevPCI = self.powers.PCI
        
        for i in 0..<items.count {
            let item = items[i] as! CFDictionary
            
            guard let group = IOReportChannelGetGroup(item)?.takeUnretainedValue() as? String,
                  group == "Energy Model",
                  let channel = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as? String,
                  let unit = IOReportChannelGetUnitLabel(item)?.takeUnretainedValue() as? String else { continue }
            
            let value = Double(IOReportSimpleGetIntegerValue(item, 0))
            
            if channel.hasSuffix("CPU Energy") {
                self.powers.CPU = value.power(unit)
            } else if channel.hasSuffix("GPU Energy") {
                self.powers.GPU = value.power(unit)
            } else if channel.starts(with: "ANE") {
                self.powers.ANE = value.power(unit)
            } else if channel.starts(with: "DRAM") {
                self.powers.RAM = value.power(unit)
            } else if channel.starts(with: "PCI") && channel.hasSuffix("Energy") {
                self.powers.PCI = value.power(unit)
            }
        }
        
        guard let lastIOSensorsRead = self.lastIOSensorsRead else {
            self.lastIOSensorsRead = now
            return (0, 0, 0, 0, 0)
        }
        guard prevCPU != 0 else {
            self.lastIOSensorsRead = now
            return (0, 0, 0, 0, 0)
        }
        
        let elapsed = now.timeIntervalSince(lastIOSensorsRead)
        defer { self.lastIOSensorsRead = now }
        return (
            Self.appleSiliconPower(currentEnergy: self.powers.CPU, previousEnergy: prevCPU, elapsed: elapsed),
            Self.appleSiliconPower(currentEnergy: self.powers.GPU, previousEnergy: prevGPU, elapsed: elapsed),
            Self.appleSiliconPower(currentEnergy: self.powers.ANE, previousEnergy: prevANE, elapsed: elapsed),
            Self.appleSiliconPower(currentEnergy: self.powers.RAM, previousEnergy: prevRAM, elapsed: elapsed),
            Self.appleSiliconPower(currentEnergy: self.powers.PCI, previousEnergy: prevPCI, elapsed: elapsed)
        )
    }
}
