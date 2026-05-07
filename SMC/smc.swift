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
    private var fanController: AppleSiliconSMC!
    
    public init() {
        self.fanController = AppleSiliconSMC(self)
        
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
        key == "Ftst" || key.range(of: #"^F\d"#, options: .regularExpression) != nil
    }
    
    /// Lock-free getValue for use inside queue.sync blocks (avoids recursive lock)
    fileprivate func _getValueUnsafe(_ key: String) -> Double? {
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
            return self._getValueUnsafe(key)
        }
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
            self.fanController.setFanMode(id, mode: mode)
        }
    }
    
    public func setFanSpeed(_ id: Int, speed: Int) {
        queue.sync {
            self._setFanSpeedUnsafe(id, speed: speed)
        }
    }
    
    fileprivate func _setFanSpeedUnsafe(_ id: Int, speed: Int) {
        var modeVal = SMCVal_t(fanModeKey(id))
        let modeResult = read(&modeVal)
        guard modeResult == kIOReturnSuccess else {
            return
        }
        
        var result: kern_return_t = 0
        var value = SMCVal_t("F\(id)Tg")
        
        result = read(&value)
        if result != kIOReturnSuccess {
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
        
        _ = self.writeWithRetry(value)
    }
    
    fileprivate func writeWithRetry(_ value: SMCVal_t, maxAttempts: Int = 10, delayMicros: UInt32 = 50_000) -> Bool {
        let mutableValue = value
        for attempt in 0..<maxAttempts {
            if self.write(mutableValue) == kIOReturnSuccess {
                return true
            }
            if attempt < maxAttempts - 1 {
                usleep(delayMicros)
            }
        }
        return false
    }
    
    public func resetFanControl() -> Bool {
        return queue.sync {
            self.fanController.resetFanControl()
        }
    }
    
    // MARK: - internal functions
    
    fileprivate func read(_ value: UnsafeMutablePointer<SMCVal_t>) -> kern_return_t {
        var result: kern_return_t = 0
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        
        input.key = FourCharCode(fromString: value.pointee.key)
        input.data8 = SMCKeys.readKeyInfo.rawValue
        
        result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }
        if output.result != 0 {
            return kern_return_t(output.result)
        }
        
        value.pointee.dataSize = UInt32(output.keyInfo.dataSize)
        value.pointee.dataType = output.keyInfo.dataType.toString()
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = SMCKeys.readBytes.rawValue
        
        result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result != kIOReturnSuccess {
            return result
        }
        if output.result != 0 {
            return kern_return_t(output.result)
        }
        
        memcpy(&value.pointee.bytes, &output.bytes, Int(value.pointee.dataSize))
        
        return kIOReturnSuccess
    }
    
    fileprivate func write(_ value: SMCVal_t) -> kern_return_t {
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
        if output.result != 0 {
            return kern_return_t(output.result)
        }
        
        return kIOReturnSuccess
    }
    
    fileprivate func call(_ index: UInt8, input: inout SMCKeyData_t, output: inout SMCKeyData_t) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData_t>.stride
        var outputSize = MemoryLayout<SMCKeyData_t>.stride
        
        return IOConnectCallStructMethod(conn, UInt32(index), &input, inputSize, &output, &outputSize)
    }
}

// MARK: - Providers

internal class AppleSiliconSMC {
    private weak var parent: SMC?
    
    init(_ parent: SMC) {
        self.parent = parent
    }
    
    func setFanMode(_ id: Int, mode: FanMode) {
        guard let parent = self.parent else { return }
        
        if mode == .forced {
            _ = self.unlockFanControl(fanId: id)
        } else {
            let modeKey = parent.fanModeKey(id)
            var modeVal = SMCVal_t(modeKey)
            if parent.read(&modeVal) == kIOReturnSuccess && modeVal.bytes[0] != 0 {
                modeVal.bytes[0] = 0
                _ = parent.writeWithRetry(modeVal)
            }
            self.resetFtstIfAllAuto()
        }
    }
    
    func resetFanControl() -> Bool {
        guard let parent = self.parent else { return false }
        
        // Reset Ftst
        var ftstVal = SMCVal_t("Ftst")
        if parent.read(&ftstVal) == kIOReturnSuccess && ftstVal.dataSize > 0 && ftstVal.bytes[0] != 0 {
            ftstVal.bytes[0] = 0
            _ = parent.writeWithRetry(ftstVal)
        }
        
        // Reset all fans
        guard let count = parent._getValueUnsafe("FNum") else { return true }
        for i in 0..<Int(count) {
            let modeKey = parent.fanModeKey(i)
            var modeVal = SMCVal_t(modeKey)
            if parent.read(&modeVal) == kIOReturnSuccess && modeVal.bytes[0] != 0 {
                modeVal.bytes[0] = 0
                _ = parent.writeWithRetry(modeVal)
            }
        }
        return true
    }
    
    private func unlockFanControl(fanId: Int) -> Bool {
        guard let parent = self.parent else { return false }
        
        let modeKey = parent.fanModeKey(fanId)
        var modeVal = SMCVal_t(modeKey)
        if parent.read(&modeVal) == kIOReturnSuccess && modeVal.bytes[0] == 1 {
            return true
        }
        
        // Try direct write (M5+)
        modeVal.bytes[0] = 1
        if parent.write(modeVal) == kIOReturnSuccess {
            return true
        }
        
        // Use Ftst (M1-M4)
        var ftstVal = SMCVal_t("Ftst")
        if parent.read(&ftstVal) == kIOReturnSuccess && ftstVal.bytes[0] != 1 {
            ftstVal.bytes[0] = 1
            _ = parent.writeWithRetry(ftstVal, maxAttempts: 50, delayMicros: 10_000)
        }
        
        // Write mode with retry (up to 2 seconds total)
        _ = parent.writeWithRetry(modeVal, maxAttempts: 100, delayMicros: 20_000)
        
        // Final check
        if parent.read(&modeVal) == kIOReturnSuccess && modeVal.bytes[0] == 1 {
            return true
        }
        
        return false
    }
    
    private func resetFtstIfAllAuto() {
        guard let parent = self.parent, let count = parent._getValueUnsafe("FNum") else { return }
        for i in 0..<Int(count) {
            var modeVal = SMCVal_t(parent.fanModeKey(i))
            if parent.read(&modeVal) == kIOReturnSuccess && modeVal.bytes[0] != 0 {
                return
            }
        }
        var ftstVal = SMCVal_t("Ftst")
        if parent.read(&ftstVal) == kIOReturnSuccess && ftstVal.bytes[0] != 0 {
            ftstVal.bytes[0] = 0
            _ = parent.writeWithRetry(ftstVal)
        }
    }
}
