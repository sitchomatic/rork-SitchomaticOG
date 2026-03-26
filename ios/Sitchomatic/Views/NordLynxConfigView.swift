import SwiftUI

struct NordLynxConfigView: View {
    @State private var viewModel = NordLynxConfigViewModel()
    @State private var successBounce: Int = 0
    @State private var selectedConfig: NordLynxGeneratedConfig?
    @State private var listItemsVisible: Bool = false
    @State private var showSettings: Bool = false
    @State private var importResult: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    headerSection
                    inputSection
                    resultSection
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(
                MeshGradient(
                    width: 3, height: 3,
                    points: [
                        [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                        [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                        [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                    ],
                    colors: [
                        .black, Color(red: 0.03, green: 0.05, blue: 0.15), .black,
                        Color(red: 0.0, green: 0.08, blue: 0.12), Color(red: 0.02, green: 0.06, blue: 0.18), Color(red: 0.0, green: 0.04, blue: 0.1),
                        .black, Color(red: 0.0, green: 0.06, blue: 0.1), .black
                    ]
                )
                .ignoresSafeArea()
            )
            .preferredColorScheme(.dark)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedConfig) { config in
                NordLynxConfigDetailView(config: config)
            }
            .sheet(isPresented: $showSettings) {
                NordLynxAccessKeySettingsView()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .withMainMenuButton()
            .animation(.smooth(duration: 0.4), value: viewModel.state)
        }
    }

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(
                    .linearGradient(
                        colors: [Color(red: 0.0, green: 0.78, blue: 1.0), Color(red: 0.0, green: 0.55, blue: 0.9)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .symbolEffect(.pulse, isActive: isLoading)
                .symbolEffect(.bounce, value: successBounce)

            Text("NordLynx")
                .font(.system(.largeTitle, design: .default, weight: .bold))
                .foregroundStyle(.white)
            + Text(" Generator")
                .font(.system(.largeTitle, design: .default, weight: .light))
                .foregroundStyle(.white.opacity(0.7))

            Text("WireGuard & OpenVPN configs from NordVPN")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            activeKeyBadge
        }
        .padding(.top, 20)
    }

    private var activeKeyBadge: some View {
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "key.horizontal.fill")
                    .font(.caption2)
                Text(viewModel.activeKeyName)
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(accentColor.opacity(0.12), in: .capsule)
        }
    }

    private var inputSection: some View {
        VStack(spacing: 20) {
            protocolPicker
            filterSection

            VStack(alignment: .leading, spacing: 10) {
                Label("Server Count", systemImage: "server.rack")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    Button {
                        if viewModel.serverLimit > 1 {
                            viewModel.serverLimit -= 1
                        }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(viewModel.serverLimit > 1 ? accentColor : Color.gray.opacity(0.3))
                    }
                    .disabled(viewModel.serverLimit <= 1)

                    Text("\(viewModel.serverLimit)")
                        .font(.system(.title, design: .monospaced, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 48)
                        .contentTransition(.numericText(value: Double(viewModel.serverLimit)))
                        .animation(.snappy, value: viewModel.serverLimit)

                    Button {
                        if viewModel.serverLimit < 50 {
                            viewModel.serverLimit += 1
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(viewModel.serverLimit < 50 ? accentColor : Color.gray.opacity(0.3))
                    }
                    .disabled(viewModel.serverLimit >= 50)

                    Spacer()

                    limitPresetButtons
                }
            }

            Button {
                listItemsVisible = false
                Task {
                    await viewModel.generateConfigs()
                    if case .success = viewModel.state {
                        successBounce += 1
                        withAnimation(.spring(response: 0.5)) {
                            listItemsVisible = true
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    if isLoading {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Image(systemName: viewModel.selectedProtocol.icon)
                    }
                    Text(isLoading ? generatingLabel : "Generate Configs")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(accentColor)
            .disabled(!viewModel.canGenerate)
            .sensoryFeedback(.impact(weight: .medium), trigger: successBounce)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
    }

    private var protocolPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Protocol", systemImage: "network.badge.shield.half.filled")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                ForEach(NordLynxVPNProtocol.allCases) { proto in
                    Button {
                        withAnimation(.snappy(duration: 0.25)) {
                            viewModel.selectedProtocol = proto
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: proto.icon)
                                .font(.caption)
                            Text(proto.shortName)
                                .font(.system(.caption2, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            viewModel.selectedProtocol == proto
                                ? protocolAccent(for: proto).opacity(0.2)
                                : Color.white.opacity(0.04),
                            in: .rect(cornerRadius: 8)
                        )
                        .foregroundStyle(
                            viewModel.selectedProtocol == proto
                                ? protocolAccent(for: proto)
                                : .secondary
                        )
                    }
                }
            }
            .padding(4)
            .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 12))
        }
    }

    private func protocolAccent(for proto: NordLynxVPNProtocol) -> Color {
        switch proto {
        case .wireguardUDP: .cyan
        case .openvpnUDP: .orange
        case .openvpnTCP: Color(red: 1.0, green: 0.6, blue: 0.2)
        }
    }

    private var accentColor: Color {
        protocolAccent(for: viewModel.selectedProtocol)
    }

    private var generatingLabel: String {
        viewModel.selectedProtocol.isOpenVPN ? "Downloading configs…" : "Generating…"
    }

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Location Filter", systemImage: "globe")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Menu {
                    Button {
                        withAnimation(.snappy) {
                            viewModel.selectCountry(nil)
                        }
                    } label: {
                        Label("All Countries", systemImage: viewModel.selectedCountry == nil ? "checkmark" : "")
                    }

                    Divider()

                    ForEach(viewModel.countries) { country in
                        Button {
                            withAnimation(.snappy) {
                                viewModel.selectCountry(country)
                            }
                        } label: {
                            Label {
                                Text("\(flagEmoji(for: country.code)) \(country.name)")
                            } icon: {
                                if viewModel.selectedCountry?.id == country.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.isLoadingCountries {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.secondary)
                        } else {
                            Image(systemName: "map")
                                .font(.subheadline)
                                .foregroundStyle(accentColor)
                        }

                        if let country = viewModel.selectedCountry {
                            Text("\(flagEmoji(for: country.code)) \(country.name)")
                                .font(.subheadline)
                                .foregroundStyle(.white)
                        } else {
                            Text("All Countries")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.6))
                        }

                        Spacer()

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 10))
                }
                .frame(maxWidth: .infinity)

                if viewModel.selectedCountry != nil {
                    Button {
                        withAnimation(.snappy) {
                            viewModel.selectCountry(nil)
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !viewModel.availableCities.isEmpty {
                Menu {
                    Button {
                        withAnimation(.snappy) {
                            viewModel.selectedCity = nil
                        }
                    } label: {
                        Label("All Cities", systemImage: viewModel.selectedCity == nil ? "checkmark" : "")
                    }

                    Divider()

                    ForEach(viewModel.availableCities) { city in
                        Button {
                            withAnimation(.snappy) {
                                viewModel.selectedCity = city
                            }
                        } label: {
                            Label {
                                Text(city.name)
                            } icon: {
                                if viewModel.selectedCity?.id == city.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "building.2")
                            .font(.subheadline)
                            .foregroundStyle(accentColor)

                        if let city = viewModel.selectedCity {
                            Text(city.name)
                                .font(.subheadline)
                                .foregroundStyle(.white)
                        } else {
                            Text("All Cities")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.6))
                        }

                        Spacer()

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 10))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if viewModel.selectedCountry != nil || viewModel.selectedCity != nil {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .font(.caption)
                        .foregroundStyle(accentColor.opacity(0.7))

                    Text(filterSummary)
                        .font(.caption)
                        .foregroundStyle(accentColor.opacity(0.7))
                }
                .transition(.opacity)
            }
        }
        .task {
            await viewModel.loadCountries()
        }
    }

    private var filterSummary: String {
        var parts: [String] = []
        if let country = viewModel.selectedCountry {
            parts.append(country.name)
        }
        if let city = viewModel.selectedCity {
            parts.append(city.name)
        }
        return "Filtering: " + parts.joined(separator: " → ")
    }

    private func flagEmoji(for code: String) -> String {
        guard code.count == 2 else { return "🌐" }
        let base: UInt32 = 127397
        return code.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(base + $0.value)
        }.map { String($0) }.joined()
    }

    private var limitPresetButtons: some View {
        HStack(spacing: 8) {
            ForEach([5, 10, 25], id: \.self) { preset in
                Button {
                    withAnimation(.snappy) {
                        viewModel.serverLimit = preset
                    }
                } label: {
                    Text("\(preset)")
                        .font(.system(.caption, design: .monospaced, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            viewModel.serverLimit == preset
                                ? accentColor.opacity(0.25)
                                : Color.white.opacity(0.06),
                            in: .capsule
                        )
                        .foregroundStyle(viewModel.serverLimit == preset ? accentColor : .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        switch viewModel.state {
        case .idle:
            idleView

        case .loading:
            loadingView

        case .success(let count):
            successView(count: count)

        case .error(let message):
            errorView(message: message)
        }
    }

    private var idleView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Select a protocol, configure filters, and tap Generate")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(accentColor)

            Text(viewModel.selectedProtocol.isOpenVPN ? "Downloading OpenVPN configs…" : "Fetching optimal servers…")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Retry on failure is automatic")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private func successView(count: Int) -> some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("\(count) Configs Generated")
                            .font(.headline)
                            .foregroundStyle(.white)

                        Text(viewModel.selectedProtocol.shortName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(accentColor.opacity(0.2), in: .capsule)
                            .foregroundStyle(accentColor)
                    }

                    Text("Tap a config to preview • Export to share")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    viewModel.reset()
                    listItemsVisible = false
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.subheadline.weight(.medium))
                        .padding(8)
                        .background(.white.opacity(0.08), in: .circle)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)

            if count > 3 {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)

                    TextField("Search servers…", text: $viewModel.searchText)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 10))
            }

            importToAppButton

            if !viewModel.filteredExportURLs.isEmpty {
                exportFormatSection
            }

            LazyVStack(spacing: 10) {
                ForEach(Array(viewModel.filteredConfigs.enumerated()), id: \.element.id) { index, config in
                    Button {
                        selectedConfig = config
                    } label: {
                        NordLynxConfigRow(config: config, accentColor: accentColor)
                    }
                    .opacity(listItemsVisible ? 1 : 0)
                    .offset(y: listItemsVisible ? 0 : 12)
                    .animation(.spring(response: 0.4).delay(Double(index) * 0.03), value: listItemsVisible)
                }
            }

            if viewModel.filteredConfigs.isEmpty && !viewModel.searchText.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No matching servers")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .sensoryFeedback(.success, trigger: successBounce)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var importToAppButton: some View {
        VStack(spacing: 6) {
            Button {
                let result = viewModel.importGeneratedToApp()
                importResult = "Imported \(result.wg) WG + \(result.ovpn) OVPN to network settings"
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    importResult = nil
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.app.fill")
                    Text("Import to App Network Settings")
                        .fontWeight(.medium)
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.teal.opacity(0.12), in: .rect(cornerRadius: 10))
                .foregroundStyle(.teal)
            }
            .sensoryFeedback(.success, trigger: importResult)

            if let importResult {
                Text(importResult)
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.3), value: importResult)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, value: message)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Try Again") {
                    listItemsVisible = false
                    Task {
                        await viewModel.generateConfigs()
                        if case .success = viewModel.state {
                            successBounce += 1
                            withAnimation(.spring(response: 0.5)) {
                                listItemsVisible = true
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)

                Button("Reset") {
                    viewModel.reset()
                    listItemsVisible = false
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var exportFormatSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.caption)
                    .foregroundStyle(accentColor)
                Text("Export Format")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(NordLynxExportFormat.allCases) { format in
                        Button {
                            withAnimation(.snappy(duration: 0.25)) {
                                viewModel.selectedExportFormat = format
                                viewModel.exportedURL = nil
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: format.icon)
                                    .font(.caption2)
                                Text(format.displayName)
                                    .font(.caption.weight(.medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                viewModel.selectedExportFormat == format
                                    ? accentColor.opacity(0.2)
                                    : Color.white.opacity(0.05),
                                in: .capsule
                            )
                            .foregroundStyle(
                                viewModel.selectedExportFormat == format
                                    ? accentColor
                                    : .secondary
                            )
                        }
                    }
                }
            }
            .contentMargins(.horizontal, 0)

            Text(viewModel.selectedExportFormat.subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            exportActionButton
        }
    }

    @ViewBuilder
    private var exportActionButton: some View {
        let format = viewModel.selectedExportFormat
        let configCount = viewModel.filteredConfigs.count
        let label = viewModel.searchText.isEmpty ? "Export All (\(configCount))" : "Export Filtered (\(configCount))"

        switch format {
        case .individualFiles:
            ShareLink(items: viewModel.filteredExportURLs) {
                Label(label, systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(accentColor.opacity(0.12), in: .rect(cornerRadius: 10))
                    .foregroundStyle(accentColor)
            }

        default:
            if let url = viewModel.exportedURL, viewModel.selectedExportFormat == format {
                ShareLink(item: url) {
                    Label("Share \(format.displayName)", systemImage: "arrow.up.doc.fill")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.green.opacity(0.12), in: .rect(cornerRadius: 10))
                        .foregroundStyle(.green)
                }
            } else {
                Button {
                    Task {
                        await viewModel.exportConfigs(format: format)
                    }
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.isExporting {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.white.opacity(0.6))
                        } else {
                            Image(systemName: format.icon)
                        }
                        Text(viewModel.isExporting ? "Preparing…" : "Prepare \(format.displayName)")
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(accentColor.opacity(0.08), in: .rect(cornerRadius: 10))
                    .foregroundStyle(accentColor.opacity(0.8))
                }
                .disabled(viewModel.isExporting)
            }
        }
    }

    private var isLoading: Bool {
        if case .loading = viewModel.state { return true }
        return false
    }
}

struct NordLynxConfigRow: View {
    let config: NordLynxGeneratedConfig
    let accentColor: Color

    private var loadColor: Color {
        switch config.serverLoad {
        case 0..<30: .green
        case 30..<60: .yellow
        case 60..<80: .orange
        default: .red
        }
    }

    private var flagEmoji: String {
        guard config.countryCode.count == 2 else { return "🌐" }
        let base: UInt32 = 127397
        return config.countryCode.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(base + $0.value)
        }.map { String($0) }.joined()
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(flagEmoji)
                .font(.title2)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(config.hostname)
                    .font(.system(.subheadline, design: .monospaced, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(config.stationIP)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if !config.cityName.isEmpty {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        Text(config.cityName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(config.vpnProtocol.shortName)
                    .font(.system(.caption2, design: .default, weight: .semibold))
                    .foregroundStyle(accentColor.opacity(0.8))

                HStack(spacing: 4) {
                    Circle()
                        .fill(loadColor)
                        .frame(width: 6, height: 6)
                    Text("\(config.serverLoad)%")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 10))
    }
}
