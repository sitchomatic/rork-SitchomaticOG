import Foundation
import Observation
import WebKit

@Observable
class FlowRecorderViewModel {
    var targetURL: String = "https://joefortune24.com/login"
    var flowName: String = ""
    var isRecording: Bool = false
    var isPlaying: Bool = false
    var savedFlows: [RecordedFlow] = []
    var currentActions: [RecordedAction] = []
    var recordingDurationMs: Double = 0
    var playbackProgress: Double = 0
    var playbackActionIndex: Int = 0
    var playbackTotalActions: Int = 0
    var showSaveSheet: Bool = false
    var showPlaybackSheet: Bool = false
    var selectedFlow: RecordedFlow?
    var textboxValues: [String: String] = [:]
    var statusMessage: String = ""
    var fingerprintScore: String = "—"
    var pageTitle: String = ""
    var showExportSheet: Bool = false
    var showImportPicker: Bool = false
    var lastError: String?
    var failedActions: Int = 0
    var healedActions: Int = 0

    var playFromStepIndex: Int = 0
    var showURLDropdown: Bool = false
    var showSettingsFromRecorder: Bool = false
    var isTestingAction: Bool = false
    var testingActionIndex: Int?
    var testingActionMethod: ActionAutomationMethod = .humanClick
    var testActionResults: [ActionTestResult] = []
    var recordAfterPlayback: Bool = false
    var isRecordingAfterPlay: Bool = false

    private let persistence = FlowPersistenceService.shared
    private let playbackEngine = FlowPlaybackEngine.shared
    private let logger = DebugLogger.shared
    private var recordingStartTime: Double = 0
    private var durationTimer: Timer?
    weak var activeWebView: WKWebView?

    var currentActionCount: Int { currentActions.count }
    var mouseMovements: Int { currentActions.filter { $0.type == .mouseMove }.count }
    var clicks: Int { currentActions.filter { $0.type == .click || $0.type == .mouseDown }.count }
    var keystrokes: Int { currentActions.filter { $0.type == .keyDown }.count }
    var scrollEvents: Int { currentActions.filter { $0.type == .scroll }.count }

    var detectedTextboxes: [String] {
        let labels = Set(currentActions.compactMap(\.textboxLabel))
        return labels.sorted()
    }

    var allAvailableURLs: [String] {
        var urls: [String] = []
        let urlService = LoginURLRotationService.shared
        for u in urlService.joeURLs where u.isEnabled {
            urls.append(u.urlString)
        }
        for u in urlService.ignitionURLs where u.isEnabled {
            urls.append(u.urlString)
        }
        let flowURLs = Set(savedFlows.map(\.url))
        for fu in flowURLs {
            if !urls.contains(fu) { urls.append(fu) }
        }
        if !targetURL.isEmpty && !urls.contains(targetURL) {
            urls.insert(targetURL, at: 0)
        }
        return urls
    }

    init() {
        savedFlows = persistence.loadFlows()
    }

    func startRecording() {
        guard !isRecording else { return }
        currentActions = []
        recordingDurationMs = 0
        recordingStartTime = ProcessInfo.processInfo.systemUptime * 1000
        isRecording = true
        isRecordingAfterPlay = false
        lastError = nil
        statusMessage = "Recording..."

        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.recordingDurationMs = ProcessInfo.processInfo.systemUptime * 1000 - self.recordingStartTime
            }
        }

        logger.startSession("recording", category: .flowRecorder, message: "FlowRecorder: recording started for \(targetURL)")
    }

    func startRecordingFromStep() {
        guard !isRecording else { return }
        recordingDurationMs = 0
        recordingStartTime = ProcessInfo.processInfo.systemUptime * 1000
        isRecording = true
        isRecordingAfterPlay = true
        lastError = nil
        statusMessage = "Recording (continuing from step \(playFromStepIndex))..."

        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.recordingDurationMs = ProcessInfo.processInfo.systemUptime * 1000 - self.recordingStartTime
            }
        }

        logger.startSession("recording_continue", category: .flowRecorder, message: "FlowRecorder: recording continued from step \(playFromStepIndex)")
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        durationTimer?.invalidate()
        durationTimer = nil
        statusMessage = "Recording stopped — \(currentActions.count) actions captured"

        logger.endSession("recording", category: .flowRecorder, message: "FlowRecorder: recording stopped — \(currentActions.count) actions", level: currentActions.isEmpty ? .warning : .success)

        if currentActions.isEmpty {
            lastError = "No actions recorded. The page may be blocking the recorder script."
        } else {
            showSaveSheet = true
        }
    }

    func appendActions(_ actions: [RecordedAction]) {
        guard !actions.isEmpty else { return }
        currentActions.append(contentsOf: actions)
    }

    func handlePageLoaded(_ title: String) {
        pageTitle = title
        validateFingerprint()
    }

    func handlePageLoadFailed(_ error: String) {
        lastError = error
        statusMessage = "Page load failed: \(error)"
    }

    func saveCurrentFlow() {
        let name = flowName.isEmpty ? "Flow \(savedFlows.count + 1)" : flowName
        let textboxMappings = detectedTextboxes.map { label in
            let lastInput = currentActions.last(where: { $0.textboxLabel == label && $0.type == .input })
            let selector = lastInput?.targetSelector ?? ""
            let originalText = lastInput?.textContent ?? ""
            return RecordedFlow.TextboxMapping(
                label: label,
                selector: selector,
                originalText: originalText,
                placeholderKey: label
            )
        }

        let flow = RecordedFlow(
            name: name,
            url: targetURL,
            actions: currentActions,
            textboxMappings: textboxMappings,
            totalDurationMs: recordingDurationMs,
            actionCount: currentActions.count
        )

        savedFlows.insert(flow, at: 0)
        persistence.saveFlows(savedFlows)
        flowName = ""
        showSaveSheet = false
        statusMessage = "Flow '\(name)' saved — \(flow.actionCount) actions"
    }

    func mergeRecordedActionsIntoFlow(_ flow: RecordedFlow, fromStep: Int) {
        guard !currentActions.isEmpty else { return }
        var updatedFlow = flow
        let keepActions = Array(updatedFlow.actions.prefix(fromStep))
        updatedFlow.actions = keepActions + currentActions
        updatedFlow.actionCount = updatedFlow.actions.count
        updatedFlow.totalDurationMs = updatedFlow.actions.reduce(0) { $0 + $1.deltaFromPreviousMs }

        if let idx = savedFlows.firstIndex(where: { $0.id == flow.id }) {
            savedFlows[idx] = updatedFlow
        }
        persistence.saveFlows(savedFlows)
        statusMessage = "Flow '\(flow.name)' updated — merged \(currentActions.count) new actions from step \(fromStep)"
        currentActions = []
    }

    func deleteFlow(_ flow: RecordedFlow) {
        savedFlows.removeAll { $0.id == flow.id }
        persistence.saveFlows(savedFlows)
    }

    func selectFlowForPlayback(_ flow: RecordedFlow) {
        selectedFlow = flow
        textboxValues = [:]
        playFromStepIndex = 0
        for mapping in flow.textboxMappings {
            textboxValues[mapping.placeholderKey] = ""
        }
        showPlaybackSheet = true
    }

    func playSelectedFlow() {
        guard let flow = selectedFlow else { return }
        guard let webView = activeWebView else {
            lastError = "WebView not available for playback"
            return
        }

        showPlaybackSheet = false
        isPlaying = true
        playbackProgress = 0
        playbackActionIndex = 0
        playbackTotalActions = flow.actions.count
        failedActions = 0
        healedActions = 0
        lastError = nil
        statusMessage = "Playing '\(flow.name)' from step \(playFromStepIndex)..."

        Task {
            await playbackEngine.playFlow(
                flow,
                in: webView,
                textboxValues: textboxValues,
                startFromStep: playFromStepIndex,
                onProgress: { [weak self] current, total in
                    guard let self else { return }
                    self.playbackActionIndex = current
                    self.playbackTotalActions = total
                    self.playbackProgress = Double(current) / Double(max(total, 1))
                },
                onComplete: { [weak self] success in
                    guard let self else { return }
                    self.isPlaying = false
                    self.failedActions = self.playbackEngine.failedActionIndices.count
                    self.healedActions = self.playbackEngine.healedActionCount
                    if success {
                        if self.failedActions > 0 {
                            self.statusMessage = "Playback complete — \(self.failedActions) failed, \(self.healedActions) healed"
                        } else {
                            self.statusMessage = "Playback complete"
                        }
                        if self.recordAfterPlayback {
                            self.playFromStepIndex = flow.actions.count
                            self.startRecordingFromStep()
                        }
                    } else {
                        self.statusMessage = "Playback cancelled"
                    }
                }
            )
        }
    }

    func cancelPlayback() {
        playbackEngine.cancel()
        isPlaying = false
        statusMessage = "Playback cancelled"
    }

    func testSingleAction(_ action: RecordedAction, method: ActionAutomationMethod) {
        guard let webView = activeWebView else {
            lastError = "WebView not available"
            return
        }
        isTestingAction = true
        statusMessage = "Testing action with \(method.rawValue)..."

        Task {
            let startTime = Date()
            let success = await playbackEngine.testActionWithMethod(action, method: method, in: webView, textboxValues: textboxValues)
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)

            let result = ActionTestResult(
                actionId: action.id,
                method: method,
                success: success,
                durationMs: elapsed
            )
            testActionResults.append(result)
            isTestingAction = false
            statusMessage = success ? "Action test PASSED (\(method.rawValue), \(elapsed)ms)" : "Action test FAILED (\(method.rawValue), \(elapsed)ms)"
        }
    }

    func testAllMethodsForAction(_ action: RecordedAction) {
        guard let webView = activeWebView else {
            lastError = "WebView not available"
            return
        }
        isTestingAction = true
        statusMessage = "Testing all methods..."

        Task {
            for method in ActionAutomationMethod.allCases {
                let startTime = Date()
                let success = await playbackEngine.testActionWithMethod(action, method: method, in: webView, textboxValues: textboxValues)
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)

                let result = ActionTestResult(
                    actionId: action.id,
                    method: method,
                    success: success,
                    durationMs: elapsed
                )
                testActionResults.append(result)

                if success {
                    statusMessage = "Found working method: \(method.rawValue) (\(elapsed)ms)"
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            isTestingAction = false
        }
    }

    func validateFingerprint() {
        guard let webView = activeWebView else { return }
        Task {
            let profile = await PPSRStealthService.shared.nextProfile()
            let score = await FingerprintValidationService.shared.validate(in: webView, profileSeed: profile.seed)
            fingerprintScore = score.formattedScore
        }
    }

    func exportFlow(_ flow: RecordedFlow) -> Data? {
        persistence.exportFlow(flow)
    }

    func importFlow(from data: Data) {
        if let flow = persistence.importFlow(from: data) {
            savedFlows.insert(flow, at: 0)
            persistence.saveFlows(savedFlows)
            statusMessage = "Imported '\(flow.name)'"
        } else {
            lastError = "Failed to import flow — invalid data format"
            statusMessage = "Import failed — invalid data"
        }
    }

    var formattedDuration: String {
        let seconds = recordingDurationMs / 1000.0
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let remaining = Int(seconds) % 60
        return "\(minutes)m \(remaining)s"
    }
}

nonisolated enum ActionAutomationMethod: String, Codable, Sendable, CaseIterable {
    case humanClick = "Human Touch Chain"
    case jsClick = "JS Click"
    case pointerDispatch = "Pointer+Touch Dispatch"
    case formSubmit = "Form Submit"
    case enterKey = "Enter Key"
    case ocrTextDetect = "OCR Text Detect"
    case coordinateClick = "Coordinate Click"
    case visionMLDetect = "Vision ML Detect"
    case screenshotCropNav = "Screenshot Crop Nav"
    case focusThenClick = "Focus Then Click"
    case tabNavigation = "Tab Navigation"
    case nativeSetterFill = "Native Setter Fill"
    case execCommandInsert = "ExecCommand Insert"
    case mouseHoverThenClick = "Mouse Hover+Click"
}

nonisolated struct ActionTestResult: Sendable, Identifiable {
    let id: String = UUID().uuidString
    let actionId: String
    let method: ActionAutomationMethod
    let success: Bool
    let durationMs: Int
}
