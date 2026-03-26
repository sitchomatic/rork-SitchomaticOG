import Foundation
import Observation

@Observable
@MainActor
class BlacklistService {
    static let shared = BlacklistService()

    private(set) var blacklistedEmails: [BlacklistEntry] = []
    var autoExcludeBlacklist: Bool = true {
        didSet { persistSettings() }
    }
    var autoBlacklistNoAcc: Bool = true {
        didSet { persistSettings() }
    }

    private let storageKey = "blacklist_emails_v2"
    private let settingsKey = "blacklist_settings_v1"

    init() {
        loadData()
        loadSettings()
    }

    func isBlacklisted(_ email: String) -> Bool {
        let lower = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return blacklistedEmails.contains { $0.email.lowercased() == lower }
    }

    func addToBlacklist(_ email: String, reason: String = "") {
        let lower = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty, !isBlacklisted(lower) else { return }
        blacklistedEmails.insert(BlacklistEntry(email: lower, reason: reason, addedAt: Date()), at: 0)
        persistData()
    }

    func addMultipleToBlacklist(_ emails: [String], reason: String = "") {
        var added = 0
        for email in emails {
            let lower = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lower.isEmpty, !isBlacklisted(lower) else { continue }
            blacklistedEmails.insert(BlacklistEntry(email: lower, reason: reason, addedAt: Date()), at: 0)
            added += 1
        }
        if added > 0 { persistData() }
    }

    func removeFromBlacklist(_ entry: BlacklistEntry) {
        blacklistedEmails.removeAll { $0.id == entry.id }
        persistData()
    }

    func removeFromBlacklistByEmail(_ email: String) {
        let lower = email.lowercased()
        blacklistedEmails.removeAll { $0.email.lowercased() == lower }
        persistData()
    }

    func clearBlacklist() {
        blacklistedEmails.removeAll()
        persistData()
    }

    func exportBlacklist() -> String {
        blacklistedEmails.map(\.email).joined(separator: "\n")
    }

    func importBlacklist(_ text: String, reason: String = "Imported") {
        let emails = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        addMultipleToBlacklist(emails, reason: reason)
    }

    private func persistData() {
        let encoded = blacklistedEmails.map { entry -> [String: Any] in
            [
                "id": entry.id,
                "email": entry.email,
                "reason": entry.reason,
                "addedAt": entry.addedAt.timeIntervalSince1970,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: encoded) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadData() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        blacklistedEmails = array.compactMap { dict in
            guard let email = dict["email"] as? String else { return nil }
            let id = dict["id"] as? String ?? UUID().uuidString
            let reason = dict["reason"] as? String ?? ""
            let ts = dict["addedAt"] as? TimeInterval ?? Date().timeIntervalSince1970
            return BlacklistEntry(id: id, email: email, reason: reason, addedAt: Date(timeIntervalSince1970: ts))
        }
    }

    private func persistSettings() {
        let dict: [String: Any] = [
            "autoExcludeBlacklist": autoExcludeBlacklist,
            "autoBlacklistNoAcc": autoBlacklistNoAcc,
        ]
        UserDefaults.standard.set(dict, forKey: settingsKey)
    }

    private func loadSettings() {
        guard let dict = UserDefaults.standard.dictionary(forKey: settingsKey) else { return }
        if let v = dict["autoExcludeBlacklist"] as? Bool { autoExcludeBlacklist = v }
        if let v = dict["autoBlacklistNoAcc"] as? Bool { autoBlacklistNoAcc = v }
    }
}

struct BlacklistEntry: Identifiable {
    let id: String
    let email: String
    let reason: String
    let addedAt: Date

    init(id: String = UUID().uuidString, email: String, reason: String = "", addedAt: Date = Date()) {
        self.id = id
        self.email = email
        self.reason = reason
        self.addedAt = addedAt
    }

    var formattedDate: String {
        DateFormatters.mediumDateTime.string(from: addedAt)
    }
}
