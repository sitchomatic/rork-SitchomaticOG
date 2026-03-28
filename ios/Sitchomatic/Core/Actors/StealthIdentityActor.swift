import Foundation

// MARK: - Stealth Identity Actor

/// Manages randomized identity seeds for WebView anti-fingerprinting.
///
/// Each concurrent WebView session requires unique canvas noise, audio
/// context perturbation, and hardware spoofing seeds. This actor ensures
/// seeds are generated once per session and never reused across WebViews,
/// preventing cross-tab fingerprint correlation by anti-bot systems.
///
/// Replaces the ad-hoc seed generation previously scattered across
/// `PPSRStealthService`, `FingerprintValidationService`, and
/// `AntiBotDetectionService`.
public actor StealthIdentityActor {
    public static let shared = StealthIdentityActor()

    // MARK: - Identity Profile

    /// A complete stealth identity profile for a single WebView session.
    /// All fields are value types — zero ARC overhead on cross-actor transfer.
    public struct IdentityProfile: Sendable, Identifiable {
        public let id: UUID
        public let canvasNoiseSeed: UInt64
        public let audioNoiseSeed: UInt64
        public let hardwareConcurrency: Int
        public let deviceMemoryGB: Int
        public let webGLVendor: String
        public let webGLRenderer: String
        public let screenWidth: Int
        public let screenHeight: Int
        public let timezoneOffset: Int
        public let languageCode: String
        public let createdAt: Date

        public init(
            id: UUID = UUID(),
            canvasNoiseSeed: UInt64 = .random(in: 1...UInt64.max),
            audioNoiseSeed: UInt64 = .random(in: 1...UInt64.max),
            hardwareConcurrency: Int = .random(in: 4...8),
            deviceMemoryGB: Int = [4, 6, 8].randomElement()!,
            webGLVendor: String = "Apple Inc.",
            webGLRenderer: String = StealthIdentityActor.randomGPURenderer(),
            screenWidth: Int = [375, 390, 393, 414, 428].randomElement()!,
            screenHeight: Int = [667, 736, 812, 844, 852, 896, 926, 932].randomElement()!,
            timezoneOffset: Int = [600, 660, -300, -360, -420, -480, 0, 60].randomElement()!,
            languageCode: String = ["en-US", "en-AU", "en-GB"].randomElement()!,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.canvasNoiseSeed = canvasNoiseSeed
            self.audioNoiseSeed = audioNoiseSeed
            self.hardwareConcurrency = hardwareConcurrency
            self.deviceMemoryGB = deviceMemoryGB
            self.webGLVendor = webGLVendor
            self.webGLRenderer = webGLRenderer
            self.screenWidth = screenWidth
            self.screenHeight = screenHeight
            self.timezoneOffset = timezoneOffset
            self.languageCode = languageCode
            self.createdAt = createdAt
        }
    }

    // MARK: - State

    private var activeProfiles: [UUID: IdentityProfile] = [:]
    private var usedCanvasSeeds: Set<UInt64> = []
    private var usedAudioSeeds: Set<UInt64> = []

    // MARK: - Profile Management

    /// Generates a new, unique stealth identity profile.
    /// Guarantees that canvas and audio seeds are never reused across sessions.
    public func generateProfile() -> IdentityProfile {
        var canvasSeed: UInt64
        repeat {
            canvasSeed = .random(in: 1...UInt64.max)
        } while usedCanvasSeeds.contains(canvasSeed)

        var audioSeed: UInt64
        repeat {
            audioSeed = .random(in: 1...UInt64.max)
        } while usedAudioSeeds.contains(audioSeed)

        usedCanvasSeeds.insert(canvasSeed)
        usedAudioSeeds.insert(audioSeed)

        let profile = IdentityProfile(canvasNoiseSeed: canvasSeed, audioNoiseSeed: audioSeed)
        activeProfiles[profile.id] = profile
        return profile
    }

    /// Retrieves an active profile by ID.
    public func profile(for id: UUID) -> IdentityProfile? {
        activeProfiles[id]
    }

    /// Releases a profile when its WebView session ends.
    public func releaseProfile(_ id: UUID) {
        if let profile = activeProfiles.removeValue(forKey: id) {
            usedCanvasSeeds.remove(profile.canvasNoiseSeed)
            usedAudioSeeds.remove(profile.audioNoiseSeed)
        }
    }

    /// Releases all active profiles (e.g., on batch completion).
    public func releaseAllProfiles() {
        activeProfiles.removeAll()
        usedCanvasSeeds.removeAll()
        usedAudioSeeds.removeAll()
    }

    /// Returns the count of currently active stealth profiles.
    public func activeProfileCount() -> Int {
        activeProfiles.count
    }

    // MARK: - GPU Renderer Randomization

    /// Returns a realistic Apple GPU renderer string for WebGL spoofing.
    nonisolated public static func randomGPURenderer() -> String {
        let renderers = [
            "Apple GPU",
            "Apple A15 GPU",
            "Apple A16 GPU",
            "Apple A17 Pro GPU",
            "Apple M1",
            "Apple M2"
        ]
        return renderers.randomElement() ?? "Apple GPU"
    }
}
