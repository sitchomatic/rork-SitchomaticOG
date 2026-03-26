import SwiftUI

struct CredentialGroupsView: View {
    let vm: LoginViewModel
    @State private var groupService = CredentialGroupService.shared
    @State private var showCreateSheet: Bool = false
    @State private var selectedSize: GroupSize = .fifty
    @State private var showRenameAlert: Bool = false
    @State private var renameGroupId: String = ""
    @State private var renameText: String = ""
    @State private var showColorPicker: Bool = false
    @State private var colorPickerGroupId: String = ""
    @State private var showMergeSheet: Bool = false
    @State private var mergeSelection: Set<String> = []
    @State private var mergeName: String = ""
    @State private var mergeColor: GroupColor = .blue

    private var totalCredentials: Int { vm.credentials.count }

    var body: some View {
        List {
            activeGroupBanner
            if groupService.groups.isEmpty {
                emptyState
            } else {
                groupsList
            }
            createSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Credential Groups")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !groupService.groups.isEmpty {
                    Button {
                        showMergeSheet = true
                        mergeSelection.removeAll()
                    } label: {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.subheadline)
                    }
                }
            }
        }
        .alert("Rename Group", isPresented: $showRenameAlert) {
            TextField("Group name", text: $renameText)
            Button("Save") {
                groupService.renameGroup(id: renameGroupId, name: renameText)
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showColorPicker) {
            colorPickerSheet
        }
        .sheet(isPresented: $showMergeSheet) {
            mergeSheet
        }
        .sheet(isPresented: $showCreateSheet) {
            createGroupSheet
        }
    }

    private var activeGroupBanner: some View {
        Section {
            if let activeId = groupService.activeGroupId,
               let group = groupService.groups.first(where: { $0.id == activeId }) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(group.color.color)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Active Group")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(group.name)
                            .font(.subheadline.bold())
                    }
                    Spacer()
                    Text("\(group.count) creds")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(group.color.color)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(group.color.color.opacity(0.12))
                        .clipShape(Capsule())
                    Button {
                        groupService.selectGroup(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Text("Tests will run against this group only.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No Active Group")
                            .font(.subheadline.bold())
                        Text("Tests run against all \(totalCredentials) credentials")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            HStack {
                Image(systemName: "target")
                Text("Active Filter")
            }
        }
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("No Groups Yet")
                    .font(.headline)
                Text("Split your \(totalCredentials) credentials into groups for organized batch testing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    private var groupsList: some View {
        Section {
            ForEach(groupService.groups) { group in
                groupRow(group)
            }
            .onDelete { indexSet in
                for idx in indexSet {
                    groupService.deleteGroup(id: groupService.groups[idx].id)
                }
            }
        } header: {
            HStack {
                Image(systemName: "folder.fill")
                Text("Groups (\(groupService.groups.count))")
                Spacer()
                Text("\(groupService.groups.reduce(0) { $0 + $1.count }) creds")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func groupRow(_ group: CredentialGroup) -> some View {
        Button {
            withAnimation(.spring(duration: 0.3)) {
                if groupService.activeGroupId == group.id {
                    groupService.selectGroup(nil)
                } else {
                    groupService.selectGroup(group.id)
                }
            }
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(group.color.color)
                    .frame(width: 6, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.name)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        if groupService.activeGroupId == group.id {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    HStack(spacing: 8) {
                        Text("\(group.count) credentials")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        let stats = groupStats(group)
                        if stats.untested > 0 {
                            Text("\(stats.untested) untested")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                        if stats.working > 0 {
                            Text("\(stats.working) working")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                    }
                }

                Spacer()

                Text(group.color.label)
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(group.color.color)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(group.color.color.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameGroupId = group.id
                renameText = group.name
                showRenameAlert = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                colorPickerGroupId = group.id
                showColorPicker = true
            } label: {
                Label("Change Color", systemImage: "paintpalette")
            }

            Button {
                groupService.selectGroup(group.id)
            } label: {
                Label("Set as Active", systemImage: "target")
            }

            Divider()

            Button(role: .destructive) {
                groupService.deleteGroup(id: group.id)
            } label: {
                Label("Delete Group", systemImage: "trash")
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: groupService.activeGroupId)
    }

    private func groupStats(_ group: CredentialGroup) -> (untested: Int, working: Int) {
        let ids = Set(group.credentialIds)
        let matched = vm.credentials.filter { ids.contains($0.id) }
        return (
            untested: matched.filter { $0.status == .untested }.count,
            working: matched.filter { $0.status == .working }.count
        )
    }

    private var createSection: some View {
        Section {
            Button {
                showCreateSheet = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.rectangle.on.folder.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-Split Credentials")
                            .font(.subheadline.bold())
                        Text("Break \(totalCredentials) creds into groups")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if !groupService.groups.isEmpty {
                Button(role: .destructive) {
                    groupService.deleteAllGroups()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.red)
                        Text("Delete All Groups")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
            }
        } header: {
            HStack {
                Image(systemName: "wand.and.stars")
                Text("Actions")
            }
        }
    }

    private var createGroupSheet: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Split \(totalCredentials) credentials into groups of:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        ForEach(GroupSize.allCases, id: \.rawValue) { size in
                            let groupCount = max(1, (totalCredentials + size.rawValue - 1) / size.rawValue)
                            Button {
                                selectedSize = size
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedSize == size ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedSize == size ? .blue : .secondary)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(size.rawValue) per group")
                                            .font(.subheadline.bold())
                                            .foregroundStyle(.primary)
                                        Text("\(groupCount) group\(groupCount == 1 ? "" : "s")")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    HStack(spacing: 3) {
                                        ForEach(0..<min(groupCount, 6), id: \.self) { i in
                                            Circle()
                                                .fill(GroupColor.allCases[i % GroupColor.allCases.count].color)
                                                .frame(width: 8, height: 8)
                                        }
                                        if groupCount > 6 {
                                            Text("+\(groupCount - 6)")
                                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Group Size")
                } footer: {
                    Text("Each group gets a unique color. You can rename and recolor groups after creation.")
                }

                Section {
                    Button {
                        let allIds = vm.credentials.map(\.id)
                        groupService.createGroups(from: allIds, size: selectedSize)
                        showCreateSheet = false
                    } label: {
                        HStack {
                            Spacer()
                            Label("Create Groups", systemImage: "plus.rectangle.on.folder.fill")
                                .font(.headline)
                            Spacer()
                        }
                    }
                    .tint(.blue)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Auto-Split")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCreateSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var colorPickerSheet: some View {
        NavigationStack {
            List {
                ForEach(GroupColor.allCases, id: \.rawValue) { gc in
                    Button {
                        groupService.recolorGroup(id: colorPickerGroupId, color: gc)
                        showColorPicker = false
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(gc.color)
                                .frame(width: 24, height: 24)
                            Text(gc.label)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer()
                            if groupService.groups.first(where: { $0.id == colorPickerGroupId })?.color == gc {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Pick Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showColorPicker = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var mergeSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(groupService.groups) { group in
                        Button {
                            if mergeSelection.contains(group.id) {
                                mergeSelection.remove(group.id)
                            } else {
                                mergeSelection.insert(group.id)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: mergeSelection.contains(group.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(mergeSelection.contains(group.id) ? group.color.color : .secondary)
                                Circle()
                                    .fill(group.color.color)
                                    .frame(width: 10, height: 10)
                                Text(group.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(group.count)")
                                    .font(.system(.caption, design: .monospaced, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Select groups to merge")
                }

                if mergeSelection.count >= 2 {
                    Section {
                        TextField("Merged group name", text: $mergeName)
                        Picker("Color", selection: $mergeColor) {
                            ForEach(GroupColor.allCases, id: \.rawValue) { gc in
                                HStack {
                                    Circle().fill(gc.color).frame(width: 12, height: 12)
                                    Text(gc.label)
                                }.tag(gc)
                            }
                        }

                        let totalMerged = mergeSelection.compactMap { id in groupService.groups.first(where: { $0.id == id })?.count }.reduce(0, +)
                        Button {
                            let name = mergeName.isEmpty ? "Merged Group" : mergeName
                            groupService.mergeGroups(ids: mergeSelection, intoName: name, color: mergeColor)
                            showMergeSheet = false
                        } label: {
                            HStack {
                                Spacer()
                                Label("Merge \(mergeSelection.count) Groups (\(totalMerged) creds)", systemImage: "arrow.triangle.merge")
                                    .font(.subheadline.bold())
                                Spacer()
                            }
                        }
                        .tint(.blue)
                    } header: {
                        Text("Merge Settings")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Merge Groups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showMergeSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
