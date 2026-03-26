import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var accentColor: Color = .secondary
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var tips: [EmptyStateTip] = []

    @State private var animateIcon: Bool = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.08))
                    .frame(width: 100, height: 100)

                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundStyle(accentColor.opacity(0.6))
                    .symbolEffect(.pulse.byLayer, options: .repeating, isActive: animateIcon)
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(.title3.bold())

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(accentColor)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }

            if !tips.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tips) { tip in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: tip.icon)
                                .font(.caption)
                                .foregroundStyle(accentColor)
                                .frame(width: 20)
                            Text(tip.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: 300, alignment: .leading)
                .background(accentColor.opacity(0.05))
                .clipShape(.rect(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 48)
        .onAppear { animateIcon = true }
    }
}

struct EmptyStateTip: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
}
