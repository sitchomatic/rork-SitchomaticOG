import Foundation

nonisolated let kDefaultNickKey = "e9f2ab7e7bf1fc575b04fe32e90cc8e4023f0d46151a5f8238ed1dccc6bcffd7"
nonisolated let kDefaultPoliKey = "e9f2ab92d0403a4715baf19e67d70b5ebc2b860c4f17bb5396085bb10dedf579"

@MainActor
class NordVPNKeyStore {
    static let shared = NordVPNKeyStore()

    private let nickKeyStorageKey = "nordvpn_nick_access_key_v3"
    private let legacyNickKeyStorageKey = "nordvpn_nick_access_key_v2"
    private let legacyDefaultNickKey = "68b9f594ef76d1ec4ef82eb3e0c0a93dfe0ad4bd091a38965218d1f23340c78d"
    private let poliKeyStorageKey = "nordvpn_poli_access_key_v2"

    static let defaultNickKey = kDefaultNickKey
    static let defaultPoliKey = kDefaultPoliKey

    var nickKey: String {
        get {
            if let stored = UserDefaults.standard.string(forKey: nickKeyStorageKey), !stored.isEmpty {
                return stored
            }
            if let legacy = UserDefaults.standard.string(forKey: legacyNickKeyStorageKey), !legacy.isEmpty {
                let migratedKey = legacy == legacyDefaultNickKey ? Self.defaultNickKey : legacy
                UserDefaults.standard.set(migratedKey, forKey: nickKeyStorageKey)
                UserDefaults.standard.removeObject(forKey: legacyNickKeyStorageKey)
                return migratedKey
            }
            return Self.defaultNickKey
        }
        set { UserDefaults.standard.set(newValue, forKey: nickKeyStorageKey) }
    }

    var poliKey: String {
        get { UserDefaults.standard.string(forKey: poliKeyStorageKey) ?? Self.defaultPoliKey }
        set { UserDefaults.standard.set(newValue, forKey: poliKeyStorageKey) }
    }

    func keyForProfile(_ profile: NordKeyProfile) -> String {
        switch profile {
        case .nick: nickKey
        case .poli: poliKey
        }
    }

    func updateKey(_ key: String, for profile: NordKeyProfile) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch profile {
        case .nick: nickKey = trimmed
        case .poli: poliKey = trimmed
        }
    }

    func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: nickKeyStorageKey)
        UserDefaults.standard.removeObject(forKey: legacyNickKeyStorageKey)
        UserDefaults.standard.removeObject(forKey: poliKeyStorageKey)
    }
}
