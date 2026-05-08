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
    private let callbacksLock = OSAllocatedUnfairLock(initialState: [UUID: () -> Void]())
    
    init(interval: Int) {
        self.interval = interval
        self.queue = DispatchQueue(label: "eu.exelban.Stats.Repeater.\(interval)", qos: .default)
    }
    
    var isEmpty: Bool {
        self.callbacksLock.withLock { $0.isEmpty }
    }
    
    func add(id: UUID, callback: @escaping () -> Void) {
        self.callbacksLock.withLock { $0[id] = callback }
        if self.timer == nil {
            self.startTimer()
        }
    }
    
    func remove(id: UUID) {
        let isEmpty = self.callbacksLock.withLock { callbacks in
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
        let leeway = min(max(self.interval / 5, 1), 5)
        timer.schedule(
            deadline: DispatchTime.now() + Double(self.interval),
            repeating: .seconds(self.interval),
            leeway: .seconds(leeway)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let list = self.callbacksLock.withLock { Array($0.values) }
            list.forEach { $0() }
        }
        timer.resume()
        self.timer = timer
    }
}

private final class RepeaterScheduler {
    static let shared = RepeaterScheduler()
    
    private let lock = OSAllocatedUnfairLock(initialState: [Int: RepeaterBucket]())
    
    func add(id: UUID, interval: Int, callback: @escaping () -> Void) {
        let bucket = self.lock.withLock { lock in
            let b = lock[interval] ?? RepeaterBucket(interval: interval)
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
