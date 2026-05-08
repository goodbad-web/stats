//
//  SettingsStore.swift
//  Kit
//
//  Created by Codex on 08/05/2026.
//

import Foundation

public struct SettingsKey<Value>: @unchecked Sendable {
    public let rawValue: String
    public let defaultValue: Value
    
    public init(_ rawValue: String, defaultValue: Value) {
        self.rawValue = rawValue
        self.defaultValue = defaultValue
    }
}

public protocol SettingsStore {
    func bool(_ key: SettingsKey<Bool>) -> Bool
    func int(_ key: SettingsKey<Int>) -> Int
    func string(_ key: SettingsKey<String>) -> String
    func array(_ key: SettingsKey<[Any]>) -> [Any]
    func exist<Value>(_ key: SettingsKey<Value>) -> Bool
    func remove<Value>(_ key: SettingsKey<Value>)
    func set(_ key: SettingsKey<Bool>, value: Bool)
    func set(_ key: SettingsKey<Int>, value: Int)
    func set(_ key: SettingsKey<String>, value: String)
    func set(_ key: SettingsKey<[Any]>, value: [Any])
}

public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    public static let shared = UserDefaultsSettingsStore()
    
    private let store: Store
    
    public init(store: Store = .shared) {
        self.store = store
    }
    
    public func bool(_ key: SettingsKey<Bool>) -> Bool {
        self.store.bool(key: key.rawValue, defaultValue: key.defaultValue)
    }
    
    public func int(_ key: SettingsKey<Int>) -> Int {
        self.store.int(key: key.rawValue, defaultValue: key.defaultValue)
    }
    
    public func string(_ key: SettingsKey<String>) -> String {
        self.store.string(key: key.rawValue, defaultValue: key.defaultValue)
    }

    public func array(_ key: SettingsKey<[Any]>) -> [Any] {
        self.store.array(key: key.rawValue, defaultValue: key.defaultValue)
    }

    public func exist<Value>(_ key: SettingsKey<Value>) -> Bool {
        self.store.exist(key: key.rawValue)
    }

    public func remove<Value>(_ key: SettingsKey<Value>) {
        self.store.remove(key.rawValue)
    }
    
    public func set(_ key: SettingsKey<Bool>, value: Bool) {
        self.store.set(key: key.rawValue, value: value)
    }
    
    public func set(_ key: SettingsKey<Int>, value: Int) {
        self.store.set(key: key.rawValue, value: value)
    }
    
    public func set(_ key: SettingsKey<String>, value: String) {
        self.store.set(key: key.rawValue, value: value)
    }

    public func set(_ key: SettingsKey<[Any]>, value: [Any]) {
        self.store.set(key: key.rawValue, value: value)
    }
}

public enum AppSettingsKeys {
    public static let pause = SettingsKey<Bool>("pause", defaultValue: false)
    public static let updateInterval = SettingsKey<String>("update-interval", defaultValue: AppUpdateInterval.silent.rawValue)
    public static let temperatureUnits = SettingsKey<String>("temperature_units", defaultValue: "system")
    public static let dockIcon = SettingsKey<Bool>("dockIcon", defaultValue: false)
    public static let runAtLoginInitialized = SettingsKey<Bool>("runAtLoginInitialized", defaultValue: false)
    public static let combinedModules = SettingsKey<Bool>("CombinedModules", defaultValue: false)
    public static let combinedModulesSpacing = SettingsKey<String>("CombinedModules_spacing", defaultValue: "none")
    public static let combinedModulesSeparator = SettingsKey<Bool>("CombinedModules_separator", defaultValue: false)
    public static let combinedModulesPopup = SettingsKey<Bool>("CombinedModules_popup", defaultValue: true)
    public static let combinedModulesPopupKeyboardShortcut = SettingsKey<[Any]>("CombinedModules_popup_keyboardShortcut", defaultValue: [])
    public static let globalOneView = SettingsKey<Bool>("OneView", defaultValue: false)
    
    public static func moduleState(_ module: String, defaultValue: Bool) -> SettingsKey<Bool> {
        SettingsKey<Bool>("\(module)_state", defaultValue: defaultValue)
    }
    
    public static func modulePosition(_ module: String) -> SettingsKey<Int> {
        SettingsKey<Int>("\(module)_position", defaultValue: 0)
    }
    
    public static func moduleUpdateInterval(_ module: String, defaultValue: Int) -> SettingsKey<Int> {
        SettingsKey<Int>("\(module)_updateInterval", defaultValue: defaultValue)
    }

    public static func moduleOneView(_ module: String, defaultValue: Bool = false) -> SettingsKey<Bool> {
        SettingsKey<Bool>("\(module)_oneView", defaultValue: defaultValue)
    }

    public static func modulePopupKeyboardShortcut(_ module: String) -> SettingsKey<[Any]> {
        SettingsKey<[Any]>("\(module)_popup_keyboardShortcut", defaultValue: [])
    }

    public static func widgetPosition(module: String, widget: widget_t) -> SettingsKey<Int> {
        SettingsKey<Int>("\(module)_\(widget)_position", defaultValue: 0)
    }

    public static func widgetList(module: String, defaultWidget: widget_t) -> SettingsKey<String> {
        SettingsKey<String>("\(module)_widget", defaultValue: defaultWidget.rawValue)
    }

    public static func widgetPreviewPosition(_ id: String) -> SettingsKey<Int> {
        SettingsKey<Int>("\(id)_position", defaultValue: 0)
    }

    public static func string(_ rawValue: String, defaultValue: String) -> SettingsKey<String> {
        SettingsKey<String>(rawValue, defaultValue: defaultValue)
    }

    public static func int(_ rawValue: String, defaultValue: Int) -> SettingsKey<Int> {
        SettingsKey<Int>(rawValue, defaultValue: defaultValue)
    }

    public static func bool(_ rawValue: String, defaultValue: Bool) -> SettingsKey<Bool> {
        SettingsKey<Bool>(rawValue, defaultValue: defaultValue)
    }
}
