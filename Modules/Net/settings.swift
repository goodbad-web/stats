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
    @AppStorage(AppSettingsKeys.moduleInt("Net", "processes", defaultValue: 8).rawValue) private var numberOfProcesses: Int = 8
    @AppStorage(AppSettingsKeys.moduleString("Net", "reader", defaultValue: "interface").rawValue) private var readerType: String = "interface"
    @AppStorage(AppSettingsKeys.moduleString("Net", "usageReset", defaultValue: AppUpdateInterval.never.rawValue).rawValue) private var usageReset: String = AppUpdateInterval.never.rawValue
    @AppStorage(AppSettingsKeys.moduleBool("Net", "VPNMode", defaultValue: false).rawValue) private var vpnMode: Bool = false
    @AppStorage(AppSettingsKeys.moduleBool("Net", "widgetActivationThresholdState", defaultValue: false).rawValue) private var widgetActivationThresholdState: Bool = false
    @AppStorage(AppSettingsKeys.moduleInt("Net", "widgetActivationThreshold", defaultValue: 0).rawValue) private var widgetActivationThreshold: Int = 0
    @AppStorage(AppSettingsKeys.moduleString("Net", "widgetActivationThresholdSize", defaultValue: SizeUnit.MB.key).rawValue) private var widgetActivationThresholdSize: String = SizeUnit.MB.key
    @AppStorage(AppSettingsKeys.moduleString("Net", "ICMPHost", defaultValue: "1.1.1.1").rawValue) private var connectivityICMPHost: String = "1.1.1.1"
    @AppStorage(AppSettingsKeys.moduleString("Net", "HTTPHost", defaultValue: "https://google.com").rawValue) private var connectivityHTTPHost: String = "https://google.com"
    @AppStorage(AppSettingsKeys.moduleInt("Net", "updateICMPInterval", defaultValue: 1).rawValue) private var updateConnectivityInterval: Int = 1
    @AppStorage(AppSettingsKeys.moduleString("Net", "connectivityMode", defaultValue: "icmp").rawValue) private var connectivityMode: String = "icmp"
    @AppStorage(AppSettingsKeys.moduleBool("Net", "publicIP", defaultValue: true).rawValue) private var publicIPState: Bool = true
    @AppStorage(AppSettingsKeys.moduleString("Net", "publicIPRefreshInterval", defaultValue: "never").rawValue) private var publicIPRefreshInterval: String = "never"
    @AppStorage(AppSettingsKeys.moduleString("Net", "base", defaultValue: "byte").rawValue) private var base: String = "byte"
    @AppStorage(AppSettingsKeys.moduleString("Net", "textWidgetValue", defaultValue: "$addr.public - $status").rawValue) private var textValue: String = "$addr.public - $status"
    @AppStorage(AppSettingsKeys.moduleString("Net", "interface", defaultValue: "").rawValue) private var selectedInterface: String = ""
    
    @AppStorage(AppSettingsKeys.moduleString("Net", "mini_sensor", defaultValue: "Download speed").rawValue) private var selectedMiniSensor: String = "Download speed"
    @AppStorage(AppSettingsKeys.moduleString("Net", "stack_sensor", defaultValue: "Speed").rawValue) private var selectedStackSensor: String = "Speed"
    
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
