//
//  process.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 05/01/2024
//  Using Swift 5.0
//  Running on macOS 14.3
//
//  Copyright © 2024 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Darwin

// libproc.h definitions
// swiftlint:disable identifier_name
private let PROC_ALL_PIDS: UInt32 = 1
private let PROC_PIDTASKINFO: Int32 = 4
private let PROC_PIDPATHINFO_MAXSIZE: Int32 = 1024

private struct proc_taskinfo {
    var pti_virtual_size: UInt64 = 0
    var pti_resident_size: UInt64 = 0
    var pti_total_user: UInt64 = 0
    var pti_total_system: UInt64 = 0
    var pti_threads_user: UInt64 = 0
    var pti_threads_system: UInt64 = 0
    var pti_policy: Int32 = 0
    var pti_faults: Int32 = 0
    var pti_pageins: Int32 = 0
    var pti_cow_faults: Int32 = 0
    var pti_messages_sent: Int32 = 0
    var pti_messages_received: Int32 = 0
    var pti_syscalls_mach: Int32 = 0
    var pti_syscalls_unix: Int32 = 0
    var pti_csw: Int32 = 0
    var pti_threadnum: Int32 = 0
    var pti_numrunning: Int32 = 0
    var pti_priority: Int32 = 0
}
// swiftlint:enable identifier_name

@_silgen_name("proc_listpids")
private func proc_listpids(_ type: UInt32, _ typeinfo: UInt32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_pidinfo")
private func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_name")
private func proc_name(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: UInt32) -> Int32

public protocol Process_p {
    var pid: Int { get }
    var name: String { get }
    var icon: NSImage { get }
}

public typealias ProcessHeader = (title: String, color: NSColor?)

public class ProcessesView: NSStackView {
    public var count: Int {
        self.list.count
    }
    private var list: [ProcessView] = []
    private var colorViews: [ColorView] = []
    
    public init(frame: NSRect = .zero, values: [ProcessHeader], n: Int = 0) {
        super.init(frame: frame)
        
        self.orientation = .vertical
        self.spacing = 0
        
        let header = self.generateHeaderView(values)
        self.addArrangedSubview(header)
        
        for _ in 0..<n {
            let view = ProcessView(n: values.count)
            self.addArrangedSubview(view)
            self.list.append(view)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func generateHeaderView(_ values: [ProcessHeader]) -> NSView {
        let view = NSStackView()
        view.widthAnchor.constraint(equalToConstant: self.bounds.width).isActive = true
        view.heightAnchor.constraint(equalToConstant: ProcessView.height).isActive = true
        view.orientation = .horizontal
        view.distribution = .fill
        view.alignment = .centerY
        view.spacing = 0
        
        let iconView: NSImageView = NSImageView()
        iconView.widthAnchor.constraint(equalToConstant: ProcessView.height).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: ProcessView.height).isActive = true
        view.addArrangedSubview(iconView)
        
        let titleField = LabelField()
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.toolTip = localizedString("Process")
        titleField.stringValue = localizedString("Process")
        titleField.textColor = .tertiaryLabelColor
        titleField.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        view.addArrangedSubview(titleField)
        
        if values.count == 1, let v = values.first {
            let field = LabelField()
            field.cell?.truncatesLastVisibleLine = true
            field.toolTip = v.title
            field.stringValue = v.title
            field.alignment = .right
            field.textColor = .tertiaryLabelColor
            field.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            view.addArrangedSubview(field)
        } else {
            for v in values {
                if let color = v.color {
                    let container: NSView = NSView()
                    container.widthAnchor.constraint(equalToConstant: 60).isActive = true
                    container.heightAnchor.constraint(equalToConstant: ProcessView.height).isActive = true
                    let colorBlock: ColorView = ColorView(frame: NSRect(x: 48, y: 5, width: 12, height: 12), color: color, state: true, radius: 4)
                    colorBlock.toolTip = v.title
                    colorBlock.widthAnchor.constraint(equalToConstant: 12).isActive = true
                    colorBlock.heightAnchor.constraint(equalToConstant: 12).isActive = true
                    self.colorViews.append(colorBlock)
                    container.addSubview(colorBlock)
                    view.addArrangedSubview(container)
                }
            }
        }
        
        return view
    }
    
    public func setLock(_ newValue: Bool) {
        self.list.forEach{ $0.setLock(newValue) }
    }
    
    public func clear(_ symbol: String = "") {
        self.list.forEach{ $0.clear(symbol) }
    }
    
    public func set(_ idx: Int, _ process: Process_p, _ values: [String]) {
        if self.list.indices.contains(idx) {
            self.list[idx].set(process, values)
        }
    }
    
    public func setColor(_ idx: Int, _ newColor: NSColor) {
        if self.colorViews.indices.contains(idx) {
            self.colorViews[idx].setColor(newColor)
        }
    }
}

public class ProcessView: NSStackView {
    static let height: CGFloat = 22
    
    private var pid: Int? = nil
    private var lock: Bool = false
    
    private var imageView: NSImageView = NSImageView()
    private var killView: NSButton = NSButton()
    private var labelView: LabelField = {
        let view = LabelField()
        view.cell?.truncatesLastVisibleLine = true
        return view
    }()
    private var valueViews: [ValueField] = []
    
    public init(size: CGSize = CGSize(width: 264, height: 22), n: Int = 1) {
        var rect = NSRect(x: 2, y: 5, width: 12, height: 12)
        if size.height != 22 {
            rect = NSRect(x: 1, y: 3, width: 12, height: 12)
        }
        self.imageView = NSImageView(frame: rect)
        self.killView = NSButton(frame: rect)
        
        super.init(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        
        self.wantsLayer = true
        self.orientation = .horizontal
        self.distribution = .fill
        self.alignment = .centerY
        self.spacing = 0
        self.layer?.cornerRadius = 3
        
        let imageBox: NSView = {
            let view = NSView()
            
            self.killView.bezelStyle = .regularSquare
            self.killView.translatesAutoresizingMaskIntoConstraints = false
            self.killView.imageScaling = .scaleNone
            self.killView.image = Bundle(for: type(of: self)).image(forResource: "cancel") ?? NSImage(named: NSImage.stopProgressFreestandingTemplateName)
            self.killView.contentTintColor = .lightGray
            self.killView.isBordered = false
            self.killView.action = #selector(self.kill)
            self.killView.target = self
            self.killView.toolTip = localizedString("Kill process")
            self.killView.focusRingType = .none
            self.killView.isHidden = true
            
            view.addSubview(self.imageView)
            view.addSubview(self.killView)
            
            return view
        }()
        
        self.addArrangedSubview(imageBox)
        self.addArrangedSubview(self.labelView)
        self.valuesViews(n).forEach{ self.addArrangedSubview($0) }
        
        self.addTrackingArea(NSTrackingArea(
            rect: NSRect(x: 0, y: 0, width: self.frame.width, height: self.frame.height),
            options: [NSTrackingArea.Options.activeAlways, NSTrackingArea.Options.mouseEnteredAndExited, NSTrackingArea.Options.activeInActiveApp],
            owner: self,
            userInfo: nil
        ))
        
        NSLayoutConstraint.activate([
            imageBox.widthAnchor.constraint(equalToConstant: self.bounds.height),
            imageBox.heightAnchor.constraint(equalToConstant: self.bounds.height),
            self.labelView.heightAnchor.constraint(equalToConstant: 16),
            self.widthAnchor.constraint(equalToConstant: self.bounds.width),
            self.heightAnchor.constraint(equalToConstant: self.bounds.height)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func valuesViews(_ n: Int) -> [NSView] {
        var list: [ValueField] = []
        
        for _ in 0..<n {
            let view: ValueField = ValueField()
            view.widthAnchor.constraint(equalToConstant: 68).isActive = true
            if n != 1 {
                view.font = NSFont.systemFont(ofSize: 10, weight: .regular)
            }
            list.append(view)
        }
        
        self.valueViews = list
        return list
    }
    
    public override func mouseEntered(with: NSEvent) {
        if self.lock {
            self.imageView.isHidden = true
            self.killView.isHidden = false
            return
        }
        self.layer?.backgroundColor = .init(gray: 0.01, alpha: 0.05)
    }
    
    public override func mouseExited(with: NSEvent) {
        if self.lock {
            self.imageView.isHidden = false
            self.killView.isHidden = true
            return
        }
        self.layer?.backgroundColor = .none
    }
    
    public override func mouseDown(with: NSEvent) {
        self.setLock(!self.lock)
    }
    
    fileprivate func set(_ process: Process_p, _ values: [String]) {
        if self.lock && process.pid != self.pid { return }
        
        self.labelView.stringValue = process.name
        values.enumerated().forEach({ self.valueViews[$0.offset].stringValue = $0.element })
        self.imageView.image = process.icon
        self.pid = process.pid
        self.toolTip = "pid: \(process.pid)"
    }
    
    fileprivate func clear(_ symbol: String = "") {
        self.labelView.stringValue = symbol
        self.valueViews.forEach({ $0.stringValue = symbol })
        self.imageView.image = nil
        self.pid = nil
        self.setLock(false)
        self.toolTip = symbol
    }
    
    fileprivate func setLock(_ state: Bool) {
        self.lock = state
        if self.lock {
            self.imageView.isHidden = true
            self.killView.isHidden = false
            self.layer?.backgroundColor = .init(gray: 0.01, alpha: 0.1)
        } else {
            self.imageView.isHidden = false
            self.killView.isHidden = true
            self.layer?.backgroundColor = .none
        }
    }
    
    @objc private func kill() {
        if let pid = self.pid {
            Darwin.kill(pid_t(pid), SIGKILL)
            self.clear()
            self.setLock(false)
        }
    }
}

// MARK: - Process Monitor

public actor ProcessMonitor {
    public static let shared = ProcessMonitor()
    
    private var lastCPUUsage: [Int32: UInt64] = [:]
    private var lastTime: UInt64 = 0
    private var nameCache: [Int32: String] = [:]
    private var cache: [String: (time: Date, list: [TopProcess])] = [:]
    
    private init() {}
    
    public func getTopProcesses(limit: Int, category: String) async -> [TopProcess] {
        if let cached = self.cache[category], Date().timeIntervalSince(cached.time) < 2.0 && cached.list.count >= limit {
            return Array(cached.list.prefix(limit))
        }
        
        if category == "Power" {
            let list = await self.getTopByShell(limit: limit, category: category)
            self.cache[category] = (Date(), list)
            return list
        }
        
        let pidsCount = proc_listpids(PROC_ALL_PIDS, 0, nil, 0)
        var pids = [Int32](repeating: 0, count: Int(pidsCount))
        let actualCount = proc_listpids(PROC_ALL_PIDS, 0, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        
        var tempList: [(pid: Int32, usage: Double)] = []
        let now = mach_absolute_time()
        
        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)
        
        for i in 0..<Int(actualCount) / MemoryLayout<Int32>.size {
            let pid = pids[i]
            if pid <= 0 { continue }
            
            var taskInfo = proc_taskinfo()
            let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
            if result != MemoryLayout<proc_taskinfo>.size { continue }
            
            var usage: Double = 0
            if category == "CPU" {
                let totalTime = taskInfo.pti_total_user + taskInfo.pti_total_system
                if let last = self.lastCPUUsage[pid], self.lastTime > 0 {
                    let deltaTicks = totalTime - last
                    let deltaTime = now - self.lastTime
                    
                    let deltaTicksNS = Double(deltaTicks)
                    let deltaTimeNS = Double(deltaTime) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
                    
                    if deltaTimeNS > 1000 { // Guard against too small delta ( < 1 microsecond )
                        usage = (deltaTicksNS / deltaTimeNS) * 100.0
                    }
                }
                self.lastCPUUsage[pid] = totalTime
            } else if category == "RAM" {
                usage = Double(taskInfo.pti_resident_size)
            }
            
            if usage > 0 || category == "RAM" {
                tempList.append((pid: pid, usage: usage))
            }
        }
        
        self.lastTime = now
        
        tempList.sort { $0.usage > $1.usage }
        
        var list: [TopProcess] = []
        for item in tempList.prefix(limit) {
            list.append(TopProcess(pid: Int(item.pid), name: self.getName(item.pid), usage: item.usage))
        }
        
        // Periodically clear cache if it grows too large
        if self.nameCache.count > 1000 {
            self.nameCache.removeAll()
        }
        
        self.cache[category] = (Date(), list)
        return list
    }
    
    private func getName(_ pid: Int32) -> String {
        if let cached = self.nameCache[pid] {
            return cached
        }
        
        var buffer = [UInt8](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
        let result = proc_name(pid, &buffer, UInt32(PROC_PIDPATHINFO_MAXSIZE))
        var name = "Unknown"
        
        if result > 0 {
            name = String(cString: buffer)
        } else if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName {
            name = n
        }
        
        self.nameCache[pid] = name
        return name
    }
    
    private func getTopByShell(limit: Int, category: String) async -> [TopProcess] {
        return await Task.detached(priority: .userInitiated) {
            let task = Process()
            task.launchPath = "/usr/bin/top"
            task.arguments = ["-o", "power", "-l", "2", "-n", "\(limit)", "-stats", "pid,command,power"]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                return []
            }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            
            var list: [TopProcess] = []
            let samples = output.components(separatedBy: "PID")
            guard samples.count >= 2, let lastSample = samples.last else { return [] }
            
            lastSample.enumerateLines { (line, _) in
                if list.count >= limit { return }
                let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").filter{ !$0.isEmpty }
                if parts.count >= 3 {
                    let pid = Int(parts[0]) ?? 0
                    guard let usage = Double(parts.last!.filter("0123456789.".contains)) else { return }
                    let command = parts[1..<(parts.count - 1)].joined(separator: " ")
                    var name = command
                    if let app = NSRunningApplication(processIdentifier: pid_t(pid)), let n = app.localizedName {
                        name = n
                    }
                    list.append(TopProcess(pid: pid, name: name, usage: usage))
                }
            }
            return list
        }.value
    }
}
