import Foundation

nonisolated enum TargetHostResolver {
    static func hostname(for target: ProxyRotationService.ProxyTarget) -> String {
        switch target {
        case .joe: "www.joefortune.com"
        case .ignition: "www.ignitioncasino.eu"
        case .ppsr: "ppsr.com.au"
        }
    }
}
