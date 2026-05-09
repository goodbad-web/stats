//
//  Speed.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 24/05/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

private struct SpeedDisplayState: Equatable {
    let inputText: String
    let outputText: String
    let inputActive: Bool
    let outputActive: Bool
    let valueState: Bool
    let unitsState: Bool
    let icon: String
    let monochromeState: Bool
    let valueColorState: String
    let iconColorState: String
    let inputColorState: String
    let outputColorState: String
    let modeState: String
    let displayValueState: String
}

public class SpeedWidget: WidgetWrapper, WidgetConfigurable {
    private var icon: String = "dots"
    private var valueState: Bool = true
    private var unitsState: Bool = true
    private var monochromeState: Bool = false
    private var valueColorState: String = "none"
    private var iconColorState: String = "default"
    private var valueAlignmentState: String = "right"
    private var modeState: String = "twoRows"
    private var iconAlignmentState: String = "left"
    private var displayValueState: String = "oi"
    
    private var inputColorState: SColor = .secondBlue
    private var outputColorState: SColor = .secondRed
    
    private var symbols: (input: String, output: String) = ("I", "O")
    private var words: (input: String, output: String) = ("Input", "Output")
    
    private var inputValue: Int64 = 0
    private var outputValue: Int64 = 0
    private var renderedState: SpeedDisplayState?
    
    private var width: CGFloat = 58
    
    private var valueColorView: NSPopUpButton? = nil
    private var valueAlignmentView: NSPopUpButton? = nil
    private var iconAlignmentView: NSPopUpButton? = nil
    private var iconColorView: NSPopUpButton? = nil
    private var displayModeView: NSPopUpButton? = nil
    public lazy var widgetConfiguration: WidgetSettingsConfiguration = SpeedWidgetConfiguration(widget: self)
    
    private var inputColor: (String) -> NSColor {{ state in
        if state == "none" { return .textColor }
        var color = self.monochromeState ? MonochromeColor.blue : (self.inputColorState.additional as? NSColor ?? NSColor.systemBlue)
        if self.inputValue < 1024 {
            if state == "transparent" {
                color = .clear
            } else if state == "default" {
                color = .textColor
            }
        }
        return color
    }}
    private var outputColor: (String) -> NSColor {{ state in
        if state == "none" { return .textColor }
        var color = self.monochromeState ? MonochromeColor.red : (self.outputColorState.additional as? NSColor ?? NSColor.red)
        if self.outputValue < 1024 {
            if state == "transparent" {
                color = .clear
            } else if state == "default" {
                color = .textColor
            }
        }
        return color
    }}
    
    private var valueAlignment: NSTextAlignment {
        get {
            if let alignmentPair = Alignments.first(where: { $0.key == self.valueAlignmentState }) {
                return alignmentPair.additional as? NSTextAlignment ?? .left
            }
            return .left
        }
    }
    
    private var base: DataSizeBase {
        DataSizeBase(rawValue: Store.shared.string(key: "\(self.title)_base", defaultValue: "byte")) ?? .byte
    }
    
    public init(title: String, config: NSDictionary?, preview: Bool = false) {
        let widgetTitle: String = title
        if config != nil {
            if let symbols = config!["Symbols"] as? NSDictionary {
                if let i = symbols["Input"] as? String { self.symbols.input = i }
                if let o = symbols["Output"] as? String { self.symbols.output = o }
            }
            if let icon = config!["Icon"] as? String { self.icon = icon }
            if let words = config!["Words"] as? NSDictionary {
                if let i = words["Input"] as? String { self.words.input = i }
                if let o = words["Output"] as? String { self.words.output = o }
            }
        }
        
        super.init(.speed, title: widgetTitle, frame: CGRect(
            x: 0,
            y: Constants.Widget.margin.y,
            width: width,
            height: Constants.Widget.height - (2*Constants.Widget.margin.y)
        ))
        self.canDrawConcurrently = true
        
        if !preview {
            self.valueState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_value", defaultValue: self.valueState)
            self.icon = Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_icon", defaultValue: self.icon)
            self.unitsState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_units", defaultValue: self.unitsState)
            self.monochromeState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_monochrome", defaultValue: self.monochromeState)
            self.valueColorState = Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_valueColor", defaultValue: self.valueColorState)
            if self.valueColorState == "0" {
                self.valueColorState = "none"
            }
            self.inputColorState = SColor.fromString(Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_downloadColor", defaultValue: self.inputColorState.key))
            self.outputColorState = SColor.fromString(Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_uploadColor", defaultValue: self.outputColorState.key))
            self.valueAlignmentState = Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_valueAlignment", defaultValue: self.valueAlignmentState)
            self.modeState = Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_mode", defaultValue: self.modeState)
            self.iconAlignmentState = Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_iconAlignment", defaultValue: self.iconAlignmentState)
            self.iconColorState = Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_iconColor", defaultValue: self.iconColorState)
            self.displayValueState = Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_displayValue", defaultValue: self.displayValueState)
        }
        
        if preview {
            self.inputValue = 8947141
            self.outputValue = 478678
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        var width: CGFloat = 0
        switch self.modeState {
        case "oneRow":
            width = self.drawOneRow()
        case "twoRows":
            width = self.drawTwoRows()
        default:
            width = 0
        }
        
        self.setWidth(width)
    }
    
    // MARK: - one row
    
    private func drawOneRow() -> CGFloat {
        var width: CGFloat = Constants.Widget.margin.x
        
        if self.displayValueState.first == "i" {
            width = self.drawRowItem(
                initWidth: width,
                symbol: self.symbols.input,
                iconColor: self.inputColor(self.iconColorState),
                value: self.inputValue,
                valueColor: self.inputColor(self.valueColorState)
            )
        } else {
            width = self.drawRowItem(
                initWidth: width,
                symbol: self.symbols.output,
                iconColor: self.outputColor(self.iconColorState),
                value: self.outputValue,
                valueColor: self.outputColor(self.valueColorState)
            )
        }
        
        if self.displayValueState.count > 1 {
            width += Constants.Widget.spacing*3
            if self.displayValueState.last == "i" {
                width = self.drawRowItem(
                    initWidth: width,
                    symbol: self.symbols.input,
                    iconColor: self.inputColor(self.iconColorState),
                    value: self.inputValue,
                    valueColor: self.inputColor(self.valueColorState)
                )
            } else {
                width = self.drawRowItem(
                    initWidth: width,
                    symbol: self.symbols.output,
                    iconColor: self.outputColor(self.iconColorState),
                    value: self.outputValue,
                    valueColor: self.outputColor(self.valueColorState)
                )
            }
        }
        
        return width + Constants.Widget.margin.x
    }
    
    private func drawRowItem(initWidth: CGFloat, symbol: String, iconColor: NSColor, value: Int64, valueColor: NSColor) -> CGFloat {
        var width = initWidth
        
        if self.iconAlignmentState == "left" {
            switch self.icon {
            case "dots":
                width += self.drawDot(CGPoint(x: width, y: 0), color: iconColor)
            case "arrows":
                width += self.drawArrow(CGPoint(x: width, y: 0), symbol: symbol, color: iconColor)
            case "chars":
                width += self.drawChar(CGPoint(x: width, y: 0), symbol: symbol, color: iconColor)
            default: break
            }
            width += self.valueState && self.icon != "none" ? 2 : 0
        }
        
        if self.valueState {
            width += self.drawValue(value, offset: CGPoint(x: width, y: 0), color: valueColor)
        }
        
        if self.iconAlignmentState == "right" {
            if self.valueState {
                width += 2
            }
            switch self.icon {
            case "dots":
                width += self.drawDot(CGPoint(x: width, y: 0), color: iconColor)
            case "arrows":
                width += self.drawArrow(CGPoint(x: width, y: 0), symbol: symbol, color: iconColor)
            case "chars":
                width += self.drawChar(CGPoint(x: width, y: 0), symbol: symbol, color: iconColor)
            default: break
            }
        }
        
        return width
    }
    
    private func drawValue(_ value: Int64, offset: CGPoint, color: NSColor) -> CGFloat {
        let rowWidth: CGFloat = self.unitsState ? 58 : 32
        let height: CGFloat = self.frame.height
        let style = NSMutableParagraphStyle()
        style.alignment = self.valueAlignment
        let size: CGFloat = 10
        
        let inputStringAttributes = [
            NSAttributedString.Key.font: NSFont.systemFont(ofSize: 11, weight: .regular),
            NSAttributedString.Key.foregroundColor: color,
            NSAttributedString.Key.paragraphStyle: style
        ]
        
        let rect = CGRect(x: offset.x, y: (height-size)/2 + offset.y + 1, width: rowWidth - (Constants.Widget.margin.x*2), height: size)
        let value = NSAttributedString.init(
            string: Units(bytes: value).getReadableSpeed(base: base, omitUnits: !self.unitsState),
            attributes: inputStringAttributes
        )
        value.draw(with: rect)
        
        return rowWidth
    }
    
    private func drawDot(_ offset: CGPoint, color: NSColor) -> CGFloat {
        var size: CGFloat = 8
        var height: CGFloat = self.frame.height
        
        if self.modeState == "twoRows" {
            size = 6
            height /= 2
        }
        
        var circle = NSBezierPath()
        circle = NSBezierPath(ovalIn: CGRect(x: offset.x, y: (height-size)/2 + offset.y, width: size, height: size))
        color.set()
        circle.fill()
        
        return size
    }
    
    private func drawArrow(_ offset: CGPoint, symbol: String, color: NSColor) -> CGFloat {
        let height = self.frame.height
        let size = height * 0.8
        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 1
        let lineWidth: CGFloat = 1
        let arrowSize: CGFloat = 3 + (scaleFactor/2)
        let x = arrowSize + (lineWidth / 2)
        let y = (height - size)/2
        
        var start: CGPoint = CGPoint(x: offset.x + x, y: y)
        var end: CGPoint = CGPoint(x: offset.x + x, y: size + y)
        if symbol == "D" || symbol == "R" {
            start = CGPoint(x: offset.x + x, y: size + y)
            end = CGPoint(x: offset.x + x, y: y)
        } else if symbol == "U" || symbol == "W" {
            start = CGPoint(x: offset.x + x, y: y)
            end = CGPoint(x: offset.x + x, y: size + y)
        }
        
        let arrow = NSBezierPath()
        arrow.addArrow(
            start: start,
            end: end,
            pointerLineLength: arrowSize,
            arrowAngle: CGFloat(Double.pi / 5)
        )
        
        color.set()
        arrow.lineWidth = lineWidth
        arrow.stroke()
        arrow.close()
        
        return arrowSize
    }
    
    private func drawChar(_ offset: CGPoint, symbol: String, color: NSColor) -> CGFloat {
        let rowHeight: CGFloat = self.frame.height
        let height: CGFloat = 10
        let inputAttributes = [
            NSAttributedString.Key.font: NSFont.systemFont(ofSize: 12, weight: .regular),
            NSAttributedString.Key.foregroundColor: color,
            NSAttributedString.Key.paragraphStyle: NSMutableParagraphStyle()
        ]
        let rect = CGRect(x: offset.x, y: offset.y + ((rowHeight-height)/2) + 1, width: 10, height: height)
        let str = NSAttributedString.init(string: symbol, attributes: inputAttributes)
        str.draw(with: rect)
        
        return 10
    }
    
    // MARK: - two rows
    
    private func drawTwoRows() -> CGFloat {
        var width: CGFloat = 7
        var x: CGFloat = 7
        
        if self.iconAlignmentState == "right" {
            x = 0
        }
        if self.icon == "none" {
            x = 0
            width = 0
        }
        
        if self.valueState {
            let rowWidth: CGFloat = self.unitsState ? 48 : 30
            let rowHeight: CGFloat = self.frame.height / 2
            let style = NSMutableParagraphStyle()
            style.alignment = self.valueAlignment
            
            let inputStringAttributes = [
                NSAttributedString.Key.font: NSFont.systemFont(ofSize: 9, weight: .light),
                NSAttributedString.Key.foregroundColor: self.inputColor(self.valueColorState),
                NSAttributedString.Key.paragraphStyle: style
            ]
            let outputStringAttributes = [
                NSAttributedString.Key.font: NSFont.systemFont(ofSize: 9, weight: .light),
                NSAttributedString.Key.foregroundColor: self.outputColor(self.valueColorState),
                NSAttributedString.Key.paragraphStyle: style
            ]
            
            let inputY: CGFloat = self.displayValueState == "io" ? rowHeight + 1 : 1
            let outputY: CGFloat = self.displayValueState == "io" ? 1 : rowHeight + 1
            
            var rect = CGRect(x: Constants.Widget.margin.x + x, y: inputY, width: rowWidth - (Constants.Widget.margin.x*2), height: rowHeight)
            let input = NSAttributedString.init(
                string: Units(bytes: self.inputValue).getReadableSpeed(base: base, omitUnits: !self.unitsState),
                attributes: inputStringAttributes
            )
            input.draw(with: rect)
            
            rect = CGRect(x: Constants.Widget.margin.x + x, y: outputY, width: rowWidth - (Constants.Widget.margin.x*2), height: rowHeight)
            let output = NSAttributedString.init(
                string: Units(bytes: self.outputValue).getReadableSpeed(base: base, omitUnits: !self.unitsState),
                attributes: outputStringAttributes
            )
            output.draw(with: rect)
            
            width += rowWidth
        }
        
        switch self.icon {
        case "dots":
            self.drawDots(width)
        case "arrows":
            self.drawArrows(width)
        case "chars":
            self.drawChars(width)
        default: break
        }
        
        return width
    }
    
    private func drawDots(_ width: CGFloat) {
        let rowHeight: CGFloat = self.frame.height / 2
        let size: CGFloat = 6
        let y: CGFloat = (rowHeight-size)/2
        let x: CGFloat = self.iconAlignmentState == "left" ? Constants.Widget.margin.x : Constants.Widget.margin.x+(width-6)
        let inputY: CGFloat = self.displayValueState == "io" ? 10.5 : y-0.2
        let outputdY: CGFloat = self.displayValueState == "io" ? y-0.2 : 10.5
        
        var inputCircle = NSBezierPath()
        inputCircle = NSBezierPath(ovalIn: CGRect(x: x, y: inputY, width: size, height: size))
        self.inputColor(self.iconColorState).set()
        inputCircle.fill()
        
        var outputCircle = NSBezierPath()
        outputCircle = NSBezierPath(ovalIn: CGRect(x: x, y: outputdY, width: size, height: size))
        self.outputColor(self.iconColorState).set()
        outputCircle.fill()
    }
    
    private func drawArrows(_ width: CGFloat) {
        let arrowAngle = CGFloat(Double.pi / 5)
        let half = self.frame.size.height / 2
        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 1
        let lineWidth: CGFloat = 1
        let arrowSize: CGFloat = 3 + (scaleFactor/2)
        var x = Constants.Widget.margin.x + arrowSize + (lineWidth / 2)
        if self.iconAlignmentState == "right" {
            x += (width-7)
        }
        
        let inputYStart: CGFloat = self.displayValueState == "io" ? self.frame.size.height : half - Constants.Widget.spacing/2
        let inputYEnd: CGFloat = self.displayValueState == "io" ? (half + Constants.Widget.spacing/2)+1 : 1
        
        let outputYStart: CGFloat = self.displayValueState == "io" ? 0 : half + Constants.Widget.spacing/2
        let uploadYEnd: CGFloat = self.displayValueState == "io" ? (half - Constants.Widget.spacing/2)-1 : self.frame.size.height-1
        
        let inputArrow = NSBezierPath()
        inputArrow.addArrow(
            start: CGPoint(x: x, y: inputYStart),
            end: CGPoint(x: x, y: inputYEnd),
            pointerLineLength: arrowSize,
            arrowAngle: arrowAngle
        )
        
        self.inputColor(self.iconColorState).set()
        inputArrow.lineWidth = lineWidth
        inputArrow.stroke()
        inputArrow.close()
        
        let outputArrow = NSBezierPath()
        outputArrow.addArrow(
            start: CGPoint(x: x, y: outputYStart),
            end: CGPoint(x: x, y: uploadYEnd),
            pointerLineLength: arrowSize,
            arrowAngle: arrowAngle
        )
        
        self.outputColor(self.iconColorState).set()
        outputArrow.lineWidth = lineWidth
        outputArrow.stroke()
        outputArrow.close()
    }
    
    private func drawChars(_ width: CGFloat) {
        let rowHeight: CGFloat = self.frame.height / 2
        let inputY: CGFloat = self.displayValueState == "io" ? rowHeight+1 : 1
        let outputY: CGFloat = self.displayValueState == "io" ? 1 : rowHeight+1
        let x: CGFloat = self.iconAlignmentState == "left" ? Constants.Widget.margin.x : Constants.Widget.margin.x+(width-6)
        
        let inputAttributes = [
            NSAttributedString.Key.font: NSFont.systemFont(ofSize: 9, weight: .regular),
            NSAttributedString.Key.foregroundColor: self.inputColor(self.iconColorState),
            NSAttributedString.Key.paragraphStyle: NSMutableParagraphStyle()
        ]
        var rect = CGRect(x: x, y: inputY, width: 8, height: rowHeight)
        var str = NSAttributedString.init(string: self.symbols.input, attributes: inputAttributes)
        str.draw(with: rect)
        
        let outputAttributes = [
            NSAttributedString.Key.font: NSFont.systemFont(ofSize: 9, weight: .regular),
            NSAttributedString.Key.foregroundColor: self.outputColor(self.iconColorState),
            NSAttributedString.Key.paragraphStyle: NSMutableParagraphStyle()
        ]
        rect = CGRect(x: x, y: outputY, width: 8, height: rowHeight)
        str = NSAttributedString.init(string: self.symbols.output, attributes: outputAttributes)
        str.draw(with: rect)
    }

    public func setValue(input: Int64, output: Int64) {
        let nextInput = abs(input)
        let nextOutput = abs(output)
        let nextState = self.displayState(input: nextInput, output: nextOutput)

        guard self.renderedState != nextState else { return }

        self.inputValue = nextInput
        self.outputValue = nextOutput
        self.renderedState = nextState

        DispatchQueue.main.async(execute: {
            self.display()
        })
    }

    private func displayState(input: Int64, output: Int64) -> SpeedDisplayState {
        let base = self.base
        return SpeedDisplayState(
            inputText: Units(bytes: input).getReadableSpeed(base: base, omitUnits: !self.unitsState),
            outputText: Units(bytes: output).getReadableSpeed(base: base, omitUnits: !self.unitsState),
            inputActive: input >= 1024,
            outputActive: output >= 1024,
            valueState: self.valueState,
            unitsState: self.unitsState,
            icon: self.icon,
            monochromeState: self.monochromeState,
            valueColorState: self.valueColorState,
            iconColorState: self.iconColorState,
            inputColorState: self.inputColorState.key,
            outputColorState: self.outputColorState.key,
            modeState: self.modeState,
            displayValueState: self.displayValueState
        )
    }

    fileprivate func configurationState() -> (
        icon: String,
        valueState: Bool,
        unitsState: Bool,
        monochromeState: Bool,
        valueColorState: String,
        iconColorState: String,
        valueAlignmentState: String,
        modeState: String,
        iconAlignmentState: String,
        displayValueState: String,
        inputColorState: SColor,
        outputColorState: SColor
    ) {
        (
            self.icon,
            self.valueState,
            self.unitsState,
            self.monochromeState,
            self.valueColorState,
            self.iconColorState,
            self.valueAlignmentState,
            self.modeState,
            self.iconAlignmentState,
            self.displayValueState,
            self.inputColorState,
            self.outputColorState
        )
    }

    fileprivate func configurationWords() -> (input: String, output: String) {
        self.words
    }

    fileprivate func applyConfiguration(
        icon: String? = nil,
        valueState: Bool? = nil,
        unitsState: Bool? = nil,
        monochromeState: Bool? = nil,
        valueColorState: String? = nil,
        iconColorState: String? = nil,
        valueAlignmentState: String? = nil,
        modeState: String? = nil,
        iconAlignmentState: String? = nil,
        displayValueState: String? = nil,
        inputColorState: SColor? = nil,
        outputColorState: SColor? = nil
    ) {
        if let icon { self.icon = icon }
        if let valueState { self.valueState = valueState }
        if let unitsState { self.unitsState = unitsState }
        if let monochromeState { self.monochromeState = monochromeState }
        if let valueColorState { self.valueColorState = valueColorState }
        if let iconColorState { self.iconColorState = iconColorState }
        if let valueAlignmentState { self.valueAlignmentState = valueAlignmentState }
        if let modeState { self.modeState = modeState }
        if let iconAlignmentState { self.iconAlignmentState = iconAlignmentState }
        if let displayValueState { self.displayValueState = displayValueState }
        if let inputColorState { self.inputColorState = inputColorState }
        if let outputColorState { self.outputColorState = outputColorState }
        self.display()
    }

    // MARK: - settings

    public override func settings() -> NSView {
        self.widgetConfiguration.settingsView()
    }
}

private final class SpeedWidgetConfiguration: BaseWidgetConfiguration {
    private weak var widget: SpeedWidget?
    private weak var valueColorView: NSPopUpButton?
    private weak var valueAlignmentView: NSPopUpButton?
    private weak var iconAlignmentView: NSPopUpButton?
    private weak var iconColorView: NSPopUpButton?
    private weak var displayModeView: NSPopUpButton?

    init(widget: SpeedWidget) {
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

        let valueAlignment = selectView(
            action: #selector(self.toggleValueAlignment),
            items: Alignments,
            selected: state.valueAlignmentState
        )
        valueAlignment.isEnabled = state.valueState
        self.valueAlignmentView = valueAlignment

        let iconAlignment = selectView(
            action: #selector(self.toggleIconAlignment),
            items: Alignments.filter({ $0.key != "center" }),
            selected: state.iconAlignmentState
        )
        iconAlignment.isEnabled = state.icon != "none"
        self.iconAlignmentView = iconAlignment

        let iconColor = selectView(
            action: #selector(self.toggleIconColor),
            items: SpeedPictogramColor.filter({ $0.key != "none" }),
            selected: state.iconColorState
        )
        iconColor.isEnabled = state.icon != "none"
        self.iconColorView = iconColor

        let valueColor = selectView(
            action: #selector(self.toggleValueColor),
            items: SpeedPictogramColor,
            selected: state.valueColorState
        )
        valueColor.isEnabled = state.valueState
        self.valueColorView = valueColor

        let displayMode = selectView(
            action: #selector(self.changeDisplayMode),
            items: SensorsWidgetMode.filter({ $0.key == "oneRow" || $0.key == "twoRows" }),
            selected: state.modeState
        )
        displayMode.isEnabled = state.displayValueState.count > 1
        self.displayModeView = displayMode

        let words = widget.configurationWords()
        let sensorWidgetValue = SensorsWidgetValue.map { v in
            var value = v.value.replacingOccurrences(of: "input", with: localizedString(words.input), options: .literal, range: nil)
            value = value.replacingOccurrences(of: "output", with: localizedString(words.output), options: .literal, range: nil)
            return KeyValue_t(key: v.key, value: value)
        }

        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Value"), component: selectView(
                action: #selector(self.changeDisplayValue),
                items: sensorWidgetValue,
                selected: state.displayValueState
            )),
            PreferencesRow(localizedString("Display mode"), component: displayMode)
        ]))

        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Pictogram"), component: selectView(
                action: #selector(self.toggleIcon),
                items: SpeedPictogram,
                selected: state.icon
            )),
            PreferencesRow(localizedString("Colorize"), component: iconColor),
            PreferencesRow(localizedString("Alignment"), component: iconAlignment)
        ]))

        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Value"), component: switchView(
                action: #selector(self.toggleValue),
                state: state.valueState
            )),
            PreferencesRow(localizedString("Colorize value"), component: valueColor),
            PreferencesRow(localizedString("Alignment"), component: valueAlignment),
            PreferencesRow(localizedString("Units"), component: switchView(
                action: #selector(self.toggleUnits),
                state: state.unitsState
            ))
        ]))

        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Monochrome accent"), component: switchView(
                action: #selector(self.toggleMonochrome),
                state: state.monochromeState
            )),
            PreferencesRow(localizedString("Color of download"), component: selectView(
                action: #selector(self.toggleInputColor),
                items: SColor.allColors,
                selected: state.inputColorState.key
            )),
            PreferencesRow(localizedString("Color of upload"), component: selectView(
                action: #selector(self.toggleOutputColor),
                items: SColor.allColors,
                selected: state.outputColorState.key
            ))
        ]))

        return view
    }

    @objc private func changeDisplayValue(_ sender: NSMenuItem) {
        guard let widget, let key = sender.representedObject as? String else { return }
        var modeState = widget.configurationState().modeState
        if key.count == 1 {
            if modeState != "oneRow" {
                modeState = "oneRow"
                self.writeString("mode", value: modeState)
            }
            self.displayModeView?.selectItem(at: 0)
        }
        self.displayModeView?.isEnabled = key.count > 1
        self.writeString("displayValue", value: key)
        widget.applyConfiguration(modeState: modeState, displayValueState: key)
    }

    @objc private func changeDisplayMode(_ sender: NSMenuItem) {
        guard let widget, let key = sender.representedObject as? String else { return }
        self.writeString("mode", value: key)
        widget.applyConfiguration(modeState: key)
    }

    @objc private func toggleValue(_ sender: NSControl) {
        guard let widget else { return }
        let value = controlState(sender)
        self.valueColorView?.isEnabled = value
        self.valueAlignmentView?.isEnabled = value
        self.writeBool("value", value: value)
        widget.applyConfiguration(valueState: value)
    }

    @objc private func toggleUnits(_ sender: NSControl) {
        guard let widget else { return }
        let value = controlState(sender)
        self.writeBool("units", value: value)
        widget.applyConfiguration(unitsState: value)
    }

    @objc private func toggleIcon(_ sender: NSMenuItem) {
        guard let widget, let key = sender.representedObject as? String else { return }
        self.iconColorView?.isEnabled = key != "none"
        self.iconAlignmentView?.isEnabled = key != "none"
        self.writeString("icon", value: key)
        widget.applyConfiguration(icon: key)
    }

    @objc private func toggleMonochrome(_ sender: NSControl) {
        guard let widget else { return }
        let value = controlState(sender)
        self.writeBool("monochrome", value: value)
        widget.applyConfiguration(monochromeState: value)
    }

    @objc private func toggleValueColor(_ sender: NSMenuItem) {
        guard let widget,
              let key = sender.representedObject as? String,
              SpeedPictogramColor.first(where: { $0.key == key }) != nil else { return }
        self.writeString("valueColor", value: key)
        widget.applyConfiguration(valueColorState: key)
    }

    @objc private func toggleOutputColor(_ sender: NSMenuItem) {
        guard let widget,
              let key = sender.representedObject as? String,
              let newValue = SColor.allColors.first(where: { $0.key == key }) else { return }
        self.writeString("uploadColor", value: key)
        widget.applyConfiguration(outputColorState: newValue)
    }

    @objc private func toggleInputColor(_ sender: NSMenuItem) {
        guard let widget,
              let key = sender.representedObject as? String,
              let newValue = SColor.allColors.first(where: { $0.key == key }) else { return }
        self.writeString("downloadColor", value: key)
        widget.applyConfiguration(inputColorState: newValue)
    }

    @objc private func toggleValueAlignment(_ sender: NSMenuItem) {
        guard let widget,
              let key = sender.representedObject as? String,
              Alignments.first(where: { $0.key == key }) != nil else { return }
        self.writeString("valueAlignment", value: key)
        widget.applyConfiguration(valueAlignmentState: key)
    }

    @objc private func toggleIconAlignment(_ sender: NSMenuItem) {
        guard let widget,
              let key = sender.representedObject as? String,
              Alignments.first(where: { $0.key == key }) != nil else { return }
        self.writeString("iconAlignment", value: key)
        widget.applyConfiguration(iconAlignmentState: key)
    }

    @objc private func toggleIconColor(_ sender: NSMenuItem) {
        guard let widget,
              let key = sender.representedObject as? String,
              SpeedPictogramColor.first(where: { $0.key == key }) != nil else { return }
        self.writeString("iconColor", value: key)
        widget.applyConfiguration(iconColorState: key)
    }
}
