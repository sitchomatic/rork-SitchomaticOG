import Foundation

@MainActor
class ServiceContainer {
    static let shared = ServiceContainer()

    let proxyRotation: ProxyRotationService
    let networkSessionFactory: NetworkSessionFactory
    let deviceProxy: DeviceProxyService
    let debugLogger: DebugLogger
    let fingerprintValidation: FingerprintValidationService
    let screenshotCache: ScreenshotCacheService

    let socks5Manager: SOCKS5ProxyManager
    let jsBuilder: LoginJSBuilder
    let typingEngine: HumanTypingEngine

    init(
        proxyRotation: ProxyRotationService? = nil,
        networkSessionFactory: NetworkSessionFactory? = nil,
        deviceProxy: DeviceProxyService? = nil,
        debugLogger: DebugLogger? = nil,
        fingerprintValidation: FingerprintValidationService? = nil,
        screenshotCache: ScreenshotCacheService? = nil
    ) {
        self.proxyRotation = proxyRotation ?? .shared
        self.networkSessionFactory = networkSessionFactory ?? .shared
        self.deviceProxy = deviceProxy ?? .shared
        self.debugLogger = debugLogger ?? .shared
        self.fingerprintValidation = fingerprintValidation ?? .shared
        self.screenshotCache = screenshotCache ?? .shared

        self.socks5Manager = SOCKS5ProxyManager()
        self.jsBuilder = LoginJSBuilder()
        self.typingEngine = HumanTypingEngine()
    }
}
