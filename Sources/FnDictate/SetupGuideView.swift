import SwiftUI

/// Shared instructions for onboarding and the settings window. Illustrations contain
/// only invented system-settings content, never a capture of the user's Mac.
enum SetupGuideKind: String, CaseIterable, Identifiable {
    case fnKey, microphone, accessibility, inputMonitoring

    var id: String { rawValue }

    fileprivate var title: String {
        switch self {
        case .fnKey: return "Keep Fn free for your dictation"
        case .microphone: return "Turn on microphone access"
        case .accessibility: return "Let your words land in other apps"
        case .inputMonitoring: return "Allow the keyboard shortcut"
        }
    }

    fileprivate var paneName: String {
        switch self {
        case .fnKey: return "Keyboard"
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .fnKey: return "keyboard"
        case .microphone: return "mic.fill"
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        }
    }

    fileprivate var pane: Permissions.Pane {
        switch self {
        case .fnKey: return .keyboard
        case .microphone: return .microphone
        case .accessibility: return .accessibility
        case .inputMonitoring: return .inputMonitoring
        }
    }

    fileprivate var steps: [(title: String, detail: String)] {
        switch self {
        case .fnKey:
            return [
                ("Turn off Apple Dictation first", "Open System Settings → Keyboard. Scroll to Dictation and switch it off."),
                ("Set the Globe action to Do Nothing", "Scroll up to “Press 🌐︎ key to”, above Keyboard Shortcuts… Choose “Do Nothing”. Some Macs label this key Fn."),
                ("Return to Expertise Typer", "During setup, press and release Fn in the shortcut check. After setup, one press starts dictation and another finishes it.")
            ]
        case .microphone:
            return [
                ("Open Microphone settings", "System Settings → Privacy & Security → Microphone."),
                ("Turn on Expertise Typer", "Find the app and switch its microphone access on."),
                ("Return to the app", "The permission status updates automatically.")
            ]
        case .accessibility:
            return [
                ("Open Accessibility settings", "System Settings → Privacy & Security → Accessibility."),
                ("Turn on Expertise Typer", "This lets the app insert text where you are writing."),
                ("Return to the app", "If macOS asks you to quit and reopen it, follow that prompt.")
            ]
        case .inputMonitoring:
            return [
                ("Open Input Monitoring settings", "System Settings → Privacy & Security → Input Monitoring."),
                ("Turn on Expertise Typer", "Use this permission if macOS asks for keyboard access."),
                ("Reopen the app if asked", "Then return here and try your shortcut again.")
            ]
        }
    }

    fileprivate var note: String {
        switch self {
        case .fnKey:
            return "Apple Dictation has its own Shortcut setting. Changing it can also change the Globe action. If you change that shortcut later, recheck “Press 🌐︎ key to” and choose “Do Nothing” again."
        case .microphone:
            return "App missing? Use Allow Microphone in setup first so macOS can request access, then check this list again."
        case .accessibility:
            return "App missing? Click Open Accessibility Settings in setup. Or use + in the system pane and select Expertise Typer from Applications."
        case .inputMonitoring:
            return "This is only needed if the shortcut asks for it. Use Allow keyboard access in setup first if the app is not listed."
        }
    }

    fileprivate var exampleExplanation: String {
        switch self {
        case .fnKey: return "The Globe key's system action is set to Do Nothing."
        case .microphone: return "Allow the applications below to access your microphone."
        case .accessibility: return "Allow the applications below to control your computer."
        case .inputMonitoring: return "Allow the applications below to monitor input from your keyboard."
        }
    }
}

struct SetupGuideView: View {
    let kind: SetupGuideKind
    let showsOpenButton: Bool
    @State private var showsLargeExample = false

    init(kind: SetupGuideKind, showsOpenButton: Bool = true) {
        self.kind = kind
        self.showsOpenButton = showsOpenButton
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(kind.title, systemImage: kind.symbol)
                .font(.hub(15, .semibold)).foregroundColor(Hub.ink)
            if showsOpenButton { openButton }
            instructionSteps
            SetupSettingsExample(kind: kind)
            HStack {
                Text("Example screen · layout may vary")
                    .font(.hub(11)).foregroundColor(Hub.helper)
                Spacer(minLength: 8)
                Button { showsLargeExample = true } label: {
                    Label("Show larger example", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.hub(11, .medium))
                        .padding(.vertical, 5).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundColor(Hub.green)
                .accessibilityIdentifier("setup-guide-expand-\(kind.rawValue)")
            }
            Text(kind.note).font(.hub(12)).foregroundColor(Hub.helper)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Hub.cardRadius).fill(Hub.cream))
        .overlay(RoundedRectangle(cornerRadius: Hub.cardRadius).strokeBorder(Hub.line2).allowsHitTesting(false))
        .sheet(isPresented: $showsLargeExample) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(kind.paneName).font(.hub(23, .semibold)).foregroundColor(Hub.ink)
                        Text("Example screen — make this change in System Settings.")
                            .font(.hub(13)).foregroundColor(Hub.helper)
                    }
                    Spacer()
                    Button("Done") { showsLargeExample = false }
                        .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                        .keyboardShortcut(.cancelAction)
                }
                SetupSettingsExample(kind: kind, enlarged: true)
                Text(kind.note).font(.hub(14)).foregroundColor(Hub.helper)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Illustration only. macOS wording and layout can vary.")
                        .font(.hub(12)).foregroundColor(Hub.helper)
                    Spacer()
                    if showsOpenButton { openButton }
                }
            }
            .padding(28).frame(width: 700)
            .background(Hub.cream)
        }
    }

    private var instructionSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(kind.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)").font(.hub(11, .semibold)).foregroundColor(Hub.green)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Hub.green.opacity(0.10)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).font(.hub(13, .semibold)).foregroundColor(Hub.body)
                        Text(step.detail).font(.hub(12)).foregroundColor(Hub.helper)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(index + 1). \(step.title). \(step.detail)")
            }
        }
    }

    private var openButton: some View {
        Button("Open \(kind.paneName) Settings") { Permissions.open(kind.pane) }
            .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
            .accessibilityIdentifier("setup-guide-open-\(kind.rawValue)")
    }
}

/// Onboarding opens detailed instructions only when requested. Its close button
/// and the real System Settings action remain visible while the guide scrolls.
struct SetupGuideSheet: View {
    let kind: SetupGuideKind
    var allowsSystemSettings = true
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(kind.paneName).font(.hub(25, .semibold)).foregroundColor(Hub.ink)
                    Text("Follow these steps in macOS System Settings.")
                        .font(.hub(13)).foregroundColor(Hub.helper)
                }
                Spacer()
                Button("Done", action: onDismiss)
                    .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("onboarding-guide-done")
            }.padding(24)
            Divider()
            ScrollView {
                SetupGuideView(kind: kind, showsOpenButton: false).padding(24)
            }
            Divider()
            HStack {
                Text("Illustration only. Your macOS version may look different.")
                    .font(.hub(11)).foregroundColor(Hub.helper)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Open \(kind.paneName) Settings") {
                    if allowsSystemSettings { Permissions.open(kind.pane) }
                }.buttonStyle(PillButtonStyleHub())
                    .accessibilityIdentifier("onboarding-guide-open-\(kind.rawValue)")
            }.padding(24)
        }
        .frame(width: 680, height: 610)
        .background(Hub.cream)
    }
}

/// Deliberately static, synthetic diagram: the switches and popup are not controls.
/// The real action button stays outside the illustration to avoid a false affordance.
private struct SetupSettingsExample: View {
    let kind: SetupGuideKind
    var enlarged = false
    private var scale: CGFloat { enlarged ? 1.2 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach(0..<3) { _ in Circle().fill(Hub.line2).frame(width: 7 * scale, height: 7 * scale) }
                Text("System Settings").font(.system(size: 11 * scale, weight: .medium)).foregroundColor(Hub.helper)
                    .padding(.leading, 6)
                Spacer()
                Text("EXAMPLE").font(.system(size: 9 * scale, weight: .semibold)).tracking(0.6).foregroundColor(Hub.helper)
            }
            .padding(12 * scale).background(Hub.line.opacity(0.8))
            VStack(alignment: .leading, spacing: 14 * scale) {
                HStack(spacing: 7 * scale) {
                    if kind != .fnKey {
                        Text("Privacy & Security").foregroundColor(Hub.helper)
                        Image(systemName: "chevron.right").font(.system(size: 9 * scale, weight: .semibold)).foregroundColor(Hub.helper)
                    }
                    Label(kind.paneName, systemImage: kind.symbol).foregroundColor(Hub.ink)
                }.font(.system(size: 12 * scale, weight: .semibold))
                if kind == .fnKey { keyboardRow }
                else { permissionRow }
            }
            .padding(16 * scale)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Hub.card))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Hub.line2))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind == .fnKey
            ? "Example System Settings, Keyboard. First, turn Dictation off further down the page. Then set Press Globe key to: Do Nothing."
            : "Example System Settings, Privacy and Security, \(kind.paneName). Expertise Typer changes from off to on.")
    }

    private var keyboardRow: some View {
        VStack(alignment: .leading, spacing: 11 * scale) {
            HStack(spacing: 10 * scale) {
                Text("Press 🌐︎ key to").font(.system(size: 13 * scale)).foregroundColor(Hub.body)
                Spacer(minLength: 10)
                HStack(spacing: 10 * scale) {
                    Image(systemName: "checkmark").font(.system(size: 10 * scale, weight: .semibold)).foregroundColor(Hub.green)
                    Text("Do Nothing").font(.system(size: 12 * scale, weight: .medium)).foregroundColor(Hub.ink)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9 * scale, weight: .semibold)).foregroundColor(Hub.helper)
                }
                .padding(.horizontal, 10 * scale).padding(.vertical, 7 * scale)
                .background(RoundedRectangle(cornerRadius: 6).fill(Hub.card))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Hub.green.opacity(0.5)))
            }
            .padding(12 * scale)
            .background(RoundedRectangle(cornerRadius: 8).fill(Hub.greenSoft))
            Text("Further down the same Keyboard page")
                .font(.system(size: 11 * scale)).foregroundColor(Hub.helper)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12 * scale) {
                VStack(alignment: .leading, spacing: 3 * scale) {
                    Text("Dictation").font(.system(size: 13 * scale, weight: .semibold)).foregroundColor(Hub.ink)
                    Text("Apple’s built-in dictation").font(.system(size: 11 * scale)).foregroundColor(Hub.helper)
                }
                Spacer(minLength: 10)
                illustratedSwitch(on: false)
            }
            .padding(12 * scale)
            .background(RoundedRectangle(cornerRadius: 8).fill(Hub.line.opacity(0.7)))
        }
    }

    private var permissionRow: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            Text(kind.exampleExplanation).font(.system(size: 11 * scale)).foregroundColor(Hub.helper)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10 * scale) {
                Image(systemName: "waveform.and.mic").font(.system(size: 17 * scale, weight: .medium)).foregroundColor(.white)
                    .frame(width: 34 * scale, height: 34 * scale)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Hub.buttonGreen))
                Text("Expertise Typer").font(.system(size: 13 * scale, weight: .medium)).foregroundColor(Hub.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                illustratedSwitch(on: false)
                Image(systemName: "arrow.right").font(.system(size: 11 * scale, weight: .semibold)).foregroundColor(Hub.helper)
                illustratedSwitch(on: true)
            }
            .padding(12 * scale)
            .background(RoundedRectangle(cornerRadius: 8).fill(Hub.greenSoft))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Hub.green.opacity(0.25)))
        }
    }

    private func illustratedSwitch(on: Bool) -> some View {
        VStack(spacing: 4 * scale) {
            Capsule().fill(on ? Color.accentColor : Hub.line2)
                .frame(width: 32 * scale, height: 19 * scale)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(Color.white).frame(width: 15 * scale, height: 15 * scale).padding(2 * scale)
                }
            Text(on ? "On" : "Off").font(.system(size: 9 * scale, weight: on ? .semibold : .regular))
                .foregroundColor(on ? Hub.ink : Hub.helper)
        }
    }
}
