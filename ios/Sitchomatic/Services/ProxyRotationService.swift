import Foundation
import Network
import Observation

nonisolated enum ConnectionMode: String, CaseIterable, Sendable {
    case direct = "Direct"
    case dns = "DNS"
    case proxy = "Proxy"
    case openvpn = "OpenVPN"
    case wireguard = "WireGuard"
    case nodeMaven = "NodeMaven"
    case hybrid = "Hybrid"

    var icon: String {
        switch self {
        case .direct: "bolt.horizontal.fill"
        case .dns: "lock.shield.fill"
        case .proxy: "network"
        case .openvpn: "shield.lefthalf.filled"
        case .wireguard: "lock.trianglebadge.exclamationmark.fill"
        case .nodeMaven: "cloud.fill"
        case .hybrid: "rectangle.3.group.fill"
        }
    }

    var label: String {
        switch self {
        case .direct: "Direct (No Proxy)"
        case .dns: "DNS-over-HTTPS"
        case .proxy: "SOCKS5 Proxy"
        case .openvpn: "OpenVPN"
        case .wireguard: "WireGuard"
        case .nodeMaven: "NodeMaven"
        case .hybrid: "Hybrid (1 per method)"
        }
    }
}

nonisolated enum NetworkRegion: String, CaseIterable, Codable, Sendable {
    case usa = "USA"
    case au = "AU"

    var icon: String {
        switch self {
        case .usa: "flag.fill"
        case .au: "globe.asia.australia.fill"
        }
    }

    var label: String {
        switch self {
        case .usa: "United States"
        case .au: "Australia"
        }
    }
}

nonisolated struct ProfileStorageCounts: Sendable {
    let wireGuard: Int
    let openVPN: Int
}

@Observable
@MainActor
class ProxyRotationService {
    static let shared = ProxyRotationService()

    nonisolated enum ProxyTarget: String, Sendable {
        case joe
        case ignition
        case ppsr
    }

    var savedProxies: [ProxyConfig] = []
    var ignitionProxies: [ProxyConfig] = []
    var ppsrProxies: [ProxyConfig] = []

    var joeVPNConfigs: [OpenVPNConfig] = []
    var ignitionVPNConfigs: [OpenVPNConfig] = []
    var ppsrVPNConfigs: [OpenVPNConfig] = []

    var joeWGConfigs: [WireGuardConfig] = []
    var ignitionWGConfigs: [WireGuardConfig] = []
    var ppsrWGConfigs: [WireGuardConfig] = []
    var currentProxyIndex: Int = 0
    var currentIgnitionProxyIndex: Int = 0
    var currentPPSRProxyIndex: Int = 0

    var currentJoeWGIndex: Int = 0
    var currentIgnitionWGIndex: Int = 0
    var currentPPSRWGIndex: Int = 0

    var currentJoeOVPNIndex: Int = 0
    var currentIgnitionOVPNIndex: Int = 0
    var currentPPSROVPNIndex: Int = 0

    var rotateAfterDisabled: Bool = true
    var lastImportReport: ImportReport?

    var joeConnectionMode: ConnectionMode = .wireguard
    var ignitionConnectionMode: ConnectionMode = .wireguard
    var ppsrConnectionMode: ConnectionMode = .wireguard

    var unifiedConnectionMode: ConnectionMode = .wireguard {
        didSet { syncUnifiedConnectionMode() }
    }
    var networkRegion: NetworkRegion = .au {
        didSet { persistNetworkRegion() }
    }

    struct ImportReport {
        let added: Int
        let duplicates: Int
        let failed: [String]
        var total: Int { added + duplicates + failed.count }
    }

    private let connectionModePersistKey = "connection_modes_v1"
    private let networkRegionPersistKey = "network_region_v1"
    private let unifiedModePersistKey = "unified_connection_mode_v1"

    private var activeProfilePrefix: String {
        let profile = UserDefaults.standard.string(forKey: "nordvpn_key_profile_v1") ?? "Nick"
        return profile.lowercased()
    }

    private func profilePrefix(for profile: NordKeyProfile) -> String {
        profile.rawValue.lowercased()
    }

    private func vpnPersistKey(for target: ProxyTarget, profile: NordKeyProfile) -> String {
        "\(profilePrefix(for: profile))_openvpn_configs_\(target.rawValue)_v1"
    }

    private func wgPersistKey(for target: ProxyTarget, profile: NordKeyProfile) -> String {
        "\(profilePrefix(for: profile))_wireguard_configs_\(target.rawValue)_v1"
    }

    private var persistKey: String { "\(activeProfilePrefix)_socks5_proxies_joe_v2" }
    private var ignitionPersistKey: String { "\(activeProfilePrefix)_socks5_proxies_ignition_v1" }
    private var ppsrPersistKey: String { "\(activeProfilePrefix)_socks5_proxies_ppsr_v1" }

    private var joeVPNPersistKey: String { "\(activeProfilePrefix)_openvpn_configs_joe_v1" }
    private var ignitionVPNPersistKey: String { "\(activeProfilePrefix)_openvpn_configs_ignition_v1" }
    private var ppsrVPNPersistKey: String { "\(activeProfilePrefix)_openvpn_configs_ppsr_v1" }

    private var joeWGPersistKey: String { "\(activeProfilePrefix)_wireguard_configs_joe_v1" }
    private var ignitionWGPersistKey: String { "\(activeProfilePrefix)_wireguard_configs_ignition_v1" }
    private var ppsrWGPersistKey: String { "\(activeProfilePrefix)_wireguard_configs_ppsr_v1" }

    private let logger = DebugLogger.shared

    init() {
        migrateUnprefixedKeys()
        loadAllProfileData()
        loadConnectionModes()
        loadNetworkRegion()
        loadUnifiedMode()
    }

    func reloadForActiveProfile() {
        loadAllProfileData()
        resetRotationIndexes()
        logger.log("ProxyRotation: reloaded for profile '\(activeProfilePrefix)' — joe:\(savedProxies.count) ign:\(ignitionProxies.count) ppsr:\(ppsrProxies.count) wg:\(joeWGConfigs.count+ignitionWGConfigs.count+ppsrWGConfigs.count) vpn:\(joeVPNConfigs.count+ignitionVPNConfigs.count+ppsrVPNConfigs.count)", category: .proxy, level: .success)
    }

    private func loadAllProfileData() {
        loadProxies()
        loadIgnitionProxies()
        loadPPSRProxies()
        loadVPNConfigs()
        loadWGConfigs()
        logger.log("ProxyRotation: loaded profile '\(activeProfilePrefix)' — joe:\(savedProxies.count) ign:\(ignitionProxies.count) ppsr:\(ppsrProxies.count) vpn:\(joeVPNConfigs.count+ignitionVPNConfigs.count+ppsrVPNConfigs.count) wg:\(joeWGConfigs.count+ignitionWGConfigs.count+ppsrWGConfigs.count) region:\(networkRegion.rawValue)", category: .proxy, level: .info)
    }

    private func migrateUnprefixedKeys() {
        let oldSocks5Joe = "saved_socks5_proxies_v2"
        let oldSocks5Ign = "saved_socks5_proxies_ignition_v1"
        let oldSocks5Ppsr = "saved_socks5_proxies_ppsr_v1"
        let oldVPNJoe = "openvpn_configs_joe_v1"
        let oldVPNIgn = "openvpn_configs_ignition_v1"
        let oldVPNPpsr = "openvpn_configs_ppsr_v1"
        let oldWGJoe = "wireguard_configs_joe_v1"
        let oldWGIgn = "wireguard_configs_ignition_v1"
        let oldWGPpsr = "wireguard_configs_ppsr_v1"

        let migrationDone = UserDefaults.standard.bool(forKey: "profile_storage_migration_v1")
        guard !migrationDone else { return }

        let pairs: [(String, String)] = [
            (oldSocks5Joe, "nick_socks5_proxies_joe_v2"),
            (oldSocks5Ign, "nick_socks5_proxies_ignition_v1"),
            (oldSocks5Ppsr, "nick_socks5_proxies_ppsr_v1"),
            (oldVPNJoe, "nick_openvpn_configs_joe_v1"),
            (oldVPNIgn, "nick_openvpn_configs_ignition_v1"),
            (oldVPNPpsr, "nick_openvpn_configs_ppsr_v1"),
            (oldWGJoe, "nick_wireguard_configs_joe_v1"),
            (oldWGIgn, "nick_wireguard_configs_ignition_v1"),
            (oldWGPpsr, "nick_wireguard_configs_ppsr_v1"),
        ]

        for (oldKey, newKey) in pairs {
            if let data = UserDefaults.standard.data(forKey: oldKey) {
                UserDefaults.standard.set(data, forKey: newKey)
                UserDefaults.standard.removeObject(forKey: oldKey)
            }
        }

        UserDefaults.standard.set(true, forKey: "profile_storage_migration_v1")
        logger.log("ProxyRotation: migrated old config keys to nick profile", category: .persistence, level: .info)
    }

    func setConnectionMode(_ mode: ConnectionMode, for target: ProxyTarget) {
        switch target {
        case .joe: joeConnectionMode = mode
        case .ignition: ignitionConnectionMode = mode
        case .ppsr: ppsrConnectionMode = mode
        }
        persistConnectionModes()
    }

    func setUnifiedConnectionMode(_ mode: ConnectionMode) {
        let previousMode = unifiedConnectionMode
        unifiedConnectionMode = mode
        joeConnectionMode = mode
        ignitionConnectionMode = mode
        ppsrConnectionMode = mode
        persistConnectionModes()
        persistUnifiedMode()
        DeviceProxyService.shared.handleUnifiedConnectionModeChange()

        let urlService = LoginURLRotationService.shared
        if mode == .direct || mode == .dns {
            urlService.applyDirectDNSAutoDisable()
        } else if previousMode == .direct || previousMode == .dns {
            urlService.restoreAutoDisabledURLs()
        }

        logger.log("ProxyRotation: unified connection mode set to \(mode.label)", category: .proxy, level: .success)
    }

    private func syncUnifiedConnectionMode() {
        joeConnectionMode = unifiedConnectionMode
        ignitionConnectionMode = unifiedConnectionMode
        ppsrConnectionMode = unifiedConnectionMode
        persistConnectionModes()
    }

    func syncProxiesAcrossTargets() {
        ignitionProxies = savedProxies
        ppsrProxies = savedProxies
        persistIgnitionProxies()
        persistPPSRProxies()
        logger.log("ProxyRotation: synced \(savedProxies.count) proxies across all targets", category: .proxy, level: .info)
    }

    func syncVPNConfigsAcrossTargets() {
        ignitionVPNConfigs = joeVPNConfigs
        ppsrVPNConfigs = joeVPNConfigs
        persistVPNConfigs(for: .ignition)
        persistVPNConfigs(for: .ppsr)
        logger.log("ProxyRotation: synced \(joeVPNConfigs.count) VPN configs across all targets", category: .vpn, level: .info)
    }

    func syncWGConfigsAcrossTargets() {
        ignitionWGConfigs = joeWGConfigs
        ppsrWGConfigs = joeWGConfigs
        persistWGConfigs(for: .ignition)
        persistWGConfigs(for: .ppsr)
        logger.log("ProxyRotation: synced \(joeWGConfigs.count) WG configs across all targets", category: .vpn, level: .info)
    }

    func syncAllNetworkConfigsAcrossTargets() {
        syncProxiesAcrossTargets()
        syncVPNConfigsAcrossTargets()
        syncWGConfigsAcrossTargets()
    }

    var unifiedProxies: [ProxyConfig] { savedProxies }
    var unifiedVPNConfigs: [OpenVPNConfig] { joeVPNConfigs }
    var unifiedWGConfigs: [WireGuardConfig] { joeWGConfigs }

    func storageCounts(for profile: NordKeyProfile) -> ProfileStorageCounts {
        ProfileStorageCounts(
            wireGuard: loadPersistedWGConfigs(for: .joe, profile: profile).count,
            openVPN: loadPersistedVPNConfigs(for: .joe, profile: profile).count
        )
    }

    func allProfileStorageCounts() -> ProfileStorageCounts {
        let nickCounts = storageCounts(for: .nick)
        let poliCounts = storageCounts(for: .poli)
        return ProfileStorageCounts(
            wireGuard: nickCounts.wireGuard + poliCounts.wireGuard,
            openVPN: nickCounts.openVPN + poliCounts.openVPN
        )
    }

    func replaceUnifiedVPNConfigs(_ configs: [OpenVPNConfig], for profile: NordKeyProfile) {
        persistVPNConfigs(configs, for: .joe, profile: profile)
        persistVPNConfigs(configs, for: .ignition, profile: profile)
        persistVPNConfigs(configs, for: .ppsr, profile: profile)
        if activeProfilePrefix == profilePrefix(for: profile) {
            joeVPNConfigs = configs
            ignitionVPNConfigs = configs
            ppsrVPNConfigs = configs
            resetRotationIndexes()
        }
    }

    func replaceUnifiedWGConfigs(_ configs: [WireGuardConfig], for profile: NordKeyProfile) {
        persistWGConfigs(configs, for: .joe, profile: profile)
        persistWGConfigs(configs, for: .ignition, profile: profile)
        persistWGConfigs(configs, for: .ppsr, profile: profile)
        if activeProfilePrefix == profilePrefix(for: profile) {
            joeWGConfigs = configs
            ignitionWGConfigs = configs
            ppsrWGConfigs = configs
            resetRotationIndexes()
        }
    }

    func clearUnifiedNetworkConfigs(for profile: NordKeyProfile) {
        replaceUnifiedWGConfigs([], for: profile)
        replaceUnifiedVPNConfigs([], for: profile)
    }

    func importUnifiedProxy(_ text: String) -> ImportReport {
        let report = bulkImportSOCKS5(text, forIgnition: false)
        syncProxiesAcrossTargets()
        return report
    }

    func importUnifiedVPNConfig(_ config: OpenVPNConfig) {
        importVPNConfig(config, for: .joe)
        syncVPNConfigsAcrossTargets()
    }

    func importUnifiedWGConfigs(_ configs: [WireGuardConfig]) -> ImportReport {
        let report = bulkImportWGConfigs(configs, for: .joe)
        syncWGConfigsAcrossTargets()
        return report
    }

    func clearAllUnifiedProxies() {
        removeAll(forIgnition: false)
        removeAll(forIgnition: true)
        removeAll(target: .ppsr)
    }

    func clearAllUnifiedVPNConfigs() {
        clearAllVPNConfigs(target: .joe)
        clearAllVPNConfigs(target: .ignition)
        clearAllVPNConfigs(target: .ppsr)
    }

    func clearAllUnifiedWGConfigs() {
        clearAllWGConfigs(target: .joe)
        clearAllWGConfigs(target: .ignition)
        clearAllWGConfigs(target: .ppsr)
    }

    func testAllUnifiedProxies() async {
        await testAllProxies(forIgnition: false)
        syncProxiesAcrossTargets()
    }

    func testAllUnifiedVPNConfigs() async {
        await testAllVPNConfigs(target: .joe)
        syncVPNConfigsAcrossTargets()
    }

    func testAllUnifiedWGConfigs() async {
        await testAllWGConfigs(target: .joe)
        syncWGConfigsAcrossTargets()
    }

    private func persistNetworkRegion() {
        UserDefaults.standard.set(networkRegion.rawValue, forKey: networkRegionPersistKey)
    }

    private func loadNetworkRegion() {
        if let raw = UserDefaults.standard.string(forKey: networkRegionPersistKey),
           let region = NetworkRegion(rawValue: raw) {
            networkRegion = region
        }
    }

    private func persistUnifiedMode() {
        UserDefaults.standard.set(unifiedConnectionMode.rawValue, forKey: unifiedModePersistKey)
    }

    private func loadUnifiedMode() {
        if let raw = UserDefaults.standard.string(forKey: unifiedModePersistKey),
           let mode = ConnectionMode(rawValue: raw) {
            unifiedConnectionMode = mode
        } else {
            unifiedConnectionMode = joeConnectionMode
        }
    }

    func connectionMode(for target: ProxyTarget) -> ConnectionMode {
        switch target {
        case .joe: joeConnectionMode
        case .ignition: ignitionConnectionMode
        case .ppsr: ppsrConnectionMode
        }
    }

    func proxies(for target: ProxyTarget) -> [ProxyConfig] {
        switch target {
        case .joe: savedProxies
        case .ignition: ignitionProxies
        case .ppsr: ppsrProxies
        }
    }

    func bulkImportSOCKS5(_ text: String, for target: ProxyTarget) -> ImportReport {
        switch target {
        case .joe: return bulkImportSOCKS5(text, forIgnition: false)
        case .ignition: return bulkImportSOCKS5(text, forIgnition: true)
        case .ppsr: return bulkImportSOCKS5PPSR(text)
        }
    }

    func bulkImportSOCKS5(_ text: String, forIgnition: Bool = false) -> ImportReport {
        let expandedLines = expandProxyLines(text)

        var added = 0
        var duplicates = 0
        var failed: [String] = []

        let targetList = forIgnition ? ignitionProxies : savedProxies
        for line in expandedLines {
            if let proxy = parseProxyLine(line) {
                let isDuplicate = targetList.contains { $0.host == proxy.host && $0.port == proxy.port && $0.username == proxy.username }
                if isDuplicate {
                    duplicates += 1
                } else {
                    if forIgnition {
                        ignitionProxies.append(proxy)
                    } else {
                        savedProxies.append(proxy)
                    }
                    added += 1
                }
            } else {
                failed.append(line)
            }
        }

        if added > 0 {
            if forIgnition { persistIgnitionProxies() } else { persistProxies() }
        }

        let report = ImportReport(added: added, duplicates: duplicates, failed: failed)
        lastImportReport = report
        return report
    }

    private func bulkImportSOCKS5PPSR(_ text: String) -> ImportReport {
        let expandedLines = expandProxyLines(text)

        var added = 0
        var duplicates = 0
        var failed: [String] = []

        for line in expandedLines {
            if let proxy = parseProxyLine(line) {
                let isDuplicate = ppsrProxies.contains { $0.host == proxy.host && $0.port == proxy.port && $0.username == proxy.username }
                if isDuplicate {
                    duplicates += 1
                } else {
                    ppsrProxies.append(proxy)
                    added += 1
                }
            } else {
                failed.append(line)
            }
        }

        if added > 0 { persistPPSRProxies() }
        let report = ImportReport(added: added, duplicates: duplicates, failed: failed)
        lastImportReport = report
        return report
    }

    private func expandProxyLines(_ text: String) -> [String] {
        let rawLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var expandedLines: [String] = []
        for line in rawLines {
            if line.contains("\t") {
                expandedLines.append(contentsOf: line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            } else if line.contains(" ") && !line.contains("://") {
                expandedLines.append(contentsOf: line.components(separatedBy: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            } else {
                expandedLines.append(line)
            }
        }
        return expandedLines
    }

    private func parseProxyLine(_ raw: String) -> ProxyConfig? {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        let schemePatterns = ["socks5h://", "socks5://", "socks4://", "socks://", "http://", "https://"]
        for scheme in schemePatterns {
            if line.lowercased().hasPrefix(scheme) {
                line = String(line.dropFirst(scheme.count))
                break
            }
        }

        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

        guard !line.isEmpty else { return nil }

        var username: String?
        var password: String?
        var hostPort: String

        if let atIndex = line.lastIndex(of: "@") {
            let authPart = String(line[line.startIndex..<atIndex])
            hostPort = String(line[line.index(after: atIndex)...])

            let authComponents = splitFirst(authPart, separator: ":")
            if let pw = authComponents.rest {
                username = authComponents.first
                password = pw
            } else {
                username = authPart
            }
        } else {
            let colonCount = line.filter({ $0 == ":" }).count
            if colonCount >= 3 {
                let parts = line.components(separatedBy: ":")
                if parts.count == 4, let _ = Int(parts[3]) {
                    username = parts[0]
                    password = parts[1]
                    hostPort = "\(parts[2]):\(parts[3])"
                } else if parts.count == 4, let _ = Int(parts[1]) {
                    hostPort = "\(parts[0]):\(parts[1])"
                    username = parts[2]
                    password = parts[3]
                } else {
                    hostPort = line
                }
            } else {
                hostPort = line
            }
        }

        hostPort = hostPort.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

        guard !hostPort.isEmpty else { return nil }

        let hpParts = hostPort.components(separatedBy: ":")
        guard hpParts.count >= 2 else { return nil }

        let portString = hpParts.last?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let port = Int(portString), port > 0, port <= 65535 else { return nil }

        let host = hpParts.dropLast().joined(separator: ":").trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }

        let validHostChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let hostChars = CharacterSet(charactersIn: host)
        guard validHostChars.isSuperset(of: hostChars) || isValidIPv4(host) else { return nil }

        if let u = username, u.isEmpty { username = nil }
        if let p = password, p.isEmpty { password = nil }

        return ProxyConfig(host: host, port: port, username: username, password: password)
    }

    private func splitFirst(_ s: String, separator: Character) -> (first: String, rest: String?) {
        if let idx = s.firstIndex(of: separator) {
            return (String(s[s.startIndex..<idx]), String(s[s.index(after: idx)...]))
        }
        return (s, nil)
    }

    private func isValidIPv4(_ host: String) -> Bool {
        let octets = host.components(separatedBy: ".")
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard let num = Int(octet) else { return false }
            return num >= 0 && num <= 255
        }
    }

    func nextWorkingProxy(for target: ProxyTarget) -> ProxyConfig? {
        switch target {
        case .joe: return nextWorkingProxy(forIgnition: false)
        case .ignition: return nextWorkingProxy(forIgnition: true)
        case .ppsr: return nextWorkingPPSRProxy()
        }
    }

    func nextWorkingProxy(forIgnition: Bool = false) -> ProxyConfig? {
        if forIgnition {
            let working = ignitionProxies.filter(\.isWorking)
            guard !working.isEmpty else {
                return ignitionProxies.isEmpty ? nil : ignitionProxies[currentIgnitionProxyIndex % ignitionProxies.count]
            }
            currentIgnitionProxyIndex = currentIgnitionProxyIndex % working.count
            let proxy = working[currentIgnitionProxyIndex]
            currentIgnitionProxyIndex += 1
            return proxy
        }
        let working = savedProxies.filter(\.isWorking)
        guard !working.isEmpty else {
            return savedProxies.isEmpty ? nil : savedProxies[currentProxyIndex % savedProxies.count]
        }
        currentProxyIndex = currentProxyIndex % working.count
        let proxy = working[currentProxyIndex]
        currentProxyIndex += 1
        return proxy
    }

    private func nextWorkingPPSRProxy() -> ProxyConfig? {
        let working = ppsrProxies.filter(\.isWorking)
        guard !working.isEmpty else {
            return ppsrProxies.isEmpty ? nil : ppsrProxies[currentPPSRProxyIndex % ppsrProxies.count]
        }
        currentPPSRProxyIndex = currentPPSRProxyIndex % working.count
        let proxy = working[currentPPSRProxyIndex]
        currentPPSRProxyIndex += 1
        return proxy
    }

    // MARK: - WireGuard Config Rotation

    func nextEnabledWGConfig(for target: ProxyTarget) -> WireGuardConfig? {
        let configs = wgConfigs(for: target).filter { $0.isEnabled }
        guard !configs.isEmpty else { return nil }

        switch target {
        case .joe:
            let idx = currentJoeWGIndex % configs.count
            currentJoeWGIndex = idx + 1
            return configs[idx]
        case .ignition:
            let idx = currentIgnitionWGIndex % configs.count
            currentIgnitionWGIndex = idx + 1
            return configs[idx]
        case .ppsr:
            let idx = currentPPSRWGIndex % configs.count
            currentPPSRWGIndex = idx + 1
            return configs[idx]
        }
    }

    func nextReachableWGConfig(for target: ProxyTarget) -> WireGuardConfig? {
        let reachable = wgConfigs(for: target).filter { $0.isEnabled && $0.isReachable }
        if !reachable.isEmpty {
            switch target {
            case .joe:
                let idx = currentJoeWGIndex % reachable.count
                currentJoeWGIndex = idx + 1
                return reachable[idx]
            case .ignition:
                let idx = currentIgnitionWGIndex % reachable.count
                currentIgnitionWGIndex = idx + 1
                return reachable[idx]
            case .ppsr:
                let idx = currentPPSRWGIndex % reachable.count
                currentPPSRWGIndex = idx + 1
                return reachable[idx]
            }
        }
        return nextEnabledWGConfig(for: target)
    }

    // MARK: - OpenVPN Config Rotation

    func nextEnabledOVPNConfig(for target: ProxyTarget) -> OpenVPNConfig? {
        let configs = vpnConfigs(for: target).filter { $0.isEnabled }
        guard !configs.isEmpty else { return nil }

        switch target {
        case .joe:
            let idx = currentJoeOVPNIndex % configs.count
            currentJoeOVPNIndex = idx + 1
            return configs[idx]
        case .ignition:
            let idx = currentIgnitionOVPNIndex % configs.count
            currentIgnitionOVPNIndex = idx + 1
            return configs[idx]
        case .ppsr:
            let idx = currentPPSROVPNIndex % configs.count
            currentPPSROVPNIndex = idx + 1
            return configs[idx]
        }
    }

    func nextReachableOVPNConfig(for target: ProxyTarget) -> OpenVPNConfig? {
        let reachable = vpnConfigs(for: target).filter { $0.isEnabled && $0.isReachable }
        if !reachable.isEmpty {
            switch target {
            case .joe:
                let idx = currentJoeOVPNIndex % reachable.count
                currentJoeOVPNIndex = idx + 1
                return reachable[idx]
            case .ignition:
                let idx = currentIgnitionOVPNIndex % reachable.count
                currentIgnitionOVPNIndex = idx + 1
                return reachable[idx]
            case .ppsr:
                let idx = currentPPSROVPNIndex % reachable.count
                currentPPSROVPNIndex = idx + 1
                return reachable[idx]
            }
        }
        return nextEnabledOVPNConfig(for: target)
    }

    func resetRotationIndexes() {
        currentProxyIndex = 0
        currentIgnitionProxyIndex = 0
        currentPPSRProxyIndex = 0
        currentJoeWGIndex = 0
        currentIgnitionWGIndex = 0
        currentPPSRWGIndex = 0
        currentJoeOVPNIndex = 0
        currentIgnitionOVPNIndex = 0
        currentPPSROVPNIndex = 0
    }

    func networkSummary(for target: ProxyTarget) -> String {
        let mode = connectionMode(for: target)
        switch mode {
        case .direct:
            return "Direct (No Proxy)"
        case .dns:
            return "Direct (DNS)"
        case .proxy:
            let count = proxies(for: target).filter(\.isWorking).count
            let total = proxies(for: target).count
            return "SOCKS5 (\(count)/\(total) working)"
        case .wireguard:
            let enabled = wgConfigs(for: target).filter { $0.isEnabled }.count
            let total = wgConfigs(for: target).count
            return "WireGuard (\(enabled)/\(total) enabled)"
        case .openvpn:
            let enabled = vpnConfigs(for: target).filter { $0.isEnabled }.count
            let total = vpnConfigs(for: target).count
            return "OpenVPN (\(enabled)/\(total) enabled)"
        case .nodeMaven:
            let nm = NodeMavenService.shared
            return nm.isEnabled ? "NodeMaven (\(nm.shortStatus))" : "NodeMaven (not configured)"
        case .hybrid:
            return "Hybrid (1 per method)"
        }
    }

    func markProxyWorking(_ proxy: ProxyConfig) {
        if let idx = savedProxies.firstIndex(where: { $0.id == proxy.id }) {
            savedProxies[idx].isWorking = true
            savedProxies[idx].lastTested = Date()
            savedProxies[idx].failCount = 0
            persistProxies()
        }
        if let idx = ignitionProxies.firstIndex(where: { $0.id == proxy.id }) {
            ignitionProxies[idx].isWorking = true
            ignitionProxies[idx].lastTested = Date()
            ignitionProxies[idx].failCount = 0
            persistIgnitionProxies()
        }
        if let idx = ppsrProxies.firstIndex(where: { $0.id == proxy.id }) {
            ppsrProxies[idx].isWorking = true
            ppsrProxies[idx].lastTested = Date()
            ppsrProxies[idx].failCount = 0
            persistPPSRProxies()
        }
    }

    func markProxyFailed(_ proxy: ProxyConfig) {
        if let idx = savedProxies.firstIndex(where: { $0.id == proxy.id }) {
            savedProxies[idx].failCount += 1
            savedProxies[idx].lastTested = Date()
            if savedProxies[idx].failCount >= 3 {
                savedProxies[idx].isWorking = false
            }
            persistProxies()
        }
        if let idx = ignitionProxies.firstIndex(where: { $0.id == proxy.id }) {
            ignitionProxies[idx].failCount += 1
            ignitionProxies[idx].lastTested = Date()
            if ignitionProxies[idx].failCount >= 3 {
                ignitionProxies[idx].isWorking = false
            }
            persistIgnitionProxies()
        }
        if let idx = ppsrProxies.firstIndex(where: { $0.id == proxy.id }) {
            ppsrProxies[idx].failCount += 1
            ppsrProxies[idx].lastTested = Date()
            if ppsrProxies[idx].failCount >= 3 {
                ppsrProxies[idx].isWorking = false
            }
            persistPPSRProxies()
        }
    }

    func removeProxy(_ proxy: ProxyConfig, fromIgnition: Bool = false) {
        if fromIgnition {
            ignitionProxies.removeAll { $0.id == proxy.id }
            persistIgnitionProxies()
        } else {
            savedProxies.removeAll { $0.id == proxy.id }
            persistProxies()
        }
    }

    func removeProxy(_ proxy: ProxyConfig, target: ProxyTarget) {
        switch target {
        case .joe:
            savedProxies.removeAll { $0.id == proxy.id }
            persistProxies()
        case .ignition:
            ignitionProxies.removeAll { $0.id == proxy.id }
            persistIgnitionProxies()
        case .ppsr:
            ppsrProxies.removeAll { $0.id == proxy.id }
            persistPPSRProxies()
        }
    }

    func removeAll(forIgnition: Bool = false) {
        if forIgnition {
            ignitionProxies.removeAll()
            currentIgnitionProxyIndex = 0
            persistIgnitionProxies()
        } else {
            savedProxies.removeAll()
            currentProxyIndex = 0
            persistProxies()
        }
    }

    func removeAll(target: ProxyTarget) {
        switch target {
        case .joe: removeAll(forIgnition: false)
        case .ignition: removeAll(forIgnition: true)
        case .ppsr:
            ppsrProxies.removeAll()
            currentPPSRProxyIndex = 0
            persistPPSRProxies()
        }
    }

    func removeDead(forIgnition: Bool = false) {
        if forIgnition {
            ignitionProxies.removeAll { !$0.isWorking && $0.lastTested != nil }
            persistIgnitionProxies()
        } else {
            savedProxies.removeAll { !$0.isWorking && $0.lastTested != nil }
            persistProxies()
        }
    }

    func removeDead(target: ProxyTarget) {
        switch target {
        case .joe: removeDead(forIgnition: false)
        case .ignition: removeDead(forIgnition: true)
        case .ppsr:
            ppsrProxies.removeAll { !$0.isWorking && $0.lastTested != nil }
            persistPPSRProxies()
        }
    }

    func resetAllStatus(forIgnition: Bool = false) {
        if forIgnition {
            for i in ignitionProxies.indices {
                ignitionProxies[i].isWorking = false
                ignitionProxies[i].lastTested = nil
                ignitionProxies[i].failCount = 0
            }
            persistIgnitionProxies()
        } else {
            for i in savedProxies.indices {
                savedProxies[i].isWorking = false
                savedProxies[i].lastTested = nil
                savedProxies[i].failCount = 0
            }
            persistProxies()
        }
    }

    func resetAllStatus(target: ProxyTarget) {
        switch target {
        case .joe: resetAllStatus(forIgnition: false)
        case .ignition: resetAllStatus(forIgnition: true)
        case .ppsr:
            for i in ppsrProxies.indices {
                ppsrProxies[i].isWorking = false
                ppsrProxies[i].lastTested = nil
                ppsrProxies[i].failCount = 0
            }
            persistPPSRProxies()
        }
    }

    func testAllProxies(forIgnition: Bool = false) async {
        let maxConcurrent = 5
        if forIgnition {
            let proxySnapshot = ignitionProxies
            await withTaskGroup(of: (UUID, Bool).self) { group in
                var launched = 0
                for proxy in proxySnapshot {
                    if launched >= maxConcurrent {
                        if let result = await group.next() {
                            applyTestResult(result, forIgnition: true)
                        }
                    }
                    group.addTask {
                        let working = await self.testSingleProxy(proxy)
                        return (proxy.id, working)
                    }
                    launched += 1
                }
                for await result in group {
                    applyTestResult(result, forIgnition: true)
                }
            }
            persistIgnitionProxies()
        } else {
            let proxySnapshot = savedProxies
            await withTaskGroup(of: (UUID, Bool).self) { group in
                var launched = 0
                for proxy in proxySnapshot {
                    if launched >= maxConcurrent {
                        if let result = await group.next() {
                            applyTestResult(result, forIgnition: false)
                        }
                    }
                    group.addTask {
                        let working = await self.testSingleProxy(proxy)
                        return (proxy.id, working)
                    }
                    launched += 1
                }
                for await result in group {
                    applyTestResult(result, forIgnition: false)
                }
            }
            persistProxies()
        }
    }

    func testAllProxies(target: ProxyTarget) async {
        switch target {
        case .joe: await testAllProxies(forIgnition: false)
        case .ignition: await testAllProxies(forIgnition: true)
        case .ppsr:
            let maxConcurrent = 5
            let proxySnapshot = ppsrProxies
            await withTaskGroup(of: (UUID, Bool).self) { group in
                var launched = 0
                for proxy in proxySnapshot {
                    if launched >= maxConcurrent {
                        if let result = await group.next() {
                            applyPPSRTestResult(result)
                        }
                    }
                    group.addTask {
                        let working = await self.testSingleProxy(proxy)
                        return (proxy.id, working)
                    }
                    launched += 1
                }
                for await result in group {
                    applyPPSRTestResult(result)
                }
            }
            persistPPSRProxies()
        }
    }

    private func applyTestResult(_ result: (UUID, Bool), forIgnition: Bool) {
        let (proxyId, working) = result
        if forIgnition {
            if let idx = ignitionProxies.firstIndex(where: { $0.id == proxyId }) {
                ignitionProxies[idx].isWorking = working
                ignitionProxies[idx].lastTested = Date()
                if working { ignitionProxies[idx].failCount = 0 }
                else { ignitionProxies[idx].failCount += 1 }
            }
        } else {
            if let idx = savedProxies.firstIndex(where: { $0.id == proxyId }) {
                savedProxies[idx].isWorking = working
                savedProxies[idx].lastTested = Date()
                if working { savedProxies[idx].failCount = 0 }
                else { savedProxies[idx].failCount += 1 }
            }
        }
    }

    private func applyPPSRTestResult(_ result: (UUID, Bool)) {
        let (proxyId, working) = result
        if let idx = ppsrProxies.firstIndex(where: { $0.id == proxyId }) {
            ppsrProxies[idx].isWorking = working
            ppsrProxies[idx].lastTested = Date()
            if working { ppsrProxies[idx].failCount = 0 }
            else { ppsrProxies[idx].failCount += 1 }
        }
    }

    nonisolated func testSingleProxy(_ proxy: ProxyConfig) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15

        var proxyDict: [String: Any] = [
            "SOCKSEnable": 1,
            "SOCKSProxy": proxy.host,
            "SOCKSPort": proxy.port,
        ]
        if let u = proxy.username { proxyDict["SOCKSUser"] = u }
        if let p = proxy.password { proxyDict["SOCKSPassword"] = p }
        config.connectionProxyDictionary = proxyDict

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let testURLs = [
            "https://api.ipify.org?format=json",
            "https://httpbin.org/ip",
            "https://ifconfig.me/ip"
        ]

        let result = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for urlString in testURLs {
                group.addTask {
                    guard let url = URL(string: urlString) else { return false }
                    do {
                        var request = URLRequest(url: url)
                        request.httpMethod = "GET"
                        request.timeoutInterval = 10
                        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                        let (data, response) = try await session.data(for: request)
                        if let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty {
                            return true
                        }
                    } catch { }
                    return false
                }
            }
            for await success in group {
                if success {
                    group.cancelAll()
                    return true
                }
            }
            return false
        }

        if !result {
            let proxyDisplay = proxy.displayString
            Task { @MainActor in
                DebugLogger.shared.log("ProxyTest FAIL: \(proxyDisplay)", category: .proxy, level: .debug)
            }
        }
        return result
    }

    func exportProxies(forIgnition: Bool = false) -> String {
        let list = forIgnition ? ignitionProxies : savedProxies
        return formatProxyList(list)
    }

    func exportProxies(target: ProxyTarget) -> String {
        formatProxyList(proxies(for: target))
    }

    private func formatProxyList(_ list: [ProxyConfig]) -> String {
        list.map { proxy in
            if let u = proxy.username, let p = proxy.password {
                return "socks5://\(u):\(p)@\(proxy.host):\(proxy.port)"
            } else {
                return "socks5://\(proxy.host):\(proxy.port)"
            }
        }.joined(separator: "\n")
    }

    var activeProxies: [ProxyConfig] {
        savedProxies
    }

    func proxies(forIgnition: Bool) -> [ProxyConfig] {
        forIgnition ? ignitionProxies : savedProxies
    }

    private func persistIgnitionProxies() {
        persistProxyList(ignitionProxies, key: ignitionPersistKey)
    }

    private func loadIgnitionProxies() {
        ignitionProxies = loadProxyList(key: ignitionPersistKey)
    }

    private func persistProxies() {
        persistProxyList(savedProxies, key: persistKey)
    }

    private func persistPPSRProxies() {
        persistProxyList(ppsrProxies, key: ppsrPersistKey)
    }

    private func loadPPSRProxies() {
        ppsrProxies = loadProxyList(key: ppsrPersistKey)
    }

    private func persistProxyList(_ list: [ProxyConfig], key: String) {
        let encoded = list.map { p -> [String: Any] in
            var dict: [String: Any] = [
                "id": p.id.uuidString,
                "host": p.host,
                "port": p.port,
                "isWorking": p.isWorking,
                "failCount": p.failCount,
            ]
            if let u = p.username { dict["username"] = u }
            if let pw = p.password { dict["password"] = pw }
            if let d = p.lastTested { dict["lastTested"] = d.timeIntervalSince1970 }
            return dict
        }
        if let data = try? JSONSerialization.data(withJSONObject: encoded) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadProxyList(key: String) -> [ProxyConfig] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { dict -> ProxyConfig? in
            guard let host = dict["host"] as? String,
                  let port = dict["port"] as? Int else { return nil }
            let restoredID: UUID
            if let idString = dict["id"] as? String, let parsed = UUID(uuidString: idString) {
                restoredID = parsed
            } else {
                restoredID = UUID()
            }
            var proxy = ProxyConfig(
                id: restoredID,
                host: host,
                port: port,
                username: dict["username"] as? String,
                password: dict["password"] as? String
            )
            proxy.isWorking = dict["isWorking"] as? Bool ?? false
            proxy.failCount = dict["failCount"] as? Int ?? 0
            if let ts = dict["lastTested"] as? TimeInterval {
                proxy.lastTested = Date(timeIntervalSince1970: ts)
            }
            return proxy
        }
    }

    private func persistConnectionModes() {
        let dict: [String: String] = [
            "joe": joeConnectionMode.rawValue,
            "ignition": ignitionConnectionMode.rawValue,
            "ppsr": ppsrConnectionMode.rawValue,
        ]
        UserDefaults.standard.set(dict, forKey: connectionModePersistKey)
    }

    private func loadConnectionModes() {
        guard let dict = UserDefaults.standard.dictionary(forKey: connectionModePersistKey) as? [String: String] else { return }
        if let joe = dict["joe"], let mode = ConnectionMode(rawValue: joe) { joeConnectionMode = mode }
        if let ign = dict["ignition"], let mode = ConnectionMode(rawValue: ign) { ignitionConnectionMode = mode }
        if let ppsr = dict["ppsr"], let mode = ConnectionMode(rawValue: ppsr) { ppsrConnectionMode = mode }
    }

    func vpnConfigs(for target: ProxyTarget) -> [OpenVPNConfig] {
        switch target {
        case .joe: joeVPNConfigs
        case .ignition: ignitionVPNConfigs
        case .ppsr: ppsrVPNConfigs
        }
    }

    func importVPNConfig(_ config: OpenVPNConfig, for target: ProxyTarget) {
        switch target {
        case .joe:
            guard !joeVPNConfigs.contains(where: { $0.remoteHost == config.remoteHost && $0.remotePort == config.remotePort }) else { return }
            joeVPNConfigs.append(config)
        case .ignition:
            guard !ignitionVPNConfigs.contains(where: { $0.remoteHost == config.remoteHost && $0.remotePort == config.remotePort }) else { return }
            ignitionVPNConfigs.append(config)
        case .ppsr:
            guard !ppsrVPNConfigs.contains(where: { $0.remoteHost == config.remoteHost && $0.remotePort == config.remotePort }) else { return }
            ppsrVPNConfigs.append(config)
        }
        persistVPNConfigs(for: target)
    }

    func removeVPNConfig(_ config: OpenVPNConfig, target: ProxyTarget) {
        switch target {
        case .joe: joeVPNConfigs.removeAll { $0.id == config.id }
        case .ignition: ignitionVPNConfigs.removeAll { $0.id == config.id }
        case .ppsr: ppsrVPNConfigs.removeAll { $0.id == config.id }
        }
        persistVPNConfigs(for: target)
    }

    func toggleVPNConfig(_ config: OpenVPNConfig, target: ProxyTarget, enabled: Bool) {
        switch target {
        case .joe:
            if let idx = joeVPNConfigs.firstIndex(where: { $0.id == config.id }) { joeVPNConfigs[idx].isEnabled = enabled }
        case .ignition:
            if let idx = ignitionVPNConfigs.firstIndex(where: { $0.id == config.id }) { ignitionVPNConfigs[idx].isEnabled = enabled }
        case .ppsr:
            if let idx = ppsrVPNConfigs.firstIndex(where: { $0.id == config.id }) { ppsrVPNConfigs[idx].isEnabled = enabled }
        }
        persistVPNConfigs(for: target)
    }

    func markVPNConfigReachable(_ config: OpenVPNConfig, target: ProxyTarget, reachable: Bool, latencyMs: Int? = nil) {
        func update(_ configs: inout [OpenVPNConfig]) {
            if let idx = configs.firstIndex(where: { $0.id == config.id || $0.uniqueKey == config.uniqueKey }) {
                configs[idx].isReachable = reachable
                configs[idx].lastTested = Date()
                configs[idx].lastLatencyMs = latencyMs
                if reachable {
                    configs[idx].failCount = 0
                    configs[idx].isEnabled = true
                } else {
                    configs[idx].failCount += 1
                    if configs[idx].failCount >= 2 { configs[idx].isEnabled = false }
                }
            }
        }
        switch target {
        case .joe: update(&joeVPNConfigs)
        case .ignition: update(&ignitionVPNConfigs)
        case .ppsr: update(&ppsrVPNConfigs)
        }
        persistVPNConfigs(for: target)
    }

    func testAllVPNConfigs(target: ProxyTarget) async {
        let configs = vpnConfigs(for: target)
        guard !configs.isEmpty else { return }
        let maxConcurrent = 8
        await withTaskGroup(of: (String, Bool, Int).self) { group in
            var launched = 0
            for config in configs {
                if launched >= maxConcurrent {
                    if let result = await group.next() {
                        applyVPNTestResult(result, target: target)
                    }
                }
                group.addTask {
                    let (reachable, latency) = await self.testOpenVPNEndpointReachability(config)
                    return (config.uniqueKey, reachable, latency)
                }
                launched += 1
            }
            for await result in group {
                applyVPNTestResult(result, target: target)
            }
        }
        persistVPNConfigs(for: target)
    }

    private func applyVPNTestResult(_ result: (String, Bool, Int), target: ProxyTarget) {
        let (uniqueKey, reachable, latency) = result
        func update(_ configs: inout [OpenVPNConfig]) {
            if let idx = configs.firstIndex(where: { $0.uniqueKey == uniqueKey }) {
                configs[idx].isReachable = reachable
                configs[idx].lastTested = Date()
                configs[idx].lastLatencyMs = reachable ? latency : nil
                if reachable {
                    configs[idx].failCount = 0
                    configs[idx].isEnabled = true
                } else {
                    configs[idx].failCount += 1
                    if configs[idx].failCount >= 2 { configs[idx].isEnabled = false }
                }
            }
        }
        switch target {
        case .joe: update(&joeVPNConfigs)
        case .ignition: update(&ignitionVPNConfigs)
        case .ppsr: update(&ppsrVPNConfigs)
        }
    }

    nonisolated func testOpenVPNEndpointReachability(_ config: OpenVPNConfig) async -> (Bool, Int) {
        let result = await VPNProtocolTestService.shared.testOpenVPNEndpoint(config)
        Task { @MainActor in
            if result.reachable {
                self.logger.log("VPN reachability: \(config.remoteHost):\(config.remotePort) — \(result.detail)", category: .vpn, level: .success)
            } else {
                self.logger.log("VPN reachability: \(config.remoteHost):\(config.remotePort) — \(result.detail)", category: .vpn, level: .warning)
            }
        }
        return (result.reachable, result.latencyMs)
    }

    func clearAllVPNConfigs(target: ProxyTarget) {
        switch target {
        case .joe: joeVPNConfigs.removeAll()
        case .ignition: ignitionVPNConfigs.removeAll()
        case .ppsr: ppsrVPNConfigs.removeAll()
        }
        persistVPNConfigs(for: target)
    }

    func removeUnreachableVPNConfigs(target: ProxyTarget) {
        switch target {
        case .joe: joeVPNConfigs.removeAll { !$0.isReachable && $0.lastTested != nil }
        case .ignition: ignitionVPNConfigs.removeAll { !$0.isReachable && $0.lastTested != nil }
        case .ppsr: ppsrVPNConfigs.removeAll { !$0.isReachable && $0.lastTested != nil }
        }
        persistVPNConfigs(for: target)
    }

    func removeUnreachableWGConfigs(target: ProxyTarget) {
        switch target {
        case .joe: joeWGConfigs.removeAll { !$0.isReachable && $0.lastTested != nil }
        case .ignition: ignitionWGConfigs.removeAll { !$0.isReachable && $0.lastTested != nil }
        case .ppsr: ppsrWGConfigs.removeAll { !$0.isReachable && $0.lastTested != nil }
        }
        persistWGConfigs(for: target)
    }

    private func persistVPNConfigs(for target: ProxyTarget) {
        let configs: [OpenVPNConfig]
        switch target {
        case .joe: configs = joeVPNConfigs
        case .ignition: configs = ignitionVPNConfigs
        case .ppsr: configs = ppsrVPNConfigs
        }
        persistVPNConfigs(configs, for: target, profile: NordVPNService.shared.activeKeyProfile)
    }

    private func persistVPNConfigs(_ configs: [OpenVPNConfig], for target: ProxyTarget, profile: NordKeyProfile) {
        let key = vpnPersistKey(for: target, profile: profile)
        do {
            let data = try JSONEncoder().encode(configs)
            UserDefaults.standard.set(data, forKey: key)
            logger.log("ProxyRotation: persisted \(configs.count) VPN configs for \(target.rawValue)", category: .persistence, level: .debug)
        } catch {
            logger.logError("ProxyRotation: failed to persist VPN configs for \(target.rawValue)", error: error, category: .persistence)
        }
    }

    private func loadPersistedVPNConfigs(for target: ProxyTarget, profile: NordKeyProfile) -> [OpenVPNConfig] {
        let key = vpnPersistKey(for: target, profile: profile)
        guard let data = UserDefaults.standard.data(forKey: key),
              let configs = try? JSONDecoder().decode([OpenVPNConfig].self, from: data) else {
            return []
        }
        return configs
    }

    private func loadVPNConfigs() {
        joeVPNConfigs = loadPersistedVPNConfigs(for: .joe, profile: NordVPNService.shared.activeKeyProfile)
        ignitionVPNConfigs = loadPersistedVPNConfigs(for: .ignition, profile: NordVPNService.shared.activeKeyProfile)
        ppsrVPNConfigs = loadPersistedVPNConfigs(for: .ppsr, profile: NordVPNService.shared.activeKeyProfile)
    }

    func wgConfigs(for target: ProxyTarget) -> [WireGuardConfig] {
        switch target {
        case .joe: joeWGConfigs
        case .ignition: ignitionWGConfigs
        case .ppsr: ppsrWGConfigs
        }
    }

    func importWGConfig(_ config: WireGuardConfig, for target: ProxyTarget) {
        let existing = wgConfigs(for: target)
        guard !existing.contains(where: { $0.uniqueKey == config.uniqueKey }) else { return }
        switch target {
        case .joe: joeWGConfigs.append(config)
        case .ignition: ignitionWGConfigs.append(config)
        case .ppsr: ppsrWGConfigs.append(config)
        }
        persistWGConfigs(for: target)
    }

    func bulkImportWGConfigs(_ configs: [WireGuardConfig], for target: ProxyTarget) -> ImportReport {
        var added = 0
        var duplicates = 0
        let failed: [String] = []
        var seenKeys = Set(wgConfigs(for: target).map(\.uniqueKey))
        for config in configs {
            if seenKeys.contains(config.uniqueKey) {
                duplicates += 1
            } else {
                seenKeys.insert(config.uniqueKey)
                switch target {
                case .joe: joeWGConfigs.append(config)
                case .ignition: ignitionWGConfigs.append(config)
                case .ppsr: ppsrWGConfigs.append(config)
                }
                added += 1
            }
        }
        if added > 0 { persistWGConfigs(for: target) }
        let report = ImportReport(added: added, duplicates: duplicates, failed: failed)
        lastImportReport = report
        return report
    }

    func removeWGConfig(_ config: WireGuardConfig, target: ProxyTarget) {
        switch target {
        case .joe: joeWGConfigs.removeAll { $0.id == config.id || $0.uniqueKey == config.uniqueKey }
        case .ignition: ignitionWGConfigs.removeAll { $0.id == config.id || $0.uniqueKey == config.uniqueKey }
        case .ppsr: ppsrWGConfigs.removeAll { $0.id == config.id || $0.uniqueKey == config.uniqueKey }
        }
        persistWGConfigs(for: target)
    }

    func toggleWGConfig(_ config: WireGuardConfig, target: ProxyTarget, enabled: Bool) {
        switch target {
        case .joe:
            if let idx = joeWGConfigs.firstIndex(where: { $0.id == config.id || $0.uniqueKey == config.uniqueKey }) { joeWGConfigs[idx].isEnabled = enabled }
        case .ignition:
            if let idx = ignitionWGConfigs.firstIndex(where: { $0.id == config.id || $0.uniqueKey == config.uniqueKey }) { ignitionWGConfigs[idx].isEnabled = enabled }
        case .ppsr:
            if let idx = ppsrWGConfigs.firstIndex(where: { $0.id == config.id || $0.uniqueKey == config.uniqueKey }) { ppsrWGConfigs[idx].isEnabled = enabled }
        }
        persistWGConfigs(for: target)
    }

    func clearAllWGConfigs(target: ProxyTarget) {
        switch target {
        case .joe: joeWGConfigs.removeAll()
        case .ignition: ignitionWGConfigs.removeAll()
        case .ppsr: ppsrWGConfigs.removeAll()
        }
        persistWGConfigs(for: target)
    }

    func markWGConfigReachable(_ config: WireGuardConfig, target: ProxyTarget, reachable: Bool) {
        func update(_ configs: inout [WireGuardConfig]) {
            if let idx = configs.firstIndex(where: { $0.id == config.id || $0.uniqueKey == config.uniqueKey }) {
                configs[idx].isReachable = reachable
                configs[idx].lastTested = Date()
                if reachable {
                    configs[idx].failCount = 0
                    configs[idx].isEnabled = true
                } else {
                    configs[idx].failCount += 1
                    if configs[idx].failCount >= 3 {
                        configs[idx].isEnabled = false
                    }
                }
            }
        }
        switch target {
        case .joe: update(&joeWGConfigs)
        case .ignition: update(&ignitionWGConfigs)
        case .ppsr: update(&ppsrWGConfigs)
        }
        persistWGConfigs(for: target)
    }

    func testAllWGConfigs(target: ProxyTarget) async {
        resetWGTestState(for: target)
        let configs = wgConfigs(for: target)
        guard !configs.isEmpty else { return }
        let maxConcurrent = 6
        await withTaskGroup(of: (String, Bool, Int).self) { group in
            var launched = 0
            for config in configs {
                if launched >= maxConcurrent {
                    if let result = await group.next() {
                        applyWGTestResult(result, target: target)
                    }
                }
                group.addTask {
                    let (reachable, latency) = await self.testWGEndpointWithLatency(config)
                    return (config.uniqueKey, reachable, latency)
                }
                launched += 1
            }
            for await result in group {
                applyWGTestResult(result, target: target)
            }
        }
        persistWGConfigs(for: target)
    }

    private func resetWGTestState(for target: ProxyTarget) {
        func reset(_ configs: inout [WireGuardConfig]) {
            for i in configs.indices {
                configs[i].isEnabled = true
                configs[i].isReachable = false
                configs[i].lastTested = nil
                configs[i].failCount = 0
            }
        }
        switch target {
        case .joe: reset(&joeWGConfigs)
        case .ignition: reset(&ignitionWGConfigs)
        case .ppsr: reset(&ppsrWGConfigs)
        }
    }

    private func applyWGTestResult(_ result: (String, Bool, Int), target: ProxyTarget) {
        let (uniqueKey, reachable, _) = result
        func update(_ configs: inout [WireGuardConfig]) {
            if let idx = configs.firstIndex(where: { $0.uniqueKey == uniqueKey }) {
                configs[idx].isReachable = reachable
                configs[idx].lastTested = Date()
                if reachable {
                    configs[idx].failCount = 0
                    configs[idx].isEnabled = true
                } else {
                    configs[idx].failCount += 1
                    if configs[idx].failCount >= 3 {
                        configs[idx].isEnabled = false
                    }
                }
            }
        }
        switch target {
        case .joe: update(&joeWGConfigs)
        case .ignition: update(&ignitionWGConfigs)
        case .ppsr: update(&ppsrWGConfigs)
        }
    }

    nonisolated func testWGEndpointReachability(_ config: WireGuardConfig) async -> Bool {
        let result = await VPNProtocolTestService.shared.testWireGuardEndpoint(config)
        Task { @MainActor in
            if result.reachable {
                self.logger.log("WG reachability: \(config.endpointHost):\(config.endpointPort) — \(result.detail)", category: .vpn, level: .success)
            } else {
                self.logger.log("WG reachability: \(config.endpointHost):\(config.endpointPort) — \(result.detail)", category: .vpn, level: .warning)
            }
        }
        return result.reachable
    }

    nonisolated func testWGEndpointWithLatency(_ config: WireGuardConfig) async -> (Bool, Int) {
        let result = await VPNProtocolTestService.shared.testWireGuardEndpoint(config)
        Task { @MainActor in
            if result.reachable {
                self.logger.log("WG reachability: \(config.endpointHost):\(config.endpointPort) — \(result.detail)", category: .vpn, level: .success)
            } else {
                self.logger.log("WG reachability: \(config.endpointHost):\(config.endpointPort) — \(result.detail)", category: .vpn, level: .warning)
            }
        }
        return (result.reachable, result.latencyMs)
    }

    private nonisolated func resolveHost(_ host: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let hostRef = CFHostCreateWithName(nil, host as CFString).takeRetainedValue()
            var resolved = DarwinBoolean(false)
            CFHostStartInfoResolution(hostRef, .addresses, nil)
            let addresses = CFHostGetAddressing(hostRef, &resolved)
            if resolved.boolValue, let addrs = addresses?.takeUnretainedValue() as? [Data], !addrs.isEmpty {
                continuation.resume(returning: true)
            } else {
                continuation.resume(returning: false)
            }
        }
    }

    private nonisolated func resolveHostViaDoH(_ host: String) async -> Bool {
        let dohEndpoints = [
            "https://cloudflare-dns.com/dns-query?name=\(host)&type=A",
            "https://dns.google/dns-query?name=\(host)&type=A",
            "https://dns.quad9.net:5053/dns-query?name=\(host)&type=A"
        ]

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        for urlString in dohEndpoints {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 6
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let answers = json["Answer"] as? [[String: Any]], !answers.isEmpty {
                        return true
                    }
                }
            } catch {
                continue
            }
        }
        return false
    }

    private nonisolated func testHTTPSHandshake(host: String) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        guard let url = URL(string: "https://\(host)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                return http.statusCode < 500
            }
            return true
        } catch let error as NSError {
            if error.domain == NSURLErrorDomain {
                if error.code == NSURLErrorSecureConnectionFailed { return true }
                if error.code == NSURLErrorServerCertificateUntrusted { return true }
                if error.code == NSURLErrorServerCertificateHasBadDate { return true }
                if error.code == NSURLErrorServerCertificateHasUnknownRoot { return true }
            }
            return false
        }
    }

    private nonisolated func testTCPConnection(host: String, port: Int, timeoutSeconds: Double) async -> Bool {
        guard port > 0, port <= 65535, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: nwPort,
                using: .tcp
            )
            let guard_ = ContinuationGuard()
            let queue = DispatchQueue(label: "tcp.test.\(host).\(port)")

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if guard_.tryConsume() {
                        connection.cancel()
                        continuation.resume(returning: true)
                    }
                case .failed, .cancelled:
                    if guard_.tryConsume() {
                        continuation.resume(returning: false)
                    }
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                if guard_.tryConsume() {
                    connection.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func persistWGConfigs(for target: ProxyTarget) {
        let configs: [WireGuardConfig]
        switch target {
        case .joe: configs = joeWGConfigs
        case .ignition: configs = ignitionWGConfigs
        case .ppsr: configs = ppsrWGConfigs
        }
        persistWGConfigs(configs, for: target, profile: NordVPNService.shared.activeKeyProfile)
    }

    private func persistWGConfigs(_ configs: [WireGuardConfig], for target: ProxyTarget, profile: NordKeyProfile) {
        let key = wgPersistKey(for: target, profile: profile)
        do {
            let data = try JSONEncoder().encode(configs)
            UserDefaults.standard.set(data, forKey: key)
            logger.log("ProxyRotation: persisted \(configs.count) WG configs for \(target.rawValue)", category: .persistence, level: .debug)
        } catch {
            logger.logError("ProxyRotation: failed to persist WG configs for \(target.rawValue)", error: error, category: .persistence)
        }
    }

    private func loadPersistedWGConfigs(for target: ProxyTarget, profile: NordKeyProfile) -> [WireGuardConfig] {
        let key = wgPersistKey(for: target, profile: profile)
        guard let data = UserDefaults.standard.data(forKey: key),
              let configs = try? JSONDecoder().decode([WireGuardConfig].self, from: data) else {
            return []
        }
        return configs
    }

    private func loadWGConfigs() {
        joeWGConfigs = loadPersistedWGConfigs(for: .joe, profile: NordVPNService.shared.activeKeyProfile)
        ignitionWGConfigs = loadPersistedWGConfigs(for: .ignition, profile: NordVPNService.shared.activeKeyProfile)
        ppsrWGConfigs = loadPersistedWGConfigs(for: .ppsr, profile: NordVPNService.shared.activeKeyProfile)
    }

    private func loadProxies() {
        let loaded = loadProxyList(key: persistKey)
        if !loaded.isEmpty {
            savedProxies = loaded
        } else {
            migrateFromV1()
        }
    }

    private func migrateFromV1() {
        let v1Key = "saved_socks5_proxies_v1"
        guard let data = UserDefaults.standard.data(forKey: v1Key),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        savedProxies = array.compactMap { dict -> ProxyConfig? in
            guard let host = dict["host"] as? String,
                  let port = dict["port"] as? Int else { return nil }
            var proxy = ProxyConfig(
                host: host,
                port: port,
                username: dict["username"] as? String,
                password: dict["password"] as? String
            )
            proxy.isWorking = dict["isWorking"] as? Bool ?? false
            if let ts = dict["lastTested"] as? TimeInterval {
                proxy.lastTested = Date(timeIntervalSince1970: ts)
            }
            return proxy
        }

        if !savedProxies.isEmpty {
            persistProxies()
            UserDefaults.standard.removeObject(forKey: v1Key)
        }
    }
}
