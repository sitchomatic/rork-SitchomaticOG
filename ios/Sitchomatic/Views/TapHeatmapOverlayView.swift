import SwiftUI
import UIKit

struct TapHeatmapOverlayView: View {
    let vm: LoginViewModel
    @State private var selectedScreenshot: PPSRDebugScreenshot?
    @State private var heatmapData: TapHeatmapData?
    @State private var isAnalyzing: Bool = false
    @State private var showOCR: Bool = true
    @State private var showFields: Bool = true
    @State private var showButtons: Bool = true
    @State private var showTaps: Bool = true
    @State private var showRects: Bool = false
    @State private var analysisScreenshot: UIImage?
    @State private var showFlipbook: Bool = false
    @State private var flipbookStartIndex: Int = 0

    var body: some View {
        Group {
            if vm.debugScreenshots.isEmpty {
                ContentUnavailableView(
                    "No Screenshots",
                    systemImage: "viewfinder.rectangular",
                    description: Text("Enable Debug Mode and run tests to capture screenshots for heatmap analysis.")
                )
            } else if let data = heatmapData, let image = analysisScreenshot {
                heatmapResultView(data: data, image: image)
            } else {
                screenshotPicker
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(heatmapData != nil ? "Heatmap Result" : "Tap Heatmap")
        .navigationBarBackButtonHidden(heatmapData != nil)
        .toolbar {
            if heatmapData != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.snappy) {
                            heatmapData = nil
                            analysisScreenshot = nil
                            selectedScreenshot = nil
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.body.weight(.semibold))
                            Text("Screenshots")
                        }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showFlipbook) {
            ScreenshotFlipbookView(screenshots: vm.debugScreenshots, startIndex: flipbookStartIndex)
        }
    }

    private var screenshotPicker: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "viewfinder.rectangular")
                            .font(.title2)
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Vision Detection Overlay")
                                .font(.headline)
                            Text("Select a screenshot to analyze where Vision detected fields, buttons, and where taps were dispatched.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 12))

                ForEach(Array(vm.debugScreenshots.enumerated()), id: \.element.id) { index, screenshot in
                    Button {
                        analyzeScreenshot(screenshot)
                    } label: {
                        HeatmapScreenshotPickerCard(screenshot: screenshot, isAnalyzing: isAnalyzing && selectedScreenshot?.id == screenshot.id)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            flipbookStartIndex = index
                            showFlipbook = true
                        } label: {
                            Label("Flipbook View", systemImage: "book.pages")
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }

    private func heatmapResultView(data: TapHeatmapData, image: UIImage) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                overlayToggles

                GeometryReader { geo in
                    let imageAspect = image.size.width / image.size.height
                    let displayWidth = geo.size.width
                    let displayHeight = displayWidth / imageAspect

                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)

                        Canvas { context, size in
                            let scaleX = size.width / data.imageSize.width
                            let scaleY = size.height / data.imageSize.height

                            if showFields {
                                for field in data.detectedFields {
                                    let rect = scaledRect(field.boundingBox, scaleX: scaleX, scaleY: scaleY)
                                    let path = RoundedRectangle(cornerRadius: 4).path(in: rect)
                                    context.stroke(path, with: .color(fieldColor(field.elementType)), lineWidth: 2.5)
                                    context.fill(Path(rect), with: .color(fieldColor(field.elementType).opacity(0.08)))

                                    let labelPoint = CGPoint(x: rect.minX + 4, y: rect.minY - 14)
                                    if labelPoint.y > 0 {
                                        context.draw(
                                            Text(field.label)
                                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                .foregroundColor(fieldColor(field.elementType)),
                                            at: labelPoint,
                                            anchor: .leading
                                        )
                                    }
                                }
                            }

                            if showButtons {
                                for button in data.detectedButtons {
                                    let rect = scaledRect(button.boundingBox, scaleX: scaleX, scaleY: scaleY)
                                    let path = RoundedRectangle(cornerRadius: 6).path(in: rect)
                                    context.stroke(path, with: .color(.red), style: StrokeStyle(lineWidth: 2.5, dash: [6, 3]))
                                    context.fill(Path(rect), with: .color(.red.opacity(0.08)))

                                    let labelPoint = CGPoint(x: rect.midX, y: rect.minY - 14)
                                    if labelPoint.y > 0 {
                                        context.draw(
                                            Text(button.label)
                                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                .foregroundColor(.red),
                                            at: labelPoint,
                                            anchor: .center
                                        )
                                    }
                                }
                            }

                            if showOCR {
                                for ocr in data.ocrElements {
                                    let rect = scaledRect(ocr.boundingBox, scaleX: scaleX, scaleY: scaleY)
                                    context.stroke(
                                        Rectangle().path(in: rect),
                                        with: .color(.yellow.opacity(0.5)),
                                        lineWidth: 1
                                    )
                                }
                            }

                            if showTaps {
                                for tap in data.tapPoints {
                                    let point = CGPoint(
                                        x: tap.coordinate.x * scaleX,
                                        y: tap.coordinate.y * scaleY
                                    )
                                    let outerRadius: CGFloat = 18
                                    let innerRadius: CGFloat = 6
                                    let color: Color = tap.wasSuccessful ? .green : .red

                                    let outerRect = CGRect(
                                        x: point.x - outerRadius,
                                        y: point.y - outerRadius,
                                        width: outerRadius * 2,
                                        height: outerRadius * 2
                                    )
                                    context.fill(Circle().path(in: outerRect), with: .color(color.opacity(0.25)))
                                    context.stroke(Circle().path(in: outerRect), with: .color(color), lineWidth: 2)

                                    let innerRect = CGRect(
                                        x: point.x - innerRadius,
                                        y: point.y - innerRadius,
                                        width: innerRadius * 2,
                                        height: innerRadius * 2
                                    )
                                    context.fill(Circle().path(in: innerRect), with: .color(color))

                                    let crossSize: CGFloat = 24
                                    var hLine = Path()
                                    hLine.move(to: CGPoint(x: point.x - crossSize / 2, y: point.y))
                                    hLine.addLine(to: CGPoint(x: point.x + crossSize / 2, y: point.y))
                                    context.stroke(hLine, with: .color(color.opacity(0.6)), lineWidth: 1)

                                    var vLine = Path()
                                    vLine.move(to: CGPoint(x: point.x, y: point.y - crossSize / 2))
                                    vLine.addLine(to: CGPoint(x: point.x, y: point.y + crossSize / 2))
                                    context.stroke(vLine, with: .color(color.opacity(0.6)), lineWidth: 1)

                                    let labelPoint = CGPoint(x: point.x + outerRadius + 4, y: point.y)
                                    context.draw(
                                        Text(tap.label)
                                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                                            .foregroundColor(color),
                                        at: labelPoint,
                                        anchor: .leading
                                    )
                                }
                            }
                        }
                    }
                    .frame(width: displayWidth, height: displayHeight)
                    .clipShape(.rect(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                }
                .aspectRatio(image.size.width / image.size.height, contentMode: .fit)

                detectionSummary(data: data)
                detectionDetailList(data: data)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }

    private var overlayToggles: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                OverlayToggleChip(label: "Fields", icon: "text.cursor", isOn: $showFields, color: .cyan)
                OverlayToggleChip(label: "Buttons", icon: "hand.tap.fill", isOn: $showButtons, color: .red)
                OverlayToggleChip(label: "OCR Text", icon: "text.viewfinder", isOn: $showOCR, color: .yellow)
                OverlayToggleChip(label: "Taps", icon: "target", isOn: $showTaps, color: .green)
            }
        }
    }

    private func detectionSummary(data: TapHeatmapData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(.cyan)
                Text("Detection Summary").font(.headline)
            }

            HStack(spacing: 16) {
                SummaryStatBadge(value: "\(data.detectedFields.count)", label: "Fields", color: .cyan)
                SummaryStatBadge(value: "\(data.detectedButtons.count)", label: "Buttons", color: .red)
                SummaryStatBadge(value: "\(data.ocrElements.count)", label: "OCR", color: .yellow)
                SummaryStatBadge(value: "\(data.tapPoints.count)", label: "Taps", color: .green)
            }

            if data.detectedFields.isEmpty && data.detectedButtons.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("No fields or buttons detected — OCR may have missed elements or page layout is non-standard.")
                        .font(.caption).foregroundStyle(.orange)
                }
                .padding(8)
                .background(Color.orange.opacity(0.08))
                .clipShape(.rect(cornerRadius: 8))
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func detectionDetailList(data: TapHeatmapData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(.purple)
                Text("Detected Elements").font(.headline)
            }

            if !data.detectedFields.isEmpty {
                Text("FIELDS").font(.system(.caption2, design: .monospaced, weight: .bold)).foregroundStyle(.cyan)
                ForEach(data.detectedFields) { field in
                    DetectionElementRow(element: field)
                }
            }

            if !data.detectedButtons.isEmpty {
                Text("BUTTONS").font(.system(.caption2, design: .monospaced, weight: .bold)).foregroundStyle(.red)
                    .padding(.top, 4)
                ForEach(data.detectedButtons) { button in
                    DetectionElementRow(element: button)
                }
            }

            if !data.tapPoints.isEmpty {
                Text("TAP POINTS").font(.system(.caption2, design: .monospaced, weight: .bold)).foregroundStyle(.green)
                    .padding(.top, 4)
                ForEach(data.tapPoints) { tap in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(tap.wasSuccessful ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(tap.label)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text("(\(Int(tap.coordinate.x)), \(Int(tap.coordinate.y)))")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func analyzeScreenshot(_ screenshot: PPSRDebugScreenshot) {
        selectedScreenshot = screenshot
        isAnalyzing = true
        analysisScreenshot = screenshot.image

        Task {
            let data = await ReplayDebuggerService.shared.buildHeatmapData(for: screenshot.image)
            withAnimation(.snappy) {
                heatmapData = data
                isAnalyzing = false
            }
        }
    }

    private func scaledRect(_ rect: CGRect, scaleX: CGFloat, scaleY: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x * scaleX,
            y: rect.origin.y * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }

    private func fieldColor(_ type: TapHeatmapData.DetectedElement.ElementType) -> Color {
        switch type {
        case .emailField: .cyan
        case .passwordField: .indigo
        case .loginButton: .red
        case .inputField: .teal
        case .button: .red
        case .label: .yellow
        case .unknown: .gray
        }
    }
}

struct OverlayToggleChip: View {
    let label: String
    let icon: String
    @Binding var isOn: Bool
    let color: Color

    var body: some View {
        Button {
            withAnimation(.snappy) { isOn.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(label)
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
            }
            .foregroundStyle(isOn ? .white : color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(isOn ? color : color.opacity(0.12))
            .clipShape(Capsule())
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isOn)
    }
}

struct SummaryStatBadge: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .monospaced, weight: .bold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.08))
        .clipShape(.rect(cornerRadius: 8))
    }
}

struct DetectionElementRow: View {
    let element: TapHeatmapData.DetectedElement

    private var typeColor: Color {
        switch element.elementType {
        case .emailField: .cyan
        case .passwordField: .indigo
        case .loginButton: .red
        case .inputField: .teal
        case .button: .red
        case .label: .yellow
        case .unknown: .gray
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(typeColor)
                .frame(width: 4, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(element.label)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(element.elementType.rawValue)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(typeColor)
                    Text("conf: \(String(format: "%.0f%%", element.confidence * 100))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text("\(Int(element.boundingBox.width))×\(Int(element.boundingBox.height))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.quaternary)
        }
        .padding(.vertical, 2)
    }
}

struct HeatmapScreenshotPickerCard: View {
    let screenshot: PPSRDebugScreenshot
    let isAnalyzing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 160)
                .overlay {
                    Image(uiImage: screenshot.displayImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .allowsHitTesting(false)
                }
                .clipShape(.rect(cornerRadii: .init(topLeading: 12, topTrailing: 12)))
                .overlay(alignment: .center) {
                    if isAnalyzing {
                        ZStack {
                            Color.black.opacity(0.5)
                            VStack(spacing: 8) {
                                ProgressView()
                                    .tint(.white)
                                Text("Analyzing...")
                                    .font(.system(.caption, design: .monospaced, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .clipShape(.rect(cornerRadii: .init(topLeading: 12, topTrailing: 12)))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "viewfinder.rectangular")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .padding(8)
                }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(screenshot.stepName.replacingOccurrences(of: "_", with: " ").uppercased())
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.cyan.opacity(0.12))
                        .clipShape(Capsule())
                    Spacer()
                    Text(screenshot.formattedTime)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 8) {
                    Label(screenshot.cardDisplayNumber, systemImage: "person.fill")
                    Spacer()
                    Label("Analyze", systemImage: "wand.and.stars")
                        .foregroundStyle(.cyan)
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }
}
