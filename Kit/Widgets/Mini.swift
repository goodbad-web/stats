//
//  Mini.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 10/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

public class Mini: WidgetWrapper, WidgetConfigurable {
    private var labelState: Bool = true
    private var colorState: SColor = .monochrome
    private var alignmentState: String = "left"
    
    private var colors: [SColor] = SColor.allCases
    
    private var _value: Double = 0
    private var _pressureLevel: RAMPressure = .normal
    private var _colorZones: colorZones = (0.6, 0.8)
    private var _suffix: String = "%"
    
    private var defaultLabel: String
    private var _label: String
    public lazy var widgetConfiguration: WidgetSettingsConfiguration = MiniWidgetConfiguration(widget: self)
    
    private var width: CGFloat {
        (self.labelState ? 31 : 36) + (2*Constants.Widget.margin.x)
    }
    
    private var alignment: NSTextAlignment {
        if let alignmentPair = Alignments.first(where: { $0.key == self.alignmentState }) {
            return alignmentPair.additional as? NSTextAlignment ?? .left
        }
        return .left
    }
    
    public init(title: String, config: WidgetConfig? = nil, preview: Bool = false) {
        var widgetTitle: String = title
        if let config {
            if preview, let previewConfig = config.section("Preview"), let value = previewConfig.string("Value") {
                self._value = Double(value) ?? 0
            }
            
            if let titleFromConfig = config.string("Title") {
                widgetTitle = titleFromConfig
            }
            if let label = config.bool("Label") {
                self.labelState = label
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
        
        self.defaultLabel = widgetTitle
        self._label = widgetTitle
        super.init(.mini, title: widgetTitle, frame: CGRect(
            x: 0,
            y: Constants.Widget.margin.y,
            width: Constants.Widget.width + (2*Constants.Widget.margin.x),
            height: Constants.Widget.height - (2*Constants.Widget.margin.y)
        ))
        
        self.canDrawConcurrently = true
        
        if !preview {
            self.colorState = SColor.fromString(Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_color", defaultValue: self.colorState.key))
            self.labelState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_label", defaultValue: self.labelState)
            self.alignmentState = Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_alignment", defaultValue: self.alignmentState)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        var value: Double = 0
        var pressureLevel: RAMPressure = .normal
        var colorZones: colorZones = (0.6, 0.8)
        var label: String = ""
        var suffix: String = ""
        self.queue.sync {
            value = self._value
            pressureLevel = self._pressureLevel
            colorZones = self._colorZones
            label = self._label
            suffix = self._suffix
        }
        
        let valueSize: CGFloat = self.labelState ? 12 : 14
        var origin: CGPoint = CGPoint(x: Constants.Widget.margin.x, y: (Constants.Widget.height-valueSize)/2)
        let style = NSMutableParagraphStyle()
        style.alignment = self.labelState ? self.alignment : .center
        
        if self.labelState {
            let style = NSMutableParagraphStyle()
            style.alignment = self.alignment
            
            let stringAttributes = [
                NSAttributedString.Key.font: NSFont.systemFont(ofSize: 7, weight: .light),
                NSAttributedString.Key.foregroundColor: isDarkMode ? NSColor.white : NSColor.textColor,
                NSAttributedString.Key.paragraphStyle: style
            ]
            let rect = CGRect(x: origin.x, y: 12, width: self.width - (Constants.Widget.margin.x*2), height: 7)
            let str = NSAttributedString.init(string: label, attributes: stringAttributes)
            str.draw(with: rect)
            
            origin.y = 1
        }
        
        var color: NSColor = .controlAccentColor
        switch self.colorState {
        case .systemAccent: color = .controlAccentColor
        case .utilization: color = value.usageColor(zones: colorZones, reversed: self.title == "BAT")
        case .pressure: color = pressureLevel.pressureColor()
        case .monochrome: color = (isDarkMode ? NSColor.white : NSColor.black)
        default: color = self.colorState.additional as? NSColor ?? .controlAccentColor
        }
        
        let stringAttributes = [
            NSAttributedString.Key.font: NSFont.systemFont(ofSize: valueSize, weight: .regular),
            NSAttributedString.Key.foregroundColor: color,
            NSAttributedString.Key.paragraphStyle: style
        ]
        let rect = CGRect(x: origin.x, y: origin.y, width: self.width - (Constants.Widget.margin.x*2), height: valueSize+1)
        let val = value.isFinite ? Int(value.rounded(toPlaces: 2) * 100) : 0
        let str = NSAttributedString.init(string: "\(val)\(suffix)", attributes: stringAttributes)
        str.draw(with: rect)
        
        self.setWidth(width)
    }
    
    public func setValue(_ newValue: Double) {
        guard self._value != newValue else { return }
        self._value = newValue
        DispatchQueue.main.async(execute: {
            self.display()
        })
    }
    
    public func setPressure(_ newPressureLevel: RAMPressure) {
        guard self._pressureLevel != newPressureLevel else { return }
        self._pressureLevel = newPressureLevel
        DispatchQueue.main.async(execute: {
            self.needsDisplay = true
        })
    }
    
    public func setTitle(_ newTitle: String?) {
        var title = self.defaultLabel
        if let new = newTitle {
            title = new
        }
        guard self._label != title else { return }
        self._label = title
        DispatchQueue.main.async(execute: {
            self.needsDisplay = true
        })
    }
    
    public func setColorZones(_ newColorZones: colorZones) {
        guard self._colorZones != newColorZones else { return }
        self._colorZones = newColorZones
        DispatchQueue.main.async(execute: {
            self.display()
        })
    }
    
    public func setSuffix(_ newSuffix: String) {
        guard self._suffix != newSuffix else { return }
        self._suffix = newSuffix
        DispatchQueue.main.async(execute: {
            self.display()
        })
    }

    fileprivate func availableColors() -> [SColor] {
        self.colors
    }

    fileprivate func configurationState() -> (label: Bool, color: SColor, alignment: String) {
        (self.labelState, self.colorState, self.alignmentState)
    }

    fileprivate func applyConfigurationState(label: Bool? = nil, color: SColor? = nil, alignment: String? = nil) {
        if let label {
            self.labelState = label
        }
        if let color {
            self.colorState = color
        }
        if let alignment {
            self.alignmentState = alignment
        }
        self.display()
    }
    
    // MARK: - Settings
    
    public override func settings() -> NSView {
        self.widgetConfiguration.settingsView()
    }
}

private final class MiniWidgetConfiguration: BaseWidgetConfiguration {
    private weak var widget: Mini?

    init(widget: Mini) {
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
        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Label"), component: switchView(
                action: #selector(self.toggleLabel),
                state: state.label
            )),
            PreferencesRow(localizedString("Color"), component: selectView(
                action: #selector(self.toggleColor),
                items: widget.availableColors(),
                selected: state.color.key
            )),
            PreferencesRow(localizedString("Alignment"), component: selectView(
                action: #selector(self.toggleAlignment),
                items: Alignments,
                selected: state.alignment
            ))
        ]))
        return view
    }

    @objc private func toggleColor(_ sender: NSMenuItem) {
        guard let widget,
              let key = sender.representedObject as? String,
              let newColor = SColor.allCases.first(where: { $0.key == key }) else { return }
        self.writeString("color", value: key)
        widget.applyConfigurationState(color: newColor)
    }

    @objc private func toggleLabel(_ sender: NSControl) {
        guard let widget else { return }
        let value = controlState(sender)
        self.writeBool("label", value: value)
        widget.applyConfigurationState(label: value)
    }

    @objc private func toggleAlignment(_ sender: NSMenuItem) {
        guard let widget,
              let key = sender.representedObject as? String,
              Alignments.first(where: { $0.key == key }) != nil else { return }
        self.writeString("alignment", value: key)
        widget.applyConfigurationState(alignment: key)
    }
}
