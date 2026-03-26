import Foundation

@MainActor
class TaskMetricsCollectionService {
    static let shared = TaskMetricsCollectionService()

    private let logger = DebugLogger.shared
    private var recentMetrics: [NetworkProbeMetrics] = []
    private let maxStoredMetrics: Int = 200

    struct NetworkProbeMetrics {
        let url: String
        let timestamp: Date
        let dnsLookupMs: Int?
        let connectMs: Int?
        let tlsHandshakeMs: Int?
        let firstByteMs: Int?
        let transferMs: Int?
        let totalMs: Int
        let httpStatus: Int?
        let success: Bool
        let errorDomain: String?
        let proxyUsed: String?

        var bottleneck: String {
            guard success else { return errorDomain ?? "unknown_error" }
            if let dns = dnsLookupMs, dns > 2000 { return "dns_slow(\(dns)ms)" }
            if let conn = connectMs, conn > 3000 { return "connect_slow(\(conn)ms)" }
            if let tls = tlsHandshakeMs, tls > 2000 { return "tls_slow(\(tls)ms)" }
            if let fb = firstByteMs, fb > 5000 { return "first_byte_slow(\(fb)ms)" }
            if let tx = transferMs, tx > 5000 { return "transfer_slow(\(tx)ms)" }
            return "ok"
        }
    }

    func probeURL(_ urlString: String, proxyConfig: ProxyConfig? = nil, timeout: TimeInterval = 10) async -> NetworkProbeMetrics {
        guard let url = URL(string: urlString) else {
            return NetworkProbeMetrics(url: urlString, timestamp: Date(), dnsLookupMs: nil, connectMs: nil, tlsHandshakeMs: nil, firstByteMs: nil, transferMs: nil, totalMs: 0, httpStatus: nil, success: false, errorDomain: "invalid_url", proxyUsed: nil)
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout

        if let proxy = proxyConfig {
            var proxyDict: [String: Any] = [
                "SOCKSEnable": 1,
                "SOCKSProxy": proxy.host,
                "SOCKSPort": proxy.port,
            ]
            if let u = proxy.username { proxyDict["SOCKSUser"] = u }
            if let p = proxy.password { proxyDict["SOCKSPassword"] = p }
            config.connectionProxyDictionary = proxyDict
        }

        let delegate = MetricsDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeout
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        let start = Date()

        do {
            let (_, response) = try await session.data(for: request)
            let totalMs = Int(Date().timeIntervalSince(start) * 1000)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode

            let metrics = delegate.collectedMetrics
            let proxyLabel = proxyConfig.map { "\($0.host):\($0.port)" }

            let result = buildMetrics(url: urlString, totalMs: totalMs, httpStatus: httpStatus, success: true, metrics: metrics, proxyUsed: proxyLabel)

            storeMetrics(result)
            return result
        } catch {
            let totalMs = Int(Date().timeIntervalSince(start) * 1000)
            let nsError = error as NSError
            let proxyLabel = proxyConfig.map { "\($0.host):\($0.port)" }

            let result = NetworkProbeMetrics(
                url: urlString,
                timestamp: Date(),
                dnsLookupMs: nil,
                connectMs: nil,
                tlsHandshakeMs: nil,
                firstByteMs: nil,
                transferMs: nil,
                totalMs: totalMs,
                httpStatus: nil,
                success: false,
                errorDomain: "\(nsError.domain):\(nsError.code)",
                proxyUsed: proxyLabel
            )

            storeMetrics(result)
            return result
        }
    }

    func recentBottlenecks() -> [String: Int] {
        var counts: [String: Int] = [:]
        for m in recentMetrics.suffix(50) {
            counts[m.bottleneck, default: 0] += 1
        }
        return counts
    }

    func averageMetrics(last n: Int = 20) -> (avgTotal: Int, avgDns: Int?, avgConnect: Int?, avgTls: Int?, avgFirstByte: Int?) {
        let recent = Array(recentMetrics.suffix(n))
        guard !recent.isEmpty else { return (0, nil, nil, nil, nil) }

        let avgTotal = recent.map(\.totalMs).reduce(0, +) / recent.count
        let dnsValues = recent.compactMap(\.dnsLookupMs)
        let connValues = recent.compactMap(\.connectMs)
        let tlsValues = recent.compactMap(\.tlsHandshakeMs)
        let fbValues = recent.compactMap(\.firstByteMs)

        return (
            avgTotal,
            dnsValues.isEmpty ? nil : dnsValues.reduce(0, +) / dnsValues.count,
            connValues.isEmpty ? nil : connValues.reduce(0, +) / connValues.count,
            tlsValues.isEmpty ? nil : tlsValues.reduce(0, +) / tlsValues.count,
            fbValues.isEmpty ? nil : fbValues.reduce(0, +) / fbValues.count
        )
    }

    func allMetrics() -> [NetworkProbeMetrics] {
        recentMetrics
    }

    func clearAll() {
        recentMetrics.removeAll()
    }

    private func storeMetrics(_ metrics: NetworkProbeMetrics) {
        recentMetrics.append(metrics)
        if recentMetrics.count > maxStoredMetrics {
            recentMetrics.removeFirst(recentMetrics.count - maxStoredMetrics)
        }
        logger.log("TaskMetrics: \(metrics.url) total=\(metrics.totalMs)ms bottleneck=\(metrics.bottleneck) proxy=\(metrics.proxyUsed ?? "none")", category: .network, level: .trace)
    }

    private func buildMetrics(url: String, totalMs: Int, httpStatus: Int?, success: Bool, metrics: URLSessionTaskMetrics?, proxyUsed: String?) -> NetworkProbeMetrics {
        guard let metrics, let txMetrics = metrics.transactionMetrics.first else {
            return NetworkProbeMetrics(url: url, timestamp: Date(), dnsLookupMs: nil, connectMs: nil, tlsHandshakeMs: nil, firstByteMs: nil, transferMs: nil, totalMs: totalMs, httpStatus: httpStatus, success: success, errorDomain: nil, proxyUsed: proxyUsed)
        }

        let dnsMs = intervalMs(from: txMetrics.domainLookupStartDate, to: txMetrics.domainLookupEndDate)
        let connMs = intervalMs(from: txMetrics.connectStartDate, to: txMetrics.connectEndDate)
        let tlsMs = intervalMs(from: txMetrics.secureConnectionStartDate, to: txMetrics.secureConnectionEndDate)
        let fbMs = intervalMs(from: txMetrics.requestStartDate, to: txMetrics.responseStartDate)
        let txMs = intervalMs(from: txMetrics.responseStartDate, to: txMetrics.responseEndDate)

        return NetworkProbeMetrics(url: url, timestamp: Date(), dnsLookupMs: dnsMs, connectMs: connMs, tlsHandshakeMs: tlsMs, firstByteMs: fbMs, transferMs: txMs, totalMs: totalMs, httpStatus: httpStatus, success: success, errorDomain: nil, proxyUsed: proxyUsed)
    }

    private func intervalMs(from start: Date?, to end: Date?) -> Int? {
        guard let s = start, let e = end else { return nil }
        return Int(e.timeIntervalSince(s) * 1000)
    }
}

private final class MetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var _metrics: URLSessionTaskMetrics?
    private let lock = NSLock()

    var collectedMetrics: URLSessionTaskMetrics? {
        lock.lock()
        defer { lock.unlock() }
        return _metrics
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        _metrics = metrics
        lock.unlock()
    }
}
