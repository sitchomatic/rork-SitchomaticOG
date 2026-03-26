import SwiftUI
import WebKit

struct DebugLoginButtonView: View {
    let vm: LoginViewModel
    @State private var session: LoginSiteWebSession?
    @State private var isPageLoaded: Bool = false
    @State private var isScanning: Bool = false
    @State private var attempts: [DebugClickAttempt] = []
    @State private var selectedURL: URL?
    @State private var buttonLocation: DebugLoginButtonConfig.ButtonLocation?
    @State private var showLocationPicker: Bool = false
    @State private var scanProgress: Double = 0
    @State private var currentMethodName: String = ""
    @State private var statusMessage: String = "Select a URL and load the page to begin"
    @State private var showCloneSheet: Bool = false
    @State private var savedConfigs: [String: DebugLoginButtonConfig] = [:]
    @State private var showSavedConfigs: Bool = false

    private let debugService = DebugLoginButtonService.shared

    var body: some View {
        List {
            instructionSection
            urlSelectionSection
            if isPageLoaded {
                buttonLocationSection
                scanControlSection
            }
            if !attempts.isEmpty {
                attemptResultsSection
            }
            savedConfigsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Debug Login Button")
        .onAppear {
            savedConfigs = debugService.configs
        }
    }

    private var instructionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "target")
                        .font(.title2)
                        .foregroundStyle(.red)
                    Text("Login Button Debugger")
                        .font(.headline)
                }
                Text("This tool tries dozens of click methods on the login button one after another. Either the app auto-detects success, or you confirm which method worked. The successful method is saved per URL and reused automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var urlSelectionSection: some View {
        Section("Target URL") {
            let rotatingURLs = vm.urlRotation.activeURLs
            ForEach(rotatingURLs) { rotURL in
                if let url = rotURL.url {
                    Button {
                        selectedURL = url
                        statusMessage = "Loading \(url.host ?? "")..."
                        loadPage(url: url)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedURL == url ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedURL == url ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rotURL.host)
                                    .font(.system(.subheadline, design: .monospaced, weight: .medium))
                                    .foregroundStyle(.primary)
                                if let config = debugService.configFor(url: url.absoluteString), let method = config.successfulMethod {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                        Text("Saved: \(method.methodName)")
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            Spacer()
                            if selectedURL == url && !isPageLoaded {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                }
            }

            if isPageLoaded {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Page loaded: \(selectedURL?.host ?? "")")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var buttonLocationSection: some View {
        Section("Button Location (Optional)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Optionally mark where the login button is. This enables coordinate-based click methods in addition to DOM-based ones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let loc = buttonLocation {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Button at (\(Int(loc.absoluteX)), \(Int(loc.absoluteY)))")
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                            if let tag = loc.elementTag {
                                Text("Element: <\(tag)> \(loc.elementText ?? "")")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Clear") {
                            buttonLocation = nil
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.08))
                    .clipShape(.rect(cornerRadius: 8))
                } else {
                    Button {
                        detectButtonLocation()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "scope")
                            Text("Auto-Detect Button Location")
                                .font(.subheadline.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(.rect(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private var scanControlSection: some View {
        Section("Scan Control") {
            VStack(spacing: 12) {
                Text(statusMessage)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isScanning {
                    VStack(spacing: 6) {
                        ProgressView(value: scanProgress)
                            .tint(.red)
                        HStack {
                            Text("Method \(debugService.currentAttemptIndex + 1)/\(debugService.totalMethods + (buttonLocation != nil ? 10 : 0))")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(currentMethodName)
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                                .foregroundStyle(.red)
                        }
                    }

                    Button {
                        debugService.stop()
                        isScanning = false
                        statusMessage = "Scan stopped by user"
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                            Text("Stop Scan")
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.15))
                        .foregroundStyle(.red)
                        .clipShape(.rect(cornerRadius: 10))
                    }
                } else {
                    Button {
                        startScan()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.circle.fill")
                            Text("Start Full Debug Scan")
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red)
                        .foregroundStyle(.white)
                        .clipShape(.rect(cornerRadius: 10))
                    }

                    if let url = selectedURL, debugService.hasSuccessfulMethod(for: url.absoluteString) {
                        Button {
                            replaySaved()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                Text("Replay Saved Method")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(.rect(cornerRadius: 10))
                        }
                    }
                }
            }
        }
    }

    private var attemptResultsSection: some View {
        Section("Results (\(attempts.count) methods tried)") {
            let successAttempts = attempts.filter { $0.status == .success || $0.status == .userConfirmed }
            let failedAttempts = attempts.filter { $0.status == .failed }

            if !successAttempts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("\(successAttempts.count) possible success(es) detected")
                            .font(.subheadline.bold())
                            .foregroundStyle(.green)
                    }
                    Text("If the login didn't actually work, tap a method below to manually confirm the correct one.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color.green.opacity(0.06))
                .clipShape(.rect(cornerRadius: 8))
            }

            ForEach(attempts) { attempt in
                DebugAttemptRow(
                    attempt: attempt,
                    onConfirmSuccess: {
                        confirmSuccess(attempt)
                    }
                )
            }

            if !successAttempts.isEmpty && selectedURL != nil {
                Button {
                    showCloneSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc.fill")
                        Text("Clone to Other URLs")
                            .font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue.opacity(0.15))
                    .foregroundStyle(.blue)
                    .clipShape(.rect(cornerRadius: 10))
                }
                .sheet(isPresented: $showCloneSheet) {
                    CloneConfigSheet(
                        sourceURL: selectedURL?.absoluteString ?? "",
                        allURLs: vm.urlRotation.activeURLs.compactMap(\.url).map(\.absoluteString),
                        debugService: debugService
                    )
                }
            }

            HStack {
                Text("\(failedAttempts.count) failed")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.red)
                Spacer()
                Text("\(successAttempts.count) detected")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.green)
            }
        }
    }

    private var savedConfigsSection: some View {
        Section("Saved Button Configs (\(savedConfigs.count))") {
            if savedConfigs.isEmpty {
                Text("No saved configs yet. Run a debug scan to find working methods.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(savedConfigs.keys.sorted()), id: \.self) { host in
                    if let config = savedConfigs[host] {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: config.userConfirmed ? "checkmark.seal.fill" : "checkmark.circle")
                                    .foregroundStyle(config.userConfirmed ? .green : .orange)
                                    .font(.caption)
                                Text(host)
                                    .font(.system(.caption, design: .monospaced, weight: .bold))
                                Spacer()
                                if config.userConfirmed {
                                    Text("USER")
                                        .font(.system(.caption2, design: .monospaced, weight: .heavy))
                                        .foregroundStyle(.green)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.12))
                                        .clipShape(Capsule())
                                } else {
                                    Text("AUTO")
                                        .font(.system(.caption2, design: .monospaced, weight: .heavy))
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                            if let method = config.successfulMethod {
                                Text(method.methodName)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text("Attempt #\(config.successfulAttemptIndex ?? 0 + 1) of \(config.totalAttempts) | \(method.responseTimeMs)ms")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                debugService.deleteConfig(forURL: "https://\(host)")
                                savedConfigs = debugService.configs
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func loadPage(url: URL) {
        isPageLoaded = false
        attempts.removeAll()

        Task {
            let newSession = LoginSiteWebSession(targetURL: url)
            newSession.stealthEnabled = vm.stealthEnabled
            await newSession.setUp(wipeAll: true)

            let loaded = await newSession.loadPage(timeout: AutomationSettings.minimumTimeoutSeconds)
            if loaded {
                session = newSession
                isPageLoaded = true
                statusMessage = "Page loaded. Ready to scan."
                vm.log("DebugLoginButton: page loaded for \(url.host ?? "")", level: .success)
            } else {
                statusMessage = "Failed to load page: \(newSession.lastNavigationError ?? "unknown")"
                vm.log("DebugLoginButton: page load failed — \(newSession.lastNavigationError ?? "unknown")", level: .error)
                newSession.tearDown(wipeAll: true)
            }
        }
    }

    private func detectButtonLocation() {
        guard let session else { return }
        Task {
            let js = """
            (function(){
                var terms=['log in','login','sign in','signin','submit','continue'];
                var all=document.querySelectorAll('button,input[type="submit"],a,[role="button"],span,div');
                for(var i=0;i<all.length;i++){
                    var el=all[i];
                    var text=(el.textContent||el.value||'').replace(/[\\s]+/g,' ').toLowerCase().trim();
                    if(text.length>50)continue;
                    for(var t=0;t<terms.length;t++){
                        if(text===terms[t]||(text.indexOf(terms[t])!==-1&&text.length<30)){
                            var r=el.getBoundingClientRect();
                            if(r.width===0||r.height===0)continue;
                            return JSON.stringify({
                                x:r.left+r.width/2,
                                y:r.top+r.height/2,
                                w:r.width,
                                h:r.height,
                                tag:el.tagName,
                                text:text.substring(0,30),
                                sel:el.id?'#'+el.id:(el.className?'.'+el.className.split(' ')[0]:'')
                            });
                        }
                    }
                }
                return'NOT_FOUND';
            })()
            """
            let result = await session.executeJS(js)
            if let result, result != "NOT_FOUND",
               let data = result.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let x = json["x"] as? Double ?? 0
                let y = json["y"] as? Double ?? 0
                let vw = session.getViewportSize().width
                let vh = session.getViewportSize().height
                buttonLocation = DebugLoginButtonConfig.ButtonLocation(
                    relativeX: x / vw,
                    relativeY: y / vh,
                    absoluteX: x,
                    absoluteY: y,
                    viewportWidth: vw,
                    viewportHeight: vh,
                    elementTag: json["tag"] as? String,
                    elementText: json["text"] as? String,
                    elementSelector: json["sel"] as? String
                )
                statusMessage = "Button detected at (\(Int(x)), \(Int(y)))"
                vm.log("DebugLoginButton: auto-detected button at (\(Int(x)),\(Int(y)))", level: .success)
            } else {
                statusMessage = "Could not auto-detect button location"
                vm.log("DebugLoginButton: auto-detect failed — try marking manually or proceed without", level: .warning)
            }
        }
    }

    private func startScan() {
        guard let session, let url = selectedURL else { return }
        isScanning = true
        attempts.removeAll()
        statusMessage = "Scanning..."

        debugService.onAttemptUpdate = { attempt in
            if let idx = attempts.firstIndex(where: { $0.id == attempt.id }) {
                attempts[idx] = attempt
            } else {
                attempts.append(attempt)
            }
            let total = Double(debugService.totalMethods + (buttonLocation != nil ? 10 : 0))
            scanProgress = total > 0 ? Double(attempt.index + 1) / total : 0
            currentMethodName = attempt.methodName
            statusMessage = "[\(attempt.index + 1)] \(attempt.methodName): \(attempt.status.rawValue)"
        }

        debugService.onLog = { message, level in
            vm.log("DebugBtn: \(message)", level: level)
        }

        Task {
            let results = await debugService.runFullDebugScan(
                session: session,
                targetURL: url,
                buttonLocation: buttonLocation
            )
            attempts = results
            isScanning = false
            savedConfigs = debugService.configs

            let successCount = results.filter { $0.status == .success }.count
            if successCount > 0 {
                statusMessage = "Scan complete! \(successCount) method(s) auto-detected as working"
            } else {
                statusMessage = "Scan complete. No auto-detected success — review results and confirm manually if one worked"
            }
        }
    }

    private func replaySaved() {
        guard let session, let url = selectedURL else { return }
        Task {
            statusMessage = "Replaying saved method..."
            let result = await debugService.replaySuccessfulMethod(session: session, url: url.absoluteString)
            statusMessage = result.success ? "Replay SUCCESS: \(result.detail)" : "Replay FAILED: \(result.detail)"
        }
    }

    private func confirmSuccess(_ attempt: DebugClickAttempt) {
        guard let session, let url = selectedURL else { return }
        debugService.confirmUserSuccess(attempt: attempt, session: session, targetURL: url, buttonLocation: buttonLocation)
        savedConfigs = debugService.configs
        if let idx = attempts.firstIndex(where: { $0.id == attempt.id }) {
            attempts[idx].status = .userConfirmed
        }
        statusMessage = "User confirmed: '\(attempt.methodName)' saved for \(url.host ?? "")"
        vm.log("DebugLoginButton: user confirmed '\(attempt.methodName)' for \(url.host ?? "")", level: .success)
    }
}

struct DebugAttemptRow: View {
    let attempt: DebugClickAttempt
    let onConfirmSuccess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                Text("#\(attempt.index + 1)")
                    .font(.system(.caption2, design: .monospaced, weight: .heavy))
                    .foregroundStyle(.secondary)
                Text(attempt.methodName)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text("\(attempt.durationMs)ms")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Text(attempt.resultDetail.prefix(120))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if attempt.status == .success {
                Button {
                    onConfirmSuccess()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.thumbsup.fill")
                        Text("Confirm This Worked")
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.15))
                    .foregroundStyle(.green)
                    .clipShape(Capsule())
                }
            }

            if attempt.status == .failed {
                Button {
                    onConfirmSuccess()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.thumbsup")
                        Text("Actually This Worked")
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: String {
        switch attempt.status {
        case .pending: "circle"
        case .running: "arrow.triangle.2.circlepath"
        case .success: "checkmark.circle.fill"
        case .failed: "xmark.circle"
        case .skipped: "forward.fill"
        case .userConfirmed: "checkmark.seal.fill"
        }
    }

    private var statusColor: Color {
        switch attempt.status {
        case .pending: .secondary
        case .running: .orange
        case .success: .green
        case .failed: .red
        case .skipped: .secondary
        case .userConfirmed: .green
        }
    }
}

struct CloneConfigSheet: View {
    let sourceURL: String
    let allURLs: [String]
    let debugService: DebugLoginButtonService
    @Environment(\.dismiss) private var dismiss
    @State private var selectedURLs: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Clone the working login button method to other URLs with similar login pages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Select Target URLs") {
                    ForEach(allURLs.filter { $0 != sourceURL }, id: \.self) { url in
                        Button {
                            if selectedURLs.contains(url) {
                                selectedURLs.remove(url)
                            } else {
                                selectedURLs.insert(url)
                            }
                        } label: {
                            HStack {
                                Image(systemName: selectedURLs.contains(url) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedURLs.contains(url) ? .blue : .secondary)
                                Text(URL(string: url)?.host ?? url)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        debugService.cloneConfig(from: sourceURL, to: Array(selectedURLs))
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc.fill")
                            Text("Clone to \(selectedURLs.count) URL(s)")
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .disabled(selectedURLs.isEmpty)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Clone Config")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
