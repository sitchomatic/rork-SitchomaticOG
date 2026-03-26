import Foundation
import UIKit

@MainActor
class PPSRPersistenceService {
    static let shared = PPSRPersistenceService()

    private let cardsKey = "saved_cards_v2"
    private let settingsKey = "app_settings_v3"
    private let iCloudCardsKey = "icloud_saved_cards_v2"
    private let testQueueKey = "ppsr_test_queue_v1"
    private let testQueueTimestampKey = "ppsr_test_queue_ts_v1"

    private let store = NSUbiquitousKeyValueStore.default

    func saveCards(_ cards: [PPSRCard]) {
        let encoded = cards.map { card -> [String: Any] in
            var dict: [String: Any] = [
                "id": card.id,
                "number": card.number,
                "expiryMonth": card.expiryMonth,
                "expiryYear": card.expiryYear,
                "cvv": card.cvv,
                "brand": card.brand.rawValue,
                "addedAt": card.addedAt.timeIntervalSince1970,
                "status": card.status.rawValue,
            ]

            let results = card.testResults.map { result -> [String: Any] in
                var r: [String: Any] = [
                    "id": result.id.uuidString,
                    "timestamp": result.timestamp.timeIntervalSince1970,
                    "success": result.success,
                    "vin": result.vin,
                    "duration": result.duration,
                ]
                if let err = result.errorMessage {
                    r["errorMessage"] = err
                }
                return r
            }
            dict["testResults"] = results

            if let binData = card.binData {
                dict["binData"] = [
                    "bin": binData.bin,
                    "scheme": binData.scheme,
                    "type": binData.type,
                    "category": binData.category,
                    "issuer": binData.issuer,
                    "country": binData.country,
                    "countryCode": binData.countryCode,
                    "isLoaded": binData.isLoaded,
                ]
            }

            return dict
        }

        if let data = try? JSONSerialization.data(withJSONObject: encoded) {
            UserDefaults.standard.set(data, forKey: cardsKey)
            store.set(data, forKey: iCloudCardsKey)
            store.synchronize()
        }
    }

    func loadCards() -> [PPSRCard] {
        var data = UserDefaults.standard.data(forKey: cardsKey)

        if data == nil, let iCloudData = store.data(forKey: iCloudCardsKey) {
            data = iCloudData
            UserDefaults.standard.set(iCloudData, forKey: cardsKey)
        }

        guard let data,
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return array.compactMap { dict -> PPSRCard? in
            guard let number = dict["number"] as? String,
                  let expiryMonth = dict["expiryMonth"] as? String,
                  let expiryYear = dict["expiryYear"] as? String,
                  let cvv = dict["cvv"] as? String else { return nil }

            let id = dict["id"] as? String
            let addedAt = (dict["addedAt"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
            let card = PPSRCard(number: number, expiryMonth: expiryMonth, expiryYear: expiryYear, cvv: cvv, id: id, addedAt: addedAt)

            if let statusRaw = dict["status"] as? String, let status = CardStatus(rawValue: statusRaw) {
                card.status = status
            }

            if let results = dict["testResults"] as? [[String: Any]] {
                card.testResults = results.compactMap { r in
                    guard let success = r["success"] as? Bool,
                          let vin = r["vin"] as? String,
                          let duration = r["duration"] as? TimeInterval,
                          let ts = r["timestamp"] as? TimeInterval else { return nil }
                    return PPSRTestResult(
                        success: success,
                        vin: vin,
                        duration: duration,
                        errorMessage: r["errorMessage"] as? String,
                        timestamp: Date(timeIntervalSince1970: ts)
                    )
                }
            }

            if let binDict = dict["binData"] as? [String: Any] {
                let bin = PPSRBINData(
                    bin: binDict["bin"] as? String ?? "",
                    scheme: binDict["scheme"] as? String ?? "",
                    type: binDict["type"] as? String ?? "",
                    category: binDict["category"] as? String ?? "",
                    issuer: binDict["issuer"] as? String ?? "",
                    country: binDict["country"] as? String ?? "",
                    countryCode: binDict["countryCode"] as? String ?? "",
                    isLoaded: binDict["isLoaded"] as? Bool ?? false
                )
                card.binData = bin
            }

            return card
        }
    }

    func saveSettings(email: String, maxConcurrency: Int, debugMode: Bool, appearanceMode: String, useEmailRotation: Bool, stealthEnabled: Bool, retrySubmitOnFail: Bool = false, screenshotCropRect: CGRect = .zero) {
        var dict: [String: Any] = [
            "email": email,
            "maxConcurrency": maxConcurrency,
            "debugMode": debugMode,
            "appearanceMode": appearanceMode,
            "useEmailRotation": useEmailRotation,
            "stealthEnabled": stealthEnabled,
            "retrySubmitOnFail": retrySubmitOnFail,
        ]
        if screenshotCropRect != .zero {
            dict["cropX"] = Double(screenshotCropRect.origin.x)
            dict["cropY"] = Double(screenshotCropRect.origin.y)
            dict["cropW"] = Double(screenshotCropRect.size.width)
            dict["cropH"] = Double(screenshotCropRect.size.height)
        }
        UserDefaults.standard.set(dict, forKey: settingsKey)
    }

    func loadSettings() -> (email: String, maxConcurrency: Int, debugMode: Bool, appearanceMode: String, useEmailRotation: Bool, stealthEnabled: Bool, retrySubmitOnFail: Bool, screenshotCropRect: CGRect?)? {
        guard let dict = UserDefaults.standard.dictionary(forKey: settingsKey) else { return nil }
        var cropRect: CGRect?
        if let x = dict["cropX"] as? Double,
           let y = dict["cropY"] as? Double,
           let w = dict["cropW"] as? Double,
           let h = dict["cropH"] as? Double {
            cropRect = CGRect(x: x, y: y, width: w, height: h)
        }
        return (
            email: dict["email"] as? String ?? "dev@test.ppsr.gov.au",
            maxConcurrency: dict["maxConcurrency"] as? Int ?? 8,
            debugMode: dict["debugMode"] as? Bool ?? true,
            appearanceMode: dict["appearanceMode"] as? String ?? "Dark",
            useEmailRotation: dict["useEmailRotation"] as? Bool ?? true,
            stealthEnabled: dict["stealthEnabled"] as? Bool ?? true,
            retrySubmitOnFail: dict["retrySubmitOnFail"] as? Bool ?? false,
            screenshotCropRect: cropRect
        )
    }

    func saveTestQueue(cardIds: [String]) {
        UserDefaults.standard.set(cardIds, forKey: testQueueKey)
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

    func syncFromiCloud() -> [PPSRCard]? {
        store.synchronize()
        guard let data = store.data(forKey: iCloudCardsKey),
              let _ = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        UserDefaults.standard.set(data, forKey: cardsKey)
        return loadCards()
    }
}
