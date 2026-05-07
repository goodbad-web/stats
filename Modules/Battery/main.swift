//
//  main.swift
//  Battery
//
//  Created by Serhiy Mytrovtsiy on 06/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit
import IOKit.ps

struct Battery_Usage: Codable, Equatable {
    var powerSource: String = ""
    var state: String? = nil
    var isCharged: Bool = false
    var isCharging: Bool = false
    var isBatteryPowered: Bool = false
    var optimizedChargingEngaged: Bool = false
    var level: Double = 0
    var cycles: Int = 0
    var health: Int = 0
    
    var designedCapacity: Int = 0
    var maxCapacity: Int = 0
    var currentCapacity: Int = 0
    
    var amperage: Int = 0
    var powerBusAmperage: Int = 0
    var voltage: Double = 0
    var temperature: Double = 0
    
    var ACwatts: Int = 0
    var adapterMaxCurrent: Int = 0
    var adapterMaxVoltage: Int = 0
    var adapterCurrent: Int = 0
    var adapterVoltage: Int = 0
    var adapterPower: Double = 0
    var chargingCurrent: Int = 0
    var chargingVoltage: Int = 0
    
    var systemPower: Double = 0
    
    var timeToEmpty: Int = 0
    var timeToCharge: Int = 0
    var timeOnACPower: Date? = nil

    public static func == (lhs: Battery_Usage, rhs: Battery_Usage) -> Bool {
        return lhs.powerSource == rhs.powerSource &&
            lhs.state == rhs.state &&
            lhs.isCharged == rhs.isCharged &&
            lhs.isCharging == rhs.isCharging &&
            lhs.isBatteryPowered == rhs.isBatteryPowered &&
            lhs.optimizedChargingEngaged == rhs.optimizedChargingEngaged &&
            lhs.level == rhs.level &&
            lhs.cycles == rhs.cycles &&
            lhs.health == rhs.health &&
            lhs.maxCapacity == rhs.maxCapacity &&
            abs(lhs.amperage - rhs.amperage) < 10 &&
            abs(lhs.voltage - rhs.voltage) < 0.05 &&
            abs(lhs.temperature - rhs.temperature) < 0.2 &&
            lhs.ACwatts == rhs.ACwatts &&
            abs(lhs.systemPower - rhs.systemPower) < 0.1 &&
            lhs.timeToEmpty == rhs.timeToEmpty &&
            lhs.timeToCharge == rhs.timeToCharge
    }
}

public class Battery: Module {
    private let popupView: Popup
    private let settingsView: Settings
    private let portalView: Portal
    private let notificationsView: Notifications
    
    private var usageReader: UsageReader? = nil
    private var processReader: ProcessReader? = nil
    
    private var selectedMiniSensor: String {
        Store.shared.string(key: "Battery_mini_sensor", defaultValue: "Level")
    }
    private var selectedStackSensor: String {
        Store.shared.string(key: "Battery_stack_sensor", defaultValue: "Level/Time")
    }
    
    private var lowLevelNotificationState: Bool = false
    private var highLevelNotificationState: Bool = false
    private var notificationID: String? = nil
    
    public init() {
        self.settingsView = Settings(.battery)
        self.popupView = Popup(.battery)
        self.portalView = Portal(.battery)
        self.notificationsView = Notifications(.battery)
        
        super.init(
            moduleType: .battery,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView
        )
        guard self.available else { return }
        
        self.usageReader = UsageReader(.battery) { [weak self] value in
            self?.usageCallback(value)
        }
        self.processReader = ProcessReader(.battery) { [weak self] value in
            if let list = value {
                self?.popupView.processCallback(list)
            }
        }
        
        let usageReader = self.usageReader
        self.settingsView.callback = {
            Task {
                usageReader?.read()
            }
        }
        let processReader = self.processReader
        self.settingsView.callbackWhenUpdateNumberOfProcesses = { [weak self] in
            self?.popupView.numberOfProcessesUpdated()
            Task {
                processReader?.read()
            }
        }
        
        self.setReaders([self.usageReader, self.processReader])
    }
    
    public override func willTerminate() {
        guard self.isAvailable() else { return }
        self.notificationsView.willTerminate()
    }
    
    public override func isAvailable() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        return !sources.isEmpty
    }
    
    private func usageCallback(_ raw: Battery_Usage?) {
        guard let value = raw, self.enabled else { return }
        
        Task { @MainActor in
            self.popupView.usageCallback(value)
            self.portalView.loadCallback(value)
            self.notificationsView.usageCallback(value)
            
            self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
                switch w.item {
                case let widget as Mini:
                    var val = abs(value.level)
                    if self.selectedMiniSensor == "Power" {
                        val = abs(value.systemPower) / 50 // Normalized for visual
                    }
                    widget.setValue(val)
                    widget.setColorZones((0.15, 0.3))
                case let widget as StackWidget:
                    var list: [Stack_t] = []
                    if self.selectedStackSensor == "Level/Time" {
                        list.append(Stack_t(key: "level", value: "\(Int(value.level * 100))%", label: localizedString("Level")))
                        let time = value.timeToEmpty == 0 && value.timeToCharge != 0 ? value.timeToCharge : value.timeToEmpty
                        list.append(Stack_t(key: "time", value: Double(time).printSecondsToHoursMinutesSeconds(), label: localizedString("Time")))
                    } else if self.selectedStackSensor == "Power/Voltage" {
                        list.append(Stack_t(key: "power", value: "\(abs(value.systemPower).formatted())W", label: localizedString("Power")))
                        list.append(Stack_t(key: "voltage", value: "\(value.voltage.formatted())V", label: localizedString("Voltage")))
                    }
                    widget.setValues(list)
                case let widget as BarChart:
                    widget.setValue([[ColorValue(value.level)]])
                    widget.setColorZones((0.15, 0.3))
                case let widget as BatteryWidget:
                    widget.setValue(
                        percentage: value.level,
                        ACStatus: !value.isBatteryPowered,
                        isCharging: value.isCharging,
                        optimizedCharging: value.optimizedChargingEngaged,
                        time: value.timeToEmpty == 0 && value.timeToCharge != 0 ? value.timeToCharge : value.timeToEmpty
                    )
                case let widget as BatteryDetailsWidget:
                    widget.setValue(
                        percentage: value.level,
                        time: value.timeToEmpty == 0 && value.timeToCharge != 0 ? value.timeToCharge : value.timeToEmpty
                    )
                default: break
                }
            }
        }
    }
}
