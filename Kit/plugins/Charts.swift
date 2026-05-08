//
//  Chart.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 17/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import SwiftUI
import Charts

internal func scaleValue(scale: Scale = .linear, value: Double, maxValue: Double, zeroValue: Double, maxHeight: CGFloat, limit: Double) -> CGFloat {
    var value = value
    if scale == .none && value > 1 && maxValue != 0 {
        value /= maxValue
    }
    var localMaxValue = maxValue
    var y = value * maxHeight
    
    switch scale {
    case .square:
        if value > 0 {
            value = sqrt(value)
        }
        if localMaxValue > 0 {
            localMaxValue = sqrt(maxValue)
        }
    case .cube:
        if value > 0 {
            value = cbrt(value)
        }
        if localMaxValue > 0 {
            localMaxValue = cbrt(maxValue)
        }
    case .logarithmic:
        if value > 0 {
            value = log(value/zeroValue)
        }
        if localMaxValue > 0 {
            localMaxValue = log(maxValue/zeroValue)
        }
    case .fixed:
        if value > limit {
            value = limit
        }
        localMaxValue = limit
    default: break
    }
    
    if value < 0 {
        value = 0
    }
    if localMaxValue <= 0 {
        localMaxValue = 1
    }
    
    if scale != .none {
        y = (maxHeight * value)/localMaxValue
    }
    
    return y
}

private func drawToolTip(_ frame: NSRect, _ point: CGPoint, _ size: CGSize, value: String, subtitle: String? = nil) {
    guard !value.isEmpty else { return }
    
    let style = NSMutableParagraphStyle()
    style.alignment = .left
    var position: CGPoint = point
    let textHeight: CGFloat = subtitle != nil ? 22 : 12
    let valueOffset: CGFloat = subtitle != nil ? 11 : 1
    
    position.x = max(frame.origin.x, min(position.x, frame.origin.x + frame.size.width - size.width))
    position.y = max(frame.origin.y, min(position.y, frame.origin.y + frame.size.height - textHeight - 2))
    
    if position.x + size.width > frame.size.width+frame.origin.x {
        position.x = point.x - size.width
        style.alignment = .right
    }
    if position.y + textHeight > size.height {
        position.y = point.y - textHeight - 20
    }
    if position.y < 2 {
        position.y = 2
    }
    
    let box = NSBezierPath(roundedRect: NSRect(x: position.x-3, y: position.y-2, width: size.width, height: textHeight+2), xRadius: 2, yRadius: 2)
    NSColor.gray.setStroke()
    box.stroke()
    (isDarkMode ? NSColor.black : NSColor.white).withAlphaComponent(0.8).setFill()
    box.fill()
    
    var attributes = [
        NSAttributedString.Key.font: NSFont.systemFont(ofSize: 12, weight: .regular),
        NSAttributedString.Key.foregroundColor: isDarkMode ? NSColor.white : NSColor.textColor
    ]
    var rect = CGRect(x: position.x, y: position.y+valueOffset, width: size.width, height: 12)
    var str = NSAttributedString.init(string: value, attributes: attributes)
    str.draw(with: rect)
    
    if let subtitle {
        attributes[NSAttributedString.Key.font] = NSFont.systemFont(ofSize: 9, weight: .medium)
        attributes[NSAttributedString.Key.foregroundColor] = (isDarkMode ? NSColor.white : NSColor.textColor).withAlphaComponent(0.7)
        rect = CGRect(x: position.x, y: position.y, width: size.width-8, height: 9)
        str = NSAttributedString.init(string: subtitle, attributes: attributes)
        str.draw(with: rect)
    }
}

public class ChartView: NSView {
    public var id: String = UUID().uuidString
    fileprivate let stateQueue: DispatchQueue
    
    fileprivate init(frame: NSRect, queueLabel: String) {
        self.stateQueue = DispatchQueue(label: queueLabel, attributes: .concurrent)
        super.init(frame: frame)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    fileprivate func read<T>(_ block: () -> T) -> T {
        self.stateQueue.sync(execute: block)
    }
    
    fileprivate func write(_ block: @escaping () -> Void) {
        self.stateQueue.async(flags: .barrier, execute: block)
    }
    
    fileprivate func displayIfVisible() {
        if Thread.isMainThread {
            self.updateSwiftUI()
            self.needsDisplay = true
            if self.window != nil { self.display() }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.updateSwiftUI()
                self?.needsDisplay = true
                if self?.window != nil { self?.display() }
            }
        }
    }
    
    internal func updateSwiftUI() {}
}

public class LineChartView: ChartView {
    private let dateFormatter = DateFormatter()
    
    private var points: [DoubleValue?]
    private var shadowPoints: [DoubleValue?] = []
    private var transparent: Bool = true
    private var flipY: Bool = false
    private var minMax: Bool = false
    private var color: NSColor
    private var suffix: String
    private var toolTipFunc: ((DoubleValue) -> String)?
    private var isTooltipEnabled: Bool = true
    private var xLegend: Bool = false
    private var yLegend: Bool = false
    
    private var scale: Scale
    private var fixedScale: Double
    private var zeroValue: Double
    private let legendDateFormatter = DateFormatter()
    
    private var cursor: NSPoint? = nil
    private var stop: Bool = false
    
    private var hostingView: NSHostingView<LineChartContent>?
    
    private var tooltipEnabledSnapshot: Bool {
        self.read { self.isTooltipEnabled }
    }
    
    public init(frame: NSRect = .zero, num: Int, suffix: String = "%", color: NSColor = .controlAccentColor, scale: Scale = .none, fixedScale: Double = 1, zeroValue: Double = 0.01) {
        let now = Date()
        self.points = (0..<num).map { i in
            DoubleValue(0, ts: now.addingTimeInterval(Double(i - num)))
        }
        self.suffix = suffix
        self.color = color
        self.scale = scale
        self.fixedScale = fixedScale
        self.zeroValue = zeroValue
        
        super.init(frame: frame, queueLabel: "eu.exelban.Stats.Charts.Line")
        
        self.dateFormatter.dateFormat = "dd/MM HH:mm:ss"
        self.legendDateFormatter.dateFormat = "HH:mm:ss"
        
        let content = LineChartContent(points: self.points, color: self.color, scale: self.scale, fixedScale: self.fixedScale, zeroValue: self.zeroValue, minMax: self.minMax, suffix: self.suffix)
        let hostingView = NSHostingView<LineChartContent>(rootView: content)
        hostingView.frame = self.bounds
        hostingView.autoresizingMask = [.width, .height]
        self.addSubview(hostingView)
        self.hostingView = hostingView
        
        self.addTrackingArea(NSTrackingArea(
            rect: CGRect(x: 0, y: 0, width: self.frame.width, height: self.frame.height),
            options: [
                .activeAlways,
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect
            ],
            owner: self, userInfo: nil
        ))
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        // No longer using manual draw for the chart itself, SwiftUI hosting view handles it.
        // We only draw tooltips if needed, but Swift Charts has better native tooltips we can explore later.
        // For now, keeping the tooltip logic might be complex with NSHostingView layering.
    }
    
    override func updateSwiftUI() {
        let content = LineChartContent(
            points: self.read { self.points },
            color: self.read { self.color },
            scale: self.read { self.scale },
            fixedScale: self.read { self.fixedScale },
            zeroValue: self.read { self.zeroValue },
            minMax: self.read { self.minMax },
            suffix: self.read { self.suffix }
        )
        self.hostingView?.rootView = content
    }
    
    public override func updateTrackingAreas() {
        self.trackingAreas.forEach({ self.removeTrackingArea($0) })
        self.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [
                .activeAlways,
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect
            ],
            owner: self, userInfo: nil
        ))
        super.updateTrackingAreas()
    }
    
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        self.hostingView?.frame = NSRect(origin: .zero, size: newSize)
    }
    
    public func addValue(_ value: DoubleValue) {
        self.write {
            guard !self.points.isEmpty else { return }
            self.points.remove(at: 0)
            self.points.append(value)
        }
        self.displayIfVisible()
    }
    
    public func addValue(_ value: Double) {
        self.addValue(DoubleValue(value))
    }
    
    public func reinit(_ num: Int = 60) {
        self.write {
            guard self.points.count != num else { return }
            if num < self.points.count {
                self.points = Array(self.points[self.points.count-num..<self.points.count])
            } else {
                let origin = self.points
                self.points = Array(repeating: nil, count: num)
                self.points.replaceSubrange(Range(uncheckedBounds: (lower: num-origin.count, upper: num)), with: origin)
            }
        }
        self.displayIfVisible()
    }
    
    public func setScale(_ newScale: Scale, fixedScale: Double = 1) {
        self.write {
            self.scale = newScale
            self.fixedScale = fixedScale
        }
        self.displayIfVisible()
    }
    
    public func setPoints(_ newPoints: [DoubleValue]) {
        self.write { self.points = newPoints.map { Optional($0) } }
        self.displayIfVisible()
    }
    
    public func setColor(_ newColor: NSColor) {
        self.write { self.color = newColor }
        self.displayIfVisible()
    }
    
    public func setSuffix(_ newSuffix: String) {
        self.write { self.suffix = newSuffix }
        self.displayIfVisible()
    }
    
    public func setTransparent(_ newValue: Bool) {
        self.write { self.transparent = newValue }
        self.displayIfVisible()
    }
    
    public func setFlipY(_ newValue: Bool) {
        self.write { self.flipY = newValue }
        self.displayIfVisible()
    }
    
    public func setMinMax(_ newValue: Bool) {
        self.write { self.minMax = newValue }
        self.displayIfVisible()
    }
    
    public func setToolTipFunc(_ newValue: ((DoubleValue) -> String)?) {
        self.write { self.toolTipFunc = newValue }
    }
    
    public func setTooltipEnabled(_ newValue: Bool) {
        self.write { self.isTooltipEnabled = newValue }
    }
    
    public func setLegend(x: Bool, y: Bool) {
        self.write {
            self.xLegend = x
            self.yLegend = y
        }
        self.displayIfVisible()
    }
    
    public override func mouseEntered(with event: NSEvent) {
        guard self.tooltipEnabledSnapshot else { return }
        self.cursor = convert(event.locationInWindow, from: nil)
        self.needsDisplay = true
    }
    
    public override func mouseMoved(with event: NSEvent) {
        guard self.tooltipEnabledSnapshot else { return }
        self.cursor = convert(event.locationInWindow, from: nil)
        self.needsDisplay = true
    }
    
    public override func mouseDragged(with event: NSEvent) {
        guard self.tooltipEnabledSnapshot else { return }
        self.cursor = convert(event.locationInWindow, from: nil)
        self.needsDisplay = true
    }
    
    public override func mouseExited(with event: NSEvent) {
        guard self.tooltipEnabledSnapshot else { return }
        self.cursor = nil
        self.needsDisplay = true
    }
    
    public override func mouseDown(with: NSEvent) {
        guard self.tooltipEnabledSnapshot else { return }
        self.write { self.shadowPoints = self.points }
        self.stop = true
    }
    
    public override func mouseUp(with: NSEvent) {
        guard self.tooltipEnabledSnapshot else { return }
        self.stop = false
    }
}

public class NetworkChartView: ChartView {
    private var reversedOrder: Bool
    private var base: DataSizeBase = .byte
    
    private var inPoints: [DoubleValue?] = []
    private var outPoints: [DoubleValue?] = []
    private var inColor: NSColor
    private var outColor: NSColor
    
    private var hostingView: NSHostingView<NetworkChartContent>?
    
    public init(frame: NSRect, num: Int, minMax: Bool = true, reversedOrder: Bool = false,
                outColor: NSColor = .systemRed, inColor: NSColor = .systemBlue, scale: Scale = .none, fixedScale: Double = 1) {
        let now = Date()
        self.reversedOrder = reversedOrder
        self.inColor = inColor
        self.outColor = outColor
        self.inPoints = (0..<num).map { i in
            DoubleValue(0, ts: now.addingTimeInterval(Double(i - num)))
        }
        self.outPoints = (0..<num).map { i in
            DoubleValue(0, ts: now.addingTimeInterval(Double(i - num)))
        }
        
        super.init(frame: frame, queueLabel: "eu.exelban.Stats.Charts.Network")
        
        let content = NetworkChartContent(inPoints: self.inPoints, outPoints: self.outPoints, inColor: self.inColor, outColor: self.outColor, reversedOrder: self.reversedOrder)
        let hostingView = NSHostingView<NetworkChartContent>(rootView: content)
        hostingView.frame = self.bounds
        hostingView.autoresizingMask = [.width, .height]
        self.addSubview(hostingView)
        self.hostingView = hostingView
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func setBase(_ newBase: DataSizeBase) {
        self.write { self.base = newBase }
    }
    
    override func updateSwiftUI() {
        let content = NetworkChartContent(
            inPoints: self.read { self.inPoints },
            outPoints: self.read { self.outPoints },
            inColor: self.read { self.inColor },
            outColor: self.read { self.outColor },
            reversedOrder: self.read { self.reversedOrder }
        )
        self.hostingView?.rootView = content
    }
    
    public func addValue(upload: Double, download: Double) {
        self.write {
            if !self.inPoints.isEmpty {
                self.inPoints.remove(at: 0)
                self.inPoints.append(DoubleValue(download))
            }
            if !self.outPoints.isEmpty {
                self.outPoints.remove(at: 0)
                self.outPoints.append(DoubleValue(upload))
            }
        }
        self.displayIfVisible()
    }
    
    public func reinit(_ num: Int = 60) {
        self.write {
            if num < self.inPoints.count {
                self.inPoints = Array(self.inPoints[self.inPoints.count-num..<self.inPoints.count])
                self.outPoints = Array(self.outPoints[self.outPoints.count-num..<self.outPoints.count])
            } else {
                let inOrigin = self.inPoints
                let outOrigin = self.outPoints
                self.inPoints = Array(repeating: nil, count: num)
                self.outPoints = Array(repeating: nil, count: num)
                self.inPoints.replaceSubrange(Range(uncheckedBounds: (lower: num-inOrigin.count, upper: num)), with: inOrigin)
                self.outPoints.replaceSubrange(Range(uncheckedBounds: (lower: num-outOrigin.count, upper: num)), with: outOrigin)
            }
        }
        self.displayIfVisible()
    }
    
    public func setScale(_ newScale: Scale, _ fixedScale: Double = 1) {}
    
    public func setReverseOrder(_ newValue: Bool) {
        guard self.reversedOrder != newValue else { return }
        self.write { self.reversedOrder = newValue }
        self.displayIfVisible()
    }
    
    public func setColors(in inColor: NSColor? = nil, out outColor: NSColor? = nil) {
        self.write {
            if let inColor { self.inColor = inColor }
            if let outColor { self.outColor = outColor }
        }
        self.displayIfVisible()
    }
    
    public func setTooltipState(_ newState: Bool) {}
    
    public func setLegend(x: Bool, y: Bool) {}
    
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        self.hostingView?.frame = NSRect(origin: .zero, size: newSize)
    }
}

public class PieChartView: ChartView {
    private var segments: [ColorValue] = []
    private var color: NSColor = NSColor.systemBlue
    private var filled: Bool = false
    private var drawValue: Bool = false
    private var drawNeedle: Bool = false
    private var openCircle: Bool = false
    private var usageValue: Double? = nil
    private var centerText: String? = nil
    private var activeSegment: Int? = nil
    private var nonActiveSegmentColor: NSColor = NSColor.lightGray
    
    private var hostingView: NSHostingView<PieChartContent>?
    
    public init(frame: NSRect = .zero, segments: [ColorValue] = [], filled: Bool = false, drawValue: Bool = false, drawNeedle: Bool = false, openCircle: Bool = false) {
        self.filled = filled
        self.drawValue = drawValue
        self.drawNeedle = drawNeedle
        self.openCircle = openCircle
        self.segments = segments
        
        super.init(frame: frame, queueLabel: "eu.exelban.Stats.Charts.Pie")
        
        let content = PieChartContent(segments: self.segments, openCircle: self.openCircle)
        let hostingView = NSHostingView<PieChartContent>(rootView: content)
        hostingView.frame = self.bounds
        hostingView.autoresizingMask = [.width, .height]
        self.addSubview(hostingView)
        self.hostingView = hostingView
        
        self.setAccessibilityElement(true)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func draw(_ rect: CGRect) {}
    
    override func updateSwiftUI() {
        let content = PieChartContent(
            segments: self.read { self.segments },
            openCircle: self.read { self.openCircle }
        )
        self.hostingView?.rootView = content
    }
    
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        self.hostingView?.frame = NSRect(origin: .zero, size: newSize)
    }
    
    public func setValue(_ value: Double) {
        let sanitized = value.isFinite ? value : 0
        self.write { self.usageValue = self.openCircle ? (sanitized > 1 ? sanitized/100 : sanitized) : sanitized }
        self.displayIfVisible()
    }
    
    public func setActiveSegment(_ index: Int) {
        self.write { self.activeSegment = index }
        self.displayIfVisible()
    }
    
    public func setText(_ value: String) {
        self.write { self.centerText = value }
        self.displayIfVisible()
    }
    
    public func setSegments(_ segments: [ColorValue]) {
        self.write { self.segments = segments }
        self.displayIfVisible()
    }
    
    public func setNonActiveSegmentColor(_ newColor: NSColor) {
        self.write {
            guard self.nonActiveSegmentColor != newColor else { return }
            self.nonActiveSegmentColor = newColor
        }
        self.displayIfVisible()
    }
}

public class TachometerGraphView: ChartView {
    private var filled: Bool
    private var segments: [ColorValue]
    
    public init(frame: NSRect = .zero, segments: [ColorValue], filled: Bool = true) {
        self.filled = filled
        self.segments = segments
        
        super.init(frame: frame, queueLabel: "eu.exelban.Stats.Charts.Tachometer")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func draw(_ rect: CGRect) {
        var filled: Bool = false
        var segments: [ColorValue] = []
        self.read {
            filled = self.filled
            segments = self.segments
        }
        
        let arcWidth: CGFloat = filled ? min(self.frame.width, self.frame.height) / 2 : 7
        let totalAmount = segments.reduce(0) { $0 + $1.value }
        if totalAmount < 1 {
            segments.append(ColorValue(Double(1-totalAmount), color: NSColor.lightGray.withAlphaComponent(0.5)))
        }
        
        let centerPoint = CGPoint(x: self.frame.width/2, y: self.frame.height/2)
        let radius = (min(self.frame.width, self.frame.height) - arcWidth) / 2
        
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldAntialias(true)
        context.setLineWidth(arcWidth)
        context.setLineCap(.butt)
        
        context.translateBy(x: self.frame.width, y: -4)
        context.scaleBy(x: -1, y: 1)
        
        let startAngle: CGFloat = 0
        let endCircle: CGFloat = CGFloat.pi
        var previousAngle = startAngle
        
        for segment in segments {
            let currentAngle: CGFloat = previousAngle + (CGFloat(segment.value) * endCircle)
            
            if let color = segment.color {
                context.setStrokeColor(color.cgColor)
            }
            context.addArc(center: centerPoint, radius: radius, startAngle: previousAngle, endAngle: currentAngle, clockwise: false)
            context.strokePath()
            
            previousAngle = currentAngle
        }
    }
    
    internal func setSegments(_ segments: [ColorValue]) {
        self.write { self.segments = segments }
        self.displayIfVisible()
    }
}

public class ColumnChartView: ChartView {
    private var values: [ColorValue] = []
    private var cursor: CGPoint? = nil
    
    public init(frame: NSRect = NSRect.zero, num: Int) {
        super.init(frame: frame, queueLabel: "eu.exelban.Stats.Charts.Column")
        self.values = Array(repeating: ColorValue(0, color: .controlAccentColor), count: num)
        
        self.addTrackingArea(NSTrackingArea(
            rect: CGRect(x: 0, y: 0, width: self.frame.width, height: self.frame.height),
            options: [
                .activeAlways,
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect
            ],
            owner: self, userInfo: nil
        ))
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        var values: [ColorValue] = []
        self.read {
            values = self.values
        }
        
        guard !values.isEmpty else { return }
        
        let blocks: Int = 16
        let spacing: CGFloat = 2
        let count: CGFloat = CGFloat(values.count)
        guard count > 0, self.frame.width > 0, self.frame.height > 0 else { return }
        
        let partitionSize: CGSize = CGSize(width: (self.frame.width - (count*spacing)) / count, height: self.frame.height)
        let blockSize = CGSize(width: partitionSize.width-(spacing*2), height: ((partitionSize.height - spacing - 1)/CGFloat(blocks))-1)
        
        var list: [(value: Double, path: NSBezierPath)] = []
        var x: CGFloat = 0
        for i in 0..<values.count {
            let partition = NSBezierPath(
                roundedRect: NSRect(x: x, y: 0, width: partitionSize.width, height: partitionSize.height),
                xRadius: 3, yRadius: 3
            )
            NSColor.underPageBackgroundColor.withAlphaComponent(0.5).setFill()
            partition.fill()
            partition.close()
            
            let value = values[i]
            let color = value.color ?? .controlAccentColor
            let activeBlockNum = Int(round(value.value*Double(blocks)))
            let h = value.value*(partitionSize.height-spacing)
            
            if dirtyRect.height < 30 && h != 0 {
                let block = NSBezierPath(
                    roundedRect: NSRect(x: x+spacing, y: 1, width: partitionSize.width-(spacing*2), height: h),
                    xRadius: 1, yRadius: 1
                )
                color.setFill()
                block.fill()
                block.close()
            } else {
                var y: CGFloat = spacing
                for b in 0..<blocks {
                    let block = NSBezierPath(
                        roundedRect: NSRect(x: x+spacing, y: y, width: blockSize.width, height: blockSize.height),
                        xRadius: 1, yRadius: 1
                    )
                    (activeBlockNum <= b ? NSColor.controlBackgroundColor.withAlphaComponent(0.4) : color).setFill()
                    block.fill()
                    block.close()
                    y += blockSize.height + 1
                }
            }
            
            x += partitionSize.width + spacing
            list.append((value: value.value, path: partition))
        }
        
        if let p = self.cursor {
            let matchingBlock = list.first(where: { $0.path.contains(p) })
            if let block = matchingBlock {
                let value = "\(Int(block.value.rounded(toPlaces: 2) * 100))%"
                let width: CGFloat = block.value == 1 ? 38 : block.value > 0.1 ? 32 : 24
                let tooltipX = min(p.x+4, self.frame.width - width)
                let tooltipY = min(p.y+4, self.frame.height - partitionSize.height)
                drawToolTip(self.frame, CGPoint(x: tooltipX, y: tooltipY), CGSize(width: width, height: min(partitionSize.height, self.frame.height)), value: value)
            }
        }
    }
    
    public func setValues(_ values: [ColorValue]) {
        self.write { self.values = values }
        self.displayIfVisible()
    }
    
    public override func mouseEntered(with event: NSEvent) {
        self.cursor = convert(event.locationInWindow, from: nil)
        self.display()
    }
    public override func mouseMoved(with event: NSEvent) {
        self.cursor = convert(event.locationInWindow, from: nil)
        self.display()
    }
    public override func mouseDragged(with event: NSEvent) {
        self.cursor = convert(event.locationInWindow, from: nil)
        self.display()
    }
    public override func mouseExited(with event: NSEvent) {
        self.cursor = nil
        self.display()
    }
    
    public override func updateTrackingAreas() {
        self.trackingAreas.forEach({ self.removeTrackingArea($0) })
        self.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [
                .activeAlways,
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect
            ],
            owner: self, userInfo: nil
        ))
        super.updateTrackingAreas()
    }
}

public class GridChartView: ChartView {
    private let okColor: NSColor = .systemGreen
    private let notOkColor: NSColor = .systemRed
    private let inactiveColor: NSColor = .underPageBackgroundColor.withAlphaComponent(0.4)
    
    private var values: [NSColor] = []
    private let grid: (rows: Int, columns: Int)
    
    public init(frame: NSRect, grid: (rows: Int, columns: Int)) {
        self.grid = grid
        super.init(frame: frame, queueLabel: "eu.exelban.Stats.Charts.Grid")
        let totalCells = max(grid.rows * grid.columns, 1)
        self.values = Array(repeating: self.inactiveColor, count: totalCells)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        var grid: (rows: Int, columns: Int) = (0, 0)
        var values: [NSColor] = []
        self.read {
            grid = self.grid
            values = self.values
        }
        
        let spacing: CGFloat = 2
        let size: CGSize = CGSize(
            width: (self.frame.width - ((CGFloat(grid.rows)-1) * spacing)) / CGFloat(grid.rows),
            height: (self.frame.height - ((CGFloat(grid.columns)-1) * spacing)) / CGFloat(grid.columns)
        )
        var origin: CGPoint = CGPoint(x: 0, y: (size.height + spacing) * CGFloat(grid.columns - 1))
        
        var i: Int = 0
        for _ in 0..<grid.columns {
            for _ in 0..<grid.rows {
                let box = NSBezierPath(roundedRect: NSRect(origin: origin, size: size), xRadius: 1, yRadius: 1)
                values[i].setFill()
                box.fill()
                box.close()
                i += 1
                origin.x += size.width + spacing
            }
            origin.x = 0
            origin.y -= size.height + spacing
        }
    }
    
    public func addValue(_ value: Bool) {
        self.write {
            self.values.remove(at: 0)
            self.values.append(value ? self.okColor : self.notOkColor)
        }
        self.displayIfVisible()
    }
}

public class BarChartView: ChartView {
    private var values: [[ColorValue]] = []
    private var cursor: CGPoint? = nil
    
    private var size: CGFloat?
    private var horizontal: Bool
    
    private var hostingView: NSHostingView<BarChartContent>?
    
    public init(frame: NSRect = NSRect.zero, size: CGFloat? = nil, horizontal: Bool = false) {
        self.size = size
        self.horizontal = horizontal
        
        super.init(frame: frame, queueLabel: "eu.exelban.Stats.Charts.Bar")
        
        let content = BarChartContent(values: self.values, horizontal: self.horizontal)
        let hostingView = NSHostingView<BarChartContent>(rootView: content)
        hostingView.frame = self.bounds
        hostingView.autoresizingMask = [.width, .height]
        self.addSubview(hostingView)
        self.hostingView = hostingView
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func draw(_ dirtyRect: NSRect) {}
    
    override func updateSwiftUI() {
        let content = BarChartContent(
            values: self.read { self.values },
            horizontal: self.read { self.horizontal }
        )
        self.hostingView?.rootView = content
    }
    
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        self.hostingView?.frame = NSRect(origin: .zero, size: newSize)
    }
    
    public func setValue(_ values: ColorValue) {
        self.write { self.values = [[values]] }
        self.displayIfVisible()
    }
    
    public func setValues(_ values: [ColorValue]) {
        self.write { self.values = [values] }
        self.displayIfVisible()
    }
    
    public func setValues(_ values: [[ColorValue]]) {
        self.write { self.values = values }
        self.displayIfVisible()
    }
}

public struct LineChartContent: View {
    let points: [DoubleValue]
    let color: Color
    let gradient: Gradient?
    let scale: Scale
    let fixedScale: Double
    let zeroValue: Double
    let minMax: Bool
    let suffix: String
    
    public init(points: [DoubleValue?], color: NSColor, gradient: NSGradient? = nil, scale: Scale = .none,
                fixedScale: Double = 1, zeroValue: Double = 0.01, minMax: Bool = false, suffix: String = "%") {
        self.points = points.compactMap { $0 }
        self.color = Color(color)
        if let nsGradient = gradient {
            var colors: [Color] = []
            for i in 0..<nsGradient.numberOfColorStops {
                var color = NSColor.black
                nsGradient.getColor(&color, location: nil, at: i)
                colors.append(Color(color))
            }
            self.gradient = Gradient(colors: colors)
        } else {
            self.gradient = nil
        }
        self.scale = scale
        self.fixedScale = fixedScale
        self.zeroValue = zeroValue
        self.minMax = minMax
        self.suffix = suffix
    }
    
    public var body: some View {
        let maxVal = points.map { $0.value }.max() ?? 0
        let domainMax = max(fixedScale, maxVal)
        
        Chart(points) { point in
            AreaMark(
                x: .value("Time", point.ts),
                y: .value("Value", point.value)
            )
            .foregroundStyle(gradient != nil ? AnyShapeStyle(LinearGradient(gradient: gradient!, startPoint: .bottom, endPoint: .top)) : AnyShapeStyle(color.opacity(0.5)))
            .interpolationMethod(.linear)
            
            LineMark(
                x: .value("Time", point.ts),
                y: .value("Value", point.value)
            )
            .foregroundStyle(color)
            .interpolationMethod(.linear)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...domainMax)
        .overlay(alignment: .topLeading) {
            if minMax, maxVal > 0 {
                Text("\(Int(maxVal * 100))\(suffix)")
                    .font(.system(size: 9, weight: .light))
                    .foregroundStyle(.secondary)
                    .padding(2)
            }
        }
    }
}

public struct BarChartContent: View {
    let values: [[ColorValue]]
    let horizontal: Bool
    
    public init(values: [[ColorValue]], horizontal: Bool = false) {
        self.values = values
        self.horizontal = horizontal
    }
    
    @ViewBuilder
    public var body: some View {
        let content = Chart {
            ForEach(values.indices, id: \.self) { barIndex in
                let bar = values[barIndex]
                ForEach(bar.indices, id: \.self) { itemIndex in
                    let item = bar[itemIndex]
                    let barLabel = "Bar \(barIndex)"
                    let itemColor: Color = item.color != nil ? Color(item.color!) : Color.accentColor
                    
                    if horizontal {
                        BarMark(
                            x: .value("Value", item.value),
                            y: .value("Bar", barLabel),
                            stacking: .standard
                        )
                        .foregroundStyle(itemColor)
                    } else {
                        BarMark(
                            x: .value("Bar", barLabel),
                            y: .value("Value", item.value),
                            stacking: .standard
                        )
                        .foregroundStyle(itemColor)
                    }
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .padding(0)
        
        if horizontal {
            content.chartXScale(domain: 0.0...1.0)
        } else {
            content.chartYScale(domain: 0.0...1.0)
        }
    }
}

public struct PieChartContent: View {
    let segments: [ColorValue]
    let openCircle: Bool
    
    public init(segments: [ColorValue], openCircle: Bool = false) {
        self.segments = segments
        self.openCircle = openCircle
    }
    
    public var body: some View {
        Chart(segments) { segment in
            SectorMark(
                angle: .value("Value", segment.value),
                innerRadius: .ratio(0.6),
                angularInset: 1.0
            )
            .cornerRadius(2)
            .foregroundStyle(segment.color != nil ? Color(segment.color!) : .accentColor)
        }
        .chartLegend(.hidden)
    }
}

public struct NetworkChartContent: View {
    let inPoints: [DoubleValue]
    let outPoints: [DoubleValue]
    let inColor: Color
    let outColor: Color
    let reversedOrder: Bool
    
    public init(inPoints: [DoubleValue?], outPoints: [DoubleValue?], inColor: NSColor, outColor: NSColor, reversedOrder: Bool = false) {
        self.inPoints = inPoints.compactMap { $0 }
        self.outPoints = outPoints.compactMap { $0 }
        self.inColor = Color(inColor)
        self.outColor = Color(outColor)
        self.reversedOrder = reversedOrder
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            if reversedOrder {
                chartView(points: inPoints, color: inColor, flip: true)
                chartView(points: outPoints, color: outColor, flip: false)
            } else {
                chartView(points: outPoints, color: outColor, flip: true)
                chartView(points: inPoints, color: inColor, flip: false)
            }
        }
    }
    
    @ViewBuilder
    private func chartView(points: [DoubleValue], color: Color, flip: Bool) -> some View {
        Chart(points) { point in
            AreaMark(
                x: .value("Time", point.ts),
                y: .value("Value", point.value)
            )
            .foregroundStyle(color.opacity(0.5))
            
            LineMark(
                x: .value("Time", point.ts),
                y: .value("Value", point.value)
            )
            .foregroundStyle(color)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .scaleEffect(y: flip ? -1 : 1)
    }
}
