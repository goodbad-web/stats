//
//  main.swift
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
import WidgetKit

public typealias GPU_type = String
public enum GPU_types: GPU_type {
    case unknown = ""
    
    case integrated = "i"
    case external = "e"
    case discrete = "d"
}

public struct GPU_Info: Codable, Equatable {
    public let id: String
    public let type: GPU_type
    
    public let IOClass: String
    public var vendor: String? = nil
    public let model: String
    public var cores: Int? = nil
    
    public var state: Bool = true
    
    public var fanSpeed: Int? = nil
    public var coreClock: Int? = nil
    public var memoryClock: Int? = nil
    public var temperature: Double? = nil
    public var utilization: Double? = nil
    public var renderUtilization: Double? = nil
    public var tilerUtilization: Double? = nil
    public var aneUtilization: Double? = nil
    public var vramTotal: Int64? = nil
    public var vramUsed: Double? = nil
    public var gpuPower: Double? = nil
    public var fps: Double? = nil
    public var topProcesses: [TopProcess] = []
    
    init(id: String, type: GPU_type, IOClass: String, vendor: String? = nil, model: String, cores: Int?, utilization: Double? = nil, render: Double? = nil, tiler: Double? = nil) {
        self.id = id
        self.type = type
        self.IOClass = IOClass
        self.vendor = vendor
        self.model = model
        self.cores = cores
        self.utilization = utilization
        self.renderUtilization = render
        self.tilerUtilization = tiler
    }
    
    public func remote() -> String {
        var id = self.id
        if self.id.isEmpty {
            id = "0"
        }
        return "\(id),1,\(self.utilization ?? 0),\(self.renderUtilization ?? 0),\(self.tilerUtilization ?? 0),\(self.vramUsed ?? 0),\(self.gpuPower ?? 0)"
    }

    public static func == (lhs: GPU_Info, rhs: GPU_Info) -> Bool {
        return lhs.id == rhs.id &&
            lhs.state == rhs.state &&
            abs((lhs.utilization ?? 0) - (rhs.utilization ?? 0)) < 0.01 &&
            abs((lhs.renderUtilization ?? 0) - (rhs.renderUtilization ?? 0)) < 0.01 &&
            abs((lhs.tilerUtilization ?? 0) - (rhs.tilerUtilization ?? 0)) < 0.01 &&
            abs((lhs.aneUtilization ?? 0) - (rhs.aneUtilization ?? 0)) < 0.01 &&
            lhs.temperature == rhs.temperature &&
            lhs.vramUsed == rhs.vramUsed &&
            lhs.gpuPower == rhs.gpuPower
    }
}

public class GPUs: Codable, Equatable, RemoteType {
    private var queue: DispatchQueue = DispatchQueue(label: "eu.exelban.Stats.GPU.SynchronizedArray")
    
    private var _list: [GPU_Info] = []
    public var list: [GPU_Info] {
        get { self.queue.sync { self._list } }
        set { self.queue.sync { self._list = newValue } }
    }
    
    enum CodingKeys: String, CodingKey {
        case list
    }
    
    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.list = try container.decode([GPU_Info].self, forKey: CodingKeys.list)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(list, forKey: .list)
    }
    
    init() {}
    
    internal func active() -> [GPU_Info] {
        return self.list.filter{ $0.state && $0.utilization != nil }.sorted{ $0.utilization ?? 0 > $1.utilization ?? 0 }
    }
    
    public func remote() -> Data? {
        var string = "\(self.list.count),"
        for (i, v) in self.list.enumerated() {
            string += v.remote()
            if i != self.list.count {
                string += ","
            }
        }
        string += "$"
        return string.data(using: .utf8)
    }

    public static func == (lhs: GPUs, rhs: GPUs) -> Bool {
        return lhs.list == rhs.list
    }
}

public class GPU: Module {
    private let popupView: Popup
    private let settingsView: Settings
    private let portalView: Portal
    private let notificationsView: Notifications
    private let previewView: Preview
    
    private var infoReader: InfoReader? = nil
    
    private var selectedMiniSensor: String {
        Store.shared.string(key: "GPU_mini_sensor", defaultValue: "Utilization")
    }
    private var selectedStackSensor: String {
        Store.shared.string(key: "GPU_stack_sensor", defaultValue: "Utilization/Render")
    }
    
    private var selectedGPU: String = ""
    private var notificationLevelState: Bool = false
    private var notificationID: String? = nil
    
    private var showType: Bool {
        Store.shared.bool(key: "\(self.config.name)_showType", defaultValue: false)
    }
    
    private var systemWidgetsUpdatesState: Bool {
        self.userDefaults?.bool(forKey: "systemWidgetsUpdates_state") ?? false
    }
    
    public init() {
        self.popupView = Popup()
        self.settingsView = Settings(.GPU)
        self.portalView = Portal(.GPU)
        self.notificationsView = Notifications(.GPU)
        self.previewView = Preview(.GPU)
        
        super.init(
            moduleType: .GPU,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView,
            preview: self.previewView
        )
        guard self.available else { return }
        
        self.infoReader = InfoReader(.GPU) { [weak self] value in
            self?.infoCallback(value)
        }
        self.selectedGPU = Store.shared.string(key: "\(self.config.name)_gpu", defaultValue: self.selectedGPU)
        
        self.settingsView.selectedGPUHandler = { [weak self] value in
            self?.selectedGPU = value
            self?.infoReader?.read()
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.infoReader?.setInterval(value)
        }
        self.settingsView.callback = { [weak self] in
            self?.popupView.numberOfProcessesUpdated()
            self?.infoReader?.read()
        }
        
        self.setReaders([self.infoReader])
    }
    
    private func infoCallback(_ raw: GPUs?) {
        guard raw != nil && !raw!.list.isEmpty, let value = raw, self.enabled else { return }
        
        Task { @MainActor in
            self.popupView.infoCallback(value)
        }
        self.settingsView.setList(value)
        
        let activeGPUs = value.active()
        guard let activeGPU = activeGPUs.first(where: { $0.state }) ?? activeGPUs.first else {
            return
        }
        let selectedGPU: GPU_Info = activeGPUs.first{ $0.model == self.selectedGPU } ?? activeGPU
        guard let utilization = selectedGPU.utilization else {
            return
        }
        
        self.portalView.callback(selectedGPU)
        self.notificationsView.usageCallback(utilization)
        self.previewView.loadCallback(selectedGPU)
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as Mini:
                var val = utilization
                if self.selectedMiniSensor == "Render" {
                    val = selectedGPU.renderUtilization ?? 0
                } else if self.selectedMiniSensor == "Tiler" {
                    val = selectedGPU.tilerUtilization ?? 0
                }
                widget.setValue(val)
                widget.setTitle(self.showType ? "\(selectedGPU.type)GPU" : nil)
            case let widget as LineChart: widget.setValue(utilization)
            case let widget as StackWidget:
                var list: [Stack_t] = []
                if self.selectedStackSensor == "Utilization/Render" {
                    list.append(Stack_t(key: "utilization", value: "\(Int(utilization * 100))%", label: localizedString("Utilization")))
                    list.append(Stack_t(key: "render", value: "\(Int((selectedGPU.renderUtilization ?? 0) * 100))%", label: localizedString("Render")))
                } else if self.selectedStackSensor == "Render/Tiler" {
                    list.append(Stack_t(key: "render", value: "\(Int((selectedGPU.renderUtilization ?? 0) * 100))%", label: localizedString("Render")))
                    list.append(Stack_t(key: "tiler", value: "\(Int((selectedGPU.tilerUtilization ?? 0) * 100))%", label: localizedString("Tiler")))
                } else if self.selectedStackSensor == "Utilization/ANE" {
                    list.append(Stack_t(key: "utilization", value: "\(Int(utilization * 100))%", label: localizedString("Utilization")))
                    list.append(Stack_t(key: "ane", value: "\(Int((selectedGPU.aneUtilization ?? 0) * 100))%", label: localizedString("ANE")))
                }
                widget.setValues(list)
            case let widget as BarChart: widget.setValue([[ColorValue(utilization)]])
            case let widget as Tachometer:
                widget.setValue([
                    ColorValue(utilization, color: NSColor.systemBlue)
                ])
            default: break
            }
        }
        
        if self.systemWidgetsUpdatesState {
            if isWidgetActive(self.userDefaults, [GPU_entry.kind, "UnitedWidget"]), let blobData = try? JSONEncoder().encode(selectedGPU) {
                let key = "GPU@InfoReader"
                if self.userDefaults?.data(forKey: key) != blobData {
                    self.userDefaults?.set(blobData, forKey: key)
                    WidgetCenter.shared.reloadTimelines(ofKind: GPU_entry.kind)
                    WidgetCenter.shared.reloadTimelines(ofKind: "UnitedWidget")
                }
            }
        }
    }
}
