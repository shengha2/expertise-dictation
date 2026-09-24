import SwiftUI
import AppKit

/// A short, verified path from permissions to an actual insertion. Connection
/// setup follows the distribution mode, and leaving early never completes setup.
struct OnboardingView: View {
    @ObservedObject var controller: DictationController
    let hotkey: HotkeyMonitor
    var onFinish: () -> Void
    @EnvironmentObject var settings: Settings
    @ObservedObject private var session = OnboardingSession.shared
    @ObservedObject private var service = HostedService.shared

    private enum Step: Int, CaseIterable {
        case permissions, microphone, shortcut, practice, ready
        var title: String {
            switch self {
            case .permissions: return "Permissions"
            case .microphone: return "Microphone"
            case .shortcut: return "Shortcut"
            case .practice: return "Try it"
            case .ready: return "Ready"
            }
        }
    }

    @State private var step = Step.permissions
    @State private var micStatus = Permissions.microphoneStatus
    @State private var axGranted = Permissions.accessibilityGranted
    @State private var shortcutActive = false
    @State private var attempt = OnboardingAttempt()
    @State private var practiceEvidence = OnboardingPracticeEvidence()
    @State private var practiceText = ""
    @State private var showLanguages = false
    @State private var showShortcutChoices = false
    @State private var showMicrophoneChoices = false
    @State private var guide: SetupGuideKind?
    @FocusState private var practiceFocused: Bool
    private let uiTesting = CommandLine.arguments.contains("--ui-test")
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var permissionsReady: Bool { micStatus == .authorized && axGranted }
    private var serviceReady: Bool {
        if !settings.usesHostedService { return connectionIsConfigured(settings) }
        if case .ready = service.state { return true }
        return false
    }
    private var shortcutVerified: Bool { session.verifiedShortcut == settings.triggerKey }
    private var canPractice: Bool { permissionsReady && attempt.microphone.heardAudio && shortcutActive && shortcutVerified && serviceReady }
    private var canFinish: Bool {
        controller.phase == .idle && attempt.canFinish(permissionsReady: permissionsReady,
                                                       shortcutReady: shortcutActive && shortcutVerified)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                ScrollView {
                    let layout = geometry.size.width >= 820
                        ? AnyLayout(HStackLayout(alignment: .top, spacing: 38))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: 22))
                    layout {
                        introduction.frame(maxWidth: .infinity, alignment: .leading)
                        activity.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(32)
                    .frame(maxWidth: 1060, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            Divider().padding(.horizontal, 32)
            footer
        }
        .frame(minWidth: 720, minHeight: 600)
        .background(Hub.cream)
        .onAppear {
            applyPreviewStep()
            resumeAttempt()
        }
        .onDisappear { controller.stopMicTest(); session.suspend() }
        .onReceive(NotificationCenter.default.publisher(for: .fnDictateResumeOnboarding)) { _ in resumeAttempt() }
        .task {
            if settings.usesHostedService && !uiTesting { await service.refresh() }
        }
        .onReceive(refresh) { _ in refreshStatus(); updatePracticeSuccess() }
        .onReceive(controller.$micTestLevel) { level in
            guard session.isActive, step == .microphone else { return }
            attempt.microphone.receive(level: level, testing: controller.micTesting)
        }
        .onChange(of: settings.micPreference) { _, _ in
            attempt.microphone.reset()
            attempt.practiceSucceeded = false
            refreshStatus()
            if step == .microphone && session.isActive { restartMicrophoneCheck() }
        }
        .onChange(of: settings.triggerKey) { _, key in
            attempt.practiceSucceeded = false
            session.invalidateShortcut()
            refreshStatus()
            if step == .shortcut { session.beginShortcutCheck(key) }
        }
        .onChange(of: controller.phase) { _, phase in
            if session.isActive && step == .practice && phase == .recording {
                attempt.practiceSucceeded = false
                practiceEvidence.begin(focused: practiceFocused,
                                       insertionCount: controller.successfulInsertionCount,
                                       text: practiceText)
            }
        }
        .onChange(of: controller.successfulInsertionCount) { _, _ in updatePracticeSuccess() }
        .onChange(of: controller.lastInserted) { _, _ in updatePracticeSuccess() }
        .onChange(of: practiceText) { _, _ in updatePracticeSuccess() }
        .sheet(isPresented: $showLanguages) { LanguagePickerView().environmentObject(settings) }
        .sheet(item: $guide) { kind in
            SetupGuideSheet(kind: kind, allowsSystemSettings: !uiTesting) { guide = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Expertise Dictation", systemImage: "waveform.and.mic")
                    .font(.hub(14, .semibold)).foregroundColor(Hub.green)
                Spacer()
                Text("\(step.rawValue + 1) of \(Step.allCases.count) · \(step.title)")
                    .font(.hub(12, .medium)).foregroundColor(Hub.helper)
                    .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count), \(step.title)")
            }
            HStack(spacing: 7) {
                ForEach(Step.allCases, id: \.rawValue) { item in
                    Capsule().fill(item.rawValue <= step.rawValue ? Hub.green : Hub.line2)
                        .frame(height: 3)
                }
            }.accessibilityHidden(true)
        }
        .padding(.horizontal, 32).padding(.top, 25).padding(.bottom, 10)
    }

    @ViewBuilder private var introduction: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: introductionSymbol).font(.system(size: 30, weight: .medium))
                .foregroundColor(Hub.green).accessibilityHidden(true)
            Text(introductionTitle).font(.hub(31, .semibold)).tracking(-0.7)
                .foregroundColor(Hub.ink).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(introductionDetail).font(.hub(15)).foregroundColor(Hub.body)
                .fixedSize(horizontal: false, vertical: true)
            switch step {
            case .permissions:
                Text(settings.usesHostedService ? "No account or API key to set up." : "Use your own API key.")
                    .font(.hub(13, .medium)).foregroundColor(Hub.green)
                if !settings.usesHostedService {
                    Text("Save your OpenAI API key in Connection settings before trying dictation. Your provider bills usage to your account.")
                        .font(.hub(12)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
                    Button(serviceReady ? "Connection settings" : "Add your API key") { openConnectionSettings() }
                        .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                }
                Text(settings.usesHostedService
                     ? "Online dictation sends audio and text to the processing service. Your microphone is used when you start a recording or this setup check."
                     : "Online dictation sends audio and text directly to your selected providers. Your microphone is used when you start a recording or this setup check.")
                    .font(.hub(12)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
            case .microphone:
                Text("Say a few words in any language. This check measures audio on your Mac; it does not send speech for transcription.")
                    .font(.hub(13)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
            case .shortcut:
                Text("This step only checks the key. It won’t start a recording.")
                    .font(.hub(13)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
                if settings.triggerKey == .fn {
                    helpButton("Fn opens emoji or Apple Dictation?", kind: .fnKey)
                }
            case .practice:
                practiceInstructions
                Text("Try your own sentence, or use the example. You can speak any of your selected languages.")
                    .font(.hub(12)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
            case .ready:
                Text("Expertise Dictation stays in your menu bar when this window is closed.")
                    .font(.hub(13)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var introductionSymbol: String {
        switch step {
        case .permissions: return "hand.raised"
        case .microphone: return "mic"
        case .shortcut: return "keyboard"
        case .practice: return "text.bubble"
        case .ready: return "checkmark.circle"
        }
    }
    private var introductionTitle: String {
        switch step {
        case .permissions: return "A couple of permissions. Then your voice."
        case .microphone: return attempt.microphone.heardAudio ? "Your microphone is working." : "Let’s hear you."
        case .shortcut: return shortcutVerified ? "That’s your shortcut." : "Press \(settings.triggerKey.shortName) to try it."
        case .practice: return attempt.practiceSucceeded ? "Your words are right here." : "Say your first message."
        case .ready: return "Ready where you write."
        }
    }
    private var introductionDetail: String {
        switch step {
        case .permissions: return "macOS asks you to allow these once. We’ll guide you through each one."
        case .microphone: return attempt.microphone.heardAudio ? "We received audio from the selected microphone." : "Speak normally and watch the level move."
        case .shortcut: return "Press and release the key once. We’ll try a real dictation in the next step."
        case .practice: return attempt.practiceSucceeded ? "This was inserted into a real text field. You can edit it as usual." : "Click the message field, use your shortcut, and speak naturally."
        case .ready: return "Open a message, note or document. Click where you want your words to go."
        }
    }

    @ViewBuilder private var activity: some View {
        switch step {
        case .permissions: permissionsCard
        case .microphone: microphoneCard
        case .shortcut: shortcutCard
        case .practice: practiceCard
        case .ready: readyCard
        }
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            permissionRow(title: "Microphone", detail: "To hear you when you dictate.", symbol: "mic",
                          allowed: micStatus == .authorized,
                          actionTitle: micStatus == .notDetermined ? "Allow microphone" : "Open settings",
                          guideKind: .microphone) {
                guard !uiTesting else { return }
                if micStatus == .notDetermined { Permissions.requestMicrophone { _ in refreshStatus() } }
                else { Permissions.open(.microphone) }
            }
            Divider()
            permissionRow(title: "Accessibility", detail: "To use your shortcut and insert text in other apps.",
                          symbol: "cursorarrow.click", allowed: axGranted,
                          actionTitle: "Open settings", guideKind: .accessibility) {
                guard !uiTesting else { return }
                Permissions.requestAccessibility()
                Permissions.open(.accessibility)
            }
            Text(permissionsReady ? "Both permissions are allowed. You can continue." : "After enabling access in System Settings, come back here. We check automatically.")
                .font(.hub(12)).foregroundColor(permissionsReady ? Hub.green : Hub.helper)
                .fixedSize(horizontal: false, vertical: true)
            if micStatus == .restricted {
                Text("This Mac restricts microphone access. A device administrator may need to enable it.")
                    .font(.hub(12)).foregroundColor(Hub.amber).fixedSize(horizontal: false, vertical: true)
            }
        }.onboardingCard()
    }

    private func permissionRow(title: String, detail: String, symbol: String, allowed: Bool,
                               actionTitle: String, guideKind: SetupGuideKind,
                               action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 21)).foregroundColor(Hub.green)
                    .frame(width: 28).padding(.top, 2).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.hub(16, .semibold)).foregroundColor(Hub.ink)
                    Text(detail).font(.hub(12)).foregroundColor(Hub.helper)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if allowed {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Hub.green)
                        .accessibilityLabel("\(title) allowed")
                }
            }
            if !allowed {
                Button(actionTitle, action: action).buttonStyle(PillButtonStyleHub())
                    .accessibilityIdentifier("onboarding-allow-\(guideKind.rawValue)")
                helpButton("Show me how", kind: guideKind)
            }
        }
    }

    private var microphoneCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Microphone check").font(.hub(15, .semibold)).foregroundColor(Hub.ink)
                Spacer()
                if attempt.microphone.heardAudio {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Hub.green)
                }
            }
            OnboardingAudioMeter(level: controller.micTestLevel, running: controller.micTesting)
                .frame(height: 80)
            Text(attempt.microphone.heardAudio ? "Audio received" : (controller.micTesting ? "Listening for your voice…" : "The microphone check is stopped"))
                .font(.hub(14, .medium)).foregroundColor(attempt.microphone.heardAudio ? Hub.green : Hub.helper)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("onboarding-microphone-status")
            disclosureButton("Change microphone", expanded: $showMicrophoneChoices)
            if showMicrophoneChoices {
                Picker("Microphone", selection: $settings.micPreference) {
                    Text("System default").tag(MicPreference.systemDefault)
                    Text("Built-in microphone").tag(MicPreference.builtIn)
                }.accessibilityIdentifier("onboarding-microphone-picker")
                Text("System default follows the input selected in macOS Sound settings.")
                    .font(.hub(12)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
            }
            if !controller.micTesting {
                Button("Try microphone again") { restartMicrophoneCheck() }
                    .buttonStyle(PillButtonStyleHub(kind: .secondary))
                    .disabled(micStatus != .authorized)
            }
            if let error = controller.lastError, !error.isEmpty, !controller.micTesting, !attempt.microphone.heardAudio {
                Text(error).font(.hub(12)).foregroundColor(Hub.flag).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            languageControl
        }.onboardingCard()
    }

    private var languageControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Languages you speak").font(.hub(12, .medium)).foregroundColor(Hub.helper)
            Button { showLanguages = true } label: {
                HStack(spacing: 10) {
                    Text(languageSummary(settings.dictationLanguages))
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Image(systemName: "plus.circle")
                }.font(.hub(14, .medium)).foregroundColor(Hub.green)
                    .frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("onboarding-languages")
            Text("One language or several. Add the languages you use.")
                .font(.hub(12)).foregroundColor(Hub.helper)
        }
    }

    private var shortcutCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(settings.triggerKey == .fn ? "Bottom-left of your Mac keyboard" : "Your dictation shortcut")
                .font(.hub(12)).foregroundColor(Hub.helper).frame(maxWidth: .infinity)
            Text(settings.triggerKey == .fn ? "fn  🌐" : settings.triggerKey.shortName)
                .font(.hub(36, .medium)).foregroundColor(session.shortcutIsDown ? .white : Hub.ink)
                .padding(.horizontal, 30).frame(minWidth: 140, minHeight: 112)
                .background(RoundedRectangle(cornerRadius: 18).fill(session.shortcutIsDown ? Hub.green : Hub.cream))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(shortcutVerified ? Hub.green : Hub.line2).allowsHitTesting(false))
                .frame(maxWidth: .infinity)
                .accessibilityLabel("\(settings.triggerKey.shortName), \(session.shortcutIsDown ? "pressed" : "released")")
                .accessibilityIdentifier("onboarding-shortcut-key")
            Label(shortcutVerified ? "Shortcut detected" : (session.shortcutIsDown ? "Now release the key" : "Press and release the key once"),
                  systemImage: shortcutVerified ? "checkmark.circle.fill" : "keyboard")
                .font(.hub(13, .medium)).foregroundColor(shortcutVerified ? Hub.green : Hub.helper)
                .frame(maxWidth: .infinity).accessibilityIdentifier("onboarding-shortcut-status")
            disclosureButton("Use a different shortcut", expanded: $showShortcutChoices)
            if showShortcutChoices {
                Picker("Dictation shortcut", selection: $settings.triggerKey) {
                    ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("onboarding-shortcut-picker")
            }
            if !shortcutActive {
                Divider()
                Text("The shortcut listener is not connected yet.")
                    .font(.hub(12)).foregroundColor(Hub.amber).fixedSize(horizontal: false, vertical: true)
                Button("Retry shortcut connection") {
                    guard !uiTesting else { return }
                    if Permissions.accessibilityGranted { _ = hotkey.start() }
                    refreshStatus()
                }.buttonStyle(PillButtonStyleHub(kind: .secondary))
                helpButton("macOS is asking for Input Monitoring", kind: .inputMonitoring)
                Button("Allow keyboard access") {
                    guard !uiTesting else { return }
                    Permissions.requestInputMonitoring()
                    Permissions.open(.inputMonitoring)
                }.buttonStyle(PillButtonStyleHub(kind: .ghost, small: true))
            }
            if shortcutVerified { serviceStatus }
        }.onboardingCard()
    }

    private var practiceInstructions: some View {
        VStack(alignment: .leading, spacing: 14) {
            instruction(1, "Click the message field.")
            instruction(2, "Press \(settings.triggerKey.shortName), then speak.")
            instruction(3, "Press \(settings.triggerKey.shortName) again to finish.")
            Text("For example")
                .font(.hub(11, .semibold)).foregroundColor(Hub.helper).textCase(.uppercase)
                .padding(.top, 4)
            Text("“Let’s meet at ten. Actually, make that ten thirty. I’ll bring the notes.”")
                .font(.hub(16)).foregroundColor(Hub.ink).fixedSize(horizontal: false, vertical: true)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Hub.greenSoft))
        }
    }

    private func instruction(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)").font(.hub(11, .semibold)).foregroundColor(Hub.green)
                .frame(width: 22, height: 22).background(Circle().fill(Hub.greenSoft))
            Text(text).font(.hub(13)).foregroundColor(Hub.body).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }

    private var practiceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Your first message", systemImage: "text.bubble")
                    .font(.hub(14, .semibold)).foregroundColor(Hub.ink)
                Spacer()
                if attempt.practiceSucceeded { Image(systemName: "checkmark.circle.fill").foregroundColor(Hub.green) }
            }
            TextEditor(text: $practiceText)
                .font(.hub(17)).scrollContentBackground(.hidden)
                .focused($practiceFocused).frame(height: 190).padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Hub.cream))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(practiceFocused ? Hub.green : Hub.line2).allowsHitTesting(false))
                .accessibilityLabel("Dictation practice text")
                .accessibilityIdentifier("onboarding-practice-editor")
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: attempt.practiceSucceeded ? "checkmark.circle.fill" : (controller.phase == .recording ? "mic.fill" : "waveform"))
                Text(attempt.practiceSucceeded ? "Dictation inserted successfully" : practiceStatus)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.font(.hub(12, .medium)).foregroundColor(attempt.practiceSucceeded ? Hub.green : Hub.helper)
                .accessibilityIdentifier("onboarding-practice-status")
            if controller.phase == .recording {
                Button("Cancel recording") { controller.cancel(reason: "Practice cancelled"); practiceFocused = true }
                    .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
            }
            Text("Esc cancels. If you haven’t said anything, the recording closes quietly.")
                .font(.hub(12)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
            if !serviceReady { serviceStatus }
            if let error = controller.lastError, !error.isEmpty, !attempt.practiceSucceeded {
                Text(error).font(.hub(12)).foregroundColor(Hub.flag).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again in this field") { practiceFocused = true }
                    .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                    .disabled(controller.phase != .idle || !canPractice)
            }
        }.onboardingCard()
    }

    private var readyCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Your setup is working", systemImage: "checkmark.circle.fill")
                .font(.hub(17, .semibold)).foregroundColor(Hub.green)
            HStack(spacing: 12) {
                KeyBadge(text: settings.triggerKey.shortName)
                Text("Press. Speak. Press again.").font(.hub(15, .medium)).foregroundColor(Hub.ink)
            }
            Divider()
            Text("\(settings.dictationMode.menuTitle) is selected.")
                .font(.hub(14, .medium)).foregroundColor(Hub.ink)
            Text("You can change how much is rewritten in Settings: Full rewrite, Light, or None.")
                .font(.hub(13)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
            if settings.triggerKey == .fn && settings.doubleTapTranslates {
                Text("For translation, double-tap Fn before speaking. Press once more to finish.")
                    .font(.hub(13)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
            }
            Text("If the destination changes, your result stays available to copy.")
                .font(.hub(13)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
            if !serviceReady { serviceStatus }
        }.onboardingCard()
    }

    @ViewBuilder private var serviceStatus: some View {
        if settings.usesHostedService {
            switch service.state {
            case .ready:
                Label("Dictation service is ready", systemImage: "checkmark.circle.fill")
                    .font(.hub(12)).foregroundColor(Hub.green)
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking the dictation service…").font(.hub(12)).foregroundColor(Hub.helper)
                }
            case .unavailable(let message):
                VStack(alignment: .leading, spacing: 10) {
                    Text("The dictation service isn’t available yet.")
                        .font(.hub(13, .medium)).foregroundColor(Hub.amber)
                    Text(message).font(.hub(12)).foregroundColor(Hub.helper)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Button("Retry connection") { refreshService() }
                        .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                }
            }
        } else if !serviceReady {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add or check your API key in Connection settings, then return here to continue. Your microphone and shortcut checks are kept.")
                    .font(.hub(12)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
                Button("Open connection settings") { openConnectionSettings() }
                    .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                if settings.offersHostedService, HostedService.baseURL != nil, service.state == .ready {
                    Button("Use included service") { settings.usesHostedService = true }
                        .buttonStyle(PillButtonStyleHub(kind: .ghost, small: true))
                }
            }
        }
    }

    private func openConnectionSettings() {
        session.suspend()
        NotificationCenter.default.post(name: .fnDictateOpenSettings, object: nil,
                                        userInfo: ["tab": SettingsTab.advanced.rawValue])
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if !permissionsReady && step != .permissions {
                recoveryNotice("A required permission is no longer allowed.", action: "Check permissions", step: .permissions)
            } else if step.rawValue >= Step.shortcut.rawValue && !attempt.microphone.heardAudio {
                recoveryNotice("Let’s check this microphone before continuing.", action: "Check microphone", step: .microphone)
            } else if (step == .practice || step == .ready) && (!shortcutActive || !shortcutVerified) {
                recoveryNotice("Your shortcut needs to be checked again.", action: "Check shortcut", step: .shortcut)
            }
            HStack {
                if step != .permissions {
                    Button("Back") { goBack() }.buttonStyle(PillButtonStyleHub(kind: .secondary))
                } else if step != .ready {
                    Button("Set up later") { leaveIncomplete() }
                        .buttonStyle(PillButtonStyleHub(kind: .ghost))
                }
                Spacer()
                Button(primaryTitle) { advance() }
                    .buttonStyle(PillButtonStyleHub()).disabled(!primaryEnabled)
                    .accessibilityIdentifier("onboarding-continue")
            }
            if step != .permissions && step != .ready {
                HStack {
                    Button("Set up later") { leaveIncomplete() }
                        .buttonStyle(PillButtonStyleHub(kind: .ghost, small: true))
                    Spacer()
                }
            }
        }.padding(.horizontal, 32).padding(.top, 16).padding(.bottom, 18)
    }

    private func recoveryNotice(_ message: String, action: String, step destination: Step) -> some View {
        HStack(spacing: 16) {
            Text(message).font(.hub(12)).foregroundColor(Hub.amber)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action) { move(to: destination) }
                .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
        }
    }

    private var primaryTitle: String {
        switch step {
        case .permissions: return "Check microphone"
        case .microphone: return "Check shortcut"
        case .shortcut: return "Try dictation"
        case .practice: return "Continue"
        case .ready: return "Start using Expertise Dictation"
        }
    }
    private var primaryEnabled: Bool {
        switch step {
        case .permissions: return permissionsReady
        case .microphone: return permissionsReady && attempt.microphone.heardAudio
        case .shortcut: return canPractice
        case .practice, .ready: return canFinish
        }
    }
    private var practiceStatus: String {
        switch controller.phase {
        case .idle: return practiceFocused ? "Press \(settings.triggerKey.shortName) when you’re ready." : "Click the field first, then press \(settings.triggerKey.shortName)."
        case .recording: return "Listening · \(Int(controller.recordingSeconds))s"
        case .finishing, .processing: return "Turning your words into text…"
        }
    }

    private func helpButton(_ title: String, kind: SetupGuideKind) -> some View {
        Button { guide = kind } label: {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.circle")
                Text(title).multilineTextAlignment(.leading)
            }.font(.hub(12, .medium)).foregroundColor(Hub.green)
                .frame(minHeight: 36, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("onboarding-help-\(kind.rawValue)")
    }

    private func disclosureButton(_ title: String, expanded: Binding<Bool>) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                Text(title)
                Spacer(minLength: 0)
            }.font(.hub(13, .medium)).foregroundColor(Hub.green)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

    private func advance() {
        guard primaryEnabled else { return }
        switch step {
        case .permissions: move(to: .microphone)
        case .microphone: move(to: .shortcut)
        case .shortcut: move(to: .practice)
        case .practice: move(to: .ready)
        case .ready:
            guard canFinish, !uiTesting else { return }
            settings.hasCompletedSetup = true
            session.end()
            onFinish()
        }
    }

    private func move(to newStep: Step) {
        controller.stopMicTest()
        if controller.phase != .idle { controller.cancel(reason: "Setup navigation") }
        session.pausePractice()
        step = newStep
        switch newStep {
        case .microphone:
            if !attempt.microphone.heardAudio { restartMicrophoneCheck() }
        case .shortcut:
            session.beginShortcutCheck(settings.triggerKey)
            if !uiTesting && axGranted && !hotkey.isRunning { _ = hotkey.start() }
            refreshStatus()
        case .practice:
            guard canPractice || canFinish else { step = .shortcut; session.beginShortcutCheck(settings.triggerKey); return }
            practiceEvidence = OnboardingPracticeEvidence()
            if canPractice { session.beginPractice() }
            DispatchQueue.main.async { practiceFocused = true }
        case .permissions, .ready: break
        }
    }

    private func goBack() {
        if let previous = Step(rawValue: step.rawValue - 1) { move(to: previous) }
    }

    private func restartMicrophoneCheck() {
        controller.stopMicTest()
        attempt.microphone.reset()
        guard micStatus == .authorized, !uiTesting else { return }
        controller.startMicTest()
    }

    private func updatePracticeSuccess() {
        guard session.isActive, step == .practice, !attempt.practiceSucceeded,
              practiceEvidence.succeeded(insertionCount: controller.successfulInsertionCount,
                                         inserted: controller.lastInserted, fieldText: practiceText) else { return }
        attempt.practiceSucceeded = true
    }

    private func refreshStatus() {
        let previousMicStatus = micStatus
        micStatus = Permissions.microphoneStatus
        axGranted = Permissions.accessibilityGranted
        shortcutActive = hotkey.isRunning
        if uiTesting {
            let missing = CommandLine.arguments.contains("--setup-permissions-missing")
            micStatus = missing ? .denied : .authorized
            axGranted = !missing
            shortcutActive = !missing
        }
        if micStatus != .authorized && previousMicStatus == .authorized {
            controller.stopMicTest()
            attempt.microphone.reset()
        }
        let inputDeviceID: UInt32? = uiTesting ? nil : (settings.micPreference == .builtIn
            ? AudioDevices.builtInInputDeviceID() : AudioDevices.defaultInputDeviceID())
        let heardAudio = attempt.microphone.heardAudio
        let invalidateShortcut = attempt.refresh(.init(microphone: settings.micPreference.rawValue,
                                                       inputDeviceID: inputDeviceID,
                                                       shortcut: settings.triggerKey.rawValue,
                                                       microphoneAllowed: micStatus == .authorized,
                                                       accessibilityAllowed: axGranted),
                                                 listenerRunning: shortcutActive)
        if invalidateShortcut { session.invalidateShortcut() }
        if heardAudio && !attempt.microphone.heardAudio && step == .microphone && session.isActive {
            restartMicrophoneCheck()
        }
        if session.isActive && step == .practice && controller.phase == .idle {
            if canPractice { session.beginPractice() }
            else { session.pausePractice() }
        }
    }

    private func resumeAttempt() {
        session.resume()
        refreshStatus()
        guard !uiTesting else { return }
        if !permissionsReady { step = .permissions }
        else if step.rawValue >= Step.microphone.rawValue && !attempt.microphone.heardAudio { step = .microphone }
        else if step.rawValue >= Step.shortcut.rawValue && !shortcutVerified { step = .shortcut }
        if step == .microphone && !attempt.microphone.heardAudio && !controller.micTesting { restartMicrophoneCheck() }
        if step == .shortcut { session.beginShortcutCheck(settings.triggerKey) }
        if step == .practice && canPractice { session.beginPractice(); practiceFocused = true }
    }

    private func refreshService() {
        guard !uiTesting else { return }
        Task { await service.refresh() }
    }

    private func leaveIncomplete() {
        controller.stopMicTest()
        if controller.phase != .idle { controller.cancel(reason: "Setup postponed") }
        session.suspend()
        onFinish()
    }

    private func applyPreviewStep() {
        guard uiTesting, let index = CommandLine.arguments.firstIndex(of: "--setup-step"),
              index + 1 < CommandLine.arguments.count else { return }
        switch CommandLine.arguments[index + 1] {
        case "microphone": step = .microphone
        case "shortcut", "fnKey", "inputMonitoring": step = .shortcut
        case "practice": step = .practice
        case "ready": step = .ready
        default: step = .permissions
        }
        // Preview navigation never manufactures microphone, shortcut, or insertion proof.
    }
}

private extension View {
    func onboardingCard() -> some View {
        padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(Hub.card))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Hub.line).allowsHitTesting(false))
    }
}

private struct OnboardingAudioMeter: View {
    let level: Float
    let running: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(0..<19, id: \.self) { index in
                let distance = abs(CGFloat(index) - 9) / 9
                let signal = running && level.isFinite ? max(0, min(1, CGFloat(level) * 4)) : 0
                Capsule().fill(signal > 0.03 ? Hub.green : Hub.line2)
                    .frame(width: 7, height: 8 + signal * (1 - distance * 0.65) * 60)
            }
        }.frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.1), value: level)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(running ? "Live microphone audio level" : "Microphone check stopped")
    }
}
