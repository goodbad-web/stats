//
//  reader.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 10/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

import os

public enum ReaderActivityMode {
    case active
    case passive
    case paused
}

@MainActor public protocol Reader_p: Sendable {
    var name: String { get }
    var popup: Bool { get }
    var preview: Bool { get }
    var sleep: Bool { get }
    
    func setup()
    func read()
    func terminate()
    
    func start()
    func pause()
    func stop()
    
    func lock()
    func unlock()
    
    func initStoreValues(title: String)
    func setInterval(_ value: Int)
    func setActivityMode(_ mode: ReaderActivityMode)
    func sleepMode(state: Bool)
}

public protocol ReaderInternal_p {
    associatedtype T
    
    var value: T? { get }
    func read()
}

struct ReaderState<T> {
    var value: T?
    var active: Bool = false
    var locked: Bool = true
    var popup: Bool = false
    var preview: Bool = false
    var lastDBWrite: Date?
    var interval: Double? = nil
    var defaultInterval: Int = 1
}

private let efficiencyQueue = DispatchQueue(label: "eu.exelban.Stats.Efficiency", qos: .background)

@MainActor open class Reader<T: Codable & Sendable>: NSObject, ReaderInternal_p, @unchecked Sendable {
    nonisolated public var log: NextLog {
        NextLog.shared.copy(category: "\(String(describing: self))")
    }
    
    let stateLock = OSAllocatedUnfairLock(initialState: ReaderState<T>())
    
    nonisolated public var value: T? {
        get { self.stateLock.withLock { $0.value } }
        set { self.stateLock.withLock { $0.value = newValue } }
    }
    nonisolated public var active: Bool {
        get { self.stateLock.withLock { $0.active } }
        set { self.stateLock.withLock { $0.active = newValue } }
    }
    nonisolated private var locked: Bool {
        get { self.stateLock.withLock { $0.locked } }
        set { self.stateLock.withLock { $0.locked = newValue } }
    }
    nonisolated private var lastDBWrite: Date? {
        get { self.stateLock.withLock { $0.lastDBWrite } }
        set { self.stateLock.withLock { $0.lastDBWrite = newValue } }
    }
    nonisolated public let name: String
    nonisolated public var interval: Double? {
        get { self.stateLock.withLock { $0.interval } }
        set { self.stateLock.withLock { $0.interval = newValue } }
    }
    nonisolated public var defaultInterval: Int {
        get { self.stateLock.withLock { $0.defaultInterval } }
        set { self.stateLock.withLock { $0.defaultInterval = newValue } }
    }
    public var optional: Bool = false
    nonisolated public var popup: Bool {
        get { self.stateLock.withLock { $0.popup } }
        set { self.stateLock.withLock { $0.popup = newValue } }
    }
    nonisolated public var preview: Bool {
        get { self.stateLock.withLock { $0.preview } }
        set { self.stateLock.withLock { $0.preview = newValue } }
    }
    public var sleep: Bool = false
    
    public var alignToSecondBoundary: Bool = false
    public var alignOffset: TimeInterval = 0
    
    public var callbackHandler: (T?) -> Void
    public var observable = ObservableModel<T>()
    
    nonisolated private let module: ModuleType
    nonisolated public let metricID: MetricID
    nonisolated private let history: Bool
    nonisolated private let pipeline = MetricPipeline<T>()
    nonisolated private let cache = MetricCache<T>()
    nonisolated private let metricStore: LevelDBMetricHistoryStore
    nonisolated private let readLock = OSAllocatedUnfairLock(initialState: false)
    private var repeatTask: Repeater?
    private var initlizalized: Bool = false
    private var userInterval: Int?
    private var effectiveInterval: Int?
    private var activityMode: ReaderActivityMode = .active
    
    private var alignWorkItem: DispatchWorkItem?
    private let alignQueue = DispatchQueue(label: "eu.exelban.readerAlignQueue")
    
    public init(_ module: ModuleType, popup: Bool = false, preview: Bool = false, history: Bool = false, callback: @escaping (T?) -> Void = {_ in }) {
        let name = String(NSStringFromClass(type(of: self)).split(separator: ".").last ?? "unknown")
        self.name = name
        self.metricID = MetricID(module: module, reader: name)
        
        self.module = module
        self.history = history
        self.callbackHandler = callback
        self.metricStore = .shared
        
        super.init()
        self.popup = popup
        self.preview = preview
        self.configureMetricPipeline()
        self.metricStore.setup(T.self, id: self.metricID)
        if let lastValue = self.metricStore.latest(T.self, id: self.metricID) {
            self.stateLock.withLock { $0.value = lastValue }
            
            Task { @MainActor in
                callback(lastValue)
                self.observable.value = lastValue
            }
        }
        self.setup()
        
        if SystemKit.shared.device.platform != nil {
            self.alignToSecondBoundary = true
            self.alignOffset = Self.alignmentOffset(for: self.metricID.key)
        }
        
        debug("Successfully initialize reader", log: self.log)
    }
    
    deinit {
        if let value = self.value {
            let snapshot = MetricSnapshot(id: self.metricID, value: value, history: self.history)
            self.metricStore.save(snapshot, force: true)
        }
        let metricID = self.metricID
        Task {
            await SamplingScheduler.shared.remove(metricID)
        }
    }
    
    public func initStoreValues(title: String) {
        guard self.userInterval == nil else { return }
        let updateInterval = UserDefaultsSettingsStore.shared.int(
            AppSettingsKeys.moduleUpdateInterval(title, defaultValue: self.defaultInterval)
        )
        self.userInterval = updateInterval
        self.applyActivityMode(restart: false)
    }
    
    nonisolated public func callback(_ value: T?) {
        self.value = value
        if let value {
            self.pipeline.publish(MetricSnapshot(id: self.metricID, value: value, history: self.history))
        }
    }
    
    nonisolated open func read() {
        let isReading = self.readLock.withLock { $0 }
        guard !isReading else { return }
        self.readLock.withLock { $0 = true }

        Task(priority: .background) { [weak self] in
            defer { self?.readLock.withLock { $0 = false } }
            if let value = await self?.readAsync() {
                self?.callback(value)
            }
        }
    }

    nonisolated open func readAsync() async -> T? { return nil }
    open func setup() {}
    open func terminate() {}
    
    open func start() {
        if (self.popup || self.preview) && self.locked {
            efficiencyQueue.async {
                self.read()
            }
            return
        }
        
        if !self.initlizalized {
            if self.alignToSecondBoundary {
                self.startAlignedRepeater()
            } else {
                self.startNormalRepeater()
                self.repeatTask?.start()
            }
            self.initlizalized = true
        } else if (self.popup || self.sleep) && !self.active {
            self.repeatTask?.start()
        } else {
            self.repeatTask?.start()
        }
        
        self.active = true
    }
    
    open func pause() {
        self.alignWorkItem?.cancel()
        self.repeatTask?.pause()
        self.active = false
    }
    
    open func stop() {
        self.alignWorkItem?.cancel()
        self.repeatTask?.pause()
        self.repeatTask = nil
        self.active = false
        self.initlizalized = false
    }
    
    public func setInterval(_ value: Int) {
        guard self.userInterval != value else { return }
        debug("Set update interval: \(value) sec", log: self.log)
        self.userInterval = value
        self.applyActivityMode(restart: true)
    }
    
    public func setActivityMode(_ mode: ReaderActivityMode) {
        guard self.activityMode != mode else { return }
        debug("Set activity mode: \(mode)", log: self.log)
        self.activityMode = mode
        Task {
            await SamplingScheduler.shared.setMode(mode, for: self.metricID)
        }
        self.applyActivityMode(restart: false)
    }
    
    private func applyActivityMode(restart: Bool) {
        guard let userInterval = self.userInterval else { return }
        
        switch self.activityMode {
        case .active:
            self.applyInterval(userInterval, restart: restart)
        case .passive:
            self.applyInterval(max(userInterval * 5, 30), restart: restart)
        case .paused:
            self.pause()
        }
    }
    
    private func applyInterval(_ value: Int, restart: Bool) {
        guard self.effectiveInterval != value else {
            if self.initlizalized && !self.active {
                self.start()
            }
            return
        }
        self.effectiveInterval = value
        self.interval = Double(value)

        if self.alignToSecondBoundary {
            self.repeatTask?.pause()
            self.repeatTask = nil
            self.alignWorkItem?.cancel()
            if self.active {
                self.startAlignedRepeater()
            }
        } else {
            self.repeatTask?.reset(seconds: value, restart: restart)
        }
        
        if self.initlizalized && !self.active {
            self.start()
        }
    }
    
    public func save(_ value: T) {
        self.metricStore.save(MetricSnapshot(id: self.metricID, value: value, history: self.history), force: true)
    }

    private func configureMetricPipeline() {
        self.pipeline.subscribe { [weak self] snapshot in
            self?.cache.update(snapshot)
        }
        self.pipeline.subscribe { snapshot in
            RemoteMetricPublisher.shared.publish(snapshot)
        }
        self.pipeline.subscribe { [weak self] snapshot in
            guard let self else { return }
            
            let interval = self.interval ?? Double(self.defaultInterval)
            let now = Date()
            
            if let ts = self.lastDBWrite,
               now.timeIntervalSince(ts) <= interval * 10 {
                return
            }
            
            self.lastDBWrite = now
            Task.detached(priority: .background) {
                self.metricStore.save(snapshot, force: false)
            }
        }
        self.pipeline.subscribe { [weak self] snapshot in
            Task { @MainActor in
                self?.callbackHandler(snapshot.value)
                self?.observable.value = snapshot.value
            }
        }
    }
    
    private func delayToNextSecondBoundary() -> TimeInterval {
        let now = Date().addingTimeInterval(self.alignOffset)
        let fractional = now.timeIntervalSince1970.truncatingRemainder(dividingBy: 1.0)
        let baseDelay = (fractional == 0) ? 0.0 : (1.0 - fractional)
        let safety: TimeInterval = 0.005 // 5ms past the boundary
        return baseDelay + safety
    }

    private static func alignmentOffset(for key: String) -> TimeInterval {
        let bucket = key.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 10 }
        return TimeInterval(bucket) / 10.0
    }
    
    private func startNormalRepeater() {
        guard let interval = self.interval, self.repeatTask == nil else { return }
        
        if !self.popup && !self.preview {
            debug("Set up update interval: \(Int(interval)) sec", log: self.log)
        }
        
        self.repeatTask = Repeater(seconds: Int(interval)) { [weak self] in
            self?.read()
        }
    }
    
    private func startAlignedRepeater() {
        guard let interval = self.interval, self.repeatTask == nil else { return }
        
        if !self.popup && !self.preview {
            debug("Set up update interval: \(Int(interval)) sec (aligned)", log: self.log)
        }
        
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            
            self.read()
            self.repeatTask = Repeater(seconds: Int(interval)) { [weak self] in
                self?.read()
            }
            self.repeatTask?.start()
        }
        
        self.alignWorkItem?.cancel()
        self.alignWorkItem = work
        self.alignQueue.asyncAfter(deadline: .now() + self.delayToNextSecondBoundary(), execute: work)
    }
    
    public func sleepMode(state: Bool) {
        guard state != self.sleep else { return }

        debug("Sleep mode: \(state ? "on" : "off")", log: self.log)
        self.sleep = state

        if state {
            self.pause()
        } else {
            self.start()
        }
    }
}

extension Reader: Reader_p {
    public func lock() {
        self.locked = true
    }
    
    public func unlock() {
        self.locked = false
    }
}
