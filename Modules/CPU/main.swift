//
//  main.swift
//  CPU
//
//  Created by Serhiy Mytrovtsiy on 09/04/2020.
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit
import WidgetKit

public struct CPU_Load: Codable, Equatable, RemoteType {
    public var totalUsage: Double = 0
    var usagePerCore: [Double] = []
    var usageECores: Double? = nil
    var usagePCores: Double? = nil
    var usageSCores: Double? = nil
    
    var systemLoad: Double = 0
    var userLoad: Double = 0
    var idleLoad: Double = 0
    
    public func remote() -> Data? {
        var string = "1,1,\(self.totalUsage),\(self.usagePerCore.count),"
        for c in self.usagePerCore {
            string += "\(c),"
        }
        string += "$"
        return string.data(using: .utf8)
    }

    public static func == (lhs: CPU_Load, rhs: CPU_Load) -> Bool {
        return abs(lhs.totalUsage - rhs.totalUsage) < 0.01 &&
            lhs.usagePerCore.count == rhs.usagePerCore.count &&
            lhs.usageECores == rhs.usageECores &&
            lhs.usagePCores == rhs.usagePCores &&
            lhs.usageSCores == rhs.usageSCores &&
            abs(lhs.systemLoad - rhs.systemLoad) < 0.01 &&
            abs(lhs.userLoad - rhs.userLoad) < 0.01
    }
}

public struct CPU_Frequency: Codable, Equatable {
    var value: Double? = nil
    var eCore: Double? = nil
    var pCore: Double? = nil
    var sCore: Double? = nil

    public static func == (lhs: CPU_Frequency, rhs: CPU_Frequency) -> Bool {
        return lhs.value == rhs.value &&
            lhs.eCore == rhs.eCore &&
            lhs.pCore == rhs.pCore &&
            lhs.sCore == rhs.sCore
    }
}

public struct CPU_Limit: Codable {
    var scheduler: Int = 0
    var cpus: Int = 0
    var speed: Int = 0
}

public struct CPU_AverageLoad: Codable, Equatable, RemoteType {
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0
    
    public func remote() -> Data? {
        let string = "1,1,\(self.load1),\(self.load5),\(self.load15)$"
        return string.data(using: .utf8)
    }

    public static func == (lhs: CPU_AverageLoad, rhs: CPU_AverageLoad) -> Bool {
        return abs(lhs.load1 - rhs.load1) < 0.01 &&
            abs(lhs.load5 - rhs.load5) < 0.01 &&
            abs(lhs.load15 - rhs.load15) < 0.01
    }
}

public class CPU: Module {
    private let popupView: Popup
    private let settingsView: Settings
    private let portalView: Portal
    private let notificationsView: Notifications
    private let previewView: Preview
    
    private var loadReader: LoadReader? = nil
    private var processReader: ProcessReader? = nil
    private var temperatureReader: TemperatureReader? = nil
    private var frequencyReader: FrequencyReader? = nil
    private var averageLoadReader: AverageLoadReader? = nil
    
    private var usagePerCoreState: Bool {
        Store.shared.bool(key: "\(self.config.name)_usagePerCore", defaultValue: false)
    }
    private var splitValueState: Bool {
        Store.shared.bool(key: "\(self.config.name)_splitValue", defaultValue: false)
    }
    private var groupByClustersState: Bool {
        Store.shared.bool(key: "\(self.config.name)_clustersGroup", defaultValue: false)
    }
    private var systemColor: NSColor {
        let color = SColor.secondRed
        let key = Store.shared.string(key: "\(self.config.name)_systemColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    private var userColor: NSColor {
        let color = SColor.secondBlue
        let key = Store.shared.string(key: "\(self.config.name)_userColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    
    private var eCoresColor: NSColor {
        let color = SColor.teal
        let key = Store.shared.string(key: "\(self.config.name)_eCoresColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    private var pCoresColor: NSColor {
        let color = SColor.indigo
        let key = Store.shared.string(key: "\(self.config.name)_pCoresColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    private var sCoresColor: NSColor {
        let color = SColor.orange
        let key = Store.shared.string(key: "\(self.config.name)_sCoresColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    
    private var selectedMiniSensor: String {
        Store.shared.string(key: "CPU_mini_sensor", defaultValue: "Total")
    }
    private var selectedStackSensor: String {
        Store.shared.string(key: "CPU_stack_sensor", defaultValue: "Total/Free")
    }
    
    private var systemWidgetsUpdatesState: Bool {
        self.userDefaults?.bool(forKey: "systemWidgetsUpdates_state") ?? false
    }
    
    public init() {
        self.settingsView = Settings(.CPU)
        
        let loadReader = LoadReader(.CPU)
        let processReader = ProcessReader(.CPU)
        let temperatureReader = TemperatureReader(.CPU, popup: true)
        let frequencyReader = FrequencyReader(.CPU)
        let averageLoadReader = AverageLoadReader(.CPU, popup: true)
        
        self.loadReader = loadReader
        self.processReader = processReader
        self.temperatureReader = temperatureReader
        self.frequencyReader = frequencyReader
        self.averageLoadReader = averageLoadReader
        
        self.popupView = Popup(.CPU, load: loadReader, frequency: frequencyReader, temperature: temperatureReader)
        self.portalView = Portal(.CPU)
        self.notificationsView = Notifications(.CPU)
        self.previewView = Preview(.CPU)
        
        super.init(
            moduleType: .CPU,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView,
            preview: self.previewView
        )
        guard self.available else { return }
        
        self.loadReader?.callbackHandler = { [weak self] value in
            self?.loadCallback(value)
        }
        self.processReader?.callbackHandler = { [weak self] value in
            self?.popupView.processCallback(value)
        }
        self.averageLoadReader?.callbackHandler = { [weak self] value in
            self?.popupView.averageCallback(value)
            self?.previewView.averageCallback(value)
        }
        self.temperatureReader?.callbackHandler = { [weak self] value in
            self?.popupView.temperatureCallback(value)
        }
        self.frequencyReader?.callbackHandler = { [weak self] value in
            self?.popupView.frequencyCallback(value)
            self?.previewView.frequencyCallback(value)
        }
        
        self.settingsView.callback = { [weak self] in
            self?.loadReader?.read()
        }
        self.settingsView.callbackWhenUpdateNumberOfProcesses = { [weak self] in
            self?.popupView.numberOfProcessesUpdated()
            self?.processReader?.read()
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.loadReader?.setInterval(value)
        }
        self.settingsView.setTopInterval = { [weak self] value in
            self?.processReader?.setInterval(value)
        }
        
        self.setReaders([
            self.loadReader,
            self.processReader,
            self.temperatureReader,
            self.frequencyReader,
            self.averageLoadReader
        ])
    }
    
    public override func updateReaderActivityModes() {
        let detailVisible = self.isPopupVisible || self.isSettingsWindowVisible
        let mainMode = SamplingPolicy.mode(hasActiveValueWidget: self.hasActiveValueWidget, detailVisible: detailVisible)
        
        self.loadReader?.setActivityMode(mainMode)
        self.frequencyReader?.setActivityMode(detailVisible ? .active : mainMode)
        self.temperatureReader?.setActivityMode(SamplingPolicy.detailMode(detailVisible: detailVisible))
        self.averageLoadReader?.setActivityMode(SamplingPolicy.detailMode(detailVisible: detailVisible))
        self.processReader?.setActivityMode(SamplingPolicy.popupMode(popupVisible: self.isPopupVisible))
    }
    
    private func loadCallback(_ raw: CPU_Load?) {
        guard let value = raw, self.enabled else { return }
        
        self.popupView.loadCallback(value)
        self.portalView.callback(value)
        self.notificationsView.loadCallback(value)
        self.previewView.loadCallback(value)
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { [self] (w: SWidget) in
            switch w.item {
            case let widget as Mini:
                var val = value.totalUsage
                if self.selectedMiniSensor == "System" {
                    val = value.systemLoad
                } else if self.selectedMiniSensor == "User" {
                    val = value.userLoad
                }
                widget.setValue(val)
            case let widget as LineChart: widget.setValue(value.totalUsage)
            case let widget as StackWidget:
                var list: [Stack_t] = []
                if self.selectedStackSensor == "Total/Free" {
                    list.append(Stack_t(key: "total", value: "\(value.totalUsage.finiteInt(multipliedBy: 100))%", label: localizedString("Total")))
                    list.append(Stack_t(key: "idle", value: "\(value.idleLoad.finiteInt(multipliedBy: 100))%", label: localizedString("Idle")))
                } else if self.selectedStackSensor == "System/User" {
                    list.append(Stack_t(key: "system", value: "\(value.systemLoad.finiteInt(multipliedBy: 100))%", label: localizedString("System")))
                    list.append(Stack_t(key: "user", value: "\(value.userLoad.finiteInt(multipliedBy: 100))%", label: localizedString("User")))
                }
                widget.setValues(list)
            case let widget as BarChart:
                var val: [[ColorValue]] = [[ColorValue(value.totalUsage)]]
                let cores = SystemKit.shared.device.info.cpu?.cores ?? []
                
                if self.usagePerCoreState {
                    if widget.colorState == .cluster {
                        val = []
                        for (i, v) in value.usagePerCore.enumerated() {
                            let core = cores.first(where: {$0.id == i })
                            let color = core?.type == .efficiency ? self.eCoresColor : core?.type == .super ? self.sCoresColor : self.pCoresColor
                            val.append([ColorValue(v, color: color)])
                        }
                    } else {
                        val = value.usagePerCore.map({ [ColorValue($0)] })
                    }
                } else if self.splitValueState {
                    val = [[
                        ColorValue(value.systemLoad, color: self.systemColor),
                        ColorValue(value.userLoad, color: self.userColor)
                    ]]
                } else if self.groupByClustersState {
                    var clusters: [[ColorValue]] = []
                    var clustersPlain: [[ColorValue]] = []
                    
                    if let e = value.usageECores {
                        clusters.append([ColorValue(e, color: self.eCoresColor)])
                        clustersPlain.append([ColorValue(e)])
                    }
                    if let p = value.usagePCores {
                        clusters.append([ColorValue(p, color: self.pCoresColor)])
                        clustersPlain.append([ColorValue(p)])
                    }
                    if let s = value.usageSCores {
                        clusters.append([ColorValue(s, color: self.sCoresColor)])
                        clustersPlain.append([ColorValue(s)])
                    }
                    
                    if !clusters.isEmpty {
                        val = widget.colorState == .cluster ? clusters : clustersPlain
                    }
                }
                widget.setValue(val)
            case let widget as PieChart:
                widget.setValue([
                    ColorValue(value.systemLoad, color: self.systemColor),
                    ColorValue(value.userLoad, color: self.userColor)
                ])
            case let widget as Tachometer:
                widget.setValue([
                    ColorValue(value.systemLoad, color: self.systemColor),
                    ColorValue(value.userLoad, color: self.userColor)
                ])
            default: break
            }
        }
        
        if self.systemWidgetsUpdatesState {
            if isWidgetActive(self.userDefaults, [CPU_entry.kind, "UnitedWidget"]), let blobData = try? JSONEncoder().encode(value) {
                let key = "CPU@LoadReader"
                if self.userDefaults?.data(forKey: key) != blobData {
                    self.userDefaults?.set(blobData, forKey: key)
                    WidgetCenter.shared.reloadTimelines(ofKind: CPU_entry.kind)
                    WidgetCenter.shared.reloadTimelines(ofKind: "UnitedWidget")
                }
            }
        }
    }
}
