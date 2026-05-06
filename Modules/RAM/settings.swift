//
//  settings.swift
//  Memory
//
//  Created by Serhiy Mytrovtsiy on 11/07/2020.
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
<li>$mem.used/$mem.total ($pressure.value)</li>
<li>Pressure: $pressure.value</li>
<li>Free: $mem.free</li>
</ul>
<h2>Available variables</h2>
<ul>
<li><b>$mem.total</b>: <small>Total RAM memory.</small></li>
<li><b>$mem.used</b>: <small>Used RAM memory.</small></li>
<li><b>$mem.free</b>: <small>Free RAM memory.</small></li>
<li><b>$mem.active</b>: <small>Active RAM memory.</small></li>
<li><b>$mem.inactive</b>: <small>Inactive RAM memory.</small></li>
<li><b>$mem.wired</b>: <small>Wired RAM memory.</small></li>
<li><b>$mem.compressed</b>: <small>Compressed RAM memory.</small></li>
<li><b>$mem.app</b>: <small>Used RAM memory by applications.</small></li>
<li><b>$mem.cache</b>: <small>Cached RAM memory.</small></li>
<li><b>$mem.swapins</b>: <small>The number of memory pages loaded in from virtual memory to physical memory.</small></li>
<li><b>$mem.swapouts</b>: <small>The number of memory pages swapped out to physical memory from virtual memory.</small></li>
<li><b>$swap.total</b>: <small>Total swap memory.</small></li>
<li><b>$swap.used</b>: <small>Used swap memory.</small></li>
<li><b>$swap.free</b>: <small>Free swap memory.</small></li>
<li><b>$pressure.value</b>: <small>Pressure value (normal, warning, critical).</small></li>
<li><b>$pressure.level</b>: <small>Pressure level (1, 2, 4).</small></li>
</ul>
"""

struct RAMSettingsView: View {
    @AppStorage("RAM_updateInterval") private var updateInterval = 1
    @AppStorage("RAM_updateTopInterval") private var updateTopInterval = 1
    @AppStorage("RAM_processes") private var numberOfProcesses = 8
    @AppStorage("RAM_splitValue") private var splitValue = false
    @AppStorage("RAM_combinedProcesses") private var combinedProcesses = false
    @AppStorage("RAM_textWidgetValue") private var textWidgetValue = "$mem.used/$mem.total ($pressure.value)"
    
    var widgets: [widget_t]
    var callback: () -> Void
    var callbackWhenUpdateNumberOfProcesses: () -> Void
    var setInterval: (Int) -> Void
    var setTopInterval: (Int) -> Void
    
    private let textWidgetHelpPanel: HelpHUD = HelpHUD(textWidgetHelp)
    
    var body: some View {
        VStack(spacing: 16) {
            Section {
                VStack(spacing: 8) {
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
                    
                    HStack {
                        Text(localizedString("Update interval for top processes"))
                        Spacer()
                        Picker("", selection: $updateTopInterval) {
                            ForEach(ReaderUpdateIntervals, id: \.key) { item in
                                Text(item.value).tag(Int(item.key) ?? 1)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: updateTopInterval) { newValue in
                            setTopInterval(newValue)
                        }
                    }
                }
                .padding(10)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(5)
            }
            
            Section {
                VStack(spacing: 8) {
                    Toggle(localizedString("Combined processes"), isOn: $combinedProcesses)
                        .onChange(of: combinedProcesses) { _ in
                            callback()
                        }
                    
                    HStack {
                        Text(localizedString("Number of top processes"))
                        Spacer()
                        Picker("", selection: $numberOfProcesses) {
                            ForEach(NumbersOfProcesses, id: \.self) { val in
                                Text("\(val)").tag(val)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: numberOfProcesses) { _ in
                            callbackWhenUpdateNumberOfProcesses()
                        }
                    }
                }
                .padding(10)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(5)
            }
            
            if widgets.contains(.barChart) {
                Section {
                    Toggle(localizedString("Split the value (App/Wired/Compressed)"), isOn: $splitValue)
                        .onChange(of: splitValue) { _ in
                            callback()
                        }
                        .padding(10)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(5)
                }
            }
            
            if widgets.contains(.text) {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(localizedString("Text widget value"))
                            Spacer()
                            Button(action: { textWidgetHelpPanel.show() }) {
                                Image(systemName: "questionmark.circle")
                            }
                            .buttonStyle(.plain)
                        }
                        
                        TextField(localizedString("This will be visible in the text widget"), text: $textWidgetValue)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(10)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(5)
                }
            }
        }
        .padding()
    }
}

internal class Settings: NSHostingView<RAMSettingsView>, Settings_v {
    public var callback: (() -> Void) = {}
    public var callbackWhenUpdateNumberOfProcesses: (() -> Void) = {}
    public var setInterval: ((_ value: Int) -> Void) = {_ in }
    public var setTopInterval: ((_ value: Int) -> Void) = {_ in }
    
    private var widgets: [widget_t] = []
    
    public init(_ module: ModuleType) {
        super.init(rootView: RAMSettingsView(
            widgets: [],
            callback: {},
            callbackWhenUpdateNumberOfProcesses: {},
            setInterval: { _ in },
            setTopInterval: { _ in }
        ))
    }
    
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    required public init(rootView: RAMSettingsView) {
        super.init(rootView: rootView)
    }
    
    public func load(widgets: [widget_t]) {
        self.widgets = widgets
        self.rootView = RAMSettingsView(
            widgets: widgets,
            callback: self.callback,
            callbackWhenUpdateNumberOfProcesses: self.callbackWhenUpdateNumberOfProcesses,
            setInterval: self.setInterval,
            setTopInterval: self.setTopInterval
        )
    }
}
