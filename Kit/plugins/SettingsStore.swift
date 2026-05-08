//
//  SettingsStore.swift
//  Kit
//
//  Created by Codex on 08/05/2026.
//

import Foundation

public struct SettingsKey<Value: Sendable>: Sendable {
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
    func set(_ key: SettingsKey<Bool>, value: Bool)
    func set(_ key: SettingsKey<Int>, value: Int)
    func set(_ key: SettingsKey<String>, value: String)
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
    
    public func set(_ key: SettingsKey<Bool>, value: Bool) {
        self.store.set(key: key.rawValue, value: value)
    }
    
    public func set(_ key: SettingsKey<Int>, value: Int) {
        self.store.set(key: key.rawValue, value: value)
    }
    
    public func set(_ key: SettingsKey<String>, value: String) {
        self.store.set(key: key.rawValue, value: value)
    }
}

public enum AppSettingsKeys {
    public static let pause = SettingsKey<Bool>("pause", defaultValue: false)
    
    public static func moduleState(_ module: String, defaultValue: Bool) -> SettingsKey<Bool> {
        SettingsKey<Bool>("\(module)_state", defaultValue: defaultValue)
    }
    
    public static func modulePosition(_ module: String) -> SettingsKey<Int> {
        SettingsKey<Int>("\(module)_position", defaultValue: 0)
    }
    
    public static func moduleUpdateInterval(_ module: String, defaultValue: Int) -> SettingsKey<Int> {
        SettingsKey<Int>("\(module)_updateInterval", defaultValue: defaultValue)
    }
}
