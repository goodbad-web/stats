//
//  readers.swift
//  Bluetooth
//
//  Created by Serhiy Mytrovtsiy on 08/06/2021.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2021 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation
@preconcurrency import Kit
import CoreBluetooth
import IOBluetooth
import os

private struct bleDevice: Sendable {
    var name: String?
    var address: String
    var uuid: UUID?
    var batteryLevel: [KeyValue_t]
    var vendorId: Int? = nil
    var productId: Int? = nil
}

private struct ioDevice: Sendable {
    var name: String
    var address: String
    var rssi: Int8
    var isConnected: Bool
    var isPaired: Bool
}

private actor BluetoothReaderWorker {
    func fetchSystemDevices() async -> (hid: [bleDevice], SPB: ([bleDevice], [String]), cached: [bleDevice], pmset: [bleDevice], paired: [ioDevice]) {
        let hid = self.HIDDevices()
        let SPB = self.profilerDevices()
        let cached = self.cacheDevices()
        let pmsetLevels = self.pmsetAccessoryLevels()
        
        let pairedDevices: [ioDevice] = IOBluetoothDevice.pairedDevices()?.compactMap({
            if let device = $0 as? IOBluetoothDevice, device.isPaired() || device.isConnected() {
                return ioDevice(
                    name: device.nameOrAddress,
                    address: device.addressString,
                    rssi: device.rssi(),
                    isConnected: device.isConnected(),
                    isPaired: device.isPaired()
                )
            }
            return nil
        }) ?? []
        
        return (hid, SPB, cached, pmsetLevels, pairedDevices)
    }
    
    private func HIDDevices() -> [bleDevice] {
        guard let ioDevices = fetchIOService("AppleDeviceManagementHIDEventService") else {
            return []
        }
        
        var list: [bleDevice] = []
        ioDevices.filter{ $0.object(forKey: "BluetoothDevice") as? Bool == true }.forEach { (d: NSDictionary) in
            guard let name = d.object(forKey: "Product") as? String, let batteryPercent = d.object(forKey: "BatteryPercent") as? Int else {
                return
            }
            
            var address: String = ""
            if let addr = d.object(forKey: "DeviceAddress") as? String, addr != "" {
                address = addr
            } else if let addr = d.object(forKey: "SerialNumber") as? String, addr != "" {
                address = addr
            } else if let bleAddr = d.object(forKey: "BD_ADDR") as? Data {
                address = bleAddr.map { String(format: "%02hhx", $0) }.joined(separator: "-")
            }
            
            let vendorId = d.object(forKey: "VendorID") as? Int
            let productId = d.object(forKey: "ProductID") as? Int
            list.append(bleDevice(name: name, address: address, uuid: nil, batteryLevel: [KeyValue_t(key: "battery", value: "\(batteryPercent)")], vendorId: vendorId, productId: productId))
        }
        
        return list
    }
    
    private func cacheDevices() -> [bleDevice] {
        guard let cache = UserDefaults(suiteName: "/Library/Preferences/com.apple.Bluetooth"),
              let deviceCache = cache.object(forKey: "DeviceCache") as? [String: [String: Any]],
              let pairedDevices = cache.object(forKey: "PairedDevices") as? [String],
              let coreCache = cache.object(forKey: "CoreBluetoothCache") as? [String: [String: Any]] else {
            return []
        }
        
        var list: [bleDevice] = []
        deviceCache.filter({ pairedDevices.contains($0.key) }).forEach { (address: String, dict: [String: Any]) in
            let name = dict.first{ $0.key == "Name" }?.value as? String
            var uuid: UUID? = nil
            var batteryLevel: [KeyValue_t] = []
            
            for key in ["BatteryPercent", "BatteryPercentCase", "BatteryPercentLeft", "BatteryPercentRight"] {
                if let pair = dict.first(where: { $0.key == key }) {
                    var percentage: Int = 0
                    switch pair.value {
                    case let value as Int:
                        percentage = value
                        if percentage == 1 { percentage *= 100 }
                    case let value as Double:
                        percentage = Int(value.isFinite ? value*100 : 0)
                    default: continue
                    }
                    
                    batteryLevel.append(KeyValue_t(key: key, value: "\(percentage)"))
                }
            }
            
            coreCache.forEach { (key: String, dict: [String: Any]) in
                guard let field = dict.first(where: { $0.key == "DeviceAddress" }),
                        let value = field.value as? String,
                        value == address else {
                    return
                }
                uuid = UUID(uuidString: key)
            }
            
            list.append(bleDevice(name: name, address: address, uuid: uuid, batteryLevel: batteryLevel))
        }
        
        return list
    }
    
    private func profilerDevices() -> ([bleDevice], [String]) {
        guard let res = process(path: "/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"]) else {
            return ([], [])
        }
        
        var list: [bleDevice] = []
        var notConnected: [String] = []
        do {
            if let json = try JSONSerialization.jsonObject(with: Data(res.utf8), options: []) as? [String: Any] {
                guard let arr = json["SPBluetoothDataType"] as? [[String: Any]], let data = arr.first else {
                    return (list, notConnected)
                }
                
                if let rawList = data["device_connected"] as? [[String: [String: Any]]], let devices = rawList.first {
                    for obj in devices {
                        var batteryLevel: [KeyValue_t] = []
                        for key in ["device_batteryLevelCase", "device_batteryLevelLeft", "device_batteryLevelRight", "Left Battery Level", "Right Battery Level", "device_batteryLevelMain"] {
                            if let pair = obj.value.first(where: { $0.key == key }) {
                                batteryLevel.append(KeyValue_t(key: key, value: (pair.value as? String)?.replacingOccurrences(of: "%", with: "") ?? "-1"))
                            }
                        }
                        
                        let address = obj.value["device_address"] as? String ?? ""
                        list.append(bleDevice(
                            name: obj.key,
                            address: address.replacingOccurrences(of: ":", with: "-").lowercased(),
                            batteryLevel: batteryLevel
                        ))
                    }
                }
                if let rawList = data["device_not_connected"] as? [[String: [String: String]]] {
                    for device in rawList {
                        for d in device.values {
                            if let addr = d["device_address"] {
                                notConnected.append(addr.replacingOccurrences(of: ":", with: "-").lowercased())
                            }
                        }
                    }
                }
            }
        } catch {
            return (list, notConnected)
        }
        
        return (list, notConnected)
    }
    
    private func pmsetAccessoryLevels() -> [bleDevice] {
        guard let res = process(path: "/usr/bin/pmset", arguments: ["-g", "accps", "-xml"]) else { return [] }
        
        let plists = res.components(separatedBy: "<?xml")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .compactMap { chunk -> [String: Any]? in
                let xml = "<?xml" + chunk
                guard let data = xml.data(using: .utf8),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    return nil
                }
                return plist
            }
        
        struct PmsetEntry {
            let name: String
            let capacity: Int
            let accessoryIdentifier: String
            let partIdentifier: String?
            let groupIdentifier: String?
            let category: String?
            let isCharging: Bool
            let vendorId: Int?
            let productId: Int?
            let combinedParts: [[String: Any]]?
        }
        
        var entries: [PmsetEntry] = []
        for dict in plists {
            guard let name = dict["Name"] as? String,
                  let capacity = dict["Current Capacity"] as? Int,
                  let accessoryId = dict["Accessory Identifier"] as? String else { continue }
            
            let isCharging: Bool
            if let charging = dict["Is Charging"] as? Bool {
                isCharging = charging
            } else if let state = dict["Power Source State"] as? String {
                isCharging = state == "AC Power"
            } else {
                isCharging = false
            }
            
            entries.append(PmsetEntry(
                name: name,
                capacity: capacity,
                accessoryIdentifier: accessoryId,
                partIdentifier: dict["Part Identifier"] as? String,
                groupIdentifier: dict["Group Identifier"] as? String,
                category: dict["Accessory Category"] as? String,
                isCharging: isCharging,
                vendorId: dict["Vendor ID"] as? Int,
                productId: dict["Product ID"] as? Int,
                combinedParts: dict["Combined Parts"] as? [[String: Any]]
            ))
        }
        
        var grouped: [String: [PmsetEntry]] = [:]
        var standalone: [PmsetEntry] = []
        for entry in entries {
            if let groupId = entry.groupIdentifier {
                grouped[groupId, default: []].append(entry)
            } else {
                standalone.append(entry)
            }
        }
        
        var out: [bleDevice] = []
        for entry in standalone {
            let state = entry.isCharging ? "charging" : "discharging"
            out.append(bleDevice(
                name: entry.name,
                address: entry.accessoryIdentifier,
                uuid: nil,
                batteryLevel: [KeyValue_t(key: "battery", value: "\(entry.capacity)", additional: state)],
                vendorId: entry.vendorId,
                productId: entry.productId
            ))
        }
        
        for (_, group) in grouped {
            let combinedEntry = group.first(where: { $0.partIdentifier == "Combined" })
            let caseEntry = group.first(where: { $0.partIdentifier == "Case" || $0.category == "Audio Battery Case" })
            let displayName = combinedEntry?.name ?? group.first(where: { !($0.category ?? "").contains("Case") })?.name ?? group.first?.name ?? ""
            let accessoryId = combinedEntry?.accessoryIdentifier ?? group.first?.accessoryIdentifier ?? ""
            
            var kv: [KeyValue_t] = []
            if let c = caseEntry {
                let state = c.isCharging ? "charging" : "discharging"
                kv.append(KeyValue_t(key: "case", value: "\(c.capacity)", additional: state))
            }
            if let parts = combinedEntry?.combinedParts {
                for part in parts {
                    guard let partId = part["Part Identifier"] as? String,
                          let cap = part["Current Capacity"] as? Int else { continue }
                    let charging = (part["Is Charging"] as? Bool) ?? false
                    let state = charging ? "charging" : "discharging"
                    kv.append(KeyValue_t(key: partId.lowercased(), value: "\(cap)", additional: state))
                }
            }
            if kv.isEmpty, let e = combinedEntry ?? group.first {
                let state = e.isCharging ? "charging" : "discharging"
                kv.append(KeyValue_t(key: "battery", value: "\(e.capacity)", additional: state))
            }
            
            let vendorId = combinedEntry?.vendorId ?? group.first?.vendorId
            let productId = combinedEntry?.productId ?? group.first?.productId
            out.append(bleDevice(
                name: displayName,
                address: accessoryId,
                uuid: nil,
                batteryLevel: kv,
                vendorId: vendorId,
                productId: productId
            ))
        }
        
        return out
    }
}

private struct DevicesState {
    var devices: [BLEDevice] = []
    var devicesToRemove: [UUID] = []
    var characteristicsDict: [UUID: CBCharacteristic] = [:]
    var bleLevels: [UUID: KeyValue_t] = [:]
}

internal class DevicesReader: Reader<[BLEDevice]>, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let worker = BluetoothReaderWorker()
    private let deviceLock = OSAllocatedUnfairLock(initialState: DevicesState())
    private var manager: CBCentralManager!
    
    static let batteryServiceUUID = CBUUID(string: "0x180F")
    static let batteryCharacteristicsUUID = CBUUID(string: "0x2A19")
    
    private let readLock = OSAllocatedUnfairLock(initialState: false)
    
    @MainActor public override init(_ module: ModuleType, popup: Bool = false, preview: Bool = false, history: Bool = false, callback: @escaping ([BLEDevice]?) -> Void = {_ in }) {
        super.init(module, popup: popup, preview: preview, history: history, callback: callback)
        self.defaultInterval = 30
        self.manager = CBCentralManager(delegate: self, queue: nil)
    }
    
    nonisolated public override func read() {
        let isReading = self.readLock.withLock { $0 }
        guard !isReading else { return }
        self.readLock.withLock { $0 = true }
        
        let worker = self.worker
        Task {
            defer { self.readLock.withLock { $0 = false } }
            
            let results = await worker.fetchSystemDevices()
            
            var list = results.cached
            results.hid.forEach { v in
                if !list.contains(where: {$0.address == v.address}) { list.append(v) }
            }
            results.SPB.0.forEach { v in
                if !list.contains(where: {$0.address == v.address}) { list.append(v) }
            }
            
            let finalList = list
            await MainActor.run {
                let identifiers = self.deviceLock.withLock { $0.devices.compactMap({ $0.uuid }) }
                let peripherals = self.manager.retrievePeripherals(withIdentifiers: identifiers)
                let isScanning = self.manager.isScanning
                let batteryUUID = DevicesReader.batteryServiceUUID
                
                let (toConnect, toInitialize, result) = self.deviceLock.withLock { state in
                    results.paired.forEach { (device: ioDevice) in
                        guard let data = finalList.first(where: { $0.address == device.address }) else { return }
                        
                        let rssi = device.rssi == 127 ? nil : Int(device.rssi)
                        if let idx = state.devices.firstIndex(where: { $0.address == data.address }) {
                            state.devices[idx].RSSI = rssi
                            state.devices[idx].batteryLevel = data.batteryLevel
                            state.devices[idx].isPaired = device.isPaired
                            state.devices[idx].isConnected = device.isConnected
                            if state.devices[idx].vendorId == nil { state.devices[idx].vendorId = data.vendorId }
                            if state.devices[idx].productId == nil { state.devices[idx].productId = data.productId }
                            return
                        }
                        
                        state.devices.append(BLEDevice(
                            address: data.address,
                            name: data.name ?? device.name,
                            uuid: data.uuid,
                            RSSI: rssi,
                            batteryLevel: data.batteryLevel,
                            isConnected: device.isConnected,
                            isPaired: device.isPaired,
                            vendorId: data.vendorId,
                            productId: data.productId
                        ))
                    }
                    
                    var connectList: [CBPeripheral] = []
                    var initList: [CBPeripheral] = []
                    peripherals.forEach { (p: CBPeripheral) in
                        guard let idx = state.devices.firstIndex(where: { $0.uuid == p.identifier }) else { return }
                        if state.devices[idx].peripheral == nil { state.devices[idx].peripheral = p }
                        
                        if p.state == .disconnected {
                            if isScanning { connectList.append(p) }
                        } else if p.state == .disconnecting {
                            state.devicesToRemove.append(p.identifier)
                        } else if p.state == .connected && !state.devices[idx].isPeripheralInitialized {
                            initList.append(p)
                            state.devices[idx].isPeripheralInitialized = true
                        }
                    }
                    
                    for (i, d) in state.devices.enumerated() {
                        if let uuid = d.uuid, let val = state.bleLevels[uuid] {
                            state.devices[i].batteryLevel = [val]
                        }
                    }
                    
                    if !state.devicesToRemove.isEmpty {
                        state.devices = state.devices.filter { !state.devicesToRemove.contains($0.uuid ?? UUID()) }
                        state.devicesToRemove = []
                    }
                    if !results.SPB.1.isEmpty {
                        state.devices = state.devices.filter({ !results.SPB.1.contains($0.address) })
                    }
                    
                    results.pmset.forEach { p in
                        let pmsetName = (p.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if !pmsetName.isEmpty, let idx = state.devices.firstIndex(where: {
                            let deviceName = $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            return deviceName == pmsetName || deviceName.contains(pmsetName) || pmsetName.contains(deviceName)
                        }) {
                            if !p.batteryLevel.isEmpty { state.devices[idx].batteryLevel = p.batteryLevel }
                            return
                        }
                        if let pVendor = p.vendorId, let pProduct = p.productId, let idx = state.devices.firstIndex(where: { $0.vendorId == pVendor && $0.productId == pProduct }) {
                            if !p.batteryLevel.isEmpty { state.devices[idx].batteryLevel = p.batteryLevel }
                            return
                        }
                        state.devices.append(BLEDevice(
                            address: p.address,
                            name: p.name ?? "",
                            uuid: p.uuid,
                            RSSI: 100,
                            batteryLevel: p.batteryLevel,
                            isConnected: true,
                            isPaired: false,
                            vendorId: p.vendorId,
                            productId: p.productId
                        ))
                    }
                    
                    return (connectList, initList, state.devices.filter({ $0.RSSI != nil }))
                }
                
                if let old = self.value, old != result {
                    self.callback(result)
                } else if self.value == nil {
                    self.callback(result)
                }
                
                toConnect.forEach { self.manager.connect($0, options: nil) }
                toInitialize.forEach { p in
                    p.delegate = self
                    p.discoverServices([batteryUUID])
                }
            }
        }
    }
    
    // MARK: - CBCentralManager
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOff {
            central.stopScan()
        } else if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        self.deviceLock.withLock { $0.devicesToRemove.append(peripheral.identifier) }
    }
    
    // MARK: - CBPeripheral
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return }
        guard let service = peripheral.services?.first(where: { $0.uuid == DevicesReader.batteryServiceUUID }) else { return }
        peripheral.discoverCharacteristics([DevicesReader.batteryCharacteristicsUUID], for: service)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {}
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        guard let batteryCharacteristics = service.characteristics?.first(where: { $0.uuid == DevicesReader.batteryCharacteristicsUUID }) else { return }
        self.deviceLock.withLock { $0.characteristicsDict[peripheral.identifier] = batteryCharacteristics }
        peripheral.readValue(for: batteryCharacteristics)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else { return }
        if let batteryLevel = characteristic.value?[0] {
            self.deviceLock.withLock { $0.bleLevels[peripheral.identifier] = KeyValue_t(key: "battery", value: "\(batteryLevel)") }
        }
    }
}
