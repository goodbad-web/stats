//
//  readers.swift
//  Net
//
//  Created by Serhiy Mytrovtsiy on 24/05/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
@preconcurrency import Kit
import SystemConfiguration
import CoreWLAN
import os

struct ipResponse: Decodable {
    var ip: String
    var country: String
    var cc: String
}

private struct PublicIPAddressResponse: Decodable, Sendable {
    let ipv4: String?
    let ipv6: String?
    let country: String?
}

private func runNettop() -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
    task.arguments = ["-P", "-L", "1", "-n", "-k", "time,interface,state,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch"]
    task.environment = ["NSUnbufferedIO": "YES", "LC_ALL": "en_US.UTF-8"]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    task.standardOutput = outputPipe
    task.standardError = errorPipe

    do {
        try task.run()
    } catch {
        return nil
    }

    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: outputData, encoding: .utf8)
}

// swiftlint:disable control_statement
extension CWPHYMode: @retroactive CustomStringConvertible {
    public var description: String {
        switch(self) {
        case .mode11a:  return "802.11a"
        case .mode11ac: return "802.11ac"
        case .mode11b:  return "802.11b"
        case .mode11g:  return "802.11g"
        case .mode11n:  return "802.11n"
        case .mode11ax: return "802.11ax"
        case .mode11be: return "802.11be"
        case .modeNone: return "none"
        @unknown default: return "unknown"
        }
    }
}

extension CWInterfaceMode: @retroactive CustomStringConvertible {
    public var description: String {
        switch(self) {
        case .hostAP:       return "AP"
        case .IBSS:         return "Adhoc"
        case .station:      return "Station"
        case .none:         return "none"
        @unknown default:   return "unknown"
        }
    }
}

extension CWSecurity: @retroactive CustomStringConvertible {
    public var description: String {
        switch(self) {
        case .none:               return "none"
        case .WEP:                return "WEP"
        case .wpaPersonal:        return "WPA Personal"
        case .wpaPersonalMixed:   return "WPA Personal Mixed"
        case .wpa2Personal:       return "WPA2 Personal"
        case .personal:           return "Personal"
        case .dynamicWEP:         return "Dynamic WEP"
        case .wpaEnterprise:      return "WPA Enterprise"
        case .wpaEnterpriseMixed: return "WPA Enterprise Mixed"
        case .wpa2Enterprise:     return "WPA2 Enterprise"
        case .enterprise:         return "Enterprise"
        case .unknown:            return "unknown"
        case .wpa3Personal:       return "WPA3 Personal"
        case .wpa3Enterprise:     return "WPA3 Enterprise"
        case .wpa3Transition:     return "WPA3 Transition"
        default:                  return "unknown"
        }
    }
}

extension CWChannelBand: @retroactive CustomStringConvertible {
    public var description: String {
        switch(self) {
        case .band2GHz:     return "2 GHz"
        case .band5GHz:     return "5 GHz"
        case .band6GHz:     return "6 GHz"
        case .bandUnknown:  return "unknown"
        @unknown default:   return "unknown"
        }
    }
}

extension CWChannelWidth: @retroactive CustomStringConvertible {
    public var description: String {
        switch(self) {
        case .width20MHz:   return "20 MHz"
        case .width40MHz:   return "40 MHz"
        case .width80MHz:   return "80 MHz"
        case .width160MHz:  return "160 MHz"
        case .widthUnknown: return "unknown"
        @unknown default:   return "unknown"
        }
    }
}
// swiftlint:enable control_statement

extension CWChannel {
    override public var description: String {
        return "\(channelNumber) (\(channelBand), \(channelWidth))"
    }
}

internal class UsageReader: Reader<Network_Usage>, CWEventDelegate, @unchecked Sendable {
    private nonisolated(unsafe) var reachability: Reachability = Reachability(start: true)
    private nonisolated(unsafe) var _usage: Network_Usage = Network_Usage()
    public var usage: Network_Usage {
        get { self._usage }
        set { self._usage = newValue }
    }
    
    private var primaryInterface: String {
        if let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString), let name = (global as? [String: Any])?["PrimaryInterface"] as? String {
            return name
        }
        return ""
    }
    
    private var interfaceID: String {
        get { Store.shared.string(key: "Network_interface", defaultValue: self.primaryInterface) }
        set { Store.shared.set(key: "Network_interface", value: newValue) }
    }
    
    private var reader: String {
        Store.shared.string(key: "Network_reader", defaultValue: "interface")
    }
    
    private var vpnConnection: Bool {
        if let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any], let scopes = settings["__SCOPED__"] as? [String: Any] {
            return !scopes.filter({ $0.key.contains("tap") || $0.key.contains("tun") || $0.key.contains("ppp") || $0.key.contains("ipsec") || $0.key.contains("ipsec0")}).isEmpty
        }
        return false
    }
    
    private var VPNMode: Bool {
        Store.shared.bool(key: "Network_VPNMode", defaultValue: false)
    }
    private var publicIPState: Bool {
        Store.shared.bool(key: "Network_publicIP", defaultValue: true)
    }
    
    private let wifiClient = CWWiFiClient.shared()
    private nonisolated(unsafe) var lastDetailsReadTS: Date = .distantPast
    
    @MainActor public override func setup() {
        self.reachability.reachable = {
            Task { @MainActor in
                if self.active {
                    await self.getPublicIP()
                    await self.updateDetails()
                    await self.updateWiFiDetails()
                }
            }
        }
        self.reachability.unreachable = {
            Task { @MainActor in
                if self.active {
                    await self.updateWiFiDetails()
                    self.usage.reset()
                    self.callback(self.usage)
                }
            }
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(refreshPublicIP), name: .refreshPublicIP, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resetTotalNetworkUsage(_:)), name: .resetTotalNetworkUsage, object: nil)
        
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if self.active {
                await self.getPublicIP()
                await self.updateDetails()
            }
        }
        
        if let usage = self.value {
            self.usage = usage
            self.usage.bandwidth = Bandwidth()
        }
        
        self.wifiClient.delegate = self
        self.startListeningForWifiEvents()
    }
    
    @MainActor public override func terminate() {
        self.reachability.stop()
        self.stopListeningForWifiEvents()
    }
    
    private let readLock = OSAllocatedUnfairLock(initialState: false)
    
    nonisolated public override func read() {
        let isReading = self.readLock.withLock { $0 }
        guard !isReading else { return }
        self.readLock.withLock { $0 = true }
        
        Task { @MainActor in
            await self.updateDetails()
            
            let readerType = self.reader
            let interfaceID = self.interfaceID
            let currentUsage = self.usage
            
            let currentBandwidth = await Task.detached(priority: .background) {
                if readerType == "interface" {
                    return self.readInterfaceBandwidth(interfaceID: interfaceID)
                } else {
                    return self.readProcessBandwidth()
                }
            }.value
            
            if self.usage.bandwidth.upload != 0 {
                self.usage.bandwidth.upload = currentBandwidth.upload - currentUsage.bandwidth.upload
            }
            if self.usage.bandwidth.download != 0 {
                self.usage.bandwidth.download = currentBandwidth.download - currentUsage.bandwidth.download
            }
            
            self.usage.bandwidth.upload = max(self.usage.bandwidth.upload, 0)
            self.usage.bandwidth.download = max(self.usage.bandwidth.download, 0)
            
            self.usage.total.upload += self.usage.bandwidth.upload
            self.usage.total.download += self.usage.bandwidth.download
            self.usage.status = self.reachability.isReachable
            
            if self.vpnConnection && self.VPNMode {
                self.usage.bandwidth.upload /= 2
                self.usage.bandwidth.download /= 2
            }
            
            if let old = self.value, old == self.usage {
                self.readLock.withLock { $0 = false }
                return
            }
            
            self.callback(self.usage)
            self.readLock.withLock { $0 = false }
            
            self.usage.bandwidth.upload = currentBandwidth.upload
            self.usage.bandwidth.download = currentBandwidth.download
        }
    }
    
    nonisolated private func readInterfaceBandwidth(interfaceID: String) -> Bandwidth {
        var interfaceAddresses: UnsafeMutablePointer<ifaddrs>? = nil
        var totalUpload: Int64 = 0
        var totalDownload: Int64 = 0
        guard getifaddrs(&interfaceAddresses) == 0 else {
            return Bandwidth()
        }
        
        var pointer = interfaceAddresses
        while pointer != nil {
            defer { pointer = pointer?.pointee.ifa_next }
            guard let p = pointer else { break }
            
            if String(cString: p.pointee.ifa_name) != interfaceID {
                continue
            }
            
            if let info = self.getBytesInfo(p) {
                totalUpload += info.upload
                totalDownload += info.download
            }
        }
        freeifaddrs(interfaceAddresses)
        
        return Bandwidth(upload: totalUpload, download: totalDownload)
    }
    
    nonisolated private func readProcessBandwidth() -> Bandwidth {
        guard let output = runNettop() else { return Bandwidth() }

        var totalUpload: Int64 = 0
        var totalDownload: Int64 = 0
        var firstLine = false
        output.enumerateLines { (line, _) in
            if !firstLine {
                firstLine = true
                return
            }
            let parsedLine = line.split(separator: ",")
            guard parsedLine.count >= 3 else { return }
            if let download = Int64(parsedLine[1]) { totalDownload += download }
            if let upload = Int64(parsedLine[2]) { totalUpload += upload }
        }
        return Bandwidth(upload: totalUpload, download: totalDownload)
    }

    @MainActor private func updateDetails() async {
        guard self.interfaceID != "" else { return }
        let now = Date()
        if now.timeIntervalSince(self.lastDetailsReadTS) < 15 { return }
        
        let interfaceID = self.interfaceID
        let details = await Task.detached(priority: .background) {
            var res = (interface: nil as Network_interface?, connectionType: .other as Network_t, dns: [] as [String])
            
            let interfaces = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
            for interface in interfaces {
                guard let bsName = SCNetworkInterfaceGetBSDName(interface),
                      let type = SCNetworkInterfaceGetInterfaceType(interface),
                      let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface),
                      let address = SCNetworkInterfaceGetHardwareAddressString(interface) else {
                    continue
                }
                
                let bsdName = bsName as String
                if bsdName == interfaceID {
                    res.interface = Network_interface(displayName: displayName as String, BSDName: bsdName, address: address as String)
                    switch type {
                    case kSCNetworkInterfaceTypeEthernet: res.connectionType = .ethernet
                    case kSCNetworkInterfaceTypeIEEE80211, kSCNetworkInterfaceTypeWWAN: res.connectionType = .wifi
                    case kSCNetworkInterfaceTypeBluetooth: res.connectionType = .bluetooth
                    default: res.connectionType = .other
                    }
                }
            }
            
            if let prefs = SCPreferencesCreate(nil, "Stats" as CFString, nil), let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] {
                for service in services {
                    if let interface = SCNetworkServiceGetInterface(service), let name = SCNetworkInterfaceGetBSDName(interface), name as String == interfaceID,
                       let serviceID = SCNetworkServiceGetServiceID(service) {
                        let key = "State:/Network/Service/\(serviceID)/DNS" as CFString
                        if let settings = SCDynamicStoreCopyValue(nil, key) as? [String: Any] {
                            res.dns = settings["ServerAddresses"] as? [String] ?? []
                        }
                    }
                }
            }
            return res
        }.value
        
        self.usage.interface = details.interface
        self.usage.connectionType = details.connectionType
        self.usage.dns = details.dns
        
        if self.usage.wifiDetails.ssid != nil && (self.usage.wifiDetails.ssid == "" || self.usage.wifiDetails.ssid == "<redacted>") {
            self.usage.wifiDetails.ssid = nil
        }
        if self.usage.connectionType == .wifi && (self.usage.wifiDetails.ssid == nil || self.usage.wifiDetails.ssid == "") {
            await self.updateWiFiDetails()
        }
        self.lastDetailsReadTS = Date()
    }
    
    @MainActor private func updateWiFiDetails() async {
        let interfaceID = self.interfaceID
        let wifiDetails = await Task.detached(priority: .background) {
            var details = Network_wifi()
            if let interface = CWWiFiClient.shared().interface(withName: interfaceID) {
                details.ssid = interface.ssid()
                if details.ssid == nil || details.ssid == "" {
                    if let cfg = interface.configuration(), let set = (cfg.value(forKey: "networkProfiles") as? NSOrderedSet),
                       let first = set.firstObject as? CWNetworkProfile, let raw = first.ssid, !raw.isEmpty {
                        details.ssid = raw.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                details.bssid = interface.bssid()
                details.countryCode = interface.countryCode()
                details.RSSI = interface.rssiValue()
                details.noise = interface.noiseMeasurement()
                details.standard = interface.activePHYMode().description
                details.mode = interface.interfaceMode().description
                details.security = interface.security().description
                if let ch = interface.wlanChannel() {
                    details.channel = ch.description
                    details.channelBand = ch.channelBand.description
                    details.channelWidth = ch.channelWidth.description
                    details.channelNumber = ch.channelNumber.description
                }
            }
            return details
        }.value
        self.usage.wifiDetails = wifiDetails
    }
    
    @MainActor private func getPublicIP() async {
        guard self.publicIPState else { return }
        
        let result = await Task.detached(priority: .background) {
            async let ipv4 = Self.fetchPublicIP()
            async let ipv6 = Self.fetchPublicIP()
            let v4 = await ipv4
            let v6 = await ipv6
            return (ipv4: v4?.ipv4 ?? v6?.ipv4, ipv6: v6?.ipv6 ?? v4?.ipv6, country: v4?.country ?? v6?.country)
        }.value
        
        if let ip = result.ipv4 {
            self.usage.raddr.v4 = ip
        }
        if let ip = result.ipv6 {
            self.usage.raddr.v6 = ip
        }
        if let cc = result.country {
            self.usage.raddr.countryCode = cc
        }
    }
    
    nonisolated private static func fetchPublicIP() async -> PublicIPAddressResponse? {
        guard let url = URL(string: "https://api.mac-stats.com/ip") else { return nil }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Stats", forHTTPHeaderField: "User-Agent")

        let configuration: URLSessionConfiguration = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            return configuration
        }()

        do {
            let session = URLSession(configuration: configuration)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try? JSONDecoder().decode(PublicIPAddressResponse.self, from: data)
        } catch {
            return nil
        }
    }
    
    nonisolated private func getBytesInfo(_ pointer: UnsafeMutablePointer<ifaddrs>) -> (upload: Int64, download: Int64)? {
        guard let addrPtr = pointer.pointee.ifa_addr, addrPtr.pointee.sa_family == UInt8(AF_LINK) else { return nil }
        guard let raw = pointer.pointee.ifa_data else { return nil }
        let data = raw.assumingMemoryBound(to: if_data.self)
        return (upload: Int64(data.pointee.ifi_obytes), download: Int64(data.pointee.ifi_ibytes))
    }
    
    @objc func refreshPublicIP() {
        Task { @MainActor in
            self.usage.raddr.v4 = nil
            self.usage.raddr.v6 = nil
            await self.getPublicIP()
        }
    }
    
    @MainActor func refreshPublicIPFromScheduler() async {
        self.usage.raddr.v4 = nil
        self.usage.raddr.v6 = nil
        await self.getPublicIP()
    }
    
    @objc func resetTotalNetworkUsage(_ notification: Notification) {
        if notification.userInfo?["skipReader"] as? Bool == true {
            return
        }
        
        Task { @MainActor in
            self.resetTotalNetworkUsageFromScheduler()
        }
    }
    
    @MainActor func resetTotalNetworkUsageFromScheduler() {
        self.usage.total = Bandwidth()
        self.save(self.usage)
    }
    
    private func startListeningForWifiEvents() {
        try? self.wifiClient.startMonitoringEvent(with: .ssidDidChange)
    }
    
    private func stopListeningForWifiEvents() {
        try? self.wifiClient.stopMonitoringEvent(with: .ssidDidChange)
    }
    
    public func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in await self.updateWiFiDetails() }
    }
}

public class ProcessReader: Reader<[Network_Process]>, @unchecked Sendable {
    public override func setup() {
        self.defaultInterval = 5
        self.setInterval(Store.shared.int(key: "Net_updateInterval", defaultValue: 5))
    }
    
    private let processLock = OSAllocatedUnfairLock(initialState: false)
    
    nonisolated public override func read() {
        let isReading = self.processLock.withLock { $0 }
        guard !isReading else { return }
        self.processLock.withLock { $0 = true }
        
        Task { @MainActor in
            let processes = await Task.detached(priority: .background) {
                var list: [Network_Process] = []
                guard let output = runNettop() else { return list }
                var firstLine = false
                output.enumerateLines { (line, _) in
                    if !firstLine { firstLine = true; return }
                    let parsedLine = line.split(separator: ",")
                    guard parsedLine.count >= 3 else { return }
                    let name = String(parsedLine[0])
                    let download = Int64(parsedLine[1]) ?? 0
                    let upload = Int64(parsedLine[2]) ?? 0
                    if let index = list.firstIndex(where: { $0.name == name }) {
                        list[index].download += Int(download)
                        list[index].upload += Int(upload)
                    } else {
                        list.append(Network_Process(name: name, download: Int(download), upload: Int(upload)))
                    }
                }
                return list.sorted { ($0.download + $0.upload) > ($1.download + $1.upload) }
            }.value
            if let old = self.value, old == processes {
                self.processLock.withLock { $0 = false }
                return
            }
            
            self.callback(processes)
            self.processLock.withLock { $0 = false }
        }
    }
}

internal class ConnectivityReaderWrapper {
    weak var reader: ConnectivityReader?
    init(_ reader: ConnectivityReader) { self.reader = reader }
}

internal class ConnectivityReader: Reader<Network_Connectivity>, @unchecked Sendable {
    private let identifier = UInt16.random(in: 0..<UInt16.max)
    private var fingerprint: UUID = UUID()
    private var ICMPHost: String { Store.shared.string(key: "Net_ICMPHost", defaultValue: "1.1.1.1") }
    private var HTTPHost: String { Store.shared.string(key: "Net_HTTPHost", defaultValue: "https://google.com") }
    private var connectivityMode: String { Store.shared.string(key: "Net_connectivityMode", defaultValue: "icmp") }
    
    private nonisolated(unsafe) var lastHost: String = ""
    private nonisolated(unsafe) var addr: Data? = nil
    private let timeout: TimeInterval = 5
    
    private nonisolated(unsafe) var socket: CFSocket?
    private nonisolated(unsafe) var socketSource: CFRunLoopSource?
    private nonisolated(unsafe) var wrapper: Network_Connectivity = Network_Connectivity(status: false)
    
    private nonisolated(unsafe) var isPinging: Bool = false
    private nonisolated(unsafe) var latency: Double? = nil
    private nonisolated(unsafe) var previousLatency: Double? = nil
    private nonisolated(unsafe) var jitter: Double? = nil
    private nonisolated(unsafe) var start: DispatchTime? = nil
    private nonisolated(unsafe) var timeoutTimer: Timer?
    
    private struct ICMPHeader {
        var type: UInt8; var code: UInt8; var checksum: UInt16; var identifier: UInt16; var sequenceNumber: UInt16; var payload: uuid_t
    }
    
    private struct IPHeader {
        var versionAndHeaderLength: UInt8; var differentiatedServices: UInt8; var totalLength: UInt16; var identification: UInt16; var flagsAndFragmentOffset: UInt16
        var timeToLive: UInt8; var `protocol`: UInt8; var headerChecksum: UInt16; var sourceAddress: (UInt8, UInt8, UInt8, UInt8); var destinationAddress: (UInt8, UInt8, UInt8, UInt8)
    }
    
    @MainActor public override func setup() {
        self.setInterval(Store.shared.int(key: "Net_updateICMPInterval", defaultValue: 1))
        self.prepare()
    }
    
    public override func stop() {
        self.closeConn()
    }
    
    @MainActor private func prepare() {
        let host = self.ICMPHost
        Task {
            let addr = await self.resolve(host: host)
            self.addr = addr
            self.openConn()
            self.read()
        }
    }
    
    private let connLock = OSAllocatedUnfairLock(initialState: false)
    
    nonisolated public override func read() {
        let isReading = self.connLock.withLock { $0 }
        guard !isReading else { return }
        self.connLock.withLock { $0 = true }
        
        Task { @MainActor in
            if self.connectivityMode == "http" {
                self.httpCheck()
            } else {
                guard !self.ICMPHost.isEmpty else {
                    if self.socket != nil { self.closeConn() }
                    return
                }
                self.icmpCheck()
            }
            
            self.wrapper.status = !self.isPinging && self.latency != nil
            if let l = self.latency { self.wrapper.latency = l }
            if let j = self.jitter { self.wrapper.jitter = j }
            if let old = self.value, old == self.wrapper {
                self.connLock.withLock { $0 = false }
                return
            }
            
            self.callback(self.wrapper)
            self.connLock.withLock { $0 = false }
        }
    }
    
    @MainActor private func httpCheck() {
        guard !self.isPinging else { return }
        self.isPinging = true
        let urlString = self.HTTPHost.hasPrefix("http") ? self.HTTPHost : "https://\(self.HTTPHost)"
        guard let url = URL(string: urlString) else { self.isPinging = false; return }
        
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: self.timeout)
        Task {
            let startTime = DispatchTime.now()
            _ = try? await URLSession.shared.data(for: request)
            let endTime = DispatchTime.now()
            let elapsed = Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000
            
            self.updateStats(elapsed: elapsed)
            self.isPinging = false
        }
    }
    
    @MainActor private func icmpCheck() {
        if self.socket == nil { self.prepare() }
        if self.lastHost != self.ICMPHost { self.prepare() }
        
        guard !self.isPinging && self.active, let socket = self.socket, let addr = self.addr, let data = self.request() else { return }
        self.isPinging = true
        
        Task {
            self.start = DispatchTime.now()
            CFSocketSendData(socket, addr as CFData, data as CFData, self.timeout)
            
            try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
            self.isPinging = false
        }
    }
    
    @MainActor func socketCallback(data: Data) {
        guard self.validateResponse(data) else { return }
        let end = DispatchTime.now()
        let elapsed = Double(end.uptimeNanoseconds - (self.start?.uptimeNanoseconds ?? 0)) / 1_000_000
        self.updateStats(elapsed: elapsed)
        self.isPinging = false
        self.timeoutTimer?.invalidate()
    }
    
    @MainActor private func updateStats(elapsed: Double) {
        self.latency = elapsed
        if let prev = self.previousLatency {
            let d = abs(elapsed - prev)
            self.jitter = (self.jitter ?? d) + (d - (self.jitter ?? d)) / 16.0
        }
        self.previousLatency = elapsed
    }
    
    private func validateResponse(_ data: Data) -> Bool {
        guard data.count >= MemoryLayout<ICMPHeader>.size + MemoryLayout<IPHeader>.size else { return false }
        let headerOffset = 20 // simplified
        let icmpHeader = data.withUnsafeBytes { $0.load(fromByteOffset: headerOffset, as: ICMPHeader.self) }
        return UUID(uuid: icmpHeader.payload) == self.fingerprint
    }
    
    private func request() -> Data? {
        var header = ICMPHeader(type: 8, code: 0, checksum: 0, identifier: identifier.bigEndian, sequenceNumber: 0, payload: fingerprint.uuid)
        return Data(bytes: &header, count: MemoryLayout<ICMPHeader>.size)
    }
    
    private func openConn() {
        let info = ConnectivityReaderWrapper(self)
        var context = CFSocketContext(version: 0, info: Unmanaged.passRetained(info).toOpaque(), retain: nil, release: { info in
            guard let info = info else { return }
            Unmanaged<ConnectivityReaderWrapper>.fromOpaque(info).release()
        }, copyDescription: nil)
        self.socket = CFSocketCreate(kCFAllocatorDefault, AF_INET, SOCK_DGRAM, IPPROTO_ICMP, CFSocketCallBackType.dataCallBack.rawValue, { _, _, _, data, info in
            guard let info = info, let data = data else { return }
            let wrapper = Unmanaged<ConnectivityReaderWrapper>.fromOpaque(info).takeUnretainedValue()
            let cfdata = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue()
            wrapper.reader?.socketCallback(data: cfdata as Data)
        }, &context)
        if let s = self.socket {
            self.socketSource = CFSocketCreateRunLoopSource(nil, s, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), self.socketSource, .commonModes)
        }
    }
    
    private func closeConn() {
        if let s = self.socketSource { CFRunLoopSourceInvalidate(s); self.socketSource = nil }
        if let s = self.socket { CFSocketInvalidate(s); self.socket = nil }
        self.timeoutTimer?.invalidate()
    }
    
    private func resolve(host: String) async -> Data? {
        self.lastHost = host
        return await Task.detached(priority: .background) {
            let hostRef = CFHostCreateWithName(nil, host as CFString).takeRetainedValue()
            if CFHostStartInfoResolution(hostRef, .addresses, nil), let addrs = CFHostGetAddressing(hostRef, nil)?.takeUnretainedValue() as? [Data] {
                return addrs.first { $0.count >= MemoryLayout<sockaddr>.size && $0.withUnsafeBytes({ $0.load(as: sockaddr.self).sa_family == UInt8(AF_INET) }) }
            }
            return nil
        }.value
    }
}
