//
//  settings.swift
//  GPU
//
//  Created by Serhiy Mytrovtsiy on 17/08/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit
import SwiftUI

struct GPUSettingsView: View {
    @AppStorage(AppSettingsKeys.moduleInt("GPU", "updateInterval", defaultValue: 1).rawValue) private var updateInterval = 1
    @AppStorage(AppSettingsKeys.moduleString("GPU", "gpu", defaultValue: "automatic").rawValue) private var selectedGPU = "automatic"
    
    @AppStorage(AppSettingsKeys.moduleString("GPU", "mini_sensor", defaultValue: "Utilization").rawValue) private var selectedMiniSensor: String = "Utilization"
    @AppStorage(AppSettingsKeys.moduleString("GPU", "stack_sensor", defaultValue: "Utilization/Render").rawValue) private var selectedStackSensor: String = "Utilization/Render"
    
    @AppStorage(AppSettingsKeys.moduleInt("GPU", "processes", defaultValue: 5).rawValue) private var numberOfProcesses = 5
    
    var widgets: [widget_t]
    var gpuList: [KeyValue_t]
    var callback: () -> Void
    var setInterval: (Int) -> Void
    var selectedGPUHandler: (String) -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Section {
                HStack {
                    Text(localizedString("Update interval"))
                    Spacer()
                    Picker("", selection: $updateInterval) {
                        ForEach(ReaderUpdateIntervals, id: \.key) { item in
                            Text(item.value).tag(Int(item.key) ?? 1)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: updateInterval) { _, newValue in
                        setInterval(newValue)
                    }
                }
                .padding(10)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(5)
            }
            
            Section {
                VStack(spacing: 8) {
                    HStack {
                        Text(localizedString("GPU to show"))
                        Spacer()
                        Picker("", selection: $selectedGPU) {
                            ForEach(gpuList, id: \.key) { item in
                                if item.key == "separator" {
                                    Divider()
                                } else {
                                    Text(localizedString(item.value)).tag(item.key)
                                }
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: selectedGPU) { _, newValue in
                            selectedGPUHandler(newValue)
                        }
                    }
                    
                    HStack {
                        Text(localizedString("Mini") + ": " + localizedString("Sensor to show"))
                        Spacer()
                        Picker("", selection: $selectedMiniSensor) {
                            ForEach(["Utilization", "Render", "Tiler"], id: \.self) {
                                Text(localizedString($0)).tag($0)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: selectedMiniSensor) { _, _ in callback() }
                    }
                    .disabled(!widgets.contains(.mini))
                    
                    HStack {
                        Text(localizedString("Stack") + ": " + localizedString("Sensor to show"))
                        Spacer()
                        Picker("", selection: $selectedStackSensor) {
                            ForEach(["Utilization/Render", "Render/Tiler", "Utilization/ANE"], id: \.self) {
                                Text(localizedString($0)).tag($0)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: selectedStackSensor) { _, _ in callback() }
                    }
                    .disabled(!widgets.contains(.stack))
                    
                    HStack {
                        Text(localizedString("Number of top processes"))
                        Spacer()
                        Picker("", selection: $numberOfProcesses) {
                            ForEach([0, 3, 5, 8, 10, 15], id: \.self) { item in
                                Text("\(item)").tag(item)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: numberOfProcesses) { _, _ in
                            callback()
                        }
                    }
                }
                .padding(10)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(5)
            }
        }
        .padding()
    }
}

internal class Settings: NSHostingView<GPUSettingsView>, Settings_v {
    public var selectedGPUHandler: (String) -> Void = {_ in }
    public var callback: (() -> Void) = {}
    public var setInterval: ((_ value: Int) -> Void) = {_ in }
    
    private var gpuList: [KeyValue_t] = [
        KeyValue_t(key: "automatic", value: "Automatic"),
        KeyValue_t(key: "separator", value: "separator")
    ]
    private var widgets: [widget_t] = []
    
    public init(_ module: ModuleType) {
        super.init(rootView: GPUSettingsView(
            widgets: [],
            gpuList: [],
            callback: {},
            setInterval: { _ in },
            selectedGPUHandler: { _ in }
        ))
    }
    
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    required public init(rootView: GPUSettingsView) {
        super.init(rootView: rootView)
    }
    
    public func load(widgets: [widget_t]) {
        self.widgets = widgets
        self.updateView()
    }
    
    internal func setList(_ gpus: GPUs) {
        var list: [KeyValue_t] = [
            KeyValue_t(key: "automatic", value: "Automatic"),
            KeyValue_t(key: "separator", value: "separator")
        ]
        gpus.active().forEach{ list.append(KeyValue_t(key: $0.model, value: $0.model)) }
        self.gpuList = list
        self.updateView()
    }
    
    private func updateView() {
        self.rootView = GPUSettingsView(
            widgets: self.widgets,
            gpuList: self.gpuList,
            callback: self.callback,
            setInterval: self.setInterval,
            selectedGPUHandler: self.selectedGPUHandler
        )
    }
}
