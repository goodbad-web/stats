//
//  settings.swift
//  Sensors
//
//  Created by Serhiy Mytrovtsiy on 23/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit
import SwiftUI

internal class Settings: NSStackView, Settings_v {
    public var callback: (() -> Void) = {}
    public var HIDcallback: (() -> Void) = {}
    public var unknownCallback: (() -> Void) = {}
    public var setInterval: ((_ value: Int) -> Void) = {_ in }
    public var selectedHandler: (String) -> Void = {_ in }
    
    private let title: String
    private var hostingView: NSHostingView<SensorsSettingsView>?
    
    public init(_ module: ModuleType) {
        self.title = module.stringValue
        super.init(frame: NSRect.zero)
        self.orientation = .vertical
        self.spacing = 0
        
        let sensorsSettingsView = SensorsSettingsView(
            title: self.title,
            onCallback: { [weak self] in self?.callback() },
            onHIDCallback: { [weak self] in self?.HIDcallback() },
            onUnknownCallback: { [weak self] in self?.unknownCallback() },
            onSetInterval: { [weak self] value in self?.setInterval(value) },
            onSelectedHandler: { [weak self] value in self?.selectedHandler(value) }
        )
        
        let hostingView = NSHostingView(rootView: sensorsSettingsView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        self.addArrangedSubview(hostingView)
        self.hostingView = hostingView
        
        NSLayoutConstraint.activate([
            hostingView.widthAnchor.constraint(equalTo: self.widthAnchor),
            hostingView.heightAnchor.constraint(greaterThanOrEqualToConstant: 400)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func load(widgets: [widget_t]) {
        self.hostingView?.rootView.widgets = widgets
    }
    
    public func setList(_ list: [Sensor_p]?) {
        guard let list else { return }
        self.hostingView?.rootView.allSensors = list
    }
}

struct SensorsSettingsView: View {
    let title: String
    
    @AppStorage("Sensors_updateInterval") private var updateInterval: Int = 3
    @AppStorage("Sensors_hid") private var hidState: Bool = isARM
    @AppStorage("Sensors_speed") private var fanSpeedState: Bool = false
    @AppStorage("Sensors_fansSync") private var fansSyncState: Bool = false
    @AppStorage("Sensors_unknown") private var unknownSensorsState: Bool = false
    @AppStorage("Sensors_fanValue") private var fanValueState: String = "percentage"
    @AppStorage("Sensors_sensor") private var selectedSensor: String = "Average System Total"
    @AppStorage("Sensors_fanSafety") private var fanSafetyState: Bool = true
    @AppStorage("Sensors_stack_line1") private var selectedStackLine1: String = ""
    @AppStorage("Sensors_stack_line2") private var selectedStackLine2: String = ""
    @AppStorage("Sensors_barChart_sensors") private var selectedBarChartSensors: String = "Fans,Temp"
    @AppStorage("Sensors_fanBatteryAuto") private var fanBatteryAutoState: Bool = false
    
    var allSensors: [Sensor_p] = []
    var widgets: [widget_t] = []
    
    var onCallback: () -> Void = {}
    var onHIDCallback: () -> Void = {}
    var onUnknownCallback: () -> Void = {}
    var onSetInterval: (Int) -> Void = { _ in }
    var onSelectedHandler: (String) -> Void = { _ in }
    
    var sensors: [Sensor_p] {
        if unknownSensorsState {
            return allSensors
        }
        return allSensors.filter { $0.group != .unknown }
    }
    
    private var groupedSensors: [SensorType: [Sensor_p]] {
        Dictionary(grouping: sensors, by: { $0.type })
    }
    
    private var sortedSensorTypes: [SensorType] {
        groupedSensors.keys.sorted { $0.rawValue < $1.rawValue }
    }
    
    private func isBarChartSensorSelected(_ key: String) -> Bool {
        selectedBarChartSensors.split(separator: ",").contains(String.SubSequence(key))
    }
    
    private func toggleBarChartSensor(_ key: String) {
        var keys = selectedBarChartSensors.split(separator: ",").map { String($0) }
        if let index = keys.firstIndex(of: key) {
            keys.remove(at: index)
        } else {
            keys.append(key)
        }
        selectedBarChartSensors = keys.joined(separator: ",")
        onCallback()
    }
    
    var body: some View {
        Form {
            Section {
                Picker(localizedString("Update interval"), selection: $updateInterval) {
                    ForEach(ReaderUpdateIntervals, id: \.key) { item in
                        Text(localizedString(item.value)).tag(Int(item.key) ?? 3)
                    }
                }
                .onChange(of: updateInterval) { _, newValue in
                    onSetInterval(newValue)
                }
            }
            
            Section {
                Picker(localizedString("Fan value"), selection: $fanValueState) {
                    ForEach(FanValues, id: \.key) { item in
                        Text(localizedString(item.value)).tag(item.key)
                    }
                }
                .onChange(of: fanValueState) { _, _ in
                    onCallback()
                }
                
                Toggle(localizedString("Save the fan speed"), isOn: $fanSpeedState)
                    .onChange(of: fanSpeedState) { _, _ in
                        onCallback()
                    }
                
                Toggle(localizedString("Synchronize fan's control"), isOn: $fansSyncState)
                
                Toggle(localizedString("Show unknown sensors"), isOn: $unknownSensorsState)
                    .onChange(of: unknownSensorsState) { _, _ in
                        onUnknownCallback()
                    }
                
                if isARM {
                    Toggle(localizedString("HID sensors"), isOn: $hidState)
                        .onChange(of: hidState) { _, _ in
                            onHIDCallback()
                        }
                }
                
                Section(header: Text(localizedString("Fan control"))) {
                    Toggle(localizedString("Safety override"), isOn: $fanSafetyState)
                        .onChange(of: fanSafetyState) { _, _ in
                            onCallback()
                        }
                    Toggle(localizedString("Auto mode on battery"), isOn: $fanBatteryAutoState)
                        .onChange(of: fanBatteryAutoState) { _, _ in
                            onCallback()
                        }
                }
                
                if widgets.contains(where: { $0 == .mini }) {
                    Picker("\(localizedString("Mini")): \(localizedString("Sensor to show"))", selection: $selectedSensor) {
                        ForEach(sortedSensorTypes, id: \.self) { type in
                            Section(header: Text(localizedString(type.rawValue))) {
                                ForEach(groupedSensors[type] ?? [], id: \.key) { s in
                                    Text(localizedString(s.name)).tag(s.key)
                                }
                            }
                        }
                    }
                    .onChange(of: selectedSensor) { _, newValue in
                        onSelectedHandler(newValue)
                    }
                }
                
                if widgets.contains(where: { $0 == .stack }) {
                    Section(header: Text(localizedString("Stack"))) {
                        Picker(localizedString("Line 1"), selection: $selectedStackLine1) {
                            Text(localizedString("None")).tag("")
                            ForEach(sortedSensorTypes, id: \.self) { type in
                                Section(header: Text(localizedString(type.rawValue))) {
                                    ForEach(groupedSensors[type] ?? [], id: \.key) { s in
                                        Text(localizedString(s.name)).tag(s.key)
                                    }
                                }
                            }
                        }
                        .onChange(of: selectedStackLine1) { _, _ in onCallback() }
                        
                        Picker(localizedString("Line 2"), selection: $selectedStackLine2) {
                            Text(localizedString("None")).tag("")
                            ForEach(sortedSensorTypes, id: \.self) { type in
                                Section(header: Text(localizedString(type.rawValue))) {
                                    ForEach(groupedSensors[type] ?? [], id: \.key) { s in
                                        Text(localizedString(s.name)).tag(s.key)
                                    }
                                }
                            }
                        }
                        .onChange(of: selectedStackLine2) { _, _ in onCallback() }
                    }
                }
                
                if widgets.contains(where: { $0 == .barChart }) {
                    BarChartSettings(
                        sortedSensorTypes: sortedSensorTypes,
                        groupedSensors: groupedSensors,
                        isBarChartSensorSelected: isBarChartSensorSelected,
                        toggleBarChartSensor: toggleBarChartSensor
                    )
                }
            }
            
            ForEach(sortedSensorTypes, id: \.self) { type in
                Section(header: Text(localizedString(type.rawValue))) {
                    ForEach(sensors.filter { $0.type == type }, id: \.key) { sensor in
                        SensorToggleRow(sensor: sensor, onCallback: onCallback)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct BarChartSettings: View {
    let sortedSensorTypes: [SensorType]
    let groupedSensors: [SensorType: [Sensor_p]]
    let isBarChartSensorSelected: (String) -> Bool
    let toggleBarChartSensor: (String) -> Void
    
    var body: some View {
        Section(header: Text(localizedString("Bar chart"))) {
            ForEach(sortedSensorTypes, id: \.self) { type in
                DisclosureGroup(localizedString(type.rawValue)) {
                    ForEach(groupedSensors[type] ?? [], id: \.key) { s in
                        Toggle(localizedString(s.name), isOn: Binding(
                            get: { isBarChartSensorSelected(s.key) },
                            set: { _ in toggleBarChartSensor(s.key) }
                        ))
                    }
                }
            }
        }
    }
}

struct SensorToggleRow: View {
    let sensor: Sensor_p
    let onCallback: () -> Void
    
    @State private var isOn: Bool
    
    init(sensor: Sensor_p, onCallback: @escaping () -> Void) {
        self.sensor = sensor
        self.onCallback = onCallback
        self._isOn = State(initialValue: sensor.state)
    }
    
    var body: some View {
        Toggle(localizedString(sensor.name), isOn: $isOn)
            .onChange(of: isOn) { _, newValue in
                Store.shared.set(key: "sensor_\(sensor.key)", value: newValue)
                onCallback()
            }
    }
}
