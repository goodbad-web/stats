import Foundation
import os

public struct MetricID: Hashable, Sendable {
    public let module: String
    public let reader: String
    public let key: String
    
    public init(module: ModuleType, reader: String) {
        let m = String(module.stringValue)
        let r = String(reader)
        self.module = m
        self.reader = r
        self.key = m + "@" + r
    }
    
    public init(module: String, reader: String) {
        let m = String(module)
        let r = String(reader)
        self.module = m
        self.reader = r
        self.key = m + "@" + r
    }
}

public struct MetricSnapshot<Value: Codable & Sendable>: Sendable {
    public let id: MetricID
    public let value: Value
    public let timestamp: Date
    public let history: Bool
    
    public init(id: MetricID, value: Value, timestamp: Date = Date(), history: Bool = false) {
        self.id = id
        self.value = value
        self.timestamp = timestamp
        self.history = history
    }
}

public protocol MetricSampler: AnyObject {
    associatedtype Value: Codable & Sendable
    
    var metricID: MetricID { get }
    func read()
}

public protocol MetricStore {
    func setup<Value: Codable & Sendable>(_ type: Value.Type, id: MetricID)
    func latest<Value: Codable & Sendable>(_ type: Value.Type, id: MetricID) -> Value?
    func save<Value: Codable & Sendable>(_ snapshot: MetricSnapshot<Value>, force: Bool)
}

public final class MetricPipeline<Value: Codable & Sendable>: @unchecked Sendable {
    public typealias Subscriber = @Sendable (MetricSnapshot<Value>) -> Void
    
    private let stateLock = NSRecursiveLock()
    private nonisolated(unsafe) var state = PipelineState<Value>()
    
    public init() {}
    
    @discardableResult
    public func subscribe(_ subscriber: @escaping Subscriber) -> UUID {
        let id = UUID()
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        self.state.subscribers[id] = subscriber
        return id
    }
    
    public func unsubscribe(_ id: UUID) {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        self.state.subscribers.removeValue(forKey: id)
    }
    
    public func publish(_ snapshot: MetricSnapshot<Value>, removeDuplicates: Bool = false) {
        self.stateLock.lock()
        if self.state.isPublishing {
            self.stateLock.unlock()
            return
        }
        self.state.isPublishing = true
        
        let subscribers: [Subscriber] = {
            if removeDuplicates,
               let data = try? JSONEncoder().encode(snapshot.value),
               self.state.lastData == data {
                return []
            } else if removeDuplicates {
                self.state.lastData = try? JSONEncoder().encode(snapshot.value)
            }
            return Array(self.state.subscribers.values)
        }()
        self.stateLock.unlock()
        
        subscribers.forEach { $0(snapshot) }
        
        self.stateLock.lock()
        self.state.isPublishing = false
        self.stateLock.unlock()
    }
}

private struct PipelineState<Value: Codable & Sendable> {
    var subscribers: [UUID: MetricPipeline<Value>.Subscriber] = [:]
    var lastData: Data?
    var isPublishing: Bool = false
}

public final class LevelDBMetricHistoryStore: MetricStore, @unchecked Sendable {
    public static let shared = LevelDBMetricHistoryStore()
    
    private let db: DB
    
    public init(db: DB = .shared) {
        self.db = db
    }
    
    public func setup<Value: Codable & Sendable>(_ type: Value.Type, id: MetricID) {
        self.db.setup(type, id.key)
    }
    
    public func latest<Value: Codable & Sendable>(_ type: Value.Type, id: MetricID) -> Value? {
        self.db.findOne(type, key: id.key)
    }
    
    public func save<Value: Codable & Sendable>(_ snapshot: MetricSnapshot<Value>, force: Bool = false) {
        self.db.insert(key: snapshot.id.key, value: snapshot.value, ts: snapshot.history, force: force)
    }
}

public final class RemoteMetricPublisher: @unchecked Sendable {
    public static let shared = RemoteMetricPublisher()
    
    private let remote: Remote
    
    public init(remote: Remote = .shared) {
        self.remote = remote
    }
    
    public func publish<Value: Codable & Sendable>(_ snapshot: MetricSnapshot<Value>) {
        self.remote.send(key: snapshot.id.key, value: snapshot.value)
    }
}

public final class MetricCache<Value: Codable & Sendable>: @unchecked Sendable {
    private let stateLock = NSRecursiveLock()
    private nonisolated(unsafe) var state: MetricSnapshot<Value>? = nil
    
    public init() {}
    
    public var latest: MetricSnapshot<Value>? {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.state
    }
    
    public func update(_ snapshot: MetricSnapshot<Value>) {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        self.state = snapshot
    }
}

public enum SamplingPolicy {
    public static func mode(hasActiveValueWidget: Bool, detailVisible: Bool) -> ReaderActivityMode {
        hasActiveValueWidget || detailVisible ? .active : .passive
    }
    
    public static func detailMode(detailVisible: Bool) -> ReaderActivityMode {
        detailVisible ? .active : .paused
    }
    
    public static func popupMode(popupVisible: Bool) -> ReaderActivityMode {
        popupVisible ? .active : .paused
    }
}

public actor SamplingScheduler {
    public static let shared = SamplingScheduler()
    
    private var policies: [MetricID: ReaderActivityMode] = [:]
    
    public func setMode(_ mode: ReaderActivityMode, for id: MetricID) {
        self.policies[id] = mode
    }
    
    public func mode(for id: MetricID) -> ReaderActivityMode? {
        self.policies[id]
    }
    
    public func remove(_ id: MetricID) {
        self.policies.removeValue(forKey: id)
    }
}
