import SwiftUI

struct AutomationTemplateView: View {
    @Bindable var vm: LoginViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var templates: [AutomationTemplate] = []
    @State private var showCreateTemplate: Bool = false
    @State private var showDeleteConfirm: Bool = false
    @State private var templateToDelete: AutomationTemplate?
    @State private var appliedTemplateName: String?

    private let persistence = TemplatePersistenceService.shared

    private func templateColor(_ colorName: String) -> Color {
        switch colorName {
        case "purple": return .purple
        case "red": return .red
        case "indigo": return .indigo
        case "orange": return .orange
        case "green": return .green
        case "blue": return .blue
        case "cyan": return .cyan
        case "pink": return .pink
        case "yellow": return .yellow
        case "teal": return .teal
        default: return .blue
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(templates.filter(\.isBuiltIn)) { template in
                    templateRow(template)
                }
            } header: {
                Label("Built-In Templates", systemImage: "star.fill")
            } footer: {
                Text("Tap a template to preview. Long-press to apply. Each template optimizes settings for a specific automation strategy.")
            }

            if !templates.filter({ !$0.isBuiltIn }).isEmpty {
                Section {
                    ForEach(templates.filter { !$0.isBuiltIn }) { template in
                        templateRow(template)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    templateToDelete = template
                                    showDeleteConfirm = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Label("Custom Templates", systemImage: "person.fill")
                }
            }

            Section {
                Button {
                    showCreateTemplate = true
                } label: {
                    Label("Save Current Settings as Template", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            templates = persistence.loadTemplates()
        }
        .sheet(isPresented: $showCreateTemplate) {
            NavigationStack {
                CreateTemplateView(settings: vm.automationSettings) { newTemplate in
                    var custom = persistence.loadCustomTemplates()
                    custom.append(newTemplate)
                    persistence.saveTemplates(custom + AutomationTemplate.builtInTemplates)
                    templates = persistence.loadTemplates()
                    showCreateTemplate = false
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .alert("Delete Template?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let t = templateToDelete {
                    var custom = persistence.loadCustomTemplates()
                    custom.removeAll { $0.id == t.id }
                    persistence.saveTemplates(custom + AutomationTemplate.builtInTemplates)
                    templates = persistence.loadTemplates()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .overlay(alignment: .bottom) {
            if let name = appliedTemplateName {
                Text("Applied: \(name)")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.green.gradient)
                    .clipShape(Capsule())
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation { appliedTemplateName = nil }
                        }
                    }
            }
        }
        .animation(.spring(duration: 0.3), value: appliedTemplateName)
    }

    private func templateRow(_ template: AutomationTemplate) -> some View {
        HStack(spacing: 14) {
            Image(systemName: template.icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(templateColor(template.color))
                .frame(width: 40, height: 40)
                .background(templateColor(template.color).opacity(0.12))
                .clipShape(.rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(template.name)
                        .font(.system(.subheadline, weight: .bold))
                    if template.isBuiltIn {
                        Text("BUILT-IN")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(templateColor(template.color))
                            .clipShape(Capsule())
                    }
                }
                Text(template.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                applyTemplate(template)
            } label: {
                Label("Apply Template", systemImage: "checkmark.circle.fill")
            }
            if !template.isBuiltIn {
                Button(role: .destructive) {
                    templateToDelete = template
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                applyTemplate(template)
            } label: {
                Label("Apply", systemImage: "checkmark")
            }
            .tint(templateColor(template.color))
        }
    }

    private func applyTemplate(_ template: AutomationTemplate) {
        vm.automationSettings = template.settings.normalizedTimeouts()
        vm.persistAutomationSettings()
        withAnimation {
            appliedTemplateName = template.name
        }
    }
}

struct CreateTemplateView: View {
    let settings: AutomationSettings
    let onCreate: (AutomationTemplate) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var selectedIcon: String = "gearshape.fill"
    @State private var selectedColor: String = "blue"

    private let iconOptions = [
        "gearshape.fill", "bolt.fill", "eye.slash.fill", "scope",
        "eye.trianglebadge.exclamationmark", "shield.checkered",
        "tornado", "flame.fill", "wand.and.stars",
        "cpu.fill", "antenna.radiowaves.left.and.right", "lock.shield.fill",
    ]

    private let colorOptions: [(String, Color)] = [
        ("blue", .blue), ("purple", .purple), ("red", .red),
        ("orange", .orange), ("green", .green), ("indigo", .indigo),
        ("cyan", .cyan), ("pink", .pink), ("teal", .teal),
    ]

    var body: some View {
        Form {
            Section("Template Info") {
                TextField("Template Name", text: $name)
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section("Icon") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                    ForEach(iconOptions, id: \.self) { icon in
                        Button {
                            selectedIcon = icon
                        } label: {
                            Image(systemName: icon)
                                .font(.system(size: 20))
                                .frame(width: 36, height: 36)
                                .background(selectedIcon == icon ? Color.blue.opacity(0.2) : Color.clear)
                                .clipShape(.rect(cornerRadius: 8))
                                .foregroundStyle(selectedIcon == icon ? .blue : .secondary)
                        }
                    }
                }
            }

            Section("Color") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                    ForEach(colorOptions, id: \.0) { name, color in
                        Button {
                            selectedColor = name
                        } label: {
                            Circle()
                                .fill(color)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    if selectedColor == name {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                    }
                }
            }

            Section {
                Button {
                    let template = AutomationTemplate(
                        name: name.isEmpty ? "Custom Template" : name,
                        description: description.isEmpty ? "Custom automation template" : description,
                        icon: selectedIcon,
                        color: selectedColor,
                        settings: settings.normalizedTimeouts()
                    )
                    onCreate(template)
                } label: {
                    HStack {
                        Spacer()
                        Label("Create Template", systemImage: "plus.circle.fill")
                            .font(.headline)
                        Spacer()
                    }
                }
                .disabled(name.isEmpty)
            }
        }
        .navigationTitle("Create Template")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}
