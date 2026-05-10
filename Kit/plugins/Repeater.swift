//
//  Repeater.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 27/06/2022.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2022 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation
import os

private enum RepeaterState {
    case paused
    case running
}

private struct RepeaterBucketState {
    var timer: DispatchSourceTimer?
    var callbacks: [UUID: () -> Void] = [:]
}

private final class RepeaterBucket {
    private let interval: Int
    private let queue: DispatchQueue
    private let lock = OSAllocatedUnfairLock(initialState: RepeaterBucketState())
    
    init(interval: Int) {
        self.interval = interval
        self.queue = DispatchQueue(label: "eu.exelban.Stats.Repeater.\(interval)", qos: .utility)
    }
    
    var isEmpty: Bool {
        self.lock.withLock { $0.callbacks.isEmpty }
    }
    
    func add(id: UUID, callback: @escaping () -> Void) {
        self.lock.withLock { state in
            state.callbacks[id] = callback
            if state.timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                let leeway = min(max(self.interval / 5, 1), 5)
                timer.schedule(
                    deadline: DispatchTime.now() + Double(self.interval),
                    repeating: .seconds(self.interval),
                    leeway: .seconds(leeway)
                )
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    let list = self.lock.withLock { Array($0.callbacks.values) }
                    list.forEach { $0() }
                }
                timer.resume()
                state.timer = timer
            }
        }
    }
    
    func remove(id: UUID) {
        self.lock.withLock { state in
            state.callbacks.removeValue(forKey: id)
            if state.callbacks.isEmpty {
                state.timer?.cancel()
                state.timer = nil
            }
        }
    }
}

private final class RepeaterScheduler {
    static let shared = RepeaterScheduler()
    
    private let lock = OSAllocatedUnfairLock(initialState: [Int: RepeaterBucket]())
    
    func add(id: UUID, interval: Int, callback: @escaping () -> Void) {
        let bucket = self.lock.withLock { lock in
            if let b = lock[interval] {
                return b
            }
            let b = RepeaterBucket(interval: interval)
            lock[interval] = b
            return b
        }
        bucket.add(id: id, callback: callback)
    }
    
    func remove(id: UUID, interval: Int) {
        self.lock.withLock { lock in
            guard let bucket = lock[interval] else { return }
            bucket.remove(id: id)
            if bucket.isEmpty {
                lock.removeValue(forKey: interval)
            }
        }
    }
}

private struct RepeaterInternalState {
    var state: RepeaterState = .paused
    var seconds: Int
}

internal class Repeater {
    private let id = UUID()
    private var callback: (() -> Void)
    private let lock: OSAllocatedUnfairLock<RepeaterInternalState>
    
    internal init(seconds: Int, callback: @escaping (() -> Void)) {
        self.callback = callback
        self.lock = OSAllocatedUnfairLock(initialState: RepeaterInternalState(seconds: seconds))
    }
    
    deinit {
        self.pause()
    }
    
    internal func start() {
        let (state, seconds) = self.lock.withLock { state in
            guard state.state == .paused else { return (state.state, state.seconds) }
            state.state = .running
            return (state.state, state.seconds)
        }
        
        if state == .running {
            RepeaterScheduler.shared.add(id: self.id, interval: seconds, callback: self.callback)
        }
    }
    
    internal func pause() {
        let (state, seconds) = self.lock.withLock { state in
            guard state.state == .running else { return (state.state, state.seconds) }
            state.state = .paused
            return (state.state, state.seconds)
        }
        
        if state == .paused {
            RepeaterScheduler.shared.remove(id: self.id, interval: seconds)
        }
    }
    
    internal func reset(seconds: Int, restart: Bool = false) {
        self.pause()
        self.lock.withLock { $0.seconds = seconds }
        
        if restart {
            self.callback()
        }
        self.start()
    }
}
