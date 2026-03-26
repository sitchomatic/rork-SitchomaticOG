import Foundation
import UIKit
import Vision

@MainActor
class HostFingerprintLearningService {
    static let shared = HostFingerprintLearningService()

    private let logger = DebugLogger.shared
    private let persistKey = "host_fingerprint_learning_v1"
    private var signatures: [String: PageSignature] = [:]

    init() {
        loadSignatures()
    }

    nonisolated struct PageSignature: Codable, Sendable {
        var host: String = ""
        var domStructureHash: Int = 0
        var formFieldCount: Int = 0
        var hasPasswordField: Bool = false
        var hasEmailField: Bool = false
        var buttonCount: Int = 0
        var inputTypes: [String] = []
        var pageFramework: String?
        var cssClassPatterns: [String] = []
        var lastUpdated: Date = .distantPast
        var matchedPatterns: [String: Int] = [:]
        var bestPattern: String?
        var captureCount: Int = 0

        var isStale: Bool {
            Date().timeIntervalSince(lastUpdated) > 86400 * 7
        }

        func similarityScore(to other: PageSignature) -> Double {
            var score = 0.0
            var checks = 0.0

            checks += 1
            if domStructureHash == other.domStructureHash && domStructureHash != 0 {
                score += 1.0
            }

            checks += 1
            if formFieldCount == other.formFieldCount { score += 0.5 }
            else if abs(formFieldCount - other.formFieldCount) <= 1 { score += 0.25 }

            checks += 1
            if hasPasswordField == other.hasPasswordField { score += 0.5 }

            checks += 1
            if hasEmailField == other.hasEmailField { score += 0.5 }

            checks += 1
            if buttonCount == other.buttonCount { score += 0.3 }

            checks += 1
            let commonTypes = Set(inputTypes).intersection(Set(other.inputTypes))
            let allTypes = Set(inputTypes).union(Set(other.inputTypes))
            if !allTypes.isEmpty {
                score += Double(commonTypes.count) / Double(allTypes.count) * 0.5
            }

            checks += 1
            if pageFramework == other.pageFramework && pageFramework != nil {
                score += 0.5
            }

            checks += 1
            let commonCSS = Set(cssClassPatterns).intersection(Set(other.cssClassPatterns))
            let allCSS = Set(cssClassPatterns).union(Set(other.cssClassPatterns))
            if !allCSS.isEmpty {
                score += Double(commonCSS.count) / Double(allCSS.count) * 0.7
            }

            return checks > 0 ? score / checks : 0
        }
    }

    func captureSignature(from session: LoginSiteWebSession, host: String) async -> PageSignature? {
        let probeJS = """
        (function(){
            var forms = document.querySelectorAll('form');
            var inputs = document.querySelectorAll('input:not([type="hidden"])');
            var buttons = document.querySelectorAll('button, input[type="submit"], [role="button"]');
            var passFields = document.querySelectorAll('input[type="password"]');
            var emailFields = document.querySelectorAll('input[type="email"], input[name*="email"], input[id*="email"]');
            var types = [];
            for (var i = 0; i < inputs.length; i++) { types.push(inputs[i].type || 'text'); }
            var framework = 'unknown';
            if (window.__REACT_DEVTOOLS_GLOBAL_HOOK__) framework = 'react';
            else if (window.angular || document.querySelector('[ng-app]')) framework = 'angular';
            else if (window.Vue) framework = 'vue';
            else if (window.jQuery) framework = 'jquery';
            var classes = [];
            var allEls = document.querySelectorAll('[class]');
            var classSet = {};
            for (var j = 0; j < Math.min(allEls.length, 100); j++) {
                var cls = allEls[j].className;
                if (typeof cls === 'string') {
                    var parts = cls.split(/\\s+/);
                    for (var k = 0; k < parts.length; k++) {
                        var base = parts[k].replace(/[-_]\\d+/g, '').replace(/[0-9]+/g, '');
                        if (base.length > 2 && base.length < 30) classSet[base] = 1;
                    }
                }
            }
            classes = Object.keys(classSet).slice(0, 20);
            var structHash = document.body ? document.body.innerHTML.length : 0;
            structHash = structHash ^ (forms.length * 17) ^ (inputs.length * 31) ^ (buttons.length * 47);
            return JSON.stringify({
                formCount: forms.length,
                inputCount: inputs.length,
                buttonCount: buttons.length,
                passCount: passFields.length,
                emailCount: emailFields.length,
                types: types,
                framework: framework,
                classes: classes,
                structHash: structHash
            });
        })()
        """

        guard let resultStr = await session.executeJS(probeJS),
              let data = resultStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var sig = PageSignature()
        sig.host = host
        sig.formFieldCount = json["inputCount"] as? Int ?? 0
        sig.hasPasswordField = (json["passCount"] as? Int ?? 0) > 0
        sig.hasEmailField = (json["emailCount"] as? Int ?? 0) > 0
        sig.buttonCount = json["buttonCount"] as? Int ?? 0
        sig.inputTypes = json["types"] as? [String] ?? []
        sig.pageFramework = json["framework"] as? String
        sig.cssClassPatterns = json["classes"] as? [String] ?? []
        sig.domStructureHash = json["structHash"] as? Int ?? 0
        sig.lastUpdated = Date()
        sig.captureCount += 1

        if let existing = signatures[host] {
            sig.matchedPatterns = existing.matchedPatterns
            sig.bestPattern = existing.bestPattern
        }

        signatures[host] = sig
        persistSignatures()

        logger.log("HostFingerprint: captured signature for \(host) — fields=\(sig.formFieldCount) pass=\(sig.hasPasswordField) btn=\(sig.buttonCount) fw=\(sig.pageFramework ?? "unknown")", category: .automation, level: .debug)

        return sig
    }

    func recordPatternOutcome(host: String, pattern: String, success: Bool) {
        guard var sig = signatures[host] else { return }
        sig.matchedPatterns[pattern, default: 0] += success ? 1 : -1
        let best = sig.matchedPatterns.max(by: { $0.value < $1.value })
        sig.bestPattern = best?.key
        sig.lastUpdated = Date()
        signatures[host] = sig
        persistSignatures()
    }

    func bestPatternForHost(_ host: String) -> String? {
        signatures[host]?.bestPattern
    }

    func findSimilarHost(to host: String) -> (host: String, similarity: Double, bestPattern: String?)? {
        guard let targetSig = signatures[host] else { return nil }

        var bestMatch: (String, Double, String?)? = nil
        for (otherHost, otherSig) in signatures where otherHost != host {
            let sim = targetSig.similarityScore(to: otherSig)
            if sim > 0.6, sim > (bestMatch?.1 ?? 0) {
                bestMatch = (otherHost, sim, otherSig.bestPattern)
            }
        }
        return bestMatch
    }

    func suggestPattern(for host: String) -> String? {
        if let direct = bestPatternForHost(host) { return direct }
        if let similar = findSimilarHost(to: host) {
            logger.log("HostFingerprint: no direct pattern for \(host), using similar host \(similar.host) (similarity: \(String(format: "%.0f%%", similar.similarity * 100)))", category: .automation, level: .info)
            return similar.bestPattern
        }
        return nil
    }

    func signatureFor(_ host: String) -> PageSignature? {
        signatures[host]
    }

    func allSignatures() -> [PageSignature] {
        Array(signatures.values).sorted { $0.lastUpdated > $1.lastUpdated }
    }

    func clearAll() {
        signatures.removeAll()
        persistSignatures()
        logger.log("HostFingerprint: all signatures cleared", category: .automation, level: .info)
    }

    private func persistSignatures() {
        if let data = try? JSONEncoder().encode(signatures) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
    }

    private func loadSignatures() {
        if let data = UserDefaults.standard.data(forKey: persistKey),
           let decoded = try? JSONDecoder().decode([String: PageSignature].self, from: data) {
            signatures = decoded
        }
    }
}
