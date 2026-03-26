import Foundation

@MainActor
class WebViewLifetimeBudgetService {
    static let shared = WebViewLifetimeBudgetService()

    private let logger = DebugLogger.shared
    private var navigationCounts: [String: Int] = [:]
    private let maxNavigationsBeforeRecycle: Int = 25
    private(set) var totalRecycles: Int = 0

    func recordNavigation(sessionId: String) -> Bool {
        navigationCounts[sessionId, default: 0] += 1
        let count = navigationCounts[sessionId] ?? 0
        if count >= maxNavigationsBeforeRecycle {
            logger.log("LifetimeBudget: session \(sessionId) hit \(count) navigations — recycle recommended", category: .webView, level: .warning)
            return true
        }
        return false
    }

    func navigationCount(for sessionId: String) -> Int {
        navigationCounts[sessionId] ?? 0
    }

    func shouldRecycle(sessionId: String) -> Bool {
        (navigationCounts[sessionId] ?? 0) >= maxNavigationsBeforeRecycle
    }

    func recycleSession(_ session: LoginSiteWebSession, sessionId: String) async {
        totalRecycles += 1
        navigationCounts.removeValue(forKey: sessionId)
        session.tearDown(wipeAll: true)
        await session.setUp(wipeAll: true)
        logger.log("LifetimeBudget: session \(sessionId) RECYCLED (total recycles: \(totalRecycles))", category: .webView, level: .info)
    }

    func clearSession(_ sessionId: String) {
        navigationCounts.removeValue(forKey: sessionId)
    }

    func resetAll() {
        navigationCounts.removeAll()
        totalRecycles = 0
    }
}
