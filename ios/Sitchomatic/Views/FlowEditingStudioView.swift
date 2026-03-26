import SwiftUI

struct FlowEditingStudioView: View {
    @State private var flow: RecordedFlow
    @State private var selectedActionIds: Set<String> = []
    @State private var showActionEditor: Bool = false
    @State private var editingAction: RecordedAction?
    @State private var editingIndex: Int?
    @State private var showBulkTimingSheet: Bool = false
    @State private var showDuplicateSheet: Bool = false
    @State private var showTextboxMappingEditor: Bool = false
    @State private var showInsertActionSheet: Bool = false
    @State private var insertAtIndex: Int = 0
    @State private var flowName: String
    @State private var filterType: RecordedActionType?
    @State private var searchText: String = ""
    @State private var globalTimeScale: Double = 1.0
    @State private var newDuplicateName: String = ""
    @State private var showDeleteConfirmation: Bool = false
    @State private var showOptimizeSheet: Bool = false
    @State private var showSettingsSheet: Bool = false
    @State private var showActionTestSheet: Bool = false
    @State private var testingAction: RecordedAction?
    @State private var automationSettings: AutomationSettings = AutomationSettings()

    let onSave: (RecordedFlow) -> Void
    let onDuplicate: (RecordedFlow) -> Void

    private let persistence = FlowPersistenceService.shared

    init(flow: RecordedFlow, onSave: @escaping (RecordedFlow) -> Void, onDuplicate: @escaping (RecordedFlow) -> Void) {
        self._flow = State(initialValue: flow)
        self._flowName = State(initialValue: flow.name)
        self.onSave = onSave
        self.onDuplicate = onDuplicate
    }

    private var filteredActions: [RecordedAction] {
        var actions = flow.actions
        if let filter = filterType {
            actions = actions.filter { $0.type == filter }
        }
        if !searchText.isEmpty {
            actions = actions.filter { action in
                action.type.rawValue.localizedStandardContains(searchText) ||
                (action.targetSelector ?? "").localizedStandardContains(searchText) ||
                (action.textboxLabel ?? "").localizedStandardContains(searchText) ||
                (action.textContent ?? "").localizedStandardContains(searchText) ||
                (action.key ?? "").localizedStandardContains(searchText)
            }
        }
        return actions
    }

    private var actionTypeCounts: [(RecordedActionType, Int)] {
        var counts: [RecordedActionType: Int] = [:]
        for action in flow.actions {
            counts[action.type, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    var body: some View {
        List {
            flowInfoSection
            statsSection
            filterSection
            textboxMappingsSection
            actionsListSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Flow Studio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showBulkTimingSheet = true } label: {
                        Label("Bulk Timing Edit", systemImage: "clock.arrow.2.circlepath")
                    }
                    Button { showOptimizeSheet = true } label: {
                        Label("Optimize Flow", systemImage: "wand.and.stars")
                    }
                    Button { showDuplicateSheet = true } label: {
                        Label("Duplicate Flow", systemImage: "doc.on.doc")
                    }
                    Button { showSettingsSheet = true } label: {
                        Label("Automation Settings", systemImage: "gearshape.2.fill")
                    }
                    Divider()
                    Button { stripMouseMoves() } label: {
                        Label("Strip Mouse Moves", systemImage: "cursorarrow.slash")
                    }
                    Button { normalizeCoordinates() } label: {
                        Label("Normalize Coordinates", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete Selected (\(selectedActionIds.count))", systemImage: "trash")
                    }
                    .disabled(selectedActionIds.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    saveFlow()
                } label: {
                    Text("Save")
                        .fontWeight(.semibold)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search actions...")
        .sheet(isPresented: $showActionEditor) {
            if let action = editingAction, let index = editingIndex {
                NavigationStack {
                    ActionEditorView(action: action, index: index) { updated in
                        flow.actions[index] = updated
                        showActionEditor = false
                    }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
            }
        }
        .sheet(isPresented: $showBulkTimingSheet) {
            NavigationStack {
                BulkTimingEditorView(flow: $flow, globalTimeScale: $globalTimeScale)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showDuplicateSheet) {
            NavigationStack {
                DuplicateFlowSheet(originalName: flow.name, newName: $newDuplicateName) {
                    duplicateFlow()
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showTextboxMappingEditor) {
            NavigationStack {
                TextboxMappingEditorView(mappings: $flow.textboxMappings)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showInsertActionSheet) {
            NavigationStack {
                InsertActionView(insertAt: insertAtIndex) { newAction in
                    flow.actions.insert(newAction, at: min(insertAtIndex, flow.actions.count))
                    flow.actionCount = flow.actions.count
                    showInsertActionSheet = false
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showOptimizeSheet) {
            NavigationStack {
                FlowOptimizeView(flow: $flow)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showSettingsSheet) {
            NavigationStack {
                FlowSettingsView(settings: $automationSettings)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
        }
        .sheet(isPresented: $showActionTestSheet) {
            if let action = testingAction {
                NavigationStack {
                    ActionTestView(action: action)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
            }
        }
        .alert("Delete Selected Actions?", isPresented: $showDeleteConfirmation) {
            Button("Delete \(selectedActionIds.count)", role: .destructive) {
                flow.actions.removeAll { selectedActionIds.contains($0.id) }
                flow.actionCount = flow.actions.count
                selectedActionIds.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Sections

    private var flowInfoSection: some View {
        Section {
            HStack {
                Image(systemName: "pencil.line")
                    .foregroundStyle(.blue)
                TextField("Flow Name", text: $flowName)
                    .font(.system(.body, weight: .semibold))
            }

            LabeledContent("URL") {
                Text(flow.url)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            LabeledContent("Created") {
                Text(flow.createdAt, style: .date)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Duration") {
                Text(flow.formattedDuration)
                    .font(.system(.caption, design: .monospaced, weight: .bold))
            }
        } header: {
            Label("Flow Info", systemImage: "info.circle")
        }
    }

    private var statsSection: some View {
        Section {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
            ], spacing: 12) {
                StatCard(label: "Total", value: "\(flow.actions.count)", icon: "number", color: .blue)
                StatCard(label: "Clicks", value: "\(flow.actions.filter { $0.type == .click || $0.type == .mouseDown }.count)", icon: "hand.tap.fill", color: .green)
                StatCard(label: "Keys", value: "\(flow.actions.filter { $0.type == .keyDown }.count)", icon: "keyboard.fill", color: .orange)
                StatCard(label: "Scrolls", value: "\(flow.actions.filter { $0.type == .scroll }.count)", icon: "scroll.fill", color: .purple)
                StatCard(label: "Inputs", value: "\(flow.actions.filter { $0.type == .input || $0.type == .textboxEntry }.count)", icon: "textformat.abc", color: .cyan)
                StatCard(label: "Mouse", value: "\(flow.actions.filter { $0.type == .mouseMove }.count)", icon: "cursorarrow.motionlines", color: .secondary)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        } header: {
            Label("Action Breakdown", systemImage: "chart.bar.fill")
        }
    }

    private var filterSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FlowFilterChip(label: "All", isSelected: filterType == nil) {
                        filterType = nil
                    }
                    ForEach(actionTypeCounts, id: \.0) { type, count in
                        FlowFilterChip(label: "\(type.rawValue) (\(count))", isSelected: filterType == type) {
                            filterType = filterType == type ? nil : type
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        } header: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private var textboxMappingsSection: some View {
        Section {
            if flow.textboxMappings.isEmpty {
                HStack {
                    Image(systemName: "textformat.abc")
                        .foregroundStyle(.secondary)
                    Text("No textbox mappings detected")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            } else {
                ForEach(flow.textboxMappings) { mapping in
                    HStack(spacing: 10) {
                        Image(systemName: "textformat.abc")
                            .font(.caption)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mapping.label)
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                            Text("Key: \(mapping.placeholderKey)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !mapping.originalText.isEmpty {
                            Text(mapping.originalText)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Button {
                showTextboxMappingEditor = true
            } label: {
                Label("Edit Mappings", systemImage: "pencil")
            }
        } header: {
            Label("Textbox Mappings (\(flow.textboxMappings.count))", systemImage: "rectangle.and.text.magnifyingglass")
        }
    }

    private var actionsListSection: some View {
        Section {
            if filteredActions.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No actions match filter")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            } else {
                ForEach(Array(filteredActions.enumerated()), id: \.element.id) { displayIndex, action in
                    let realIndex = flow.actions.firstIndex(where: { $0.id == action.id }) ?? displayIndex
                    ActionRowView(
                        action: action,
                        index: realIndex,
                        isSelected: selectedActionIds.contains(action.id),
                        onSelect: {
                            if selectedActionIds.contains(action.id) {
                                selectedActionIds.remove(action.id)
                            } else {
                                selectedActionIds.insert(action.id)
                            }
                        },
                        onEdit: {
                            editingAction = action
                            editingIndex = realIndex
                            showActionEditor = true
                        },
                        onInsertBefore: {
                            insertAtIndex = realIndex
                            showInsertActionSheet = true
                        },
                        onInsertAfter: {
                            insertAtIndex = realIndex + 1
                            showInsertActionSheet = true
                        },
                        onDelete: {
                            flow.actions.remove(at: realIndex)
                            flow.actionCount = flow.actions.count
                            selectedActionIds.remove(action.id)
                        },
                        onTestAction: {
                            testingAction = action
                            showActionTestSheet = true
                        }
                    )
                }
                .onMove { source, destination in
                    flow.actions.move(fromOffsets: source, toOffset: destination)
                }
            }
        } header: {
            HStack {
                Label("Actions (\(filteredActions.count)/\(flow.actions.count))", systemImage: "list.bullet")
                Spacer()
                EditButton()
                    .font(.caption)
            }
        }
    }

    // MARK: - Operations

    private func saveFlow() {
        flow.name = flowName
        flow.actionCount = flow.actions.count
        flow.totalDurationMs = flow.actions.reduce(0) { $0 + $1.deltaFromPreviousMs }
        onSave(flow)
    }

    private func duplicateFlow() {
        let name = newDuplicateName.isEmpty ? "\(flow.name) (Copy)" : newDuplicateName
        let copy = RecordedFlow(
            name: name,
            url: flow.url,
            actions: flow.actions,
            textboxMappings: flow.textboxMappings,
            totalDurationMs: flow.totalDurationMs,
            actionCount: flow.actionCount
        )
        onDuplicate(copy)
        showDuplicateSheet = false
    }

    private func stripMouseMoves() {
        flow.actions.removeAll { $0.type == .mouseMove }
        flow.actionCount = flow.actions.count
    }

    private func normalizeCoordinates() {
        let viewportW: Double = 1280
        let viewportH: Double = 800
        for i in 0..<flow.actions.count {
            guard let pos = flow.actions[i].mousePosition else { continue }
            let normX = pos.x / viewportW
            let normY = pos.y / viewportH
            let newPos = RecordedMousePosition(
                x: normX * viewportW,
                y: normY * viewportH,
                viewportX: pos.viewportX,
                viewportY: pos.viewportY
            )
            flow.actions[i] = RecordedAction(
                id: flow.actions[i].id,
                type: flow.actions[i].type,
                timestampMs: flow.actions[i].timestampMs,
                deltaFromPreviousMs: flow.actions[i].deltaFromPreviousMs,
                mousePosition: newPos,
                scrollDeltaX: flow.actions[i].scrollDeltaX,
                scrollDeltaY: flow.actions[i].scrollDeltaY,
                keyCode: flow.actions[i].keyCode,
                key: flow.actions[i].key,
                code: flow.actions[i].code,
                charCode: flow.actions[i].charCode,
                targetSelector: flow.actions[i].targetSelector,
                targetTagName: flow.actions[i].targetTagName,
                targetType: flow.actions[i].targetType,
                textboxLabel: flow.actions[i].textboxLabel,
                textContent: flow.actions[i].textContent,
                button: flow.actions[i].button,
                buttons: flow.actions[i].buttons,
                holdDurationMs: flow.actions[i].holdDurationMs,
                isTrusted: flow.actions[i].isTrusted,
                shiftKey: flow.actions[i].shiftKey,
                ctrlKey: flow.actions[i].ctrlKey,
                altKey: flow.actions[i].altKey,
                metaKey: flow.actions[i].metaKey
            )
        }
    }
}

// MARK: - Subviews

private struct StatCard: View {
    let label: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
            Text(value)
                .font(.system(.title3, design: .monospaced, weight: .bold))
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.08))
        .clipShape(.rect(cornerRadius: 8))
    }
}

private struct FlowFilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.blue : Color(.tertiarySystemBackground))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
    }
}

private struct ActionRowView: View {
    let action: RecordedAction
    let index: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onInsertBefore: () -> Void
    let onInsertAfter: () -> Void
    let onDelete: () -> Void
    let onTestAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? .blue : .secondary)
            }
            .buttonStyle(.plain)

            Text("#\(index)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .trailing)

            Image(systemName: iconForType(action.type))
                .font(.system(size: 11))
                .foregroundStyle(colorForType(action.type))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(action.type.rawValue)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                HStack(spacing: 6) {
                    if let pos = action.mousePosition {
                        Text("(\(Int(pos.x)),\(Int(pos.y)))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if let key = action.key, !key.isEmpty {
                        Text(key)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                    if let label = action.textboxLabel {
                        Text(label)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.blue)
                    }
                }
            }

            Spacer()

            Text("+\(Int(action.deltaFromPreviousMs))ms")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button { onEdit() } label: {
                Label("Edit Action", systemImage: "pencil")
            }
            Button { onTestAction() } label: {
                Label("Test Action Methods", systemImage: "play.square.stack")
            }
            Button { onInsertBefore() } label: {
                Label("Insert Before", systemImage: "arrow.up.to.line")
            }
            Button { onInsertAfter() } label: {
                Label("Insert After", systemImage: "arrow.down.to.line")
            }
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
            Button { onEdit() } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .leading) {
            Button { onTestAction() } label: {
                Label("Test", systemImage: "play.square.stack")
            }
            .tint(.purple)
        }
    }

    private func iconForType(_ type: RecordedActionType) -> String {
        switch type {
        case .mouseMove: return "cursorarrow.motionlines"
        case .mouseDown, .mouseUp: return "cursorarrow.click"
        case .click: return "hand.tap.fill"
        case .doubleClick: return "hand.tap"
        case .scroll: return "scroll.fill"
        case .keyDown, .keyUp, .keyPress: return "keyboard.fill"
        case .touchStart, .touchEnd, .touchMove: return "hand.point.up.fill"
        case .focus: return "target"
        case .blur: return "circle.dotted"
        case .input: return "textformat.abc"
        case .pageLoad: return "globe"
        case .navigationStart: return "arrow.right"
        case .textboxEntry: return "character.cursor.ibeam"
        case .pause: return "pause.fill"
        }
    }

    private func colorForType(_ type: RecordedActionType) -> Color {
        switch type {
        case .mouseMove: return .secondary
        case .mouseDown, .mouseUp, .click, .doubleClick: return .green
        case .scroll: return .purple
        case .keyDown, .keyUp, .keyPress: return .orange
        case .touchStart, .touchEnd, .touchMove: return .pink
        case .focus: return .cyan
        case .blur: return .gray
        case .input, .textboxEntry: return .blue
        case .pageLoad, .navigationStart: return .indigo
        case .pause: return .yellow
        }
    }
}

// MARK: - Action Editor

struct ActionEditorView: View {
    @State private var action: RecordedAction
    let index: Int
    let onSave: (RecordedAction) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var posX: String = ""
    @State private var posY: String = ""
    @State private var viewportX: String = ""
    @State private var viewportY: String = ""
    @State private var deltaMs: String = ""
    @State private var scrollDX: String = ""
    @State private var scrollDY: String = ""
    @State private var keyValue: String = ""
    @State private var codeValue: String = ""
    @State private var keyCodeValue: String = ""
    @State private var textContent: String = ""
    @State private var textboxLabel: String = ""
    @State private var holdDuration: String = ""
    @State private var selectedType: RecordedActionType

    init(action: RecordedAction, index: Int, onSave: @escaping (RecordedAction) -> Void) {
        self._action = State(initialValue: action)
        self.index = index
        self.onSave = onSave
        self._selectedType = State(initialValue: action.type)
        self._posX = State(initialValue: action.mousePosition.map { "\(Int($0.x))" } ?? "")
        self._posY = State(initialValue: action.mousePosition.map { "\(Int($0.y))" } ?? "")
        self._viewportX = State(initialValue: action.mousePosition.map { "\(Int($0.viewportX))" } ?? "")
        self._viewportY = State(initialValue: action.mousePosition.map { "\(Int($0.viewportY))" } ?? "")
        self._deltaMs = State(initialValue: "\(Int(action.deltaFromPreviousMs))")
        self._scrollDX = State(initialValue: action.scrollDeltaX.map { "\(Int($0))" } ?? "0")
        self._scrollDY = State(initialValue: action.scrollDeltaY.map { "\(Int($0))" } ?? "0")
        self._keyValue = State(initialValue: action.key ?? "")
        self._codeValue = State(initialValue: action.code ?? "")
        self._keyCodeValue = State(initialValue: action.keyCode.map { "\($0)" } ?? "")
        self._textContent = State(initialValue: action.textContent ?? "")
        self._textboxLabel = State(initialValue: action.textboxLabel ?? "")
        self._holdDuration = State(initialValue: action.holdDurationMs.map { "\(Int($0))" } ?? "")
    }

    var body: some View {
        Form {
            Section("Action Type") {
                Picker("Type", selection: $selectedType) {
                    ForEach(RecordedActionType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
            }

            Section("Timing") {
                HStack {
                    Text("Delta from Previous")
                    Spacer()
                    TextField("ms", text: $deltaMs)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                    Text("ms").foregroundStyle(.secondary)
                }

                if !holdDuration.isEmpty || selectedType == .click || selectedType == .mouseDown {
                    HStack {
                        Text("Hold Duration")
                        Spacer()
                        TextField("ms", text: $holdDuration)
                            .keyboardType(.numberPad)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .monospaced))
                        Text("ms").foregroundStyle(.secondary)
                    }
                }
            }

            Section("Position") {
                HStack(spacing: 16) {
                    VStack(alignment: .leading) {
                        Text("X").font(.caption2).foregroundStyle(.tertiary)
                        TextField("X", text: $posX)
                            .keyboardType(.numberPad)
                            .font(.system(.body, design: .monospaced))
                    }
                    VStack(alignment: .leading) {
                        Text("Y").font(.caption2).foregroundStyle(.tertiary)
                        TextField("Y", text: $posY)
                            .keyboardType(.numberPad)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                HStack(spacing: 16) {
                    VStack(alignment: .leading) {
                        Text("Viewport X").font(.caption2).foregroundStyle(.tertiary)
                        TextField("VX", text: $viewportX)
                            .keyboardType(.numberPad)
                            .font(.system(.body, design: .monospaced))
                    }
                    VStack(alignment: .leading) {
                        Text("Viewport Y").font(.caption2).foregroundStyle(.tertiary)
                        TextField("VY", text: $viewportY)
                            .keyboardType(.numberPad)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }

            if selectedType == .scroll {
                Section("Scroll") {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading) {
                            Text("Delta X").font(.caption2).foregroundStyle(.tertiary)
                            TextField("DX", text: $scrollDX)
                                .keyboardType(.numbersAndPunctuation)
                                .font(.system(.body, design: .monospaced))
                        }
                        VStack(alignment: .leading) {
                            Text("Delta Y").font(.caption2).foregroundStyle(.tertiary)
                            TextField("DY", text: $scrollDY)
                                .keyboardType(.numbersAndPunctuation)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
            }

            if selectedType == .keyDown || selectedType == .keyUp || selectedType == .keyPress {
                Section("Key") {
                    TextField("Key", text: $keyValue)
                        .font(.system(.body, design: .monospaced))
                    TextField("Code", text: $codeValue)
                        .font(.system(.body, design: .monospaced))
                    HStack {
                        Text("Key Code")
                        Spacer()
                        TextField("0", text: $keyCodeValue)
                            .keyboardType(.numberPad)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }

            if selectedType == .input || selectedType == .textboxEntry {
                Section("Text") {
                    TextField("Textbox Label", text: $textboxLabel)
                    TextField("Text Content", text: $textContent)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section {
                Button {
                    saveAction()
                } label: {
                    HStack {
                        Spacer()
                        Label("Save Changes", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Edit Action #\(index)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func saveAction() {
        var mousePos: RecordedMousePosition?
        if let x = Double(posX), let y = Double(posY) {
            mousePos = RecordedMousePosition(
                x: x,
                y: y,
                viewportX: Double(viewportX) ?? x,
                viewportY: Double(viewportY) ?? y
            )
        }

        let updated = RecordedAction(
            id: action.id,
            type: selectedType,
            timestampMs: action.timestampMs,
            deltaFromPreviousMs: Double(deltaMs) ?? action.deltaFromPreviousMs,
            mousePosition: mousePos,
            scrollDeltaX: Double(scrollDX),
            scrollDeltaY: Double(scrollDY),
            keyCode: Int(keyCodeValue),
            key: keyValue.isEmpty ? nil : keyValue,
            code: codeValue.isEmpty ? nil : codeValue,
            charCode: action.charCode,
            targetSelector: action.targetSelector,
            targetTagName: action.targetTagName,
            targetType: action.targetType,
            textboxLabel: textboxLabel.isEmpty ? nil : textboxLabel,
            textContent: textContent.isEmpty ? nil : textContent,
            button: action.button,
            buttons: action.buttons,
            holdDurationMs: Double(holdDuration),
            isTrusted: action.isTrusted,
            shiftKey: action.shiftKey,
            ctrlKey: action.ctrlKey,
            altKey: action.altKey,
            metaKey: action.metaKey
        )
        onSave(updated)
    }
}

// MARK: - CaseIterable for RecordedActionType

extension RecordedActionType: CaseIterable {
    nonisolated static var allCases: [RecordedActionType] {
        [.mouseMove, .mouseDown, .mouseUp, .click, .doubleClick, .scroll,
         .keyDown, .keyUp, .keyPress, .touchStart, .touchEnd, .touchMove,
         .focus, .blur, .input, .pageLoad, .navigationStart, .textboxEntry, .pause]
    }
}

// MARK: - Bulk Timing Editor

struct BulkTimingEditorView: View {
    @Binding var flow: RecordedFlow
    @Binding var globalTimeScale: Double
    @Environment(\.dismiss) private var dismiss
    @State private var maxDelayMs: String = "3000"
    @State private var minDelayMs: String = "10"
    @State private var addJitter: Bool = true
    @State private var jitterPercent: Int = 20

    var body: some View {
        Form {
            Section("Time Scale") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scale: \(String(format: "%.1fx", globalTimeScale))")
                        .font(.system(.body, design: .monospaced, weight: .bold))
                    Slider(value: $globalTimeScale, in: 0.1...5.0, step: 0.1)
                        .tint(.orange)
                    Text("Multiply all action delays by this factor")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button("Apply Scale") {
                    applyTimeScale()
                }
            }

            Section("Clamp Delays") {
                HStack {
                    Text("Min Delay")
                    Spacer()
                    TextField("10", text: $minDelayMs)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                    Text("ms").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Max Delay")
                    Spacer()
                    TextField("3000", text: $maxDelayMs)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                    Text("ms").foregroundStyle(.secondary)
                }
                Button("Clamp All Delays") {
                    clampDelays()
                }
            }

            Section("Add Jitter") {
                Toggle("Enable Jitter", isOn: $addJitter)
                if addJitter {
                    Stepper("Jitter: \u{00B1}\(jitterPercent)%", value: $jitterPercent, in: 5...50, step: 5)
                }
                Button("Apply Jitter") {
                    applyJitter()
                }
            }
        }
        .navigationTitle("Bulk Timing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func applyTimeScale() {
        for i in 0..<flow.actions.count {
            let scaled = flow.actions[i].deltaFromPreviousMs * globalTimeScale
            flow.actions[i] = rebuildAction(flow.actions[i], delta: scaled)
        }
        flow.totalDurationMs = flow.actions.reduce(0) { $0 + $1.deltaFromPreviousMs }
    }

    private func clampDelays() {
        let minVal = Double(minDelayMs) ?? 10
        let maxVal = Double(maxDelayMs) ?? 3000
        for i in 0..<flow.actions.count {
            let clamped = max(minVal, min(maxVal, flow.actions[i].deltaFromPreviousMs))
            flow.actions[i] = rebuildAction(flow.actions[i], delta: clamped)
        }
        flow.totalDurationMs = flow.actions.reduce(0) { $0 + $1.deltaFromPreviousMs }
    }

    private func applyJitter() {
        guard addJitter else { return }
        let factor = Double(jitterPercent) / 100.0
        for i in 0..<flow.actions.count {
            let base = flow.actions[i].deltaFromPreviousMs
            let jitter = base * Double.random(in: -factor...factor)
            flow.actions[i] = rebuildAction(flow.actions[i], delta: max(1, base + jitter))
        }
        flow.totalDurationMs = flow.actions.reduce(0) { $0 + $1.deltaFromPreviousMs }
    }

    private func rebuildAction(_ a: RecordedAction, delta: Double) -> RecordedAction {
        RecordedAction(
            id: a.id, type: a.type, timestampMs: a.timestampMs, deltaFromPreviousMs: delta,
            mousePosition: a.mousePosition, scrollDeltaX: a.scrollDeltaX, scrollDeltaY: a.scrollDeltaY,
            keyCode: a.keyCode, key: a.key, code: a.code, charCode: a.charCode,
            targetSelector: a.targetSelector, targetTagName: a.targetTagName, targetType: a.targetType,
            textboxLabel: a.textboxLabel, textContent: a.textContent,
            button: a.button, buttons: a.buttons, holdDurationMs: a.holdDurationMs,
            isTrusted: a.isTrusted, shiftKey: a.shiftKey, ctrlKey: a.ctrlKey, altKey: a.altKey, metaKey: a.metaKey
        )
    }
}

// MARK: - Duplicate Flow Sheet

struct DuplicateFlowSheet: View {
    let originalName: String
    @Binding var newName: String
    let onDuplicate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Original") {
                Text(originalName)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Section("New Name") {
                TextField("e.g. \(originalName) (Fast)", text: $newName)
            }
            Section {
                Button {
                    onDuplicate()
                } label: {
                    HStack {
                        Spacer()
                        Label("Duplicate", systemImage: "doc.on.doc.fill")
                            .font(.headline)
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Duplicate Flow")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}

// MARK: - Textbox Mapping Editor

struct TextboxMappingEditorView: View {
    @Binding var mappings: [RecordedFlow.TextboxMapping]
    @Environment(\.dismiss) private var dismiss
    @State private var newLabel: String = ""
    @State private var newKey: String = ""

    var body: some View {
        Form {
            Section("Add Mapping") {
                TextField("Label (e.g. Email)", text: $newLabel)
                TextField("Placeholder Key", text: $newKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    guard !newLabel.isEmpty, !newKey.isEmpty else { return }
                    mappings.append(RecordedFlow.TextboxMapping(
                        label: newLabel,
                        selector: "",
                        originalText: "",
                        placeholderKey: newKey
                    ))
                    newLabel = ""
                    newKey = ""
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                }
                .disabled(newLabel.isEmpty || newKey.isEmpty)
            }

            Section("Mappings (\(mappings.count))") {
                if mappings.isEmpty {
                    Text("No mappings")
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    ForEach(Array(mappings.enumerated()), id: \.element.id) { index, mapping in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(mapping.label)
                                    .font(.system(.caption, design: .monospaced, weight: .bold))
                                Spacer()
                                Text("-> \(mapping.placeholderKey)")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                            if !mapping.originalText.isEmpty {
                                Text("Original: \(mapping.originalText)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                mappings.remove(at: index)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onMove { source, destination in
                        mappings.move(fromOffsets: source, toOffset: destination)
                    }
                }
            }
        }
        .navigationTitle("Textbox Mappings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
    }
}

// MARK: - Insert Action View

struct InsertActionView: View {
    let insertAt: Int
    let onInsert: (RecordedAction) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedType: RecordedActionType = .click
    @State private var posX: String = "0"
    @State private var posY: String = "0"
    @State private var deltaMs: String = "100"
    @State private var keyValue: String = ""
    @State private var textContent: String = ""
    @State private var textboxLabel: String = ""
    @State private var scrollDY: String = "0"

    var body: some View {
        Form {
            Section("Action Type") {
                Picker("Type", selection: $selectedType) {
                    ForEach(RecordedActionType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
            }

            Section("Timing") {
                HStack {
                    Text("Delay Before")
                    Spacer()
                    TextField("ms", text: $deltaMs)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                    Text("ms").foregroundStyle(.secondary)
                }
            }

            if selectedType == .click || selectedType == .mouseDown || selectedType == .mouseUp || selectedType == .mouseMove || selectedType == .touchStart || selectedType == .touchEnd {
                Section("Position") {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading) {
                            Text("X").font(.caption2).foregroundStyle(.tertiary)
                            TextField("X", text: $posX)
                                .keyboardType(.numberPad)
                                .font(.system(.body, design: .monospaced))
                        }
                        VStack(alignment: .leading) {
                            Text("Y").font(.caption2).foregroundStyle(.tertiary)
                            TextField("Y", text: $posY)
                                .keyboardType(.numberPad)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
            }

            if selectedType == .keyDown || selectedType == .keyUp || selectedType == .keyPress {
                Section("Key") {
                    TextField("Key (e.g. Enter, Tab, a)", text: $keyValue)
                        .font(.system(.body, design: .monospaced))
                }
            }

            if selectedType == .input || selectedType == .textboxEntry {
                Section("Text") {
                    TextField("Textbox Label", text: $textboxLabel)
                    TextField("Text Content", text: $textContent)
                        .font(.system(.body, design: .monospaced))
                }
            }

            if selectedType == .scroll {
                Section("Scroll") {
                    HStack {
                        Text("Delta Y")
                        Spacer()
                        TextField("DY", text: $scrollDY)
                            .keyboardType(.numbersAndPunctuation)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }

            Section {
                Button {
                    insertAction()
                } label: {
                    HStack {
                        Spacer()
                        Label("Insert at #\(insertAt)", systemImage: "plus.circle.fill")
                            .font(.headline)
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Insert Action")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func insertAction() {
        var mousePos: RecordedMousePosition?
        if let x = Double(posX), let y = Double(posY) {
            mousePos = RecordedMousePosition(x: x, y: y, viewportX: x, viewportY: y)
        }

        let action = RecordedAction(
            type: selectedType,
            timestampMs: 0,
            deltaFromPreviousMs: Double(deltaMs) ?? 100,
            mousePosition: mousePos,
            scrollDeltaY: Double(scrollDY),
            key: keyValue.isEmpty ? nil : keyValue,
            textboxLabel: textboxLabel.isEmpty ? nil : textboxLabel,
            textContent: textContent.isEmpty ? nil : textContent
        )
        onInsert(action)
    }
}

// MARK: - Flow Optimize View

struct FlowOptimizeView: View {
    @Binding var flow: RecordedFlow
    @Environment(\.dismiss) private var dismiss

    @State private var settings = FlowOptimizationSettings()
    @State private var previewActionCount: Int = 0
    @State private var previewDurationMs: Double = 0

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Current")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(flow.actions.count) actions, \(flow.formattedDuration)")
                            .font(.system(.caption, design: .monospaced))
                    }
                    if previewActionCount > 0 {
                        HStack {
                            Text("After Optimize")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                            Spacer()
                            Text("\(previewActionCount) actions, \(String(format: "%.1fs", previewDurationMs / 1000))")
                                .font(.system(.caption, design: .monospaced, weight: .bold))
                                .foregroundStyle(.green)
                        }
                    }
                }
            } header: {
                Label("Preview", systemImage: "eye")
            }

            Section("Mouse Moves") {
                Toggle("Strip Redundant Moves", isOn: $settings.stripRedundantMouseMoves)
                if settings.stripRedundantMouseMoves {
                    Stepper("Keep every \(settings.mouseMoveSampleRate)th", value: $settings.mouseMoveSampleRate, in: 1...50)
                }
            }

            Section("Timing Constraints") {
                HStack {
                    Text("Max Delay Cap")
                    Spacer()
                    TextField("ms", value: $settings.capMaxDelay, format: .number)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                    Text("ms").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Min Delay Floor")
                    Spacer()
                    TextField("ms", value: $settings.enforceMinDelay, format: .number)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                    Text("ms").foregroundStyle(.secondary)
                }
            }

            Section("Variance & Randomness") {
                Toggle("Add Timing Variance", isOn: $settings.addTimingVariance)
                if settings.addTimingVariance {
                    VStack(alignment: .leading) {
                        Text("Variance: \u{00B1}\(Int(settings.variancePercent))%")
                            .font(.system(.body, design: .monospaced, weight: .bold))
                        Slider(value: $settings.variancePercent, in: 5...50, step: 5)
                            .tint(.orange)
                    }
                }
                Toggle("Gaussian Distribution", isOn: $settings.gaussianDistribution)
            }

            Section("Speed") {
                VStack(alignment: .leading) {
                    Text("Time Scale: \(String(format: "%.1fx", settings.applyTimeScale))")
                        .font(.system(.body, design: .monospaced, weight: .bold))
                    Slider(value: $settings.applyTimeScale, in: 0.1...5.0, step: 0.1)
                        .tint(.cyan)
                    Text("< 1.0 = faster, > 1.0 = slower")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Human Pauses") {
                Toggle("Add Human Pauses", isOn: $settings.addHumanPauses)
                if settings.addHumanPauses {
                    HStack {
                        Text("Min")
                        Spacer()
                        TextField("ms", value: $settings.humanPauseMinMs, format: .number)
                            .keyboardType(.numberPad)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .monospaced))
                        Text("ms").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Max")
                        Spacer()
                        TextField("ms", value: $settings.humanPauseMaxMs, format: .number)
                            .keyboardType(.numberPad)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.body, design: .monospaced))
                        Text("ms").foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button {
                    previewOptimization()
                } label: {
                    HStack {
                        Spacer()
                        Label("Preview", systemImage: "eye")
                            .font(.headline)
                        Spacer()
                    }
                }

                Button {
                    applyOptimization()
                } label: {
                    HStack {
                        Spacer()
                        Label("Apply Optimization", systemImage: "wand.and.stars")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .background(.blue)
                    .clipShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Optimize Flow")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func previewOptimization() {
        let optimized = FlowPlaybackEngine.shared.optimizeFlow(flow, settings: settings)
        previewActionCount = optimized.actions.count
        previewDurationMs = optimized.totalDurationMs
    }

    private func applyOptimization() {
        let optimized = FlowPlaybackEngine.shared.optimizeFlow(flow, settings: settings)
        flow = optimized
        dismiss()
    }
}

// MARK: - Action Test View

struct ActionTestView: View {
    let action: RecordedAction
    @Environment(\.dismiss) private var dismiss
    @State private var results: [ActionAutomationMethod: Bool] = [:]
    @State private var isTesting: Bool = false
    @State private var currentMethod: ActionAutomationMethod?

    var body: some View {
        Form {
            Section {
                LabeledContent("Type") {
                    Text(action.type.rawValue)
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                }
                if let pos = action.mousePosition {
                    LabeledContent("Position") {
                        Text("(\(Int(pos.x)), \(Int(pos.y)))")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                if let label = action.textboxLabel {
                    LabeledContent("Label") {
                        Text(label)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.blue)
                    }
                }
            } header: {
                Label("Action Details", systemImage: "info.circle")
            }

            Section {
                ForEach(ActionAutomationMethod.allCases, id: \.self) { method in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(method.rawValue)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            Text(descriptionFor(method))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if currentMethod == method && isTesting {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else if let passed = results[method] {
                            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(passed ? .green : .red)
                        }
                    }
                }
            } header: {
                Label("Automation Methods", systemImage: "play.square.stack")
            }

            Section {
                Button {
                    isTesting = true
                } label: {
                    HStack {
                        Spacer()
                        if isTesting {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Testing...")
                        } else {
                            Label("Test All Methods", systemImage: "play.fill")
                        }
                        Spacer()
                    }
                    .font(.headline)
                }
                .disabled(isTesting)
            }
        }
        .navigationTitle("Test Action")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func descriptionFor(_ method: ActionAutomationMethod) -> String {
        switch method {
        case .humanClick: return "Full pointer+mouse event chain"
        case .jsClick: return "Direct el.click() call"
        case .pointerDispatch: return "Touch + pointer event dispatch"
        case .formSubmit: return "Find form and submit directly"
        case .enterKey: return "Dispatch Enter key to active element"
        case .ocrTextDetect: return "Screenshot OCR to find target text"
        case .coordinateClick: return "elementFromPoint + click"
        case .visionMLDetect: return "Vision ML login element detection"
        case .screenshotCropNav: return "Crop area, OCR, relocate and click"
        case .focusThenClick: return "Focus element then fire click"
        case .tabNavigation: return "Tab through focusable elements"
        case .nativeSetterFill: return "Native property descriptor value set"
        case .execCommandInsert: return "document.execCommand insertText"
        case .mouseHoverThenClick: return "Hover delay then mouse click"
        }
    }
}

// MARK: - Flow Settings View

struct FlowSettingsView: View {
    @Binding var settings: AutomationSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Page Loading") {
                Stepper("Timeout: \(Int(settings.pageLoadTimeout))s", value: $settings.pageLoadTimeout, in: 90...300, step: 15)
                Stepper("Retries: \(settings.pageLoadRetries)", value: $settings.pageLoadRetries, in: 0...10)
                Stepper("JS Render Wait: \(settings.waitForJSRenderMs)ms", value: $settings.waitForJSRenderMs, in: 500...15000, step: 500)
                Toggle("Full Reset on Final Retry", isOn: $settings.fullSessionResetOnFinalRetry)
            }

            Section("Field Detection") {
                Toggle("Field Verification", isOn: $settings.fieldVerificationEnabled)
                Toggle("Auto Calibration", isOn: $settings.autoCalibrationEnabled)
                Toggle("Vision ML Fallback", isOn: $settings.visionMLCalibrationFallback)
                VStack(alignment: .leading) {
                    Text("Confidence: \(String(format: "%.1f", settings.calibrationConfidenceThreshold))")
                        .font(.system(.caption, design: .monospaced))
                    Slider(value: $settings.calibrationConfidenceThreshold, in: 0.1...1.0, step: 0.05)
                }
            }

            Section("Credential Entry") {
                Stepper("Min Type Speed: \(settings.typingSpeedMinMs)ms", value: $settings.typingSpeedMinMs, in: 5...500, step: 5)
                Stepper("Max Type Speed: \(settings.typingSpeedMaxMs)ms", value: $settings.typingSpeedMaxMs, in: 20...1000, step: 10)
                Toggle("Typing Jitter", isOn: $settings.typingJitterEnabled)
                Toggle("Occasional Backspace", isOn: $settings.occasionalBackspaceEnabled)
                Stepper("Field Focus Delay: \(settings.fieldFocusDelayMs)ms", value: $settings.fieldFocusDelayMs, in: 0...2000, step: 50)
                Stepper("Inter-Field Delay: \(settings.interFieldDelayMs)ms", value: $settings.interFieldDelayMs, in: 0...3000, step: 50)
            }

            Section("Login Button Detection") {
                Picker("Mode", selection: $settings.loginButtonDetectionMode) {
                    ForEach(AutomationSettings.ButtonDetectionMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                Picker("Click Method", selection: $settings.loginButtonClickMethod) {
                    ForEach(AutomationSettings.ButtonClickMethod.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                Stepper("Pre-Click: \(settings.loginButtonPreClickDelayMs)ms", value: $settings.loginButtonPreClickDelayMs, in: 0...5000, step: 50)
                Stepper("Post-Click: \(settings.loginButtonPostClickDelayMs)ms", value: $settings.loginButtonPostClickDelayMs, in: 0...5000, step: 50)
                Toggle("Double Click Guard", isOn: $settings.loginButtonDoubleClickGuard)
                Toggle("Scroll Into View", isOn: $settings.loginButtonScrollIntoView)
                Toggle("Wait For Enabled", isOn: $settings.loginButtonWaitForEnabled)
                Toggle("Hover Before Click", isOn: $settings.loginButtonHoverBeforeClick)
                Toggle("Focus Before Click", isOn: $settings.loginButtonFocusBeforeClick)
                Toggle("Click Offset Jitter", isOn: $settings.loginButtonClickOffsetJitter)
                Toggle("Enter Key Fallback", isOn: $settings.loginButtonEnterKeyFallback)
                Toggle("Form Submit Fallback", isOn: $settings.loginButtonFormSubmitFallback)
                Toggle("Vision ML Fallback", isOn: $settings.loginButtonVisionMLFallback)
                Toggle("OCR Fallback", isOn: $settings.loginButtonOCRFallback)
                Toggle("Coordinate Fallback", isOn: $settings.loginButtonCoordinateFallback)
            }

            Section("Submit Behavior") {
                Stepper("Retry Count: \(settings.submitRetryCount)", value: $settings.submitRetryCount, in: 0...10)
                Stepper("Retry Delay: \(settings.submitRetryDelayMs)ms", value: $settings.submitRetryDelayMs, in: 100...10000, step: 100)
                Toggle("Rapid Poll", isOn: $settings.rapidPollEnabled)
            }

            Section("Post-Submit Evaluation") {
                Toggle("Redirect Detection", isOn: $settings.redirectDetection)
                Toggle("Error Banner Detection", isOn: $settings.errorBannerDetection)
                Toggle("Content Change Detection", isOn: $settings.contentChangeDetection)
                Picker("Strictness", selection: $settings.evaluationStrictness) {
                    ForEach(AutomationSettings.EvaluationStrictness.allCases, id: \.self) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
            }

            Section("Stealth") {
                Toggle("Stealth JS Injection", isOn: $settings.stealthJSInjection)
                Toggle("Fingerprint Spoofing", isOn: $settings.fingerprintSpoofing)
                Toggle("User Agent Rotation", isOn: $settings.userAgentRotation)
                Toggle("Viewport Randomization", isOn: $settings.viewportRandomization)
                Toggle("WebGL Noise", isOn: $settings.webGLNoise)
                Toggle("Canvas Noise", isOn: $settings.canvasNoise)
                Toggle("Audio Context Noise", isOn: $settings.audioContextNoise)
            }

            Section("Human Simulation") {
                Toggle("Human Mouse Movement", isOn: $settings.humanMouseMovement)
                Toggle("Human Scroll Jitter", isOn: $settings.humanScrollJitter)
                Toggle("Random Pre-Action Pause", isOn: $settings.randomPreActionPause)
                Stepper("Pre Pause Min: \(settings.preActionPauseMinMs)ms", value: $settings.preActionPauseMinMs, in: 0...1000, step: 10)
                Stepper("Pre Pause Max: \(settings.preActionPauseMaxMs)ms", value: $settings.preActionPauseMaxMs, in: 0...3000, step: 50)
                Toggle("Gaussian Distribution", isOn: $settings.gaussianTimingDistribution)
            }

            Section("Time Delays") {
                Stepper("Pre-Navigation: \(settings.preNavigationDelayMs)ms", value: $settings.preNavigationDelayMs, in: 0...5000, step: 50)
                Stepper("Post-Navigation: \(settings.postNavigationDelayMs)ms", value: $settings.postNavigationDelayMs, in: 0...5000, step: 50)
                Stepper("Pre-Typing: \(settings.preTypingDelayMs)ms", value: $settings.preTypingDelayMs, in: 0...5000, step: 50)
                Stepper("Post-Typing: \(settings.postTypingDelayMs)ms", value: $settings.postTypingDelayMs, in: 0...5000, step: 50)
                Stepper("Pre-Submit: \(settings.preSubmitDelayMs)ms", value: $settings.preSubmitDelayMs, in: 0...5000, step: 50)
                Stepper("Post-Submit: \(settings.postSubmitDelayMs)ms", value: $settings.postSubmitDelayMs, in: 0...5000, step: 50)
                Stepper("Page Stabilization: \(settings.pageStabilizationDelayMs)ms", value: $settings.pageStabilizationDelayMs, in: 0...10000, step: 100)
                Stepper("AJAX Settle: \(settings.ajaxSettleDelayMs)ms", value: $settings.ajaxSettleDelayMs, in: 0...10000, step: 100)
                Stepper("DOM Mutation Settle: \(settings.domMutationSettleMs)ms", value: $settings.domMutationSettleMs, in: 0...5000, step: 100)
                Toggle("Delay Randomization", isOn: $settings.delayRandomizationEnabled)
                if settings.delayRandomizationEnabled {
                    Stepper("Randomize \u{00B1}\(settings.delayRandomizationPercent)%", value: $settings.delayRandomizationPercent, in: 5...50, step: 5)
                }
            }

            Section("Form Interaction") {
                Toggle("Clear Fields Before Typing", isOn: $settings.clearFieldsBeforeTyping)
                Picker("Clear Method", selection: $settings.clearFieldMethod) {
                    ForEach(AutomationSettings.FieldClearMethod.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                Toggle("Tab Between Fields", isOn: $settings.tabBetweenFields)
                Toggle("Click Field Before Typing", isOn: $settings.clickFieldBeforeTyping)
                Toggle("Verify After Typing", isOn: $settings.verifyFieldValueAfterTyping)
                Toggle("Retype on Failure", isOn: $settings.retypeOnVerificationFailure)
                Toggle("Dismiss Autofill", isOn: $settings.dismissAutofillSuggestions)
            }

            Section("Session Management") {
                Picker("Isolation", selection: $settings.sessionIsolation) {
                    ForEach(AutomationSettings.SessionIsolationMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                Toggle("Clear Cookies", isOn: $settings.clearCookiesBetweenAttempts)
                Toggle("Clear LocalStorage", isOn: $settings.clearLocalStorageBetweenAttempts)
                Toggle("Clear SessionStorage", isOn: $settings.clearSessionStorageBetweenAttempts)
                Toggle("Fresh WebView Per Attempt", isOn: $settings.freshWebViewPerAttempt)
            }

            Section("Viewport") {
                Toggle(isOn: Binding(
                    get: { settings.smartFingerprintReuse },
                    set: { newValue in
                        settings.smartFingerprintReuse = newValue
                        if newValue { settings.randomizeViewportSize = false }
                    }
                )) {
                    Text("Smart Fingerprint Reuse")
                }
                Stepper("Width: \(settings.viewportWidth)px", value: $settings.viewportWidth, in: 320...1920, step: 10)
                Stepper("Height: \(settings.viewportHeight)px", value: $settings.viewportHeight, in: 480...1080, step: 10)
                Toggle(isOn: Binding(
                    get: { settings.randomizeViewportSize },
                    set: { newValue in
                        settings.randomizeViewportSize = newValue
                        if newValue { settings.smartFingerprintReuse = false }
                    }
                )) {
                    Text("Randomize Viewport")
                }
                Toggle("Mobile Emulation", isOn: $settings.mobileViewportEmulation)
            }
        }
        .navigationTitle("Full Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
        }
    }
}
