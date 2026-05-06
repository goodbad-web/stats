//
//  Settings.swift
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

internal class Settings: NSStackView, Settings_v {
    private var usagePerCoreState: Bool = false
    private var splitValueState: Bool = false
    private var updateIntervalValue: Int = 1
    private var updateTopIntervalValue: Int = 1
    private var numberOfProcesses: Int = 8
    private var clustersGroupState: Bool = false
    
    private let title: String
    
    public var callback: (() -> Void) = {}
    public var callbackWhenUpdateNumberOfProcesses: (() -> Void) = {}
    public var setInterval: ((_ value: Int) -> Void) = {_ in }
    public var setTopInterval: ((_ value: Int) -> Void) = {_ in }
    private var splitValueView: NSSwitch? = nil
    private var usagePerCoreView: NSSwitch? = nil
    private var groupByClustersView: NSSwitch? = nil
    
    public init(_ module: ModuleType) {
        self.title = module.stringValue
        self.usagePerCoreState = Store.shared.bool(key: "\(self.title)_usagePerCore", defaultValue: self.usagePerCoreState)
        self.splitValueState = Store.shared.bool(key: "\(self.title)_splitValue", defaultValue: self.splitValueState)
        self.updateIntervalValue = Store.shared.int(key: "\(self.title)_updateInterval", defaultValue: self.updateIntervalValue)
        self.updateTopIntervalValue = Store.shared.int(key: "\(self.title)_updateTopInterval", defaultValue: self.updateTopIntervalValue)
        self.numberOfProcesses = Store.shared.int(key: "\(self.title)_processes", defaultValue: self.numberOfProcesses)
        self.clustersGroupState = Store.shared.bool(key: "\(self.title)_clustersGroup", defaultValue: self.clustersGroupState)
        
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: 0))
        
        self.orientation = .vertical
        self.distribution = .gravityAreas
        self.translatesAutoresizingMaskIntoConstraints = false
        self.spacing = Constants.Settings.margin
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func load(widgets: [widget_t]) {
        self.subviews.forEach{ $0.removeFromSuperview() }
        
        self.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Update interval"), component: selectView(
                action: #selector(self.changeUpdateInterval),
                items: ReaderUpdateIntervals,
                selected: "\(self.updateIntervalValue)"
            )),
            PreferencesRow(localizedString("Update interval for top processes"), component: selectView(
                action: #selector(self.changeUpdateTopInterval),
                items: ReaderUpdateIntervals,
                selected: "\(self.updateTopIntervalValue)"
            ))
        ]))
        
        self.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Number of top processes"), component: selectView(
                action: #selector(self.changeNumberOfProcesses),
                items: NumbersOfProcesses.map{ KeyValue_t(key: "\($0)", value: "\($0)") },
                selected: "\(self.numberOfProcesses)"
            ))
        ]))
        
        if !widgets.filter({ $0 == .barChart }).isEmpty {
            self.splitValueView = switchView(
                action: #selector(self.toggleSplitValue),
                state: self.splitValueState
            )
            self.usagePerCoreView = switchView(
                action: #selector(self.toggleUsagePerCore),
                state: self.usagePerCoreState
            )
            if self.usagePerCoreState || self.clustersGroupState {
                self.splitValueView?.isEnabled = false
                self.splitValueView?.state = .off
            }
            
            var rows: [PreferencesRow] = [
                PreferencesRow(localizedString("Show usage per core"), component: self.usagePerCoreView!)
            ]
            
            self.groupByClustersView = switchView(
                action: #selector(self.toggleClustersGroup),
                state: self.clustersGroupState
            )
            rows.append(PreferencesRow(localizedString("Cluster grouping"), component: self.groupByClustersView!))
            
            rows.append(PreferencesRow(localizedString("Split the value (System/User)"), component: self.splitValueView!))
            
            self.addArrangedSubview(PreferencesSection(rows))
        }
    }
    
    @objc private func changeUpdateInterval(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let value = Int(key) else { return }
        self.updateIntervalValue = value
        Store.shared.set(key: "\(self.title)_updateInterval", value: value)
        self.setInterval(value)
    }
    
    @objc private func changeUpdateTopInterval(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let value = Int(key) else { return }
        self.updateTopIntervalValue = value
        Store.shared.set(key: "\(self.title)_updateTopInterval", value: value)
        self.setTopInterval(value)
    }
    
    @objc private func changeNumberOfProcesses(_ sender: NSMenuItem) {
        if let value = Int(sender.title) {
            self.numberOfProcesses = value
            Store.shared.set(key: "\(self.title)_processes", value: value)
            self.callbackWhenUpdateNumberOfProcesses()
        }
    }
    
    @objc func toggleUsagePerCore(_ sender: NSControl) {
        self.usagePerCoreState = controlState(sender)
        Store.shared.set(key: "\(self.title)_usagePerCore", value: self.usagePerCoreState)
        self.callback()
        
        if !self.usagePerCoreState {
            self.splitValueState = false
            Store.shared.set(key: "\(self.title)_splitValue", value: self.splitValueState)
            self.splitValueView?.state = .off
        } else {
            self.splitValueState = false
            Store.shared.set(key: "\(self.title)_splitValue", value: self.splitValueState)
            self.splitValueView?.state = .off
        }
        
        if self.clustersGroupState && self.usagePerCoreState {
            self.clustersGroupState = false
            Store.shared.set(key: "\(self.title)_clustersGroup", value: self.clustersGroupState)
            self.groupByClustersView?.state = .off
        }
    }
    @objc func toggleSplitValue(_ sender: NSControl) {
        self.splitValueState = controlState(sender)
        Store.shared.set(key: "\(self.title)_splitValue", value: self.splitValueState)
        self.callback()
    }
    
    @objc func toggleClustersGroup(_ sender: NSControl) {
        self.clustersGroupState = controlState(sender)
        Store.shared.set(key: "\(self.title)_clustersGroup", value: self.clustersGroupState)
        
        self.splitValueView?.isEnabled = !(self.usagePerCoreState || self.clustersGroupState)
        
        if self.clustersGroupState && self.usagePerCoreState {
            self.usagePerCoreView?.state = .off
            let toggle: NSSwitch = NSSwitch()
            toggle.state = .off
            self.toggleUsagePerCore(toggle)
        }
        
        self.callback()
    }
}
