//
//  main.swift
//  Sensors
//
//  Created by Serhiy Mytrovtsiy on 17/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

public class Sensors: Module {
    private static let defaultMiniSensor = "Average CPU"
    private static let miniSensorFallbacks = [
        "Average CPU",
        "Hottest CPU",
        "Average System Total",
        "CPU Power",
        "GPU Power",
        "Average SOC",
        "Hottest SOC",
        "Fastest fan"
    ]
    private static let stackSensorFallbacks = [
        "Average CPU",
        "Hottest CPU",
        "Average SOC",
        "Hottest SOC",
        "CPU Power",
        "GPU Power",
        "Fastest fan"
    ]

    private var sensorsReader: SensorsReader?
    private let popupView: Popup
    private let settingsView: Settings
    private let portalView: Portal
    private let notificationsView: Notifications
    private var sensorViewKeys: Set<String> = []
    private var notificationSensorKeys: Set<String> = []

    private var fanValueState: FanValue {
        FanValue(rawValue: Store.shared.string(key: "\(self.config.name)_fanValue", defaultValue: "percentage")) ?? .percentage
    }

    private var selectedStackLine1: String {
        Store.shared.string(key: "Sensors_stack_line1", defaultValue: "Average CPU")
    }
    private var selectedStackLine2: String {
        Store.shared.string(key: "Sensors_stack_line2", defaultValue: "Hottest CPU")
    }
    private var selectedBarChartSensors: [String] {
        Store.shared.string(key: "Sensors_barChart_sensors", defaultValue: "Fans,Temperature")
            .split(separator: ",")
            .map { String($0) == "Temp" ? SensorType.temperature.rawValue : String($0) }
    }
    private var selectedSensor: String

    public init() {
        self.settingsView = Settings(.sensors)
        self.popupView = Popup()
        self.portalView = Portal(.sensors)
        self.notificationsView = Notifications(.sensors)
        self.selectedSensor = Store.shared.string(key: "\(ModuleType.sensors.stringValue)_sensor", defaultValue: Self.defaultMiniSensor)

        super.init(
            moduleType: .sensors,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView
        )
        guard self.available else { return }

        self.sensorsReader = SensorsReader { [weak self] value in
            self?.usageCallback(value)
        }

        self.setupSensorDependentViews(self.sensorsReader?.list.sensors)

        self.settingsView.callback = { [weak self] in
            self?.sensorsReader?.setReadScope(.full)
            self?.sensorsReader?.read()
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.sensorsReader?.setUserInterval(value)
        }
        self.settingsView.HIDcallback = { [weak self] in
            Task { @MainActor in
                self?.sensorsReader?.HIDCallback()
                self?.setupSensorDependentViews(self?.sensorsReader?.list.sensors, force: true)
            }
        }
        self.settingsView.unknownCallback = { [weak self] in
            Task { @MainActor in
                self?.sensorsReader?.unknownCallback()
                self?.setupSensorDependentViews(self?.sensorsReader?.list.sensors, force: true)
            }
        }
        self.selectedSensor = Store.shared.string(key: "\(ModuleType.sensors.stringValue)_sensor", defaultValue: self.selectedSensor)
        self.settingsView.selectedHandler = { [weak self] value in
            self?.selectedSensor = value
            Store.shared.set(key: "\(ModuleType.sensors.stringValue)_sensor", value: value)
            self?.updateReaderActivityModes()
            self?.sensorsReader?.read()
        }
        self.notificationsView.notificationChangeCallback = { [weak self] id, threshold in
            guard let self else { return }
            if threshold.isEmpty {
                self.notificationSensorKeys.remove(id)
            } else {
                self.notificationSensorKeys.insert(id)
            }
            self.updateReaderActivityModes()
            self.sensorsReader?.read()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(self.fanControlOverrideCallback), name: .fanControlOverride, object: nil)

        self.setReaders([self.sensorsReader])

        if let reader = self.sensorsReader {
            self.usageCallback(reader.list)
        }
    }

    public override func updateReaderActivityModes() {
        let activeWidgets = self.menuBar.widgets.filter { $0.isActive }
        self.sensorsReader?.setReadScope(self.sensorsReadScope(for: activeWidgets))
        self.sensorsReader?.setActivityMode(self.sensorsActivityMode(for: activeWidgets))
    }

    public override func willTerminate() {
        guard SMCHelper.shared.isActive(), let reader = self.sensorsReader else { return }

        reader.list.sensors.filter({ $0 is Fan }).forEach { (s: Sensor_p) in
            if let f = s as? Fan, let mode = f.customMode {
                if !mode.isAutomatic {
                    Task {
                        await SMCHelper.shared.setFanMode(f.id, mode: FanMode.automatic.rawValue)
                    }
                }
            }
        }
    }

    @objc private func fanControlOverrideCallback(_ notification: Notification) {
        guard let reason = notification.userInfo?["reason"] as? String else { return }
        let title = localizedString("Fan control override")
        var subtitle = ""

        if reason == "high_temp" {
            subtitle = localizedString("Fans set to Auto due to high temperature")
        } else if reason == "battery" {
            subtitle = localizedString("Fans set to Auto on battery power")
        }

        self.notificationsView.newNotification(id: "fan_override", title: title, subtitle: subtitle)
    }

    private func usageCallback(_ raw: Sensors_List?) {
        guard let value = raw else { return }
        self.setupSensorDependentViews(value.sensors)
        guard self.enabled else { return }

        self.popupView.usageCallback(value.sensors)
        self.portalView.usageCallback(value.sensors)
        self.notificationsView.usageCallback(value.sensors)

        let activeWidgets = self.menuBar.widgets.filter{ $0.isActive }
        self.sensorsReader?.setReadScope(self.sensorsReadScope(for: activeWidgets))
        self.sensorsReader?.setActivityMode(self.sensorsActivityMode(for: activeWidgets))

        activeWidgets.forEach { (w: SWidget) in
            switch w.item {
            case let widget as Mini:
                if let active = self.miniSensor(from: value.sensors) {
                    var value: Double = active.localValue/100
                    var unit: String = active.miniUnit
                    if let fan = active as? Fan, self.fanValueState == .percentage {
                        value = Double(fan.percentage)/100
                        unit = "%"
                    }
                    if value > 999 {
                        unit = ""
                    }
                    widget.setValue(value)
                    widget.setSuffix(unit)
                }
            case let widget as StackWidget:
                widget.setValues(self.stackSensors(from: value.sensors).map { self.getStackItem($0) })
            case let widget as BarChart:
                var flatList: [[ColorValue]] = []
                let selected = self.selectedBarChartSensors

                value.sensors.forEach { (s: Sensor_p) in
                    if s.state && (selected.contains(s.type.rawValue) || selected.contains(s.key)) {
                        if let f = s as? Fan {
                            flatList.append([ColorValue(((f.value*100)/f.maxSpeed)/100)])
                        } else {
                            var val = s.value / 100
                            if s.type == .voltage {
                                val = s.value / 20
                            } else if s.type == .power {
                                val = s.value / 150
                            }
                            flatList.append([ColorValue(val)])
                        }
                    }
                }
                widget.setValue(flatList)
            default: break
            }
        }
    }

    private func sensorsActivityMode(for activeWidgets: [SWidget]) -> SensorsReader.ActivityMode {
        let hasValueWidget = activeWidgets.contains { !($0.item is Label) }
        if hasValueWidget {
            return .active
        }

        let fanSafetyState = Store.shared.bool(key: "Sensors_fanSafety", defaultValue: true)
        let batteryAutoState = Store.shared.bool(key: "Sensors_fanBatteryAuto", defaultValue: false)
        return fanSafetyState || batteryAutoState ? .passive : .paused
    }

    private func sensorsReadScope(for activeWidgets: [SWidget]) -> SensorsReadScope {
        if self.isPopupVisible || self.isSettingsWindowVisible {
            return .full
        }

        var scope = SensorsReadScope()

        activeWidgets.forEach { widget in
            switch widget.item {
            case is Mini:
                scope.include(key: self.selectedSensor)
                Self.miniSensorFallbacks.forEach { scope.include(key: $0) }
            case is StackWidget:
                scope.include(key: self.selectedStackLine1)
                scope.include(key: self.selectedStackLine2)
                Self.stackSensorFallbacks.forEach { scope.include(key: $0) }
            case is BarChart:
                self.selectedBarChartSensors.forEach { value in
                    if let type = SensorType(rawValue: value) {
                        scope.include(type: type)
                    } else {
                        scope.include(key: value)
                    }
                }
            case is Label:
                break
            default:
                return
            }
        }

        if Store.shared.bool(key: "Sensors_fanSafety", defaultValue: true) {
            scope.include(type: .temperature, includeHID: false)
            scope.include(type: .fan)
            scope.needsFanMode = true
        }
        if Store.shared.bool(key: "Sensors_fanBatteryAuto", defaultValue: false) {
            scope.include(type: .fan)
            scope.needsFanMode = true
        }

        self.notificationSensorKeys.forEach { scope.include(key: $0) }

        return scope
    }

    private func miniSensor(from sensors: [Sensor_p]) -> Sensor_p? {
        if let selected = sensors.first(where: { $0.key == self.selectedSensor }) {
            return selected
        }

        for key in Self.miniSensorFallbacks {
            if let sensor = sensors.first(where: { $0.key == key }) {
                return sensor
            }
        }

        return sensors.first(where: { $0.type == .temperature }) ??
            sensors.first(where: { $0.type == .power }) ??
            sensors.first(where: { $0.type == .fan })
    }

    private func stackSensors(from sensors: [Sensor_p]) -> [Sensor_p] {
        var list: [Sensor_p] = []
        self.appendSensor(self.selectedStackLine1, from: sensors, to: &list)
        self.appendSensor(self.selectedStackLine2, from: sensors, to: &list)

        for key in Self.stackSensorFallbacks where list.count < 2 {
            self.appendSensor(key, from: sensors, to: &list)
        }

        if list.count == 2 {
            return list
        }

        for type in [SensorType.temperature, .power, .fan] where list.count < 2 {
            if let sensor = sensors.first(where: { candidate in
                candidate.type == type && !list.contains(where: { $0.key == candidate.key })
            }) {
                list.append(sensor)
            }
        }
        return list
    }

    private func appendSensor(_ key: String, from sensors: [Sensor_p], to list: inout [Sensor_p]) {
        guard !key.isEmpty, !list.contains(where: { $0.key == key }) else { return }
        if let sensor = sensors.first(where: { $0.key == key }) {
            list.append(sensor)
        }
    }

    private func setupSensorDependentViews(_ sensors: [Sensor_p]?, force: Bool = false) {
        guard let sensors, !sensors.isEmpty else { return }

        let keys = Set(sensors.map(\.key))
        guard force || keys != self.sensorViewKeys else { return }

        self.settingsView.setList(sensors)
        self.popupView.setup(sensors)
        self.portalView.setup(sensors)
        self.notificationsView.setup(sensors)
        self.sensorViewKeys = keys
        self.updateNotificationSensorKeys(sensors)
    }

    private func updateNotificationSensorKeys(_ sensors: [Sensor_p]) {
        self.notificationSensorKeys = Set(sensors.filter { !$0.notificationThreshold.isEmpty }.map(\.key))
    }

    private func getStackItem(_ s: Sensor_p) -> Stack_t {
        var value = s.formattedMiniValue
        if let f = s as? Fan {
            if self.fanValueState == .percentage {
                value = "\(f.percentage)%"
            }
        }
        return Stack_t(key: s.key, value: value, label: localizedString(s.name))
    }
}
