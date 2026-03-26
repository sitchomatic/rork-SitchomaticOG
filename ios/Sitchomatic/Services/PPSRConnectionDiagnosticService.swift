import Foundation

nonisolated struct DiagnosticStep: Identifiable, Sendable {
    let id: UUID
    let name: String
    let status: StepStatus
    let detail: String
    let latencyMs: Int?

    nonisolated enum StepStatus: String, Sendable {
        case pending = "Pending"
        case running = "Running"
        case passed = "Passed"
        case failed = "Failed"
        case warning = "Warning"
    }

    init(name: String, status: StepStatus, detail: String, latencyMs: Int? = nil) {
        self.id = UUID()
        self.name = name
        self.status = status
        self.detail = detail
        self.latencyMs = latencyMs
    }
}

nonisolated struct DiagnosticReport: Sendable {
    let steps: [DiagnosticStep]
    let overallHealthy: Bool
    let recommendation: String
    let timestamp: Date

    init(steps: [DiagnosticStep], recommendation: String) {
        self.steps = steps
        self.overallHealthy = steps.allSatisfy { $0.status == .passed || $0.status == .warning }
        self.recommendation = recommendation
        self.timestamp = Date()
    }
}

@MainActor
class PPSRConnectionDiagnosticService {
    static let shared = PPSRConnectionDiagnosticService()

    private let targetHost = "transact.ppsr.gov.au"
    private let targetURL = URL(string: "https://transact.ppsr.gov.au/CarCheck/")!
    private let logger = DebugLogger.shared

    var isRunning: Bool = false
    var currentStepName: String = ""
    var steps: [DiagnosticStep] = []

    func runFullDiagnostic() async -> DiagnosticReport {
        isRunning = true
        steps = []
        var allSteps: [DiagnosticStep] = []
        logger.startSession("ppsr_diag", category: .network, message: "PPSR Diagnostic: starting full diagnostic")

        let internetStep = await testInternetConnectivity()
        allSteps.append(internetStep)
        steps = allSteps

        guard internetStep.status != .failed else {
            let report = DiagnosticReport(steps: allSteps, recommendation: "No internet connection detected. Check Wi-Fi or cellular data and try again.")
            isRunning = false
            return report
        }

        let dnsStep = await testDNSResolution()
        allSteps.append(dnsStep)
        steps = allSteps

        let dohStep = await testDoHResolution()
        allSteps.append(dohStep)
        steps = allSteps

        let httpStep = await testHTTPReachability()
        allSteps.append(httpStep)
        steps = allSteps

        guard httpStep.status != .failed else {
            let report = DiagnosticReport(steps: allSteps, recommendation: "PPSR server is unreachable via HTTPS. The server may be down, under maintenance, or blocking your IP. Try switching networks or enabling a VPN.")
            isRunning = false
            return report
        }

        let sslStep = await testSSLCertificate()
        allSteps.append(sslStep)
        steps = allSteps

        let contentStep = await testPageContent()
        allSteps.append(contentStep)
        steps = allSteps

        let altDNSStep = await testAlternativeDNS()
        allSteps.append(altDNSStep)
        steps = allSteps

        let recommendation = generateRecommendation(steps: allSteps)
        let report = DiagnosticReport(steps: allSteps, recommendation: recommendation)
        isRunning = false
        let passedCount = allSteps.filter { $0.status == .passed }.count
        let failedCount = allSteps.filter { $0.status == .failed }.count
        logger.endSession("ppsr_diag", category: .network, message: "PPSR Diagnostic: complete — \(passedCount) passed, \(failedCount) failed", level: failedCount == 0 ? .success : (passedCount > 0 ? .warning : .error))
        return report
    }

    func quickHealthCheck() async -> (healthy: Bool, detail: String) {
        let start = Date()
        logger.startTimer(key: "ppsr_health")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: targetURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await session.data(for: request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            _ = logger.stopTimer(key: "ppsr_health")
            if let http = response as? HTTPURLResponse {
                if http.statusCode >= 200 && http.statusCode < 400 {
                    logger.log("PPSR health: OK (\(http.statusCode)) in \(latency)ms", category: .network, level: .success, durationMs: latency)
                    return (true, "OK (\(http.statusCode)) in \(latency)ms")
                } else {
                    logger.log("PPSR health: FAIL HTTP \(http.statusCode) in \(latency)ms", category: .network, level: .error, durationMs: latency)
                    return (false, "HTTP \(http.statusCode) in \(latency)ms")
                }
            }
            return (true, "Response received in \(latency)ms")
        } catch {
            _ = logger.stopTimer(key: "ppsr_health")
            logger.logError("PPSR health: network error", error: error, category: .network)
            return (false, error.localizedDescription)
        }
    }

    private func testInternetConnectivity() async -> DiagnosticStep {
        currentStepName = "Internet Connectivity"
        let start = Date()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let testURLs = [
            URL(string: "https://www.apple.com")!,
            URL(string: "https://www.google.com")!,
            URL(string: "https://1.1.1.1")!,
        ]

        for testURL in testURLs {
            var request = URLRequest(url: testURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
            request.httpMethod = "HEAD"
            do {
                let (_, response) = try await session.data(for: request)
                let latency = Int(Date().timeIntervalSince(start) * 1000)
                if let http = response as? HTTPURLResponse, http.statusCode < 400 {
                    return DiagnosticStep(name: "Internet Connectivity", status: .passed, detail: "Connected via \(testURL.host ?? "unknown") (\(http.statusCode))", latencyMs: latency)
                }
            } catch {
                continue
            }
        }

        return DiagnosticStep(name: "Internet Connectivity", status: .failed, detail: "Cannot reach Apple, Google, or Cloudflare — no internet connection")
    }

    private func testDNSResolution() async -> DiagnosticStep {
        currentStepName = "System DNS"
        let start = Date()
        let hostName = targetHost

        let result: (addresses: Int, success: Bool) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let host = CFHostCreateWithName(nil, hostName as CFString).takeRetainedValue()
                var resolved = DarwinBoolean(false)
                CFHostStartInfoResolution(host, .addresses, nil)
                if let addresses = CFHostGetAddressing(host, &resolved)?.takeUnretainedValue() as? [Data], !addresses.isEmpty {
                    continuation.resume(returning: (addresses.count, true))
                } else {
                    continuation.resume(returning: (0, false))
                }
            }
        }

        let latency = Int(Date().timeIntervalSince(start) * 1000)

        guard result.success else {
            return DiagnosticStep(name: "System DNS", status: .failed, detail: "System DNS cannot resolve \(targetHost) — DNS may be blocked or misconfigured", latencyMs: latency)
        }
        return DiagnosticStep(name: "System DNS", status: .passed, detail: "Resolved \(targetHost) via system DNS (\(result.addresses) address(es))", latencyMs: latency)
    }

    private func testDoHResolution() async -> DiagnosticStep {
        currentStepName = "DoH DNS"
        let doh = PPSRDoHService.shared

        var successCount = 0
        var failCount = 0
        var bestLatency = Int.max
        var bestProvider = ""

        for provider in doh.providers.prefix(5) {
            if let answer = await doh.resolve(hostname: targetHost, using: provider) {
                successCount += 1
                if answer.latencyMs < bestLatency {
                    bestLatency = answer.latencyMs
                    bestProvider = answer.provider
                }
            } else {
                failCount += 1
            }
        }

        if successCount == 0 {
            return DiagnosticStep(name: "DoH DNS", status: .failed, detail: "All 5 DoH providers failed to resolve \(targetHost)")
        } else if failCount > 0 {
            return DiagnosticStep(name: "DoH DNS", status: .warning, detail: "\(successCount)/5 providers succeeded. Best: \(bestProvider) (\(bestLatency)ms).", latencyMs: bestLatency)
        } else {
            return DiagnosticStep(name: "DoH DNS", status: .passed, detail: "All 5 DoH providers resolved successfully. Best: \(bestProvider) (\(bestLatency)ms)", latencyMs: bestLatency)
        }
    }

    private func testHTTPReachability() async -> DiagnosticStep {
        currentStepName = "HTTPS Reachability"
        let start = Date()

        var request = URLRequest(url: targetURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)

            if let http = response as? HTTPURLResponse {
                if http.statusCode >= 200 && http.statusCode < 300 {
                    return DiagnosticStep(name: "HTTPS Reachability", status: .passed, detail: "HTTP \(http.statusCode) — \(data.count) bytes received", latencyMs: latency)
                } else if http.statusCode >= 300 && http.statusCode < 400 {
                    let location = http.value(forHTTPHeaderField: "Location") ?? "unknown"
                    return DiagnosticStep(name: "HTTPS Reachability", status: .warning, detail: "HTTP \(http.statusCode) redirect to \(location)", latencyMs: latency)
                } else if http.statusCode == 403 {
                    return DiagnosticStep(name: "HTTPS Reachability", status: .failed, detail: "HTTP 403 Forbidden — server is blocking requests.", latencyMs: latency)
                } else if http.statusCode == 503 {
                    return DiagnosticStep(name: "HTTPS Reachability", status: .failed, detail: "HTTP 503 Service Unavailable — server is likely under maintenance", latencyMs: latency)
                } else {
                    return DiagnosticStep(name: "HTTPS Reachability", status: .failed, detail: "HTTP \(http.statusCode)", latencyMs: latency)
                }
            }
            return DiagnosticStep(name: "HTTPS Reachability", status: .warning, detail: "Response received but could not parse HTTP status", latencyMs: latency)
        } catch let error as NSError {
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let detail = classifyURLError(error)
            return DiagnosticStep(name: "HTTPS Reachability", status: .failed, detail: detail, latencyMs: latency)
        }
    }

    private func testSSLCertificate() async -> DiagnosticStep {
        currentStepName = "SSL/TLS"
        let start = Date()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: URL(string: "https://\(targetHost)")!)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (_, response) = try await session.data(for: request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            if let http = response as? HTTPURLResponse {
                return DiagnosticStep(name: "SSL/TLS Certificate", status: .passed, detail: "TLS handshake successful (HTTP \(http.statusCode))", latencyMs: latency)
            }
            return DiagnosticStep(name: "SSL/TLS Certificate", status: .passed, detail: "TLS handshake successful", latencyMs: latency)
        } catch let error as NSError {
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            if error.domain == NSURLErrorDomain && (error.code == NSURLErrorServerCertificateUntrusted || error.code == NSURLErrorServerCertificateHasBadDate || error.code == NSURLErrorServerCertificateHasUnknownRoot) {
                return DiagnosticStep(name: "SSL/TLS Certificate", status: .failed, detail: "SSL certificate error: \(error.localizedDescription)", latencyMs: latency)
            }
            return DiagnosticStep(name: "SSL/TLS Certificate", status: .warning, detail: "SSL check inconclusive: \(error.localizedDescription)", latencyMs: latency)
        }
    }

    private func testPageContent() async -> DiagnosticStep {
        currentStepName = "Page Content"
        let start = Date()

        var request = URLRequest(url: targetURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let html = String(data: data, encoding: .utf8) ?? ""
            let htmlLower = html.lowercased()

            let hasForm = htmlLower.contains("<form") || htmlLower.contains("<input")
            let hasVIN = htmlLower.contains("vin") || htmlLower.contains("vehicle")
            let hasEmail = htmlLower.contains("email")
            let hasCard = htmlLower.contains("card") || htmlLower.contains("payment")
            let hasMaintenance = htmlLower.contains("maintenance") || htmlLower.contains("unavailable")
            let hasCaptcha = htmlLower.contains("captcha") || htmlLower.contains("recaptcha")
            let hasBlocked = htmlLower.contains("blocked") || htmlLower.contains("access denied")

            if hasMaintenance {
                return DiagnosticStep(name: "Page Content", status: .failed, detail: "Page indicates maintenance/unavailability", latencyMs: latency)
            }
            if hasBlocked {
                return DiagnosticStep(name: "Page Content", status: .failed, detail: "Page indicates access is blocked/denied", latencyMs: latency)
            }
            if hasCaptcha {
                return DiagnosticStep(name: "Page Content", status: .warning, detail: "CAPTCHA/challenge detected on page", latencyMs: latency)
            }

            var foundFields: [String] = []
            if hasForm { foundFields.append("form") }
            if hasVIN { foundFields.append("VIN") }
            if hasEmail { foundFields.append("email") }
            if hasCard { foundFields.append("payment") }

            if foundFields.count >= 3 {
                return DiagnosticStep(name: "Page Content", status: .passed, detail: "Page has expected structure: \(foundFields.joined(separator: ", ")) (\(data.count) bytes)", latencyMs: latency)
            } else if !foundFields.isEmpty {
                return DiagnosticStep(name: "Page Content", status: .warning, detail: "Partial page structure: \(foundFields.joined(separator: ", ")) (\(data.count) bytes)", latencyMs: latency)
            } else {
                return DiagnosticStep(name: "Page Content", status: .warning, detail: "No expected fields in HTML source (\(data.count) bytes)", latencyMs: latency)
            }
        } catch {
            return DiagnosticStep(name: "Page Content", status: .failed, detail: "Could not fetch page content: \(error.localizedDescription)")
        }
    }

    private func testAlternativeDNS() async -> DiagnosticStep {
        currentStepName = "Alternative DNS"

        let altResolvers: [(String, String)] = [
            ("Cloudflare", "https://cloudflare-dns.com/dns-query"),
            ("Google", "https://dns.google/dns-query"),
            ("Quad9", "https://dns.quad9.net:5053/dns-query"),
        ]

        var results: [(String, String, Int)] = []
        for (name, url) in altResolvers {
            let provider = DoHProvider(name: name, url: url)
            if let answer = await PPSRDoHService.shared.resolve(hostname: targetHost, using: provider) {
                results.append((name, answer.ip, answer.latencyMs))
            }
        }

        if results.isEmpty {
            return DiagnosticStep(name: "Alternative DNS", status: .failed, detail: "All alternative DNS providers failed")
        }

        let ips = Set(results.map { $0.1 })
        let details = results.map { "\($0.0): \($0.1) (\($0.2)ms)" }.joined(separator: " · ")

        if ips.count == 1 {
            return DiagnosticStep(name: "Alternative DNS", status: .passed, detail: "Consistent resolution: \(details)")
        } else {
            return DiagnosticStep(name: "Alternative DNS", status: .warning, detail: "Inconsistent IPs: \(details)")
        }
    }

    private func classifyURLError(_ error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else {
            return "Error: \(error.localizedDescription)"
        }
        switch error.code {
        case NSURLErrorNotConnectedToInternet:
            return "Device is not connected to the internet"
        case NSURLErrorTimedOut:
            return "Connection timed out"
        case NSURLErrorCannotFindHost:
            return "Cannot find host '\(targetHost)'"
        case NSURLErrorCannotConnectToHost:
            return "Cannot connect to host"
        case NSURLErrorNetworkConnectionLost:
            return "Network connection was lost"
        case NSURLErrorDNSLookupFailed:
            return "DNS lookup failed"
        case NSURLErrorSecureConnectionFailed:
            return "Secure connection failed"
        default:
            return "Network error (\(error.code)): \(error.localizedDescription)"
        }
    }

    private func generateRecommendation(steps: [DiagnosticStep]) -> String {
        let failed = steps.filter { $0.status == .failed }
        let warnings = steps.filter { $0.status == .warning }

        if failed.isEmpty && warnings.isEmpty {
            return "All checks passed. Connection to PPSR is healthy."
        }

        if failed.first(where: { $0.name == "Internet Connectivity" }) != nil {
            return "No internet connection. Connect to Wi-Fi or enable cellular data."
        }

        if failed.first(where: { $0.name == "System DNS" }) != nil {
            if steps.first(where: { $0.name == "DoH DNS" })?.status == .passed {
                return "System DNS is failing but DoH works. Enable Ultra Stealth Mode to use DoH resolution."
            }
            return "DNS resolution is failing. Try switching networks or changing DNS to 1.1.1.1 or 8.8.8.8."
        }

        if let httpFail = failed.first(where: { $0.name == "HTTPS Reachability" }) {
            if httpFail.detail.contains("403") || httpFail.detail.contains("blocked") {
                return "PPSR server is blocking requests. Enable Ultra Stealth Mode and reduce concurrency."
            }
            if httpFail.detail.contains("503") || httpFail.detail.contains("maintenance") {
                return "PPSR server is under maintenance. Wait and try again later."
            }
            return "Cannot reach PPSR server. Try switching networks or waiting."
        }

        if !warnings.isEmpty && failed.isEmpty {
            let warningNames = warnings.map(\.name).joined(separator: ", ")
            return "Connection partially healthy with warnings (\(warningNames)). Consider enabling stealth mode."
        }

        return "Multiple issues detected. Try switching networks, enabling stealth mode, or reducing concurrency."
    }
}
