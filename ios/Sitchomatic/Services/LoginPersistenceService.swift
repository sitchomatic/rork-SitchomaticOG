import Foundation

@MainActor
class LoginPersistenceService {
    static let shared = LoginPersistenceService()

    private let credentialsKey = "saved_login_credentials_v1"
    private let settingsKey = "login_app_settings_v1"
    private let iCloudCredentialsKey = "icloud_login_credentials_v1"
    private let viewModeKey = "login_view_mode_prefs_v1"
    private let historyKey = "login_testing_history_v1"
    private let logger = DebugLogger.shared

    private let store = NSUbiquitousKeyValueStore.default

    func saveCredentials(_ credentials: [LoginCredential]) {
        let encoded = credentials.map { cred -> [String: Any] in
            var dict: [String: Any] = [
                "id": cred.id,
                "username": cred.username,
                "password": cred.password,
                "addedAt": cred.addedAt.timeIntervalSince1970,
                "status": cred.status.rawValue,
                "notes": cred.notes,
                "assignedPasswords": cred.assignedPasswords,
                "nextPasswordIndex": cred.nextPasswordIndex,
            ]

            let results = cred.testResults.map { result -> [String: Any] in
                var r: [String: Any] = [
                    "id": result.id.uuidString,
                    "timestamp": result.timestamp.timeIntervalSince1970,
                    "success": result.success,
                    "duration": result.duration,
                ]
                if let err = result.errorMessage { r["errorMessage"] = err }
                if let detail = result.responseDetail { r["responseDetail"] = detail }
                return r
            }
            dict["testResults"] = results
            return dict
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: encoded)
            UserDefaults.standard.set(data, forKey: credentialsKey)
            store.set(data, forKey: iCloudCredentialsKey)
            store.synchronize()
        } catch {
            logger.log("LoginPersistence: failed to encode credentials: \(error.localizedDescription)", category: .persistence, level: .error)
        }
    }

    func loadCredentials() -> [LoginCredential] {
        var data = UserDefaults.standard.data(forKey: credentialsKey)

        if data == nil, let iCloudData = store.data(forKey: iCloudCredentialsKey) {
            data = iCloudData
            UserDefaults.standard.set(iCloudData, forKey: credentialsKey)
        }

        guard let data else {
            return []
        }

        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            logger.log("LoginPersistence: failed to decode saved credentials data", category: .persistence, level: .error)
            return []
        }

        return array.compactMap { dict -> LoginCredential? in
            guard let username = dict["username"] as? String,
                  let password = dict["password"] as? String else { return nil }

            let id = dict["id"] as? String
            let addedAt = (dict["addedAt"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
            let cred = LoginCredential(username: username, password: password, id: id, addedAt: addedAt)

            if let statusRaw = dict["status"] as? String, let status = CredentialStatus(rawValue: statusRaw) {
                cred.status = status
            }
            if let notes = dict["notes"] as? String { cred.notes = notes }
            if let assignedPws = dict["assignedPasswords"] as? [String] { cred.assignedPasswords = assignedPws }
            if let pwIdx = dict["nextPasswordIndex"] as? Int { cred.nextPasswordIndex = pwIdx }

            if let results = dict["testResults"] as? [[String: Any]] {
                cred.testResults = results.compactMap { r in
                    guard let success = r["success"] as? Bool,
                          let duration = r["duration"] as? TimeInterval,
                          let ts = r["timestamp"] as? TimeInterval else { return nil }
                    return LoginTestResult(
                        success: success,
                        duration: duration,
                        errorMessage: r["errorMessage"] as? String,
                        responseDetail: r["responseDetail"] as? String,
                        timestamp: Date(timeIntervalSince1970: ts)
                    )
                }
            }

            return cred
        }
    }

    func saveSettings(targetSite: String, maxConcurrency: Int, debugMode: Bool, appearanceMode: String, stealthEnabled: Bool, testTimeout: TimeInterval) {
        let dict: [String: Any] = [
            "targetSite": targetSite,
            "maxConcurrency": maxConcurrency,
            "debugMode": debugMode,
            "appearanceMode": appearanceMode,
            "stealthEnabled": stealthEnabled,
            "testTimeout": testTimeout,
        ]
        UserDefaults.standard.set(dict, forKey: settingsKey)
    }

    func loadSettings() -> (targetSite: String, maxConcurrency: Int, debugMode: Bool, appearanceMode: String, stealthEnabled: Bool, testTimeout: TimeInterval)? {
        guard let dict = UserDefaults.standard.dictionary(forKey: settingsKey) else { return nil }
        return (
            targetSite: dict["targetSite"] as? String ?? LoginTargetSite.joefortune.rawValue,
            maxConcurrency: dict["maxConcurrency"] as? Int ?? 8,
            debugMode: dict["debugMode"] as? Bool ?? false,
            appearanceMode: dict["appearanceMode"] as? String ?? "Dark",
            stealthEnabled: dict["stealthEnabled"] as? Bool ?? true,
            testTimeout: max(dict["testTimeout"] as? TimeInterval ?? 90, AutomationSettings.minimumTimeoutSeconds)
        )
    }

    private let testQueueKey = "login_test_queue_v1"
    private let testQueueTimestampKey = "login_test_queue_ts_v1"

    func saveTestQueue(credentialIds: [String]) {
        UserDefaults.standard.set(credentialIds, forKey: testQueueKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: testQueueTimestampKey)
    }

    func loadTestQueue() -> [String]? {
        let ts = UserDefaults.standard.double(forKey: testQueueTimestampKey)
        guard ts > 0 else { return nil }
        let age = Date().timeIntervalSince1970 - ts
        guard age < 3600 else {
            clearTestQueue()
            return nil
        }
        return UserDefaults.standard.stringArray(forKey: testQueueKey)
    }

    func clearTestQueue() {
        UserDefaults.standard.removeObject(forKey: testQueueKey)
        UserDefaults.standard.removeObject(forKey: testQueueTimestampKey)
    }

    func syncFromiCloud() -> [LoginCredential]? {
        store.synchronize()
        guard let data = store.data(forKey: iCloudCredentialsKey),
              let _ = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        UserDefaults.standard.set(data, forKey: credentialsKey)
        return loadCredentials()
    }
}
