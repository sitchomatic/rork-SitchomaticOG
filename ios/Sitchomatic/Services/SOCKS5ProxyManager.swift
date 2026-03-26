import Foundation

@MainActor
class SOCKS5ProxyManager {
    private let proxyService = ProxyRotationService.shared

    var joeProxies: [ProxyConfig] { proxyService.savedProxies }
    var ignitionProxies: [ProxyConfig] { proxyService.ignitionProxies }
    var ppsrProxies: [ProxyConfig] { proxyService.ppsrProxies }

    func loadAll() {}

    func proxies(for target: ProxyRotationService.ProxyTarget) -> [ProxyConfig] {
        proxyService.proxies(for: target)
    }

    func nextWorkingProxy(for target: ProxyRotationService.ProxyTarget) -> ProxyConfig? {
        proxyService.nextWorkingProxy(for: target)
    }

    func bulkImport(_ text: String, for target: ProxyRotationService.ProxyTarget) -> ProxyRotationService.ImportReport {
        proxyService.bulkImportSOCKS5(text, for: target)
    }

    func markWorking(_ proxy: ProxyConfig) {
        proxyService.markProxyWorking(proxy)
    }

    func markFailed(_ proxy: ProxyConfig) {
        proxyService.markProxyFailed(proxy)
    }

    func removeProxy(_ proxy: ProxyConfig, target: ProxyRotationService.ProxyTarget) {
        proxyService.removeProxy(proxy, target: target)
    }

    func removeAll(target: ProxyRotationService.ProxyTarget) {
        proxyService.removeAll(target: target)
    }

    func removeDead(target: ProxyRotationService.ProxyTarget) {
        proxyService.removeDead(target: target)
    }

    func resetAllStatus(target: ProxyRotationService.ProxyTarget) {
        proxyService.resetAllStatus(target: target)
    }

    func syncAcrossTargets() {
        proxyService.syncProxiesAcrossTargets()
    }

    func exportProxies(target: ProxyRotationService.ProxyTarget) -> String {
        proxyService.exportProxies(target: target)
    }

    func applyTestResult(proxyId: UUID, working: Bool, target: ProxyRotationService.ProxyTarget) {
        if working {
            if let proxy = proxyService.proxies(for: target).first(where: { $0.id == proxyId }) {
                proxyService.markProxyWorking(proxy)
            }
        } else {
            if let proxy = proxyService.proxies(for: target).first(where: { $0.id == proxyId }) {
                proxyService.markProxyFailed(proxy)
            }
        }
    }

    func persistAll() {}

    func resetRotationIndexes() {
        proxyService.resetRotationIndexes()
    }

    nonisolated func testSingleProxy(_ proxy: ProxyConfig) async -> Bool {
        await ProxyRotationService.shared.testSingleProxy(proxy)
    }

    func persist(for target: ProxyRotationService.ProxyTarget) {}
}
