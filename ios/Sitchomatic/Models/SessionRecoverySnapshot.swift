import Foundation

nonisolated struct SessionRecoverySnapshot: Codable, Identifiable, Sendable {
    let id: String
    let credentialId: String
    let username: String
    let targetURL: String
    let chosenPattern: String?
    let retriesUsed: Int
    let maxRetries: Int
    let lastScreenshotHash: String?
    let networkMode: String
    let proxyHost: String?
    let proxyPort: Int?
    let tunnelActive: Bool
    let wireProxyActive: Bool
    let ipRoutingMode: String
    let lastFailureReason: String?
    let lastFailureOutcome: String?
    let sessionIndex: Int
    let batchPosition: Int
    let batchTotal: Int
    let automationSettingsHash: String?
    let createdAt: Date
    let updatedAt: Date

    init(
        id: String = UUID().uuidString,
        credentialId: String,
        username: String,
        targetURL: String,
        chosenPattern: String? = nil,
        retriesUsed: Int = 0,
        maxRetries: Int = 3,
        lastScreenshotHash: String? = nil,
        networkMode: String = "Direct",
        proxyHost: String? = nil,
        proxyPort: Int? = nil,
        tunnelActive: Bool = false,
        wireProxyActive: Bool = false,
        ipRoutingMode: String = "Per-Session",
        lastFailureReason: String? = nil,
        lastFailureOutcome: String? = nil,
        sessionIndex: Int = 0,
        batchPosition: Int = 0,
        batchTotal: Int = 0,
        automationSettingsHash: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.credentialId = credentialId
        self.username = username
        self.targetURL = targetURL
        self.chosenPattern = chosenPattern
        self.retriesUsed = retriesUsed
        self.maxRetries = maxRetries
        self.lastScreenshotHash = lastScreenshotHash
        self.networkMode = networkMode
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.tunnelActive = tunnelActive
        self.wireProxyActive = wireProxyActive
        self.ipRoutingMode = ipRoutingMode
        self.lastFailureReason = lastFailureReason
        self.lastFailureOutcome = lastFailureOutcome
        self.sessionIndex = sessionIndex
        self.batchPosition = batchPosition
        self.batchTotal = batchTotal
        self.automationSettingsHash = automationSettingsHash
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func withUpdate(
        chosenPattern: String? = nil,
        retriesUsed: Int? = nil,
        lastScreenshotHash: String? = nil,
        networkMode: String? = nil,
        proxyHost: String?? = nil,
        proxyPort: Int?? = nil,
        tunnelActive: Bool? = nil,
        wireProxyActive: Bool? = nil,
        lastFailureReason: String?? = nil,
        lastFailureOutcome: String?? = nil
    ) -> SessionRecoverySnapshot {
        SessionRecoverySnapshot(
            id: id,
            credentialId: credentialId,
            username: username,
            targetURL: targetURL,
            chosenPattern: chosenPattern ?? self.chosenPattern,
            retriesUsed: retriesUsed ?? self.retriesUsed,
            maxRetries: maxRetries,
            lastScreenshotHash: lastScreenshotHash ?? self.lastScreenshotHash,
            networkMode: networkMode ?? self.networkMode,
            proxyHost: proxyHost ?? self.proxyHost,
            proxyPort: proxyPort ?? self.proxyPort,
            tunnelActive: tunnelActive ?? self.tunnelActive,
            wireProxyActive: wireProxyActive ?? self.wireProxyActive,
            ipRoutingMode: ipRoutingMode,
            lastFailureReason: lastFailureReason ?? self.lastFailureReason,
            lastFailureOutcome: lastFailureOutcome ?? self.lastFailureOutcome,
            sessionIndex: sessionIndex,
            batchPosition: batchPosition,
            batchTotal: batchTotal,
            automationSettingsHash: automationSettingsHash,
            createdAt: createdAt,
            updatedAt: Date()
        )
    }
}

nonisolated struct SessionRecoveryBatch: Codable, Sendable {
    let batchId: String
    let startedAt: Date
    let snapshots: [SessionRecoverySnapshot]
    let siteMode: String
    let totalCredentials: Int
    let completedCount: Int

    init(
        batchId: String = UUID().uuidString,
        startedAt: Date = Date(),
        snapshots: [SessionRecoverySnapshot] = [],
        siteMode: String = "Joe",
        totalCredentials: Int = 0,
        completedCount: Int = 0
    ) {
        self.batchId = batchId
        self.startedAt = startedAt
        self.snapshots = snapshots
        self.siteMode = siteMode
        self.totalCredentials = totalCredentials
        self.completedCount = completedCount
    }
}
