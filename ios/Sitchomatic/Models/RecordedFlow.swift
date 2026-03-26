import Foundation

nonisolated struct RecordedFlow: Codable, Sendable, Identifiable {
    let id: String
    var name: String
    let url: String
    let createdAt: Date
    var actions: [RecordedAction]
    var textboxMappings: [TextboxMapping]
    var totalDurationMs: Double
    var actionCount: Int

    nonisolated struct TextboxMapping: Codable, Sendable, Identifiable {
        let id: String
        let label: String
        let selector: String
        let originalText: String
        var placeholderKey: String

        init(
            id: String = UUID().uuidString,
            label: String,
            selector: String,
            originalText: String,
            placeholderKey: String
        ) {
            self.id = id
            self.label = label
            self.selector = selector
            self.originalText = originalText
            self.placeholderKey = placeholderKey
        }
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        url: String,
        createdAt: Date = Date(),
        actions: [RecordedAction] = [],
        textboxMappings: [TextboxMapping] = [],
        totalDurationMs: Double = 0,
        actionCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.createdAt = createdAt
        self.actions = actions
        self.textboxMappings = textboxMappings
        self.totalDurationMs = totalDurationMs
        self.actionCount = actionCount
    }

    var formattedDuration: String {
        let seconds = totalDurationMs / 1000.0
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let remaining = Int(seconds) % 60
        return "\(minutes)m \(remaining)s"
    }

    var summary: String {
        let mouseActions = actions.filter { $0.type == .mouseMove }.count
        let clicks = actions.filter { $0.type == .click || $0.type == .mouseDown }.count
        let keystrokes = actions.filter { $0.type == .keyDown }.count
        let scrolls = actions.filter { $0.type == .scroll }.count
        return "Mouse:\(mouseActions) Clicks:\(clicks) Keys:\(keystrokes) Scrolls:\(scrolls)"
    }
}
