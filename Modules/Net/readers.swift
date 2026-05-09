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

private struct NetworkUsageReadConfig: Sendable {
    let readerType: String
    let interfaceID: String
    let vpnMode: Bool
    let vpnConnection: Bool
    let isReachable: Bool
}

private struct NetworkUsageReadResult: Sendable {
    let usage: Network_Usage
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

private func primaryNetworkInterface() -> String {
    if let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString),
       let name = (global as? [String: Any])?["PrimaryInterface"] as? String {
        return name
    }
    return ""
}

private func networkBytesInfo(_ pointer: UnsafeMutablePointer<ifaddrs>) -> (upload: Int64, download: Int64)? {
    guard let addrPtr = pointer.pointee.ifa_addr, addrPtr.pointee.sa_family == UInt8(AF_LINK) else { return nil }
    guard let raw = pointer.pointee.ifa_data else { return nil }
    let data = raw.assumingMemoryBound(to: if_data.self)
    return (upload: Int64(data.pointee.ifi_obytes), download: Int64(data.pointee.ifi_ibytes))
}

private func readInterfaceBandwidth(interfaceID: String) -> Bandwidth {
    var interfaceAddresses: UnsafeMutablePointer<ifaddrs>? = nil
    var totalUpload: Int64 = 0
    var totalDownload: Int64 = 0
    guard getifaddrs(&interfaceAddresses) == 0 else {
        return Bandwidth()
    }
    defer { freeifaddrs(interfaceAddresses) }

    var pointer = interfaceAddresses
    while pointer != nil {
        defer { pointer = pointer?.pointee.ifa_next }
        guard let p = pointer else { break }

        if String(cString: p.pointee.ifa_name) != interfaceID {
            continue
        }

        if let info = networkBytesInfo(p) {
            totalUpload += info.upload
            totalDownload += info.download
        }
    }

    return Bandwidth(upload: totalUpload, download: totalDownload)
}

private func readProcessBandwidth() -> Bandwidth {
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

private actor NetworkUsageWorker {
    private var usage = Network_Usage()
    private var lastDetailsReadTS: Date = .distantPast
    private var isReading = false

    func restore(_ cachedUsage: Network_Usage) {
        self.usage = cachedUsage
        self.usage.bandwidth = Bandwidth()
    }

    func read(config: NetworkUsageReadConfig) async -> NetworkUsageReadResult? {
        guard !self.isReading else { return nil }
        self.isReading = true
        defer { self.isReading = false }

        await self.updateDetails(interfaceID: config.interfaceID)

        let currentBandwidth: Bandwidth = config.readerType == "interface" ?
            readInterfaceBandwidth(interfaceID: config.interfaceID) :
            readProcessBandwidth()

        var updatedUsage = self.usage
        if updatedUsage.bandwidth.upload != 0 {
            updatedUsage.bandwidth.upload = currentBandwidth.upload - self.usage.bandwidth.upload
        }
        if updatedUsage.bandwidth.download != 0 {
            updatedUsage.bandwidth.download = currentBandwidth.download - self.usage.bandwidth.download
        }

        updatedUsage.bandwidth.upload = max(updatedUsage.bandwidth.upload, 0)
        updatedUsage.bandwidth.download = max(updatedUsage.bandwidth.download, 0)
        updatedUsage.total.upload += updatedUsage.bandwidth.upload
        updatedUsage.total.download += updatedUsage.bandwidth.download
        updatedUsage.status = config.isReachable

        if config.vpnConnection && config.vpnMode {
            updatedUsage.bandwidth.upload /= 2
            updatedUsage.bandwidth.download /= 2
        }

        self.usage = updatedUsage
        self.usage.bandwidth = currentBandwidth
        return NetworkUsageReadResult(usage: updatedUsage)
    }

    func refreshReachable(interfaceID: String, publicIPEnabled: Bool) async -> Network_Usage {
        await self.getPublicIP(enabled: publicIPEnabled)
        await self.updateDetails(interfaceID: interfaceID, force: true)
        await self.updateWiFiDetails(interfaceID: interfaceID)
        return self.usage
    }

    func resetUnreachable(interfaceID: String) async -> Network_Usage {
        await self.updateWiFiDetails(interfaceID: interfaceID)
        self.usage.reset()
        return self.usage
    }

    func refreshPublicIP(enabled: Bool) async -> Network_Usage {
        self.usage.raddr.v4 = nil
        self.usage.raddr.v6 = nil
        await self.getPublicIP(enabled: enabled)
        return self.usage
    }

    func resetTotalUsage() -> Network_Usage {
        self.usage.total = Bandwidth()
        return self.usage
    }

    func updateWiFi(interfaceID: String) async -> Network_Usage {
        await self.updateWiFiDetails(interfaceID: interfaceID)
        return self.usage
    }

    private func updateDetails(interfaceID: String, force: Bool = false) async {
        guard interfaceID != "" else { return }
        let now = Date()
        if !force && now.timeIntervalSince(self.lastDetailsReadTS) < 15 { return }

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

        if let prefs = SCPreferencesCreate(nil, "Stats" as CFString, nil),
           let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] {
            for service in services {
                guard let interface = SCNetworkServiceGetInterface(service),
                      let name = SCNetworkInterfaceGetBSDName(interface),
                      name as String == interfaceID,
                      let serviceID = SCNetworkServiceGetServiceID(service) else {
                    continue
                }
                let key = "State:/Network/Service/\(serviceID)/DNS" as CFString
                if let settings = SCDynamicStoreCopyValue(nil, key) as? [String: Any] {
                    res.dns = settings["ServerAddresses"] as? [String] ?? []
                }
            }
        }

        self.usage.interface = res.interface
        self.usage.connectionType = res.connectionType
        self.usage.dns = res.dns

        if self.usage.wifiDetails.ssid != nil && (self.usage.wifiDetails.ssid == "" || self.usage.wifiDetails.ssid == "<redacted>") {
            self.usage.wifiDetails.ssid = nil
        }
        if self.usage.connectionType == .wifi && (self.usage.wifiDetails.ssid == nil || self.usage.wifiDetails.ssid == "") {
            await self.updateWiFiDetails(interfaceID: interfaceID)
        }
        self.lastDetailsReadTS = Date()
    }

    private func updateWiFiDetails(interfaceID: String) async {
        var details = Network_wifi()
        if let interface = CWWiFiClient.shared().interface(withName: interfaceID) {
            details.ssid = interface.ssid()
            if details.ssid == nil || details.ssid == "" {
                autoreleasepool {
                    if let cfg = interface.configuration(),
                       let first = cfg.networkProfiles.firstObject as? CWNetworkProfile,
                       let raw = first.ssid,
                       !raw.isEmpty {
                        details.ssid = raw
                            .replacingOccurrences(of: "’", with: "'")
                            .replacingOccurrences(of: "‘", with: "'")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
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
        self.usage.wifiDetails = details
    }

    private func getPublicIP(enabled: Bool) async {
        guard enabled else { return }

        async let ipv4 = Self.fetchPublicIP()
        async let ipv6 = Self.fetchPublicIP()
        let v4 = await ipv4
        let v6 = await ipv6

        if let ip = v4?.ipv4 ?? v6?.ipv4 {
            self.usage.raddr.v4 = ip
        }
        if let ip = v6?.ipv6 ?? v4?.ipv6 {
            self.usage.raddr.v6 = ip
        }
        if let cc = v4?.country ?? v6?.country {
            self.usage.raddr.countryCode = cc
        }
    }

    private static func fetchPublicIP() async -> PublicIPAddressResponse? {
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
}

private actor NetworkProcessWorker {
    private var isReading = false

    func read() -> [Network_Process]? {
        guard !self.isReading else { return nil }
        self.isReading = true
        defer { self.isReading = false }

        var list: [Network_Process] = []
        guard let output = runNettop() else { return list }
        var firstLine = false
        output.enumerateLines { (line, _) in
            if !firstLine {
                firstLine = true
                return
            }
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
    }
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
    private let reachabilityLock = OSAllocatedUnfairLock(initialState: Reachability())
    private let reachabilityStartedLock = OSAllocatedUnfairLock(initialState: false)
    nonisolated private var reachability: Reachability {
        self.reachabilityLock.withLock { $0 }
    }
    nonisolated private var reachabilityStarted: Bool {
        get { self.reachabilityStartedLock.withLock { $0 } }
        set { self.reachabilityStartedLock.withLock { $0 = newValue } }
    }
    private let worker = NetworkUsageWorker()
    private var wifiEventsStarted = false

    nonisolated private var primaryInterface: String {
        primaryNetworkInterface()
    }

    nonisolated private var interfaceID: String {
        get { Store.shared.string(key: "Network_interface", defaultValue: self.primaryInterface) }
        set { Store.shared.set(key: "Network_interface", value: newValue) }
    }

    nonisolated private var reader: String {
        Store.shared.string(key: "Network_reader", defaultValue: "interface")
    }

    nonisolated private var vpnConnection: Bool {
        if let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any], let scopes = settings["__SCOPED__"] as? [String: Any] {
            return !scopes.filter({ $0.key.contains("tap") || $0.key.contains("tun") || $0.key.contains("ppp") || $0.key.contains("ipsec") || $0.key.contains("ipsec0")}).isEmpty
        }
        return false
    }

    nonisolated private var VPNMode: Bool {
        Store.shared.bool(key: "Network_VPNMode", defaultValue: false)
    }

    private var publicIPState: Bool {
        Store.shared.bool(key: "Network_publicIP", defaultValue: true)
    }

    private let wifiClient = CWWiFiClient.shared()

    @MainActor public override func setup() {
        self.defaultInterval = 5
        if Store.shared.int(key: "Network_updateInterval", defaultValue: 5) < 5 {
            Store.shared.set(key: "Network_updateInterval", value: 5)
        }

        self.reachability.reachable = {
            Task { @MainActor in
                if self.active {
                    _ = await self.worker.refreshReachable(
                        interfaceID: self.interfaceID,
                        publicIPEnabled: self.publicIPState
                    )
                }
            }
        }
        self.reachability.unreachable = {
            Task { @MainActor in
                if self.active {
                    let usage = await self.worker.resetUnreachable(interfaceID: self.interfaceID)
                    self.callback(usage)
                }
            }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(refreshPublicIP), name: .refreshPublicIP, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resetTotalNetworkUsage(_:)), name: .resetTotalNetworkUsage, object: nil)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if self.active {
                _ = await self.worker.refreshReachable(
                    interfaceID: self.interfaceID,
                    publicIPEnabled: self.publicIPState
                )
            }
        }

        if let usage = self.value {
            Task {
                await self.worker.restore(usage)
            }
        }

        self.wifiClient.delegate = self
    }

    public override func start() {
        self.startReachability()
        self.startListeningForWifiEvents()
        super.start()
    }

    public override func pause() {
        super.pause()
        self.stopReachability()
        self.stopListeningForWifiEvents()
    }

    public override func stop() {
        super.stop()
        self.stopReachability()
        self.stopListeningForWifiEvents()
    }

    @MainActor public override func terminate() {
        self.stopReachability()
        self.stopListeningForWifiEvents()
    }

    nonisolated public override func read() {
        let config = NetworkUsageReadConfig(
            readerType: self.reader,
            interfaceID: self.interfaceID,
            vpnMode: self.VPNMode,
            vpnConnection: self.vpnConnection,
            isReachable: self.reachability.isReachable
        )
        let worker = self.worker

        Task { [weak self] in
            guard let self else { return }
            guard let result = await worker.read(config: config) else { return }
            guard self.value != result.usage else { return }
            self.callback(result.usage)
        }
    }

    @objc func refreshPublicIP() {
        Task { @MainActor in
            _ = await self.worker.refreshPublicIP(enabled: self.publicIPState)
        }
    }
    
    @MainActor func refreshPublicIPFromScheduler() async {
        _ = await self.worker.refreshPublicIP(enabled: self.publicIPState)
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
        Task {
            let usage = await self.worker.resetTotalUsage()
            self.save(usage)
        }
    }

    private func startListeningForWifiEvents() {
        guard !self.wifiEventsStarted else { return }
        try? self.wifiClient.startMonitoringEvent(with: .ssidDidChange)
        self.wifiEventsStarted = true
    }

    private func stopListeningForWifiEvents() {
        guard self.wifiEventsStarted else { return }
        try? self.wifiClient.stopMonitoringEvent(with: .ssidDidChange)
        self.wifiEventsStarted = false
    }

    private func startReachability() {
        guard !self.reachabilityStarted else { return }
        self.reachability.start()
        self.reachabilityStarted = true
    }

    private func stopReachability() {
        guard self.reachabilityStarted else { return }
        self.reachability.stop()
        self.reachabilityStarted = false
    }

    public func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in
            _ = await self.worker.updateWiFi(interfaceID: self.interfaceID)
        }
    }
}

public class ProcessReader: Reader<[Network_Process]>, @unchecked Sendable {
    private let worker = NetworkProcessWorker()

    public override func setup() {
        self.defaultInterval = 5
        self.setInterval(Store.shared.int(key: "Net_updateInterval", defaultValue: 5))
    }

    nonisolated public override func read() {
        let worker = self.worker

        Task { [weak self] in
            guard let self, let processes = await worker.read() else { return }
            if let old = self.value, old == processes {
                return
            }

            self.callback(processes)
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
    nonisolated private var ICMPHost: String { Store.shared.string(key: "Net_ICMPHost", defaultValue: "1.1.1.1") }
    nonisolated private var HTTPHost: String { Store.shared.string(key: "Net_HTTPHost", defaultValue: "https://google.com") }
    nonisolated private var connectivityMode: String { Store.shared.string(key: "Net_connectivityMode", defaultValue: "icmp") }

    private struct ConnectivityState: @unchecked Sendable {
        var lastHost: String = ""
        var addr: Data? = nil
        var prepareToken: UUID = UUID()
        var socket: CFSocket? = nil
        var socketSource: CFRunLoopSource? = nil
        var wrapper: Network_Connectivity = Network_Connectivity(status: false)
        var isPinging: Bool = false
        var latency: Double? = nil
        var previousLatency: Double? = nil
        var jitter: Double? = nil
        var start: DispatchTime? = nil
        var timeoutTimer: Timer? = nil
        var isReading: Bool = false
    }
    private let stateLock = OSAllocatedUnfairLock(initialState: ConnectivityState())
    private let timeout: TimeInterval = 5

    private struct ICMPHeader {
        var type: UInt8; var code: UInt8; var checksum: UInt16; var identifier: UInt16; var sequenceNumber: UInt16; var payload: uuid_t
    }

    private struct IPHeader {
        var versionAndHeaderLength: UInt8; var differentiatedServices: UInt8; var totalLength: UInt16; var identification: UInt16; var flagsAndFragmentOffset: UInt16
        var timeToLive: UInt8; var `protocol`: UInt8; var headerChecksum: UInt16; var sourceAddress: (UInt8, UInt8, UInt8, UInt8); var destinationAddress: (UInt8, UInt8, UInt8, UInt8)
    }

    @MainActor public override func setup() {
        self.setInterval(max(5, Store.shared.int(key: "Net_updateICMPInterval", defaultValue: 5)))
        self.prepare()
    }

    public override func stop() {
        super.stop()
        self.closeConn()
    }

    public override func pause() {
        super.pause()
        self.closeConn()
    }

    @MainActor private func prepare() {
        let host = self.ICMPHost
        let token = UUID()
        self.stateLock.withLock { $0.prepareToken = token }

        Task { @MainActor in
            let addr = await self.resolve(host: host)
            let prepareToken = self.stateLock.withLock { $0.prepareToken }
            guard prepareToken == token else { return }
            self.stateLock.withLock { $0.addr = addr }
            self.openConn()
            self.read()
        }
    }

    nonisolated public override func read() {
        let alreadyReading = self.stateLock.withLock { state in
            if state.isReading { return true }
            state.isReading = true
            return false
        }
        guard !alreadyReading else { return }

        let mode = self.connectivityMode
        let host = self.ICMPHost

        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            defer { self.stateLock.withLock { $0.isReading = false } }

            if mode == "http" {
                await self.httpCheck()
            } else {
                let s = self.stateLock.withLock { $0.socket }
                guard !host.isEmpty else {
                    await MainActor.run { if s != nil { self.closeConn() } }
                    return
                }
                await self.icmpCheck()
            }

            let (isPinging, latency, jitter, currentWrapper) = self.stateLock.withLock { ($0.isPinging, $0.latency, $0.jitter, $0.wrapper) }
            var updatedWrapper = currentWrapper
            updatedWrapper.status = !isPinging && latency != nil
            if let l = latency { updatedWrapper.latency = l }
            if let j = jitter { updatedWrapper.jitter = j }

            if let old = self.value, old == updatedWrapper {
                return
            }

            let finalWrapper = updatedWrapper
            self.stateLock.withLock { $0.wrapper = finalWrapper }
            self.callback(updatedWrapper)
        }
    }

    private func httpCheck() {
        let isPinging = self.stateLock.withLock { $0.isPinging }
        guard !isPinging else { return }
        self.stateLock.withLock { $0.isPinging = true }
        let urlString = self.HTTPHost.hasPrefix("http") ? self.HTTPHost : "https://\(self.HTTPHost)"
        guard let url = URL(string: urlString) else { self.stateLock.withLock { $0.isPinging = false }; return }

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: self.timeout)
        Task {
            let startTime = DispatchTime.now()
            _ = try? await URLSession.shared.data(for: request)
            let endTime = DispatchTime.now()
            let elapsed = Double(endTime.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000

            self.updateStats(elapsed: elapsed)
            self.stateLock.withLock { $0.isPinging = false }
        }
    }

    private func icmpCheck() {
        let (s, lastHost, isPinging, addr) = self.stateLock.withLock { ($0.socket, $0.lastHost, $0.isPinging, $0.addr) }
        if s == nil || lastHost != self.ICMPHost {
            self.prepare()
            return
        }

        guard !isPinging && self.active, let socket = s, let address = addr, let data = self.request() else { return }
        self.stateLock.withLock { $0.isPinging = true }

        Task {
            self.stateLock.withLock { $0.start = DispatchTime.now() }
            CFSocketSendData(socket, address as CFData, data as CFData, self.timeout)

            try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
            self.stateLock.withLock { $0.isPinging = false }
        }
    }

    @MainActor func socketCallback(data: Data) {
        guard self.validateResponse(data) else { return }
        let end = DispatchTime.now()
        let start = self.stateLock.withLock { $0.start }
        let elapsed = Double(end.uptimeNanoseconds - (start?.uptimeNanoseconds ?? 0)) / 1_000_000
        self.updateStats(elapsed: elapsed)
        self.stateLock.withLock {
            $0.isPinging = false
            $0.timeoutTimer?.invalidate()
        }
    }

    private func updateStats(elapsed: Double) {
        self.stateLock.withLock { state in
            state.latency = elapsed
            if let prev = state.previousLatency {
                let d = abs(elapsed - prev)
                state.jitter = (state.jitter ?? d) + (d - (state.jitter ?? d)) / 16.0
            }
            state.previousLatency = elapsed
        }
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
        self.closeConn()
        let addr = self.stateLock.withLock { $0.addr }
        guard addr != nil else { return }

        let info = ConnectivityReaderWrapper(self)
        var context = CFSocketContext(version: 0, info: Unmanaged.passRetained(info).toOpaque(), retain: nil, release: { info in
            guard let info = info else { return }
            Unmanaged<ConnectivityReaderWrapper>.fromOpaque(info).release()
        }, copyDescription: nil)
        
        let socket = CFSocketCreate(kCFAllocatorDefault, AF_INET, SOCK_DGRAM, IPPROTO_ICMP, CFSocketCallBackType.dataCallBack.rawValue, { _, _, _, data, info in
            guard let info = info, let data = data else { return }
            let wrapper = Unmanaged<ConnectivityReaderWrapper>.fromOpaque(info).takeUnretainedValue()
            let cfdata = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue()
            wrapper.reader?.socketCallback(data: cfdata as Data)
        }, &context)
        
        if let s = socket {
            let source = CFSocketCreateRunLoopSource(nil, s, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.stateLock.withLock {
                $0.socket = s
                $0.socketSource = source
            }
        }
    }

    private func closeConn() {
        self.stateLock.withLock { state in
            if let s = state.socketSource { CFRunLoopSourceInvalidate(s) }
            if let s = state.socket { CFSocketInvalidate(s) }
            state.timeoutTimer?.invalidate()
            
            state.socketSource = nil
            state.socket = nil
            state.timeoutTimer = nil
        }
    }

    private func resolve(host: String) async -> Data? {
        self.stateLock.withLock { $0.lastHost = host }
        return await Task.detached(priority: .background) {
            let hostRef = CFHostCreateWithName(nil, host as CFString).takeRetainedValue()
            if CFHostStartInfoResolution(hostRef, .addresses, nil), let addrs = CFHostGetAddressing(hostRef, nil)?.takeUnretainedValue() as? [Data] {
                return addrs.first { $0.count >= MemoryLayout<sockaddr>.size && $0.withUnsafeBytes({ $0.load(as: sockaddr.self).sa_family == UInt8(AF_INET) }) }
            }
            return nil
        }.value
    }
}
