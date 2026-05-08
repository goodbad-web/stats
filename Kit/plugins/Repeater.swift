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

private final class RepeaterBucket {
    private let interval: Int
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private let callbacks = OSAllocatedUnfairLock(initialState: [UUID: () -> Void]())
    
    init(interval: Int) {
        self.interval = interval
        self.queue = DispatchQueue(label: "eu.exelban.Stats.Repeater.\(interval)", qos: .default)
    }
    
    var isEmpty: Bool {
        self.callbacks.withLock { $0.isEmpty }
    }
    
    func add(id: UUID, callback: @escaping () -> Void) {
        self.callbacks.withLock { $0[id] = callback }
        if self.timer == nil {
            self.startTimer()
        }
    }
    
    func remove(id: UUID) {
        let isEmpty = self.callbacks.withLock { callbacks in
            callbacks.removeValue(forKey: id)
            return callbacks.isEmpty
        }
        if isEmpty {
            self.timer?.cancel()
            self.timer = nil
        }
    }
    
    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(
            deadline: DispatchTime.now() + Double(self.interval),
            repeating: .seconds(self.interval),
            leeway: .milliseconds(250)
        )
        timer.setEventHandler { [weak self] in
            let callbacks = self?.callbacks.withLock { Array($0.values) } ?? []
            callbacks.forEach { $0() }
        }
        timer.resume()
        self.timer = timer
    }
}

private final class RepeaterScheduler {
    static let shared = RepeaterScheduler()
    
    private let lock = OSAllocatedUnfairLock(initialState: [Int: RepeaterBucket]())
    
    func add(id: UUID, interval: Int, callback: @escaping () -> Void) {
        self.lock.withLock { buckets in
            let bucket = buckets[interval] ?? RepeaterBucket(interval: interval)
            bucket.add(id: id, callback: callback)
            buckets[interval] = bucket
        }
    }
    
    func remove(id: UUID, interval: Int) {
        self.lock.withLock { buckets in
            guard let bucket = buckets[interval] else { return }
            bucket.remove(id: id)
            if bucket.isEmpty {
                buckets.removeValue(forKey: interval)
            }
        }
    }
}

internal class Repeater {
    private let id = UUID()
    private var callback: (() -> Void)
    private var state: RepeaterState = .paused
    private var seconds: Int
    
    internal init(seconds: Int, callback: @escaping (() -> Void)) {
        self.seconds = seconds
        self.callback = callback
    }
    
    deinit {
        self.pause()
    }
    
    internal func start() {
        guard self.state == .paused else { return }
        
        RepeaterScheduler.shared.add(id: self.id, interval: self.seconds, callback: self.callback)
        self.state = .running
    }
    
    internal func pause() {
        guard self.state == .running else { return }
        
        RepeaterScheduler.shared.remove(id: self.id, interval: self.seconds)
        self.state = .paused
    }
    
    internal func reset(seconds: Int, restart: Bool = false) {
        let wasRunning = self.state == .running
        if self.state == .running {
            self.pause()
        }
        
        self.seconds = seconds
        
        if restart {
            self.callback()
        }
        if restart || wasRunning {
            self.start()
        }
    }
}
