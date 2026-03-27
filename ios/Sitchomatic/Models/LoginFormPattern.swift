import Foundation

nonisolated enum LoginFormPattern: String, CaseIterable, Codable, Sendable {
    case trueDetection = "TRUE DETECTION"
    case tabNavigation = "Tab Navigation"
    case clickFocusSequential = "Click-Focus Sequential"
    case execCommandInsert = "ExecCommand Insert"
    case slowDeliberateTyper = "Slow Deliberate Typer"
    case mobileTouchBurst = "Mobile Touch Burst"
    case calibratedDirect = "Calibrated Direct"
    case calibratedTyping = "Calibrated Typing"
    case formSubmitDirect = "Form Submit Direct"
    case coordinateClick = "Coordinate Click"
    case reactNativeSetter = "React Native Setter"
    case visionMLCoordinate = "Vision ML Coordinate"

    var description: String {
        switch self {
        case .trueDetection:
            "Hardcoded Interaction Protocol: Triple-Wait → #email → #login-password → Triple-Click #login-submit with force dispatch"
        case .tabNavigation:
            "Click email → char-by-char type → Tab to password → char-by-char type → Enter to submit"
        case .clickFocusSequential:
            "Click each field with mouse movement → type with Gaussian delays → click login button"
        case .execCommandInsert:
            "Focus field → execCommand insertText per char → blur → human click submit"
        case .slowDeliberateTyper:
            "Very slow typing with long pauses, occasional backspace corrections, then manual click"
        case .mobileTouchBurst:
            "Touch events for field selection → fast burst typing → touch submit"
        case .calibratedDirect:
            "Use calibrated CSS selectors to fill fields and click button directly"
        case .calibratedTyping:
            "Use calibrated selectors to focus, then char-by-char type with Enter submit"
        case .formSubmitDirect:
            "Fill via nativeInputValueSetter → form.requestSubmit() or form.submit()"
        case .coordinateClick:
            "Use calibrated pixel coordinates to click email, password, and login button"
        case .reactNativeSetter:
            "React-compatible: Object.defineProperty setter + InputEvent with inputType"
        case .visionMLCoordinate:
            "Vision ML: Screenshot OCR to detect fields/buttons, then coordinate-based taps"
        }
    }
}

nonisolated struct HumanPatternResult: Sendable {
    let pattern: LoginFormPattern
    var usernameFilled: Bool = false
    var passwordFilled: Bool = false
    var submitTriggered: Bool = false
    var submitMethod: String = ""

    var overallSuccess: Bool {
        usernameFilled && passwordFilled && submitTriggered
    }

    var summary: String {
        "Pattern[\(pattern.rawValue)] user:\(usernameFilled) pass:\(passwordFilled) submit:\(submitTriggered) method:\(submitMethod)"
    }
}
