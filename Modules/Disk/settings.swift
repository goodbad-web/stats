//
//  settings.swift
//  Disk
//
//  Created by Serhiy Mytrovtsiy on 12/05/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit
import SwiftUI

var textWidgetHelp = """
<h2>Description</h2>
You can use a combination of any of the variables.
<h3>Examples:</h3>
<ul>
<li>$capacity.free/$capacity.total</li>
<li>Free: $capacity.free ($percentage.used)</li>
<li>Used: $capacity.used ($percentage.used)</li>
</ul>
<h2>Available variables</h2>
<ul>
<li><b>$capacity.free</b>: <small>Free space of active drive.</small></li>
<li><b>$capacity.used</b>: <small>Used space of active drive.</small></li>
<li><b>$capacity.total</b>: <small>Total space of active drive.</small></li>
<li><b>$percentage.free</b>: <small>Free space (percentage) of active drive.</small></li>
<li><b>$percentage.used</b>: <small>Used space (percentage) of active drive.</small></li>
</ul>
"""

struct DiskSettingsView: View {
    @AppStorage("Disk_updateInterval") private var updateInterval = 10
    @AppStorage("Disk_processes") private var numberOfProcesses = 5
    @AppStorage("Disk_disk") private var selectedDisk = ""
    @AppStorage("Disk_removable") private var removableDisks = false
    @AppStorage("Disk_base") private var base = "byte"
    @AppStorage("Disk_SMART") private var smartData = true
    @AppStorage("Disk_textWidgetValue") private var textValue = "$capacity.free/$capacity.total"
    
    var disks: [String]
    var widgets: [widget_t]
    
    var onUpdateIntervalChange: (Int) -> Void
    var onNumberOfProcessesChange: () -> Void
    var onSelectedDiskChange: (String) -> Void
    var onRemovableDisksChange: () -> Void
    var onSMARTDataChange: () -> Void
    
    var body: some View {
        Form {
            Section {
                Picker(localizedString("Update interval"), selection: $updateInterval) {
                    ForEach(ReaderUpdateIntervals, id: \.key) { item in
                        Text(localizedString(item.value)).tag(Int(item.key) ?? 10)
                    }
                }
                .onChange(of: updateInterval) { newValue in
                    onUpdateIntervalChange(newValue)
                }
                
                Picker(localizedString("Number of top processes"), selection: $numberOfProcesses) {
                    ForEach(NumbersOfProcesses, id: \.self) { num in
                        Text("\(num)").tag(num)
                    }
                }
                .onChange(of: numberOfProcesses) { _ in
                    onNumberOfProcessesChange()
                }
            }
            
            Section {
                Picker(localizedString("Disk to show"), selection: $selectedDisk) {
                    ForEach(disks, id: \.self) { disk in
                        Text(disk).tag(disk)
                    }
                }
                .onChange(of: selectedDisk) { newValue in
                    onSelectedDiskChange(newValue)
                }
                
                Toggle(localizedString("Show removable disks"), isOn: $removableDisks)
                    .onChange(of: removableDisks) { _ in
                        onRemovableDisksChange()
                    }
            }
            
            if widgets.contains(.speed) {
                Section {
                    Picker(localizedString("Base"), selection: $base) {
                        ForEach(SpeedBase, id: \.key) { item in
                            Text(localizedString(item.value)).tag(item.key)
                        }
                    }
                }
            }
            
            Section {
                Toggle(localizedString("SMART data"), isOn: $smartData)
                    .onChange(of: smartData) { _ in
                        onSMARTDataChange()
                    }
            }
            
            if widgets.contains(.text) {
                Section(localizedString("Text widget value")) {
                    TextField("", text: $textValue)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

internal class Settings: NSHostingView<DiskSettingsView>, Settings_v {
    public var selectedDiskHandler: (String) -> Void = {_ in }
    public var callback: (() -> Void) = {}
    public var setInterval: ((_ value: Int) -> Void) = {_ in }
    public var callbackWhenUpdateNumberOfProcesses: (() -> Void) = {}
    
    private var disks: [String] = []
    private var widgets: [widget_t] = []
    
    public init(_ module: ModuleType) {
        super.init(rootView: DiskSettingsView(
            disks: [],
            widgets: [],
            onUpdateIntervalChange: { _ in },
            onNumberOfProcessesChange: {},
            onSelectedDiskChange: { _ in },
            onRemovableDisksChange: {},
            onSMARTDataChange: {}
        ))
    }
    
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    required public init(rootView: DiskSettingsView) {
        super.init(rootView: rootView)
    }
    
    public func load(widgets: [widget_t]) {
        self.widgets = widgets
        self.updateView()
    }
    
    internal func setList(_ list: Disks) {
        self.disks = list.map{ $0.mediaName }
        self.updateView()
    }
    
    private func updateView() {
        self.rootView = DiskSettingsView(
            disks: self.disks,
            widgets: self.widgets,
            onUpdateIntervalChange: { [weak self] val in self?.setInterval(val) },
            onNumberOfProcessesChange: { [weak self] in self?.callbackWhenUpdateNumberOfProcesses() },
            onSelectedDiskChange: { [weak self] val in self?.selectedDiskHandler(val) },
            onRemovableDisksChange: { [weak self] in self?.callback() },
            onSMARTDataChange: { [weak self] in self?.callback() }
        )
    }
}
