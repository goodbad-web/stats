//
//  smc.swift
//  SMC
//
//  Created by Serhiy Mytrovtsiy on 25/05/2021.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2021 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation
import IOKit

internal enum SMCDataType: String {
    case UI8 = "ui8 "
    case UI16 = "ui16"
    case UI32 = "ui32"
    case SP1E = "sp1e"
    case SP3C = "sp3c"
    case SP4B = "sp4b"
    case SP5A = "sp5a"
    case SPA5 = "spa5"
    case SP69 = "sp69"
    case SP78 = "sp78"
    case SP87 = "sp87"
    case SP96 = "sp96"
    case SPB4 = "spb4"
    case SPF0 = "spf0"
    case FLT = "flt "
    case FPE2 = "fpe2"
    case SP2E = "sp2e"
    case SP3E = "sp3e"
    case SP4E = "sp4e"
    case SP5E = "sp5e"
    case FP2E = "fp2e"
    case FDS = "{fds"
}

internal enum SMCKeys: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
    case readPLimit = 11
    case readVers = 12
}

public enum FanMode: Int, Codable {
    case automatic = 0
    case forced = 1
    case auto3 = 3

    public var isAutomatic: Bool {
        self == .automatic || self == .auto3
    }
}

internal struct SMCKeyData_t {
    typealias SMCBytes_t = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8)
    
    struct vers_t {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }
    
    struct LimitData_t {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    
    struct keyInfo_t {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }
    
    var key: UInt32 = 0
    var vers = vers_t()
    var pLimitData = LimitData_t()
    var keyInfo = keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0))
}

public struct SMCVal_t {
    public var key: String
    public var dataSize: UInt32 = 0
    public var dataType: String = ""
    public var bytes: [UInt8] = Array(repeating: 0, count: 32)
    
    public init(_ key: String) {
        self.key = key
    }
}

extension FourCharCode {
    init(fromString str: String) {
        var string = str
        if string.count < 4 {
            string = string.padding(toLength: 4, withPad: " ", startingAt: 0)
        } else if string.count > 4 {
            string = String(string.prefix(4))
        }
        
        self = string.utf8.reduce(0) { sum, character in
            return sum << 8 | UInt32(character)
        }
    }
    
    func toString() -> String {
        return String(describing: UnicodeScalar(self >> 24 & 0xff)!) +
               String(describing: UnicodeScalar(self >> 16 & 0xff)!) +
               String(describing: UnicodeScalar(self >> 8  & 0xff)!) +
               String(describing: UnicodeScalar(self       & 0xff)!)
    }
}

extension UInt16 {
    init(bytes: (UInt8, UInt8)) {
        self = UInt16(bytes.0) << 8 | UInt16(bytes.1)
    }
}

extension UInt32 {
    init(bytes: (UInt8, UInt8, UInt8, UInt8)) {
        self = UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3)
    }
}

extension Int {
    init(fromFPE2 bytes: (UInt8, UInt8)) {
        self = (Int(bytes.0) << 6) + (Int(bytes.1) >> 2)
    }
}

extension Float {
    init?(_ bytes: [UInt8]) {
        self = bytes.withUnsafeBytes {
            return $0.load(fromByteOffset: 0, as: Self.self)
        }
    }
    
    var bytes: [UInt8] {
        withUnsafeBytes(of: self, Array.init)
    }
}
public actor SMC {
    public static let shared = SMC()
    nonisolated private let connection: IOConnection?
    private var provider: SMCProvider? = nil
    private var keyInfoCache: [String: (size: UInt32, type: String)] = [:]
    
    private init() {
        var iterator: io_iterator_t = 0
        let matchingDictionary = IOServiceMatching("AppleSMC")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
        
        guard result == kIOReturnSuccess else {
            print("Error IOServiceGetMatchingServices(): \(result)")
            self.connection = nil
            return
        }
        
        let ioIterator = IOIterator(iterator)
        let device = ioIterator.next()
        if device == 0 {
            print("Error: No AppleSMC device found")
            self.connection = nil
            return
        }
        
        var conn: io_connect_t = 0
        let openResult = IOServiceOpen(device, mach_task_self_, 0, &conn)
        IOObjectRelease(device)
        
        guard openResult == kIOReturnSuccess else {
            print("Error IOServiceOpen(): \(openResult)")
            self.connection = nil
            return
        }
        
        self.connection = IOConnection(conn)
    }
    
    private static func isZeroAllowed(_ key: String) -> Bool {
        key == "Ftst" || key == "ID0R" || key == "VD0R" || key == "PADC" || key == "PADV" || key == "PSTR" || key.range(of: #"^F\d"#, options: .regularExpression) != nil
    }
    
    private func _getValueUnsafe(_ key: String) -> Double? {
        var val: SMCVal_t = SMCVal_t(key)
        let result = read(&val)
        if result != kIOReturnSuccess { return nil }
        guard val.dataSize > 0 else { return nil }
        if val.bytes.first(where: { $0 != 0 }) == nil && !Self.isZeroAllowed(val.key) { return nil }
        
        return SMCConverter.convert(val)
    }
    
    public func getValue(_ key: String) -> Double? {
        return self._getValueUnsafe(key)
    }
    
    public func getValues(_ keys: [String]) -> [String: Double] {
        var results: [String: Double] = [:]
        for key in keys {
            if let val = self._getValueUnsafe(key) {
                results[key] = val
            }
        }
        return results
    }
    
    public func getStringValue(_ key: String) -> String? {
        var val: SMCVal_t = SMCVal_t(key)
        if read(&val) != kIOReturnSuccess || val.dataSize == 0 { return nil }
        if val.bytes.first(where: { $0 != 0}) == nil { return nil }
        
        if val.dataType == SMCDataType.FDS.rawValue {
            var str = ""
            for i in 4..<16 {
                if val.bytes[i] == 0 { break }
                str.append(Character(UnicodeScalar(val.bytes[i])))
            }
            return str.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
    
    public func getAllKeys() -> [String] {
        var list: [String] = []
        guard let keysNum = self._getValueUnsafe("#KEY") else { return list }
        
        for i in 0...Int(keysNum) {
            var input = SMCKeyData_t()
            var output = SMCKeyData_t()
            input.data8 = SMCKeys.readIndex.rawValue
            input.data32 = UInt32(i)
            if call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output) == kIOReturnSuccess {
                list.append(output.key.toString())
            }
        }
        return list
    }
    
    private func getProvider() -> SMCProvider {
        if let provider = self.provider {
            return provider
        }
        let provider = AppleSiliconSMCProvider(self)
        self.provider = provider
        return provider
    }
    
    public func fanModeKey(_ id: Int) -> String {
        return self.getProvider().fanModeKey(id)
    }
    
    @discardableResult
    public func setFanMode(_ id: Int, mode: FanMode) async -> Bool {
        await self.getProvider().setFanMode(id, mode: mode)
    }
    
    @discardableResult
    public func setFanSpeed(_ id: Int, speed: Int) async -> Bool {
        await self.getProvider().setFanSpeed(id, speed: speed)
    }
    
    public func resetFanControl() async -> Bool {
        return await self.getProvider().resetFanControl()
    }
    
    fileprivate func read(_ value: UnsafeMutablePointer<SMCVal_t>) -> kern_return_t {
        let key = value.pointee.key
        
        if let cached = self.keyInfoCache[key] {
            value.pointee.dataSize = cached.size
            value.pointee.dataType = cached.type
        } else {
            var input = SMCKeyData_t()
            var output = SMCKeyData_t()
            input.key = FourCharCode(fromString: key)
            input.data8 = SMCKeys.readKeyInfo.rawValue
            
            let result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
            if result != kIOReturnSuccess || output.result != 0 {
                return result != kIOReturnSuccess ? result : kern_return_t(output.result)
            }
            
            let size = UInt32(output.keyInfo.dataSize)
            let type = output.keyInfo.dataType.toString()
            self.keyInfoCache[key] = (size: size, type: type)
            
            value.pointee.dataSize = size
            value.pointee.dataType = type
        }
        
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        input.key = FourCharCode(fromString: key)
        input.keyInfo.dataSize = IOByteCount32(value.pointee.dataSize)
        input.data8 = SMCKeys.readBytes.rawValue
        
        let result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess || output.result != 0 {
            return result != kIOReturnSuccess ? result : kern_return_t(output.result)
        }
        
        memcpy(&value.pointee.bytes, &output.bytes, Int(value.pointee.dataSize))
        return kIOReturnSuccess
    }
    
    public func write(_ value: SMCVal_t) -> kern_return_t {
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        input.key = FourCharCode(fromString: value.key)
        input.data8 = SMCKeys.writeBytes.rawValue
        input.keyInfo.dataSize = IOByteCount32(value.dataSize)
        input.bytes = (value.bytes[0], value.bytes[1], value.bytes[2], value.bytes[3], value.bytes[4], value.bytes[5],
                       value.bytes[6], value.bytes[7], value.bytes[8], value.bytes[9], value.bytes[10], value.bytes[11],
                       value.bytes[12], value.bytes[13], value.bytes[14], value.bytes[15], value.bytes[16], value.bytes[17],
                       value.bytes[18], value.bytes[19], value.bytes[20], value.bytes[21], value.bytes[22], value.bytes[23],
                       value.bytes[24], value.bytes[25], value.bytes[26], value.bytes[27], value.bytes[28], value.bytes[29],
                       value.bytes[30], value.bytes[31])
        
        let result = self.call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        return result != kIOReturnSuccess ? result : kern_return_t(output.result)
    }
    
    public func write(_ key: String, _ value: Int) -> kern_return_t {
        var val: SMCVal_t = SMCVal_t(key)
        let result = self.read(&val)
        if result != kIOReturnSuccess { return result }
        
        switch val.dataType {
        case SMCDataType.UI8.rawValue:
            val.bytes[0] = UInt8(value)
        case SMCDataType.UI16.rawValue:
            let v = UInt16(value)
            val.bytes[0] = UInt8(v >> 8)
            val.bytes[1] = UInt8(v & 0xFF)
        case SMCDataType.UI32.rawValue:
            let v = UInt32(value)
            val.bytes[0] = UInt8(v >> 24)
            val.bytes[1] = UInt8((v >> 16) & 0xFF)
            val.bytes[2] = UInt8((v >> 8) & 0xFF)
            val.bytes[3] = UInt8(v & 0xFF)
        case SMCDataType.SP78.rawValue:
            let v = UInt16(value * 256)
            val.bytes[0] = UInt8(v >> 8)
            val.bytes[1] = UInt8(v & 0xFF)
        default:
            return kIOReturnError
        }
        
        return self.write(val)
    }
    
    fileprivate func call(_ index: UInt8, input: inout SMCKeyData_t, output: inout SMCKeyData_t) -> kern_return_t {
        guard let conn = self.connection?.connection else { return kIOReturnNotOpen }
        let inputSize = MemoryLayout<SMCKeyData_t>.stride
        var outputSize = MemoryLayout<SMCKeyData_t>.stride
        return IOConnectCallStructMethod(conn, UInt32(index), &input, inputSize, &output, &outputSize)
    }
    
    fileprivate func writeWithRetry(_ value: SMCVal_t, maxAttempts: Int = 10, delayMicros: UInt32 = 50_000) async -> Bool {
        for attempt in 0..<maxAttempts {
            if self.write(value) == kIOReturnSuccess { return true }
            if attempt < maxAttempts - 1 {
                try? await Task.sleep(nanoseconds: UInt64(delayMicros) * 1000)
            }
        }
        return false
    }
}

// MARK: - Converter

internal struct SMCConverter {
    static func convert(_ val: SMCVal_t) -> Double? {
        let getInt16 = { (bytes: [UInt8]) -> Int16 in
            return Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        }
        
        switch val.dataType {
        case SMCDataType.UI8.rawValue: return Double(val.bytes[0])
        case SMCDataType.UI16.rawValue: return Double(UInt16(val.bytes[0]) << 8 | UInt16(val.bytes[1]))
        case SMCDataType.UI32.rawValue: return Double(UInt32(val.bytes[0]) << 24 | UInt32(val.bytes[1]) << 16 | UInt32(val.bytes[2]) << 8 | UInt32(val.bytes[3]))
        case SMCDataType.FLT.rawValue: return Float(val.bytes).map { Double($0) }
        case SMCDataType.SP1E.rawValue, SMCDataType.SP2E.rawValue, SMCDataType.SP3E.rawValue, SMCDataType.SP4E.rawValue, SMCDataType.SP5E.rawValue:
            return Double(getInt16(val.bytes)) / 16384
        case SMCDataType.SP3C.rawValue: return Double(getInt16(val.bytes)) / 4096
        case SMCDataType.SP4B.rawValue: return Double(getInt16(val.bytes)) / 2048
        case SMCDataType.SP5A.rawValue: return Double(getInt16(val.bytes)) / 1024
        case SMCDataType.SPA5.rawValue: return Double(getInt16(val.bytes)) / 32
        case SMCDataType.SP69.rawValue: return Double(getInt16(val.bytes)) / 512
        case SMCDataType.SP78.rawValue: return Double(getInt16(val.bytes)) / 256
        case SMCDataType.SP87.rawValue: return Double(getInt16(val.bytes)) / 128
        case SMCDataType.SP96.rawValue: return Double(getInt16(val.bytes)) / 64
        case SMCDataType.SPB4.rawValue: return Double(getInt16(val.bytes)) / 16
        case SMCDataType.SPF0.rawValue: return Double(getInt16(val.bytes))
        case SMCDataType.FP2E.rawValue: return Double(UInt16(val.bytes[0]) << 8 | UInt16(val.bytes[1])) / 16384
        case SMCDataType.FPE2.rawValue: return Double(UInt16(val.bytes[0]) << 8 | UInt16(val.bytes[1])) / 4
        default: return nil
        }
    }
}

// MARK: - Strategy Pattern

internal protocol SMCProvider: Sendable {
    func fanModeKey(_ id: Int) -> String
    func setFanMode(_ id: Int, mode: FanMode) async -> Bool
    func setFanSpeed(_ id: Int, speed: Int) async -> Bool
    func resetFanControl() async -> Bool
}

class AppleSiliconSMCProvider: SMCProvider, @unchecked Sendable {
    private weak var parent: SMC?
    private var _fanModeKeyIsLower: Bool?
    
    init(_ parent: SMC) {
        self.parent = parent
    }
    
    func fanModeKey(_ id: Int) -> String {
        return "F\(id)md"
    }
    
    func setFanMode(_ id: Int, mode: FanMode) async -> Bool {
        guard let parent = self.parent else { return false }
        if mode == .forced {
            return await self.unlockFanControl(fanId: id)
        } else {
            let modeKey = self.fanModeKey(id)
            var modeVal = SMCVal_t(modeKey)
            guard await parent.read(&modeVal) == kIOReturnSuccess else { return false }
            var success = true
            if modeVal.bytes[0] != 0 {
                modeVal.bytes[0] = 0
                success = await parent.writeWithRetry(modeVal)
            }
            return await self.resetFtstIfAllAuto() && success
        }
    }
    
    func setFanSpeed(_ id: Int, speed: Int) async -> Bool {
        guard let parent = self.parent else { return false }
        var modeVal = SMCVal_t(self.fanModeKey(id))
        if await parent.read(&modeVal) != kIOReturnSuccess { return false }
        
        var value = SMCVal_t("F\(id)Tg")
        if await parent.read(&value) != kIOReturnSuccess { return false }
        
        let bytes = Float(speed).bytes
        value.bytes[0] = bytes[0]
        value.bytes[1] = bytes[1]
        value.bytes[2] = bytes[2]
        value.bytes[3] = bytes[3]
        
        return await parent.writeWithRetry(value)
    }
    
    func resetFanControl() async -> Bool {
        guard let parent = self.parent, let count = await parent.getValue("FNum") else { return false }
        var success = true
        
        for i in 0..<Int(count) {
            var modeVal = SMCVal_t(self.fanModeKey(i))
            guard await parent.read(&modeVal) == kIOReturnSuccess else {
                success = false
                continue
            }
            if modeVal.bytes[0] != 0 {
                modeVal.bytes[0] = 0
                success = await parent.writeWithRetry(modeVal) && success
            }
        }
        
        var ftstVal = SMCVal_t("Ftst")
        guard await parent.read(&ftstVal) == kIOReturnSuccess else { return success }
        if ftstVal.bytes[0] != 0 {
            ftstVal.bytes[0] = 0
            success = await parent.writeWithRetry(ftstVal) && success
        }
        
        return success
    }
    
    private func unlockFanControl(fanId: Int) async -> Bool {
        guard let parent = self.parent else { return false }
        let modeKey = self.fanModeKey(fanId)
        var modeVal = SMCVal_t(modeKey)
        if await parent.read(&modeVal) == kIOReturnSuccess && modeVal.bytes[0] == 1 { return true }
        
        modeVal.bytes[0] = 1
        if await parent.write(modeVal) == kIOReturnSuccess { return true }
        
        var ftstVal = SMCVal_t("Ftst")
        if await parent.read(&ftstVal) == kIOReturnSuccess && ftstVal.bytes[0] != 1 {
            ftstVal.bytes[0] = 1
            _ = await parent.writeWithRetry(ftstVal, maxAttempts: 50, delayMicros: 10_000)
        }
        
        _ = await parent.writeWithRetry(modeVal, maxAttempts: 100, delayMicros: 20_000)
        return await parent.read(&modeVal) == kIOReturnSuccess && modeVal.bytes[0] == 1
    }
    
    private func resetFtstIfAllAuto() async -> Bool {
        guard let parent = self.parent, let count = await parent.getValue("FNum") else { return false }
        for i in 0..<Int(count) {
            var modeVal = SMCVal_t(self.fanModeKey(i))
            guard await parent.read(&modeVal) == kIOReturnSuccess else { return false }
            if modeVal.bytes[0] != 0 { return true }
        }
        var ftstVal = SMCVal_t("Ftst")
        guard await parent.read(&ftstVal) == kIOReturnSuccess else { return true }
        guard ftstVal.bytes[0] != 0 else { return true }
        ftstVal.bytes[0] = 0
        return await parent.writeWithRetry(ftstVal)
    }
}

// MARK: - System Resources

/// A safe wrapper for IOKit objects to ensure they are released properly.
public final class IOObject: @unchecked Sendable {
    private(set) var object: io_object_t
    
    public init(_ object: io_object_t) {
        self.object = object
    }
    
    deinit {
        if object != 0 {
            IOObjectRelease(object)
        }
    }
    
    public func release() {
        if object != 0 {
            IOObjectRelease(object)
            object = 0
        }
    }
}

/// A safe wrapper for IOKit connections.
public final class IOConnection: @unchecked Sendable {
    private(set) var connection: io_connect_t
    
    public init(_ connection: io_connect_t) {
        self.connection = connection
    }
    
    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }
}

/// A safe wrapper for IOKit iterators.
public final class IOIterator: @unchecked Sendable {
    private(set) var iterator: io_iterator_t
    
    public init(_ iterator: io_iterator_t) {
        self.iterator = iterator
    }
    
    deinit {
        if iterator != 0 {
            IOObjectRelease(iterator)
        }
    }
    
    public func next() -> io_object_t {
        return IOIteratorNext(iterator)
    }
}
