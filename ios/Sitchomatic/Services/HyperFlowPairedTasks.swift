import Foundation
import WebKit

// MARK: - Paired Task Definitions

/// Maps existing target URLs and scraping logic into the new PairedTask structure.
/// Each pair consists of a primary and secondary URL that share an isolated
/// WKProcessPool and WKWebsiteDataStore.

public enum HyperFlowTaskFactory {

    // MARK: - Allowed Domains

    public static let joefortuneDomains: Set<String> = [
        "joefortune24.com",
        "joefortune36.com",
        "joefortunepokies.win",
        "joefortune.eu",
        "joefortune.club",
        "joefortune.eu.com",
        "joefortune.lv",
        "joefortune.ooo",
        "joefortuneonlinepokies.com",
        "joefortuneonlinepokies.eu",
        "joefortuneonlinepokies.net",
        "joefortunepokies.com",
        "joefortunepokies.eu",
        "joefortunepokies.net",
    ]

    public static let ignitionDomains: Set<String> = [
        "ignitioncasino.eu",
        "ignitioncasino.lat",
        "ignitioncasino.cool",
        "ignitioncasino.fun",
        "ignitioncasino.ooo",
        "ignitioncasino.lv",
        "ignitioncasino.eu.com",
        "ignitioncasino.buzz",
        "ignitionpoker.eu",
        "ignition231.com",
        "ignition165.com",
        "ignition551.com",
    ]

    public static let ppsrDomains: Set<String> = [
        "ppsr.gov.au",
        "transact.ppsr.gov.au",
    ]

    public static let bpointDomains: Set<String> = [
        "bpoint.com.au",
        "www.bpoint.com.au",
    ]

    public static let allAllowedDomains: Set<String> = {
        var all = Set<String>()
        all.formUnion(joefortuneDomains)
        all.formUnion(ignitionDomains)
        all.formUnion(ppsrDomains)
        all.formUnion(bpointDomains)
        return all
    }()

    // MARK: - Standard Viewports

    public static let standardViewport = CGSize(width: 390, height: 844)
    public static let compactViewport = CGSize(width: 375, height: 667)

    // MARK: - Task Builders

    /// Creates a Joe Fortune + Ignition dual-site login test pair.
    public static func loginDualSitePair(
        joeURL: URL? = nil,
        ignitionURL: URL? = nil
    ) -> PairedTask {
        PairedTask(
            typeName: "LoginDualSite",
            primaryURL: joeURL ?? URL(string: "https://joefortunepokies.win/login")!,
            secondaryURL: ignitionURL ?? URL(string: "https://ignitioncasino.ooo/?overlay=login")!,
            primaryViewport: standardViewport,
            secondaryViewport: standardViewport
        )
    }

    /// Creates a PPSR CarCheck pair (primary is the main check page, secondary is verification).
    public static func ppsrCheckPair(
        primaryURL: URL? = nil,
        secondaryURL: URL? = nil
    ) -> PairedTask {
        PairedTask(
            typeName: "PPSRCheck",
            primaryURL: primaryURL ?? URL(string: "https://transact.ppsr.gov.au/CarCheck/")!,
            secondaryURL: secondaryURL ?? URL(string: "https://transact.ppsr.gov.au/CarCheck/")!,
            primaryViewport: standardViewport,
            secondaryViewport: compactViewport
        )
    }

    /// Creates a BPoint payment automation pair.
    public static func bpointPair(
        primaryURL: URL? = nil,
        secondaryURL: URL? = nil
    ) -> PairedTask {
        PairedTask(
            typeName: "BPointPayment",
            primaryURL: primaryURL ?? URL(string: "https://www.bpoint.com.au/pay")!,
            secondaryURL: secondaryURL ?? URL(string: "https://www.bpoint.com.au/pay")!,
            primaryViewport: standardViewport,
            secondaryViewport: compactViewport
        )
    }

    /// Creates a batch of paired tasks for credential testing.
    /// Maps credentials across Joe Fortune and Ignition pairs.
    public static func buildLoginBatch(
        joeURLs: [URL],
        ignitionURLs: [URL],
        count: Int
    ) -> [PairedTask] {
        var tasks: [PairedTask] = []
        for i in 0..<count {
            let joeURL = joeURLs[i % joeURLs.count]
            let ignURL = ignitionURLs[i % ignitionURLs.count]
            tasks.append(PairedTask(
                typeName: "LoginBatch-\(i)",
                primaryURL: joeURL,
                secondaryURL: ignURL,
                primaryViewport: standardViewport,
                secondaryViewport: standardViewport
            ))
        }
        return tasks
    }

    /// Creates tasks for all concurrent PPSR checks.
    public static func buildPPSRBatch(count: Int) -> [PairedTask] {
        (0..<count).map { i in
            PairedTask(
                typeName: "PPSRBatch-\(i)",
                primaryURL: URL(string: "https://transact.ppsr.gov.au/CarCheck/")!,
                secondaryURL: URL(string: "https://transact.ppsr.gov.au/CarCheck/")!,
                primaryViewport: standardViewport,
                secondaryViewport: compactViewport
            )
        }
    }

    /// Domains for a specific task type.
    public static func allowedDomains(for taskType: String) -> Set<String> {
        switch taskType {
        case "LoginDualSite", "LoginBatch":
            return joefortuneDomains.union(ignitionDomains)
        case "PPSRCheck", "PPSRBatch":
            return ppsrDomains
        case "BPointPayment":
            return bpointDomains
        default:
            return allAllowedDomains
        }
    }
}

// MARK: - LoginTargetSite (preserved for backward compatibility)

nonisolated enum LoginTargetSite: String, CaseIterable, Sendable {
    case joefortune = "Joe Fortune"
    case ignition = "Ignition Casino"

    var url: URL {
        switch self {
        case .joefortune: URL(string: "https://joefortunepokies.win/login")!
        case .ignition: URL(string: "https://ignitioncasino.ooo/?overlay=login")!
        }
    }

    var host: String {
        switch self {
        case .joefortune: "joefortunepokies.win"
        case .ignition: "ignitioncasino.ooo"
        }
    }

    var icon: String {
        switch self {
        case .joefortune: "suit.spade.fill"
        case .ignition: "flame.fill"
        }
    }

    var accentColorName: String {
        switch self {
        case .joefortune: "green"
        case .ignition: "orange"
        }
    }
}
