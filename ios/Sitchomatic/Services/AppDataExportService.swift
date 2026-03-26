import Foundation
import CoreGraphics

nonisolated struct ComprehensiveExportConfig: Codable, Sendable {
    var version: String = "2.0"
    var exportedAt: String = ""

    var joeURLs: [ExportURL] = []
    var ignitionURLs: [ExportURL] = []
    var joeProxies: [ExportProxy] = []
    var ignitionProxies: [ExportProxy] = []
    var ppsrProxies: [ExportProxy] = []
    var joeVPNConfigs: [ExportVPN] = []
    var ignitionVPNConfigs: [ExportVPN] = []
    var ppsrVPNConfigs: [ExportVPN] = []
    var joeWGConfigs: [ExportWG] = []
    var ignitionWGConfigs: [ExportWG] = []
    var ppsrWGConfigs: [ExportWG] = []
    var dnsServers: [ExportDNS] = []
    var blacklist: [ExportBlacklist] = []
    var connectionModes: ExportConnectionModes = ExportConnectionModes()
    var networkRegion: String = "USA"
    var unifiedConnectionMode: String = "DNS"
    var ipRoutingSettings: ExportIPRoutingSettings?
    var settings: ExportSettings = ExportSettings()
    var automationSettings: AutomationSettings?

    var loginCredentials: [ExportCredential] = []
    var ppsrCards: [ExportCard] = []

    var loginAppSettings: ExportLoginAppSettings?
    var ppsrAppSettings: ExportPPSRAppSettings?

    var emailRotationList: [String] = []

    var debugLoginButtonConfigs: [ExportDebugButtonConfig] = []

    var recordedFlows: [RecordedFlow] = []

    var cardSortOption: String?
    var cardSortAscending: Bool?

    var loginCropRect: ExportRect?
    var ppsrCropRect: ExportRect?

    var calibrations: [String: LoginCalibrationService.URLCalibration]?
    var customTemplates: [AutomationTemplate]?
    var speedProfile: ConcurrentSpeedOptimizer.SpeedProfile?
    var nordVPNAccessKey: String?
    var nordVPNPrivateKey: String?
    var tempDisabledBgCheckEnabled: Bool?

    nonisolated struct ExportURL: Codable, Sendable {
        let url: String
        let enabled: Bool
    }

    nonisolated struct ExportProxy: Codable, Sendable {
        let host: String
        let port: Int
        let username: String?
        let password: String?
    }

    nonisolated struct ExportVPN: Codable, Sendable {
        let fileName: String
        let remoteHost: String
        let remotePort: Int
        let proto: String
        let rawContent: String
        let enabled: Bool
    }

    nonisolated struct ExportWG: Codable, Sendable {
        let fileName: String
        let rawContent: String
        let enabled: Bool
    }

    nonisolated struct ExportDNS: Codable, Sendable {
        let name: String
        let url: String
        let enabled: Bool
    }

    nonisolated struct ExportBlacklist: Codable, Sendable {
        let email: String
        let reason: String
    }

    nonisolated struct ExportConnectionModes: Codable, Sendable {
        var joe: String = "DNS"
        var ignition: String = "DNS"
        var ppsr: String = "DNS"
    }

    nonisolated struct ExportIPRoutingSettings: Codable, Sendable {
        var mode: String = "App-Wide United IP"
        var rotationInterval: String = "Every Batch"
        var rotateOnBatchStart: Bool = false
        var rotateOnFingerprintDetection: Bool = true
        var localProxyEnabled: Bool = true
        var autoFailoverEnabled: Bool = true
        var healthCheckInterval: TimeInterval = 30
        var maxFailuresBeforeRotation: Int = 3
    }

    nonisolated struct ExportSettings: Codable, Sendable {
        var autoExcludeBlacklist: Bool = true
        var autoBlacklistNoAcc: Bool = false
    }

    nonisolated struct ExportCredential: Codable, Sendable {
        let id: String
        let username: String
        let password: String
        let status: String
        let addedAt: TimeInterval
        let notes: String
        let assignedPasswords: [String]
        let nextPasswordIndex: Int
        let testResults: [ExportLoginTestResult]
    }

    nonisolated struct ExportLoginTestResult: Codable, Sendable {
        let timestamp: TimeInterval
        let success: Bool
        let duration: TimeInterval
        let errorMessage: String?
        let responseDetail: String?
    }

    nonisolated struct ExportCard: Codable, Sendable {
        let id: String
        let number: String
        let expiryMonth: String
        let expiryYear: String
        let cvv: String
        let brand: String
        let status: String
        let addedAt: TimeInterval
        let testResults: [ExportCardTestResult]
        let binData: ExportBINData?
    }

    nonisolated struct ExportCardTestResult: Codable, Sendable {
        let timestamp: TimeInterval
        let success: Bool
        let vin: String
        let duration: TimeInterval
        let errorMessage: String?
    }

    nonisolated struct ExportBINData: Codable, Sendable {
        let bin: String
        let scheme: String
        let type: String
        let category: String
        let issuer: String
        let country: String
        let countryCode: String
        let isLoaded: Bool
    }

    nonisolated struct ExportLoginAppSettings: Codable, Sendable {
        var targetSite: String
        var maxConcurrency: Int
        var debugMode: Bool
        var appearanceMode: String
        var stealthEnabled: Bool
        var testTimeout: TimeInterval
    }

    nonisolated struct ExportPPSRAppSettings: Codable, Sendable {
        var email: String
        var maxConcurrency: Int
        var debugMode: Bool
        var appearanceMode: String
        var useEmailRotation: Bool
        var stealthEnabled: Bool
        var retrySubmitOnFail: Bool
        var cropRect: ExportRect?
    }

    nonisolated struct ExportDebugButtonConfig: Codable, Sendable {
        let urlPattern: String
        let config: DebugLoginButtonConfig
    }

    nonisolated struct ExportRect: Codable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }
}

typealias ExportableConfig = ComprehensiveExportConfig

@MainActor
class AppDataExportService {
    static let shared = AppDataExportService()

    func exportJSON() -> String {
        let urlService = LoginURLRotationService.shared
        let proxyService = ProxyRotationService.shared
        let dnsService = PPSRDoHService.shared
        let blacklistService = BlacklistService.shared
        let emailService = PPSREmailRotationService.shared
        let flowService = FlowPersistenceService.shared
        let debugButtonService = DebugLoginButtonService.shared

        var config = ComprehensiveExportConfig()
        config.exportedAt = DateFormatters.exportTimestamp.string(from: Date())

        config.joeURLs = urlService.joeURLs.map { .init(url: $0.urlString, enabled: $0.isEnabled) }
        config.ignitionURLs = urlService.ignitionURLs.map { .init(url: $0.urlString, enabled: $0.isEnabled) }

        config.joeProxies = proxyService.savedProxies.map { .init(host: $0.host, port: $0.port, username: $0.username, password: $0.password) }
        config.ignitionProxies = proxyService.ignitionProxies.map { .init(host: $0.host, port: $0.port, username: $0.username, password: $0.password) }
        config.ppsrProxies = proxyService.ppsrProxies.map { .init(host: $0.host, port: $0.port, username: $0.username, password: $0.password) }

        config.joeVPNConfigs = proxyService.joeVPNConfigs.map { .init(fileName: $0.fileName, remoteHost: $0.remoteHost, remotePort: $0.remotePort, proto: $0.proto, rawContent: $0.rawContent, enabled: $0.isEnabled) }
        config.ignitionVPNConfigs = proxyService.ignitionVPNConfigs.map { .init(fileName: $0.fileName, remoteHost: $0.remoteHost, remotePort: $0.remotePort, proto: $0.proto, rawContent: $0.rawContent, enabled: $0.isEnabled) }
        config.ppsrVPNConfigs = proxyService.ppsrVPNConfigs.map { .init(fileName: $0.fileName, remoteHost: $0.remoteHost, remotePort: $0.remotePort, proto: $0.proto, rawContent: $0.rawContent, enabled: $0.isEnabled) }

        config.joeWGConfigs = proxyService.joeWGConfigs.map { .init(fileName: $0.fileName, rawContent: $0.rawContent, enabled: $0.isEnabled) }
        config.ignitionWGConfigs = proxyService.ignitionWGConfigs.map { .init(fileName: $0.fileName, rawContent: $0.rawContent, enabled: $0.isEnabled) }
        config.ppsrWGConfigs = proxyService.ppsrWGConfigs.map { .init(fileName: $0.fileName, rawContent: $0.rawContent, enabled: $0.isEnabled) }

        config.dnsServers = dnsService.managedProviders.map { .init(name: $0.name, url: $0.url, enabled: $0.isEnabled) }
        config.blacklist = blacklistService.blacklistedEmails.map { .init(email: $0.email, reason: $0.reason) }

        config.connectionModes = .init(
            joe: proxyService.joeConnectionMode.rawValue,
            ignition: proxyService.ignitionConnectionMode.rawValue,
            ppsr: proxyService.ppsrConnectionMode.rawValue
        )
        config.networkRegion = proxyService.networkRegion.rawValue
        config.unifiedConnectionMode = proxyService.unifiedConnectionMode.rawValue
        let deviceProxy = DeviceProxyService.shared
        config.ipRoutingSettings = .init(
            mode: deviceProxy.ipRoutingMode.rawValue,
            rotationInterval: deviceProxy.rotationInterval.rawValue,
            rotateOnBatchStart: deviceProxy.rotateOnBatchStart,
            rotateOnFingerprintDetection: deviceProxy.rotateOnFingerprintDetection,
            localProxyEnabled: deviceProxy.localProxyEnabled,
            autoFailoverEnabled: deviceProxy.autoFailoverEnabled,
            healthCheckInterval: deviceProxy.healthCheckInterval,
            maxFailuresBeforeRotation: deviceProxy.maxFailuresBeforeRotation
        )

        config.settings = .init(
            autoExcludeBlacklist: blacklistService.autoExcludeBlacklist,
            autoBlacklistNoAcc: blacklistService.autoBlacklistNoAcc
        )

        if let data = UserDefaults.standard.data(forKey: "automation_settings_v1"),
           let loaded = try? JSONDecoder().decode(AutomationSettings.self, from: data) {
            config.automationSettings = loaded.normalizedTimeouts()
        }

        let loginCredentials = LoginPersistenceService.shared.loadCredentials()
        config.loginCredentials = loginCredentials.map { cred in
            .init(
                id: cred.id,
                username: cred.username,
                password: cred.password,
                status: cred.status.rawValue,
                addedAt: cred.addedAt.timeIntervalSince1970,
                notes: cred.notes,
                assignedPasswords: cred.assignedPasswords,
                nextPasswordIndex: cred.nextPasswordIndex,
                testResults: cred.testResults.map { r in
                    .init(timestamp: r.timestamp.timeIntervalSince1970, success: r.success, duration: r.duration, errorMessage: r.errorMessage, responseDetail: r.responseDetail)
                }
            )
        }

        let ppsrCards = PPSRPersistenceService.shared.loadCards()
        config.ppsrCards = ppsrCards.map { card in
            .init(
                id: card.id,
                number: card.number,
                expiryMonth: card.expiryMonth,
                expiryYear: card.expiryYear,
                cvv: card.cvv,
                brand: card.brand.rawValue,
                status: card.status.rawValue,
                addedAt: card.addedAt.timeIntervalSince1970,
                testResults: card.testResults.map { r in
                    .init(timestamp: r.timestamp.timeIntervalSince1970, success: r.success, vin: r.vin, duration: r.duration, errorMessage: r.errorMessage)
                },
                binData: card.binData.map { b in
                    .init(bin: b.bin, scheme: b.scheme, type: b.type, category: b.category, issuer: b.issuer, country: b.country, countryCode: b.countryCode, isLoaded: b.isLoaded)
                }
            )
        }

        if let loginSettings = LoginPersistenceService.shared.loadSettings() {
            config.loginAppSettings = .init(
                targetSite: loginSettings.targetSite,
                maxConcurrency: loginSettings.maxConcurrency,
                debugMode: loginSettings.debugMode,
                appearanceMode: loginSettings.appearanceMode,
                stealthEnabled: loginSettings.stealthEnabled,
                testTimeout: loginSettings.testTimeout
            )
        }

        if let ppsrSettings = PPSRPersistenceService.shared.loadSettings() {
            var cropExport: ComprehensiveExportConfig.ExportRect?
            if let crop = ppsrSettings.screenshotCropRect, crop != .zero {
                cropExport = .init(x: crop.origin.x, y: crop.origin.y, width: crop.size.width, height: crop.size.height)
            }
            config.ppsrAppSettings = .init(
                email: ppsrSettings.email,
                maxConcurrency: ppsrSettings.maxConcurrency,
                debugMode: ppsrSettings.debugMode,
                appearanceMode: ppsrSettings.appearanceMode,
                useEmailRotation: ppsrSettings.useEmailRotation,
                stealthEnabled: ppsrSettings.stealthEnabled,
                retrySubmitOnFail: ppsrSettings.retrySubmitOnFail,
                cropRect: cropExport
            )
        }

        config.emailRotationList = emailService.emails

        let buttonConfigs = debugButtonService.configs
        config.debugLoginButtonConfigs = buttonConfigs.map { (key, value) in
            .init(urlPattern: key, config: value)
        }

        config.recordedFlows = flowService.loadFlows()

        if let sortRaw = UserDefaults.standard.string(forKey: "ppsr_card_sort_option") {
            config.cardSortOption = sortRaw
        }
        config.cardSortAscending = UserDefaults.standard.bool(forKey: "ppsr_card_sort_ascending")

        if let cropDict = UserDefaults.standard.dictionary(forKey: "login_crop_rect_v1"),
           let x = cropDict["x"] as? Double, let y = cropDict["y"] as? Double,
           let w = cropDict["w"] as? Double, let h = cropDict["h"] as? Double, w > 0, h > 0 {
            config.loginCropRect = .init(x: x, y: y, width: w, height: h)
        }

        let calService = LoginCalibrationService.shared
        if !calService.calibrations.isEmpty {
            config.calibrations = calService.calibrations
        }

        let customTemplates = TemplatePersistenceService.shared.loadCustomTemplates()
        if !customTemplates.isEmpty {
            config.customTemplates = customTemplates
        }

        if let speedProfile = ConcurrentSpeedOptimizer.shared.loadProfile() {
            config.speedProfile = speedProfile
        }

        let nord = NordVPNService.shared
        if !nord.accessKey.isEmpty {
            config.nordVPNAccessKey = nord.accessKey
        }
        if !nord.privateKey.isEmpty {
            config.nordVPNPrivateKey = nord.privateKey
        }

        config.tempDisabledBgCheckEnabled = TempDisabledCheckService.shared.backgroundCheckEnabled

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config), let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{}"
    }

    struct ImportResult {
        var urlsImported: Int = 0
        var proxiesImported: Int = 0
        var vpnImported: Int = 0
        var wgImported: Int = 0
        var dnsImported: Int = 0
        var blacklistImported: Int = 0
        var settingsImported: Bool = false
        var credentialsImported: Int = 0
        var cardsImported: Int = 0
        var emailsImported: Int = 0
        var flowsImported: Int = 0
        var debugConfigsImported: Int = 0
        var loginSettingsImported: Bool = false
        var ppsrSettingsImported: Bool = false
        var calibrationsImported: Int = 0
        var templatesImported: Int = 0
        var speedProfileImported: Bool = false
        var nordKeysImported: Bool = false
        var tempDisabledSettingsImported: Bool = false
        var errors: [String] = []

        var summary: String {
            var parts: [String] = []
            if urlsImported > 0 { parts.append("\(urlsImported) URLs") }
            if proxiesImported > 0 { parts.append("\(proxiesImported) proxies") }
            if vpnImported > 0 { parts.append("\(vpnImported) VPN configs") }
            if wgImported > 0 { parts.append("\(wgImported) WireGuard configs") }
            if dnsImported > 0 { parts.append("\(dnsImported) DNS servers") }
            if blacklistImported > 0 { parts.append("\(blacklistImported) blacklist entries") }
            if credentialsImported > 0 { parts.append("\(credentialsImported) credentials") }
            if cardsImported > 0 { parts.append("\(cardsImported) PPSR cards") }
            if emailsImported > 0 { parts.append("\(emailsImported) emails") }
            if flowsImported > 0 { parts.append("\(flowsImported) recorded flows") }
            if debugConfigsImported > 0 { parts.append("\(debugConfigsImported) button configs") }
            if settingsImported { parts.append("automation settings") }
            if loginSettingsImported { parts.append("login app settings") }
            if ppsrSettingsImported { parts.append("PPSR app settings") }
            if calibrationsImported > 0 { parts.append("\(calibrationsImported) calibrations") }
            if templatesImported > 0 { parts.append("\(templatesImported) templates") }
            if speedProfileImported { parts.append("speed profile") }
            if nordKeysImported { parts.append("NordVPN keys") }
            if tempDisabledSettingsImported { parts.append("temp disabled settings") }
            if parts.isEmpty { return "Nothing imported" }
            return "Imported: " + parts.joined(separator: ", ")
        }
    }

    func importJSON(_ jsonString: String) -> ImportResult {
        var result = ImportResult()

        guard let data = jsonString.data(using: .utf8) else {
            result.errors.append("Invalid text data")
            return result
        }

        let config: ComprehensiveExportConfig
        do {
            config = try JSONDecoder().decode(ComprehensiveExportConfig.self, from: data)
        } catch {
            result.errors.append("JSON parse error: \(error.localizedDescription)")
            return result
        }

        let urlService = LoginURLRotationService.shared
        let proxyService = ProxyRotationService.shared
        let dnsService = PPSRDoHService.shared
        let blacklistService = BlacklistService.shared

        for exportURL in config.joeURLs {
            if urlService.addURL(exportURL.url, forIgnition: false) {
                result.urlsImported += 1
                if !exportURL.enabled {
                    if let found = urlService.joeURLs.first(where: { $0.urlString == exportURL.url }) {
                        urlService.toggleURL(id: found.id, enabled: false)
                    }
                }
            }
        }
        for exportURL in config.ignitionURLs {
            if urlService.addURL(exportURL.url, forIgnition: true) {
                result.urlsImported += 1
                if !exportURL.enabled {
                    if let found = urlService.ignitionURLs.first(where: { $0.urlString == exportURL.url }) {
                        urlService.toggleURL(id: found.id, enabled: false)
                    }
                }
            }
        }

        for ep in config.joeProxies {
            let line = formatProxyLine(ep)
            let report = proxyService.bulkImportSOCKS5(line, for: .joe)
            result.proxiesImported += report.added
        }
        for ep in config.ignitionProxies {
            let line = formatProxyLine(ep)
            let report = proxyService.bulkImportSOCKS5(line, for: .ignition)
            result.proxiesImported += report.added
        }
        for ep in config.ppsrProxies {
            let line = formatProxyLine(ep)
            let report = proxyService.bulkImportSOCKS5(line, for: .ppsr)
            result.proxiesImported += report.added
        }

        for ev in config.joeVPNConfigs {
            if let vpn = OpenVPNConfig.parse(fileName: ev.fileName, content: ev.rawContent) {
                proxyService.importVPNConfig(vpn, for: .joe)
                if !ev.enabled { proxyService.toggleVPNConfig(vpn, target: .joe, enabled: false) }
                result.vpnImported += 1
            }
        }
        for ev in config.ignitionVPNConfigs {
            if let vpn = OpenVPNConfig.parse(fileName: ev.fileName, content: ev.rawContent) {
                proxyService.importVPNConfig(vpn, for: .ignition)
                if !ev.enabled { proxyService.toggleVPNConfig(vpn, target: .ignition, enabled: false) }
                result.vpnImported += 1
            }
        }
        for ev in config.ppsrVPNConfigs {
            if let vpn = OpenVPNConfig.parse(fileName: ev.fileName, content: ev.rawContent) {
                proxyService.importVPNConfig(vpn, for: .ppsr)
                if !ev.enabled { proxyService.toggleVPNConfig(vpn, target: .ppsr, enabled: false) }
                result.vpnImported += 1
            }
        }

        for ew in config.joeWGConfigs {
            if let wg = WireGuardConfig.parse(fileName: ew.fileName, content: ew.rawContent) {
                proxyService.importWGConfig(wg, for: .joe)
                if !ew.enabled { proxyService.toggleWGConfig(wg, target: .joe, enabled: false) }
                result.wgImported += 1
            }
        }
        for ew in config.ignitionWGConfigs {
            if let wg = WireGuardConfig.parse(fileName: ew.fileName, content: ew.rawContent) {
                proxyService.importWGConfig(wg, for: .ignition)
                if !ew.enabled { proxyService.toggleWGConfig(wg, target: .ignition, enabled: false) }
                result.wgImported += 1
            }
        }
        for ew in config.ppsrWGConfigs {
            if let wg = WireGuardConfig.parse(fileName: ew.fileName, content: ew.rawContent) {
                proxyService.importWGConfig(wg, for: .ppsr)
                if !ew.enabled { proxyService.toggleWGConfig(wg, target: .ppsr, enabled: false) }
                result.wgImported += 1
            }
        }

        for ed in config.dnsServers {
            if dnsService.addProvider(name: ed.name, url: ed.url) {
                if !ed.enabled {
                    if let found = dnsService.managedProviders.first(where: { $0.url == ed.url }) {
                        dnsService.toggleProvider(id: found.id, enabled: false)
                    }
                }
                result.dnsImported += 1
            }
        }

        for eb in config.blacklist {
            if !blacklistService.isBlacklisted(eb.email) {
                blacklistService.addToBlacklist(eb.email, reason: eb.reason)
                result.blacklistImported += 1
            }
        }

        if let joeMode = ConnectionMode(rawValue: config.connectionModes.joe) {
            proxyService.setConnectionMode(joeMode, for: .joe)
        }
        if let ignMode = ConnectionMode(rawValue: config.connectionModes.ignition) {
            proxyService.setConnectionMode(ignMode, for: .ignition)
        }
        if let ppsrMode = ConnectionMode(rawValue: config.connectionModes.ppsr) {
            proxyService.setConnectionMode(ppsrMode, for: .ppsr)
        }

        if let region = NetworkRegion(rawValue: config.networkRegion) {
            proxyService.networkRegion = region
        }
        if let unified = ConnectionMode(rawValue: config.unifiedConnectionMode) {
            proxyService.setUnifiedConnectionMode(unified)
        }

        let deviceProxy = DeviceProxyService.shared
        if let ipRouting = config.ipRoutingSettings {
            deviceProxy.ipRoutingMode = .separatePerSession
            if let interval = RotationInterval(rawValue: ipRouting.rotationInterval) {
                deviceProxy.rotationInterval = interval
            }
            deviceProxy.rotateOnBatchStart = ipRouting.rotateOnBatchStart
            deviceProxy.rotateOnFingerprintDetection = ipRouting.rotateOnFingerprintDetection
            deviceProxy.localProxyEnabled = ipRouting.localProxyEnabled
            deviceProxy.autoFailoverEnabled = ipRouting.autoFailoverEnabled
            deviceProxy.healthCheckInterval = ipRouting.healthCheckInterval
            deviceProxy.maxFailuresBeforeRotation = ipRouting.maxFailuresBeforeRotation
            if let mode = IPRoutingMode(rawValue: ipRouting.mode) {
                deviceProxy.ipRoutingMode = mode
            }
        }

        blacklistService.autoExcludeBlacklist = config.settings.autoExcludeBlacklist
        blacklistService.autoBlacklistNoAcc = config.settings.autoBlacklistNoAcc

        if let automation = config.automationSettings {
            if let data = try? JSONEncoder().encode(automation.normalizedTimeouts()) {
                UserDefaults.standard.set(data, forKey: "automation_settings_v1")
                result.settingsImported = true
            }
        }

        if !config.loginCredentials.isEmpty {
            let existingCreds = LoginPersistenceService.shared.loadCredentials()
            let existingIds = Set(existingCreds.map { "\($0.username):\($0.password)" })
            var merged = existingCreds
            for ec in config.loginCredentials {
                let key = "\(ec.username):\(ec.password)"
                guard !existingIds.contains(key) else { continue }
                let cred = LoginCredential(username: ec.username, password: ec.password, id: ec.id, addedAt: Date(timeIntervalSince1970: ec.addedAt))
                if let status = CredentialStatus(rawValue: ec.status) { cred.status = status }
                cred.notes = ec.notes
                cred.assignedPasswords = ec.assignedPasswords
                cred.nextPasswordIndex = ec.nextPasswordIndex
                cred.testResults = ec.testResults.map { r in
                    LoginTestResult(success: r.success, duration: r.duration, errorMessage: r.errorMessage, responseDetail: r.responseDetail, timestamp: Date(timeIntervalSince1970: r.timestamp))
                }
                merged.append(cred)
                result.credentialsImported += 1
            }
            if result.credentialsImported > 0 {
                LoginPersistenceService.shared.saveCredentials(merged)
            }
        }

        if !config.ppsrCards.isEmpty {
            let existingCards = PPSRPersistenceService.shared.loadCards()
            let existingNums = Set(existingCards.map(\.number))
            var merged = existingCards
            for ec in config.ppsrCards {
                guard !existingNums.contains(ec.number) else { continue }
                let card = PPSRCard(number: ec.number, expiryMonth: ec.expiryMonth, expiryYear: ec.expiryYear, cvv: ec.cvv, id: ec.id, addedAt: Date(timeIntervalSince1970: ec.addedAt))
                if let status = CardStatus(rawValue: ec.status) { card.status = status }
                card.testResults = ec.testResults.map { r in
                    PPSRTestResult(success: r.success, vin: r.vin, duration: r.duration, errorMessage: r.errorMessage, timestamp: Date(timeIntervalSince1970: r.timestamp))
                }
                if let bin = ec.binData {
                    card.binData = PPSRBINData(bin: bin.bin, scheme: bin.scheme, type: bin.type, category: bin.category, issuer: bin.issuer, country: bin.country, countryCode: bin.countryCode, isLoaded: bin.isLoaded)
                }
                merged.append(card)
                result.cardsImported += 1
            }
            if result.cardsImported > 0 {
                PPSRPersistenceService.shared.saveCards(merged)
            }
        }

        if let loginSettings = config.loginAppSettings {
            LoginPersistenceService.shared.saveSettings(
                targetSite: loginSettings.targetSite,
                maxConcurrency: loginSettings.maxConcurrency,
                debugMode: loginSettings.debugMode,
                appearanceMode: loginSettings.appearanceMode,
                stealthEnabled: loginSettings.stealthEnabled,
                testTimeout: loginSettings.testTimeout
            )
            result.loginSettingsImported = true
        }

        if let ppsrSettings = config.ppsrAppSettings {
            var cropRect: CGRect = .zero
            if let cr = ppsrSettings.cropRect {
                cropRect = CGRect(x: cr.x, y: cr.y, width: cr.width, height: cr.height)
            }
            PPSRPersistenceService.shared.saveSettings(
                email: ppsrSettings.email,
                maxConcurrency: ppsrSettings.maxConcurrency,
                debugMode: ppsrSettings.debugMode,
                appearanceMode: ppsrSettings.appearanceMode,
                useEmailRotation: ppsrSettings.useEmailRotation,
                stealthEnabled: ppsrSettings.stealthEnabled,
                retrySubmitOnFail: ppsrSettings.retrySubmitOnFail,
                screenshotCropRect: cropRect
            )
            result.ppsrSettingsImported = true
        }

        if !config.emailRotationList.isEmpty {
            let emailService = PPSREmailRotationService.shared
            let existingSet = Set(emailService.emails)
            var added = 0
            for email in config.emailRotationList where !existingSet.contains(email) {
                emailService.emails.append(email)
                added += 1
            }
            result.emailsImported = added
        }

        if !config.debugLoginButtonConfigs.isEmpty {
            let debugService = DebugLoginButtonService.shared
            for ec in config.debugLoginButtonConfigs {
                debugService.saveConfig(ec.config, forURL: ec.urlPattern)
                result.debugConfigsImported += 1
            }
        }

        if !config.recordedFlows.isEmpty {
            let flowService = FlowPersistenceService.shared
            var existingFlows = flowService.loadFlows()
            let existingIds = Set(existingFlows.map(\.id))
            var added = 0
            for flow in config.recordedFlows where !existingIds.contains(flow.id) {
                existingFlows.append(flow)
                added += 1
            }
            if added > 0 {
                flowService.saveFlows(existingFlows)
            }
            result.flowsImported = added
        }

        if let sortOption = config.cardSortOption {
            UserDefaults.standard.set(sortOption, forKey: "ppsr_card_sort_option")
        }
        if let sortAsc = config.cardSortAscending {
            UserDefaults.standard.set(sortAsc, forKey: "ppsr_card_sort_ascending")
        }

        if let loginCrop = config.loginCropRect {
            let dict: [String: Double] = ["x": loginCrop.x, "y": loginCrop.y, "w": loginCrop.width, "h": loginCrop.height]
            UserDefaults.standard.set(dict, forKey: "login_crop_rect_v1")
        }

        if let calibrations = config.calibrations, !calibrations.isEmpty {
            let calService = LoginCalibrationService.shared
            for (key, cal) in calibrations {
                calService.saveCalibration(cal, forURL: "https://\(key)")
                result.calibrationsImported += 1
            }
        }

        if let templates = config.customTemplates, !templates.isEmpty {
            var existing = TemplatePersistenceService.shared.loadCustomTemplates()
            let existingIds = Set(existing.map(\.id))
            var added = 0
            for t in templates where !existingIds.contains(t.id) {
                existing.append(t)
                added += 1
            }
            if added > 0 {
                TemplatePersistenceService.shared.saveTemplates(existing)
            }
            result.templatesImported = added
        }

        if let profile = config.speedProfile {
            ConcurrentSpeedOptimizer.shared.saveProfile(profile)
            result.speedProfileImported = true
        }

        let nord = NordVPNService.shared
        if let accessKey = config.nordVPNAccessKey, !accessKey.isEmpty {
            nord.setAccessKey(accessKey)
            result.nordKeysImported = true
        }
        if let privateKey = config.nordVPNPrivateKey, !privateKey.isEmpty {
            nord.setPrivateKey(privateKey)
            result.nordKeysImported = true
        }

        if let bgCheck = config.tempDisabledBgCheckEnabled {
            TempDisabledCheckService.shared.backgroundCheckEnabled = bgCheck
            result.tempDisabledSettingsImported = true
        }

        return result
    }

    private func formatProxyLine(_ ep: ComprehensiveExportConfig.ExportProxy) -> String {
        if let u = ep.username, let p = ep.password {
            return "socks5://\(u):\(p)@\(ep.host):\(ep.port)"
        }
        return "socks5://\(ep.host):\(ep.port)"
    }

    func exportComprehensiveState() -> String {
        var sections: [String] = []

        sections.append(exportHeader())
        sections.append(exportURLState())
        sections.append(exportProxyState())
        sections.append(exportDNSState())
        sections.append(exportVPNState())
        sections.append(exportBlacklistState())
        sections.append(exportSettingsState())

        return sections.joined(separator: "\n\n")
    }

    private func exportHeader() -> String {
        return """
        ========================================
        APP STATE EXPORT
        Generated: \(DateFormatters.exportTimestamp.string(from: Date()))
        ========================================
        """
    }

    private func exportURLState() -> String {
        let urlService = LoginURLRotationService.shared
        var lines: [String] = ["--- JOE FORTUNE URLs ---"]
        for url in urlService.joeURLs {
            let status = url.isEnabled ? "ENABLED" : "DISABLED"
            let stats = url.totalAttempts > 0 ? " | \(url.formattedSuccessRate) success | \(url.formattedAvgResponse) avg" : ""
            lines.append("[\(status)] \(url.urlString)\(stats)")
        }
        lines.append("")
        lines.append("--- IGNITION URLs ---")
        for url in urlService.ignitionURLs {
            let status = url.isEnabled ? "ENABLED" : "DISABLED"
            let stats = url.totalAttempts > 0 ? " | \(url.formattedSuccessRate) success | \(url.formattedAvgResponse) avg" : ""
            lines.append("[\(status)] \(url.urlString)\(stats)")
        }
        return lines.joined(separator: "\n")
    }

    private func exportProxyState() -> String {
        let proxyService = ProxyRotationService.shared
        var lines: [String] = ["--- PROXIES ---"]

        lines.append("Joe Fortune (\(proxyService.savedProxies.count)):")
        for proxy in proxyService.savedProxies {
            let status = proxy.isWorking ? "OK" : (proxy.lastTested != nil ? "DEAD" : "UNTESTED")
            lines.append("  [\(status)] \(proxy.displayString)")
        }

        lines.append("Ignition (\(proxyService.ignitionProxies.count)):")
        for proxy in proxyService.ignitionProxies {
            let status = proxy.isWorking ? "OK" : (proxy.lastTested != nil ? "DEAD" : "UNTESTED")
            lines.append("  [\(status)] \(proxy.displayString)")
        }

        lines.append("PPSR (\(proxyService.ppsrProxies.count)):")
        for proxy in proxyService.ppsrProxies {
            let status = proxy.isWorking ? "OK" : (proxy.lastTested != nil ? "DEAD" : "UNTESTED")
            lines.append("  [\(status)] \(proxy.displayString)")
        }

        return lines.joined(separator: "\n")
    }

    private func exportDNSState() -> String {
        let dnsService = PPSRDoHService.shared
        var lines: [String] = ["--- DNS SERVERS ---"]
        for provider in dnsService.managedProviders {
            let status = provider.isEnabled ? "ENABLED" : "DISABLED"
            let def = provider.isDefault ? " (DEFAULT)" : ""
            lines.append("[\(status)] \(provider.name)\(def) - \(provider.url)")
        }
        return lines.joined(separator: "\n")
    }

    private func exportVPNState() -> String {
        let proxyService = ProxyRotationService.shared
        var lines: [String] = ["--- OPENVPN CONFIGS ---"]

        lines.append("Joe Fortune (\(proxyService.joeVPNConfigs.count)):")
        for vpn in proxyService.joeVPNConfigs {
            let status = vpn.isEnabled ? "ENABLED" : "DISABLED"
            lines.append("  [\(status)] \(vpn.fileName) - \(vpn.displayString)")
        }

        lines.append("Ignition (\(proxyService.ignitionVPNConfigs.count)):")
        for vpn in proxyService.ignitionVPNConfigs {
            let status = vpn.isEnabled ? "ENABLED" : "DISABLED"
            lines.append("  [\(status)] \(vpn.fileName) - \(vpn.displayString)")
        }

        lines.append("PPSR (\(proxyService.ppsrVPNConfigs.count)):")
        for vpn in proxyService.ppsrVPNConfigs {
            let status = vpn.isEnabled ? "ENABLED" : "DISABLED"
            lines.append("  [\(status)] \(vpn.fileName) - \(vpn.displayString)")
        }

        lines.append("")
        lines.append("--- WIREGUARD CONFIGS ---")

        lines.append("Joe Fortune (\(proxyService.joeWGConfigs.count)):")
        for wg in proxyService.joeWGConfigs {
            let status = wg.isEnabled ? "ENABLED" : "DISABLED"
            lines.append("  [\(status)] \(wg.fileName) - \(wg.displayString)")
        }

        lines.append("Ignition (\(proxyService.ignitionWGConfigs.count)):")
        for wg in proxyService.ignitionWGConfigs {
            let status = wg.isEnabled ? "ENABLED" : "DISABLED"
            lines.append("  [\(status)] \(wg.fileName) - \(wg.displayString)")
        }

        lines.append("PPSR (\(proxyService.ppsrWGConfigs.count)):")
        for wg in proxyService.ppsrWGConfigs {
            let status = wg.isEnabled ? "ENABLED" : "DISABLED"
            lines.append("  [\(status)] \(wg.fileName) - \(wg.displayString)")
        }

        return lines.joined(separator: "\n")
    }

    private func exportBlacklistState() -> String {
        let blacklistService = BlacklistService.shared
        var lines: [String] = ["--- BLACKLIST (\(blacklistService.blacklistedEmails.count)) ---"]
        for entry in blacklistService.blacklistedEmails {
            lines.append("\(entry.email) | \(entry.reason) | \(entry.formattedDate)")
        }
        return lines.joined(separator: "\n")
    }

    private func exportSettingsState() -> String {
        let urlService = LoginURLRotationService.shared
        let proxyService = ProxyRotationService.shared
        let blacklistService = BlacklistService.shared
        var lines: [String] = ["--- SETTINGS ---"]
        lines.append("URL Rotation Mode: \(urlService.isIgnitionMode ? "Ignition" : "Joe")")
        lines.append("Joe Enabled URLs: \(urlService.joeURLs.filter(\.isEnabled).count)/\(urlService.joeURLs.count)")
        lines.append("Ignition Enabled URLs: \(urlService.ignitionURLs.filter(\.isEnabled).count)/\(urlService.ignitionURLs.count)")
        lines.append("Joe Connection: \(proxyService.joeConnectionMode.label)")
        lines.append("Ignition Connection: \(proxyService.ignitionConnectionMode.label)")
        lines.append("PPSR Connection: \(proxyService.ppsrConnectionMode.label)")
        lines.append("Unified Connection: \(proxyService.unifiedConnectionMode.label)\nIP Routing: \(DeviceProxyService.shared.ipRoutingMode.label)")
        lines.append("Network Region: \(proxyService.networkRegion.label)")
        lines.append("Auto-Exclude Blacklist: \(blacklistService.autoExcludeBlacklist)")
        lines.append("Auto-Blacklist No Acc: \(blacklistService.autoBlacklistNoAcc)")
        return lines.joined(separator: "\n")
    }

    func exportTestingHistory(credentials: [LoginCredential]) -> String {
        var lines: [String] = ["--- TESTING HISTORY ---"]
        lines.append("Generated: \(DateFormatters.exportTimestamp.string(from: Date()))")
        lines.append("Total Credentials: \(credentials.count)")
        lines.append("")

        for cred in credentials {
            lines.append("\(cred.username) | Status: \(cred.status.rawValue) | Tests: \(cred.totalTests) | Success: \(cred.successCount)")
            for result in cred.testResults {
                let icon = result.success ? "✓" : "✗"
                let detail = result.responseDetail ?? result.errorMessage ?? ""
                lines.append("  \(icon) \(DateFormatters.exportTimestamp.string(from: result.timestamp)) | \(result.formattedDuration) | \(detail)")
            }
            if !cred.testResults.isEmpty { lines.append("") }
        }
        return lines.joined(separator: "\n")
    }

    func exportURLHistory() -> String {
        let urlService = LoginURLRotationService.shared
        var lines: [String] = ["--- URL PERFORMANCE HISTORY ---"]

        lines.append("\nJoe Fortune URLs:")
        for url in urlService.joeURLs.sorted(by: { $0.performanceScore > $1.performanceScore }) {
            lines.append("  \(url.urlString)")
            lines.append("    Enabled: \(url.isEnabled) | Attempts: \(url.totalAttempts) | Success: \(url.formattedSuccessRate) | Avg: \(url.formattedAvgResponse) | Fails: \(url.failCount)")
        }

        lines.append("\nIgnition URLs:")
        for url in urlService.ignitionURLs.sorted(by: { $0.performanceScore > $1.performanceScore }) {
            lines.append("  \(url.urlString)")
            lines.append("    Enabled: \(url.isEnabled) | Attempts: \(url.totalAttempts) | Success: \(url.formattedSuccessRate) | Avg: \(url.formattedAvgResponse) | Fails: \(url.failCount)")
        }

        return lines.joined(separator: "\n")
    }

    func exportDataSummary() -> (credentials: Int, cards: Int, urls: Int, proxies: Int, vpns: Int, wgs: Int, dns: Int, blacklist: Int, emails: Int, flows: Int, buttonConfigs: Int) {
        let urlService = LoginURLRotationService.shared
        let proxyService = ProxyRotationService.shared
        let dnsService = PPSRDoHService.shared
        let blacklistService = BlacklistService.shared
        let emailService = PPSREmailRotationService.shared
        let flowService = FlowPersistenceService.shared
        let debugService = DebugLoginButtonService.shared

        return (
            credentials: LoginPersistenceService.shared.loadCredentials().count,
            cards: PPSRPersistenceService.shared.loadCards().count,
            urls: urlService.joeURLs.count + urlService.ignitionURLs.count,
            proxies: proxyService.savedProxies.count + proxyService.ignitionProxies.count + proxyService.ppsrProxies.count,
            vpns: proxyService.joeVPNConfigs.count,
            wgs: proxyService.joeWGConfigs.count,
            dns: dnsService.managedProviders.count,
            blacklist: blacklistService.blacklistedEmails.count,
            emails: emailService.emails.count,
            flows: flowService.loadFlows().count,
            buttonConfigs: debugService.configs.count
        )
    }
}
