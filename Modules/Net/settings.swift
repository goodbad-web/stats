//
//  settings.swift
//  Net
//
//  Created by Serhiy Mytrovtsiy on 06/07/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit
import SystemConfiguration
import SwiftUI

struct NetSettingsView: View {
    @AppStorage("Net_processes") private var numberOfProcesses: Int = 8
    @AppStorage("Net_reader") private var readerType: String = "interface"
    @AppStorage("Net_usageReset") private var usageReset: String = AppUpdateInterval.never.rawValue
    @AppStorage("Net_VPNMode") private var vpnMode: Bool = false
    @AppStorage("Net_widgetActivationThresholdState") private var widgetActivationThresholdState: Bool = false
    @AppStorage("Net_widgetActivationThreshold") private var widgetActivationThreshold: Int = 0
    @AppStorage("Net_widgetActivationThresholdSize") private var widgetActivationThresholdSize: String = SizeUnit.MB.key
    @AppStorage("Net_ICMPHost") private var connectivityICMPHost: String = "1.1.1.1"
    @AppStorage("Net_HTTPHost") private var connectivityHTTPHost: String = "https://google.com"
    @AppStorage("Net_updateICMPInterval") private var updateConnectivityInterval: Int = 1
    @AppStorage("Net_connectivityMode") private var connectivityMode: String = "icmp"
    @AppStorage("Net_publicIP") private var publicIPState: Bool = true
    @AppStorage("Net_publicIPRefreshInterval") private var publicIPRefreshInterval: String = "never"
    @AppStorage("Net_base") private var base: String = "byte"
    @AppStorage("Net_textWidgetValue") private var textValue: String = "$addr.public - $status"
    @AppStorage("Net_interface") private var selectedInterface: String = ""
    
    @AppStorage("Net_mini_sensor") private var selectedMiniSensor: String = "Download speed"
    @AppStorage("Net_stack_sensor") private var selectedStackSensor: String = "Speed"
    
    @State var widgets: [widget_t] = []
    @State private var interfaces: [Network_interface] = []
    
    var callback: () -> Void = {}
    var usageResetCallback: () -> Void = {}
    var connectivityHostCallback: (Bool) -> Void = { _ in }
    var setInterval: (Int) -> Void = { _ in }
    var publicIPRefreshIntervalCallback: () -> Void = {}
    
    var body: some View {
        Form {
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
                        ForEach(["Download speed", "Upload speed"], id: \.self) {
                            Text(localizedString($0)).tag($0)
                        }
                    }
                    .onChange(of: selectedMiniSensor) { _, _ in callback() }
                }
                
                if widgets.contains(where: { $0 == .stack }) {
                    Picker("\(localizedString("Stack")): \(localizedString("Sensor to show"))", selection: $selectedStackSensor) {
                        ForEach(["Speed", "IP"], id: \.self) {
                            Text(localizedString($0)).tag($0)
                        }
                    }
                    .onChange(of: selectedStackSensor) { _, _ in callback() }
                }
            }
            
            Section {
                Picker(localizedString("Reader type"), selection: $readerType) {
                    ForEach(NetworkReaders, id: \.key) {
                        Text(localizedString($0.value)).tag($0.key)
                    }
                }
                
                if readerType == "interface" {
                    Picker(localizedString("Network interface"), selection: $selectedInterface) {
                        Text(localizedString("Autodetection")).tag("")
                        Divider()
                        ForEach(interfaces, id: \.BSDName) {
                            Text("\($0.displayName) (\($0.BSDName))").tag($0.BSDName)
                        }
                    }
                }
                
                Picker(localizedString("Base"), selection: $base) {
                    ForEach(SpeedBase, id: \.key) {
                        Text(localizedString($0.value)).tag($0.key)
                    }
                }
                
                Picker(localizedString("Reset data usage"), selection: $usageReset) {
                    ForEach(AppUpdateIntervals.filter({ $0.key != "Silent" }), id: \.key) {
                        Text(localizedString($0.value)).tag($0.key)
                    }
                }
                
                Toggle(localizedString("Public IP"), isOn: $publicIPState)
                
                if publicIPState {
                    Picker(localizedString("Auto-refresh public IP address"), selection: $publicIPRefreshInterval) {
                        ForEach(PublicIPAddressRefreshIntervals, id: \.key) {
                            Text(localizedString($0.value)).tag($0.key)
                        }
                    }
                }
                
                if hasVPN() {
                    Toggle(localizedString("VPN mode"), isOn: $vpnMode)
                }
            }
            
            Section {
                Toggle(localizedString("Widget activation threshold"), isOn: $widgetActivationThresholdState)
                if widgetActivationThresholdState {
                    HStack {
                        TextField("", value: $widgetActivationThreshold, formatter: NumberFormatter())
                            .frame(width: 50)
                        Picker("", selection: $widgetActivationThresholdSize) {
                            ForEach(SizeUnit.allCases, id: \.key) {
                                Text($0.key).tag($0.key)
                            }
                        }
                    }
                }
            }
            
            Section(localizedString("Connectivity")) {
                Picker(localizedString("Reader type"), selection: $connectivityMode) {
                    Text("ICMP").tag("icmp")
                    Text("HTTP").tag("http")
                }
                
                TextField(localizedString("Connectivity host"), text: connectivityMode == "icmp" ? $connectivityICMPHost : $connectivityHTTPHost)
                
                Picker(localizedString("Update interval"), selection: $updateConnectivityInterval) {
                    ForEach(ReaderUpdateIntervals, id: \.key) {
                        Text(localizedString($0.value)).tag(Int($0.key) ?? 1)
                    }
                }
            }
            
            Section(localizedString("Text widget value")) {
                TextField("", text: $textValue)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadInterfaces()
        }
        .onChange(of: numberOfProcesses) { _, _ in callback() }
        .onChange(of: readerType) { _, _ in callback() }
        .onChange(of: selectedInterface) { _, _ in callback() }
        .onChange(of: base) { _, _ in callback() }
        .onChange(of: usageReset) { _, _ in usageResetCallback() }
        .onChange(of: connectivityICMPHost) { _, newValue in connectivityHostCallback(newValue.isEmpty) }
        .onChange(of: connectivityHTTPHost) { _, newValue in connectivityHostCallback(newValue.isEmpty) }
        .onChange(of: updateConnectivityInterval) { _, newValue in setInterval(newValue) }
        .onChange(of: publicIPRefreshInterval) { _, _ in publicIPRefreshIntervalCallback() }
    }
    
    private func loadInterfaces() {
        var list: [Network_interface] = []
        for interface in SCNetworkInterfaceCopyAll() as NSArray {
            if let bsdName = SCNetworkInterfaceGetBSDName(interface as! SCNetworkInterface),
               let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface as! SCNetworkInterface) {
                list.append(Network_interface(displayName: displayName as String, BSDName: bsdName as String))
            }
        }
        self.interfaces = list
    }
    
    private func hasVPN() -> Bool {
        if let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
           let scopes = settings["__SCOPED__"] as? [String: Any] {
            return !scopes.filter({ $0.key.contains("tap") || $0.key.contains("tun") || $0.key.contains("ppp") || $0.key.contains("ipsec") || $0.key.contains("ipsec0")}).isEmpty
        }
        return false
    }
}

class Settings: NSHostingView<NetSettingsView>, Settings_v {
    var callback: (() -> Void) = {}
    var callbackWhenUpdateNumberOfProcesses: (() -> Void) = {}
    var usageResetCallback: (() -> Void) = {}
    var connectivityHostCallback: ((_ newState: Bool) -> Void) = { _ in }
    var setInterval: ((_ value: Int) -> Void) = {_ in }
    var publicIPRefreshIntervalCallback: (() -> Void) = {}
    
    public init(_ module: ModuleType) {
        super.init(rootView: NetSettingsView())
        self.rootView.callback = { [weak self] in self?.callback() }
        self.rootView.usageResetCallback = { [weak self] in self?.usageResetCallback() }
        self.rootView.connectivityHostCallback = { [weak self] in self?.connectivityHostCallback($0) }
        self.rootView.setInterval = { [weak self] in self?.setInterval($0) }
        self.rootView.publicIPRefreshIntervalCallback = { [weak self] in self?.publicIPRefreshIntervalCallback() }
    }
    
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @MainActor required init(rootView: NetSettingsView) {
        fatalError("init(rootView:) has not been implemented")
    }
    
    func load(widgets: [widget_t]) {
        self.rootView.widgets = widgets
    }
}
