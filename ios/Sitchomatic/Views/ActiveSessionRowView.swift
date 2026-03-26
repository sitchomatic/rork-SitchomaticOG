import SwiftUI

struct ActiveSessionRowView: View {
    let item: ActiveSessionItem

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 2)
                    .frame(width: 28, height: 28)
                Circle()
                    .trim(from: 0, to: item.progress)
                    .stroke(progressColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 28, height: 28)
                    .rotationEffect(.degrees(-90))
                Image(systemName: item.statusIcon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(progressColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(item.statusText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            Text(item.elapsed)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
        .clipShape(.rect(cornerRadius: 8))
    }

    private var progressColor: Color {
        if item.progress >= 0.8 { return .green }
        if item.progress >= 0.4 { return .cyan }
        return .blue
    }
}
