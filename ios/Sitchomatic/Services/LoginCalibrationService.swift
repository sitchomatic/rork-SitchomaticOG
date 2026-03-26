import Foundation

@MainActor
class LoginCalibrationService {
    static let shared = LoginCalibrationService()

    private let persistKey = "LoginCalibrationData_v2"
    private let logger = DebugLogger.shared
    private(set) var calibrations: [String: URLCalibration] = [:]

    nonisolated struct ElementMapping: Codable, Sendable {
        var cssSelector: String
        var fallbackSelectors: [String]
        var coordinates: CGPoint?
        var tagName: String?
        var inputType: String?
        var placeholder: String?
        var ariaLabel: String?
        var nearbyText: String?

        init(cssSelector: String = "", fallbackSelectors: [String] = [], coordinates: CGPoint? = nil, tagName: String? = nil, inputType: String? = nil, placeholder: String? = nil, ariaLabel: String? = nil, nearbyText: String? = nil) {
            self.cssSelector = cssSelector
            self.fallbackSelectors = fallbackSelectors
            self.coordinates = coordinates
            self.tagName = tagName
            self.inputType = inputType
            self.placeholder = placeholder
            self.ariaLabel = ariaLabel
            self.nearbyText = nearbyText
        }
    }

    nonisolated struct URLCalibration: Codable, Sendable {
        var urlPattern: String
        var emailField: ElementMapping?
        var passwordField: ElementMapping?
        var loginButton: ElementMapping?
        var calibratedAt: Date
        var successCount: Int
        var failCount: Int
        var lastSuccess: Date?
        var linkedFlowId: String?
        var domFingerprint: String?
        var pageStructureHash: String?
        var notes: String?

        var isCalibrated: Bool {
            emailField != nil && passwordField != nil && loginButton != nil
        }

        var confidence: Double {
            let total = successCount + failCount
            guard total > 0 else { return 0.5 }
            return Double(successCount) / Double(total)
        }

        init(urlPattern: String, emailField: ElementMapping? = nil, passwordField: ElementMapping? = nil, loginButton: ElementMapping? = nil, calibratedAt: Date = Date(), successCount: Int = 0, failCount: Int = 0, lastSuccess: Date? = nil, linkedFlowId: String? = nil, domFingerprint: String? = nil, pageStructureHash: String? = nil, notes: String? = nil) {
            self.urlPattern = urlPattern
            self.emailField = emailField
            self.passwordField = passwordField
            self.loginButton = loginButton
            self.calibratedAt = calibratedAt
            self.successCount = successCount
            self.failCount = failCount
            self.lastSuccess = lastSuccess
            self.linkedFlowId = linkedFlowId
            self.domFingerprint = domFingerprint
            self.pageStructureHash = pageStructureHash
            self.notes = notes
        }
    }

    init() {
        load()
        pruneStaleCalibrations()
    }

    func calibrationFor(url: String) -> URLCalibration? {
        let host = extractHost(from: url)
        if let exact = calibrations[host] { return exact }
        let baseDomain = extractBaseDomain(from: host)
        for (key, cal) in calibrations {
            if extractBaseDomain(from: key) == baseDomain { return cal }
        }
        return nil
    }

    func saveCalibration(_ cal: URLCalibration, forURL url: String) {
        let host = extractHost(from: url)
        calibrations[host] = cal
        persist()
        logger.log("Calibration: saved for \(host) — email:\(cal.emailField?.cssSelector ?? "nil") pass:\(cal.passwordField?.cssSelector ?? "nil") btn:\(cal.loginButton?.cssSelector ?? "nil")", category: .automation, level: .success)
    }

    func reportSuccess(url: String) {
        let host = extractHost(from: url)
        guard var cal = calibrations[host] else { return }
        cal.successCount += 1
        cal.lastSuccess = Date()
        calibrations[host] = cal
        persist()
    }

    func reportFailure(url: String) {
        let host = extractHost(from: url)
        guard var cal = calibrations[host] else { return }
        cal.failCount += 1
        calibrations[host] = cal
        persist()
    }

    func propagateCalibration(from sourceURL: String, to targetURLs: [String]) {
        guard let source = calibrationFor(url: sourceURL) else { return }
        for targetURL in targetURLs {
            let host = extractHost(from: targetURL)
            if calibrations[host] == nil {
                var copy = source
                copy.urlPattern = host
                copy.successCount = 0
                copy.failCount = 0
                copy.lastSuccess = nil
                calibrations[host] = copy
            }
        }
        persist()
        logger.log("Calibration: propagated from \(extractHost(from: sourceURL)) to \(targetURLs.count) URLs", category: .automation, level: .info)
    }

    func linkFlow(flowId: String, toURL url: String) {
        let host = extractHost(from: url)
        if var cal = calibrations[host] {
            cal.linkedFlowId = flowId
            calibrations[host] = cal
        } else {
            calibrations[host] = URLCalibration(urlPattern: host, linkedFlowId: flowId)
        }
        persist()
    }

    func deleteCalibration(forURL url: String) {
        let host = extractHost(from: url)
        calibrations.removeValue(forKey: host)
        persist()
    }

    func deleteAll() {
        calibrations.removeAll()
        persist()
    }

    var calibratedURLCount: Int { calibrations.filter { $0.value.isCalibrated }.count }
    var totalCalibrations: Int { calibrations.count }

    func buildAdaptiveSelectorsJS(for url: String, fieldType: String) -> String {
        guard let cal = calibrationFor(url: url) else { return "null" }

        let mapping: ElementMapping?
        switch fieldType {
        case "email": mapping = cal.emailField
        case "password": mapping = cal.passwordField
        case "button": mapping = cal.loginButton
        default: mapping = nil
        }

        guard let m = mapping else { return "null" }

        var selectors: [String] = []
        if !m.cssSelector.isEmpty { selectors.append(m.cssSelector) }
        selectors.append(contentsOf: m.fallbackSelectors)

        let selectorJSON = selectors.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" }.joined(separator: ",")

        if let coords = m.coordinates {
            return """
            (function(){
                var selectors = [\(selectorJSON)];
                for (var i = 0; i < selectors.length; i++) {
                    try {
                        var el = document.querySelector(selectors[i]);
                        if (el && !el.disabled && (el.offsetParent !== null || el.offsetWidth > 0)) return el;
                    } catch(e) {}
                }
                var coordEl = document.elementFromPoint(\(Int(coords.x)), \(Int(coords.y)));
                if (coordEl) {
                    var tagName = coordEl.tagName.toLowerCase();
                    if (tagName === 'input' || tagName === 'button' || tagName === 'a' || coordEl.getAttribute('role') === 'button') return coordEl;
                    var nearInput = coordEl.querySelector('input') || coordEl.closest('button') || coordEl.closest('[role="button"]');
                    if (nearInput) return nearInput;
                    return coordEl;
                }
                return null;
            })()
            """
        }

        return """
        (function(){
            var selectors = [\(selectorJSON)];
            for (var i = 0; i < selectors.length; i++) {
                try {
                    var el = document.querySelector(selectors[i]);
                    if (el && !el.disabled) return el;
                } catch(e) {}
            }
            return null;
        })()
        """
    }

    private func extractHost(from url: String) -> String {
        URL(string: url)?.host ?? url
    }

    func pruneStaleCalibrations() {
        let urlRotation = LoginURLRotationService.shared
        let allActiveHosts: Set<String> = Set(
            urlRotation.joeURLs.map { extractHost(from: $0.urlString) } +
            urlRotation.ignitionURLs.map { extractHost(from: $0.urlString) }
        )
        let allBaseDomains: Set<String> = Set(allActiveHosts.map { extractBaseDomain(from: $0) })

        var pruned = 0
        let keys = Array(calibrations.keys)
        for key in keys {
            let baseDomain = extractBaseDomain(from: key)
            guard let cal = calibrations[key] else { continue }
            let isStale = cal.successCount == 0 && cal.failCount == 0 && !cal.isCalibrated
            let isOrphaned = !allBaseDomains.contains(baseDomain)
            if isStale && isOrphaned {
                calibrations.removeValue(forKey: key)
                pruned += 1
            }
        }
        if pruned > 0 {
            persist()
            logger.log("Calibration: pruned \(pruned) stale entries", category: .automation, level: .info)
        }
    }

    private func extractBaseDomain(from host: String) -> String {
        var h = host
        if h.hasPrefix("static.") { h = String(h.dropFirst(7)) }
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        return h
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(calibrations) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let decoded = try? JSONDecoder().decode([String: URLCalibration].self, from: data) else { return }
        calibrations = decoded
    }
}
