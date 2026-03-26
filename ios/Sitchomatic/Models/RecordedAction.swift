import Foundation

nonisolated enum RecordedActionType: String, Codable, Sendable {
    case mouseMove
    case mouseDown
    case mouseUp
    case click
    case doubleClick
    case scroll
    case keyDown
    case keyUp
    case keyPress
    case touchStart
    case touchEnd
    case touchMove
    case focus
    case blur
    case input
    case pageLoad
    case navigationStart
    case textboxEntry
    case pause
}

nonisolated struct RecordedMousePosition: Codable, Sendable {
    let x: Double
    let y: Double
    let viewportX: Double
    let viewportY: Double
}

nonisolated struct RecordedAction: Codable, Sendable, Identifiable {
    let id: String
    let type: RecordedActionType
    let timestampMs: Double
    let deltaFromPreviousMs: Double
    let mousePosition: RecordedMousePosition?
    let scrollDeltaX: Double?
    let scrollDeltaY: Double?
    let keyCode: Int?
    let key: String?
    let code: String?
    let charCode: Int?
    let targetSelector: String?
    let targetTagName: String?
    let targetType: String?
    let textboxLabel: String?
    let textContent: String?
    let button: Int?
    let buttons: Int?
    let holdDurationMs: Double?
    let isTrusted: Bool?
    let shiftKey: Bool?
    let ctrlKey: Bool?
    let altKey: Bool?
    let metaKey: Bool?

    init(
        id: String = UUID().uuidString,
        type: RecordedActionType,
        timestampMs: Double,
        deltaFromPreviousMs: Double = 0,
        mousePosition: RecordedMousePosition? = nil,
        scrollDeltaX: Double? = nil,
        scrollDeltaY: Double? = nil,
        keyCode: Int? = nil,
        key: String? = nil,
        code: String? = nil,
        charCode: Int? = nil,
        targetSelector: String? = nil,
        targetTagName: String? = nil,
        targetType: String? = nil,
        textboxLabel: String? = nil,
        textContent: String? = nil,
        button: Int? = nil,
        buttons: Int? = nil,
        holdDurationMs: Double? = nil,
        isTrusted: Bool? = nil,
        shiftKey: Bool? = nil,
        ctrlKey: Bool? = nil,
        altKey: Bool? = nil,
        metaKey: Bool? = nil
    ) {
        self.id = id
        self.type = type
        self.timestampMs = timestampMs
        self.deltaFromPreviousMs = deltaFromPreviousMs
        self.mousePosition = mousePosition
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
        self.keyCode = keyCode
        self.key = key
        self.code = code
        self.charCode = charCode
        self.targetSelector = targetSelector
        self.targetTagName = targetTagName
        self.targetType = targetType
        self.textboxLabel = textboxLabel
        self.textContent = textContent
        self.button = button
        self.buttons = buttons
        self.holdDurationMs = holdDurationMs
        self.isTrusted = isTrusted
        self.shiftKey = shiftKey
        self.ctrlKey = ctrlKey
        self.altKey = altKey
        self.metaKey = metaKey
    }
}
