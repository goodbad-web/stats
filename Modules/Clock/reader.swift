//
//  reader.swift
//  Stats
//
//  Created by Serhiy Mytrovtsiy on 05/03/2026
//  Using Swift 6.0
//  Running on macOS 26.3
//
//  Copyright © 2026 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation
@preconcurrency import Kit
import os

private actor ClockReaderWorker {
    func fetchNTPOffset(server: String) async -> TimeInterval? {
        guard let serverDate = self.requestTime(server: server) else { return nil }
        return serverDate.timeIntervalSince(Date())
    }
    
    private func requestTime(server: String, timeout: TimeInterval = 2.0) -> Date? {
        let host = CFHostCreateWithName(nil, server as CFString).takeRetainedValue()
        var resolved: DarwinBoolean = false
        let started = CFHostStartInfoResolution(host, .addresses, nil)
        guard started else { return nil }
        
        guard
            let unmanaged = CFHostGetAddressing(host, &resolved),
            resolved.boolValue,
            let addresses = unmanaged.takeUnretainedValue() as? [Data],
            let first = addresses.first
        else { return nil }
        
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { return nil }
        defer { close(socketFD) }
        
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        
        var addrStorage = sockaddr_storage()
        first.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(&addrStorage, base, min(raw.count, MemoryLayout<sockaddr_storage>.size))
        }
        
        guard addrStorage.ss_family == sa_family_t(AF_INET) else { return nil }
        withUnsafeMutablePointer(to: &addrStorage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                p.pointee.sin_port = in_port_t(123).bigEndian
            }
        }
        
        var packet = Data(count: 48)
        packet[0] = 0x1B
        let sent = packet.withUnsafeBytes { ptr in
            withUnsafePointer(to: &addrStorage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(socketFD, ptr.baseAddress, ptr.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == 48 else { return nil }
        
        var recvBuf = Data(count: 48)
        let received = recvBuf.withUnsafeMutableBytes { ptr in
            recv(socketFD, ptr.baseAddress, ptr.count, 0)
        }
        guard received >= 48 else { return nil }
        
        let seconds1900: UInt32 = recvBuf.withUnsafeBytes { ptr in
            let b = ptr.bindMemory(to: UInt8.self)
            return (UInt32(b[40]) << 24) | (UInt32(b[41]) << 16) | (UInt32(b[42]) << 8) | UInt32(b[43])
        }
        
        return Date(timeIntervalSince1970: TimeInterval(seconds1900) - 2_208_988_800)
    }
}

internal class ClockReader: Reader<Date>, @unchecked Sendable {
    private let title: String = ModuleType.clock.stringValue
    private let worker = ClockReaderWorker()
    private let offsetLock = OSAllocatedUnfairLock(initialState: TimeInterval(0))
    private let syncLock = OSAllocatedUnfairLock(initialState: false)
    
    private var now: Date { Date().addingTimeInterval(self.offsetLock.withLock { $0 }) }
    
    private nonisolated var ntpSync: Bool {
        Store.shared.bool(key: "\(self.title)_ntpSync", defaultValue: false)
    }
    
    private nonisolated var ntpServer: String {
        Store.shared.string(key: "\(self.title)_ntpServer", defaultValue: "pool.ntp.org")
    }
    
    public override func setup() {
        self.alignToSecondBoundary = true
        self.syncWithNTP()
    }
    
    nonisolated public override func read() {
        Task { @MainActor in
            let ntp = self.ntpSync
            let date = ntp ? self.now : Date()
            
            self.callback(date)
            
            if Calendar.current.component(.second, from: date) == 0 {
                self.syncWithNTP()
            }
        }
    }
    
    private func syncWithNTP() {
        guard self.ntpSync else {
            self.offsetLock.withLock { $0 = 0 }
            return
        }
        
        let isSyncing = self.syncLock.withLock { $0 }
        guard !isSyncing else { return }
        self.syncLock.withLock { $0 = true }
        
        let server = self.ntpServer
        let worker = self.worker
        
        Task {
            defer { self.syncLock.withLock { $0 = false } }
            if let newOffset = await worker.fetchNTPOffset(server: server) {
                self.offsetLock.withLock { $0 = newOffset }
                await MainActor.run {
                    self.alignOffset = newOffset
                }
            }
        }
    }
}
