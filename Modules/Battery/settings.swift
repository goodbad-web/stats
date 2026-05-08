//
//  settings.swift
//  Battery
//
//  Created by Serhiy Mytrovtsiy on 15/07/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit
import SystemConfiguration
import SwiftUI

internal class Settings: NSStackView, Settings_v {
    public var callback: (() -> Void) = {}
    public var callbackWhenUpdateNumberOfProcesses: (() -> Void) = {}
    
    private let title: String
    private var hostingView: NSHostingView<BatterySettingsView>?
    
    public init(_ module: ModuleType) {
        self.title = module.stringValue
        super.init(frame: NSRect.zero)
        self.orientation = .vertical
        self.spacing = 0
        
        let settingsView = BatterySettingsView(
            title: self.title,
            onNumberOfProcessesChange: { [weak self] in
                self?.callbackWhenUpdateNumberOfProcesses()
            },
            onTimeFormatChange: { [weak self] in
                self?.callback()
            },
            callback: { [weak self] in
                self?.callback()
            }
        )
        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        self.addArrangedSubview(hostingView)
        self.hostingView = hostingView
        
        NSLayoutConstraint.activate([
            hostingView.widthAnchor.constraint(equalTo: self.widthAnchor),
            hostingView.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func load(widgets: [widget_t]) {
        self.hostingView?.rootView.widgets = widgets
    }
}

struct BatterySettingsView: View {
    let title: String
    @AppStorage(AppSettingsKeys.moduleInt("Battery", "processes", defaultValue: 8).rawValue) private var numberOfProcesses: Int = 8
    @AppStorage(AppSettingsKeys.moduleString("Battery", "timeFormat", defaultValue: "short").rawValue) private var timeFormat: String = "short"
    
    @AppStorage(AppSettingsKeys.moduleString("Battery", "mini_sensor", defaultValue: "Level").rawValue) private var selectedMiniSensor: String = "Level"
    @AppStorage(AppSettingsKeys.moduleString("Battery", "stack_sensor", defaultValue: "Level/Time").rawValue) private var selectedStackSensor: String = "Level/Time"
    
    @State var widgets: [widget_t] = []
    
    var onNumberOfProcessesChange: () -> Void = {}
    var onTimeFormatChange: () -> Void = {}
    var callback: () -> Void = {}
    
    var body: some View {
        Form {
            Section {
                Picker(localizedString("Number of top processes"), selection: $numberOfProcesses) {
                    ForEach(NumbersOfProcesses, id: \.self) { num in
                        Text("\(num)").tag(num)
                    }
                }
                .onChange(of: numberOfProcesses) { _, _ in
                    onNumberOfProcessesChange()
                }
            }
            
            Section {
                if widgets.contains(where: { $0 == .mini }) {
                    Picker("\(localizedString("Mini")): \(localizedString("Sensor to show"))", selection: $selectedMiniSensor) {
                        ForEach(["Level", "Power"], id: \.self) {
                            Text(localizedString($0)).tag($0)
                        }
                    }
                    .onChange(of: selectedMiniSensor) { _, _ in callback() }
                }
                
                if widgets.contains(where: { $0 == .stack }) {
                    Picker("\(localizedString("Stack")): \(localizedString("Sensor to show"))", selection: $selectedStackSensor) {
                        ForEach(["Level/Time", "Power/Voltage"], id: \.self) {
                            Text(localizedString($0)).tag($0)
                        }
                    }
                    .onChange(of: selectedStackSensor) { _, _ in callback() }
                }
            }
            
            if widgets.contains(.battery) {
                Section {
                    Picker(localizedString("Time format"), selection: $timeFormat) {
                        ForEach(ShortLong, id: \.key) { item in
                            Text(localizedString(item.value)).tag(item.key)
                        }
                    }
                    .onChange(of: timeFormat) { _, _ in
                        onTimeFormatChange()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
