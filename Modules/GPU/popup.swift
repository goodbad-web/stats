//
//  popup.swift
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

internal class Popup: PopupWrapper {
    public init() {
        super.init(ModuleType.GPU, frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))
        
        self.orientation = .vertical
        self.spacing = Constants.Popup.margins
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    internal func infoCallback(_ value: GPUs) {
        if self.arrangedSubviews.filter({ $0 is GPUView }).count != value.list.count {
            self.arrangedSubviews.forEach{ $0.removeFromSuperview() }
        }
        
        value.list.reversed().forEach { (gpu: GPU_Info) in
            if let view = self.arrangedSubviews.filter({ $0 is GPUView }).map({ $0 as! GPUView }).first(where: { $0.value.id == gpu.id }) {
                view.update(gpu)
            } else {
                self.addArrangedSubview(GPUView(
                    width: self.frame.width,
                    gpu: gpu,
                    callback: self.recalculateHeight
                ))
            }
        }
        
        self.recalculateHeight()
    }
    
    private func recalculateHeight() {
        let h = self.arrangedSubviews.map({ $0.bounds.height + self.spacing }).reduce(0, +) - self.spacing
        if self.frame.size.height != h && h >= 0 {
            self.setFrameSize(NSSize(width: self.frame.width, height: h))
            self.sizeCallback?(self.frame.size)
        }
    }
    
    public func numberOfProcessesUpdated() {
        self.arrangedSubviews.filter({ $0 is GPUView }).map({ $0 as! GPUView }).forEach { view in
            view.numberOfProcessesUpdated()
        }
    }
    
    // MARK: - Settings
    
    public override func settings() -> NSView? {
        let view = SettingsContainerView()
        
        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Keyboard shortcut"), component: KeyboardShartcutView(
                callback: self.setKeyboardShortcut,
                value: self.keyboardShortcut
            ))
        ]))
        
        return view
    }
}

private class GPUView: NSStackView {
    public var value: GPU_Info
    private var detailsView: GPUDetails
    private let circleSize: CGFloat = 50
    private let chartSize: CGFloat = 60
    
    private var stateView: NSView? = nil
    private var circleRow: NSStackView? = nil
    private var chartRow: NSStackView? = nil
    
    private var temperatureChart: LineChartView? = nil
    private var utilizationChart: LineChartView? = nil
    private var renderUtilizationChart: LineChartView? = nil
    private var tilerUtilizationChart: LineChartView? = nil
    private var aneUtilizationChart: LineChartView? = nil
    private var vramUtilizationChart: LineChartView? = nil
    private var gpuPowerChart: LineChartView? = nil
    private var gpuFrequencyChart: LineChartView? = nil
    
    private var maxPower: Double = 0
    private var maxFreq: Double = 0
    
    private var processes: ProcessesView? = nil
    public var sizeCallback: (() -> Void)
    
    open override var intrinsicContentSize: CGSize {
        return CGSize(width: self.bounds.width, height: self.bounds.height)
    }
    
    public init(width: CGFloat, gpu: GPU_Info, callback: @escaping (() -> Void)) {
        self.value = gpu
        self.detailsView = GPUDetails(width: width, value: gpu)
        self.sizeCallback = callback
        
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        
        self.orientation = .vertical
        self.alignment = .centerX
        self.distribution = .fill
        self.spacing = 0
        self.wantsLayer = true
        self.layer?.cornerRadius = 2
        
        self.addArrangedSubview(self.title())
        self.addArrangedSubview(self.stats())
        self.addArrangedSubview(self.initProcesses())
        self.addArrangedSubview(NSView())
        
        let h = self.arrangedSubviews.map({ $0.bounds.height }).reduce(0, +)
        self.setFrameSize(NSSize(width: self.frame.width, height: h))
        self.sizeCallback()
    }
    
    private func initProcesses() -> NSView {
        let numberOfProcesses = UserDefaultsSettingsStore.shared.int(
            AppSettingsKeys.moduleInt("GPU", "processes", defaultValue: 5)
        )
        if numberOfProcesses == 0 { return NSView() }
        
        let h: CGFloat = 22
        let height = (h*CGFloat(numberOfProcesses)) + Constants.Popup.separatorHeight + 22
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: height))
        let separator = separatorView(localizedString("Top processes"), origin: NSPoint(x: 0, y: height-Constants.Popup.separatorHeight), width: self.frame.width)
        let container: ProcessesView = ProcessesView(
            frame: NSRect(x: 0, y: 0, width: self.frame.width, height: separator.frame.origin.y),
            values: [(localizedString("Usage"), nil)],
            n: numberOfProcesses
        )
        self.processes = container
        
        view.addSubview(separator)
        view.addSubview(container)
        
        return view
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func updateLayer() {
        self.layer?.backgroundColor = (isDarkMode ? NSColor(red: 17/255, green: 17/255, blue: 17/255, alpha: 0.25) : NSColor(red: 245/255, green: 245/255, blue: 245/255, alpha: 1)).cgColor
    }
    
    private func title() -> NSView {
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 24))
        view.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true
        
        let width: CGFloat = self.value.model.widthOfString(usingFont: NSFont.systemFont(ofSize: 13, weight: .regular)) + 16
        let labelView: NSTextField = TextView(frame: NSRect(x: 0, y: (view.frame.height-16)/2, width: width - 8, height: 16))
        labelView.alignment = .center
        labelView.textColor = .secondaryLabelColor
        labelView.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        labelView.stringValue = self.value.model
        
        let stateView: NSView = NSView(frame: NSRect(x: width - 8, y: (view.frame.height-7)/2, width: 6, height: 6))
        stateView.wantsLayer = true
        stateView.layer?.backgroundColor = (self.value.state ? NSColor.systemGreen : NSColor.systemRed).cgColor
        stateView.toolTip = localizedString("GPU \(self.value.state ? "enabled" : "disabled")")
        stateView.layer?.cornerRadius = 4
        
        let details = localizedString("Details").uppercased()
        let w = details.widthOfString(usingFont: NSFont.systemFont(ofSize: 9, weight: .regular)) + 8
        let button = NSButtonWithPadding()
        button.frame = CGRect(x: view.frame.width - w, y: 2, width: w, height: view.frame.height-2)
        button.verticalPadding = 9
        button.bezelStyle = .regularSquare
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.action = #selector(self.showDetails)
        button.target = self
        button.toolTip = localizedString("Details")
        button.title = details
        button.font = NSFont.systemFont(ofSize: 9, weight: .regular)
        
        view.addSubview(labelView)
        view.addSubview(stateView)
        view.addSubview(button)
        self.stateView = stateView
        
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            button.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            button.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            button.widthAnchor.constraint(equalToConstant: w)
        ])
        
        return view
    }
    
    private func stats() -> NSView {
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 0))
        let container: NSStackView = NSStackView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 0))
        container.orientation = .vertical
        container.spacing = 0
        
        let circles: NSStackView = NSStackView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 0))
        circles.orientation = .horizontal
        circles.distribution = .fillEqually
        circles.alignment = .bottom
        self.circleRow = circles
        
        let charts: NSStackView = NSStackView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 0))
        charts.orientation = .horizontal
        charts.distribution = .fillEqually
        self.chartRow = charts
        
        self.addStats(id: "GPU temperature", self.value.temperature)
        self.addStats(id: "GPU utilization", self.value.utilization)
        self.addStats(id: "Render utilization", self.value.renderUtilization)
        self.addStats(id: "Tiler utilization", self.value.tilerUtilization)
        self.addStats(id: "ANE utilization", self.value.aneUtilization)
        self.addStats(id: "VRAM utilization", self.value.vramUsed)
        self.addStats(id: "GPU power", self.value.gpuPower)
        self.addStats(id: "GPU frequency", self.value.coreClock != nil ? Double(self.value.coreClock!) : nil)
        
        container.addArrangedSubview(circles)
        container.addArrangedSubview(charts)
        
        view.addSubview(container)
        
        let h = container.arrangedSubviews.map({ $0.bounds.height }).reduce(0, +)
        view.setFrameSize(NSSize(width: self.frame.width, height: h))
        container.setFrameSize(NSSize(width: self.frame.width, height: view.bounds.height))
        view.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true
        container.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true
        
        return view
    }
    
    private func addStats(id: String, _ val: Double? = nil) {
        guard let value = val else { return }
        
        var circle: PieChartView
        var chart: LineChartView
        
        if let view = self.circleRow?.arrangedSubviews.filter({ $0 is PieChartView }).first(where: { ($0 as! PieChartView).id == id }) {
            circle = view as! PieChartView
        } else {
            circle = PieChartView(frame: NSRect(x: 0, y: 0, width: circleSize, height: circleSize), openCircle: true)
            circle.id = id
            circle.toolTip = localizedString(id)
            if let row = self.circleRow {
                row.setFrameSize(NSSize(width: row.frame.width, height: self.circleSize + 20))
                row.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 0, right: 10)
                row.heightAnchor.constraint(equalToConstant: row.bounds.height).isActive = true
                row.addArrangedSubview(circle)
            }
        }
        
        if let view = self.chartRow?.arrangedSubviews.filter({ $0 is LineChartView }).first(where: { ($0 as! LineChartView).id == id }) {
            chart = view as! LineChartView
        } else {
            chart = LineChartView(frame: NSRect(x: 0, y: 0, width: 100, height: self.chartSize), num: 120)
            chart.setTooltipEnabled(false)
            chart.wantsLayer = true
            chart.layer?.backgroundColor = NSColor.lightGray.withAlphaComponent(0.1).cgColor
            chart.layer?.cornerRadius = 3
            chart.id = id
            chart.toolTip = localizedString(id)
            if let row = self.chartRow {
                row.setFrameSize(NSSize(width: row.frame.width, height: self.chartSize + 20))
                row.spacing = Constants.Popup.margins
                row.edgeInsets = NSEdgeInsets(
                    top: Constants.Popup.margins,
                    left: Constants.Popup.margins,
                    bottom: Constants.Popup.margins,
                    right: Constants.Popup.margins
                )
                row.heightAnchor.constraint(equalToConstant: row.bounds.height).isActive = true
                row.addArrangedSubview(chart)
            }
        }
        
        if id == "GPU temperature" {
            circle.setValue(value)
            circle.setText(temperature(value))
            circle.toolTip = "\(localizedString(id)): \(temperature(value))"
            chart.setSuffix(UnitTemperature.current.symbol)
            
            if self.temperatureChart == nil {
                self.temperatureChart = chart
            }
        } else if id == "GPU utilization" {
            circle.setValue(value)
            circle.setText("\(Int(value.isFinite ? value*100 : 0))%")
            circle.toolTip = "\(localizedString(id)): \(Int(value.isFinite ? value*100 : 0))%"
            
            if self.utilizationChart == nil {
                self.utilizationChart = chart
            }
        } else if id == "Render utilization" {
            circle.setValue(value)
            circle.setText("\(Int(value.isFinite ? value*100 : 0))%")
            circle.toolTip = "\(localizedString(id)): \(Int(value.isFinite ? value*100 : 0))%"
            
            if self.renderUtilizationChart == nil {
                self.renderUtilizationChart = chart
            }
        } else if id == "Tiler utilization" {
            circle.setValue(value)
            circle.setText("\(Int(value.isFinite ? value*100 : 0))%")
            circle.toolTip = "\(localizedString(id)): \(Int(value.isFinite ? value*100 : 0))%"
            
            if self.tilerUtilizationChart == nil {
                self.tilerUtilizationChart = chart
            }
        } else if id == "ANE utilization" {
            circle.setValue(value)
            circle.setText("\(Int(value.isFinite ? value*100 : 0))%")
            circle.toolTip = "\(localizedString(id)): \(Int(value.isFinite ? value*100 : 0))%"
            
            if self.aneUtilizationChart == nil {
                self.aneUtilizationChart = chart
            }
        } else if id == "VRAM utilization" {
            circle.setValue(value)
            circle.setText("\(Int(value.isFinite ? value*100 : 0))%")
            circle.toolTip = "\(localizedString(id)): \(Int(value.isFinite ? value*100 : 0))%"
            
            if self.vramUtilizationChart == nil {
                self.vramUtilizationChart = chart
            }
        } else if id == "GPU power" {
            if value > self.maxPower { self.maxPower = value }
            circle.setValue(self.maxPower > 0 ? value / self.maxPower : 0)
            circle.setText(String(format: "%.1fW", value))
            circle.toolTip = "\(localizedString(id)): \(String(format: "%.2fW", value))"
            chart.setSuffix("W")
            
            if self.gpuPowerChart == nil {
                self.gpuPowerChart = chart
            }
        } else if id == "GPU frequency" {
            if value > self.maxFreq { self.maxFreq = value }
            circle.setValue(self.maxFreq > 0 ? value / self.maxFreq : 0)
            circle.setText(value >= 1000 ? String(format: "%.1fG", value/1000) : "\(Int(value))M")
            circle.toolTip = "\(localizedString(id)): \(Int(value)) MHz"
            chart.setSuffix("MHz")
            
            if self.gpuFrequencyChart == nil {
                self.gpuFrequencyChart = chart
            }
        }
    }
    
    public func update(_ gpu: GPU_Info) {
        self.detailsView.update(gpu)
        
        if self.window?.isVisible ?? false {
            self.stateView?.layer?.backgroundColor = (gpu.state ? NSColor.systemGreen : NSColor.systemRed).cgColor
            self.stateView?.toolTip = localizedString("GPU \(gpu.state ? "enabled" : "disabled")")
            
            self.addStats(id: "GPU temperature", gpu.temperature)
            self.addStats(id: "GPU utilization", gpu.utilization)
            self.addStats(id: "Render utilization", gpu.renderUtilization)
            self.addStats(id: "Tiler utilization", gpu.tilerUtilization)
            self.addStats(id: "ANE utilization", gpu.aneUtilization)
            self.addStats(id: "VRAM utilization", gpu.vramUsed)
            self.addStats(id: "GPU power", gpu.gpuPower)
            self.addStats(id: "GPU frequency", gpu.coreClock != nil ? Double(gpu.coreClock!) : nil)
            
            for i in 0..<gpu.topProcesses.count where i < (self.processes?.count ?? 0) {
                let process = gpu.topProcesses[i]
                self.processes?.set(i, process, [String(format: "%.1f%%", process.usage)])
            }
        }
        
        if let value = gpu.temperature {
            if let temp = Double(temperature(value).replacingOccurrences(of: "C", with: "").replacingOccurrences(of: "F", with: "").digits) {
                self.temperatureChart?.addValue(temp/100)
            } else {
                self.temperatureChart?.addValue(value)
            }
        }
        if let value = gpu.utilization {
            self.utilizationChart?.addValue(value)
        }
        if let value = gpu.renderUtilization {
            self.renderUtilizationChart?.addValue(value)
        }
        if let value = gpu.tilerUtilization {
            self.tilerUtilizationChart?.addValue(value)
        }
        if let value = gpu.aneUtilization {
            self.aneUtilizationChart?.addValue(value)
        }
        if let value = gpu.vramUsed {
            self.vramUtilizationChart?.addValue(value)
        }
        if let value = gpu.gpuPower {
            if value > self.maxPower { self.maxPower = value }
            self.gpuPowerChart?.addValue(self.maxPower > 0 ? value / self.maxPower : 0)
        }
        if let value = gpu.coreClock {
            let v = Double(value)
            if v > self.maxFreq { self.maxFreq = v }
            self.gpuFrequencyChart?.addValue(self.maxFreq > 0 ? v / self.maxFreq : 0)
        }
    }
    
    @objc private func showDetails() {
        if let view = self.arrangedSubviews.first(where: { $0 is GPUDetails }) {
            view.removeFromSuperview()
        } else {
            self.insertArrangedSubview(self.detailsView, at: 1)
        }
        
        self.setFrameSize(NSSize(
            width: self.frame.width,
            height: self.arrangedSubviews.map({ $0.bounds.height + self.spacing }).reduce(0, +)
        ))
        self.sizeCallback()
    }
    
    public func numberOfProcessesUpdated() {
        self.arrangedSubviews.forEach { v in
            if v.subviews.contains(where: { $0 is ProcessesView }) {
                v.removeFromSuperview()
            }
        }
        self.insertArrangedSubview(self.initProcesses(), at: 2)
        
        let h = self.arrangedSubviews.map({ $0.bounds.height }).reduce(0, +)
        self.setFrameSize(NSSize(width: self.frame.width, height: h))
        self.sizeCallback()
    }
}

private class GPUDetails: NSView {
    private var status: NSTextField? = nil
    private var fanSpeed: NSTextField? = nil
    private var coreClock: NSTextField? = nil
    private var memoryClock: NSTextField? = nil
    private var temperature: NSTextField? = nil
    private var utilization: NSTextField? = nil
    private var renderUtilization: NSTextField? = nil
    private var tilerUtilization: NSTextField? = nil
    private var aneUtilization: NSTextField? = nil
    private var fps: NSTextField? = nil
    
    open override var intrinsicContentSize: CGSize {
        return CGSize(width: self.bounds.width, height: self.bounds.height)
    }
    
    init(width: CGFloat, value: GPU_Info) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        
        let grid: NSGridView = NSGridView(frame: NSRect(
            x: Constants.Popup.margins, y: Constants.Popup.margins,
            width: self.frame.width - (Constants.Popup.margins*2), height: 0
        ))
        grid.yPlacement = .center
        grid.xPlacement = .leading
        grid.rowSpacing = 0
        grid.columnSpacing = 0
        
        var num: CGFloat = 2
        
        if let value = value.vendor {
            grid.addRow(with: keyValueRow("\(localizedString("Vendor")):", value))
            num += 1
        }
        
        grid.addRow(with: keyValueRow("\(localizedString("Model")):", value.model))
        
        if let value = value.cores {
            let arr = keyValueRow("\(localizedString("Cores")):", "\(value)")
            grid.addRow(with: arr)
            num += 1
        }
        
        let state: String = value.state ? localizedString("Active") : localizedString("Non active")
        let arr = keyValueRow("\(localizedString("Status")):", state)
        self.status = arr.last
        grid.addRow(with: arr)
        
        if let value = value.fanSpeed {
            let arr = keyValueRow("\(localizedString("Fan speed")):", "\(value)%")
            self.fanSpeed = arr.last
            grid.addRow(with: arr)
            num += 1
        }
        if let value = value.coreClock {
            let arr = keyValueRow("\(localizedString("Core clock")):", "\(value)MHz")
            self.coreClock = arr.last
            grid.addRow(with: arr)
            num += 1
        }
        if let value = value.memoryClock {
            let arr = keyValueRow("\(localizedString("Memory clock")):", "\(value)MHz")
            self.memoryClock = arr.last
            grid.addRow(with: arr)
            num += 1
        }
        
        if let value = value.temperature {
            let arr = keyValueRow("\(localizedString("Temperature")):", Kit.temperature(Double(value)))
            self.temperature = arr.last
            grid.addRow(with: arr)
            num += 1
        }
        if let value = value.utilization {
            let arr = keyValueRow("\(localizedString("Utilization")):", "\(Int(value.isFinite ? value*100 : 0))%")
            self.utilization = arr.last
            grid.addRow(with: arr)
            num += 1
        }
        if let value = value.renderUtilization {
            let arr = keyValueRow("\(localizedString("Render utilization")):", "\(Int(value.isFinite ? value*100 : 0))%")
            self.renderUtilization = arr.last
            grid.addRow(with: arr)
            num += 1
        }
        if let value = value.tilerUtilization {
            let arr = keyValueRow("\(localizedString("Tiler utilization")):", "\(Int(value.isFinite ? value*100 : 0))%")
            self.tilerUtilization = arr.last
            grid.addRow(with: arr)
            num += 1
        }
        if let value = value.aneUtilization {
            let arr = keyValueRow("\(localizedString("ANE utilization")):", "\(Int(value.isFinite ? value*100 : 0))%")
            self.aneUtilization = arr.last
            grid.addRow(with: arr)
            num += 1
        }
        if let value = value.fps {
            let arr = keyValueRow("\(localizedString("FPS")):", "\(Int(value.rounded()))")
            self.fps = arr.last
            grid.addRow(with: arr)
            num += 1
        }
        
        self.setFrameSize(NSSize(width: self.frame.width, height: (16 * num) + Constants.Popup.margins))
        grid.setFrameSize(NSSize(width: grid.frame.width, height: self.frame.height - Constants.Popup.margins))
        self.addSubview(grid)
        
        self.heightAnchor.constraint(equalToConstant: self.frame.height).isActive = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func keyValueRow(_ key: String, _ value: String) -> [NSTextField] {
        return [
            LabelField(frame: NSRect(x: 0, y: 0, width: 0, height: 16), key),
            ValueField(frame: NSRect(x: 0, y: 0, width: 0, height: 16), value)
        ]
    }
    
    public func update(_ gpu: GPU_Info) {
        self.status?.stringValue = gpu.state ? localizedString("Active") : localizedString("Non active")
        
        if let value = gpu.fanSpeed {
            self.fanSpeed?.stringValue = "\(value)%"
        }
        if let value = gpu.coreClock {
            self.coreClock?.stringValue = "\(value)MHz"
        }
        if let value = gpu.memoryClock {
            self.memoryClock?.stringValue = "\(value)MHz"
        }
        
        if let value = gpu.temperature {
            self.temperature?.stringValue = Kit.temperature(Double(value))
        }
        if let value = gpu.utilization {
            self.utilization?.stringValue = "\(Int(value.isFinite ? value*100 : 0))%"
        }
        if let value = gpu.renderUtilization {
            self.renderUtilization?.stringValue = "\(Int(value.isFinite ? value*100 : 0))%"
        }
        if let value = gpu.tilerUtilization {
            self.tilerUtilization?.stringValue = "\(Int(value.isFinite ? value*100 : 0))%"
        }
        if let value = gpu.aneUtilization {
            self.aneUtilization?.stringValue = "\(Int(value.isFinite ? value*100 : 0))%"
        }
        if let value = gpu.fps {
            self.fps?.stringValue = "\(Int(value.rounded()))"
        }
    }
}
