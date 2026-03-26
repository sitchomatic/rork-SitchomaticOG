import Foundation

@MainActor
class PPSRCardManager {
    var cards: [PPSRCard] = []

    private let persistence = PPSRPersistenceService.shared
    private let logger = DebugLogger.shared
    private var cardsSaveTask: Task<Void, Never>?
    var onLog: ((String, PPSRLogEntry.Level) -> Void)?

    var cardSortOption: PPSRAutomationViewModel.CardSortOption = {
        if let raw = UserDefaults.standard.string(forKey: "ppsr_card_sort_option"),
           let opt = PPSRAutomationViewModel.CardSortOption(rawValue: raw) { return opt }
        return .dateAdded
    }() {
        didSet { UserDefaults.standard.set(cardSortOption.rawValue, forKey: "ppsr_card_sort_option") }
    }

    var cardSortAscending: Bool = UserDefaults.standard.bool(forKey: "ppsr_card_sort_ascending") {
        didSet { UserDefaults.standard.set(cardSortAscending, forKey: "ppsr_card_sort_ascending") }
    }

    var workingCards: [PPSRCard] { cards.filter { $0.status == .working } }
    var deadCards: [PPSRCard] { cards.filter { $0.status == .dead } }
    var untestedCards: [PPSRCard] { applySortOrder(cards.filter { $0.status == .untested }) }
    var testingCards: [PPSRCard] { cards.filter { $0.status == .testing } }
    var totalSuccessfulCards: Int { cards.filter { $0.status == .working }.count }

    func applySortOrder(_ input: [PPSRCard]) -> [PPSRCard] {
        var result = input
        result.sort { a, b in
            let comparison: Bool
            switch cardSortOption {
            case .dateAdded: comparison = a.addedAt > b.addedAt
            case .lastTest: comparison = (a.lastTestedAt ?? .distantPast) > (b.lastTestedAt ?? .distantPast)
            case .successRate: comparison = a.successRate > b.successRate
            case .totalTests: comparison = a.totalTests > b.totalTests
            case .bin: comparison = a.binPrefix < b.binPrefix
            case .brand: comparison = a.brand.rawValue < b.brand.rawValue
            case .country: comparison = (a.binData?.country ?? "") < (b.binData?.country ?? "")
            }
            return cardSortAscending ? !comparison : comparison
        }
        return result
    }

    func loadPersistedCards() {
        let loaded = persistence.loadCards()
        let expiredCount = loaded.filter { $0.isExpired }.count
        cards = loaded.filter { !$0.isExpired }
        if expiredCount > 0 {
            onLog?("Removed \(expiredCount) expired card(s) automatically", .warning)
            persistCards()
        }
        if !cards.isEmpty {
            onLog?("Restored \(cards.count) cards from storage", .info)
        }
    }

    func restoreTestQueueIfNeeded() {
        guard let queuedIds = persistence.loadTestQueue(), !queuedIds.isEmpty else { return }
        let idSet = Set(queuedIds)
        var restoredCount = 0
        for card in cards where idSet.contains(card.id) {
            if card.status == .testing {
                card.status = .untested
                restoredCount += 1
            }
        }
        persistence.clearTestQueue()
        if restoredCount > 0 {
            onLog?("Restored \(restoredCount) interrupted test(s) back to queue", .warning)
            persistCards()
        }
    }

    func persistCards() {
        cardsSaveTask?.cancel()
        cardsSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            persistence.saveCards(cards)
        }
    }

    func persistCardsNow() {
        cardsSaveTask?.cancel()
        cardsSaveTask = nil
        persistence.saveCards(cards)
    }

    func smartImportCards(_ input: String) {
        let parsed = PPSRCard.smartParse(input)
        let lines = input.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if parsed.isEmpty && !lines.isEmpty {
            for line in lines {
                onLog?("Could not parse: \(line)", .warning)
            }
            return
        }

        var added = 0
        var dupes = 0
        var expired = 0
        for card in parsed {
            if card.isExpired {
                expired += 1
                onLog?("Skipped expired: \(card.brand.rawValue) \(card.number) exp \(card.formattedExpiry)", .warning)
                continue
            }
            let isDuplicate = cards.contains { $0.number == card.number }
            if isDuplicate {
                dupes += 1
                onLog?("Skipped duplicate: \(card.brand.rawValue) \(card.number)", .warning)
            } else {
                cards.append(card)
                added += 1
                onLog?("Added \(card.brand.rawValue) \(card.number) exp \(card.formattedExpiry)", .info)
                Task { await card.loadBINData() }
            }
        }

        if parsed.count > 0 {
            var msg = "Smart import: \(added) card(s) added from \(lines.count) line(s)"
            if dupes > 0 { msg += ", \(dupes) duplicate(s) skipped" }
            if expired > 0 { msg += ", \(expired) expired skipped" }
            onLog?(msg, .success)
        }
        persistCards()
    }

    func importFromCSV(_ csvText: String, mapping: PPSRCard.CSVColumnMapping = .auto) -> (added: Int, duplicates: Int) {
        let parsed = PPSRCard.parseCSVData(csvText, columnMapping: mapping)
        var added = 0
        var dupes = 0
        var expired = 0
        for card in parsed {
            if card.isExpired {
                expired += 1
                onLog?("Skipped expired: \(card.brand.rawValue) \(card.number) exp \(card.formattedExpiry)", .warning)
                continue
            }
            if cards.contains(where: { $0.number == card.number }) {
                dupes += 1
                onLog?("Skipped duplicate: \(card.brand.rawValue) \(card.number)", .warning)
            } else {
                cards.append(card)
                added += 1
                onLog?("Added \(card.brand.rawValue) \(card.number) exp \(card.formattedExpiry)", .info)
                Task { await card.loadBINData() }
            }
        }
        if added > 0 || dupes > 0 || expired > 0 {
            var msg = "CSV import: \(added) card(s) added"
            if dupes > 0 { msg += ", \(dupes) duplicate(s) skipped" }
            if expired > 0 { msg += ", \(expired) expired skipped" }
            onLog?(msg, added > 0 ? .success : .warning)
        } else {
            onLog?("CSV import: no valid cards found", .warning)
        }
        persistCards()
        return (added, dupes)
    }

    func deleteCard(_ card: PPSRCard) {
        cards.removeAll { $0.id == card.id }
        onLog?("Removed \(card.brand.rawValue) card: \(card.number)", .info)
        persistCards()
    }

    func restoreCard(_ card: PPSRCard) {
        card.status = .untested
        onLog?("Restored \(card.brand.rawValue) \(card.number) to untested", .info)
        persistCards()
    }

    func purgeDeadCards() {
        let count = deadCards.count
        cards.removeAll { $0.status == .dead }
        onLog?("Purged \(count) dead card(s)", .info)
        persistCards()
    }

    func resetStuckTestingCards() -> Int {
        var resetCount = 0
        for card in cards where card.status == .testing {
            card.status = .untested
            resetCount += 1
        }
        return resetCount
    }

    func syncFromiCloud() {
        if let synced = persistence.syncFromiCloud() {
            let existingIds = Set(cards.map(\.number))
            var added = 0
            for card in synced where !existingIds.contains(card.number) && !card.isExpired {
                cards.append(card)
                added += 1
            }
            if added > 0 {
                onLog?("iCloud sync: merged \(added) new cards", .success)
                persistCards()
            } else {
                onLog?("iCloud sync: no new cards found", .info)
            }
        }
    }

    func exportWorkingCards() -> String {
        workingCards.map(\.pipeFormat).joined(separator: "\n")
    }

    func saveTestQueue(ids: [String]) {
        persistence.saveTestQueue(cardIds: ids)
    }

    func clearTestQueue() {
        persistence.clearTestQueue()
    }
}
