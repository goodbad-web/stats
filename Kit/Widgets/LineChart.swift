//
//  Chart.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 18/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

public class LineChart: WidgetWrapper, WidgetConfigurable {
    private var labelState: Bool = false
    private var boxState: Bool = true
    private var frameState: Bool = false
    private var valueState: Bool = false
    private var valueColorState: Bool = false
    private var colorState: SColor = .systemAccent
    private var historyCount: Int = 60
    private var scaleState: Scale = .none
    
    private var chart: LineChartView = LineChartView(frame: NSRect(
        x: 0,
        y: 0,
        width: 32,
        height: Constants.Widget.height - (2*Constants.Widget.margin.y)
    ), num: 60, useSwiftUI: false)
    private var colors: [SColor] = SColor.allCases.filter({ $0 != SColor.cluster })
    private var _value: Double = 0
    private var _pressureLevel: RAMPressure = .normal
    
    private var historyNumbers: [KeyValue_p] = [
        KeyValue_t(key: "30", value: "30"),
        KeyValue_t(key: "60", value: "60"),
        KeyValue_t(key: "90", value: "90"),
        KeyValue_t(key: "120", value: "120")
    ]
    private var width: CGFloat {
        get {
            switch self.historyCount {
            case 30:
                return 24
            case 60:
                return 32
            case 90:
                return 42
            case 120:
                return 52
            default:
                return 32
            }
        }
    }
    
    private var boxSettingsView: NSSwitch? = nil
    private var frameSettingsView: NSSwitch? = nil
    public lazy var widgetConfiguration: WidgetSettingsConfiguration = LineChartWidgetConfiguration(widget: self)
    
    public var NSLabelCharts: [NSAttributedString] = []
    
    public init(title: String, config: WidgetConfig? = nil, preview: Bool = false) {
        var widgetTitle: String = title
        if let config {
            if let titleFromConfig = config.string("Title") {
                widgetTitle = titleFromConfig
            }
            if let label = config.bool("Label") {
                self.labelState = label
            }
            if let box = config.bool("Box") {
                self.boxState = box
            }
            if let value = config.bool("Value") {
                self.valueState = value
            }
            if let unsupportedColors = config.stringArray("Unsupported colors") {
                self.colors = self.colors.filter{ !unsupportedColors.contains($0.key) }
            }
            if let color = config.string("Color") {
                if let defaultColor = colors.first(where: { "\($0.self)" == color }) {
                    self.colorState = defaultColor
                }
            }
        }
        
        super.init(.lineChart, title: widgetTitle, frame: CGRect(
            x: Constants.Widget.margin.x,
            y: Constants.Widget.margin.y,
            width: 32 + (Constants.Widget.margin.x*2),
            height: Constants.Widget.height - (2*Constants.Widget.margin.y)
        ))
        
        self.canDrawConcurrently = true
        
        if !preview {
            self.boxState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_box", defaultValue: self.boxState)
            self.frameState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_frame", defaultValue: self.frameState)
            self.valueState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_value", defaultValue: self.valueState)
            self.labelState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_label", defaultValue: self.labelState)
            self.valueColorState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_valueColor", defaultValue: self.valueColorState)
            self.colorState = SColor.fromString(Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_color", defaultValue: self.colorState.key))
            self.historyCount = Store.shared.int(key: "\(self.title)_\(self.type.rawValue)_historyCount", defaultValue: self.historyCount)
            self.scaleState = Scale.fromString(Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_scale", defaultValue: self.scaleState.key))
            
            self.chart.setScale(self.scaleState)
            self.chart.reinit(self.historyCount)
        }
        
        if self.labelState {
            self.setFrameSize(NSSize(width: Constants.Widget.width + 6 + (Constants.Widget.margin.x*2), height: self.frame.size.height))
        }
        
        if preview {
            var list: [DoubleValue] = []
            for _ in 0..<16 {
                list.append(DoubleValue(Double.random(in: 0..<1)))
            }
            self.chart.setPoints(list)
            self._value = 0.38
        }
        
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let stringAttributes = [
            NSAttributedString.Key.font: NSFont.systemFont(ofSize: 7, weight: .regular),
            NSAttributedString.Key.foregroundColor: NSColor.textColor,
            NSAttributedString.Key.paragraphStyle: style
        ]
        
        for char in String(self.title.prefix(3)).uppercased().reversed() {
            let str = NSAttributedString.init(string: "\(char)", attributes: stringAttributes)
            self.NSLabelCharts.append(str)
        }
        
        self.addSubview(self.chart)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        var value: Double = 0
        var pressureLevel: RAMPressure = .normal
        self.queue.sync {
            value = self._value
            pressureLevel = self._pressureLevel
        }
        
        var width = self.width + (Constants.Widget.margin.x*2)
        var x: CGFloat = 0
        let lineWidth = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
        let offset = lineWidth / 2
        var boxSize: CGSize = CGSize(width: self.width - (Constants.Widget.margin.x*2), height: self.frame.size.height)
        
        var color: NSColor = .controlAccentColor
        switch self.colorState {
        case .systemAccent: color = .controlAccentColor
        case .utilization: color = value.usageColor()
        case .pressure: color = pressureLevel.pressureColor()
        case .monochrome:
            if self.boxState {
                color = (isDarkMode ? NSColor.black : NSColor.white)
            } else {
                color = (isDarkMode ? NSColor.white : NSColor.black)
            }
        default: color = self.colorState.additional as? NSColor ?? .controlAccentColor
        }
        
        if self.labelState {
            let letterHeight = self.frame.height / 3
            let letterWidth: CGFloat = 6.0
            
            var yMargin: CGFloat = 0
            for char in self.NSLabelCharts {
                let rect = CGRect(x: x, y: yMargin, width: letterWidth, height: letterHeight)
                char.draw(with: rect)
                yMargin += letterHeight
            }
            
            width += letterWidth + Constants.Widget.spacing
            x = letterWidth + Constants.Widget.spacing
        }
        
        if self.valueState {
            let style = NSMutableParagraphStyle()
            style.alignment = .right
            
            var valueColor = isDarkMode ? NSColor.white : NSColor.black
            if self.valueColorState {
                valueColor = color
            }
            
            let stringAttributes = [
                NSAttributedString.Key.font: NSFont.systemFont(ofSize: 8, weight: .regular),
                NSAttributedString.Key.foregroundColor: valueColor,
                NSAttributedString.Key.paragraphStyle: style
            ]
            
            let rect = CGRect(x: x+2, y: boxSize.height-7, width: boxSize.width - 2, height: 7)
            let val = value.isFinite ? Int((value.rounded(toPlaces: 2)) * 100) : 0
            let str = NSAttributedString.init(string: "\(val)%", attributes: stringAttributes)
            str.draw(with: rect)
            
            boxSize.height = offset == 0.5 ? 10 : 9
        }
        
        let box = NSBezierPath(roundedRect: NSRect(
            x: x+offset,
            y: offset,
            width: self.width - offset*2,
            height: boxSize.height - (offset*2)
        ), xRadius: 2, yRadius: 2)
        
        if self.boxState {
            (isDarkMode ? NSColor.white : NSColor.black).set()
            box.stroke()
            box.fill()
            self.chart.setTransparent(false)
        } else if self.frameState {
            self.chart.setTransparent(true)
        } else {
            self.chart.setTransparent(true)
        }

        context.saveGState()
        
        let chartFrame = NSRect(
            x: x+offset+lineWidth,
            y: offset,
            width: box.bounds.width - (offset*2+lineWidth),
            height: box.bounds.height - offset
        )
        self.chart.setColor(color)
        self.chart.frame = chartFrame
        
        context.restoreGState()
        
        if self.boxState || self.frameState {
            (isDarkMode ? NSColor.white : NSColor.black).set()
            box.lineWidth = lineWidth
            box.stroke()
        }
        
        self.setWidth(width)
    }
    
    public func setValue(_ newValue: Double) {
        guard newValue.isFinite else { return }
        DispatchQueue.main.async(execute: {
            self._value = newValue
            self.chart.addValue(newValue)
            self.needsDisplay = true
        })
    }
    
    public func setPressure(_ newPressureLevel: RAMPressure) {
        DispatchQueue.main.async(execute: {
            guard self._pressureLevel != newPressureLevel else { return }
            self._pressureLevel = newPressureLevel
            self.needsDisplay = true
        })
    }

    fileprivate func configurationState() -> (
        label: Bool,
        box: Bool,
        frame: Bool,
        value: Bool,
        valueColor: Bool,
        color: SColor,
        historyCount: Int,
        scale: Scale
    ) {
        (
            self.labelState,
            self.boxState,
            self.frameState,
            self.valueState,
            self.valueColorState,
            self.colorState,
            self.historyCount,
            self.scaleState
        )
    }

    fileprivate func configurationColors() -> [SColor] { self.colors }
    fileprivate func configurationHistoryNumbers() -> [KeyValue_p] { self.historyNumbers }

    fileprivate func applyConfiguration(
        label: Bool? = nil,
        box: Bool? = nil,
        frame: Bool? = nil,
        value: Bool? = nil,
        valueColor: Bool? = nil,
        color: SColor? = nil,
        historyCount: Int? = nil,
        scale: Scale? = nil
    ) {
        if let label { self.labelState = label }
        if let box { self.boxState = box }
        if let frame { self.frameState = frame }
        if let value { self.valueState = value }
        if let valueColor { self.valueColorState = valueColor }
        if let color { self.colorState = color }
        if let historyCount {
            self.historyCount = historyCount
            self.chart.reinit(historyCount)
        }
        if let scale {
            self.scaleState = scale
            self.chart.setScale(scale)
        }
        self.needsDisplay = true
    }
    
    // MARK: - Settings
    
    public override func settings() -> NSView {
        self.widgetConfiguration.settingsView()
    }
}

private final class LineChartWidgetConfiguration: BaseWidgetConfiguration {
    private weak var widget: LineChart?
    private weak var boxSettingsView: NSSwitch?
    private weak var frameSettingsView: NSSwitch?

    init(widget: LineChart) {
        self.widget = widget
        super.init(title: widget.title, type: widget.type)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func settingsView() -> NSView {
        guard let widget else { return NSView() }
        let state = widget.configurationState()
        let view = SettingsContainerView()

        let box = switchView(action: #selector(self.toggleBox), state: state.box)
        self.boxSettingsView = box
        let frame = switchView(action: #selector(self.toggleFrame), state: state.frame)
        self.frameSettingsView = frame

        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Label"), component: switchView(
                action: #selector(self.toggleLabel),
                state: state.label
            )),
            PreferencesRow(localizedString("Value"), component: switchView(
                action: #selector(self.toggleValue),
                state: state.value
            )),
            PreferencesRow(localizedString("Box"), component: box),
            PreferencesRow(localizedString("Frame"), component: frame),
            PreferencesRow(localizedString("Color"), component: selectView(
                action: #selector(self.toggleColor),
                items: widget.configurationColors(),
                selected: state.color.key
            )),
            PreferencesRow(localizedString("Colorize value"), component: switchView(
                action: #selector(self.toggleValueColor),
                state: state.valueColor
            )),
            PreferencesRow(localizedString("Number of reads in the chart"), component: selectView(
                action: #selector(self.toggleHistoryCount),
                items: widget.configurationHistoryNumbers(),
                selected: "\(state.historyCount)"
            )),
            PreferencesRow(localizedString("Scaling"), component: selectView(
                action: #selector(self.toggleScale),
                items: Scale.allCases.filter({ $0 != .fixed }),
                selected: state.scale.key
            ))
        ]))
        return view
    }

    @objc private func toggleLabel(_ sender: NSControl) {
        guard let widget else { return }
        let value = controlState(sender)
        self.writeBool("label", value: value)
        widget.applyConfiguration(label: value)
    }

    @objc private func toggleBox(_ sender: NSControl) {
        guard let widget else { return }
        let box = controlState(sender)
        var frame = widget.configurationState().frame
        self.writeBool("box", value: box)

        if frame {
            frame = false
            self.frameSettingsView?.state = .off
            self.writeBool("frame", value: frame)
        }
        widget.applyConfiguration(box: box, frame: frame)
    }

    @objc private func toggleFrame(_ sender: NSControl) {
        guard let widget else { return }
        let frame = controlState(sender)
        var box = widget.configurationState().box
        self.writeBool("frame", value: frame)

        if box {
            box = false
            self.boxSettingsView?.state = .off
            self.writeBool("box", value: box)
        }
        widget.applyConfiguration(box: box, frame: frame)
    }

    @objc private func toggleValue(_ sender: NSControl) {
        guard let widget else { return }
        let value = controlState(sender)
        self.writeBool("value", value: value)
        widget.applyConfiguration(value: value)
    }

    @objc private func toggleColor(_ sender: NSMenuItem) {
        guard let widget,
              let key = sender.representedObject as? String,
              let value = SColor.allCases.first(where: { $0.key == key }) else { return }
        self.writeString("color", value: key)
        widget.applyConfiguration(color: value)
    }

    @objc private func toggleValueColor(_ sender: NSControl) {
        guard let widget else { return }
        let value = controlState(sender)
        self.writeBool("valueColor", value: value)
        widget.applyConfiguration(valueColor: value)
    }

    @objc private func toggleHistoryCount(_ sender: NSMenuItem) {
        guard let widget,
              let key = sender.representedObject as? String,
              let value = Int(key) else { return }
        self.writeInt("historyCount", value: value)
        widget.applyConfiguration(historyCount: value)
    }

    @objc private func toggleScale(_ sender: NSMenuItem) {
        guard let widget,
              let key = sender.representedObject as? String,
              let value = Scale.allCases.first(where: { $0.key == key }) else { return }
        self.writeString("scale", value: key)
        widget.applyConfiguration(scale: value)
    }
}
