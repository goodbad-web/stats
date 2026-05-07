//
//  settings.swift
//  CPU
//
//  Created by Serhiy Mytrovtsiy on 18/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit
import SwiftUI

struct CPUSettingsView: View {
    @AppStorage("CPU_updateInterval") private var updateInterval: Int = 1
    @AppStorage("CPU_updateTopInterval") private var updateTopInterval: Int = 1
    @AppStorage("CPU_processes") private var numberOfProcesses: Int = 8
    @AppStorage("CPU_usagePerCore") private var usagePerCore: Bool = false
    @AppStorage("CPU_clustersGroup") private var clustersGroup: Bool = false
    @AppStorage("CPU_splitValue") private var splitValue: Bool = false
    
    @AppStorage("CPU_mini_sensor") private var selectedMiniSensor: String = "Total"
    @AppStorage("CPU_stack_sensor") private var selectedStackSensor: String = "Total/Free"
    
    @State private var hasBarChart: Bool = false
    @State var widgets: [widget_t] = []
    
    var callback: () -> Void = {}
    var callbackWhenUpdateNumberOfProcesses: () -> Void = {}
    var setInterval: (Int) -> Void = { _ in }
    var setTopInterval: (Int) -> Void = { _ in }
    
    var body: some View {
        Form {
            Section {
                Picker(localizedString("Update interval"), selection: $updateInterval) {
                    ForEach(ReaderUpdateIntervals, id: \.key) {
                        Text(localizedString($0.value)).tag(Int($0.key) ?? 1)
                    }
                }
                Picker(localizedString("Update interval for top processes"), selection: $updateTopInterval) {
                    ForEach(ReaderUpdateIntervals, id: \.key) {
                        Text(localizedString($0.value)).tag(Int($0.key) ?? 1)
                    }
                }
            }
            
            Section {
                Picker(localizedString("Number of top processes"), selection: $numberOfProcesses) {
                    ForEach(NumbersOfProcesses, id: \.self) {
                        Text("\($0)").tag($0)
                    }
                }
            }
            
            Section {
                if widgets.contains(where: { $0 == .mini }) {
                    Picker("\(localizedString("Mini")): \(localizedString("Sensor to show"))", selection: $selectedMiniSensor) {
                        ForEach(["Total", "System", "User"], id: \.self) {
                            Text(localizedString($0)).tag($0)
                        }
                    }
                    .onChange(of: selectedMiniSensor) { _, _ in callback() }
                }
                
                if widgets.contains(where: { $0 == .stack }) {
                    Picker("\(localizedString("Stack")): \(localizedString("Sensor to show"))", selection: $selectedStackSensor) {
                        ForEach(["Total/Free", "System/User"], id: \.self) {
                            Text(localizedString($0)).tag($0)
                        }
                    }
                    .onChange(of: selectedStackSensor) { _, _ in callback() }
                }
            }
            
            if hasBarChart {
                Section {
                    Toggle(localizedString("Show usage per core"), isOn: $usagePerCore)
                        .onChange(of: usagePerCore) { _, newValue in
                            if newValue && clustersGroup {
                                clustersGroup = false
                            }
                            if newValue {
                                splitValue = false
                            }
                            callback()
                        }
                    
                    Toggle(localizedString("Cluster grouping"), isOn: $clustersGroup)
                        .onChange(of: clustersGroup) { _, newValue in
                            if newValue && usagePerCore {
                                usagePerCore = false
                            }
                            if newValue {
                                splitValue = false
                            }
                            callback()
                        }
                    
                    Toggle(localizedString("Split the value (System/User)"), isOn: $splitValue)
                        .disabled(usagePerCore || clustersGroup)
                        .onChange(of: splitValue) { _, _ in
                            callback()
                        }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: updateInterval) { _, newValue in setInterval(newValue) }
        .onChange(of: updateTopInterval) { _, newValue in setTopInterval(newValue) }
        .onChange(of: numberOfProcesses) { _, _ in callbackWhenUpdateNumberOfProcesses() }
    }
    
    func setHasBarChart(_ value: Bool) {
        self.hasBarChart = value
    }
}

class Settings: NSHostingView<CPUSettingsView>, Settings_v {
    var callback: (() -> Void) = {}
    var callbackWhenUpdateNumberOfProcesses: (() -> Void) = {}
    var setInterval: ((_ value: Int) -> Void) = {_ in }
    var setTopInterval: ((_ value: Int) -> Void) = {_ in }
    
    public init(_ module: ModuleType) {
        super.init(rootView: CPUSettingsView())
        self.rootView.callback = { [weak self] in self?.callback() }
        self.rootView.callbackWhenUpdateNumberOfProcesses = { [weak self] in self?.callbackWhenUpdateNumberOfProcesses() }
        self.rootView.setInterval = { [weak self] in self?.setInterval($0) }
        self.rootView.setTopInterval = { [weak self] in self?.setTopInterval($0) }
    }
    
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @MainActor required init(rootView: CPUSettingsView) {
        fatalError("init(rootView:) has not been implemented")
    }
    
    func load(widgets: [widget_t]) {
        self.rootView.widgets = widgets
        self.rootView.setHasBarChart(!widgets.filter({ $0 == .barChart }).isEmpty)
    }
}
