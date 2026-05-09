//
//  main.swift
//  Memory
//
//  Created by Serhiy Mytrovtsiy on 12/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit
import WidgetKit

public struct RAM_Usage: Codable, Equatable, RemoteType {
    var total: Double
    var used: Double
    var free: Double
    
    var active: Double
    var inactive: Double
    var wired: Double
    var compressed: Double
    
    var app: Double
    var cache: Double
    
    var swap: Swap
    var pressure: Pressure
    
    var swapins: Int64
    var swapouts: Int64
    
    public var usage: Double {
        get {
            if self.total == 0 { return 0 }
            let val = (self.total - self.free) / self.total
            return val.isFinite ? val : 0
        }
    }
    
    public func remote() -> Data? {
        let string = "\(self.total),\(self.used),\(self.pressure.level),\(self.swap.used)$"
        return string.data(using: .utf8)
    }

    public static func == (lhs: RAM_Usage, rhs: RAM_Usage) -> Bool {
        return lhs.total == rhs.total &&
            abs(lhs.used - rhs.used) < 1024 * 1024 && // 1MB threshold
            lhs.active == rhs.active &&
            lhs.inactive == rhs.inactive &&
            lhs.wired == rhs.wired &&
            lhs.compressed == rhs.compressed &&
            lhs.app == rhs.app &&
            lhs.cache == rhs.cache &&
            lhs.swap == rhs.swap &&
            lhs.pressure == rhs.pressure &&
            lhs.swapins == rhs.swapins &&
            lhs.swapouts == rhs.swapouts
    }
}

public struct Swap: Codable, Equatable {
    var total: Double
    var used: Double
    var free: Double

    public static func == (lhs: Swap, rhs: Swap) -> Bool {
        return lhs.total == rhs.total &&
            abs(lhs.used - rhs.used) < 1024 * 1024 &&
            lhs.free == rhs.free
    }
}

public struct Pressure: Codable, Equatable {
    let level: Int
    let value: RAMPressure

    public static func == (lhs: Pressure, rhs: Pressure) -> Bool {
        return lhs.level == rhs.level &&
            lhs.value == rhs.value
    }
}

public class RAM: Module {
    private let popupView: Popup
    private let settingsView: Settings
    private let portalView: Portal
    private let notificationsView: Notifications
    private let previewView: Preview
    
    private var usageReader: UsageReader? = nil
    private var processReader: ProcessReader? = nil
    
    private var splitValueState: Bool {
        return Store.shared.bool(key: "\(self.config.name)_splitValue", defaultValue: false)
    }
    private var appColor: NSColor {
        let color = SColor.secondBlue
        let key = Store.shared.string(key: "\(self.config.name)_appColor", defaultValue: color.key)
        return SColor.fromString(key).additional as? NSColor ?? color.additional as? NSColor ?? NSColor.systemBlue
    }
    private var wiredColor: NSColor {
        let color = SColor.secondOrange
        let key = Store.shared.string(key: "\(self.config.name)_wiredColor", defaultValue: color.key)
        return SColor.fromString(key).additional as? NSColor ?? color.additional as? NSColor ?? NSColor.systemOrange
    }
    private var compressedColor: NSColor {
        let color = SColor.pink
        let key = Store.shared.string(key: "\(self.config.name)_compressedColor", defaultValue: color.key)
        return SColor.fromString(key).additional as? NSColor ?? color.additional as? NSColor ?? NSColor.systemPink
    }
    
    private var selectedMiniSensor: String {
        Store.shared.string(key: "RAM_mini_sensor", defaultValue: "Usage")
    }
    private var selectedStackSensor: String {
        Store.shared.string(key: "RAM_stack_sensor", defaultValue: "Used/Free")
    }
    
    private var textValue: String {
        Store.shared.string(key: "\(self.name)_textWidgetValue", defaultValue: "$mem.used/$mem.total ($pressure.value)")
    }
    
    private var systemWidgetsUpdatesState: Bool {
        self.userDefaults?.bool(forKey: "systemWidgetsUpdates_state") ?? false
    }
    
    public init() {
        self.settingsView = Settings(.RAM)
        self.popupView = Popup(.RAM)
        self.portalView = Portal(.RAM)
        self.notificationsView = Notifications(.RAM)
        self.previewView = Preview(.RAM)
        
        super.init(
            moduleType: .RAM,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView,
            preview: self.previewView
        )
        guard self.available else { return }
        
        self.settingsView.callback = { [weak self] in
            self?.usageReader?.read()
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.processReader?.read()
            self?.usageReader?.setInterval(value)
        }
        self.settingsView.setTopInterval = { [weak self] value in
            self?.processReader?.setInterval(value)
        }
        
        self.usageReader = UsageReader(.RAM) { [weak self] value in
            self?.loadCallback(value)
        }
        self.processReader = ProcessReader(.RAM) { [weak self] value in
            if let list = value {
                self?.popupView.processCallback(list)
            }
        }
        
        let processReader = self.processReader
        self.settingsView.callbackWhenUpdateNumberOfProcesses = { [weak self] in
            self?.popupView.numberOfProcessesUpdated()
            Task {
                processReader?.read()
            }
        }
        
        self.setReaders([self.usageReader, self.processReader])
    }
    
    public override func updateReaderActivityModes() {
        let detailVisible = self.isPopupVisible || self.isSettingsWindowVisible
        let usageMode = SamplingPolicy.mode(hasActiveValueWidget: self.hasActiveValueWidget, detailVisible: detailVisible)
        self.usageReader?.setActivityMode(usageMode)
        self.processReader?.setActivityMode(SamplingPolicy.popupMode(popupVisible: self.isPopupVisible))
    }
    
    private func loadCallback(_ raw: RAM_Usage?) {
        guard let value = raw, self.enabled else { return }

        if self.isPopupVisible {
            self.popupView.loadCallback(value)
        }
        if self.portalView.window?.isVisible ?? false {
            self.portalView.callback(value)
        }
        self.notificationsView.loadCallback(value)
        if self.previewView.window?.isVisible ?? false {
            self.previewView.loadCallback(value)
        }
        
        let total: Double = value.total == 0 ? 1 : value.total
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as Mini:
                var val = value.usage
                if self.selectedMiniSensor == "Used" {
                    val = value.used / total
                } else if self.selectedMiniSensor == "Free" {
                    val = value.free / total
                }
                widget.setValue(val)
                widget.setPressure(value.pressure.value)
            case let widget as LineChart:
                widget.setValue(value.usage)
                widget.setPressure(value.pressure.value)
            case let widget as StackWidget:
                var list: [Stack_t] = []
                if self.selectedStackSensor == "Used/Free" {
                    list.append(Stack_t(key: "used", value: Units(bytes: Int64(value.used)).getReadableMemory(style: .memory), label: localizedString("Used")))
                    list.append(Stack_t(key: "free", value: Units(bytes: Int64(value.free)).getReadableMemory(style: .memory), label: localizedString("Free")))
                } else if self.selectedStackSensor == "Active/Inactive" {
                    list.append(Stack_t(key: "active", value: Units(bytes: Int64(value.active)).getReadableMemory(style: .memory), label: localizedString("Active")))
                    list.append(Stack_t(key: "inactive", value: Units(bytes: Int64(value.inactive)).getReadableMemory(style: .memory), label: localizedString("Inactive")))
                } else if self.selectedStackSensor == "App/Cache" {
                    list.append(Stack_t(key: "app", value: Units(bytes: Int64(value.app)).getReadableMemory(style: .memory), label: localizedString("App")))
                    list.append(Stack_t(key: "cache", value: Units(bytes: Int64(value.cache)).getReadableMemory(style: .memory), label: localizedString("Cache")))
                }
                widget.setValues(list)
            case let widget as BarChart:
                if self.splitValueState {
                    widget.setValue([[
                        ColorValue(value.app/total, color: self.appColor),
                        ColorValue(value.wired/total, color: self.wiredColor),
                        ColorValue(value.compressed/total, color: self.compressedColor)
                    ]])
                } else {
                    widget.setValue([[ColorValue(value.usage)]])
                    widget.setColorZones((0.8, 0.95))
                    widget.setPressure(value.pressure.value)
                }
            case let widget as PieChart:
                widget.setValue([
                    ColorValue(value.app/total, color: self.appColor),
                    ColorValue(value.wired/total, color: self.wiredColor),
                    ColorValue(value.compressed/total, color: self.compressedColor)
                ])
            case let widget as MemoryWidget:
                let free = Units(bytes: Int64(value.free)).getReadableMemory(style: .memory)
                let used = Units(bytes: Int64(value.used)).getReadableMemory(style: .memory)
                widget.setValue((free, used), usedPercentage: value.usage)
                widget.setPressure(value.pressure.value)
            case let widget as Tachometer:
                widget.setValue([
                    ColorValue(value.app/total, color: self.appColor),
                    ColorValue(value.wired/total, color: self.wiredColor),
                    ColorValue(value.compressed/total, color: self.compressedColor)
                ])
            case let widget as TextWidget:
                var text = "\(self.textValue)"
                let pairs = TextWidget.parseText(text)
                pairs.forEach { pair in
                    var replacement: String? = nil
                    
                    switch pair.key {
                    case "$mem":
                        switch pair.value {
                        case "total": replacement = Units(bytes: Int64(value.total)).getReadableMemory(style: .memory)
                        case "used": replacement = Units(bytes: Int64(value.used)).getReadableMemory(style: .memory)
                        case "free": replacement = Units(bytes: Int64(value.free)).getReadableMemory(style: .memory)
                        case "active": replacement = Units(bytes: Int64(value.active)).getReadableMemory(style: .memory)
                        case "inactive": replacement = Units(bytes: Int64(value.inactive)).getReadableMemory(style: .memory)
                        case "wired": replacement = Units(bytes: Int64(value.wired)).getReadableMemory(style: .memory)
                        case "compressed": replacement = Units(bytes: Int64(value.compressed)).getReadableMemory(style: .memory)
                        case "app": replacement = Units(bytes: Int64(value.app)).getReadableMemory(style: .memory)
                        case "cache": replacement = Units(bytes: Int64(value.cache)).getReadableMemory(style: .memory)
                        case "swapins": replacement = "\(value.swapins)"
                        case "swapouts": replacement = "\(value.swapouts)"
                        default: return
                        }
                    case "$swap":
                        switch pair.value {
                        case "total": replacement = Units(bytes: Int64(value.swap.total)).getReadableMemory(style: .memory)
                        case "used": replacement = Units(bytes: Int64(value.swap.used)).getReadableMemory(style: .memory)
                        case "free": replacement = Units(bytes: Int64(value.swap.free)).getReadableMemory(style: .memory)
                        default: return
                        }
                    case "$pressure":
                        switch pair.value {
                        case "level": replacement = "\(value.pressure.level)"
                        case "value": replacement = value.pressure.value.rawValue
                        default: return
                        }
                    default: return
                    }
                    
                    if let replacement {
                        let key = pair.value.isEmpty ? pair.key : "\(pair.key).\(pair.value)"
                        text = text.replacingOccurrences(of: key, with: replacement)
                    }
                }
                widget.setValue(text)
            case let widget as DotWidget: widget.setValue(value.pressure.value.pressureColor())
            default: break
            }
        }
        
        if self.systemWidgetsUpdatesState {
            if isWidgetActive(self.userDefaults, [RAM_entry.kind, "UnitedWidget"]), let blobData = try? JSONEncoder().encode(value) {
                let key = "RAM@UsageReader"
                if self.userDefaults?.data(forKey: key) != blobData {
                    self.userDefaults?.set(blobData, forKey: key)
                    WidgetTimelineReloader.shared.reloadTimelines(ofKind: RAM_entry.kind)
                    WidgetTimelineReloader.shared.reloadTimelines(ofKind: "UnitedWidget")
                }
            }
        }
    }
}
