//
//  settings.swift
//  Bluetooth
//
//  Created by Serhiy Mytrovtsiy on 07/07/2021.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2021 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit
import SwiftUI

struct BluetoothSettingsView: View {
    var devices: [BLEDevice]
    var onToggle: (String, Bool) -> Void
    
    var body: some View {
        Form {
            if devices.isEmpty {
                Text(localizedString("No Bluetooth devices are available"))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                Section {
                    ForEach(devices, id: \.id) { device in
                        Toggle(device.name, isOn: Binding(
                            get: { device.state },
                            set: { newValue in
                                onToggle(device.uuid?.uuidString ?? device.address, newValue)
                            }
                        ))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

internal class Settings: NSHostingView<BluetoothSettingsView>, Settings_v {
    public var callback: (() -> Void) = {}
    private var devices: [BLEDevice] = []
    
    public init() {
        super.init(rootView: BluetoothSettingsView(devices: [], onToggle: { _, _ in }))
    }
    
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    required public init(rootView: BluetoothSettingsView) {
        super.init(rootView: rootView)
    }
    
    internal func load(widgets: [widget_t]) {}
    
    internal func setList(_ list: [BLEDevice]) {
        self.devices = list
        self.updateView()
    }
    
    private func updateView() {
        self.rootView = BluetoothSettingsView(
            devices: self.devices,
            onToggle: { [weak self] id, value in
                UserDefaultsSettingsStore.shared.set(AppSettingsKeys.bool("ble_\(id)", defaultValue: false), value: value)
                self?.callback()
            }
        )
    }
}
