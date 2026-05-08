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

internal class UsageReader: Reader<RAM_Usage>, @unchecked Sendable {
    private nonisolated(unsafe) var totalSize: Double = 0
    
    public override func setup() {
        var size: UInt64 = 0
        var sizeLen: Int = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &size, &sizeLen, nil, 0) == 0 {
            self.totalSize = Double(size)
            return
        }
        
        self.totalSize = 0
    }
    
    nonisolated public override func read() {
        let localTotalSize = self.totalSize
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            
            var stats = vm_statistics64()
            var count = UInt32(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
            
            let result: kern_return_t = withUnsafeMutablePointer(to: &stats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
                }
            }
            
            if result == KERN_SUCCESS {
                let active = Double(stats.active_count) * Double(vm_page_size)
                let speculative = Double(stats.speculative_count) * Double(vm_page_size)
                let inactive = Double(stats.inactive_count) * Double(vm_page_size)
                let wired = Double(stats.wire_count) * Double(vm_page_size)
                let compressed = Double(stats.compressor_page_count) * Double(vm_page_size)
                let purgeable = Double(stats.purgeable_count) * Double(vm_page_size)
                let external = Double(stats.external_page_count) * Double(vm_page_size)
                let swapins = Int64(stats.swapins)
                let swapouts = Int64(stats.swapouts)
                
                let used = active + inactive + speculative + wired + compressed - purgeable - external
                let free = localTotalSize - used
                
                var intSize: size_t = MemoryLayout<uint>.size
                var pressureLevel: Int = 0
                sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &intSize, nil, 0)
                
                let pressureValue: RAMPressure = {
                    switch pressureLevel {
                    case 2: return .warning
                    case 4: return .critical
                    default: return .normal
                    }
                }()
                
                var stringSize: size_t = MemoryLayout<xsw_usage>.size
                var swap: xsw_usage = xsw_usage()
                sysctlbyname("vm.swapusage", &swap, &stringSize, nil, 0)
                
                let usage = RAM_Usage(
                    total: localTotalSize,
                    used: used,
                    free: free,
                    
                    active: active,
                    inactive: inactive,
                    wired: wired,
                    compressed: compressed,
                    
                    app: used - wired - compressed,
                    cache: purgeable + external,
                    
                    swap: Swap(
                        total: Double(swap.xsu_total),
                        used: Double(swap.xsu_used),
                        free: Double(swap.xsu_avail)
                    ),
                    pressure: Pressure(level: pressureLevel, value: pressureValue),
                    
                    swapins: swapins,
                    swapouts: swapouts
                )
                
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
    private let readLock = OSAllocatedUnfairLock(initialState: false)
    
    private var numberOfProcesses: Int {
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
        
        Task { @MainActor in
            if self.numberOfProcesses == 0 {
                self.readLock.withLock { $0 = false }
                return
            }
            
            let limit = self.numberOfProcesses
            let processes = await ProcessMonitor.shared.getTopProcesses(limit: limit, category: "RAM")
            
            if let old = self.value, old == processes {
                self.readLock.withLock { $0 = false }
                return
            }
            
            self.callback(processes)
            self.readLock.withLock { $0 = false }
        }
    }
}
