//
//  readers.swift
//  Memory
//
//  Created by Serhiy Mytrovtsiy on 12/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
@preconcurrency import Kit
import os

private actor RAMReaderWorker {
    private var totalSize: Double = 0
    
    init() {
        var size: UInt64 = 0
        var sizeLen: Int = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &size, &sizeLen, nil, 0) == 0 {
            self.totalSize = Double(size)
        }
    }
    
    func readUsage() async -> RAM_Usage? {
        var stats = vm_statistics64()
        var count = UInt32(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        
        let result: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        if result != KERN_SUCCESS {
            return nil
        }
        
        let active = Double(stats.active_count) * Double(vm_page_size)
        let speculative = Double(stats.speculative_count) * Double(vm_page_size)
        let inactive = Double(stats.inactive_count) * Double(vm_page_size)
        let wired = Double(stats.wire_count) * Double(vm_page_size)
        let compressed = Double(stats.compressor_page_count) * Double(vm_page_size)
        
        let used = active + wired + compressed
        let free = self.totalSize - used
        
        var intSize: size_t = MemoryLayout<Int>.size
        var pressureLevel: Int = 0
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &intSize, nil, 0) != 0 {
            pressureLevel = 0
        }
        
        let pressureValue: RAMPressure = {
            switch pressureLevel {
            case 2: return .warning
            case 4: return .critical
            default: return .normal
            }
        }()
        
        var stringSize: size_t = MemoryLayout<xsw_usage>.size
        var swap: xsw_usage = xsw_usage()
        if sysctlbyname("vm.swapusage", &swap, &stringSize, nil, 0) != 0 {
            swap = xsw_usage()
        }
        
        return RAM_Usage(
            total: self.totalSize,
            used: used,
            free: free,
            
            active: active,
            inactive: inactive,
            wired: wired,
            compressed: compressed,
            
            app: active,
            cache: inactive + speculative,
            
            swap: Swap(
                total: Double(swap.xsu_total),
                used: Double(swap.xsu_used),
                free: Double(swap.xsu_avail)
            ),
            pressure: Pressure(level: pressureLevel, value: pressureValue),
            
            swapins: Int64(stats.swapins),
            swapouts: Int64(stats.swapouts)
        )
    }
    
    func getTopProcesses(limit: Int) async -> [TopProcess] {
        return await ProcessMonitor.shared.getTopProcesses(limit: limit, category: "RAM")
    }
}

internal class UsageReader: Reader<RAM_Usage>, @unchecked Sendable {
    private let worker = RAMReaderWorker()
    private let readLock = OSAllocatedUnfairLock(initialState: false)
    
    nonisolated public override func read() {
        let isReading = self.readLock.withLock { $0 }
        guard !isReading else { return }
        self.readLock.withLock { $0 = true }
        
        let worker = self.worker
        Task {
            defer { self.readLock.withLock { $0 = false } }
            if let usage = await worker.readUsage() {
                if let old = self.value, old == usage {
                    return
                }
                self.callback(usage)
            }
        }
    }
}

public class ProcessReader: Reader<[TopProcess]>, @unchecked Sendable {
    private let title: String = "RAM"
    private let worker = RAMReaderWorker()
    private let readLock = OSAllocatedUnfairLock(initialState: false)
    
    private nonisolated var numberOfProcesses: Int {
        get { Store.shared.int(key: "\(self.title)_processes", defaultValue: 8) }
    }
    
    public override func setup() {
        self.popup = true
        self.defaultInterval = 5
        self.setInterval(Store.shared.int(key: "\(self.title)_updateTopInterval", defaultValue: 5))
    }
    
    nonisolated public override func read() {
        let isReading = self.readLock.withLock { $0 }
        guard !isReading else { return }
        self.readLock.withLock { $0 = true }
        
        let limit = self.numberOfProcesses
        let worker = self.worker
        
        Task {
            defer { self.readLock.withLock { $0 = false } }
            
            if limit == 0 { return }
            
            let processes = await worker.getTopProcesses(limit: limit)
            
            if let old = self.value, old == processes {
                return
            }
            
            self.callback(processes)
        }
    }
}
