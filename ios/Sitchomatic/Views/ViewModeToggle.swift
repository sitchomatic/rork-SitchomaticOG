import SwiftUI
import UIKit

nonisolated enum ViewMode: String, CaseIterable, Sendable {
    case list = "List"
    case tile = "Tile"

    var icon: String {
        switch self {
        case .list: "list.bullet"
        case .tile: "square.grid.2x2"
        }
    }
}

struct ViewModeToggle: View {
    @Binding var mode: ViewMode
    var accentColor: Color = .teal

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ViewMode.allCases, id: \.self) { option in
                Button {
                    withAnimation(.spring(duration: 0.25, bounce: 0.1)) {
                        mode = option
                    }
                } label: {
                    Image(systemName: option.icon)
                        .font(.caption.bold())
                        .frame(width: 32, height: 28)
                        .background(mode == option ? accentColor : Color.clear)
                        .foregroundStyle(mode == option ? .white : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(.tertiarySystemFill))
        .clipShape(.rect(cornerRadius: 7))
        .sensoryFeedback(.selection, trigger: mode)
    }
}

struct ScreenshotTileView: View {
    let screenshot: UIImage?
    let title: String
    let subtitle: String
    let statusColor: Color
    let statusText: String
    var badge: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            if let screenshot {
                Color(.secondarySystemGroupedBackground)
                    .frame(height: 100)
                    .overlay {
                        Image(uiImage: screenshot)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .allowsHitTesting(false)
                    }
                    .clipShape(.rect(cornerRadii: .init(topLeading: 10, topTrailing: 10)))
            } else {
                Color(.tertiarySystemFill)
                    .frame(height: 100)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(.quaternary)
                    }
                    .clipShape(.rect(cornerRadii: .init(topLeading: 10, topTrailing: 10)))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Circle().fill(statusColor).frame(width: 5, height: 5)
                    Text(statusText)
                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                        .foregroundStyle(statusColor)

                    if let badge {
                        Spacer()
                        Text(badge)
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadii: .init(bottomLeading: 10, bottomTrailing: 10)))
        }
    }
}
