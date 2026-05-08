//
//  readers.swift
//  Disk
//
//  Created by Serhiy Mytrovtsiy on 07/05/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
@preconcurrency import Kit
import IOKit.storage
import CoreServices
import os
import Darwin

let kIONVMeSMARTUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(nil,
                                                                  0xAA, 0x0F, 0xA6, 0xF9,
                                                                  0xC2, 0xD6, 0x45, 0x7F,
                                                                  0xB1, 0x0B, 0x59, 0xA1,
                                                                  0x32, 0x53, 0x29, 0x2F
)
let kIONVMeSMARTInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
                                                             0xCC, 0xD1, 0xDB, 0x19,
                                                             0xFD, 0x9A, 0x4D, 0xAF,
                                                             0xBF, 0x95, 0x12, 0x45,
                                                             0x4B, 0x23, 0x0A, 0xB6
)
let kIOCFPlugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
                                                            0xC2, 0x44, 0xE8, 0x58,
                                                            0x10, 0x9C, 0x11, 0xD4,
                                                            0x91, 0xD4, 0x00, 0x50,
                                                            0xE4, 0xC6, 0x42, 0x6F
)

internal class CapacityReader: Reader<Disks>, @unchecked Sendable {
    internal nonisolated(unsafe) var list: Disks = Disks()
    
    private nonisolated var SMART: Bool {
        Store.shared.bool(key: "\(ModuleType.disk.stringValue)_SMART", defaultValue: true)
    }
    private nonisolated(unsafe) var purgableSpace: [URL: (Date, Int64)] = [:]
    private let session: DASession? = DASessionCreate(kCFAllocatorDefault)
    
    private let readLock = OSAllocatedUnfairLock(initialState: false)
    
    nonisolated public override func read() {
        let isReading = self.readLock.withLock { $0 }
        guard !isReading else { return }
        self.readLock.withLock { $0 = true }
        
        let removableState = Store.shared.bool(key: "Disk_removable", defaultValue: false)
        let smartState = self.SMART
        
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            
            let keys: [URLResourceKey] = [.volumeNameKey]
            guard let paths = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]),
                  let session = self.session else {
                self.readLock.withLock { $0 = false }
                return
            }
            
            let localList = self.list
            var active: [String] = []
            for url in paths {
                if url.pathComponents.count == 1 || (url.pathComponents.count > 1 && url.pathComponents[1] == "Volumes") {
                    if let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) {
                        if let diskName = DADiskGetBSDName(disk) {
                            let BSDName: String = String(cString: diskName)
                            active.append(BSDName)
                            
                            if let d = localList.first(where: { $0.BSDName == BSDName}), let idx = localList.firstIndex(where: { $0.BSDName == BSDName}) {
                                if d.removable && !removableState {
                                    localList.remove(at: idx)
                                    continue
                                }
                                
                                if let path = d.path {
                                    localList.updateFreeSize(idx, newValue: self.freeDiskSpaceInBytes(path))
                                    if smartState {
                                        localList.updateSMARTData(idx, smart: self.getSMARTDetails(for: BSDName))
                                    }
                                }
                                
                                continue
                            }
                            
                            if var d = driveDetails(disk, removableState: removableState) {
                                if let path = d.path {
                                    d.free = self.freeDiskSpaceInBytes(path)
                                    d.size = self.totalDiskSpaceInBytes(path)
                                }
                                if smartState {
                                    d.smart = self.getSMARTDetails(for: BSDName)
                                }
                                guard d.size != 0 else { continue }
                                localList.append(d)
                                localList.sort()
                            }
                        }
                    }
                }
            }
            
            active.difference(from: localList.map{ $0.BSDName }).forEach { (BSDName: String) in
                if let idx = localList.firstIndex(where: { $0.BSDName == BSDName }) {
                    localList.remove(at: idx)
                }
            }
            
            if let old = self.value, old == localList {
                self.readLock.withLock { $0 = false }
                return
            }
            
            self.list = localList
            self.callback(localList)
            self.readLock.withLock { $0 = false }
        }
    }
    
    public func resetPurgableSpace(for uuid: String) {
        if let disk = self.list.first(where: { $0.uuid == uuid }), let path = disk.path {
            self.purgableSpace.removeValue(forKey: path)
        }
    }
    
    nonisolated private func freeDiskSpaceInBytes(_ path: URL) -> Int64 {
        var stat = statfs()
        if statfs(path.path, &stat) == 0 {
            var purgeable: Int64 = 0
            if self.purgableSpace[path] == nil {
                let value = CSDiskSpaceGetRecoveryEstimate(path as NSURL)
                purgeable = Int64(value)
                self.purgableSpace[path] = (Date(), purgeable)
            } else if let pair = self.purgableSpace[path] {
                let delta = Date().timeIntervalSince(pair.0)
                if delta > 30 {
                    let value = CSDiskSpaceGetRecoveryEstimate(path as NSURL)
                    purgeable = Int64(value)
                    self.purgableSpace[path] = (Date(), purgeable)
                } else {
                    purgeable = pair.1
                }
            }
            return (Int64(stat.f_bfree) * Int64(stat.f_bsize)) + Int64(purgeable)
        }
        
        do {
            if let url = URL(string: path.absoluteString) {
                let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                if let capacity = values.volumeAvailableCapacityForImportantUsage, capacity != 0 {
                    return capacity
                }
            }
        } catch let err {
            error("error retrieving free space #1: \(err.localizedDescription)", log: self.log)
        }
        
        do {
            let systemAttributes = try FileManager.default.attributesOfFileSystem(forPath: path.path)
            if let freeSpace = (systemAttributes[FileAttributeKey.systemFreeSize] as? NSNumber)?.int64Value {
                return freeSpace
            }
        } catch let err {
            error("error retrieving free space: \(err.localizedDescription)", log: self.log)
        }
        
        return 0
    }
    
    nonisolated private func totalDiskSpaceInBytes(_ path: URL) -> Int64 {
        do {
            let systemAttributes = try FileManager.default.attributesOfFileSystem(forPath: path.path)
            if let totalSpace = (systemAttributes[FileAttributeKey.systemSize] as? NSNumber)?.int64Value {
                return totalSpace
            }
        } catch let err {
            error("error retrieving total space: \(err.localizedDescription)", log: self.log)
        }
        
        return 0
    }
    
    nonisolated private func getSMARTDetails(for BSDName: String) -> smart_t? {
        guard self.SMART else { return nil }
        
        var disk = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, BSDName.cString(using: .utf8)))
        guard disk != 0 else { return nil }
        defer { IOObjectRelease(disk) }
        
        while IOObjectConformsTo(disk, kIOBlockStorageDeviceClass) == 0 {
            var parent: io_registry_entry_t = 0
            let error = IORegistryEntryGetParentEntry(disk, kIOServicePlane, &parent)
            if error != kIOReturnSuccess || parent == 0 { return nil }
            IOObjectRelease(disk)
            disk = parent
        }
        
        guard IOObjectConformsTo(disk, kIOBlockStorageDeviceClass) > 0,
              let raw = IORegistryEntryCreateCFProperty(disk, "NVMe SMART Capable" as CFString, kCFAllocatorDefault, 0),
              let val = raw.takeRetainedValue() as? Bool, val else {
            return nil
        }
        
        var pluginInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var smartInterface: UnsafeMutablePointer<UnsafeMutablePointer<IONVMeSMARTInterface>?>?
        var score: Int32  = 0
        
        var result = IOCreatePlugInInterfaceForService(disk, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &pluginInterface, &score)
        guard result == kIOReturnSuccess else { return nil }
        defer {
            if pluginInterface != nil {
                IODestroyPlugInInterface(pluginInterface)
            }
        }
        
        result = withUnsafeMutablePointer(to: &smartInterface) {
            $0.withMemoryRebound(to: Optional<LPVOID>.self, capacity: 1) {
                pluginInterface?.pointee?.pointee.QueryInterface(pluginInterface, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), $0) ?? KERN_NOT_FOUND
            }
        }
        
        guard result == kIOReturnSuccess else { return nil }
        defer {
            if smartInterface != nil {
                _ = pluginInterface?.pointee?.pointee.Release(smartInterface)
            }
        }
        
        guard let smart = smartInterface?.pointee else { return nil }
        var smartData: nvme_smart_log = nvme_smart_log()
        guard smart.pointee.SMARTReadData(smartInterface, &smartData) == kIOReturnSuccess else { return nil }
        
        let temperatures: [UInt8] = [UInt8(smartData.temperature.1), UInt8(smartData.temperature.0)]
        var temperature: UInt16 = 0
        let data = NSData(bytes: temperatures, length: 2)
        data.getBytes(&temperature, length: 2)
        
        let dataUnitsRead = self.extractUInt128(smartData.data_units_read)
        let dataUnitsWritten = self.extractUInt128(smartData.data_units_written)
        let bytesPerDataUnit: Int64 = 512 * 1000
        
        let powerCycles = withUnsafeBytes(of: smartData.power_cycles) { $0.load(as: UInt32.self) }
        let powerOnHours = withUnsafeBytes(of: smartData.power_on_hours) { $0.load(as: UInt32.self) }
        
        return smart_t(
            temperature: Int(UInt16(bigEndian: temperature) - 273),
            life: 100 - Int(smartData.percent_used),
            totalRead: dataUnitsRead * bytesPerDataUnit,
            totalWritten: dataUnitsWritten * bytesPerDataUnit,
            powerCycles: Int(powerCycles),
            powerOnHours: Int(powerOnHours)
        )
    }
    
    nonisolated private func extractUInt128(_ tuple: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) -> Int64 {
        let byteArray: [UInt8] = [
            tuple.0, tuple.1, tuple.2, tuple.3, tuple.4, tuple.5, tuple.6, tuple.7,
            tuple.8, tuple.9, tuple.10, tuple.11, tuple.12, tuple.13, tuple.14, tuple.15
        ]
        
        let uint64Value = byteArray.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self) }
        let hasHigherBytes = byteArray.suffix(8).contains(where: { $0 != 0 })
        
        if hasHigherBytes || uint64Value > UInt64(Int64.max) {
            return Int64.max
        }
        
        return Int64(uint64Value)
    }
}

internal class ActivityReader: Reader<Disks>, @unchecked Sendable {
    internal nonisolated(unsafe) var list: Disks = Disks()
    private let session: DASession? = DASessionCreate(kCFAllocatorDefault)
    
    @MainActor override func setup() {
        self.setInterval(Store.shared.int(key: "Disk_updateInterval", defaultValue: self.defaultInterval))
    }
    
    private let activityLock = OSAllocatedUnfairLock(initialState: false)
    
    nonisolated public override func read() {
        let isReading = self.activityLock.withLock { $0 }
        guard !isReading else { return }
        self.activityLock.withLock { $0 = true }
        
        Task { @MainActor in
            let keys: [URLResourceKey] = [.volumeNameKey]
            let removableState = Store.shared.bool(key: "Disk_removable", defaultValue: false)
            guard let paths = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys) else {
                return
            }
            
            guard let session = self.session else {
                return
            }
            let currentInterval = Int64(self.interval ?? 1)
            
            let updatedList = await Task.detached(priority: .background) {
                let localList = self.list
                var active: [String] = []
                for url in paths {
                    if url.pathComponents.count == 1 || (url.pathComponents.count > 1 && url.pathComponents[1] == "Volumes") {
                        if let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) {
                            if let diskName = DADiskGetBSDName(disk) {
                                let BSDName: String = String(cString: diskName)
                                active.append(BSDName)
                                
                                if let d = localList.first(where: { $0.BSDName == BSDName}), let idx = localList.firstIndex(where: { $0.BSDName == BSDName}) {
                                    if d.removable && !removableState {
                                        localList.remove(at: idx)
                                        continue
                                    }
                                    
                                    self.driveStats(localList, idx, d, max(1, currentInterval))
                                    continue
                                }
                                
                                if let d = driveDetails(disk, removableState: removableState) {
                                    localList.append(d)
                                    localList.sort()
                                }
                            }
                        }
                    }
                }
                
                active.difference(from: localList.map{ $0.BSDName }).forEach { (BSDName: String) in
                    if let idx = localList.firstIndex(where: { $0.BSDName == BSDName }) {
                        localList.remove(at: idx)
                    }
                }
                return localList
            }.value
            
            if let old = self.value, old == updatedList {
                self.activityLock.withLock { $0 = false }
                return
            }
            
            self.list = updatedList
            self.callback(self.list)
            self.activityLock.withLock { $0 = false }
        }
    }
    
    nonisolated private func driveStats(_ list: Disks, _ idx: Int, _ d: drive, _ interval: Int64) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, d.BSDName))
        if service == 0 { return }
        IOObjectRelease(service)
        
        guard let props = getIOProperties(d.parent) else { return }
        
        if let statistics = props.object(forKey: "Statistics") as? NSDictionary {
            let readBytes = statistics.object(forKey: "Bytes (Read)") as? Int64 ?? 0
            let writeBytes = statistics.object(forKey: "Bytes (Write)") as? Int64 ?? 0
            
            if d.activity.readBytes != 0 {
                list.updateRead(idx, newValue: (readBytes - d.activity.readBytes) / interval)
            }
            if d.activity.writeBytes != 0 {
                list.updateWrite(idx, newValue: (writeBytes - d.activity.writeBytes) / interval)
            }
            
            list.updateReadWrite(idx, read: readBytes, write: writeBytes)
        }
    }
}

private func driveDetails(_ disk: DADisk, removableState: Bool) -> drive? {
    var d: drive = drive()
    
    if let bsdName = DADiskGetBSDName(disk) {
        d.BSDName = String(cString: bsdName)
    }
    
    if let diskDescription = DADiskCopyDescription(disk) {
        if let dict = diskDescription as? [String: AnyObject] {
            if let removable = dict[kDADiskDescriptionMediaRemovableKey as String] as? Bool {
                if removable {
                    if !removableState {
                        return nil
                    }
                    d.removable = true
                }
            }
            
            if let mediaUUID = dict[kDADiskDescriptionMediaUUIDKey as String] {
                let rawUUID = mediaUUID as CFTypeRef
                if CFGetTypeID(rawUUID) == CFUUIDGetTypeID() {
                    d.uuid = CFUUIDCreateString(kCFAllocatorDefault, unsafeBitCast(rawUUID, to: CFUUID.self)) as String
                }
            }
            if let mediaName = dict[kDADiskDescriptionVolumeNameKey as String] as? String {
                d.mediaName = mediaName
                if d.mediaName == "Recovery" {
                    return nil
                }
            }
            if d.mediaName == "" {
                if let mediaName = dict[kDADiskDescriptionMediaNameKey as String] as? String {
                    d.mediaName = mediaName
                    if d.mediaName == "Recovery" {
                        return nil
                    }
                }
            }
            if let deviceModel = dict[kDADiskDescriptionDeviceModelKey as String] as? String {
                d.model = deviceModel.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let deviceProtocol = dict[kDADiskDescriptionDeviceProtocolKey as String] as? String {
                d.connectionType = deviceProtocol
            }
            if let volumePath = dict[kDADiskDescriptionVolumePathKey as String] {
                if let url = volumePath as? NSURL {
                    d.path = url as URL
                    
                    if let components = url.pathComponents {
                        d.root = components.count == 1
                        
                        if components.count > 1 && components[1] == "Volumes" {
                            if let name: String = url.lastPathComponent, name != "" {
                                d.mediaName = name
                            }
                        }
                    }
                }
            }
            if let volumeKind = dict[kDADiskDescriptionVolumeKindKey as String] as? String {
                d.fileSystem = volumeKind
            }
        }
    }
    
    if d.path == nil {
        return nil
    }
    if d.uuid == "" || d.uuid == "00000000-0000-0000-0000-000000000000" {
        d.uuid = d.BSDName
    }
    
    let partitionLevel = d.BSDName.filter { "0"..."9" ~= $0 }.count
    let media = DADiskCopyIOMedia(disk)
    if let parent = getDeviceIOParent(media, level: Int(partitionLevel)) {
        d.parent = parent
    }
    IOObjectRelease(media)
    
    return d
}

// https://opensource.apple.com/source/bless/bless-152/libbless/APFS/BLAPFSUtilities.c.auto.html
public func getDeviceIOParent(_ obj: io_registry_entry_t, level: Int) -> io_registry_entry_t? {
    var parent: io_registry_entry_t = 0
    
    if IORegistryEntryGetParentEntry(obj, kIOServicePlane, &parent) != KERN_SUCCESS {
        return nil
    }
    
    guard level > 0 else { return parent }
    
    for _ in 1...level {
        var newParent: io_registry_entry_t = 0
        if IORegistryEntryGetParentEntry(parent, kIOServicePlane, &newParent) != KERN_SUCCESS {
            IOObjectRelease(parent)
            return nil
        }
        IOObjectRelease(parent)
        parent = newParent
    }
    
    return parent
}

struct io {
    var read: Int
    var write: Int
}

public class ProcessReader: Reader<[Disk_process]>, @unchecked Sendable {
    private nonisolated(unsafe) var _list: [Int32: io] = [:]
    
    private var numberOfProcesses: Int {
        Store.shared.int(key: "\(ModuleType.disk.stringValue)_processes", defaultValue: 5)
    }
    
    public override func setup() {
        self.popup = true
        self.defaultInterval = 5
        self.setInterval(Store.shared.int(key: "Disk_updateTopInterval", defaultValue: 5))
    }
    
    private let processLock = OSAllocatedUnfairLock(initialState: false)

    nonisolated private func listPIDs() -> [pid_t] {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return [] }

        let count = Int(bufferSize) / MemoryLayout<pid_t>.size
        guard count > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: count)
        let result = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        guard result > 0 else { return [] }
        return pids.filter { $0 > 0 }
    }

    nonisolated private func processName(for pid: pid_t) -> String {
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        if nameLength > 0 {
            let name = String(cString: nameBuffer)
            if !name.isEmpty {
                return name
            }
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if pathLength > 0 {
            return URL(fileURLWithPath: String(cString: pathBuffer)).lastPathComponent
        }

        return "\(pid)"
    }
    
    nonisolated public override func read() {
        let isReading = self.processLock.withLock { $0 }
        guard !isReading else { return }
        self.processLock.withLock { $0 = true }
        
        Task { @MainActor in
            let limit = self.numberOfProcesses
            if limit == 0 {
                self.processLock.withLock { $0 = false }
                return
            }
            
            let currentList = self._list
            let currentInterval = Int(self.interval ?? 1)
            let (updatedList, result) = await Task.detached(priority: .background) {
                let pids = self.listPIDs()
                guard !pids.isEmpty else { return (currentList, [] as [Disk_process]) }

                var snapshot = currentList
                var processes: [Disk_process] = []
                for pid in pids {
                    var usage = rusage_info_current()
                    let result = withUnsafeMutablePointer(to: &usage) { (ptr: UnsafeMutablePointer<rusage_info_current>) in
                        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                            proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                        }
                    }
                    guard result != -1 else { continue }

                    let name = self.processName(for: pid)
                    let bytesRead = Int(clamping: usage.ri_diskio_bytesread)
                    let bytesWritten = Int(clamping: usage.ri_diskio_byteswritten)
                    
                    if snapshot[pid] == nil {
                        snapshot[pid] = io(read: bytesRead, write: bytesWritten)
                    }
                    
                    if let v = snapshot[pid] {
                        let read = bytesRead - v.read
                        let write = bytesWritten - v.write
                        if read != 0 || write != 0 {
                            let interval = max(1, currentInterval)
                            processes.append(Disk_process(pid: Int(pid), name: name, read: read / interval, write: write / interval))
                        }
                    }
                    
                    snapshot[pid]?.read = bytesRead
                    snapshot[pid]?.write = bytesWritten
                }
                
                processes.sort {
                    let firstMax = max($0.read, $0.write)
                    let secondMax = max($1.read, $1.write)
                    let firstMin = min($0.read, $0.write)
                    let secondMin = min($1.read, $1.write)
                    
                    if firstMax == secondMax && firstMin != secondMin {
                        return firstMin < secondMin
                    }
                    return firstMax < secondMax
                }
                
                return (snapshot, Array(processes.suffix(limit).reversed()))
            }.value
            
            self._list = updatedList
            self.callback(result)
            self.processLock.withLock { $0 = false }
        }
    }
}
