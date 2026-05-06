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

internal class UsageReader: Reader<RAM_Usage>, @unchecked Sendable {
    private nonisolated(unsafe) var totalSize: Double = 0
    
    public override func setup() {
        var stats = host_basic_info()
        var count = UInt32(MemoryLayout<host_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_BASIC_INFO, $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            self.totalSize = Double(stats.max_mem)
            return
        }
        
        self.totalSize = 0
        error("host_info(): \(String(cString: mach_error_string(kerr), encoding: String.Encoding.ascii) ?? "unknown error")", log: self.log)
    }
    
    nonisolated public override func read() {
        Task { @MainActor in
            let localTotalSize = self.totalSize
            
            let usage = await Task.detached(priority: .userInitiated) { () -> RAM_Usage? in
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
                    
                    return RAM_Usage(
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
                }
                return nil
            }.value
            
            if let usage = usage {
                self.callback(usage)
            }
        }
    }
}

public class ProcessReader: Reader<[TopProcess]>, @unchecked Sendable {
    private let title: String = "RAM"
    
    private var numberOfProcesses: Int {
        get { Store.shared.int(key: "\(self.title)_processes", defaultValue: 8) }
    }
    
    private var combinedProcesses: Bool{
        get { Store.shared.bool(key: "\(self.title)_combinedProcesses", defaultValue: false) }
    }
    
    private typealias dynGetResponsiblePidFuncType = @convention(c) (CInt) -> CInt
    
    public override func setup() {
        self.popup = true
        self.setInterval(Store.shared.int(key: "\(self.title)_updateTopInterval", defaultValue: 1))
    }
    
    nonisolated public override func read() {
        Task { @MainActor in
            if self.numberOfProcesses == 0 {
                return
            }
            
            let limit = self.numberOfProcesses
            let combined = self.combinedProcesses
            let log = self.log
            
            let finalResult = await Task.detached(priority: .background) {
                let task = Process()
                task.launchPath = "/usr/bin/top"
                if combined {
                    task.arguments = ["-l", "1", "-o", "mem", "-stats", "pid,command,mem"]
                } else {
                    task.arguments = ["-l", "1", "-o", "mem", "-n", "\(limit)", "-stats", "pid,command,mem"]
                }
                
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                
                defer {
                    try? outputPipe.fileHandleForReading.close()
                    try? errorPipe.fileHandleForReading.close()
                }
                
                task.standardOutput = outputPipe
                task.standardError = errorPipe
                
                do {
                    try task.run()
                    task.waitUntilExit()
                } catch let err {
                    error("top(): \(err.localizedDescription)", log: log)
                    return [TopProcess]()
                }
                
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8)
                guard let output, !output.isEmpty else { return [TopProcess]() }
                
                var processes: [TopProcess] = []
                output.enumerateLines { (line, _) in
                    if line.matches("^\\d+\\** +.* +\\d+[A-Z]*\\+?\\-? *$") {
                        processes.append(ProcessReader.parseProcess(line))
                    }
                }
                
                if !combined {
                    return processes
                }
                
                var processGroups: [String: [TopProcess]] = [:]
                for process in processes {
                    let responsiblePid = ProcessReader.getResponsiblePid(process.pid)
                    let groupKey = "\(responsiblePid)"
                    
                    if processGroups[groupKey] != nil {
                        processGroups[groupKey]!.append(process)
                    } else {
                        processGroups[groupKey] = [process]
                    }
                }
                
                var result: [TopProcess] = []
                for (_, processes) in processGroups {
                    let totalUsage = processes.reduce(0) { $0 + $1.usage }
                    let firstProcess = processes.first!
                    let name: String
                    
                    let respPid = ProcessReader.getResponsiblePid(firstProcess.pid)
                    if let app = NSRunningApplication(processIdentifier: pid_t(respPid)),
                       let appName = app.localizedName {
                        name = appName
                    } else {
                        name = firstProcess.name
                    }
                    
                    result.append(TopProcess(
                        pid: respPid,
                        name: name,
                        usage: totalUsage
                    ))
                }
                
                result.sort { $0.usage > $1.usage }
                return Array(result.prefix(limit))
            }.value
            
            self.callback(finalResult)
        }
    }
    
    nonisolated private static let dynGetResponsiblePidFunc: UnsafeMutableRawPointer? = {
        let result = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid")
        if result == nil {
            error("Error loading responsibility_get_pid_responsible_for_pid")
        }
        return result
    }()
    
    nonisolated static func getResponsiblePid(_ childPid: Int) -> Int {
        guard let funcPtr = ProcessReader.dynGetResponsiblePidFunc else {
            return childPid
        }
        let responsiblePid = unsafeBitCast(funcPtr, to: dynGetResponsiblePidFuncType.self)(CInt(childPid))
        guard responsiblePid != -1 else {
            return childPid
        }
        return Int(responsiblePid)
    }
    
    nonisolated static public func parseProcess(_ raw: String) -> TopProcess {
        var str = raw.trimmingCharacters(in: .whitespaces)
        let pidString = str.find(pattern: "^\\d+")
        
        if let range = str.range(of: pidString) {
            str = str.replacingCharacters(in: range, with: "")
        }
        
        var arr = str.split(separator: " ")
        if arr.first == "*" {
            arr.removeFirst()
        }
        
        var usageString = str.suffix(6)
        if let lastElement = arr.last {
            usageString = lastElement
            arr.removeLast()
        }
        
        var command = arr.joined(separator: " ")
            .replacingOccurrences(of: pidString, with: "")
            .trimmingCharacters(in: .whitespaces)
        
        if let regex = try? NSRegularExpression(pattern: " (\\+|\\-)*$", options: .caseInsensitive) {
            command = regex.stringByReplacingMatches(in: command, options: [], range: NSRange(location: 0, length: command.count), withTemplate: "")
        }
        
        let pid = Int(pidString.filter("01234567890.".contains)) ?? 0
        var usage = Double(usageString.filter("01234567890.".contains)) ?? 0
        if usageString.last == "G" {
            usage *= 1024 // apply gigabyte multiplier
        } else if usageString.last == "K" {
            usage /= 1024 // apply kilobyte divider
        } else if usageString.last == "M" && usageString.count == 5 {
            usage /= 1024
            usage *= 1000
        }
        
        var name: String = command
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)), let n = app.localizedName {
            name = n
        }
        
        if command.contains("com.apple.Virtua") && name.contains("Docker") {
            name = "Docker"
        }
        
        return TopProcess(pid: pid, name: name, usage: usage * Double(1000 * 1000))
    }
}
