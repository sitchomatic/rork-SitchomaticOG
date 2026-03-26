import SwiftUI

struct MainMenuView: View {
    @Binding var activeMode: ActiveAppMode?
    let requiresProfileSelection: Bool
    @State private var animateIn: Bool = false
    @State private var nordService = NordVPNService.shared
    private let proxyService = ProxyRotationService.shared

    init(activeMode: Binding<ActiveAppMode?>, requiresProfileSelection: Bool = false) {
        _activeMode = activeMode
        self.requiresProfileSelection = requiresProfileSelection
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image("MainMenuBG")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                Color.black.opacity(0.3)

                VStack(spacing: 0) {
                    Spacer().frame(height: geo.safeAreaInsets.top + 8)

                    profileSwitcher
                        .padding(.horizontal, dynamicIslandHPadding(geo: geo))
                        .padding(.bottom, 12)
                        .zIndex(10)

                    if profileSelectionNeeded {
                        profileSelectionBanner
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }

                    unifiedSessionZone(geo: geo)
                        .frame(height: (geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom) * 0.28)

                    HStack(spacing: 0) {
                        dualFindZone(geo: geo)
                        testDebugZone(geo: geo)
                    }
                    .frame(height: (geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom) * 0.14)

                    ppsrZone(geo: geo)
                        .frame(height: (geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom) * 0.15)

                    HStack(spacing: 0) {
                        settingsAndTestingZone(geo: geo)
                        connectionModeZone(geo: geo)
                    }
                    .frame(maxHeight: .infinity)

                    Spacer().frame(height: geo.safeAreaInsets.bottom + 4)
                }

                VStack {
                    Spacer()

                    HStack {
                        Spacer()
                        Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.15))
                            .padding(.trailing, 16)
                    }
                    .padding(.bottom, geo.safeAreaInsets.bottom + 6)
                }
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.spring(duration: 0.7, bounce: 0.12)) {
                animateIn = true
            }
        }
        .onDisappear {
            animateIn = false
        }
    }

    private func unifiedSessionZone(geo: GeometryProxy) -> some View {
        Button {
            guard canEnterModes else { return }
            withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
                activeMode = .unifiedSession
            }
        } label: {
            ZStack {
                LinearGradient(
                    colors: [.green.opacity(0.12), .orange.opacity(0.12)],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "suit.spade.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.green)
                                .symbolEffect(.pulse, options: .repeating.speed(0.4))
                                .shadow(color: .green.opacity(0.6), radius: 10)
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .heavy))
                                .foregroundStyle(.white.opacity(0.4))
                            Image(systemName: "flame.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.orange)
                                .symbolEffect(.pulse, options: .repeating.speed(0.4))
                                .shadow(color: .orange.opacity(0.6), radius: 10)
                        }

                        Text("UNIFIED\nSESSIONS")
                            .font(.system(size: 18, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .lineSpacing(2)
                            .shadow(color: .black.opacity(0.8), radius: 4)

                        Text("Joe + Ignition · Paired Testing")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))

                        Text("V4.1 · 4 Workers · Early-Stop Sync")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .padding(.leading, 20)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 8) {
                        Image(systemName: "rectangle.split.2x1.fill")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(colors: [.green, .orange], startPoint: .leading, endPoint: .trailing)
                            )
                            .shadow(color: .green.opacity(0.3), radius: 8)

                        HStack(spacing: 3) {
                            Text("LAUNCH")
                                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .padding(.trailing, 20)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(animateIn ? (canEnterModes ? 1 : 0.35) : 0)
        .offset(y: animateIn ? 0 : -20)
        .allowsHitTesting(canEnterModes)
        .sensoryFeedback(.impact(weight: .heavy), trigger: activeMode == .unifiedSession)
    }

    private func dualFindZone(geo: GeometryProxy) -> some View {
        Button {
            guard canEnterModes else { return }
            withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
                activeMode = .dualFind
            }
        } label: {
            ZStack {
                LinearGradient(
                    colors: [.purple.opacity(0.15), .indigo.opacity(0.2)],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.purple)
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.indigo)
                        }
                        .shadow(color: .purple.opacity(0.5), radius: 8)

                        Text("DUAL FIND")
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 4)

                        Text("Email × 3 Passwords")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.purple.opacity(0.7))

                        HStack(spacing: 3) {
                            Text("FIND")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.purple.opacity(0.6))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .heavy))
                                .foregroundStyle(.purple.opacity(0.4))
                        }
                    }
                    .padding(.leading, 20)

                    Spacer()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(animateIn ? (canEnterModes ? 1 : 0.35) : 0)
        .offset(x: animateIn ? 0 : -30)
        .allowsHitTesting(canEnterModes)
        .sensoryFeedback(.impact(weight: .medium), trigger: activeMode == .dualFind)
    }

    private func testDebugZone(geo: GeometryProxy) -> some View {
        Button {
            guard canEnterModes else { return }
            withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
                activeMode = .testDebug
            }
        } label: {
            ZStack {
                LinearGradient(
                    colors: [Color.purple.opacity(0.15), Color.pink.opacity(0.2)],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                HStack(spacing: 0) {
                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "flask.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(
                                    LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.pink.opacity(0.7))
                        }
                        .shadow(color: .purple.opacity(0.5), radius: 8)

                        Text("TEST & DEBUG")
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 4)

                        Text("Known Account Optimizer")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.purple.opacity(0.7))

                        HStack(spacing: 3) {
                            Text("LAUNCH")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.purple.opacity(0.6))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .heavy))
                                .foregroundStyle(.purple.opacity(0.4))
                        }
                    }
                    .padding(.trailing, 20)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(animateIn ? (canEnterModes ? 1 : 0.35) : 0)
        .offset(x: animateIn ? 0 : 30)
        .allowsHitTesting(canEnterModes)
        .sensoryFeedback(.impact(weight: .heavy), trigger: activeMode == .testDebug)
    }

    private func ppsrZone(geo: GeometryProxy) -> some View {
        Button {
            guard canEnterModes else { return }
            withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
                activeMode = .ppsr
            }
        } label: {
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: [.cyan.opacity(0.2), .blue.opacity(0.05)],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                HStack(spacing: 14) {
                    Image(systemName: "car.side.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.cyan)
                        .shadow(color: .cyan.opacity(0.5), radius: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("PPSR")
                            .font(.system(size: 20, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 4)

                        Text("CHECK")
                            .font(.system(size: 20, weight: .black, design: .monospaced))
                            .foregroundStyle(.cyan)
                            .shadow(color: .cyan.opacity(0.4), radius: 4)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("VIN & Card Testing")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.cyan.opacity(0.7))

                        HStack(spacing: 3) {
                            Text("ENTER")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.cyan.opacity(0.6))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .heavy))
                                .foregroundStyle(.cyan.opacity(0.4))
                        }
                    }
                }
                .padding(.leading, 20)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(animateIn ? (canEnterModes ? 1 : 0.35) : 0)
        .offset(y: animateIn ? 0 : 30)
        .allowsHitTesting(canEnterModes)
        .sensoryFeedback(.impact(weight: .medium), trigger: activeMode == .ppsr)
    }

    private func settingsAndTestingZone(geo: GeometryProxy) -> some View {
        Button {
            guard canEnterModes else { return }
            withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
                activeMode = .settingsAndTesting
            }
        } label: {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.1, green: 0.1, blue: 0.15).opacity(0.4), Color(red: 0.2, green: 0.3, blue: 0.5).opacity(0.3)],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: "gearshape.2.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(
                                    LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                            Image(systemName: "bolt.horizontal.circle.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.purple.opacity(0.7))
                        }
                        .shadow(color: .blue.opacity(0.4), radius: 8)

                        Text("SETTINGS & TESTING")
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 4)

                        Text("Super Test · IP Score · Nord Config · Debug")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.leading, 20)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "network")
                            Image(systemName: "shield.lefthalf.filled")
                            Image(systemName: "externaldrive.fill")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))

                        HStack(spacing: 3) {
                            Text("OPEN")
                                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .heavy))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                    .padding(.trailing, 20)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(animateIn ? (canEnterModes ? 1 : 0.35) : 0)
        .offset(y: animateIn ? 0 : 30)
        .allowsHitTesting(canEnterModes)
        .sensoryFeedback(.impact(weight: .medium), trigger: activeMode == .settingsAndTesting)
    }

    private func connectionModeZone(geo: GeometryProxy) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.0, green: 0.2, blue: 0.25).opacity(0.5), connectionModeColor.opacity(0.25)],
                startPoint: .leading,
                endPoint: .trailing
            )

            VStack(alignment: .trailing, spacing: 6) {
                Image(systemName: proxyService.unifiedConnectionMode.icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(connectionModeColor)
                    .shadow(color: connectionModeColor.opacity(0.6), radius: 8)

                Text("CONNECTION\nMODE")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
                    .lineSpacing(2)
                    .shadow(color: .black.opacity(0.6), radius: 4)

                Menu {
                    ForEach(ConnectionMode.allCases, id: \.self) { mode in
                        Button {
                            proxyService.setUnifiedConnectionMode(mode)
                        } label: {
                            Label(mode.label, systemImage: mode.icon)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(proxyService.unifiedConnectionMode.label.uppercased())
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .heavy))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(connectionModeColor.opacity(0.5))
                    .clipShape(Capsule())
                }
            }
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .opacity(animateIn ? 1 : 0)
        .offset(x: animateIn ? 0 : 30)
        .sensoryFeedback(.impact(weight: .medium), trigger: proxyService.unifiedConnectionMode)
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

    private func dynamicIslandHPadding(geo: GeometryProxy) -> CGFloat {
        let hasDynamicIsland = geo.safeAreaInsets.top > 51
        return hasDynamicIsland ? 56 : 20
    }

    private var profileSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(NordKeyProfile.allCases, id: \.self) { profile in
                Button {
                    guard !isProfileActive(profile) else { return }
                    withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                        nordService.switchProfile(profile)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(profile.rawValue.uppercased())
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                    }
                    .foregroundStyle(isProfileActive(profile) ? .white : .white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(
                        Group {
                            if isProfileActive(profile) {
                                Capsule()
                                    .fill(
                                        profile == .nick
                                            ? LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
                                            : LinearGradient(colors: [.purple, .pink], startPoint: .leading, endPoint: .trailing)
                                    )
                            }
                        }
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.12))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .contentShape(Capsule())
        .sensoryFeedback(.impact(weight: .heavy), trigger: nordService.activeKeyProfile)
        .opacity(animateIn ? 1 : 0)
        .offset(y: animateIn ? 0 : -20)
    }

    private var canEnterModes: Bool {
        !requiresProfileSelection || nordService.hasSelectedProfile
    }

    private var profileSelectionNeeded: Bool {
        requiresProfileSelection && !nordService.hasSelectedProfile
    }

    private func isProfileActive(_ profile: NordKeyProfile) -> Bool {
        nordService.hasSelectedProfile && nordService.activeKeyProfile == profile
    }

    private var profileSelectionBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.title3)
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 4) {
                Text("Choose Nick or Poli to continue")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("No profile is selected automatically on first launch.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.white.opacity(0.10))
        .clipShape(.rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }
}

nonisolated enum ActiveAppMode: String, Sendable {
    case unifiedSession
    case ppsr
    case superTest
    case debugLog
    case flowRecorder
    case nordConfig
    case vault
    case ipScoreTest
    case dualFind
    case settingsAndTesting
    case proxyManager
    case testDebug
}
