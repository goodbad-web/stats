//
//  settings.swift
//  Clock
//
//  Created by Serhiy Mytrovtsiy on 24/03/2023
//  Using Swift 5.0
//  Running on macOS 13.2
//
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import SwiftUI
import Kit

let nameColumnID = NSUserInterfaceItemIdentifier(rawValue: "name")
let formatColumnID = NSUserInterfaceItemIdentifier(rawValue: "format")
let tzColumnID = NSUserInterfaceItemIdentifier(rawValue: "tz")
let statusColumnID = NSUserInterfaceItemIdentifier(rawValue: "status")

internal class Settings: NSStackView, Settings_v {
    public var callback: (() -> Void) = {}
    private var title: String
    
    public init(_ module: ModuleType) {
        self.title = module.stringValue
        super.init(frame: NSRect.zero)
        
        self.orientation = .vertical
        self.distribution = .fill
        self.spacing = 0
        
        let hostingView = NSHostingView(rootView: ClockSettingsView(callback: { [weak self] in
            self?.callback()
        }))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        self.addArrangedSubview(hostingView)
        
        NSLayoutConstraint.activate([
            hostingView.widthAnchor.constraint(equalTo: self.widthAnchor),
            hostingView.heightAnchor.constraint(greaterThanOrEqualToConstant: 250)
        ])
    }

struct ClockSettingsView: View {
    var callback: () -> Void
    
    @AppStorage("Clock_ntpSync") private var ntpSync: Bool = false
    @AppStorage("Clock_list") private var clockListData: Data = Data()
    
    @State private var list: [Clock_t] = []
    
    var body: some View {
        Form {
            Section {
                Toggle(localizedString("Sync with NTP server"), isOn: $ntpSync)
                    .onChange(of: ntpSync) { _, _ in
                        callback()
                    }
            }
            
            Section {
                List {
                    ForEach($list, id: \.id) { $item in
                        HStack {
                            TextField(localizedString("Name"), text: $item.name)
                                .textFieldStyle(.plain)
                            
                            TextField(localizedString("Format"), text: $item.format)
                                .textFieldStyle(.plain)
                                .frame(width: 140)
                            
                            Picker("", selection: $item.tz) {
                                ForEach(Clock.zones, id: \.key) { zone in
                                    if zone.value == "separator" {
                                        Divider()
                                    } else {
                                        Text(zone.value).tag(zone.key)
                                    }
                                }
                            }
                            .frame(width: 120)
                            .labelsHidden()
                            
                            Toggle("", isOn: $item.enabled)
                                .labelsHidden()
                        }
                    }
                    .onDelete(perform: deleteClock)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(height: 200)
            }
            
            HStack {
                Button(action: addNewClock) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .padding(4)
                
                Spacer()
                
                Button(action: openFormatHelp) {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.plain)
                .padding(4)
            }
        }
        .padding()
        .onAppear {
            loadList()
        }
        .onChange(of: list) { _, newValue in
            saveList(newValue)
            callback()
        }
    }
    
    private func loadList() {
        if let decoded = try? JSONDecoder().decode([Clock_t].self, from: clockListData) {
            list = decoded
        }
        if list.isEmpty {
            list = [Clock.local]
        }
    }
    
    private func saveList(_ newValue: [Clock_t]) {
        if let encoded = try? JSONEncoder().encode(newValue) {
            clockListData = encoded
        }
    }
    
    private func addNewClock() {
        list.append(Clock_t(name: "\(localizedString("Clock")) \(list.count)", format: Clock.local.format, tz: Clock.local.tz))
    }
    
    private func deleteClock(at offsets: IndexSet) {
        list.remove(atOffsets: offsets)
    }
    
    private func openFormatHelp() {
        NSWorkspace.shared.open(URL(string: "https://www.nsdateformatter.com")!)
    }
}
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func load(widgets: [Kit.widget_t]) {
        // SwiftUI 側で @AppStorage や @State で状態管理するため不要
    }
}
