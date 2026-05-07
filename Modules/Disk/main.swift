//
//  main.swift
//  Disk
//
//  Created by Serhiy Mytrovtsiy on 07/05/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
@preconcurrency import Kit
import WidgetKit

public struct stats: Codable, Equatable {
    var read: Int64 = 0
    var write: Int64 = 0
    
    var readBytes: Int64 = 0
    var writeBytes: Int64 = 0

    public static func == (lhs: stats, rhs: stats) -> Bool {
        return lhs.read == rhs.read &&
            lhs.write == rhs.write &&
            lhs.readBytes == rhs.readBytes &&
            lhs.writeBytes == rhs.writeBytes
    }
}

public struct smart_t: Codable, Equatable {
    var temperature: Int = 0
    var life: Int = 0
    var totalRead: Int64 = 0
    var totalWritten: Int64 = 0
    var powerCycles: Int = 0
    var powerOnHours: Int = 0

    public static func == (lhs: smart_t, rhs: smart_t) -> Bool {
        return lhs.temperature == rhs.temperature &&
            lhs.life == rhs.life &&
            lhs.totalRead == rhs.totalRead &&
            lhs.totalWritten == rhs.totalWritten &&
            lhs.powerCycles == rhs.powerCycles &&
            lhs.powerOnHours == rhs.powerOnHours
    }
}

public struct drive: Codable, Equatable {
    var parent: io_object_t = 0
    
    var uuid: String = ""
    var mediaName: String = ""
    var BSDName: String = ""
    
    var root: Bool = false
    var removable: Bool = false
    
    var model: String = ""
    var path: URL?
    var connectionType: String = ""
    var fileSystem: String = ""
    
    var size: Int64 = 1
    var free: Int64 = 0
    
    var activity: stats = stats()
    var smart: smart_t? = nil
    
    public var percentage: Double {
        let total = self.size
        let free = self.free
        var usedSpace = total - free
        if usedSpace < 0 {
            usedSpace = 0
        }
        if total == 0 {
            return 0
        }
        return Double(usedSpace) / Double(total)
    }
    
    public var popupState: Bool {
        Store.shared.bool(key: "Disk_\(self.uuid)_popup", defaultValue: true)
    }
    
    public func remote() -> String {
        return "\(self.uuid),\(self.size),\(self.size-self.free),\(self.free),\(self.activity.read),\(self.activity.write)"
    }

    public static func == (lhs: drive, rhs: drive) -> Bool {
        return lhs.uuid == rhs.uuid &&
            lhs.size == rhs.size &&
            lhs.free == rhs.free &&
            lhs.activity == rhs.activity &&
            lhs.smart == rhs.smart
    }
}

public class Disks: Codable, Equatable, RemoteType, @unchecked Sendable {
    private nonisolated(unsafe) var _array: [drive] = []
    public var array: [drive] {
        get { self._array }
        set { self._array = newValue }
    }
    
    enum CodingKeys: String, CodingKey {
        case array
    }
    
    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.array = try container.decode([drive].self, forKey: CodingKeys.array)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(array, forKey: .array)
    }
    
    init() {}
    
    public var count: Int {
        self._array.count
    }
    
    public var isEmpty: Bool {
        self._array.isEmpty
    }
    
    public func first(where predicate: (drive) -> Bool) -> drive? {
        return self.array.first(where: predicate)
    }
    
    public func firstIndex(where predicate: (drive) -> Bool) -> Int? {
        return self.array.firstIndex(where: predicate)
    }
    
    public func map<ElementOfResult>(_ transform: (drive) -> ElementOfResult?) -> [ElementOfResult] {
        return self.array.compactMap(transform)
    }
    
    public func filter(where isIncluded: (drive) -> Bool) -> [drive] {
        return self.array.filter(isIncluded)
    }
    
    public func reversed() -> [drive] {
        return self.array.reversed()
    }
    
    func forEach(_ body: (drive) -> Void) {
        self.array.forEach(body)
    }
    
    public func append( _ element: drive) {
        if !self.array.contains(where: {$0.BSDName == element.BSDName}) {
            self.array.append(element)
        }
    }
    
    public func remove(at index: Int) {
        self.array.remove(at: index)
    }
    
    public func sort() {
        self.array.sort{ $1.removable }
    }
    
    func updateFreeSize(_ idx: Int, newValue: Int64) {
        self.array[idx].free = newValue
    }
    
    func updateReadWrite(_ idx: Int, read: Int64, write: Int64) {
        self.array[idx].activity.readBytes = read
        self.array[idx].activity.writeBytes = write
    }
    
    func updateRead(_ idx: Int, newValue: Int64) {
        self.array[idx].activity.read = newValue
    }
    
    func updateWrite(_ idx: Int, newValue: Int64) {
        self.array[idx].activity.write = newValue
    }
    
    func updateSMARTData(_ idx: Int, smart: smart_t?) {
        self.array[idx].smart = smart
    }
    
    public func remote() -> Data? {
        let arr = self.array.filter({ !$0.removable })
        var string = "\(arr.count),"
        for (i, v) in arr.enumerated() {
            string += v.remote()
            if i != self.array.count {
                string += ","
            }
        }
        string += "$"
        return string.data(using: .utf8)
    }

    public static func == (lhs: Disks, rhs: Disks) -> Bool {
        return lhs.array == rhs.array
    }
}

public struct Disk_process: Process_p, Codable, Sendable, Equatable {
    public var base: DataSizeBase {
        DataSizeBase(rawValue: Store.shared.string(key: "\(ModuleType.disk.stringValue)_base", defaultValue: "byte")) ?? .byte
    }
    
    public var pid: Int
    public var name: String
    public var icon: NSImage {
        if let app = NSRunningApplication(processIdentifier: pid_t(self.pid)) {
            return app.icon ?? Constants.defaultProcessIcon
        }
        return Constants.defaultProcessIcon
    }
    
    var read: Int
    var write: Int
    
    init(pid: Int, name: String, read: Int, write: Int) {
        self.pid = pid
        self.name = name
        self.read = read
        self.write = write
        
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            if let name = app.localizedName {
                self.name = name
            }
        }
    }
}

public class Disk: Module {
    private let popupView: Popup = Popup(.disk)
    private let settingsView: Settings = Settings(.disk)
    private let portalView: Portal = Portal(.disk)
    private let notificationsView: Notifications = Notifications(.disk)
    private let previewView: Preview = Preview(.disk)
    
    private var capacityReader: CapacityReader?
    private var activityReader: ActivityReader?
    private var processReader: ProcessReader?
    
    private var selectedMiniSensor: String {
        Store.shared.string(key: "Disk_mini_sensor", defaultValue: "Percentage")
    }
    private var selectedStackSensor: String {
        Store.shared.string(key: "Disk_stack_sensor", defaultValue: "Capacity")
    }
    
    private var selectedDisk: String = ""
    
    private var textValue: String {
        Store.shared.string(key: "\(self.name)_textWidgetValue", defaultValue: "$capacity.free/$capacity.total")
    }
    
    private var systemWidgetsUpdatesState: Bool {
        self.userDefaults?.bool(forKey: "systemWidgetsUpdates_state") ?? false
    }
    
    public init() {
        super.init(
            moduleType: .disk,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView,
            preview: self.previewView
        )
        guard self.available else { return }
        
        self.capacityReader = CapacityReader(.disk) { [weak self] value in
            if let value {
                self?.capacityCallback(value)
            }
        }
        self.activityReader = ActivityReader(.disk) { [weak self] value in
            if let value {
                self?.activityCallback(value)
            }
        }
        self.processReader = ProcessReader(.disk) { [weak self] value in
            if let list = value {
                self?.popupView.processCallback(list)
            }
        }
        
        self.popupView.refreshCallback = { [weak self] uuid in
            self?.capacityReader?.resetPurgableSpace(for: uuid)
            self?.capacityReader?.read()
        }
        
        self.selectedDisk = Store.shared.string(key: "\(ModuleType.disk.stringValue)_disk", defaultValue: self.selectedDisk)
        
        self.settingsView.selectedDiskHandler = { [weak self] value in
            self?.selectedDisk = value
            self?.capacityReader?.read()
        }
        self.settingsView.callback = { [weak self] in
            self?.capacityReader?.read()
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.capacityReader?.setInterval(value)
            self?.activityReader?.setInterval(value)
        }
        let processReader = self.processReader
        self.settingsView.callbackWhenUpdateNumberOfProcesses = { [weak self] in
            self?.popupView.numberOfProcessesUpdated()
            Task {
                processReader?.read()
            }
        }
        
        self.setReaders([self.capacityReader, self.activityReader, self.processReader])
    }
    
    private func capacityCallback(_ value: Disks) {
        guard self.enabled else { return }
        
        Task { @MainActor in
            self.popupView.capacityCallback(value)
            self.previewView.capacityCallback(value)
            self.settingsView.setList(value)
            
            guard let d = value.first(where: { $0.mediaName == self.selectedDisk }) ?? value.first(where: { $0.root }) else {
                return
            }
            
            self.portalView.utilizationCallback(d)
            self.notificationsView.utilizationCallback(d.percentage)
            
            self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
                switch w.item {
                case let widget as Mini:
                    var val = d.percentage
                    if self.selectedMiniSensor == "Read speed" {
                        val = Double(d.activity.read) / 1024 / 1024 / 100 // Normalized for visual
                    } else if self.selectedMiniSensor == "Write speed" {
                        val = Double(d.activity.write) / 1024 / 1024 / 100 // Normalized for visual
                    }
                    widget.setValue(val)
                case let widget as StackWidget:
                    var list: [Stack_t] = []
                    if self.selectedStackSensor == "Capacity" {
                        list.append(Stack_t(key: "used", value: DiskSize(d.size - d.free).getReadableMemory(), label: localizedString("Used")))
                        list.append(Stack_t(key: "free", value: DiskSize(d.free).getReadableMemory(), label: localizedString("Free")))
                    } else if self.selectedStackSensor == "Speed" {
                        list.append(Stack_t(key: "read", value: Units(bytes: d.activity.read).getReadableSpeed(), label: localizedString("Read")))
                        list.append(Stack_t(key: "write", value: Units(bytes: d.activity.write).getReadableSpeed(), label: localizedString("Write")))
                    }
                    widget.setValues(list)
                case let widget as BarChart: widget.setValue([[ColorValue(d.percentage)]])
                case let widget as MemoryWidget:
                    widget.setValue((DiskSize(d.free).getReadableMemory(), DiskSize(d.size - d.free).getReadableMemory()), usedPercentage: d.percentage)
                case let widget as PieChart:
                    widget.setValue([
                        ColorValue(d.percentage, color: NSColor.systemBlue)
                    ])
                case let widget as TextWidget:
                    var text = "\(self.textValue)"
                    let pairs = TextWidget.parseText(text)
                    pairs.forEach { pair in
                        var replacement: String? = nil
                        
                        switch pair.key {
                        case "$capacity":
                            switch pair.value {
                            case "total": replacement = DiskSize(d.size).getReadableMemory()
                            case "used": replacement = DiskSize(d.size - d.free).getReadableMemory()
                            case "free": replacement = DiskSize(d.free).getReadableMemory()
                            default: return
                            }
                        case "$percentage":
                            var percentage: Int
                            if d.size == 0 {
                                percentage = 0
                            } else {
                                switch pair.value {
                                case "used": 
                                    let ratio = d.size > 0 ? (Double(d.size - d.free) / Double(d.size)) : 0
                                    percentage = ratio.isFinite ? Int(ratio * 100) : 0
                                case "free": 
                                    let ratio = d.size > 0 ? (Double(d.free) / Double(d.size)) : 0
                                    percentage = ratio.isFinite ? Int(ratio * 100) : 0
                                default: return
                                }
                            }
                            replacement = "\(percentage < 0 ? 0 : percentage)%"
                        default: return
                        }
                        
                        if let replacement {
                            let key = pair.value.isEmpty ? pair.key : "\(pair.key).\(pair.value)"
                            text = text.replacingOccurrences(of: key, with: replacement)
                        }
                    }
                    widget.setValue(text)
                default: break
                }
            }
            
            if self.systemWidgetsUpdatesState {
                if isWidgetActive(self.userDefaults, [Disk_entry.kind, "UnitedWidget"]), let blobData = try? JSONEncoder().encode(d) {
                    let key = "Disk@CapacityReader"
                    if self.userDefaults?.data(forKey: key) != blobData {
                        self.userDefaults?.set(blobData, forKey: key)
                        WidgetCenter.shared.reloadTimelines(ofKind: Disk_entry.kind)
                        WidgetCenter.shared.reloadTimelines(ofKind: "UnitedWidget")
                    }
                }
            }
        }
    }
    
    private func activityCallback(_ value: Disks) {
        guard self.enabled else { return }
        
        Task { @MainActor in
            self.popupView.activityCallback(value)
            self.previewView.activityCallback(value)
            
            guard let d = value.first(where: { $0.mediaName == self.selectedDisk }) ?? value.first(where: { $0.root }) else {
                return
            }
            
            self.portalView.activityCallback(d)
            
            self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
                switch w.item {
                case let widget as SpeedWidget: 
                    widget.setValue(input: d.activity.read, output: d.activity.write)
                case let widget as NetworkChart:
                    widget.setValue(upload: Double(d.activity.write), download: Double(d.activity.read))
                default: break
                }
            }
        }
    }
}
