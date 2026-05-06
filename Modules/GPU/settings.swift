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
    @AppStorage("GPU_updateInterval") private var updateInterval = 1
    @AppStorage("GPU_gpu") private var selectedGPU = "automatic"
    
    var gpuList: [KeyValue_t]
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
                    .onChange(of: updateInterval) { newValue in
                        setInterval(newValue)
                    }
                }
                .padding(10)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(5)
            }
            
            Section {
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
                    .onChange(of: selectedGPU) { newValue in
                        selectedGPUHandler(newValue)
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
    
    public init(_ module: ModuleType) {
        super.init(rootView: GPUSettingsView(
            gpuList: [],
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
            gpuList: self.gpuList,
            setInterval: self.setInterval,
            selectedGPUHandler: self.selectedGPUHandler
        )
    }
}
