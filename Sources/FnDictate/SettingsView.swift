import SwiftUI
import AppKit

/// Keep daily settings compact while giving the personal dictionary a visible destination.
struct SettingsView: View {
    @ObservedObject var controller: DictationController
    let hotkey: HotkeyMonitor
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var ui: UIState

    private var showingPreferences: Bool {
        [.dictation, .transcription, .cleanup, .advanced].contains(ui.tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Label("Expertise Dictation", systemImage: "waveform.and.mic")
                    .font(.hub(15, .semibold)).foregroundColor(Hub.green)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Spacer()
                navigation("Home", selected: !showingPreferences && ui.tab != .dictionary) { ui.tab = .home }
                navigation("Dictionary", selected: ui.tab == .dictionary) { ui.tab = .dictionary }
                navigation("Preferences", selected: showingPreferences) { ui.tab = .dictation }
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
            Divider().overlay(Hub.line).allowsHitTesting(false)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if ui.tab == .history {
                        Button { ui.tab = .home } label: { Label("Home", systemImage: "chevron.left") }
                            .buttonStyle(PillButtonStyleHub(kind: .ghost, small: true))
                    }
                    switch ui.tab {
                    case .home, .setup: HomePage(controller: controller, hotkey: hotkey)
                    case .dictionary: DictionaryPage()
                    case .history: HistoryPage()
                    case .dictation, .transcription, .cleanup, .advanced:
                        PreferencesPage(controller: controller, hotkey: hotkey)
                    }
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .id(ui.tab)
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(Hub.cream)
    }

    private func navigation(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(PillButtonStyleHub(kind: selected ? .secondary : .ghost, small: true))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

func connectionIsConfigured(_ settings: Settings) -> Bool {
    if settings.usesHostedService { return HostedService.shared.state == .ready }
    return Keychain.apiKey(settings.sttEngine.keychainAccount) != nil &&
        (!settings.dictationMode.usesLLM || Keychain.apiKey(settings.cleanupModel.keychainAccount) != nil)
}

func languageSummary(_ codes: [String]) -> String {
    let names = codes.map { code in DictationLanguage.all.first(where: { $0.code == code })?.name ?? code }
    let first = names.prefix(2).joined(separator: ", ")
    return names.count > 2 ? "\(first) +\(names.count - 2)" : first
}

struct HomePage: View {
    @ObservedObject private var hostedService = HostedService.shared
    @ObservedObject private var updater = AppUpdater.shared
    @ObservedObject var controller: DictationController
    let hotkey: HotkeyMonitor
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var history: History
    @EnvironmentObject var ui: UIState
    @State private var readiness = DictationReadiness.setup
    private var ready: Bool { readiness == .ready }
    @State private var showDiscard = false
    @State private var retryingRecording = false
    @State private var recoveryChoices: [RecoveryChoice] = []
    @State private var selectedRecoveryURL: URL?
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HubCard(padding: 26) {
                HStack(spacing: 8) {
                    Circle().fill(controller.phase != .idle || ready ? Hub.green : Hub.amber).frame(width: 8, height: 8)
                    Text(activityTitle)
                        .font(.hub(14, .medium)).foregroundColor(Hub.helper)
                    Spacer()
                    Text(languageSummary(settings.dictationLanguages)).font(.hub(12)).foregroundColor(Hub.helper)
                        .lineLimit(1).truncationMode(.tail)
                }
                if controller.phase == .idle && ready {
                    HStack(spacing: 10) {
                        Text("Press").font(.hub(28, .semibold)).foregroundColor(Hub.ink)
                        KeyBadge(text: settings.triggerKey.shortName)
                        Text("and speak.").font(.hub(28, .semibold)).foregroundColor(Hub.ink)
                    }
                } else {
                    Text(activityHeading).font(.hub(28, .semibold)).foregroundColor(Hub.ink)
                }
                Text(activityHint).font(.hub(14)).foregroundColor(Hub.helper)
                if controller.phase == .idle && [.permissions, .shortcut, .setup].contains(readiness) {
                    Button(settings.hasCompletedSetup ? "Check setup" : "Finish setup") {
                        NotificationCenter.default.post(name: .fnDictateShowOnboarding, object: nil)
                    }.buttonStyle(PillButtonStyleHub())
                } else if controller.phase == .idle && ready {
                    Text("Click a text field in a message, note or document first. Your words will appear there.")
                        .font(.hub(13)).foregroundColor(Hub.helper).padding(.top, 6)
                }
            }
            updateStatus
            if settings.usesHostedService, hostedService.state != .ready, controller.phase == .idle {
                HubCard {
                    Text(hostedService.state.message).font(.hub(13)).foregroundColor(Hub.helper)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry connection") { Task { await hostedService.refresh() } }
                        .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                }
            }
            if !settings.usesHostedService, !connectionIsConfigured(settings), controller.phase == .idle {
                HubCard {
                    Text("Your personal connection needs attention. Your microphone and shortcut checks are kept while you repair it.")
                        .font(.hub(13)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
                    Button("Open connection settings") { ui.tab = .advanced }
                        .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                }
            }
            if controller.recoveryAvailable {
                HubCard {
                    Label(controller.recoveryRecordingURLs.count == 1 ? "Your recording is saved" : "Your recordings are saved",
                          systemImage: "arrow.clockwise.circle")
                        .font(.hub(15, .semibold)).foregroundColor(Hub.ink)
                    if recoveryChoices.count > 1 {
                        Picker("Saved recording", selection: $selectedRecoveryURL) {
                            ForEach(recoveryChoices) { recording in
                                Text(recording.title).tag(Optional(recording.directory))
                            }
                        }
                        .pickerStyle(.menu).labelsHidden()
                        .accessibilityLabel("Saved recording")
                        .disabled(controller.phase != .idle)
                    } else if let recording = selectedRecovery {
                        Text(recording.title).font(.hub(13)).foregroundColor(Hub.helper)
                    }
                    if let recording = selectedRecovery, !recording.readable {
                        Text("This recording can’t be read. You can still inspect its files.")
                            .font(.hub(12)).foregroundColor(Hub.amber)
                    } else {
                        Text("Retry when your connection is ready. Cancelling a retry keeps the recording.")
                            .font(.hub(12)).foregroundColor(Hub.helper)
                    }
                    HStack(spacing: 8) {
                        Button("Retry recording") {
                            guard let recording = selectedRecovery, recording.readable else { return }
                            retryingRecording = true
                            controller.retryRecording(at: recording.directory)
                            if controller.phase == .idle { retryingRecording = false }
                        }
                        .buttonStyle(PillButtonStyleHub())
                        .disabled(controller.phase != .idle || selectedRecovery?.readable != true)
                        Button("Show file") { showSelectedRecovery() }
                            .buttonStyle(PillButtonStyleHub(kind: .secondary))
                            .disabled(selectedRecoveryURL == nil)
                        Spacer()
                        Button("Discard…") { showDiscard = true }
                            .buttonStyle(PillButtonStyleHub(kind: .ghost, small: true))
                            .disabled(controller.phase != .idle)
                    }
                }
                .alert("Discard saved recordings?", isPresented: $showDiscard) {
                    Button("Keep recordings", role: .cancel) {}
                    Button("Discard all", role: .destructive) { controller.discardRecovery() }
                } message: { Text("This removes all \(controller.recoveryRecordingURLs.count) saved recordings waiting to be transcribed.") }
            }
            if let notice = controller.providerNotice {
                HubCard {
                    Text("Connection needs attention").font(.hub(14, .semibold)).foregroundColor(Hub.ink)
                    Text(notice).font(.hub(12)).foregroundColor(Hub.helper).textSelection(.enabled)
                    if settings.usesHostedService {
                        Button("Retry connection") {
                            controller.retryProviders()
                            Task { await hostedService.refresh() }
                        }.buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                            .disabled(controller.phase != .idle)
                    } else {
                        Button("Open connection settings") { ui.tab = .advanced }
                            .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                    }
                }
            }
            if let error = history.persistenceError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.hub(12)).foregroundColor(Hub.amber).textSelection(.enabled)
            }
            HStack {
                Text("Recent dictations").font(.hub(15, .semibold)).foregroundColor(Hub.ink)
                Spacer()
                Button("Dictionary") { ui.tab = .dictionary }.buttonStyle(PillButtonStyleHub(kind: .ghost, small: true))
                Button("View all") { ui.tab = .history }.buttonStyle(PillButtonStyleHub(kind: .ghost, small: true))
                    .disabled(history.items.isEmpty)
            }
            if history.items.isEmpty {
                Text(settings.saveHistory ? "Your recent dictations will appear here." : "History is off. Your dictations won’t be saved here.")
                    .font(.hub(13)).foregroundColor(Hub.helper).padding(.vertical, 18)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(history.items.suffix(3).reversed())) { item in TranscriptCard(item: item, compact: true) }
                }
            }
        }
        .onAppear { refreshReady(); refreshRecoveryChoices() }
        .onReceive(refresh) { _ in refreshReady() }
        .onChange(of: controller.recoveryRecordingURLs) { _, _ in refreshRecoveryChoices() }
        .onChange(of: controller.phase) { _, phase in
            if phase == .idle || phase == .recording { retryingRecording = false }
        }
    }

    private var updateStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Text("Version \(AppUpdater.installedVersion)")
                    .font(.hub(12, .medium)).foregroundColor(Hub.helper)
                    .accessibilityIdentifier("home-installed-version")
                Spacer(minLength: 0)
                if updater.updateReady {
                    Button("Restart to update") { updater.restartToUpdate() }
                        .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                        .disabled(!updater.canRestartToUpdate)
                } else {
                    Button("Check for updates") { updater.checkForUpdates() }
                        .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                        .disabled(!updater.canCheckForUpdates)
                }
            }
            Text(updater.statusText)
                .font(.hub(12)).foregroundColor(Hub.helper)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = updater.actionUnavailableReason {
                Text(reason).font(.hub(12)).foregroundColor(Hub.helper)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
    }

    private var selectedRecovery: RecoveryChoice? {
        recoveryChoices.first { $0.directory == selectedRecoveryURL }
    }

    private func refreshRecoveryChoices() {
        recoveryChoices = controller.recoveryRecordingURLs.map(RecoveryChoice.init)
        if !recoveryChoices.contains(where: { $0.directory == selectedRecoveryURL }) {
            selectedRecoveryURL = (recoveryChoices.first(where: \.readable) ?? recoveryChoices.first)?.directory
        }
    }

    private func showSelectedRecovery() {
        guard let recording = selectedRecovery else { return }
        let audio = recording.directory.appendingPathComponent("audio.pcm")
        let file = FileManager.default.fileExists(atPath: audio.path) ? audio : recording.directory
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    private var recovering: Bool {
        retryingRecording || controller.overlay.statusDetail.localizedCaseInsensitiveContains("recover")
    }

    private var activityTitle: String {
        switch controller.phase {
        case .idle:
            switch readiness {
            case .ready: return "Ready"
            case .permissions: return "Permission needed"
            case .shortcut: return "Shortcut needs attention"
            case .setup: return "Setup incomplete"
            case .connection: return "Connection unavailable"
            }
        case .recording: return "Listening"
        case .finishing: return recovering ? "Recovering recording" : "Transcribing"
        case .processing: return "Finishing your text"
        }
    }

    private var activityHeading: String {
        switch controller.phase {
        case .idle:
            switch readiness {
            case .ready: return "Ready"
            case .permissions: return "Allow access to continue."
            case .shortcut: return "Reconnect your shortcut."
            case .setup: return "Finish your setup."
            case .connection: return "Let’s restore your connection."
            }
        case .recording: return controller.translating ? "Speak to translate." : "Go ahead, I’m listening."
        case .finishing: return recovering ? "Picking up where you left off." : "Turning speech into text."
        case .processing: return "Getting your words ready."
        }
    }

    private var activityHint: String {
        switch controller.phase {
        case .idle:
            switch readiness {
            case .ready: return "Press again to finish. Esc to cancel."
            case .permissions: return "Check the required macOS permissions."
            case .shortcut: return "Check that macOS is allowing your dictation shortcut."
            case .setup: return "Continue your microphone, shortcut and practice checks."
            case .connection: return "Your setup is saved. Retry the connection below; setup does not need to be repeated."
            }
        case .recording: return "Press \(settings.triggerKey.shortName) to finish. Esc to cancel."
        case .finishing: return recovering ? "Resuming your saved audio. Esc stops the retry and keeps the recording." : "Your recording is saved while it’s transcribed. Esc to cancel."
        case .processing: return "Finishing punctuation and cleanup. Esc to cancel."
        }
    }

    private func refreshReady() {
        readiness = .evaluate(completedSetup: settings.hasCompletedSetup,
                              permissionsReady: Permissions.accessibilityGranted && Permissions.microphoneStatus == .authorized,
                              shortcutReady: hotkey.isRunning, connectionReady: connectionIsConfigured(settings))
    }
}

/// Recovery metadata is loaded only when the pending-file list changes, never for waveform ticks.
private struct RecoveryChoice: Identifiable {
    let directory: URL
    let date: Date?
    let seconds: Double?
    let readable: Bool
    var id: URL { directory }

    init(directory: URL) {
        self.directory = directory
        let audio = directory.appendingPathComponent("audio.pcm")
        if FileManager.default.isReadableFile(atPath: audio.path),
           let archive = try? RecordingArchive(directory: directory), archive.manifest.byteCount > 0 {
            date = archive.manifest.created
            seconds = archive.seconds
            readable = true
        } else {
            date = try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate
            seconds = nil
            readable = false
        }
    }

    var title: String {
        let timestamp = date?.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()) ?? "Date unavailable"
        guard readable, let seconds else { return "Unreadable recording · \(timestamp)" }
        let duration: String
        if seconds < 60 { duration = String(format: "%.1f s", seconds) }
        else {
            let total = Int(seconds)
            duration = total >= 3600
                ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                : String(format: "%d:%02d", total / 60, total % 60)
        }
        return "\(timestamp) · \(duration)"
    }
}

struct PreferencesPage: View {
    @ObservedObject var controller: DictationController
    let hotkey: HotkeyMonitor
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var history: History
    @EnvironmentObject var ui: UIState
    @ObservedObject private var updater = AppUpdater.shared
    @State private var showLanguages = false
    @State private var showRewritePrompt = false
    @State private var moreOptions = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError = ""
    @State private var clearHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Preferences", subtitle: "A few things to make dictation yours.")
            HubCard {
                ShortcutSettings()
                Divider().padding(.vertical, 4)
                SettingRow(title: "Languages", help: "Dictate in any language you select.") {
                    Button { showLanguages = true } label: {
                        HStack(spacing: 8) {
                            Text(languageSummary(settings.dictationLanguages)).lineLimit(1).truncationMode(.tail)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }.frame(maxWidth: 280, alignment: .trailing)
                    }.buttonStyle(.plain).foregroundColor(Hub.green)
                }
                Divider().padding(.vertical, 4)
                SettingRow(title: "Rewrite", help: settings.dictationMode.rewriteHelp) {
                    Picker("Rewrite amount", selection: $settings.dictationMode) {
                        Text("Full rewrite").tag(DictationMode.rewrite)
                        Text("Light rewrite").tag(DictationMode.clean)
                        Text("No rewrite").tag(DictationMode.verbatim)
                        if settings.dictationMode == .light {
                            Text("Basic cleanup (local)").tag(DictationMode.light)
                        }
                    }.labelsHidden().frame(width: 190)
                }
                RewriteExample(mode: settings.dictationMode)
                HStack {
                    Text("Shape the wording used by Full rewrite.")
                        .font(.hub(12)).foregroundColor(Hub.helper)
                    Spacer()
                    Button("Edit rewrite prompt…") { showRewritePrompt = true }
                        .buttonStyle(PillButtonStyleHub(kind: .ghost, small: true))
                        .accessibilityIdentifier("edit-rewrite-prompt")
                        .accessibilityHint("Edit and save the instructions used by Full rewrite")
                }
                Divider().padding(.vertical, 4)
                SettingRow(title: "Sound", help: "A soft cue when recording starts and stops.") {
                    HStack(spacing: 10) {
                        Button { Sounds.previewMinimalPair() } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.plain).foregroundColor(Hub.green)
                            .help("Preview start and stop sounds").accessibilityLabel("Preview start and stop sounds")
                        Picker("Sound", selection: $settings.playSounds) {
                            Text("Minimal").tag(true)
                            Text("Silent").tag(false)
                        }.labelsHidden().frame(width: 140)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    if moreOptions { controller.stopMicTest() }
                    moreOptions.toggle()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: moreOptions ? "chevron.down" : "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 14)
                        Text("More options").font(.hub(14, .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(Hub.ink)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Hub.radius).fill(Hub.card))
                    .overlay(RoundedRectangle(cornerRadius: Hub.radius).strokeBorder(Hub.line2).allowsHitTesting(false))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More options")
                .accessibilityValue(moreOptions ? "Expanded" : "Collapsed")
                .accessibilityHint("Show or hide additional preferences")
                if moreOptions {
                    VStack(alignment: .leading, spacing: 18) {
                        HubCard { ConnectionSettings(controller: controller) }
                        HubCard {
                            CardTitle(text: "Microphone")
                            SettingRow(title: "Input") {
                                Picker("Microphone", selection: $settings.micPreference) {
                                    Text("System default").tag(MicPreference.systemDefault)
                                    Text("Built-in microphone").tag(MicPreference.builtIn)
                                }.labelsHidden().frame(width: 230)
                                .onChange(of: settings.micPreference) { _, _ in
                                    if controller.micTesting { controller.stopMicTest(); controller.startMicTest() }
                                }
                            }
                            HStack {
                                if controller.micTesting { LevelMeter(level: controller.micTestLevel) }
                                else { Text("Check that Expertise Dictation can hear you.").font(.hub(12)).foregroundColor(Hub.helper) }
                                Spacer()
                                Button(controller.micTesting ? "Stop test" : "Test microphone") {
                                    controller.micTesting ? controller.stopMicTest() : controller.startMicTest()
                                }.buttonStyle(PillButtonStyleHub(kind: .secondary, small: true)).disabled(controller.phase != .idle)
                            }
                        }
                        HubCard {
                            CardTitle(text: "Privacy and history")
                            Text(settings.usesHostedService
                                ? "Audio and text pass through our free service to OpenAI. Our service does not store recordings or transcripts. Saved history and recovery recordings stay on this Mac."
                                : "Audio is sent to your transcription provider. Text is sent for cleanup. Saved history and recovery recordings stay on this Mac.")
                                .font(.hub(12)).foregroundColor(Hub.helper)
                            SettingRow(title: "Save dictation history", help: "Turning this off keeps existing entries until you clear them.") {
                                Toggle("Save dictation history", isOn: $settings.saveHistory).hubSwitch()
                            }
                            Button("Clear saved history…") { clearHistory = true }
                                .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true)).disabled(history.items.isEmpty)
                        }
                        HubCard {
                            SettingRow(title: "Launch at login", help: "Keep Expertise Dictation ready after you sign in to your Mac.") {
                                Toggle("Launch at login", isOn: $launchAtLogin).hubSwitch()
                                    .onChange(of: launchAtLogin) { _, on in
                                        do { try LaunchAtLogin.set(on); loginError = "" }
                                        catch { launchAtLogin = LaunchAtLogin.isEnabled; loginError = error.localizedDescription }
                                    }
                            }
                            if !loginError.isEmpty { Text(loginError).font(.hub(12)).foregroundColor(Hub.flag) }
                        }
                        HubCard {
                            CardTitle(text: "Translation")
                            SettingRow(title: "Double-press Fn to translate", help: "When Fn is your shortcut, press it twice quickly to start translation.") {
                                Toggle("Double-press Fn to translate", isOn: $settings.doubleTapTranslates).hubSwitch()
                            }
                            SettingRow(title: "Translate into", help: "Used by double-Fn and Start Translation in the menu bar.") {
                                Picker("Translation language", selection: $settings.translationLanguage) {
                                    ForEach(TranslationLanguage.all) { Text($0.name).tag($0.code) }
                                }.labelsHidden().frame(width: 190)
                            }
                            if settings.triggerKey == .fn && settings.doubleTapTranslates {
                                Text("Once you are speaking, press Fn once to finish. Hold the second press and release to finish instead.")
                                    .font(.hub(12)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
                                Text("If Apple Dictation also opens, change its shortcut in macOS Keyboard settings.")
                                    .font(.hub(12)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("Choose Fn as your shortcut and enable double-press to use this gesture. You can also start translation from the menu bar and press \(settings.triggerKey.shortName) to finish.")
                                    .font(.hub(12)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        HStack {
                            Button("Check setup") {
                                NotificationCenter.default.post(name: .fnDictateShowOnboarding, object: nil)
                            }.buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                            Spacer()
                            Text("Expertise Dictation \(AppDelegate.version)").font(.hub(12)).foregroundColor(Hub.helper)
                        }
                        HubCard {
                            CardTitle(text: "Speed", subtitle: "Shorter wait after you release the key, without changing what the meaning guard allows.")
                            SettingRow(title: "Type clean transcripts at once", help: "Skips the model when nothing needs removing: no fillers, repeats, commands or spelled addresses.") {
                                Toggle("Type clean transcripts at once", isOn: $settings.skipLLMWhenClean).hubSwitch()
                            }
                            SettingRow(title: "Short cleanup prompt", help: "Same rules in fewer words, so the model answers sooner.") {
                                Toggle("Short cleanup prompt", isOn: $settings.compactPrompt).hubSwitch()
                            }
                            SettingRow(title: "Full rewrite: skip the second check when nothing was rephrased", help: "The meaning check still runs whenever the rewrite adds, replaces or reorders words.") {
                                Toggle("Skip the second check when nothing was rephrased", isOn: $settings.skipVerifierWhenVerbatim).hubSwitch()
                            }
                            if !settings.usesHostedService {
                            SettingRow(title: "OpenAI priority processing", help: "Requests a faster paid tier from your OpenAI account when available.") {
                                Toggle("OpenAI priority processing", isOn: $settings.openAIPriorityTier).hubSwitch()
                            }
                            }
                        }
                        HubCard {
                            CardTitle(text: "Updates")
                            SettingRow(title: "Check for updates automatically") {
                                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                                    .hubSwitch().disabled(!updater.isConfigured)
                            }
                            SettingRow(title: "Download and install automatically", help: "Restarts after 15 seconds of idle time, with dictation finished and this window closed.") {
                                Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloadsUpdates)
                                    .hubSwitch().disabled(!updater.isConfigured || !updater.automaticallyChecksForUpdates)
                            }
                            Text(updater.statusText).font(.hub(12)).foregroundColor(Hub.helper)
                                .fixedSize(horizontal: false, vertical: true)
                            if let reason = updater.actionUnavailableReason {
                                Text(reason).font(.hub(12)).foregroundColor(Hub.helper)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack(spacing: 10) {
                                if updater.updateReady {
                                    Button("Restart to update") { updater.restartToUpdate() }
                                        .buttonStyle(PillButtonStyleHub(kind: .primary, small: true))
                                        .disabled(!updater.canRestartToUpdate)
                                }
                                Button("Check for updates…") { updater.checkForUpdates() }
                                    .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                                    .disabled(!updater.canCheckForUpdates)
                            }
                        }
                    }.padding(.top, 14)
                }
            }
            .font(.hub(13, .medium)).tint(Hub.green)
        }
        .sheet(isPresented: $showLanguages) { LanguagePickerView().environmentObject(settings) }
        .sheet(isPresented: $showRewritePrompt) { RewritePromptEditor(settings: settings) }
        .alert("Clear saved history?", isPresented: $clearHistory) {
            Button("Keep history", role: .cancel) {}
            Button("Clear history", role: .destructive) { history.clear() }
        } message: { Text("This removes all saved dictation text from this Mac.") }
        .onAppear { moreOptions = ui.tab == .advanced || ui.tab == .transcription; launchAtLogin = LaunchAtLogin.isEnabled }
        .onDisappear { controller.stopMicTest() }
    }
}

private struct RewriteExample: View {
    let mode: DictationMode
    private var example: String {
        switch mode {
        case .rewrite: return "I may send the draft tomorrow. Please check the numbers first."
        case .clean: return "I may send the draft tomorrow, and please check the numbers first."
        case .verbatim, .light: return "Um I may send the draft tomorrow and please check the numbers first."
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Example").font(.hub(11, .semibold)).foregroundColor(Hub.helper)
            Text(example).font(.hub(13)).foregroundColor(Hub.ink)
            Text(mode == .verbatim ? "Keeps the transcription as received, including the transcriber's punctuation."
                 : "Keeps “may” and “tomorrow” — your meaning stays yours.")
                .font(.hub(11)).foregroundColor(Hub.helper)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Hub.cream))
    }
}

struct RewritePromptEditor: View {
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RewritePromptDraft
    @FocusState private var promptFocused: Bool

    init(settings: Settings) {
        self.settings = settings
        _draft = State(initialValue: RewritePromptDraft(savedOverride: settings.rewritePromptOverride))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rewrite prompt").font(.hub(22, .semibold)).foregroundColor(Hub.ink)
            Text("Edit how Full rewrite phrases and structures your words. Save before your next dictation.")
                .font(.hub(13)).foregroundColor(Hub.helper)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $draft.text)
                .font(.system(size: 13, design: .monospaced))
                .focused($promptFocused)
                .accessibilityLabel("Rewrite prompt instructions")
                .accessibilityIdentifier("rewrite-prompt-editor")
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Hub.radius).fill(Hub.card))
                .overlay(RoundedRectangle(cornerRadius: Hub.radius).strokeBorder(Hub.field).allowsHitTesting(false))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("Your language choices and dictionary stay current. Meaning, numbers and email addresses are still checked.")
                .font(.hub(12)).foregroundColor(Hub.helper)
                .fixedSize(horizontal: false, vertical: true)
            Button("View all public prompt files") {
                if let url = Bundle.main.resourceURL?.appendingPathComponent("prompts") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(PillButtonStyleHub(kind: .ghost, small: true))
            .accessibilityIdentifier("view-public-prompts")
            if !draft.canSave {
                Text("Enter instructions or restore the default prompt.")
                    .font(.hub(12)).foregroundColor(Hub.amber)
            }
            HStack(spacing: 10) {
                Button("Restore default") { draft.restoreDefault() }
                    .buttonStyle(PillButtonStyleHub(kind: .ghost, small: true))
                    .accessibilityIdentifier("rewrite-prompt-restore")
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("rewrite-prompt-cancel")
                Button("Save") {
                    if draft.save(to: settings) { dismiss() }
                }
                .buttonStyle(PillButtonStyleHub(small: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canSave)
                .accessibilityIdentifier("rewrite-prompt-save")
            }
        }
        .padding(24)
        .frame(width: 660, height: 560)
        .background(Hub.cream)
        .onAppear { promptFocused = true }
    }
}

struct ShortcutSettings: View {
    @EnvironmentObject var settings: Settings
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(title: "Shortcut", help: "Press to start. Press again to finish.") {
                Picker("Dictation shortcut", selection: $settings.triggerKey) {
                    ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.menu).frame(width: 290)
            }
            if settings.triggerKey == .fn && settings.doubleTapTranslates {
                Text("Double-press Fn quickly to translate into \(TranslationLanguage.find(settings.translationLanguage).name).")
                    .font(.hub(12)).foregroundColor(Hub.helper)
            }
            Text("Recording finishes automatically after 12 seconds of silence.")
                .font(.hub(12)).foregroundColor(Hub.helper)
            FnConflictNotice()
        }
    }
}

struct FnConflictNotice: View {
    @EnvironmentObject var settings: Settings
    @State private var fnAction = Permissions.systemFnAction
    @State private var showGuide = false
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    var body: some View {
        Group {
            if settings.triggerKey == .fn {
                VStack(alignment: .leading, spacing: 8) {
                    if fnAction != 0 {
                        Text("Check Keyboard settings: set “Press Fn / 🌐 key to” to “Do Nothing” so the key is free for dictation.")
                            .font(.hub(12)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
                    }
                    Button { showGuide.toggle() } label: {
                        HStack {
                            Image(systemName: showGuide ? "chevron.down" : "chevron.right")
                            Text("Fn setup guide")
                            Spacer()
                        }.font(.hub(13, .medium)).foregroundColor(Hub.green)
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if showGuide { SetupGuideView(kind: .fnKey) }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Hub.greenSoft))
            }
        }
        .onReceive(refresh) { _ in fnAction = Permissions.systemFnAction }
    }
}

struct LanguagePickerView: View {
    @EnvironmentObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [String] = []
    @State private var search = ""
    @State private var chineseVariant = ChineseVariant.simplified

    private var filteredLanguages: [DictationLanguage] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return DictationLanguage.all.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) ||
                $0.englishName.localizedCaseInsensitiveContains(query) || $0.code.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Languages you speak", subtitle: "Choose one or more. Dictation keeps the language you speak.")
            TextField("Search languages", text: $search).hubField().accessibilityLabel("Search languages")
            Text(selected.isEmpty ? "Choose at least one language." : languageSummary(selected))
                .font(.hub(12)).foregroundColor(selected.isEmpty ? Hub.amber : Hub.helper)
                .lineLimit(2)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filteredLanguages.isEmpty {
                        Text("No languages match your search.")
                            .font(.hub(13)).foregroundColor(Hub.helper).padding(.vertical, 14)
                    }
                    ForEach(filteredLanguages, id: \.code) { language in
                        Toggle(language.name, isOn: Binding(
                            get: { selected.contains(language.code) },
                            set: { isOn in
                                if isOn { if !selected.contains(language.code) { selected.append(language.code) } }
                                else { selected.removeAll { $0 == language.code } }
                            }
                        ))
                        .toggleStyle(.checkbox).tint(Hub.green).font(.hub(14))
                        .padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.horizontal, 3)
            }
            .frame(height: 240)
            if selected.contains(where: { $0.hasPrefix("zh") || $0 == "yue" }) {
                SettingRow(title: "Chinese writing") {
                    Picker("Chinese writing", selection: $chineseVariant) {
                        ForEach(ChineseVariant.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 190)
                }
            }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(PillButtonStyleHub(kind: .secondary)).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Done") {
                    guard !selected.isEmpty else { return }
                    settings.dictationLanguages = selected
                    settings.chineseVariant = chineseVariant
                    dismiss()
                }.buttonStyle(PillButtonStyleHub()).disabled(selected.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 500).background(Hub.cream)
        .onAppear { selected = settings.dictationLanguages; chineseVariant = settings.chineseVariant }
    }
}

struct ConnectionSettings: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var service = HostedService.shared
    @EnvironmentObject var settings: Settings
    private var otherAccounts: [String] {
        Array(Set([settings.sttEngine.keychainAccount, settings.cleanupModel.keychainAccount])).filter { $0 != "openai" }.sorted()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(text: "Connection")
            if settings.offersHostedService {
                Picker("Connection", selection: $settings.usesHostedService) {
                    Text("Free service").tag(true)
                    Text("Use my own API key").tag(false)
                }.pickerStyle(.segmented)
            } else {
                Text("Use your own API key")
                    .font(.hub(15, .medium)).foregroundColor(Hub.ink)
                Text("Add an OpenAI API key below and choose Save. This release connects directly to your provider, which bills usage to your account.")
                    .font(.hub(13)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
            }
            if settings.usesHostedService {
                Text(service.state.message).font(.hub(13)).foregroundColor(Hub.helper)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Uses OpenAI for transcription and GPT-6 Luna for rewriting and translation. Usage limits keep the free beta available to everyone.")
                    .font(.hub(12)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
                Button("Check connection") { Task { await service.refresh() } }
                    .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
            } else {
            SettingRow(title: "Text model", help: "Used for cleanup, Full rewrite and translation.") {
                Picker("Text model", selection: $settings.cleanupModel) {
                    ForEach(CleanupModel.allCases) { Text($0.shortTitle).tag($0) }
                }
                .labelsHidden().frame(width: 230)
                .accessibilityIdentifier("cleanup-model-picker")
            }
            if settings.cleanupModel == .auto {
                Text("Auto uses Claude Sonnet 5 with an Anthropic key; otherwise GPT-6 Luna with your OpenAI key.")
                    .font(.hub(12)).foregroundColor(Hub.helper)
                    .fixedSize(horizontal: false, vertical: true)
            }
            KeyField(account: "openai", title: "OpenAI", help: "Audio and text are sent to OpenAI when you dictate.", required: true, controller: controller)
            ForEach(otherAccounts, id: \.self) { account in
                KeyField(account: account, title: account == "anthropic" ? "Anthropic" : "AssemblyAI",
                         help: "Used by your existing connection.", required: true, controller: controller)
            }
            }
        }
        .task { if settings.usesHostedService { await service.refresh() } }
    }
}

struct TranscriptCard: View {
    let item: HistoryItem
    var compact = false
    @State private var copied = false
    var body: some View {
        HubCard(padding: 16) {
            Text(item.text).font(.hub(14)).foregroundColor(Hub.ink)
                .lineLimit(compact ? 3 : nil).textSelection(.enabled)
            HStack(spacing: 8) {
                Text(item.date, style: .date)
                Text(item.date, style: .time)
                if let app = item.app, !app.isEmpty { Text("· \(app)").lineLimit(1) }
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }.buttonStyle(PillButtonStyleHub(kind: .ghost, small: true))
            }.font(.hub(11)).foregroundColor(Hub.helper)
        }
    }
}

struct HistoryPage: View {
    @EnvironmentObject var history: History
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "History", subtitle: "Your saved dictations on this Mac.")
            if let error = history.persistenceError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.hub(12)).foregroundColor(Hub.amber).textSelection(.enabled)
            }
            TextField("Search dictations", text: $search).hubField().accessibilityLabel("Search dictations")
            let items = history.items.reversed().filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }
            if items.isEmpty {
                Text(search.isEmpty ? "No saved dictations yet." : "No dictations match your search.")
                    .font(.hub(13)).foregroundColor(Hub.helper).padding(.vertical, 24)
            }
            ForEach(items) { item in TranscriptCard(item: item) }
        }
    }
}

/// API keys stay as a draft until Save or Return. Verification is an explicit network action.
struct KeyField: View {
    let account: String
    let title: String
    let help: String
    let required: Bool
    @ObservedObject var controller: DictationController
    @EnvironmentObject var settings: Settings
    @State private var text = ""
    @State private var reveal = false
    @State private var status = ""
    @State private var statusOK = false
    @State private var verifying = false
    @State private var savedValue = ""
    @State private var updateDraft = InlineUpdateDraft()
    @State private var loaded = false
    @FocusState private var keyFocused: Bool

    private var draftChanged: Bool { Keychain.sanitize(text) != savedValue }
    private var draftBinding: Binding<String> {
        Binding(get: { text }, set: { value in
            text = value
            updateDraft.setUnsaved(Keychain.sanitize(value) != savedValue)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.hub(13, .semibold)).foregroundColor(Hub.ink)
                if required && savedValue.isEmpty {
                    Text("Required").font(.hub(11)).foregroundColor(Hub.amber)
                }
                Spacer()
                if draftChanged { Text("Unsaved changes").font(.hub(11)).foregroundColor(Hub.amber) }
            }
            Group {
                if reveal {
                    TextField("Paste your \(title) key", text: draftBinding).focused($keyFocused)
                } else {
                    SecureField("Paste your \(title) key", text: draftBinding).focused($keyFocused)
                }
            }
            .hubField()
            .accessibilityLabel("\(title) API key")
            .onSubmit { commit(verify: false) }
            HStack(spacing: 8) {
                Button(reveal ? "Hide" : "Show") {
                    reveal.toggle()
                    DispatchQueue.main.async { keyFocused = true }
                }.buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                Button("Paste") {
                    if let value = NSPasteboard.general.string(forType: .string), !Keychain.sanitize(value).isEmpty {
                        draftBinding.wrappedValue = Keychain.sanitize(value)
                        keyFocused = true
                        status = ""
                    } else {
                        status = "The clipboard has no text on it"
                        statusOK = false
                    }
                }.buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                Spacer()
                Button(text.isEmpty && !savedValue.isEmpty ? "Remove key" : "Save") { commit(verify: false) }
                    .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                    .disabled(!draftChanged || verifying)
                Button(verifying ? "Verifying…" : "Verify") { commit(verify: true) }
                    .buttonStyle(PillButtonStyleHub(small: true))
                    .disabled(verifying || Keychain.sanitize(text).count < 16)
            }
            Text(help).font(.hub(12)).foregroundColor(Hub.helper).fixedSize(horizontal: false, vertical: true)
            if !status.isEmpty {
                Text(status).font(.hub(12)).foregroundColor(statusOK ? Hub.green : Hub.flag)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            if !loaded {
                let existing = Keychain.get(account) ?? ""
                text = existing
                savedValue = existing
                loaded = true
                if !existing.isEmpty { status = "Saved · ends with \(existing.suffix(4))"; statusOK = true }
            }
            updateDraft.setUnsaved(draftChanged)
        }
    }

    private func commit(verify: Bool) {
        // Failed validation or Keychain writes must retain restart protection.
        defer { updateDraft.setUnsaved(draftChanged) }
        let clean = Keychain.sanitize(text)
        text = clean
        guard clean.isEmpty || clean.count >= 16 else {
            status = "That is too short to be an API key"
            statusOK = false
            return
        }
        if clean != savedValue {
            guard Keychain.set(account, clean) else {
                status = "Could not save the key"
                statusOK = false
                return
            }
            savedValue = clean
            status = clean.isEmpty ? "Key removed" : "Saved · ends with \(clean.suffix(4))"
            statusOK = true
            controller.retryProviders()
        }
        if verify && !clean.isEmpty { runVerify(clean) }
    }

    private func runVerify(_ key: String) {
        verifying = true
        status = "Checking with \(title)…"
        statusOK = true
        Task { @MainActor in
            let result = await KeyVerifier.verify(account: account, key: key, settings: settings)
            // An in-flight request must not label a subsequently edited draft as verified.
            if Keychain.sanitize(text) == key {
                switch result {
                case .success(let message):
                    status = "\(message) · ends with \(key.suffix(4))"
                    statusOK = true
                    controller.retryProviders()
                case .failure(let error):
                    status = error.localizedDescription
                    statusOK = false
                }
            }
            verifying = false
        }
    }
}


struct DictionaryPage: View {
    @EnvironmentObject var settings: Settings
    @State private var rules: [Replacement] = []
    @State private var newSpoken = ""
    @State private var newWritten = ""
    @State private var loaded = false
    @State private var updateDraft = InlineUpdateDraft()
    @FocusState private var wordsFocused: Bool

    private var rulesBinding: Binding<[Replacement]> {
        Binding(get: { rules }, set: { value in replaceRules(value) })
    }

    private var newSpokenBinding: Binding<String> {
        Binding(get: { newSpoken }, set: { value in
            newSpoken = value
            refreshDraftProtection()
        })
    }

    private var newWrittenBinding: Binding<String> {
        Binding(get: { newWritten }, set: { value in
            newWritten = value
            refreshDraftProtection()
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Dictionary", subtitle: "Names, specialist terms and your preferred spellings.")
            HubCard {
                CardTitle(text: "When I say… type…",
                          subtitle: "Choose the spelling to use when you say a phrase.")
                if rules.isEmpty {
                    Text("For example, “chat simple” → “ChatSimple”.")
                        .font(.hub(12)).foregroundColor(Hub.helper)
                }
                ForEach(rulesBinding) { $rule in
                    HStack(spacing: 8) {
                        TextField("when I say", text: $rule.spoken).hubField()
                            .accessibilityLabel("Spoken phrase")
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundColor(Hub.helper)
                        TextField("type", text: $rule.written).hubField()
                            .accessibilityLabel("Written replacement")
                        Button {
                            replaceRules(rules.filter { $0.id != rule.id })
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(PillButtonStyleHub(kind: .secondary, small: true))
                        .help("Remove")
                        .accessibilityLabel("Remove replacement for \(rule.spoken)")
                    }
                }
                if duplicateSpokenPhrase != nil {
                    Text("Each spoken phrase must be unique. Fix the duplicate before these edits can be saved.")
                        .font(.hub(12)).foregroundColor(Hub.amber)
                }
                HStack(spacing: 8) {
                    TextField("when I say…", text: newSpokenBinding).hubField()
                        .accessibilityLabel("New spoken phrase")
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundColor(Hub.helper)
                    TextField("type…", text: newWrittenBinding).hubField()
                        .accessibilityLabel("New written replacement")
                    Button("Add") { addRule() }
                        .buttonStyle(PillButtonStyleHub(small: true))
                        .disabled(newSpoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newWritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newSpokenAlreadyUsed)
                }
                if newSpokenAlreadyUsed {
                    Text("This phrase already has a replacement. Edit the existing rule above.")
                        .font(.hub(12)).foregroundColor(Hub.amber)
                }
            }
            HubCard {
                CardTitle(text: "Words to recognise", subtitle: "Add names, products and specialist terms, one per line.")
                TextEditor(text: $settings.dictionaryText)
                    .accessibilityLabel("Words to recognise")
                    .focused($wordsFocused)
                    .font(.hub(14))
                    .frame(height: 180)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: Hub.radius).fill(Hub.card))
                    .overlay(RoundedRectangle(cornerRadius: Hub.radius).strokeBorder(Hub.field).allowsHitTesting(false))
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { wordsFocused = true })
                Text("\(settings.dictionaryTerms.count) terms").font(.hub(12)).foregroundColor(Hub.helper)
            }
        }
        .onAppear {
            if !loaded {
                rules = settings.replacements
                loaded = true
            }
            refreshDraftProtection()
        }
    }

    private func replaceRules(_ value: [Replacement]) {
        rules = value
        if loaded && duplicateSpokenPhrase == nil {
            settings.replacementsText = Replacements.serialize(value.filter { !$0.spoken.isEmpty && !$0.written.isEmpty })
        }
        refreshDraftProtection()
    }

    private func refreshDraftProtection() {
        let incompleteRule = rules.contains { $0.spoken.isEmpty != $0.written.isEmpty }
        updateDraft.setUnsaved(!newSpoken.isEmpty || !newWritten.isEmpty || duplicateSpokenPhrase != nil || incompleteRule)
    }

    private var newSpokenAlreadyUsed: Bool {
        let phrase = newSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
        return !phrase.isEmpty && rules.contains {
            $0.spoken.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(phrase) == .orderedSame
        }
    }

    private var duplicateSpokenPhrase: String? {
        var seen = Set<String>()
        for rule in rules {
            let phrase = rule.spoken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !phrase.isEmpty && !seen.insert(phrase).inserted { return phrase }
        }
        return nil
    }

    private func addRule() {
        let spoken = newSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = newWritten.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty, !written.isEmpty, !newSpokenAlreadyUsed else { return }
        replaceRules(rules + [Replacement(spoken: spoken, written: written)])
        newSpoken = ""
        newWritten = ""
        refreshDraftProtection()
    }
}
