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

internal struct SMCVal_t {
    var key: String
    var dataSize: UInt32 = 0
    var dataType: String = ""
    var bytes: [UInt8] = Array(repeating: 0, count: 32)
    
    init(_ key: String) {
        self.key = key
    }
}

extension FourCharCode {
    init(fromString str: String) {
        precondition(str.count == 4)
        
        self = str.utf8.reduce(0) { sum, character in
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

public class SMC {
    public static let shared = SMC()
    private var conn: io_connect_t = 0
    private var _fanModeKeyIsLower: Bool?
    private let queue = DispatchQueue(label: "eu.exelban.Stats.SMC", qos: .userInteractive)
    
    public init() {
        var result: kern_return_t
        var iterator: io_iterator_t = 0
        let device: io_object_t
        
        let matchingDictionary: CFMutableDictionary = IOServiceMatching("AppleSMC")
        result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
        if result != kIOReturnSuccess {
            print("Error IOServiceGetMatchingServices(): " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return
        }
        
        device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        if device == 0 {
            print("Error IOIteratorNext(): " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return
        }
        
        result = IOServiceOpen(device, mach_task_self_, 0, &conn)
        IOObjectRelease(device)
        if result != kIOReturnSuccess {
            print("Error IOServiceOpen(): " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
            return
        }
    }
    
    deinit {
        let result = self.close()
        if result != kIOReturnSuccess {
            print("error close smc connection: " + (String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"))
        }
    }
    
    public func close() -> kern_return_t {
        return IOServiceClose(conn)
    }
    
    private static func isZeroAllowed(_ key: String) -> Bool {
        key == "FS! " || key == "Ftst" || key.range(of: #"^F\d"#, options: .regularExpression) != nil
    }
    
    /// Lock-free getValue for use inside queue.sync blocks (avoids recursive lock)
    private func _getValueUnsafe(_ key: String) -> Double? {
        var val: SMCVal_t = SMCVal_t(key)
        let result = read(&val)
        if result != kIOReturnSuccess { return nil }
        guard val.dataSize > 0 else { return nil }
        if val.bytes.first(where: { $0 != 0 }) == nil && !Self.isZeroAllowed(val.key) { return nil }
        switch val.dataType {
        case SMCDataType.UI8.rawValue: return Double(val.bytes[0])
        case SMCDataType.UI16.rawValue: return Double(UInt16(val.bytes[0]) << 8 | UInt16(val.bytes[1]))
        case SMCDataType.UI32.rawValue: return Double(UInt32(val.bytes[0]) << 24 | UInt32(val.bytes[1]) << 16 | UInt32(val.bytes[2]) << 8 | UInt32(val.bytes[3]))
        case SMCDataType.SP1E.rawValue: return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 16384
        case SMCDataType.SP2E.rawValue: return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 8192
        case SMCDataType.SP3E.rawValue: return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 4096
        case SMCDataType.SP4E.rawValue: return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 2048
        case SMCDataType.SP5E.rawValue: return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 1024
        case SMCDataType.SP69.rawValue: return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 512
        case SMCDataType.SP78.rawValue: return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 256
        case SMCDataType.SP87.rawValue: return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 128
        case SMCDataType.SP96.rawValue: return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 64
        case SMCDataType.SPB4.rawValue: return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 16
        case SMCDataType.SPF0.rawValue: return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
        case SMCDataType.FLT.rawValue: return Float(val.bytes).map { Double($0) }
        case SMCDataType.FPE2.rawValue: return Double(Int(fromFPE2: (val.bytes[0], val.bytes[1])))
        default: return nil
        }
    }
    
    public func getValue(_ key: String) -> Double? {
        return queue.sync {
        var result: kern_return_t = 0
        var val: SMCVal_t = SMCVal_t(key)
        
        result = read(&val)
        if result != kIOReturnSuccess {
            return nil
        }
        
        if val.dataSize > 0 {
            if val.bytes.first(where: { $0 != 0 }) == nil && !Self.isZeroAllowed(val.key) {
                return nil
            }
            
            switch val.dataType {
            case SMCDataType.UI8.rawValue:
                return Double(val.bytes[0])
            case SMCDataType.UI16.rawValue:
                return Double(UInt16(bytes: (val.bytes[0], val.bytes[1])))
            case SMCDataType.UI32.rawValue:
                return Double(UInt32(bytes: (val.bytes[0], val.bytes[1], val.bytes[2], val.bytes[3])))
            case SMCDataType.SP1E.rawValue:
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 16384)
            case SMCDataType.SP3C.rawValue:
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 4096)
            case SMCDataType.SP4B.rawValue:
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 2048)
            case SMCDataType.SP5A.rawValue:
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 1024)
            case SMCDataType.SP69.rawValue:
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 512)
            case SMCDataType.SP78.rawValue:
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return Double(intValue / 256)
            case SMCDataType.SP87.rawValue:
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return Double(intValue / 128)
            case SMCDataType.SP96.rawValue:
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return Double(intValue / 64)
            case SMCDataType.SPA5.rawValue:
                let result: Double = Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1]))
                return Double(result / 32)
            case SMCDataType.SPB4.rawValue:
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return Double(intValue / 16)
            case SMCDataType.SPF0.rawValue:
                let intValue: Double = Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
                return intValue
            case SMCDataType.FLT.rawValue:
                let value: Float? = Float(val.bytes)
                if value != nil {
                    return Double(value!)
                }
                return nil
            case SMCDataType.FPE2.rawValue:
                return Double(Int(fromFPE2: (val.bytes[0], val.bytes[1])))
            default:
                return nil
            }
        }
        
        return nil
        } // queue.sync
    }
    
    public func getStringValue(_ key: String) -> String? {
        return queue.sync {
        var result: kern_return_t = 0
        var val: SMCVal_t = SMCVal_t(key)
        
        result = read(&val)
        if result != kIOReturnSuccess {
            return nil
        }
        
        if val.dataSize > 0 {
            if val.bytes.first(where: { $0 != 0}) == nil {
                return nil
            }
            
            switch val.dataType {
            case SMCDataType.FDS.rawValue:
                let c1  = String(UnicodeScalar(val.bytes[4]))
                let c2  = String(UnicodeScalar(val.bytes[5]))
                let c3  = String(UnicodeScalar(val.bytes[6]))
                let c4  = String(UnicodeScalar(val.bytes[7]))
                let c5  = String(UnicodeScalar(val.bytes[8]))
                let c6  = String(UnicodeScalar(val.bytes[9]))
                let c7  = String(UnicodeScalar(val.bytes[10]))
                let c8  = String(UnicodeScalar(val.bytes[11]))
                let c9  = String(UnicodeScalar(val.bytes[12]))
                let c10 = String(UnicodeScalar(val.bytes[13]))
                let c11 = String(UnicodeScalar(val.bytes[14]))
                let c12 = String(UnicodeScalar(val.bytes[15]))
                
                return (c1 + c2 + c3 + c4 + c5 + c6 + c7 + c8 + c9 + c10 + c11 + c12).trimmingCharacters(in: .whitespaces)
            default:
                return nil
            }
        }
        
        return nil
        } // queue.sync
    }
    
    public func getAllKeys() -> [String] {
        return queue.sync {
        var list: [String] = []
        
        let keysNum: Double? = self._getValueUnsafe("#KEY")
        guard let keysNum else { return list }
        
        var result: kern_return_t = 0
        var input: SMCKeyData_t = SMCKeyData_t()
        var output: SMCKeyData_t = SMCKeyData_t()
        
        for i in 0...Int(keysNum) {
            input = SMCKeyData_t()
            output = SMCKeyData_t()
            
            input.data8 = SMCKeys.readIndex.rawValue
            input.data32 = UInt32(i)
            
            result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
            if result != kIOReturnSuccess {
                continue
            }
            
            list.append(output.key.toString())
        }
        
        return list
        } // queue.sync
    }
    
    public func write(_ key: String, _ newValue: Int) -> kern_return_t {
        var value = SMCVal_t(key)
        value.dataSize = 2
        value.bytes = [UInt8(newValue >> 6), UInt8((newValue << 2) ^ ((newValue >> 6) << 8)), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                       UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                       UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                       UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                       UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                       UInt8(0), UInt8(0)]
        
        return self.write(value)
    }
    
    // MARK: - fans

    public func fanModeKey(_ id: Int) -> String {
        if _fanModeKeyIsLower == nil {
            var probe = SMCVal_t("F0md")
            _fanModeKeyIsLower = read(&probe) == kIOReturnSuccess && probe.dataSize > 0
        }
        return _fanModeKeyIsLower! ? "F\(id)md" : "F\(id)Md"
    }

    public func setFanMode(_ id: Int, mode: FanMode) {
        queue.sync {
        if mode == .forced {
            if !unlockFanControl(fanId: id) { return }
        } else {
            let modeKey = fanModeKey(id)
            let targetKey = "F\(id)Tg"
            
            // Reset fan mode to automatic
            var modeVal = SMCVal_t(modeKey)
            let readResult = read(&modeVal)
            if readResult == kIOReturnSuccess && modeVal.dataSize > 0 {
                if modeVal.bytes[0] != 0 {
                    modeVal.bytes[0] = 0
                    _ = self.writeWithRetry(modeVal)
                }
            }
            
            // Clear target speed
            var targetValue = SMCVal_t(targetKey)
            let result = read(&targetValue)
            if result == kIOReturnSuccess && targetValue.dataSize > 0 {
                let bytes = Float(0).bytes
                targetValue.bytes[0] = bytes[0]
                targetValue.bytes[1] = bytes[1]
                targetValue.bytes[2] = bytes[2]
                targetValue.bytes[3] = bytes[3]
                _ = self.writeWithRetry(targetValue)
            }
            
            // Reset Ftst if all fans are now automatic
            self.resetFtstIfAllAuto()
        }
        } // queue.sync
    }
    
    public func setFanSpeed(_ id: Int, speed: Int) {
        queue.sync {
        if let maxSpeed = self._getValueUnsafe("F\(id)Mx"),
           speed > Int(maxSpeed) {
            self._setFanSpeedUnsafe(id, speed: Int(maxSpeed))
            return
        }
        if speed != 0, let minSpeed = self._getValueUnsafe("F\(id)Mn"),
           speed < Int(minSpeed) {
            self._setFanSpeedUnsafe(id, speed: Int(minSpeed))
            return
        }
        self._setFanSpeedUnsafe(id, speed: speed)
        } // queue.sync
    }
    
    private func _setFanSpeedUnsafe(_ id: Int, speed: Int) {
        var modeVal = SMCVal_t(fanModeKey(id))
        let modeResult = read(&modeVal)
        guard modeResult == kIOReturnSuccess else {
            print(smcError("read", key: fanModeKey(id), result: modeResult))
            return
        }
        if modeVal.bytes[0] != 1 {
            if !unlockFanControl(fanId: id) { return }
        }
        
        var result: kern_return_t = 0
        var value = SMCVal_t("F\(id)Tg")
        
        result = read(&value)
        if result != kIOReturnSuccess {
            print(smcError("read", key: "F\(id)Tg", result: result))
            return
        }
        
        if value.dataType == "flt " {
            let bytes = Float(speed).bytes
            value.bytes[0] = bytes[0]
            value.bytes[1] = bytes[1]
            value.bytes[2] = bytes[2]
            value.bytes[3] = bytes[3]
        } else if value.dataType == "fpe2" {
            value.bytes[0] = UInt8(speed >> 6)
            value.bytes[1] = UInt8((speed << 2) ^ ((speed >> 6) << 8))
            value.bytes[2] = UInt8(0)
            value.bytes[3] = UInt8(0)
        }
        
        if !self.writeWithRetry(value) {
            return
        }
    }
    
    /// Format SMC error for logging with context
    private func smcError(_ operation: String, key: String, result: kern_return_t) -> String {
        let errorDesc = String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error"
        return "[\(key)] \(operation) failed: \(errorDesc) (0x\(String(result, radix: 16)))"
    }
    
    private func writeWithRetry(_ value: SMCVal_t, maxAttempts: Int = 10, delayMicros: UInt32 = 50_000) -> Bool {
        let mutableValue = value
        var lastResult: kern_return_t = kIOReturnSuccess
        for attempt in 0..<maxAttempts {
            lastResult = self.write(mutableValue)
            if lastResult == kIOReturnSuccess {
                return true
            }
            if attempt < maxAttempts - 1 {
                usleep(delayMicros)
            }
        }
        print(smcError("write", key: value.key, result: lastResult))
        return false
    }
    
    private func unlockFanControl(fanId: Int) -> Bool {
        // Try direct mode write first (works on M5+ without Ftst)
        let modeKey = fanModeKey(fanId)
        var modeVal = SMCVal_t(modeKey)
        let modeRead = read(&modeVal)
        guard modeRead == kIOReturnSuccess else {
            print(smcError("read", key: modeKey, result: modeRead))
            return false
        }
        modeVal.bytes[0] = 1
        if self.write(modeVal) == kIOReturnSuccess {
            return true
        }

        // Direct failed; try Ftst unlock (M1-M4)
        var ftstVal = SMCVal_t("Ftst")
        let ftstResult = read(&ftstVal)
        guard ftstResult == kIOReturnSuccess, ftstVal.dataSize > 0 else {
            return false
        }

        if ftstVal.bytes[0] == 1 {
            return retryModeWrite(fanId: fanId, maxAttempts: 20)
        }

        ftstVal.bytes[0] = 1
        if !self.writeWithRetry(ftstVal, maxAttempts: 100) {
            return false
        }

        // Wait for thermalmonitord to yield control
        usleep(3_000_000)

        return retryModeWrite(fanId: fanId, maxAttempts: 300)
    }
    
    private func retryModeWrite(fanId: Int, maxAttempts: Int) -> Bool {
        let modeKey = fanModeKey(fanId)
        var modeVal = SMCVal_t(modeKey)
        let result = read(&modeVal)
        guard result == kIOReturnSuccess else {
            print(smcError("read", key: modeKey, result: result))
            return false
        }
        modeVal.bytes[0] = 1
        return self.writeWithRetry(modeVal, maxAttempts: maxAttempts, delayMicros: 100_000)
    }
    
    public func resetFanControl() -> Bool {
        return queue.sync {
        // Reset FS! (Intel legacy)
        var fsValue = SMCVal_t("FS! ")
        if read(&fsValue) == kIOReturnSuccess && fsValue.dataSize > 0 {
            for i in 0..<Int(fsValue.dataSize) { fsValue.bytes[i] = 0 }
            _ = self.write(fsValue)
        }
        
        // Reset Ftst (Apple Silicon)
        var ftstPresent = false
        var value = SMCVal_t("Ftst")
        let result = read(&value)
        if result == kIOReturnSuccess && value.dataSize > 0 {
            ftstPresent = true
            if value.bytes[0] != 0 {
                value.bytes[0] = 0
                if !self.writeWithRetry(value) { return false }
            }
        }

        // Reset individual fan modes and target speeds
        guard let count = _getValueUnsafe("FNum") else {
            return ftstPresent
        }
        var success = true
        for i in 0..<Int(count) {
            let modeKey = fanModeKey(i)
            var modeVal = SMCVal_t(modeKey)
            let readResult = read(&modeVal)
            if readResult == kIOReturnSuccess && modeVal.bytes[0] != 0 {
                modeVal.bytes[0] = 0
                if !self.writeWithRetry(modeVal) { success = false }
            }
            
            let targetKey = "F\(i)Tg"
            var targetVal = SMCVal_t(targetKey)
            if read(&targetVal) == kIOReturnSuccess && targetVal.dataSize > 0 {
                let bytes = Float(0).bytes
                targetVal.bytes[0] = bytes[0]
                targetVal.bytes[1] = bytes[1]
                targetVal.bytes[2] = bytes[2]
                targetVal.bytes[3] = bytes[3]
                _ = self.writeWithRetry(targetVal)
            }
        }
        return success
        } // queue.sync
    }
    
    /// Reset Ftst if all fans are in automatic mode
    private func resetFtstIfAllAuto() {
        guard let count = getValue("FNum") else { return }
        for i in 0..<Int(count) {
            var modeVal = SMCVal_t(fanModeKey(i))
            if read(&modeVal) == kIOReturnSuccess && modeVal.bytes[0] != 0 {
                return // At least one fan is still forced
            }
        }
        // All fans automatic — reset Ftst
        var ftstVal = SMCVal_t("Ftst")
        if read(&ftstVal) == kIOReturnSuccess && ftstVal.dataSize > 0 && ftstVal.bytes[0] != 0 {
            ftstVal.bytes[0] = 0
            _ = self.writeWithRetry(ftstVal)
        }
    }
    
    // MARK: - internal functions
    
    private func read(_ value: UnsafeMutablePointer<SMCVal_t>) -> kern_return_t {
        var result: kern_return_t = 0
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        
        input.key = FourCharCode(fromString: value.pointee.key)
        input.data8 = SMCKeys.readKeyInfo.rawValue
        
        result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }
        
        value.pointee.dataSize = UInt32(output.keyInfo.dataSize)
        value.pointee.dataType = output.keyInfo.dataType.toString()
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = SMCKeys.readBytes.rawValue
        
        result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }
        
        memcpy(&value.pointee.bytes, &output.bytes, Int(value.pointee.dataSize))
        
        return kIOReturnSuccess
    }
    
    private func write(_ value: SMCVal_t) -> kern_return_t {
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
        if result != kIOReturnSuccess {
            return result
        }
        
        return kIOReturnSuccess
    }
    
    private func call(_ index: UInt8, input: inout SMCKeyData_t, output: inout SMCKeyData_t) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData_t>.stride
        var outputSize = MemoryLayout<SMCKeyData_t>.stride
        
        return IOConnectCallStructMethod(conn, UInt32(index), &input, inputSize, &output, &outputSize)
    }
}
