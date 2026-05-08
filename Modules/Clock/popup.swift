//
//  popup.swift
//  Clock
//
//  Created by Serhiy Mytrovtsiy on 24/03/2023
//  Using Swift 5.0
//  Running on macOS 13.2
//
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class Popup: PopupWrapper {
    private var list: [Clock_t] = []
    
    private var calendarView: CalendarView? = nil
    private var calendarState: Bool = true
    private var weekNumbersState: Bool = false
    
    public init(_ module: ModuleType) {
        super.init(module, frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))
        
        self.orientation = .vertical
        self.spacing = Constants.Popup.margins
        
        self.calendarState = UserDefaultsSettingsStore.shared.bool(AppSettingsKeys.moduleBool(self.title, "calendar", defaultValue: self.calendarState))
        self.weekNumbersState = UserDefaultsSettingsStore.shared.bool(AppSettingsKeys.moduleBool(self.title, "calendarWeekNumbers", defaultValue: self.weekNumbersState))
        self.calendarView = CalendarView(self.frame.width, showWeekNumbers: self.weekNumbersState)
        
        if let calendar = self.calendarView, self.calendarState {
            self.addArrangedSubview(calendar)
        }
        
        self.recalculateHeight()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    internal func callback(_ list: [Clock_t]) {
        defer { self.recalculateHeight() }
        
        var sorted = list.sorted(by: { $0.popupIndex < $1.popupIndex })
        var views = self.subviews.filter{ $0 is ClockView }.compactMap{ $0 as? ClockView }
        
        sorted = sorted.filter({ $0.popupState })
        
        if sorted.count < views.count && !views.isEmpty {
            views.forEach{ $0.removeFromSuperview() }
            views = []
        }
        
        sorted.forEach { (c: Clock_t) in
            if let view = views.first(where: { $0.clock.id == c.id }) {
                view.update(c)
            } else {
                self.addArrangedSubview(ClockView(width: self.frame.width, clock: c))
            }
        }
        
        self.list = sorted
    }
    
    private func recalculateHeight() {
        let h = self.arrangedSubviews.map({ $0.bounds.height + self.spacing }).reduce(0, +) - self.spacing
        if h > 0 && self.frame.size.height != h {
            self.setFrameSize(NSSize(width: self.frame.width, height: h))
            self.sizeCallback?(self.frame.size)
        }
    }
    
    public override func settings() -> NSView? {
        let view = SettingsContainerView()
        
        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Keyboard shortcut"), component: KeyboardShartcutView(
                callback: self.setKeyboardShortcut,
                value: self.keyboardShortcut
            ))
        ]))
        
        let hostingView = NSHostingView(rootView: ClockPopupPreferencesView(
            calendarState: Binding(get: { self.calendarState }, set: { self.toggleCalendar(state: $0) }),
            weekNumbersState: Binding(get: { self.weekNumbersState }, set: { self.toggleWeekNumbers(state: $0) }),
            list: Binding(get: { self.list }, set: { newList in
                self.list = newList
                self.rearrange()
            })
        ))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addArrangedSubview(hostingView)
        
        NSLayoutConstraint.activate([
            hostingView.widthAnchor.constraint(equalTo: view.widthAnchor),
            hostingView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
        
        return view
    }
    
    public override func appear() {
        if self.calendarState {
            self.calendarView?.checkCurrentDay()
        }
    }
    
    private func rearrange() {
        let views = self.subviews.filter{ $0 is ClockView }.compactMap{ $0 as? ClockView }
        views.forEach{ $0.removeFromSuperview() }
        self.callback(self.list)
    }
    
    private func toggleCalendar(state: Bool) {
        self.calendarState = state
        UserDefaultsSettingsStore.shared.set(AppSettingsKeys.moduleBool(self.title, "calendar", defaultValue: self.calendarState), value: self.calendarState)
        
        guard let view = self.calendarView else { return }
        if self.calendarState {
            self.insertArrangedSubview(view, at: 0)
        } else {
            view.removeFromSuperview()
        }
        self.recalculateHeight()
    }
    
    private func toggleWeekNumbers(state: Bool) {
        self.weekNumbersState = state
        UserDefaultsSettingsStore.shared.set(AppSettingsKeys.moduleBool(self.title, "calendarWeekNumbers", defaultValue: self.weekNumbersState), value: self.weekNumbersState)
        self.calendarView?.setShowWeekNumbers(self.weekNumbersState)
        self.recalculateHeight()
    }
}

import SwiftUI

struct ClockPopupPreferencesView: View {
    @Binding var calendarState: Bool
    @Binding var weekNumbersState: Bool
    @Binding var list: [Clock_t]
    
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Toggle(localizedString("Calendar"), isOn: $calendarState)
                Toggle(localizedString("Show week numbers"), isOn: $weekNumbersState)
            }
            .padding()
            
            List {
                ForEach($list, id: \.id) { $item in
                    HStack {
                        Text(item.name)
                        Spacer()
                        Toggle("", isOn: Binding(get: {
                            item.popupState
                        }, set: { newValue in
                            if let index = list.firstIndex(where: { $0.id == item.id }) {
                                list[index].popupState = newValue
                            }
                        }))
                        .labelsHidden()
                    }
                }
                .onMove { indices, newOffset in
                    list.move(fromOffsets: indices, toOffset: newOffset)
                    for i in list.indices {
                        list[i].popupIndex = i
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(height: 120)
        }
    }
}

private class CalendarView: NSStackView {
    private var itemSize: CGSize
    private var showWeekNumbers: Bool
    private var navigationHeightConstraint: NSLayoutConstraint?
    
    private var year: Int
    private var month: Int
    private var day: Int
    
    private var currentYear: Int {
        Calendar.current.component(.year, from: Date())
    }
    private var currentMonth: Int {
        Calendar.current.component(.month, from: Date())
    }
    private var currentDay: Int {
        Calendar.current.component(.day, from: Date())
    }
    
    private var weekDays: [String] {
        let calendar = Calendar.current
        let firstWeekdayIndex = calendar.firstWeekday - 1
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale.current
        dateFormatter.calendar = calendar
        let weekdaySymbols = dateFormatter.shortWeekdaySymbols
        return Array(weekdaySymbols![firstWeekdayIndex...]) + weekdaySymbols![..<firstWeekdayIndex]
    }
    
    private var grid: NSGridView = NSGridView()
    private var current: NSTextField = NSTextField()
    
    init(_ width: CGFloat, showWeekNumbers: Bool) {
        self.showWeekNumbers = showWeekNumbers
        self.itemSize = NSSize.zero
        self.year = Calendar.current.component(.year, from: Date())
        self.month = Calendar.current.component(.month, from: Date())
        self.day = Calendar.current.component(.day, from: Date())
        
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: width - 32))
        self.setAccessibilityElement(true)
        self.toolTip = localizedString("Calendar")
        
        self.spacing = 0
        self.orientation = .vertical
        self.edgeInsets = .init(
            top: Constants.Popup.spacing,
            left: Constants.Popup.margins,
            bottom: Constants.Popup.spacing,
            right: Constants.Popup.margins
        )
        self.wantsLayer = true
        self.layer?.cornerRadius = 2
        
        self.updateItemSize()
        self.addArrangedSubview(self.navigation())
        self.setup()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func checkCurrentDay() {
        guard self.day != self.currentDay || self.month != self.currentMonth || self.year != self.currentYear else { return }
        
        self.year = self.currentYear
        self.month = self.currentMonth
        self.day = self.currentDay
        
        self.setup()
    }
    
    public func setShowWeekNumbers(_ state: Bool) {
        guard self.showWeekNumbers != state else { return }
        self.showWeekNumbers = state
        self.updateItemSize()
        self.setup()
    }
    
    override func updateLayer() {
        self.layer?.backgroundColor = (isDarkMode ? NSColor(red: 17/255, green: 17/255, blue: 17/255, alpha: 0.25) : NSColor(red: 245/255, green: 245/255, blue: 245/255, alpha: 1)).cgColor
    }
    
    private func setup() {
        self.grid.removeFromSuperview()
        
        let grid = NSGridView()
        grid.rowSpacing = 0
        grid.columnSpacing = 0
        
        var headerRow: [NSView] = []
        if self.showWeekNumbers {
            headerRow.append(self.weekNumberHeaderItem())
        }
        headerRow.append(contentsOf: self.weekDays.map { headerItem($0) })
        grid.addRow(with: headerRow)
          
        let weeks = self.generateDays(for: self.month, in: self.year)
        for week in weeks {
            var labels: [NSView] = []
            if self.showWeekNumbers {
                labels.append(self.weekNumberItem(week))
            }
            labels.append(contentsOf: week.map { rowItem($0) })
            grid.addRow(with: labels)
        }
        
        self.grid = grid
        self.current.stringValue = "\(Calendar.current.standaloneMonthSymbols[self.month-1]) \(self.year)"
        
        self.addArrangedSubview(grid)
    }
    
    private func navigation() -> NSView {
        let view = NSStackView()
        view.distribution = .fill
        view.alignment = .centerY
        self.navigationHeightConstraint = view.heightAnchor.constraint(greaterThanOrEqualToConstant: max(self.itemSize.height, 24))
        self.navigationHeightConstraint?.isActive = true
        view.orientation = .horizontal
        
        let details = NSTextField(labelWithString: "\(Calendar.current.standaloneMonthSymbols[self.month-1]) \(self.year)")
        details.font = .systemFont(ofSize: 16, weight: .medium)
        details.lineBreakMode = .byTruncatingTail
        details.maximumNumberOfLines = 1
        details.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.current = details
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)
        
        let prev = NSButton()
        prev.bezelStyle = .regularSquare
        prev.translatesAutoresizingMaskIntoConstraints = false
        prev.imageScaling = .scaleNone
        prev.image = iconFromSymbol(name: "arrow.left", scale: .medium)
        prev.contentTintColor = .labelColor
        prev.isBordered = false
        prev.action = #selector(self.prevMonth)
        prev.target = self
        prev.toolTip = localizedString("Previous month")
        prev.focusRingType = .none
        
        let next = NSButton()
        next.bezelStyle = .regularSquare
        next.translatesAutoresizingMaskIntoConstraints = false
        next.imageScaling = .scaleNone
        next.image = iconFromSymbol(name: "arrow.right", scale: .medium)
        next.contentTintColor = .labelColor
        next.isBordered = false
        next.action = #selector(self.nextMonth)
        next.target = self
        next.toolTip = localizedString("Next month")
        next.focusRingType = .none
        
        buttons.addArrangedSubview(prev)
        buttons.addArrangedSubview(next)
        
        view.addArrangedSubview(details)
        view.addArrangedSubview(NSView())
        view.addArrangedSubview(buttons)
        
        return view
    }
    
    private func updateItemSize() {
        let columns: CGFloat = self.showWeekNumbers ? 8 : 7
        self.itemSize = NSSize(
            width: (self.frame.width-(Constants.Popup.margins*2))/columns,
            height: (self.frame.width-(Constants.Popup.spacing*2))/8 - 4
        )
        self.navigationHeightConstraint?.constant = max(self.itemSize.height, 24)
    }
    
    private func headerItem(_ value: String) -> NSView {
        let view = NSTextField()
        let cell = VerticallyCenteredTextFieldCell(textCell: value)
        view.cell = cell
        view.alignment = .center
        view.textColor = .gray
        view.font = .systemFont(ofSize: 12)
        view.widthAnchor.constraint(equalToConstant: self.itemSize.width).isActive = true
        view.heightAnchor.constraint(equalToConstant: self.itemSize.height).isActive = true
        return view
    }
    
    private func rowItem(_ day: DateComponents) -> NSView {
        if day.year == self.currentYear && day.month == self.currentMonth && day.day == self.currentDay {
            return self.todayItem()
        }
        let view = NSTextField()
        let cell = VerticallyCenteredTextFieldCell(textCell: "\(day.day ?? 0)")
        view.cell = cell
        view.alignment = .center
        if day.month != self.month {
            view.textColor = .lightGray
        }
        
        view.widthAnchor.constraint(equalToConstant: self.itemSize.width).isActive = true
        view.heightAnchor.constraint(equalToConstant: self.itemSize.height).isActive = true
        return view
    }
    
    private func weekNumberHeaderItem() -> NSView {
        let view = NSTextField()
        let cell = VerticallyCenteredTextFieldCell(textCell: "")
        view.cell = cell
        view.alignment = .center
        view.textColor = .secondaryLabelColor
        view.font = .systemFont(ofSize: 11)
        view.widthAnchor.constraint(equalToConstant: self.itemSize.width).isActive = true
        view.heightAnchor.constraint(equalToConstant: self.itemSize.height).isActive = true
        self.addRightBorder(view)
        return view
    }
    
    private func weekNumberItem(_ week: [DateComponents]) -> NSView {
        let calendar = Calendar.current
        let firstDate = week.compactMap { calendar.date(from: $0) }.first ?? Date()
        let weekNumber = calendar.component(.weekOfYear, from: firstDate)
        
        let view = NSTextField()
        let cell = VerticallyCenteredTextFieldCell(textCell: "\(weekNumber)")
        view.cell = cell
        view.alignment = .center
        view.textColor = .secondaryLabelColor
        view.font = .systemFont(ofSize: 11)
        view.widthAnchor.constraint(equalToConstant: self.itemSize.width).isActive = true
        view.heightAnchor.constraint(equalToConstant: self.itemSize.height).isActive = true
        self.addRightBorder(view)
        return view
    }
    
    private func addRightBorder(_ view: NSView) {
        let border = NSView()
        border.wantsLayer = true
        let borderColor = self.isDarkMode
            ? NSColor.white.withAlphaComponent(0.4)
            : NSColor.separatorColor
        border.layer?.backgroundColor = borderColor.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(border)
        
        let lineWidth = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
        NSLayoutConstraint.activate([
            border.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            border.topAnchor.constraint(equalTo: view.topAnchor),
            border.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            border.widthAnchor.constraint(equalToConstant: lineWidth)
        ])
    }
    
    private func todayItem() -> NSView {
        let view = NSView()
        
        let size: CGFloat = 25
        let circle = NSView(frame: NSRect(x: (self.itemSize.width-size)/2, y: (self.itemSize.height-size)/2, width: size, height: size))
        circle.wantsLayer = true
        circle.layer?.backgroundColor = NSColor.systemRed.cgColor
        circle.layer?.cornerRadius = size/2
        
        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        let cell = VerticallyCenteredTextFieldCell(textCell: "\(self.currentDay)")
        field.cell = cell
        field.alignment = .center
        field.textColor = .white
        
        view.addSubview(circle)
        view.addSubview(field)
        
        view.widthAnchor.constraint(equalToConstant: self.itemSize.width).isActive = true
        view.heightAnchor.constraint(equalToConstant: self.itemSize.height).isActive = true
        field.widthAnchor.constraint(equalToConstant: self.itemSize.width).isActive = true
        field.heightAnchor.constraint(equalToConstant: self.itemSize.height).isActive = true
        return view
    }
    
    private func generateDays(for month: Int, in year: Int) -> [[DateComponents]] {
        let calendar = Calendar.current
        let dateComponents = DateComponents(year: year, month: month)
        
        guard let range = calendar.range(of: .day, in: .month, for: calendar.date(from: dateComponents)!),
              let firstDayOfMonth = calendar.date(from: dateComponents),
              let firstWeekdayOfMonth = calendar.dateComponents([.weekday], from: firstDayOfMonth).weekday else {
            return []
        }
        
        let localeFirstWeekday = calendar.firstWeekday
        let daysFromPreviousMonth = (firstWeekdayOfMonth - localeFirstWeekday + 7) % 7
        
        var previousMonthComponents = dateComponents
        previousMonthComponents.month = (month == 1) ? 12 : month - 1
        previousMonthComponents.year = (month == 1) ? year - 1 : year
        
        let previousMonthDate = calendar.date(from: previousMonthComponents)!
        let previousMonthRange = calendar.range(of: .day, in: .month, for: previousMonthDate)!
        let lastDayOfPreviousMonth = previousMonthRange.upperBound - 1
        
        var nextMonthComponents = dateComponents
        nextMonthComponents.month = (month == 12) ? 1 : month + 1
        nextMonthComponents.year = (month == 12) ? year + 1 : year
        
        var weeks = [[DateComponents]]()
        var currentWeek = [DateComponents]()
        let validDaysFromPreviousMonth = min(daysFromPreviousMonth, lastDayOfPreviousMonth)
        if validDaysFromPreviousMonth > 0 {
            for day in (lastDayOfPreviousMonth - validDaysFromPreviousMonth + 1)...lastDayOfPreviousMonth {
                var components = previousMonthComponents
                components.day = day
                currentWeek.append(components)
            }
        }
        
        for day in range {
            var components = dateComponents
            components.day = day
            currentWeek.append(components)
            if currentWeek.count == 7 {
                weeks.append(currentWeek)
                currentWeek = []
            }
        }
        
        var nextMonthDay = 1
        while currentWeek.count < 7 {
            var components = nextMonthComponents
            components.day = nextMonthDay
            currentWeek.append(components)
            nextMonthDay += 1
        }
        weeks.append(currentWeek)
        
        if weeks.count < 6 {
            currentWeek = []
            for _ in 1...7 {
                var components = nextMonthComponents
                components.day = nextMonthDay
                currentWeek.append(components)
                nextMonthDay += 1
            }
            weeks.append(currentWeek)
        }
        
        return weeks
    }
    
    @objc private func prevMonth() {
        self.month -= 1
        if self.month < 1 {
            self.month = 12
            self.year -= 1
        }
        self.setup()
    }
    @objc private func nextMonth() {
        self.month += 1
        if self.month > 12 {
            self.month = 1
            self.year += 1
        }
        self.setup()
    }
}

internal class ClockView: NSStackView {
    public var clock: Clock_t
    
    open override var intrinsicContentSize: CGSize {
        return CGSize(width: self.bounds.width, height: self.bounds.height)
    }
    
    private var ready: Bool = false
    
    private let clockView: ClockChart = ClockChart(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
    private let nameField: NSTextField = TextView()
    private let timeField: NSTextField = TextView()
    
    init(width: CGFloat, clock: Clock_t) {
        self.clock = clock
        
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 44))
        
        self.orientation = .horizontal
        self.spacing = 5
        self.edgeInsets = NSEdgeInsets(
            top: 5,
            left: 5,
            bottom: 5,
            right: 5
        )
        self.wantsLayer = true
        self.layer?.cornerRadius = 2
        self.setAccessibilityElement(true)
        self.toolTip = "\(clock.name): \(clock.formatted())"
        
        self.clockView.widthAnchor.constraint(equalToConstant: 34).isActive = true
        
        let container: NSStackView = NSStackView()
        container.orientation = .vertical
        container.spacing = 2
        container.distribution = .fillEqually
        container.alignment = .left
        
        self.nameField.font = NSFont.systemFont(ofSize: 11, weight: .light)
        self.setTZ()
        self.nameField.cell?.truncatesLastVisibleLine = true
        
        self.timeField.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        self.timeField.stringValue = clock.formatted()
        self.timeField.cell?.truncatesLastVisibleLine = true
        
        container.addArrangedSubview(self.nameField)
        container.addArrangedSubview(self.timeField)
        
        self.addArrangedSubview(self.clockView)
        self.addArrangedSubview(container)
        
        self.update(clock)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func updateLayer() {
        self.layer?.backgroundColor = (isDarkMode ? NSColor(red: 17/255, green: 17/255, blue: 17/255, alpha: 0.25) : NSColor(red: 245/255, green: 245/255, blue: 245/255, alpha: 1)).cgColor
    }
    
    private func setTZ() {
        self.nameField.stringValue = "\(self.clock.name)"
        if let tz = Clock.zones.first(where: { $0.key == self.clock.tz }), tz.key != "local" {
            self.nameField.stringValue += " (\(tz.value))"
        }
    }
    
    public func update(_ newClock: Clock_t) {
        if self.clock.tz != newClock.tz || self.clock.name != newClock.name {
            self.clock = newClock
            self.setTZ()
        }
        
        if (self.window?.isVisible ?? false) || !self.ready {
            self.timeField.stringValue = newClock.formatted()
            if let value = newClock.value {
                self.clockView.setValue(value.convertToTimeZone(TimeZone(from: newClock.tz)))
            }
            self.ready = true
        }
    }
}

internal class ClockChart: NSView {
    private var color: NSColor = SColor.systemAccent.additional as! NSColor
    
    private let calendar = Calendar.current
    private var hour: Int = 0
    private var minute: Int = 0
    private var second: Int = 0
    
    private let hourLayer = CALayer()
    private let minuteLayer = CALayer()
    private let secondsLayer = CALayer()
    private let pinLayer = CAShapeLayer()
    
    override init(frame: CGRect = NSRect.zero) {
        super.init(frame: frame)
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState()
        context.setFillColor(NSColor.controlBackgroundColor.cgColor)
        context.setStrokeColor((isDarkMode ? NSColor.darkGray : NSColor.lightGray).cgColor)
        context.setLineWidth(1)
        context.addEllipse(in: CGRect(x: 0, y: 0, width: self.frame.width, height: self.frame.height))
        context.drawPath(using: .fillStroke)
        context.restoreGState()
        
        let anchor = CGPoint(x: 0.5, y: 0)
        let center = CGPoint(x: self.frame.size.width / 2, y: self.frame.size.height / 2)
        
        let hourAngle: CGFloat = CGFloat(Double(hour) * (360.0 / 12.0)) + CGFloat(Double(minute) * (1.0 / 60.0) * (360.0 / 12.0))
        let minuteAngle: CGFloat = CGFloat(minute) * CGFloat(360.0 / 60.0)
        let secondsAngle: CGFloat = CGFloat(self.second) * CGFloat(360.0 / 60.0)
        
        self.hourLayer.backgroundColor = NSColor.labelColor.cgColor
        self.hourLayer.anchorPoint = anchor
        self.hourLayer.position = center
        self.hourLayer.cornerRadius = 2
        self.hourLayer.bounds = CGRect(x: 0, y: 0, width: 2, height: self.frame.size.width / 2 - 4)
        self.hourLayer.transform = CATransform3DMakeRotation(-hourAngle / 180 * CGFloat(Double.pi), 0, 0, 1)
        self.layer?.addSublayer(self.hourLayer)
        
        self.minuteLayer.backgroundColor = NSColor.secondaryLabelColor.cgColor
        self.minuteLayer.anchorPoint = anchor
        self.minuteLayer.position = center
        self.minuteLayer.cornerRadius = 2
        self.minuteLayer.bounds = CGRect(x: 0, y: 0, width: 2, height: self.frame.size.width / 2 - 2)
        self.minuteLayer.transform = CATransform3DMakeRotation(-minuteAngle / 180 * CGFloat(Double.pi), 0, 0, 1)
        self.layer?.addSublayer(self.minuteLayer)
        
        self.secondsLayer.backgroundColor = NSColor.red.cgColor
        self.secondsLayer.anchorPoint = anchor
        self.secondsLayer.position = center
        self.secondsLayer.cornerRadius = 1
        self.secondsLayer.bounds = CGRect(x: 0, y: 0, width: 1, height: self.frame.size.width / 2 - 1)
        self.secondsLayer.transform = CATransform3DMakeRotation(-secondsAngle / 180 * CGFloat(Double.pi), 0, 0, 1)
        self.layer?.addSublayer(self.secondsLayer)
        
        self.pinLayer.fillColor = NSColor.controlBackgroundColor.cgColor
        self.pinLayer.strokeColor = (isDarkMode ? NSColor.darkGray : NSColor.lightGray).cgColor
        self.pinLayer.anchorPoint = anchor
        self.pinLayer.path = CGMutablePath(roundedRect: CGRect(
            x: center.x - 3 / 2,
            y: center.y - 3 / 2,
            width: 3,
            height: 3
        ), cornerWidth: 4, cornerHeight: 4, transform: nil)
        self.layer?.addSublayer(self.pinLayer)
    }
    
    public func setValue(_ value: Date) {
        self.hour = self.calendar.component(.hour, from: value)
        self.minute = self.calendar.component(.minute, from: value)
        self.second = self.calendar.component(.second, from: value)
        
        DispatchQueue.main.async(execute: {
            self.display()
        })
    }
}
