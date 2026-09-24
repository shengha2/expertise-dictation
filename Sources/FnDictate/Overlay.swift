import AppKit
import SwiftUI
import Combine

/// What the floating bar shows. At rest it is a small dark handle at the bottom of the screen
/// (click it to start hands-free); while working it grows into a 34 pt black bar like Typeless's.
enum OverlayState: Equatable {
    case idle
    case listening
    case transcribing
    case cleaning
    case success
    case error(title: String, message: String)
    /// Transcript that had nowhere to go: shown with a Copy button, like Typeless's bubble.
    case result(text: String)

    var isCard: Bool {
        switch self {
        case .error, .result: return true
        default: return false
        }
    }

    var isBar: Bool {
        switch self {
        case .listening, .transcribing, .cleaning, .success: return true
        default: return false
        }
    }
}

final class OverlayModel: ObservableObject {
    static let barCount = 27            // 27 × 2 pt bars with 2 pt gaps = 106 pt, inside a 110 pt window
    static let barWidth: CGFloat = 236  // the bar keeps this width in every state, so nothing is ever clipped
    @Published var state: OverlayState = .idle
    @Published var levels: [CGFloat] = Array(repeating: 0, count: OverlayModel.barCount)
    @Published var micLive = false      // first real audio level received → bars go from 50 % to 100 %
    @Published var text = ""
    @Published var handsFree = false
    @Published var showPreview = false
    @Published var modeLabel = ""
    @Published var accent: Color = OverlayModel.blue
    @Published var showHandle = true
    @Published var hotkeyActive = false
    @Published var elapsedSeconds: Double = 0
    @Published var statusDetail = ""
    /// A genuine capture/provider limitation shown alongside a completed text preview.
    @Published var resultWarning = ""
    @Published var canRetry = false
    /// The panel updates this before measuring a result card, so its contents fit the display.
    @Published var availableScreenSize = CGSize(width: 800, height: 600)
    /// Natural SwiftUI content size, used to fit the actual window to its visible controls.
    var onContentSizeChanged: ((CGSize) -> Void)?

    static let blue = Color(red: 0, green: 0xD0 / 255, blue: 0xAF / 255)      // Expertise mint, used for Clean mode
    static let teal = Color(red: 0x05 / 255, green: 0x5D / 255, blue: 0x4F / 255) // Expertise green, Light / Verbatim
    static let card = Color(red: 29 / 255, green: 26 / 255, blue: 26 / 255)

    @Published var copied = false
    @Published var translating = false
    @Published var targetLanguage = "English"
    var onPickLanguage: (() -> Void)?
    var onTap: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onPrimaryAction: (() -> Void)?
    var onCopy: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?

    private var latest: CGFloat = 0
    private var smoothed: CGFloat = 0
    private var history: [CGFloat] = Array(repeating: 0, count: OverlayModel.barCount / 2 + 1)
    private var timer: Timer?

    func pushLevel(_ v: Float) {
        latest = CGFloat(v)
        if !micLive && v > 0.02 {
            DispatchQueue.main.async { self.micLive = true }
        }
    }

    func startAnimating() {
        stopAnimating()
        micLive = false
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
        latest = 0
        smoothed = 0
        history = Array(repeating: 0, count: history.count)
        levels = Array(repeating: 0, count: Self.barCount)
    }

    private func tick() {
        // Fast attack, slower release; the value then travels outwards from the centre (Typeless's
        // "diffusion" look) with a mild random variation per bar.
        let target = latest
        smoothed += (target - smoothed) * (target > smoothed ? 0.7 : 0.3)
        history.removeLast()
        history.insert(smoothed, at: 0)
        let c = Self.barCount / 2
        var l = [CGFloat](repeating: 0, count: Self.barCount)
        for d in 0...c {
            let falloff = 1 - CGFloat(d) / CGFloat(c + 1) * 0.6
            let variation = CGFloat.random(in: 0.9...1.05)
            l[c + d] = min(1, history[min(d, history.count - 1)] * falloff * variation)
            l[c - d] = min(1, history[min(d, history.count - 1)] * falloff * CGFloat.random(in: 0.9...1.05))
        }
        levels = l
    }
}

private struct OverlaySizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        content
            .padding(4)
            .fixedSize(horizontal: true, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: OverlaySizeKey.self, value: geometry.size)
            })
            .onPreferenceChange(OverlaySizeKey.self) { model.onContentSizeChanged?($0) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            if model.showHandle { handle }
        case .error(let title, let message):
            ErrorCard(title: title, message: message, model: model)
        case .result(let text):
            ResultCard(text: text, model: model)
        default:
            bar
        }
    }

    // A 40 × 6 pt dark dash, as Typeless leaves at the bottom of the screen at rest.
    private var handle: some View {
        Capsule()
            .fill(Color.black.opacity(model.hotkeyActive ? 0.85 : 0.35))
            .frame(width: 40, height: 6)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5).allowsHitTesting(false))
            .padding(6)
            .contentShape(Rectangle())
            .onTapGesture { model.onTap?() }
            .help("Click to start hands-free dictation")
    }

    private var bar: some View {
        HStack(spacing: 8) {
            leadingIcon
                .frame(width: 18, height: 18)
            ZStack {
                switch model.state {
                case .listening:
                    WaveformView(levels: model.levels, live: model.micLive)
                        .frame(width: 110, height: 24)
                case .transcribing:
                    Text("Finishing…").font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.85))
                case .cleaning:
                    Text(model.translating ? "Translating…" : "Finishing…").font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.85))
                case .success:
                    Text("Inserted")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(red: 0.4, green: 0.9, blue: 0.6))
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            if model.state == .listening {
                Text(elapsedLabel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .accessibilityLabel("Recorded \(elapsedLabel)")
            }
            if !model.statusDetail.isEmpty && model.state != .success {
                Text(model.statusDetail)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                    .frame(maxWidth: 220)
                    .help(model.statusDetail)
            }
            if model.translating && model.state != .success {
                // Target-language dropdown, remembered for next time.
                Button { model.onPickLanguage?() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                        Text(model.targetLanguage).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Choose the language to translate into")
            }
            if model.showPreview && model.state != .success {
                // Fixed slot so the bar never changes width while text streams in.
                Text(model.text)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(width: 300, alignment: .leading)
            }
            if model.state == .listening {
                barButton("Stop recording", symbol: "stop.fill") { model.onStop?() }
            }
            if model.state == .listening || model.state == .transcribing || model.state == .cleaning {
                barButton("Cancel (Esc)", symbol: "xmark") { model.onCancel?() }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(minWidth: OverlayModel.barWidth)
        .frame(height: 40)
        .background(
            ZStack {
                Color.black
                if model.state == .listening {
                    Ellipse()
                        .fill(RadialGradient(colors: [model.accent.opacity(0.95), model.accent.opacity(0)],
                                             center: .center, startRadius: 0, endRadius: 58))
                        .frame(width: 150, height: 32)
                        .blur(radius: 7)
                        .offset(y: -22)
                        .transition(.opacity)
                }
            }
        )
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.32), lineWidth: 1).allowsHitTesting(false))
        .contentShape(Capsule())
    }

    private var elapsedLabel: String {
        let seconds = max(0, Int(model.elapsedSeconds))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func barButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch model.state {
        case .listening:
            // A small red light marks hands-free listening (tap the key or click the bar to stop).
            Image(systemName: model.translating ? "globe" : "mic.fill").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                .overlay(alignment: .topTrailing) {
                    if model.handsFree {
                        Circle().fill(Color(red: 1, green: 0.3, blue: 0.3)).frame(width: 6, height: 6).offset(x: 3, y: -3)
                    }
                }
        case .transcribing:
            Image(systemName: "waveform").font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.8))
        case .cleaning:
            Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.8))
        case .success:
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(Color(red: 0.4, green: 0.9, blue: 0.6))
        default:
            EmptyView()
        }
    }
}

struct WaveformView: View {
    let levels: [CGFloat]
    let live: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(live ? 1 : 0.5))
                    .frame(width: 2, height: 2 + 16 * levels[i])
            }
        }
        .animation(.linear(duration: 0.05), value: levels)
        .animation(.easeOut(duration: 0.2), value: live)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                     .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
    }
}

/// Dim text with a light sweep running across it, like Typeless's processing label.
struct ShimmerText: View {
    let text: String
    @State private var phase: CGFloat = -1.2
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Color(red: 242 / 255, green: 241 / 255, blue: 240 / 255).opacity(0.6))
            .overlay(
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6)
                        .offset(x: phase * g.size.width)
                }
                .mask(Text(text).font(.system(size: 12, weight: .medium)))
            )
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
    }
}

struct ErrorCard: View {
    let title: String
    let message: String
    @ObservedObject var model: OverlayModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Color(red: 1, green: 0.62, blue: 0.42))
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
            }
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(8)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .help(message)
            HStack(spacing: 8) {
                if model.canRetry {
                    Button("Retry") { model.onRetry?() }
                        .buttonStyle(PillButtonStyle(primary: true))
                }
                if let url = firstURL(in: message) {
                    Button("Open link") { NSWorkspace.shared.open(url); model.onDismiss?() }
                        .buttonStyle(PillButtonStyle(primary: true))
                }
                Button("Settings") { model.onPrimaryAction?() }
                    .buttonStyle(PillButtonStyle(primary: !model.canRetry && firstURL(in: message) == nil))
                Button("Dismiss") { model.onDismiss?() }
                    .buttonStyle(PillButtonStyle(primary: false))
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(OverlayModel.card))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(red: 119 / 255, green: 119 / 255, blue: 119 / 255).opacity(0.3), lineWidth: 1).allowsHitTesting(false))
    }
}

/// Size the contents before sizing the panel. Clamping only the window would crop its controls.
struct ResultCardLayout {
    let contentWidth: CGFloat
    let previewHeight: CGFloat
    let showsScrollHint: Bool
    let detailLineLimit: Int
    let warningLineLimit: Int
    let detailHeight: CGFloat
    let warningHeight: CGFloat
    let panelSize: CGSize

    init(text: String, statusDetail: String, warning: String, canRetry: Bool, availableSize: CGSize) {
        // 24 screen-edge points, 8 outer overlay points, and 32 card-padding points.
        contentWidth = max(1, min(text.count > 800 ? 560 : 420, availableSize.width - 64))
        let width = contentWidth
        func measuredHeight(_ value: String, fontSize: CGFloat, lines: Int? = nil) -> CGFloat {
            guard !value.isEmpty else { return 0 }
            let font = NSFont.systemFont(ofSize: fontSize)
            let bounds = (value as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            return ceil(min(bounds.height, lines.map { CGFloat($0) * lineHeight } ?? bounds.height)) + 2
        }
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let textBounds = (text as NSString).boundingRect(
            with: CGSize(width: max(1, width - scrollerWidth - 20), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let textHeight = max(52, ceil(textBounds.height) + 24)
        let sectionCount = 2 + (statusDetail.isEmpty ? 0 : 1) + (warning.isEmpty ? 0 : 1)
        let fixedChrome: CGFloat = 40 + 32 + CGFloat(sectionCount - 1) * 12 +
            (!warning.isEmpty && canRetry ? 40 : 0)
        let heightBudget = max(1, availableSize.height - 24)
        var detailLines = 4
        var warningLines = 4
        func chromeHeight() -> CGFloat {
            fixedChrome + measuredHeight(statusDetail, fontSize: 12, lines: detailLines) +
                measuredHeight(warning, fontSize: 11, lines: warningLines)
        }
        // Explanatory messages can be shortened (their full text remains in Help), but the
        // transcript, Copy, Dismiss and recovery action must remain reachable on small screens.
        while heightBudget - chromeHeight() < 100 && (detailLines > 1 || warningLines > 1) {
            if detailLines > 1 { detailLines -= 1 }
            if warningLines > 1 { warningLines -= 1 }
        }
        let withoutHint = max(1, min(360, textHeight, heightBudget - chromeHeight()))
        showsScrollHint = textHeight > withoutHint + 1
        previewHeight = max(1, min(360, textHeight, heightBudget - chromeHeight() - (showsScrollHint ? 20 : 0)))
        detailLineLimit = detailLines
        warningLineLimit = warningLines
        detailHeight = measuredHeight(statusDetail, fontSize: 12, lines: detailLines)
        warningHeight = measuredHeight(warning, fontSize: 11, lines: warningLines)
        panelSize = CGSize(width: width + 40,
                           height: chromeHeight() + previewHeight + (showsScrollHint ? 20 : 0))
    }
}

/// Native text layout keeps every character selectable and makes the end of long transcripts
/// reachable without relying on SwiftUI Text's ideal height inside a fixed-size hosting view.
final class ResultTranscriptScrollView: NSScrollView {
    let transcriptView = NSTextView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        borderType = .noBorder
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = false
        scrollerStyle = .legacy
        scrollerKnobStyle = .light
        appearance = NSAppearance(named: .darkAqua)
        horizontalScrollElasticity = .none
        setAccessibilityIdentifier("result-preview-text")
        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.isRichText = false
        transcriptView.drawsBackground = false
        transcriptView.font = .systemFont(ofSize: 13)
        transcriptView.textColor = .white.withAlphaComponent(0.92)
        transcriptView.textContainerInset = NSSize(width: 10, height: 10)
        transcriptView.isHorizontallyResizable = false
        transcriptView.isVerticallyResizable = true
        transcriptView.minSize = .zero
        transcriptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcriptView.autoresizingMask = [.width]
        transcriptView.textContainer?.lineFragmentPadding = 0
        transcriptView.textContainer?.widthTracksTextView = true
        transcriptView.textContainer?.heightTracksTextView = false
        transcriptView.setAccessibilityIdentifier("result-preview-document")
        documentView = transcriptView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTranscript(_ text: String) {
        guard transcriptView.string != text else { return }
        transcriptView.string = text
        transcriptView.scroll(NSPoint.zero)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard contentSize.width > 0, contentSize.height > 0,
              let container = transcriptView.textContainer, let manager = transcriptView.layoutManager else { return }
        let width = max(1, contentSize.width)
        let containerWidth = max(1, width - transcriptView.textContainerInset.width * 2)
        if container.containerSize.width != containerWidth {
            container.containerSize = NSSize(width: containerWidth, height: .greatestFiniteMagnitude)
        }
        manager.ensureLayout(for: container)
        let height = max(contentSize.height, ceil(manager.usedRect(for: container).height) + transcriptView.textContainerInset.height * 2)
        let size = NSSize(width: width, height: height)
        if transcriptView.frame.size != size { transcriptView.setFrameSize(size) }
    }
}

private struct ResultTranscriptView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> ResultTranscriptScrollView {
        let view = ResultTranscriptScrollView(frame: .zero)
        view.setTranscript(text)
        return view
    }
    func updateNSView(_ view: ResultTranscriptScrollView, context: Context) {
        view.setTranscript(text)
    }
}

/// Full text is scrollable; Copy and Dismiss remain outside the scrolling area.
struct ResultCard: View {
    let text: String
    @ObservedObject var model: OverlayModel
    var body: some View {
        let layout = ResultCardLayout(text: text, statusDetail: model.statusDetail,
                                      warning: model.resultWarning, canRetry: model.canRetry,
                                      availableSize: model.availableScreenSize)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "doc.text").foregroundColor(OverlayModel.blue)
                Text("Your text is ready").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 12)
                Button(model.copied ? "Copied ✓" : "Copy") { model.onCopy?() }
                    .buttonStyle(PillButtonStyle(primary: true))
                    .accessibilityIdentifier("result-preview-copy")
                Button { model.onDismiss?() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss preview")
                .help("Dismiss (Esc)")
            }
            if !model.statusDetail.isEmpty {
                Text(model.statusDetail)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(layout.detailLineLimit)
                    .frame(height: layout.detailHeight, alignment: .topLeading)
                    .help(model.statusDetail)
            }
            VStack(alignment: .leading, spacing: 6) {
                if layout.showsScrollHint {
                    Text("Scroll to read all your text. Copy includes everything.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(1)
                        .frame(height: 14)
                }
                ResultTranscriptView(text: text)
                    .frame(width: layout.contentWidth, height: layout.previewHeight)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.18)))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if !model.resultWarning.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.resultWarning)
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 1, green: 0.75, blue: 0.48))
                        .lineLimit(layout.warningLineLimit)
                        .frame(height: layout.warningHeight, alignment: .topLeading)
                        .help(model.resultWarning)
                    if model.canRetry {
                        HStack {
                            Text("Audio saved for retry").font(.system(size: 11)).foregroundColor(.white.opacity(0.65))
                            Spacer()
                            Button("Retry recording") { model.onRetry?() }
                                .buttonStyle(PillButtonStyle(primary: false))
                        }
                    }
                }
            }
        }
        .frame(width: layout.contentWidth, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(OverlayModel.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.2), lineWidth: 1).allowsHitTesting(false))
    }

}

private func firstURL(in text: String) -> URL? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    return detector.firstMatch(in: text, range: range)?.url
}

struct PillButtonStyle: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(primary ? Color(red: 242 / 255, green: 241 / 255, blue: 240 / 255) : .white.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(primary
                ? (configuration.isPressed ? Color(red: 0x04 / 255, green: 0x41 / 255, blue: 0x37 / 255) : Color(red: 0x05 / 255, green: 0x5D / 255, blue: 0x4F / 255))
                : Color.white.opacity(configuration.isPressed ? 0.2 : 0.12)))
            .contentShape(Rectangle())
    }
}

/// Non-activating controls must still accept the first click from another application.
/// Native view hit testing handles buttons; there is no pointer-position gate.
/// Whenever SwiftUI changes the content's ideal size, the window is told to follow it.
final class OverlayHostingView: NSHostingView<OverlayView> {
    var onFittingSizeChange: ((CGSize) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onFittingSizeChange?(fittingSize)
    }
    override func layout() {
        super.layout()
        onFittingSizeChange?(fittingSize)
    }
}

/// The window fits its content, so no invisible 640-point-wide surface covers other apps.
/// Keeping mouse events enabled also makes a quick first click reliable, without waiting
/// for a global hover callback to catch up with the physical mouse button.
final class OverlayPanel: NSPanel {
    private let model: OverlayModel
    private var anchorScreen: NSScreen?
    private var pendingContentSize: CGSize?
    private var resizeScheduled = false
    // WindowServer visibility can change during a Space transition. Keep the
    // controller's intent separate so recovery never revives a dismissed card.
    private var presentationRequested = false
    private var workspaceRefreshGeneration = 0
    private var workspaceRefreshes: [DispatchWorkItem] = []
    private var nextVisibilityRecovery: TimeInterval = 0
    private var visibilityRecoveryAttempts = 0

    init(model: OverlayModel) {
        self.model = model
        super.init(contentRect: NSRect(x: 0, y: 0, width: 52, height: 18),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                              .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        // Hiding the settings app must not hide an in-progress dictation or its result.
        canHide = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        anchorScreen = screenUnderMouse()
        if let size = anchorScreen?.visibleFrame.size { model.availableScreenSize = size }
        let host = OverlayHostingView(rootView: OverlayView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        contentView = host
        model.onContentSizeChanged = { [weak self] size in self?.scheduleResize(to: size) }
        host.onFittingSizeChange = { [weak self] size in self?.scheduleResize(to: size) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceDidChange),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceDidChange),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceDidChange),
            name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(workspaceDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionDidChange),
            name: NSWindow.didChangeOcclusionStateNotification, object: self)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        workspaceRefreshes.forEach { $0.cancel() }
        fitWatchdog?.invalidate()
    }

    @objc private func workspaceDidChange(_ notification: Notification) {
        visibilityRecoveryAttempts = 0
        scheduleWorkspaceRefreshes()
    }

    @objc private func occlusionDidChange(_ notification: Notification) {
        recoverVisibilityIfNeeded()
    }

    private func scheduleWorkspaceRefreshes() {
        cancelWorkspaceRefreshes()
        guard presentationRequested else { return }
        nextVisibilityRecovery = ProcessInfo.processInfo.systemUptime + 1
        let generation = workspaceRefreshGeneration
        // App/Space notifications can arrive before the transition animation
        // finishes. Refresh now and after it settles, coalescing rapid switches.
        // Ordering this nonactivating panel never activates the app or takes focus.
        for delay in [0.0, 0.25, 0.75] {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.presentationRequested,
                      self.workspaceRefreshGeneration == generation else { return }
                self.reposition()
                self.orderFrontRegardless()
            }
            workspaceRefreshes.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func cancelWorkspaceRefreshes() {
        workspaceRefreshGeneration &+= 1
        workspaceRefreshes.forEach { $0.cancel() }
        workspaceRefreshes.removeAll()
    }

    private var fitWatchdog: Timer?

    /// Measured, never assumed: while the bar is on screen, compare the content's ideal size
    /// with the window a few times a second and correct any mismatch.
    private func startWatchdog() {
        fitWatchdog?.invalidate()
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.fitIfNeeded() }
        RunLoop.main.add(t, forMode: .common)
        fitWatchdog = t
    }

    private func stopWatchdog() {
        fitWatchdog?.invalidate()
        fitWatchdog = nil
    }

    private func fitIfNeeded() {
        recoverVisibilityIfNeeded()
        guard isVisible, let host = contentView as? OverlayHostingView else { return }
        let ideal = host.fittingSize
        let current = contentRect(forFrameRect: frame).size
        if abs(ideal.width - current.width) > 0.5 || abs(ideal.height - current.height) > 0.5 {
            fitWindow(to: ideal)
        }
    }

    private func recoverVisibilityIfNeeded() {
        guard presentationRequested else { return }
        if isVisible && isOnActiveSpace && occlusionState.contains(.visible) {
            visibilityRecoveryAttempts = 0
            return
        }
        // A panel can be lost after the transition notifications finish, or become
        // covered while switching windows in the same app. Inspect only this panel;
        // never activate the app, take keyboard focus, or raise its window level.
        // Bound recovery when another system surface intentionally covers it.
        guard visibilityRecoveryAttempts < 3,
              ProcessInfo.processInfo.systemUptime >= nextVisibilityRecovery else { return }
        visibilityRecoveryAttempts += 1
        scheduleWorkspaceRefreshes()
    }

    /// SwiftUI can measure during an AppKit layout pass. Defer the window mutation, coalesce
    /// repeated measurements, and ignore unchanged sizes to avoid a layout/resize cycle.
    private func scheduleResize(to size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        pendingContentSize = size
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            guard let size = self.pendingContentSize else { return }
            self.pendingContentSize = nil
            self.fitWindow(to: size)
        }
    }

    private func fitWindow(to contentSize: CGSize) {
        guard contentSize.width.isFinite, contentSize.height.isFinite,
              contentSize.width > 0, contentSize.height > 0 else { return }
        guard let screen = anchorScreen ?? screenUnderMouse() else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: ceil(contentSize.width), height: ceil(contentSize.height))
        let desired = NSRect(x: visible.midX - size.width / 2, y: visible.minY + 12,
                             width: size.width, height: size.height)
        guard frame != desired else { return }
        setFrame(desired, display: true)
        invalidateShadow()
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    // A finished preview may receive a deliberate click to select/copy text. The
    // listening/processing bar never takes keyboard focus away from the destination.
    override var canBecomeKey: Bool {
        if case .result = model.state { return true }
        return false
    }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if case .result = model.state { model.onDismiss?() }
        else { super.cancelOperation(sender) }
    }

    func present() {
        cancelWorkspaceRefreshes()
        presentationRequested = true
        visibilityRecoveryAttempts = 0
        nextVisibilityRecovery = ProcessInfo.processInfo.systemUptime + 1
        // A preview may have accepted deliberate text-selection focus. Hiding it
        // once releases that key status before the passive listening bar returns.
        if isKeyWindow && !canBecomeKey { orderOut(nil) }
        reposition()
        orderFrontRegardless()
        startWatchdog()
        // The first SwiftUI render can finish after orderFront; its size preference corrects
        // this measurement automatically without depending on mouse movement.
        if let host = contentView as? OverlayHostingView {
            host.layoutSubtreeIfNeeded()
            scheduleResize(to: host.fittingSize)
        }
    }

    func reposition() {
        anchorScreen = screenUnderMouse()
        if let size = anchorScreen?.visibleFrame.size, model.availableScreenSize != size {
            model.availableScreenSize = size
        }
        if let host = contentView as? OverlayHostingView {
            host.layoutSubtreeIfNeeded()
            fitWindow(to: host.fittingSize)
        }
    }

    func dismiss() {
        presentationRequested = false
        cancelWorkspaceRefreshes()
        stopWatchdog()
        orderOut(nil)
    }
}
