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

internal struct SensorsReadScope: Equatable, Sendable {
    internal var isFull: Bool
    internal var keys: Set<String>
    internal var types: Set<String>
    internal var hidTypes: Set<String>
    internal var needsIOSensors: Bool
    internal var needsBattery: Bool
    internal var needsFanMode: Bool

    internal static let full = SensorsReadScope(isFull: true)

    internal init(
        isFull: Bool = false,
        keys: Set<String> = [],
        types: Set<SensorType> = [],
        hidTypes: Set<SensorType> = [],
        needsIOSensors: Bool = false,
        needsBattery: Bool = false,
        needsFanMode: Bool = false
    ) {
        self.isFull = isFull
        self.keys = keys
        self.types = []
        self.hidTypes = Set(hidTypes.map(\.rawValue))
        self.needsIOSensors = needsIOSensors
        self.needsBattery = needsBattery
        self.needsFanMode = needsFanMode
        keys.forEach { self.expandComputedDependencies(for: $0) }
        types.forEach { self.include(type: $0) }
    }

    internal mutating func include(key: String) {
        guard !key.isEmpty else { return }
        self.keys.insert(key)
        self.expandComputedDependencies(for: key)
    }

    internal mutating func include(type: SensorType) {
        self.types.insert(type.rawValue)
        if type == .temperature {
            self.hidTypes.insert(SensorType.temperature.rawValue)
        } else if type == .voltage {
            self.hidTypes.insert(SensorType.voltage.rawValue)
        } else if type == .power {
            self.needsIOSensors = true
            self.needsBattery = true
        } else if type == .current {
            self.needsBattery = true
        } else if type == .fan {
            self.needsFanMode = true
        }
    }

    internal func contains(_ sensor: Sensor_p) -> Bool {
        self.isFull ||
            self.keys.contains(sensor.key) ||
            self.types.contains(sensor.type.rawValue)
    }

    internal func includesHID(type: SensorType) -> Bool {
        self.isFull || self.hidTypes.contains(type.rawValue)
    }

    internal func includesIOPower(key: String) -> Bool {
        self.isFull || self.needsIOSensors || self.keys.contains(key)
    }

    internal func includesBattery(key: String) -> Bool {
        self.isFull || self.needsBattery || self.keys.contains(key)
    }

    private mutating func expandComputedDependencies(for key: String) {
        switch key {
        case "Average CPU", "Hottest CPU":
            self.types.insert(SensorType.temperature.rawValue)
            self.hidTypes.insert(SensorType.temperature.rawValue)
        case "Average GPU", "Hottest GPU":
            self.types.insert(SensorType.temperature.rawValue)
            self.hidTypes.insert(SensorType.temperature.rawValue)
        case "Average SOC", "Hottest SOC":
            self.hidTypes.insert(SensorType.temperature.rawValue)
        case "Average Fan", "Fastest fan":
            self.types.insert(SensorType.fan.rawValue)
            self.needsFanMode = true
        case "CPU Power", "GPU Power", "ANE Power", "RAM Power", "PCI Power":
            self.needsIOSensors = true
        case "battery_amperage", "battery_power":
            self.needsBattery = true
        case "Average System Total", "Total System Consumption":
            self.keys.insert("PSTR")
        default:
            break
        }
    }

}

private actor SensorsReaderWorker {
    private var lastRead: Date = Date()
    private let firstRead: Date = Date()
    private var lastIOSensorsRead: Date? = nil
    
    private var channels: CFMutableDictionary?
    private var subscription: IOReportSubscriptionRef?
    private var powers: (CPU: Double, GPU: Double, ANE: Double, RAM: Double, PCI: Double, Media: Double) = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    
    init() {
        let (c, s) = Self.initializeIOReport()
        self.channels = c
        self.subscription = s
    }
    
    static private func initializeIOReport() -> (CFMutableDictionary?, IOReportSubscriptionRef?) {
        let c = getChannels()
        var dict: Unmanaged<CFMutableDictionary>?
        let s = IOReportCreateSubscription(nil, c, &dict, 0, nil)
        dict?.release()
        return (c, s)
    }
    
    func read(scope: SensorsReadScope, unknownSensorsState: Bool, hidState: Bool, currentSensors: [Sensor_p]) async -> [Sensor_p] {
        var sensors = currentSensors
        let smcKeys = sensors.indices.compactMap { i -> String? in
            let s = sensors[i]
            if s.group != .hid && !s.isComputed && s.key != "battery_amperage" && s.key != "battery_power" {
                if !unknownSensorsState && s.group == .unknown { return nil }
                if !scope.contains(s) { return nil }
                return s.key
            }
            return nil
        }
        let smcValues = await SMC.shared.getValues(smcKeys)

        for i in sensors.indices {
            guard sensors[i].group != .hid && !sensors[i].isComputed else { continue }
            if !unknownSensorsState && sensors[i].group == .unknown { continue }
            guard scope.contains(sensors[i]) || scope.includesBattery(key: sensors[i].key) else { continue }

            var newValue: Double = sensors[i].value
            if sensors[i].key == "battery_amperage" || sensors[i].key == "battery_power" {
                let batteryData = self.getBatteryData()
                if sensors[i].key == "battery_amperage" {
                    newValue = Double(abs(batteryData.corrected)) / 1000.0
                } else if sensors[i].key == "battery_power" {
                    newValue = (Double(abs(batteryData.corrected)) / 1000.0) * (Double(batteryData.voltage) / 1000.0)
                }
            } else {
                newValue = smcValues[sensors[i].key] ?? 0
            }

            if sensors[i].type == .temperature && (newValue < 0 || newValue > 125) {
                newValue = sensors[i].value
            }
            sensors[i].value = newValue
        }

        var cpuSensors = sensors.filter({ $0.group == .CPU && $0.type == .temperature && $0.average }).map{ $0.value }
        var gpuSensors = sensors.filter({ $0.group == .GPU && $0.type == .temperature && $0.average }).map{ $0.value }
        let fanSensors = sensors.filter({ $0.type == .fan && !$0.isComputed })

        if hidState {
            for typ in SensorsReader.HIDtypes {
                guard scope.includesHID(type: typ) else { continue }
                let (page, usage, type) = Self.m1Preset(type: typ)
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
            if let idx = sensors.firstIndex(where: { $0.key == "Fastest fan" }) {
                sensors[idx].value = fanSensors.map{ $0.value }.max() ?? 0
            }
        }

        if let PSTRSensor = sensors.first(where: { $0.key == "PSTR"}), PSTRSensor.value > 0 {
            let now = Date()
            let sinceLastRead = now.timeIntervalSince(self.lastRead)
            let sinceFirstRead = now.timeIntervalSince(self.firstRead)

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

        if scope.isFull || scope.needsIOSensors, let (cpu, gpu, ane, ram, pci, media) = self.IOSensors() {
            if let idx = sensors.firstIndex(where: { $0.key == "CPU Power" }) {
                sensors[idx].value = cpu
            }
            if let idx = sensors.firstIndex(where: { $0.key == "GPU Power" }) {
                sensors[idx].value = gpu
            }
            if let idx = sensors.firstIndex(where: { $0.key == "ANE Power" }) {
                sensors[idx].value = ane
            }
            if let idx = sensors.firstIndex(where: { $0.key == "RAM Power" }) {
                sensors[idx].value = ram
            }
            if let idx = sensors.firstIndex(where: { $0.key == "PCI Power" }) {
                sensors[idx].value = pci
            }
            if let idx = sensors.firstIndex(where: { $0.key == "Media Power" }) {
                sensors[idx].value = media
            }
        }
        
        self.lastRead = Date()
        return sensors
    }
    
    func setupInitialSensors(hidState: Bool) async -> [Sensor_p] {
        var available: [String] = await SMC.shared.getAllKeys()
        var list: [Sensor_p] = []
        var sensorsList = SensorsList

        if let platform = SystemKit.shared.device.platform {
            sensorsList = sensorsList.filter({ $0.platforms.contains(platform) })
        }

        if let count = await SMC.shared.getValue("FNum") {
            list += await self.loadFans(Int(count))
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

        for i in list.indices {
            if let newValue = await SMC.shared.getValue(list[i].key) {
                list[i].value = newValue
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

        if hidState {
            results += self.initHIDSensors()
        }
        results += self.initIOSensors()
        results += self.initCalculatedSensors(results, hidState: hidState)
        results.append(Sensor(key: "battery_amperage", name: "Battery", group: .sensor, type: .current, platforms: Platform.all))
        results.append(Sensor(key: "battery_power", name: "Battery", group: .sensor, type: .power, platforms: Platform.all))

        return results
    }
    
    func resetWorker() {
        self.subscription = nil
        self.channels = nil
    }
    
    func isAC() -> Bool {
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
    
    func getHIDSensors() -> [Sensor] {
        return self.initHIDSensors()
    }

    private func getBatteryData() -> (raw: Int, corrected: Int, voltage: Int) {
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
    
    private func loadFans(_ count: Int) async -> [Sensor_p] {
        var list: [Fan] = []
        for i in 0..<Int(count) {
            var name = await SMC.shared.getStringValue("F\(i)ID")

            if name == nil && count == 2 {
                switch i {
                case 0:
                    name = localizedString("Left fan")
                case 1:
                    name = localizedString("Right fan")
                default: break
                }
            }

            let modeValue = Int(await SMC.shared.getValue(await SMC.shared.fanModeKey(i)) ?? 0)
            let mode: FanMode = modeValue == 1 ? .forced : .automatic

            list.append(Fan(
                id: i,
                key: "F\(i)Ac",
                name: name ?? "\(localizedString("Fan")) #\(i)",
                minSpeed: await SMC.shared.getValue("F\(i)Mn") ?? 1,
                maxSpeed: await SMC.shared.getValue("F\(i)Mx") ?? 1,
                value: await SMC.shared.getValue("F\(i)Ac") ?? 0,
                mode: mode
            ))
        }

        return list
    }
    
    private func initHIDSensors() -> [Sensor] {
        var list: [Sensor] = []

        for typ in SensorsReader.HIDtypes {
            let (page, usage, type) = Self.m1Preset(type: typ)
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
    
    private func initIOSensors() -> [Sensor] {
        guard let (cpu, gpu, ane, ram, pci, media) = self.IOSensors() else { return [] }
        return [
            Sensor(key: "CPU Power", name: "CPU Power", value: cpu, group: .CPU, type: .power, platforms: Platform.apple, isComputed: true),
            Sensor(key: "GPU Power", name: "GPU Power", value: gpu, group: .GPU, type: .power, platforms: Platform.apple, isComputed: true),
            Sensor(key: "ANE Power", name: "ANE Power", value: ane, group: .system, type: .power, platforms: Platform.apple, isComputed: true),
            Sensor(key: "RAM Power", name: "RAM Power", value: ram, group: .system, type: .power, platforms: Platform.apple, isComputed: true),
            Sensor(key: "PCI Power", name: "PCI Power", value: pci, group: .system, type: .power, platforms: Platform.apple, isComputed: true),
            Sensor(key: "Media Power", name: "Media Power", value: media, group: .system, type: .power, platforms: Platform.apple, isComputed: true)
        ]
    }
    
    private func initCalculatedSensors(_ sensors: [Sensor_p], hidState: Bool) -> [Sensor_p] {
        var list: [Sensor_p] = []

        var cpuSensors = sensors.filter({ $0.group == .CPU && $0.type == .temperature && $0.average }).map{ $0.value }
        var gpuSensors = sensors.filter({ $0.group == .GPU && $0.type == .temperature && $0.average }).map{ $0.value }

        if hidState {
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
    
    static private func getChannels() -> CFMutableDictionary? {
        guard let channels = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else {
            return nil
        }
        
        let size = CFDictionaryGetCount(channels)
        guard let dict = channels as? [String: Any],
              let items = dict["IOReportChannels"] as? [[String: Any]] else {
            return nil
        }
        
        var filteredItems: [[String: Any]] = []
        for item in items {
            if let name = item["IOReportChannelName"] as? String {
                if name.hasSuffix("CPU Energy") || name.hasSuffix("GPU Energy") || 
                   name.hasPrefix("ANE") || name.hasPrefix("DRAM") || 
                   (name.hasPrefix("PCI") && name.hasSuffix("Energy")) || 
                   name.hasSuffix("Media Energy") || name.hasPrefix("VCP") || name.hasPrefix("DCP") {
                    filteredItems.append(item)
                }
            }
        }
        
        if filteredItems.isEmpty { return nil }
        
        var mutableDict = dict
        mutableDict["IOReportChannels"] = filteredItems
        return CFDictionaryCreateMutableCopy(kCFAllocatorDefault, size, mutableDict as CFDictionary)
    }
    private func IOSensors() -> (Double, Double, Double, Double, Double, Double)? {
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
        let prevMedia = self.powers.Media

        for i in 0..<items.count {
            guard let item = items[i] as? NSDictionary else { continue }
            let channelInfo = item as CFDictionary

            guard let group = IOReportChannelGetGroup(channelInfo)?.takeUnretainedValue() as? String,
                  group == "Energy Model",
                  let channel = IOReportChannelGetChannelName(channelInfo)?.takeUnretainedValue() as? String,
                  let unit = IOReportChannelGetUnitLabel(channelInfo)?.takeUnretainedValue() as? String else { continue }

            let value = Double(IOReportSimpleGetIntegerValue(channelInfo, 0))

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
            } else if channel.hasSuffix("Media Energy") || channel.starts(with: "VCP") || channel.starts(with: "DCP") {
                self.powers.Media = value.power(unit)
            }
        }

        guard let lastIOSensorsRead = self.lastIOSensorsRead else {
            self.lastIOSensorsRead = now
            return (0, 0, 0, 0, 0, 0)
        }
        guard prevCPU != 0 else {
            self.lastIOSensorsRead = now
            return (0, 0, 0, 0, 0, 0)
        }

        let elapsed = now.timeIntervalSince(lastIOSensorsRead)
        defer { self.lastIOSensorsRead = now }
        return (
            (self.powers.CPU - prevCPU) / elapsed,
            (self.powers.GPU - prevGPU) / elapsed,
            (self.powers.ANE - prevANE) / elapsed,
            (self.powers.RAM - prevRAM) / elapsed,
            (self.powers.PCI - prevPCI) / elapsed,
            (self.powers.Media - prevMedia) / elapsed
        )
    }
    
    static private func m1Preset(type: SensorType) -> (Int32, Int32, Int32) {
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
}

internal class SensorsReader: Reader<Sensors_List>, @unchecked Sendable {
    nonisolated static let HIDtypes: [SensorType] = [.temperature, .voltage]

    internal enum ActivityMode {
        case active
        case passive
        case paused
    }

    nonisolated private let listLock = OSAllocatedUnfairLock(initialState: Sensors_List())
    nonisolated internal var list: Sensors_List {
        get { self.listLock.withLock { $0 } }
        set { self.listLock.withLock { $0 = newValue } }
    }
    private let worker = SensorsReaderWorker()

    private nonisolated var hidState: Bool {
        Store.shared.bool(key: "Sensors_hid", defaultValue: true)
    }
    private var userInterval: Int = Store.shared.int(key: "Sensors_updateInterval", defaultValue: 3)
    private var activityMode: ActivityMode = .active
    private var effectiveInterval: Int?
    nonisolated private let unknownSensorsStateLock = OSAllocatedUnfairLock(initialState: false)
    nonisolated private let readScopeLock = OSAllocatedUnfairLock(initialState: SensorsReadScope.full)

    @MainActor init(callback: @escaping (T?) -> Void = {_ in }) {
        self.unknownSensorsStateLock.withLock { $0 = Store.shared.bool(key: "Sensors_unknown", defaultValue: false) }
        super.init(.sensors, callback: callback)

        let worker = self.worker
        let hidState = self.hidState
        Task {
            let list = await worker.setupInitialSensors(hidState: hidState)
            await MainActor.run {
                self.list.sensors = list
                self.callback(self.list)
            }
        }
    }

    internal func setUserInterval(_ value: Int) {
        guard self.userInterval != value else { return }
        self.userInterval = value
        self.applyActivityMode()
    }

    internal func setActivityMode(_ mode: ActivityMode) {
        guard self.activityMode != mode else { return }
        self.activityMode = mode
        self.applyActivityMode()
    }

    internal func setReadScope(_ scope: SensorsReadScope) {
        self.readScopeLock.withLock {
            guard $0 != scope else { return }
            $0 = scope
        }
    }

    private func applyActivityMode() {
        switch self.activityMode {
        case .active:
            self.applyInterval(self.userInterval)
            self.sleepMode(state: false)
        case .passive:
            self.applyInterval(max(self.userInterval * 3, 10))
            self.sleepMode(state: false)
        case .paused:
            self.sleepMode(state: true)
        }
    }

    private func applyInterval(_ value: Int) {
        guard self.effectiveInterval != value else { return }
        self.effectiveInterval = value
        super.setInterval(value)
    }

    public override func readAsync() async -> Sensors_List? {
        let scope = self.readScopeLock.withLock { $0 }
        let unknownState = self.unknownSensorsStateLock.withLock { $0 }
        let currentSensors = self.list.sensors
        
        let updatedSensors = await self.worker.read(
            scope: scope, 
            unknownSensorsState: unknownState, 
            hidState: self.hidState, 
            currentSensors: currentSensors
        )
        
        let safetyState = Store.shared.bool(key: "Sensors_fanSafety", defaultValue: true)
        if safetyState {
            let hottest = updatedSensors.filter{ $0.type == .temperature && ($0.group == .CPU || $0.group == .GPU || $0.group == .hid) }.map{ $0.value }.max() ?? 0
            if hottest > 95 {
                if updatedSensors.compactMap({ $0 as? Fan }).contains(where: { $0.mode == .forced }) {
                    await SMCHelper.shared.resetFanControl()
                    await MainActor.run {
                        NotificationCenter.default.post(name: .fanControlOverride, object: nil, userInfo: ["reason": "high_temp"])
                    }
                }
            }
        }

        let batteryAutoState = Store.shared.bool(key: "Sensors_fanBatteryAuto", defaultValue: false)
        if batteryAutoState {
            let isAC = await self.worker.isAC()
            if !isAC && updatedSensors.compactMap({ $0 as? Fan }).contains(where: { $0.mode == .forced }) {
                await SMCHelper.shared.resetFanControl()
                await MainActor.run {
                    NotificationCenter.default.post(name: .fanControlOverride, object: nil, userInfo: ["reason": "battery"])
                }
            }
        }
        
        let newList = self.list
        newList.sensors = updatedSensors
        self.list = newList
        return newList
    }

    public func unknownCallback() {
        self.unknownSensorsStateLock.withLock { $0 = Store.shared.bool(key: "Sensors_unknown", defaultValue: false) }
    }

    public func HIDCallback() {
        let hidState = self.hidState
        let worker = self.worker
        Task {
            if hidState {
                let sensors = await worker.getHIDSensors()
                await MainActor.run {
                    self.list.sensors += sensors
                }
            } else {
                await MainActor.run {
                    self.list.sensors = self.list.sensors.filter({ $0.group != .hid })
                }
            }
        }
    }

    public override func terminate() {
        let worker = self.worker
        Task {
            await worker.resetWorker()
        }
        super.terminate()
    }
}
