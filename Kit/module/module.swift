//
//  module.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 09/04/2020.
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

public var widgetsUserDefaults: UserDefaults? {
    guard let teamId = Bundle.main.object(forInfoDictionaryKey: "TeamId") as? String else {
        return nil
    }
    return UserDefaults(suiteName: "\(teamId).eu.exelban.Stats.widgets")
}

public struct module_c {
    public var name: String
    public var icon: NSImage?
    
    public var defaultState: Bool = false
    internal var defaultWidget: widget_t = .unknown
    internal var availableWidgets: [widget_t] = []
    
    internal var widgetsConfig: NSDictionary = NSDictionary()
    internal var settingsConfig: NSDictionary = NSDictionary()
    internal var previewConfig: NSDictionary = NSDictionary()
    
    public var hasPreview: Bool { self.previewConfig["enabled"] as? Bool ?? false }
    
    init(in path: String) {
        guard let dict = NSDictionary(contentsOfFile: path) else {
            fatalError("failed to initialize module: config.plist is missing or invalid")
        }
        
        if let name = dict["Name"] as? String {
            self.name = name
        } else {
            fatalError("failed to initialize module: name is missing in config.plist")
        }
        
        if let state = dict["State"] as? Bool {
            self.defaultState = state
        }
        if let symbol = dict["Symbol"] as? String {
            self.icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if self.icon == nil, let symbol = dict["AlternativeSymbol"] as? String {
            self.icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        
        if let widgetsDict = dict["Widgets"] as? NSDictionary {
            var list: [String: Int] = [:]
            self.widgetsConfig = widgetsDict
            
            for widgetName in widgetsDict.allKeys {
                if let widget = widget_t(rawValue: widgetName as! String) {
                    let widgetDict = widgetsDict[widgetName as! String] as? NSDictionary
                    if widgetDict?["Default"] as? Bool == true {
                        self.defaultWidget = widget
                    }
                    var order = 0
                    if let o = widgetDict?["Order"] as? Int {
                        order = o
                    }
                    
                    list[widgetName as! String] = order
                }
            }
            
            self.availableWidgets = list.sorted(by: { $0.1 < $1.1 }).map{ (widget_t(rawValue: $0.key) ?? .unknown) }
        }
        
        if let settingsDict = dict["Settings"] as? NSDictionary {
            self.settingsConfig = settingsDict
        }
        
        if let previewDict = dict["Preview"] as? NSDictionary {
            self.previewConfig = previewDict
        }
    }
}

@MainActor open class Module {
    public var config: module_c
    
    public var available: Bool = false
    public var enabled: Bool = false
    
    public var menuBar: MenuBar
    public var window: Window? = nil
    public let portal: Portal_p?
    
    public var name: String { config.name }
    public var combinedPosition: Int {
        get { UserDefaultsSettingsStore.shared.int(AppSettingsKeys.modulePosition(self.name)) }
        set { UserDefaultsSettingsStore.shared.set(AppSettingsKeys.modulePosition(self.name), value: newValue) }
    }
    public var userDefaults: UserDefaults? = {
        widgetsUserDefaults
    }()
    
    public var popupKeyboardShortcut: [UInt16] { self.popupView?.keyboardShortcut ?? [] }
    public var isPopupVisible: Bool { self.popupVisible }
    public var isSettingsWindowVisible: Bool { self.settingsWindowVisible }
    public var hasActiveValueWidget: Bool {
        self.menuBar.widgets.contains { $0.isActive && !($0.item is Label) }
    }
    
    private var moduleType: ModuleType
    
    private var settingsView: Settings_v? = nil
    private var popup: PopupWindow? = nil
    private var popupView: Popup_p? = nil
    private var notificationsView: NotificationsWrapper? = nil
    private var previewView: PreviewWrapper? = nil
    private var popupVisible: Bool = false
    private var settingsWindowVisible: Bool = false
    
    private let log: NextLog
    private var readers: [Reader_p] = []
    
    private var pauseState: Bool {
        get { UserDefaultsSettingsStore.shared.bool(AppSettingsKeys.pause) }
        set { UserDefaultsSettingsStore.shared.set(AppSettingsKeys.pause, value: newValue) }
    }
    
    public init(
        moduleType: ModuleType,
        popup: Popup_p? = nil,
        settings: Settings_v? = nil,
        portal: Portal_p? = nil,
        notifications: NotificationsWrapper? = nil,
        preview: PreviewWrapper? = nil
    ) {
        self.moduleType = moduleType
        self.portal = portal
        
        guard let path = Bundle(for: type(of: self)).path(forResource: "config", ofType: "plist") else {
             fatalError("failed to initialize module: config.plist not found in bundle")
        }
        self.config = module_c(in: path)
        
        self.log = NextLog.shared.copy(category: self.config.name)
        self.settingsView = settings
        self.popupView = popup
        self.notificationsView = notifications
        self.previewView = preview
        self.menuBar = MenuBar(moduleName: self.config.name)
        self.available = self.isAvailable()
        self.enabled = UserDefaultsSettingsStore.shared.bool(
            AppSettingsKeys.moduleState(self.config.name, defaultValue: self.config.defaultState)
        )
        self.userDefaults?.set(self.enabled, forKey: "\(self.config.name)_state")
        
        if !self.available {
            debug("Module is not available", log: self.log)
            
            if self.enabled {
                self.enabled = false
                UserDefaultsSettingsStore.shared.set(
                    AppSettingsKeys.moduleState(self.config.name, defaultValue: self.config.defaultState),
                    value: false
                )
            }
            
            return
        } else if self.pauseState {
            self.disable()
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(listenForMouseDownInSettings), name: .clickInSettings, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenForModuleToggle), name: .toggleModule, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenForPopupToggle), name: .togglePopup, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenForToggleWidget), name: .toggleWidget, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenForWindowOpen), name: .openWindow, object: nil)
        
        // swiftlint:disable empty_count
        if self.config.widgetsConfig.count != 0 {
            // swiftlint:enable empty_count
            self.initWidgets()
        } else {
            debug("Module started without widget", log: self.log)
        }
        
        self.window = Window(
            config: &self.config,
            widgets: &self.menuBar.widgets,
            modulePreview: self.previewView,
            moduleSettings: self.settingsView,
            popupSettings: self.popupView,
            notificationsSettings: self.notificationsView
        )
        
        self.popup = PopupWindow(title: self.config.name, module: self.moduleType, view: self.popupView, visibilityCallback: self.popupVisibilityCallback)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // load function which call when app start
    public func mount() {
        guard self.enabled else { return }
        self.readers.forEach { (reader: Reader_p) in
            reader.initStoreValues(title: self.config.name)
            reader.start()
        }
        self.menuBar.enable()
        self.updateReaderActivityModes()
    }
    
    // disable module
    public func unmount() {
        self.enabled = false
        self.available = false
    }
    
    // terminate function which call before app termination
    public func terminate() {
        self.willTerminate()
        self.readers.forEach{
            $0.stop()
            $0.terminate()
        }
        self.menuBar.disable()
        debug("Module terminated", log: self.log)
    }
    
    // function to call before module terminate
    open func willTerminate() {}
    
    // set module state to enabled
    public func enable() {
        guard self.available else { return }
        
        self.enabled = true
        UserDefaultsSettingsStore.shared.set(
            AppSettingsKeys.moduleState(self.config.name, defaultValue: self.config.defaultState),
            value: true
        )
        self.userDefaults?.set(true, forKey: "\(self.config.name)_state")
        self.readers.forEach { (reader: Reader_p) in
            reader.initStoreValues(title: self.config.name)
            reader.start()
        }
        self.menuBar.enable()
        self.updateReaderActivityModes()
        self.window?.setState(self.enabled)
        debug("Module enabled", log: self.log)
    }
    
    // set module state to disabled
    public func disable() {
        guard self.available else { return }
        
        self.enabled = false
        if !self.pauseState { // omit saving the disable state when toggle by pause, need for resume state restoration
            UserDefaultsSettingsStore.shared.set(
                AppSettingsKeys.moduleState(self.config.name, defaultValue: self.config.defaultState),
                value: false
            )
            self.userDefaults?.set(false, forKey: "\(self.config.name)_state")
        }
        self.readers.forEach{ $0.stop() }
        self.menuBar.disable()
        self.window?.setState(self.enabled)
        self.popupVisible = false
        self.settingsWindowVisible = false
        self.popup?.setIsVisible(false)
        debug("Module disabled", log: self.log)
    }
    
    public func setReaders(_ list: [Reader_p?]) {
        self.readers = list.filter({ $0 != nil }).map({ $0! as Reader_p })
    }
    
    open func updateReaderActivityModes() {}
    
    // determine if module is available (can be overrided in module)
    open func isAvailable() -> Bool { return true }
    
    // load the widget and set up. Calls when module init
    private func initWidgets() {
        guard self.available else { return }
        
        self.config.availableWidgets.forEach { (widgetType: widget_t) in
            if let widget = widgetType.new(
                module: self.config.name,
                config: self.config.widgetsConfig,
                defaultWidget: self.config.defaultWidget
            ) {
                self.menuBar.append(widget)
            }
        }
    }
    
    // call when popup appear/disappear
    private func popupVisibilityCallback(_ state: Bool) {
        self.popupVisible = state
        self.readers.filter{ $0.popup || $0.sleep }.forEach { (reader: Reader_p) in
            if state {
                reader.unlock()
                reader.start()
            } else {
                reader.pause()
                reader.lock()
            }
        }
        self.updateReaderActivityModes()
    }
    
    @objc private func listenForWindowOpen(_ notification: Notification) {
        guard let event = AppEventCenter.shared.openWindow(from: notification) else { return }
        var state = event.state
        
        if state, let name = event.module, self.config.name != name {
            state = false
        }
        self.settingsWindowVisible = state
        
        self.readers.filter{ $0.preview || $0.sleep }.forEach { (reader: Reader_p) in
            if state {
                reader.unlock()
                reader.start()
            } else {
                reader.pause()
                reader.lock()
            }
        }
        self.updateReaderActivityModes()
    }
    
    @objc private func listenForPopupToggle(_ notification: Notification) {
        guard let popup = self.popup,
              let event = AppEventCenter.shared.popupToggle(from: notification),
              let buttonOrigin = event.origin,
              let buttonCenter = event.center,
              self.config.name == event.module else {
            return
        }
        
        let openedWindows = NSApplication.shared.windows.filter{ $0 is NSPanel }
        openedWindows.forEach{ $0.setIsVisible(false) }
        
        var reopen: Bool = false
        if let widget = event.widget {
            reopen = popup.openedBy != nil && popup.openedBy != widget
            popup.openedBy = widget
        }
        
        if popup.occlusionState.rawValue == 8192 || reopen {
            NSApplication.shared.activate(ignoringOtherApps: true)
            
            popup.contentView?.invalidateIntrinsicContentSize()
            
            let windowCenter = popup.contentView!.intrinsicContentSize.width / 2
            var x = buttonOrigin.x - windowCenter + buttonCenter
            let y = buttonOrigin.y - popup.contentView!.intrinsicContentSize.height - 3
            
            let maxWidth = NSScreen.screens.map{ $0.frame.width }.reduce(0, +)
            if x + popup.contentView!.intrinsicContentSize.width > maxWidth {
                x = maxWidth - popup.contentView!.intrinsicContentSize.width - 3
            }
            
            popup.setFrameOrigin(NSPoint(x: x, y: y))
            popup.setIsVisible(true)
        } else {
            popup.locked = false
            popup.openedBy = nil
            popup.setIsVisible(false)
        }
    }
    
    @objc private func listenForModuleToggle(_ notification: Notification) {
        if let event = AppEventCenter.shared.moduleToggle(from: notification) {
            let name = event.module
            if name == self.config.name {
                if let state = event.state {
                    if state && !self.enabled {
                        self.enable()
                    } else if !state && self.enabled {
                        self.disable()
                    }
                } else {
                    if self.enabled {
                        self.disable()
                    } else {
                        self.enable()
                    }
                }
            }
            
            if self.pauseState == true {
                self.pauseState = false
                AppEventCenter.shared.post(.pause(false))
            }
        }
    }
    
    @objc private func listenForMouseDownInSettings() {
        if let popup = self.popup, popup.isVisible && !popup.locked {
            self.popup?.setIsVisible(false)
        }
    }
    
    @objc private func listenForToggleWidget(_ notification: Notification) {
        guard let name = notification.userInfo?["module"] as? String, name == self.config.name else {
            return
        }
        let isEmpty = self.menuBar.widgets.filter({ $0.isActive }).isEmpty
        if !isEmpty && !self.enabled {
            AppEventCenter.shared.post(.moduleToggle(module: self.config.name, state: true))
        }
        self.updateReaderActivityModes()
    }
}
