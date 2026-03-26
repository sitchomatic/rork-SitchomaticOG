import SwiftUI
import UniformTypeIdentifiers

struct SavedFlowsView: View {
    @Bindable var vm: FlowRecorderViewModel
    @State private var expandedFlowId: String?
    @State private var exportData: Data?
    @State private var showExportShare: Bool = false
    @State private var editingFlow: RecordedFlow?
    @State private var showEditingStudio: Bool = false

    var body: some View {
        Group {
            if vm.savedFlows.isEmpty {
                emptyState
            } else {
                flowList
            }
        }
        .navigationTitle("Saved Flows")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "record.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Recorded Flows")
                .font(.title3.weight(.semibold))
            Text("Record an automation flow from the recorder to see it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var flowList: some View {
        List {
            ForEach(vm.savedFlows) { flow in
                flowCard(flow)
            }
            .onDelete { indexSet in
                for index in indexSet {
                    vm.deleteFlow(vm.savedFlows[index])
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func flowCard(_ flow: RecordedFlow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(flow.name)
                        .font(.system(size: 15, weight: .semibold))

                    Text(flow.url)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(flow.formattedDuration)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)

                    Text("\(flow.actionCount) actions")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                flowStat(icon: "cursorarrow.motionlines", value: "\(flow.actions.filter { $0.type == .mouseMove }.count)", label: "Moves")
                flowStat(icon: "hand.tap.fill", value: "\(flow.actions.filter { $0.type == .click }.count)", label: "Clicks")
                flowStat(icon: "keyboard.fill", value: "\(flow.actions.filter { $0.type == .keyDown }.count)", label: "Keys")
                flowStat(icon: "scroll.fill", value: "\(flow.actions.filter { $0.type == .scroll }.count)", label: "Scrolls")

                Spacer()

                Text(flow.createdAt, style: .relative)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            if !flow.textboxMappings.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "textformat.abc")
                        .font(.system(size: 9))
                        .foregroundStyle(.blue)
                    Text(flow.textboxMappings.map(\.label).joined(separator: ", "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.blue.opacity(0.8))
                        .lineLimit(1)
                }
            }

            if expandedFlowId == flow.id {
                actionBreakdown(flow)
            }

            HStack(spacing: 8) {
                Button {
                    vm.selectFlowForPlayback(flow)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                        Text("Play")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.green)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    if let data = vm.exportFlow(flow) {
                        exportData = data
                        showExportShare = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 10))
                        Text("Export")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.blue)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    editingFlow = flow
                    showEditingStudio = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                        Text("Edit")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.purple)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        expandedFlowId = expandedFlowId == flow.id ? nil : flow.id
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expandedFlowId == flow.id ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                        Text("Detail")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                Button(role: .destructive) {
                    vm.deleteFlow(flow)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showExportShare) {
            if let data = exportData {
                ShareSheet(activityItems: [data])
            }
        }
        .sheet(isPresented: $showEditingStudio) {
            if let flow = editingFlow {
                NavigationStack {
                    FlowEditingStudioView(
                        flow: flow,
                        onSave: { updated in
                            if let idx = vm.savedFlows.firstIndex(where: { $0.id == updated.id }) {
                                vm.savedFlows[idx] = updated
                                FlowPersistenceService.shared.saveFlows(vm.savedFlows)
                            }
                            showEditingStudio = false
                        },
                        onDuplicate: { copy in
                            vm.savedFlows.insert(copy, at: 0)
                            FlowPersistenceService.shared.saveFlows(vm.savedFlows)
                            showEditingStudio = false
                        }
                    )
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
            }
        }
    }

    private func flowStat(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                Text(value)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 7))
                .foregroundStyle(.tertiary)
        }
    }

    private func actionBreakdown(_ flow: RecordedFlow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("ACTION TIMELINE")
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(.secondary)

            let grouped = groupActions(flow.actions)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(grouped.prefix(50).enumerated()), id: \.offset) { _, group in
                        HStack(spacing: 6) {
                            Text(String(format: "%.0fms", group.timestampMs))
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 55, alignment: .trailing)

                            Image(systemName: iconForActionType(group.type))
                                .font(.system(size: 8))
                                .foregroundStyle(colorForActionType(group.type))
                                .frame(width: 12)

                            Text(group.description)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .padding(.top, 4)
    }

    private struct ActionGroup {
        let type: RecordedActionType
        let timestampMs: Double
        let description: String
    }

    private func groupActions(_ actions: [RecordedAction]) -> [ActionGroup] {
        var result: [ActionGroup] = []
        var mouseMoveCount = 0
        var lastMouseMoveTs: Double = 0

        for action in actions {
            if action.type == .mouseMove {
                mouseMoveCount += 1
                lastMouseMoveTs = action.timestampMs
                if mouseMoveCount % 20 == 0 {
                    let pos = action.mousePosition.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? ""
                    result.append(ActionGroup(type: .mouseMove, timestampMs: lastMouseMoveTs, description: "mousemove x\(mouseMoveCount) \(pos)"))
                }
                continue
            }

            if mouseMoveCount > 0 {
                let pos = action.mousePosition.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? ""
                result.append(ActionGroup(type: .mouseMove, timestampMs: lastMouseMoveTs, description: "mousemove x\(mouseMoveCount) \(pos)"))
                mouseMoveCount = 0
            }

            let desc: String
            switch action.type {
            case .click:
                let pos = action.mousePosition.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? ""
                desc = "click \(pos) on \(action.targetTagName ?? "?")"
            case .mouseDown:
                desc = "mousedown btn:\(action.button ?? 0)"
            case .mouseUp:
                let hold = action.holdDurationMs.map { String(format: "hold:%.0fms", $0) } ?? ""
                desc = "mouseup \(hold)"
            case .keyDown:
                desc = "keydown '\(action.key ?? "?")' \(action.textboxLabel ?? "")"
            case .keyUp:
                desc = "keyup '\(action.key ?? "?")'"
            case .input:
                let label = action.textboxLabel ?? "field"
                desc = "input → \(label)"
            case .focus:
                desc = "focus \(action.targetTagName ?? "")[\(action.targetType ?? "")]"
            case .blur:
                desc = "blur \(action.targetTagName ?? "")"
            case .scroll:
                desc = "scroll dy:\(Int(action.scrollDeltaY ?? 0))"
            default:
                desc = action.type.rawValue
            }

            result.append(ActionGroup(type: action.type, timestampMs: action.timestampMs, description: desc))
        }

        return result
    }

    private func iconForActionType(_ type: RecordedActionType) -> String {
        switch type {
        case .mouseMove: "cursorarrow.motionlines"
        case .mouseDown, .mouseUp, .click: "hand.tap.fill"
        case .doubleClick: "hand.tap.fill"
        case .scroll: "scroll.fill"
        case .keyDown, .keyUp, .keyPress: "keyboard.fill"
        case .touchStart, .touchEnd, .touchMove: "hand.point.up.left.fill"
        case .focus: "scope"
        case .blur: "circle.dashed"
        case .input, .textboxEntry: "textformat.abc"
        case .pageLoad, .navigationStart: "globe"
        case .pause: "pause.fill"
        }
    }

    private func colorForActionType(_ type: RecordedActionType) -> Color {
        switch type {
        case .mouseMove: .gray
        case .mouseDown, .mouseUp, .click, .doubleClick: .orange
        case .scroll: .purple
        case .keyDown, .keyUp, .keyPress: .blue
        case .touchStart, .touchEnd, .touchMove: .green
        case .focus: .cyan
        case .blur: .secondary
        case .input, .textboxEntry: .indigo
        case .pageLoad, .navigationStart: .teal
        case .pause: .yellow
        }
    }
}

