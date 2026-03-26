import SwiftUI
import UniformTypeIdentifiers

struct PPSRSettingsView: View {
    @Bindable var vm: PPSRAutomationViewModel

    @State private var showEmailImport: Bool = false
    @State private var emailCSVText: String = ""
    @State private var cropX: String = ""
    @State private var cropY: String = ""
    @State private var cropW: String = ""
    @State private var cropH: String = ""
    @State private var showCropEditor: Bool = false
    @State private var showPresetNamePrompt: Bool = false
    @State private var newPresetName: String = ""
    @State private var showSchedulePicker: Bool = false
    @State private var scheduledDate: Date = Date().addingTimeInterval(3600)
    @State private var scheduleFilter: TestSchedule.CardFilter = .allUntested
    private let proxyService = ProxyRotationService.shared

    var body: some View {
        List {
            connectionModeSection
            batchPresetsSection
            billerPoolSection
            automationSection
            autoRetrySection
            concurrencySection
            stealthSection
            schedulingSection
            emailSection
            screenshotSection
            debugSection
            exportHistorySection
            iCloudSection
            settingsAndTestingLinkSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("PPSR Settings")
        .sheet(isPresented: $showEmailImport) { emailImportSheet }
        .sheet(isPresented: $showCropEditor) { cropEditorSheet }
        .alert("Save Preset", isPresented: $showPresetNamePrompt) {
            TextField("Preset Name", text: $newPresetName)
            Button("Save") {
                guard !newPresetName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                vm.saveCurrentAsPreset(name: newPresetName)
                newPresetName = ""
            }
            Button("Cancel", role: .cancel) { newPresetName = "" }
        } message: {
            Text("Enter a name for the current settings configuration.")
        }
        .sheet(isPresented: $showSchedulePicker) { schedulePickerSheet }
    }

    private var connectionModeSection: some View {
        Section {
            Picker(selection: Binding(
                get: { proxyService.unifiedConnectionMode },
                set: { proxyService.setUnifiedConnectionMode($0) }
            )) {
                ForEach(ConnectionMode.allCases, id: \.self) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "network.badge.shield.half.filled").foregroundStyle(.blue)
                    Text("Connection Mode")
                }
            }
            .pickerStyle(.menu)
            .sensoryFeedback(.impact(weight: .medium), trigger: proxyService.unifiedConnectionMode)

            HStack(spacing: 10) {
                Image(systemName: proxyService.unifiedConnectionMode.icon)
                    .foregroundStyle(connectionModeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Active Mode").font(.subheadline.bold())
                    Text("All targets use \(proxyService.unifiedConnectionMode.label)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(proxyService.unifiedConnectionMode.label)
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(connectionModeColor)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(connectionModeColor.opacity(0.12)).clipShape(Capsule())
            }
        } header: {
            HStack {
                Image(systemName: "network.badge.shield.half.filled")
                Text("Connection Mode")
                Spacer()
                Text(proxyService.unifiedConnectionMode.label)
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(connectionModeColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(connectionModeColor.opacity(0.12))
                    .clipShape(Capsule())
            }
        } footer: {
            Text("Switching modes applies globally to Joe Fortune, Ignition, and PPSR.")
        }
    }

    private var connectionModeColor: Color {
        switch proxyService.unifiedConnectionMode {
        case .direct: .green
        case .proxy: .blue
        case .openvpn: .indigo
        case .wireguard: .purple
        case .dns: .cyan
        case .nodeMaven: .teal
        case .hybrid: .mint
        }
    }

    private var settingsAndTestingLinkSection: some View {
        Section {
            Button {
                UserDefaults.standard.set(ActiveAppMode.settingsAndTesting.rawValue, forKey: "activeAppMode")
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "gearshape.2.fill")
                            .font(.body)
                            .foregroundStyle(.blue)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Settings & Testing").font(.subheadline.bold())
                        Text("Network, Super Test, IP Score, Nord Config, Debug, Import/Export")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.forward.circle.fill")
                        .font(.title3).foregroundStyle(.blue)
                }
            }
        } header: {
            Label("Global", systemImage: "globe")
        } footer: {
            Text("Device-wide settings, testing tools, diagnostics, and data management.")
        }
    }

    private var stealthSection: some View {
        Section {
            Toggle(isOn: $vm.stealthEnabled) {
                HStack(spacing: 10) {
                    Image(systemName: "eye.slash.fill").foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ultra Stealth Mode").font(.body)
                        Text("Rotating user agents, fingerprints & viewports").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.purple)
            .sensoryFeedback(.impact(weight: .light), trigger: vm.stealthEnabled)
        } header: {
            Text("Stealth")
        } footer: {
            Text(vm.stealthEnabled ? "Each session uses a unique browser identity. Canvas, WebGL, timezone and navigator properties are spoofed." : "Enable to rotate browser fingerprints across sessions.")
        }
    }

    private var batchPresetsSection: some View {
        Section {
            ForEach(vm.batchPresets) { preset in
                Button {
                    vm.applyPreset(preset)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.below.square.filled.and.square")
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name).font(.subheadline.bold()).foregroundStyle(.primary)
                            Text("\(preset.maxConcurrency) sessions · \(preset.stealthEnabled ? "Stealth" : "Standard") · \(Int(preset.testTimeout))s timeout")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Apply")
                            .font(.caption.bold())
                            .foregroundStyle(.cyan)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { vm.deletePreset(preset) } label: { Label("Delete", systemImage: "trash") }
                }
            }
            Button {
                showPresetNamePrompt = true
            } label: {
                Label("Save Current as Preset", systemImage: "plus.circle")
                    .foregroundStyle(.cyan)
            }
        } header: {
            Text("Batch Presets")
        } footer: {
            Text("Save and quickly switch between different batch configurations.")
        }
    }

    private var billerPoolSection: some View {
        Section {
            NavigationLink {
                BPointPoolManagementView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "building.columns.fill").foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BPoint Biller Pool").font(.body)
                        let pool = BPointBillerPoolService.shared
                        Text("\(pool.activeBillerCount) active / \(pool.blacklistedCount) blocked / \(pool.totalBillerCount) total")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let pool = BPointBillerPoolService.shared
                    Text(String(format: "%.0f%%", pool.poolHealthPercentage))
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(pool.poolHealthPercentage > 75 ? .green : pool.poolHealthPercentage > 40 ? .yellow : .red)
                }
            }
        } header: {
            Label("BPoint Biller Pool", systemImage: "circle.grid.3x3.fill")
        } footer: {
            Text("Manage the pool of \(BPointBillerPoolService.shared.totalBillerCount) biller codes used for BPoint tests. Bad billers are auto-blacklisted.")
        }
    }

    private var automationSection: some View {
        Section {
            Toggle(isOn: $vm.retrySubmitOnFail) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Retry Submit on Fail").font(.body)
                        Text("Automatically retries submit if no clear result").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.orange)
            .sensoryFeedback(.impact(weight: .light), trigger: vm.retrySubmitOnFail)
        } header: {
            Text("Automation")
        }
    }

    private var autoRetrySection: some View {
        Section {
            Toggle(isOn: $vm.autoRetryEnabled) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-Retry Failed").font(.body)
                        Text("Requeue timeout/connection failures with backoff").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.mint)
            .sensoryFeedback(.impact(weight: .light), trigger: vm.autoRetryEnabled)

            if vm.autoRetryEnabled {
                Stepper(value: $vm.autoRetryMaxAttempts, in: 1...5) {
                    HStack(spacing: 10) {
                        Image(systemName: "number.circle").foregroundStyle(.mint)
                        Text("Max Retries: \(vm.autoRetryMaxAttempts)")
                    }
                }
            }
        } header: {
            Text("Auto-Retry")
        } footer: {
            Text(vm.autoRetryEnabled ? "Cards that fail due to timeout or connection issues will be automatically retried up to \(vm.autoRetryMaxAttempts) time(s) with increasing delay." : "Enable to automatically retry cards that fail due to network issues.")
        }
    }

    private var schedulingSection: some View {
        Section {
            if vm.schedules.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.clock").foregroundStyle(.secondary)
                    Text("No scheduled tests").foregroundStyle(.secondary)
                }
            } else {
                ForEach(vm.schedules) { schedule in
                    HStack(spacing: 10) {
                        Image(systemName: "calendar.badge.clock").foregroundStyle(.indigo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DateFormatters.mediumDateTime.string(from: schedule.scheduledDate)).font(.subheadline.bold())
                            Text(schedule.cardFilter.rawValue).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if schedule.isActive {
                            Text("Active").font(.caption2.bold()).foregroundStyle(.green)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { vm.cancelSchedule(schedule) } label: { Label("Cancel", systemImage: "xmark") }
                    }
                }
            }
            Button {
                scheduledDate = Date().addingTimeInterval(3600)
                showSchedulePicker = true
            } label: {
                Label("Schedule a Test", systemImage: "plus.circle")
                    .foregroundStyle(.indigo)
            }
        } header: {
            Text("Test Scheduling")
        } footer: {
            Text("Schedule tests to run at a specific time.")
        }
    }

    private var schedulePickerSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                DatePicker("Start At", selection: $scheduledDate, in: Date()...)
                    .datePickerStyle(.graphical)

                Picker("Card Filter", selection: $scheduleFilter) {
                    ForEach(TestSchedule.CardFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                Spacer()
            }
            .padding()
            .navigationTitle("Schedule Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showSchedulePicker = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        vm.scheduleTest(at: scheduledDate, filter: scheduleFilter)
                        showSchedulePicker = false
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var exportHistorySection: some View {
        Section {
            let records = vm.exportHistory.records
            if records.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    Text("No exports recorded").foregroundStyle(.secondary)
                }
            } else {
                ForEach(records.prefix(5)) { record in
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.up").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(record.cardCount) cards (\(record.format))").font(.subheadline)
                            Text("\(record.exportType) · \(DateFormatters.mediumDateTime.string(from: record.timestamp))").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                if records.count > 5 {
                    Text("\(records.count - 5) more exports...")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    vm.exportHistory.clearHistory()
                } label: {
                    Label("Clear Export History", systemImage: "trash")
                }
            }
        } header: {
            Text("Export History")
        } footer: {
            Text("Tracks when exports were done, how many cards, and what format.")
        }
    }

    private var screenshotSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.dashed").foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screenshot Mode").font(.body)
                    Text("Full-page capture on every test").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Full Page").font(.system(.caption, design: .monospaced, weight: .bold)).foregroundStyle(.indigo)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(Color.indigo.opacity(0.12)).clipShape(Capsule())
            }

            Button {
                cropX = vm.screenshotCropRect == .zero ? "" : "\(Int(vm.screenshotCropRect.origin.x))"
                cropY = vm.screenshotCropRect == .zero ? "" : "\(Int(vm.screenshotCropRect.origin.y))"
                cropW = vm.screenshotCropRect == .zero ? "" : "\(Int(vm.screenshotCropRect.size.width))"
                cropH = vm.screenshotCropRect == .zero ? "" : "\(Int(vm.screenshotCropRect.size.height))"
                showCropEditor = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "crop").foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Focus Crop Area").font(.body)
                        Text(vm.screenshotCropRect == .zero ? "No crop — showing full page" : "Crop: \(Int(vm.screenshotCropRect.origin.x)),\(Int(vm.screenshotCropRect.origin.y)) \(Int(vm.screenshotCropRect.width))×\(Int(vm.screenshotCropRect.height))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }

            if vm.screenshotCropRect != .zero {
                Button(role: .destructive) {
                    vm.screenshotCropRect = .zero
                    vm.persistSettings()
                    vm.log("Cleared screenshot focus crop area")
                } label: {
                    Label("Clear Focus Crop", systemImage: "xmark.circle")
                }
            }
        } header: {
            Text("Screenshots")
        }
    }

    private var debugSection: some View {
        Section {
            Toggle(isOn: $vm.debugMode) {
                HStack(spacing: 10) {
                    Image(systemName: "ladybug.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Debug Mode").font(.body)
                        Text("Captures full-page screenshot per test").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.orange)

            if vm.debugMode {
                NavigationLink {
                    PPSRDebugScreenshotsView(vm: vm)
                } label: {
                    HStack {
                        Image(systemName: "photo.stack").foregroundStyle(.orange)
                        Text("Debug Screenshots")
                        Spacer()
                        Text("\(vm.debugScreenshots.count)").font(.system(.caption, design: .monospaced, weight: .bold)).foregroundStyle(.secondary)
                    }
                }

                if !vm.debugScreenshots.isEmpty {
                    Button(role: .destructive) { vm.debugScreenshots.removeAll() } label: { Label("Clear All Screenshots", systemImage: "trash") }
                }
            }
            NavigationLink {
                DebugLogView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Full Debug Log").font(.body)
                        Text("View debug entries").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        } header: {
            Text("Debug")
        } footer: {
            Text(vm.debugMode ? "Full-page screenshot captured per test." : "Enable to capture WebView screenshots during automation.")
        }
    }





    private var iCloudSection: some View {
        Section {
            Button { vm.syncFromiCloud() } label: {
                HStack(spacing: 10) { Image(systemName: "icloud.and.arrow.down").foregroundStyle(.blue); Text("Sync from iCloud") }
            }
            Button {
                vm.persistCards()
                vm.log("Forced save to local + iCloud", level: .success)
            } label: {
                HStack(spacing: 10) { Image(systemName: "icloud.and.arrow.up").foregroundStyle(.blue); Text("Force Save to iCloud") }
            }
        } header: {
            Text("iCloud Sync")
        } footer: {
            Text("Cards are automatically saved locally and to iCloud.")
        }
    }

    private var emailSection: some View {
        Section {
            Toggle(isOn: $vm.useEmailRotation) {
                HStack(spacing: 10) {
                    Image(systemName: "envelope.arrow.triangle.branch.fill").foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Generate Email").font(.body)
                        Text("Rotate through uploaded email list").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.teal)

            if vm.useEmailRotation {
                HStack {
                    Image(systemName: "list.bullet").foregroundStyle(.teal)
                    Text("Email Pool")
                    Spacer()
                    Text("\(vm.rotationEmailCount) emails").font(.system(.caption, design: .monospaced, weight: .bold)).foregroundStyle(.secondary)
                }
                Button { showEmailImport = true } label: { Label("Import Email CSV", systemImage: "square.and.arrow.down") }
                if vm.rotationEmailCount > 0 {
                    Button { vm.resetRotationEmailsToDefault() } label: { Label("Reset to Default List", systemImage: "arrow.counterclockwise") }
                    Button(role: .destructive) { vm.clearRotationEmails() } label: { Label("Clear Email List", systemImage: "trash") }
                }
            }

            if !vm.useEmailRotation {
                TextField("Test email", text: $vm.testEmail)
                    .keyboardType(.emailAddress).textContentType(.emailAddress)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
            }
        } header: {
            Text("Email")
        } footer: {
            Text(vm.useEmailRotation ? "Each test uses the next email from the pool." : "Applied to all PPSR checks.")
        }
    }

    private var concurrencySection: some View {
        Section {
            Picker("Max Sessions", selection: $vm.maxConcurrency) {
                ForEach(1...8, id: \.self) { n in Text("\(n)").tag(n) }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Concurrency")
        } footer: {
            Text("Up to 8 concurrent WKWebView sessions.")
        }
    }





    private var cropEditorSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Focus Crop Area").font(.headline)
                    Text("Define a rectangle (in points) to crop from the full-page screenshot.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        cropField("X", text: $cropX)
                        cropField("Y", text: $cropY)
                    }
                    HStack(spacing: 12) {
                        cropField("Width", text: $cropW)
                        cropField("Height", text: $cropH)
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Focus Crop").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showCropEditor = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let x = Double(cropX) ?? 0; let y = Double(cropY) ?? 0
                        let w = Double(cropW) ?? 0; let h = Double(cropH) ?? 0
                        if w > 0 && h > 0 {
                            vm.screenshotCropRect = CGRect(x: x, y: y, width: w, height: h)
                            vm.log("Set focus crop: \(Int(x)),\(Int(y)) \(Int(w))×\(Int(h))")
                        } else {
                            vm.screenshotCropRect = .zero
                        }
                        vm.persistSettings()
                        showCropEditor = false
                    }
                }
            }
        }
        .presentationDetents([.medium]).presentationDragIndicator(.visible)
    }

    private func cropField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.bold()).foregroundStyle(.secondary)
            TextField("0", text: text)
                .keyboardType(.numberPad).font(.system(.body, design: .monospaced))
                .padding(10).background(Color(.tertiarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 8))
        }
    }

    private var emailImportSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Import Emails").font(.headline)
                    Text("Paste email addresses separated by commas or newlines.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TextEditor(text: $emailCSVText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden).padding(12)
                    .background(Color(.tertiarySystemGroupedBackground)).clipShape(.rect(cornerRadius: 10))
                    .frame(minHeight: 180)
                Spacer()
            }
            .padding()
            .navigationTitle("Import Emails").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showEmailImport = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        let count = vm.importEmails(emailCSVText)
                        emailCSVText = ""
                        showEmailImport = false
                        vm.log("Imported \(count) emails for rotation", level: .success)
                    }
                    .disabled(emailCSVText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

}
