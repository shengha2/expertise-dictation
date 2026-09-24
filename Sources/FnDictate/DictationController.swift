import Foundation
import AppKit
import Combine

struct SessionTimings {
    var keyDown = Date()
    var audioStarted: Date?
    var firstPartial: Date?
    var keyUp: Date?
    var transcript: Date?
    var cleaned: Date?
    var inserted: Date?

    private func ms(_ a: Date?, _ b: Date?) -> String {
        guard let a, let b else { return "–" }
        return "\(Int(b.timeIntervalSince(a) * 1000))ms"
    }

    var summary: String {
        "hold=\(ms(keyDown, keyUp)) audioStart=\(ms(keyDown, audioStarted)) firstPartial=\(ms(keyDown, firstPartial)) " +
        "release→transcript=\(ms(keyUp, transcript)) cleanup=\(ms(transcript, cleaned)) insert=\(ms(cleaned, inserted)) release→typed=\(ms(keyUp, inserted))"
    }

    var releaseToTypedMs: Int {
        guard let keyUp, let inserted else { return 0 }
        return Int(inserted.timeIntervalSince(keyUp) * 1000)
    }
}

/// The dictation state machine: hold → listen → release → transcribe → clean → insert.
final class DictationController: ObservableObject {
    enum Phase: String { case idle, recording, finishing, processing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastInserted: String?
    @Published private(set) var lastRaw: String?
    @Published private(set) var lastError: String?
    @Published private(set) var handsFree = false
    @Published private(set) var statusLine = "Ready"
    @Published private(set) var micTestLevel: Float = 0
    @Published private(set) var micTesting = false
    @Published private(set) var recordingSeconds: Double = 0
    @Published private(set) var recoveryAvailable = false
    @Published private(set) var recoveryMessage: String?
    @Published private(set) var recoveryRecordingURLs: [URL] = []
    @Published private(set) var successfulInsertionCount = 0

    let settings = Settings.shared
    let audio = AudioCapture()
    let overlay = OverlayModel()
    lazy var panel = OverlayPanel(model: overlay)
    weak var hotkey: HotkeyMonitor?

    /// When true, nothing is typed into other apps (used by --simulate and the settings test).
    var dryRun = false
    /// When true, a mock transcriber is used instead of the network.
    var useMockSTT = false

    private let sessionFactory: (() throws -> STTSession)?
    private let soundPlayer: (Sounds.Kind) -> Void
    private let doubleTapEnabled: (() -> Bool)?
    private let cleanupClient: LLMClient?
    private let rewritePromptReader: (() -> String)?
    private let recoveryRoot: URL
    private let recoveryFactory: ((URL) throws -> DurableSTTSession)?
    private let targetReader: () -> InsertionTarget
    private let insertionTargetReader: (() -> InsertionTarget)?
    private let targetEnricher: ((InsertionTarget) -> InsertionTarget)?
    private let initialApplicationReader: () -> InsertionTarget
    private let targetCaptureWaitTimeout: TimeInterval
    private let insertionHandler: ((String, InsertionTarget, Bool) throws -> String)?
    private let clipboardWriter: (String) -> Bool
    private var pendingCopyRecording: DurableSTTSession?
    private var pendingCopyRequiresRecovery = false
    private var session: STTSession?
    private var warm: STTSession?
    private var warmConfiguration: [String]?
    private var activeDryRun = false
    private var activeRecording: DurableSTTSession?
    private var recordingTimer: Timer?
    private var processingTask: Task<Void, Never>?
    private var runID = UUID()
    private let captureHeartbeat = CaptureHeartbeat()
    private let silenceMonitor = AudioSilenceMonitor()
    private var startCuePlayed = false
    private var preserveRecovery = false
    private var replayingSavedRecording = false
    private var activeTranslationLanguage: String?
    private var activeMode: DictationMode = .clean
    private var activeRewritePromptOverride = ""
    private var timings = SessionTimings()
    private var pressedAt: Date?
    private var pressedAtUptime: TimeInterval?
    private var triggerHeld = false
    private var partial = ""
    private var target = InsertionTarget()
    private var targetCapturePending = false
    private var maxTimer: Timer?
    private var startSound: DispatchWorkItem?
    private var resetWork: DispatchWorkItem?
    private var warmTimer: Timer?
    private var warmBlockedUntil: Date?
    private var fnTranslationGesture = FnTranslationGesture()
    private var secondPressPending = false
    /// Only bounds gesture diagnostics; it never controls recording or shortcut behavior.
    private var fnDiagnosticDeadline: TimeInterval?
    @Published private(set) var translating = false
    /// Last message from the transcription/clean-up provider (billing, key, quota), shown in the hub.
    @Published private(set) var providerNotice: String?

    init(sessionFactory: (() throws -> STTSession)? = nil, soundPlayer: @escaping (Sounds.Kind) -> Void = { Sounds.play($0) },
         doubleTapEnabled: (() -> Bool)? = nil, cleanupClient: LLMClient? = nil, rewritePromptReader: (() -> String)? = nil,
         recoveryRoot: URL = RecordingArchive.root, recoveryFactory: ((URL) throws -> DurableSTTSession)? = nil,
         targetReader: (() -> InsertionTarget)? = nil,
         initialApplicationReader: @escaping () -> InsertionTarget = {
             let app = NSWorkspace.shared.frontmostApplication
             var target = InsertionTarget()
             target.processIdentifier = app?.processIdentifier
             target.bundleID = app?.bundleIdentifier
             target.appName = app?.localizedName
             return target
         },
         targetCaptureWaitTimeout: TimeInterval = 1,
         insertionHandler: ((String, InsertionTarget, Bool) throws -> String)? = nil,
         clipboardWriter: @escaping (String) -> Bool = { text in
             NSPasteboard.general.clearContents()
             return NSPasteboard.general.setString(text, forType: .string)
         }) {
        self.sessionFactory = sessionFactory
        self.soundPlayer = soundPlayer
        self.doubleTapEnabled = doubleTapEnabled
        self.cleanupClient = cleanupClient
        self.rewritePromptReader = rewritePromptReader
        self.recoveryRoot = recoveryRoot
        self.recoveryFactory = recoveryFactory
        self.targetReader = targetReader ?? TextInserter.captureRecordingTarget
        self.insertionTargetReader = targetReader
        self.targetEnricher = targetReader == nil ? TextInserter.enrichTarget : nil
        self.initialApplicationReader = initialApplicationReader
        self.targetCaptureWaitTimeout = max(0, min(1, targetCaptureWaitTimeout))
        self.insertionHandler = insertionHandler
        self.clipboardWriter = clipboardWriter
        refreshRecovery()
        warmTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.warmUp() }
        overlay.showHandle = settings.showIdleHandle
        overlay.onTap = { [weak self] in self?.overlayTapped() }
        overlay.onDismiss = { [weak self] in self?.dismissError() }
        overlay.onStop = { [weak self] in self?.finish() }
        overlay.onCancel = { [weak self] in self?.cancel(reason: "Cancel") }
        overlay.onRetry = { [weak self] in self?.retryLastRecording() }
        overlay.onPrimaryAction = { [weak self] in
            self?.dismissError()
            NotificationCenter.default.post(name: .fnDictateOpenSettings, object: nil)
        }
        overlay.onPickLanguage = { [weak self] in self?.pickLanguage() }
        overlay.targetLanguage = TranslationLanguage.find(settings.translationLanguage).native
        overlay.onCopy = { [weak self] in
            guard let self, case .result(let text) = self.overlay.state else { return }
            guard self.clipboardWriter(text) else {
                self.overlay.copied = false
                self.overlay.statusDetail = "The clipboard is unavailable. Select the text to copy it manually, or try Copy again."
                self.statusLine = "Text ready — Copy did not finish"
                return
            }
            self.overlay.copied = true
            self.statusLine = "Copied to the clipboard"
            // Copy acknowledges receipt, but a provider/capture failure still needs its
            // original audio. Keep the preview until an explicit dismissal/new recording.
            if !self.pendingCopyRequiresRecovery {
                self.pendingCopyRecording?.discardRecording()
                self.pendingCopyRecording = nil
                self.refreshRecovery()
                self.overlay.canRetry = self.recoveryAvailable
            }
            self.resetWork?.cancel()
            self.resetWork = nil
        }
    }

    // MARK: - Translation

    private func enterTranslationMode() {
        translating = true
        LLMWarmup.prewarm(settings: settings)
        activeTranslationLanguage = settings.translationLanguage
        activeRecording?.configureRecovery(mode: activeMode.rawValue, translationTarget: settings.translationLanguage)
        overlay.translating = true
        overlay.targetLanguage = TranslationLanguage.find(settings.translationLanguage).native
        statusLine = "Listening — translating to \(overlay.targetLanguage)"
        Log.info("Translation mode (target \(settings.translationLanguage))")
    }

    func startTranslation(target: String? = nil) {
        guard phase == .idle else { return }
        if let target { setTranslationLanguage(target) }
        start(mode: .clean)
        guard phase == .recording else { return }
        handsFree = true
        overlay.handsFree = true
        enterTranslationMode()
    }

    private func refreshRecovery() {
        recoveryRecordingURLs = RecordingArchive.pending(root: recoveryRoot)
        recoveryAvailable = !recoveryRecordingURLs.isEmpty
        recoveryMessage = recoveryAvailable ? "\(recoveryRecordingURLs.count) saved recording\(recoveryRecordingURLs.count == 1 ? "" : "s") available to retry" : nil
    }

    func revealRecovery() { NSWorkspace.shared.open(recoveryRoot) }

    func discardRecovery() {
        guard phase == .idle else { return }
        var skipped = false
        for url in recoveryRecordingURLs {
            do { try RecordingArchive.discardPending(url) }
            catch { skipped = true }
        }
        refreshRecovery()
        if skipped { statusLine = "Recordings still in use were kept" }
    }

    func retryLastRecording() {
        guard phase == .idle else { return }
        refreshRecovery()
        guard let directory = recoveryRecordingURLs.first else { return }
        retryRecording(at: directory)
    }

    func retryRecording(at directory: URL) {
        guard phase == .idle, recoveryRecordingURLs.contains(directory) else { return }
        do {
            let saved = try recoveryFactory?(directory) ?? STTFactory.recover(directory: directory, settings: settings)
            let metadata = try RecordingArchive(directory: directory).manifest
            runID = UUID()
            timings = SessionTimings()
            timings.keyUp = Date()
            activeMode = metadata.mode.flatMap(DictationMode.init(rawValue:)) ?? settings.dictationMode
            activeRewritePromptOverride = rewritePromptReader?() ?? settings.rewritePromptOverride
            activeDryRun = dryRun
            preserveRecovery = false
            replayingSavedRecording = true
            translating = metadata.translationTarget != nil
            activeTranslationLanguage = metadata.translationTarget
            lastError = nil
            targetCapturePending = false
            target = targetReader()
            // Retry from our own Home/Settings controls produces a copyable result. It must
            // never re-use a previously focused editor or type into a saved-key settings field.
            if target.processIdentifier == ProcessInfo.processInfo.processIdentifier { target = InsertionTarget() }
            phase = .finishing
            hotkey?.wantsKeyDowns = true
            resetWork?.cancel()
            session = saved
            activeRecording = saved
            attachSession(saved)
            overlay.state = .transcribing
            overlay.statusDetail = "Recovering saved recording…"
            panel.present()
            saved.connect()
        } catch { fail(error.localizedDescription) }
    }

    func setTranslationLanguage(_ code: String) {
        settings.translationLanguage = code
        overlay.targetLanguage = TranslationLanguage.find(code).native
        if translating {
            activeTranslationLanguage = code
            activeRecording?.configureRecovery(mode: activeMode.rawValue, translationTarget: code)
            statusLine = "Listening — translating to \(overlay.targetLanguage)"
        }
    }

    /// Dropdown on the bar: a native menu popped at the mouse, usable from the non-activating panel.
    private func pickLanguage() {
        let menu = NSMenu()
        for lang in TranslationLanguage.all {
            let item = NSMenuItem(title: "\(lang.native)  ·  \(lang.name)", action: #selector(languageChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.code
            item.state = lang.code == settings.translationLanguage ? .on : .off
            menu.addItem(item)
        }
        let location = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: NSPoint(x: location.x - 8, y: location.y + 8), in: nil)
    }

    @objc private func languageChosen(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { setTranslationLanguage(code) }
    }

    /// Completed text remains available until the user copies/dismisses it or starts again.
    /// Merely changing fields must not replace an unrelated clipboard value.
    private func showResultCard(_ text: String, reason: String = "Copy your text and paste it where you want.",
                                recording: DurableSTTSession? = nil, requiresRecovery: Bool = false) {
        pendingCopyRecording = recording
        pendingCopyRequiresRecovery = requiresRecovery
        overlay.copied = false
        overlay.statusDetail = reason
        overlay.resultWarning = requiresRecovery ? (lastError ?? "The recording is saved for retry.") : ""
        statusLine = "Text ready to copy"
        showBrief(.result(text: text), sound: nil)
    }

    /// Show the idle handle once the app is up.
    func showHandle() {
        overlay.showHandle = settings.showIdleHandle
        overlay.hotkeyActive = hotkey?.isRunning ?? false
        if settings.showIdleHandle { panel.present() } else if phase == .idle { panel.dismiss() }
    }

    private func overlayTapped() {
        if case .error = overlay.state {
            dismissError()
            return
        }
        if case .result = overlay.state { return }   // the card has its own buttons; a stray click keeps it
        switch phase {
        case .idle:
            start(mode: settings.dictationMode)
            guard phase == .recording else { return }
            handsFree = true
            overlay.handsFree = true
            statusLine = "Listening (hands-free) — click the bar or tap \(settings.triggerKey.shortName) to finish"
        case .recording:
            finish()
        default:
            break
        }
    }

    private func dismissError() {
        resetWork?.cancel()
        lastError = nil
        statusLine = "Ready"
        reset()
    }

    // MARK: - Hotkey handling

    /// Returns true when the key event should be swallowed.
    func handleHotkey(_ event: HotkeyEvent, timestamp: TimeInterval? = nil) -> Bool {
        let intercept = settings.interceptTrigger
        let now = timestamp ?? hotkey?.eventTimestamp ?? ProcessInfo.processInfo.systemUptime
        let canDoubleTap = doubleTapEnabled?() ?? settings.doubleTapTranslates
        switch event {
        case .triggerDown(.fn), .triggerUp(.fn):
            let direction = event == .triggerDown(.fn) ? "down" : "up"
            Log.shortcut("Fn shortcut \(direction) t=\(String(format: "%.3f", now)) phase=\(phase.rawValue) handsFree=\(handsFree) translating=\(translating) doubleTap=\(canDoubleTap) secondPending=\(secondPressPending)")
        default: break
        }
        switch event {
        case .triggerDown(let key):
            switch phase {
            case .idle:
                if key == .fn { fnDiagnosticDeadline = now + settings.holdThreshold + FnTranslationGesture.interval }
                triggerHeld = true
                pressedAt = Date()
                pressedAtUptime = now
                let mode: DictationMode = (key == settings.secondaryTrigger.triggerKey && key != settings.triggerKey) ? .verbatim : settings.dictationMode
                let startedAt = ProcessInfo.processInfo.systemUptime
                start(mode: mode)
                if key == .fn { Log.shortcut("Fn shortcut startup ms=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)) phase=\(phase.rawValue)") }
                if phase == .recording { fnTranslationGesture.beginIdlePress(key, at: now, enabled: canDoubleTap) }
                return intercept
            case .recording:
                if handsFree {
                    if fnTranslationGesture.consumeSecondPress(key, at: now, enabled: canDoubleTap) {
                        if key == .fn { Log.shortcut("Fn shortcut second press accepted; promoting existing capture to translation") }
                        fnDiagnosticDeadline = nil
                        triggerHeld = true
                        pressedAt = Date()
                        pressedAtUptime = now
                        secondPressPending = true
                        enterTranslationMode()
                    } else {
                        if key == .fn {
                            let reason = !canDoubleTap ? "preference disabled" : (fnDiagnosticDeadline.map { now > $0 } == true ? "double-press window expired" : "gesture not armed or already consumed")
                            Log.shortcut("Fn shortcut second press rejected: \(reason); finishing current capture")
                            fnDiagnosticDeadline = nil
                        }
                        finish()
                    }
                } else {
                    triggerHeld = true
                }
                return intercept
            case .finishing, .processing:
                return intercept
            }
        case .triggerUp(let key):
            let wasHeld = triggerHeld
            triggerHeld = false
            guard phase == .recording, wasHeld else { return intercept && phase != .idle }
            let held = max(0, now - (pressedAtUptime ?? now))
            if key == .fn { Log.shortcut("Fn shortcut release held=\(String(format: "%.3f", held)) holdThreshold=\(settings.holdThreshold) tapToggle=\(settings.tapTogglesHandsFree)") }
            if secondPressPending {
                // Double-tap-and-hold = push-to-talk translation; a plain double-tap stays hands-free.
                secondPressPending = false
                if held >= settings.holdThreshold {
                    if key == .fn { Log.shortcut("Fn shortcut translation second release classified as hold; finishing") }
                    finish()
                } else if key == .fn { Log.shortcut("Fn shortcut translation second release stays hands-free") }
                return intercept
            }
            if held < settings.holdThreshold && settings.tapTogglesHandsFree {
                fnTranslationGesture.releaseFirstTap(key, at: now, holdThreshold: settings.holdThreshold)
                if key == .fn {
                    fnDiagnosticDeadline = now + FnTranslationGesture.interval
                    Log.shortcut("Fn shortcut first release classified as tap; waiting for optional second press")
                }
                handsFree = true
                overlay.handsFree = true
                statusLine = "Listening (hands-free) — tap \(settings.triggerKey.shortName) to finish"
                return intercept
            }
            if key == .fn { Log.shortcut("Fn shortcut first release classified as hold; finishing") }
            finish()
            return intercept
        case .monitorInterrupted:
            fnTranslationGesture.reset()
            guard phase != .idle else { return false }
            runID = UUID()
            fail("Recording interrupted because macOS temporarily disabled the keyboard monitor")
            return false
        case .escape:
            fnTranslationGesture.reset()
            if overlay.state.isCard {
                dismissError()
                return true
            }
            if phase == .recording || phase == .finishing || phase == .processing {
                cancel(reason: "Esc")
                return true
            }
            return false
        case .otherKeyDown:
            if let deadline = fnDiagnosticDeadline, now <= deadline {
                Log.shortcut("Fn shortcut pending gesture reset by another key event")
            }
            fnDiagnosticDeadline = nil
            fnTranslationGesture.reset()
            // Trigger key used as a modifier (Fn+Delete, Fn+arrow…): this was not a dictation.
            if phase == .recording && triggerHeld && (!handsFree || secondPressPending) {
                cancel(reason: "key chord")
            }
            return false
        }
    }

    // MARK: - Session lifecycle

    private func makeSession() throws -> STTSession {
        if let sessionFactory { return try sessionFactory() }
        if useMockSTT { return MockSTTSession() }
        return try STTFactory.make(settings: settings)
    }

    /// Opens a transcription socket ahead of time so the first words are not lost to a handshake.
    /// Called when a key changes: forget any provider refusal and try again.
    func retryProviders() {
        warm?.cancel()
        warm = nil
        warmConfiguration = nil
        warmBlockedUntil = nil
        providerNotice = nil
        warmUp()
    }

    func warmUp() {
        guard phase == .idle else { return }
        if warmConfiguration != sessionConfiguration || !settings.keepConnectionWarm || useMockSTT || settings.usesHostedService {
            warm?.cancel()
            warm = nil
            warmConfiguration = nil
        }
        guard settings.keepConnectionWarm, settings.sttEngine != .assemblyAI, !useMockSTT, !settings.usesHostedService else { return }
        if let until = warmBlockedUntil, Date() < until { return }
        if let w = warm {
            if w.isUsable { return }
            w.cancel()
            warm = nil
        }
        guard Keychain.apiKey("openai") != nil else { return }
        do {
            let s = try makeSession()
            s.onFinal = { [weak self, weak s] result in
                guard let self, let s, self.warm === s else { return }
                if case .failure(let e) = result {
                    Log.info("Warm session ended (\(e.localizedDescription)); will reconnect on demand")
                    self.warm = nil
                    if case STTError.server(let msg) = e {
                        // The provider refused us (no credits, bad key…): stop hammering it and tell the user.
                        self.providerNotice = msg
                        self.warmBlockedUntil = Date().addingTimeInterval(10 * 60)
                    }
                }
            }
            s.connect()
            warm = s
            warmConfiguration = sessionConfiguration
        } catch {
            Log.warn("Could not warm up: \(error.localizedDescription)")
        }
    }

    private var sessionConfiguration: [String] {
        if settings.usesHostedService {
            return ["hosted", HostedService.baseURL ?? "", settings.chineseVariant.rawValue, settings.liveDelay.rawValue] + settings.keywordHints + settings.transcriptionLanguageCodes
        }
        return [settings.sttEngine.rawValue, settings.openAIBaseURL, settings.chineseVariant.rawValue,
         settings.liveDelay.rawValue, Keychain.apiKey(settings.sttEngine.keychainAccount) ?? ""] + settings.keywordHints + settings.transcriptionLanguageCodes
    }

    // MARK: - Microphone test (Setup page)

    func startMicTest() {
        guard !UITestEnvironment.active else { return }
        guard phase == .idle, !micTesting else { return }
        switch Permissions.microphoneStatus {
        case .authorized: break
        case .notDetermined:
            Permissions.requestMicrophone { [weak self] ok in if ok { self?.startMicTest() } }
            return
        default:
            Permissions.open(.microphone)
            return
        }
        audio.preferBuiltInMic = settings.micPreference == .builtIn
        audio.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.micTestLevel = level }
        }
        audio.onChunk = { _ in }
        audio.onError = { [weak self] error in
            self?.stopMicTest()
            self?.lastError = error.localizedDescription
        }
        do {
            try audio.start(sampleRate: 16000)
            micTesting = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopMicTest() {
        guard micTesting else { return }
        audio.stop(keepWarm: false)
        micTesting = false
        micTestLevel = 0
    }

    func start(mode: DictationMode, previewOnly: Bool = false) {
        guard phase == .idle else { return }
        stopMicTest()
        timings = SessionTimings()
        runID = UUID()
        captureHeartbeat.begin(runID)
        silenceMonitor.reset(sessionID: runID, now: ProcessInfo.processInfo.systemUptime)
        processingTask?.cancel()
        activeRecording = nil
        pendingCopyRecording = nil
        pendingCopyRequiresRecovery = false
        preserveRecovery = false
        replayingSavedRecording = false
        recordingSeconds = 0
        overlay.elapsedSeconds = 0
        overlay.statusDetail = ""
        overlay.resultWarning = ""
        startCuePlayed = false
        activeMode = mode
        if mode == .clean || mode == .rewrite { LLMWarmup.prewarm(settings: settings) }
        activeRewritePromptOverride = rewritePromptReader?() ?? settings.rewritePromptOverride
        activeDryRun = dryRun || previewOnly
        handsFree = false
        translating = false
        activeTranslationLanguage = nil
        overlay.translating = false
        fnTranslationGesture.reset()
        secondPressPending = false
        partial = ""
        lastError = nil
        let initialApplication = initialApplicationReader()
        target = InsertionTarget()
        target.processIdentifier = initialApplication.processIdentifier
        target.bundleID = initialApplication.bundleID
        target.appName = initialApplication.appName
        phase = .recording
        hotkey?.wantsKeyDowns = true
        resetWork?.cancel()
        // Begin the original field lookup before provider/microphone setup. A slow
        // Accessibility response must not delay capture or be lost on a quick Finish.
        beginTargetCapture()

        let session: STTSession
        if settings.keepConnectionWarm, warmConfiguration == sessionConfiguration, let w = warm, w.isUsable {
            session = w
            warm = nil
        } else {
            warm?.cancel()
            warm = nil
            do {
                session = try makeSession()
                session.connect()
            } catch {
                fail(error.localizedDescription)
                return
            }
        }
        self.session = session
        activeRecording = session as? DurableSTTSession
        activeRecording?.configureRecovery(mode: mode.rawValue, translationTarget: nil)
        attachSession(session)

        let overlay = self.overlay
        if useMockSTT {
            startMockAudio(session: session)
            timings.audioStarted = Date()
        } else {
            // Starting the engine before the microphone is authorised blocks on the system prompt,
            // so ask first and let the user try again once they have answered it.
            switch Permissions.microphoneStatus {
            case .authorized:
                break
            case .notDetermined:
                Permissions.requestMicrophone { _ in }
                fail("Allow the microphone, then try again")
                return
            default:
                Permissions.open(.microphone)
                fail("Microphone access is off for Expertise Typer — enable it in System Settings")
                return
            }
            audio.preferBuiltInMic = settings.micPreference == .builtIn
            audio.onLevel = { level in overlay.pushLevel(level) }
            let generation = runID
            let sampleRate = session.sampleRate
            audio.onChunk = { [weak self, weak session] chunk in
                self?.captureHeartbeat.mark(generation)
                self?.silenceMonitor.observe(pcm16: chunk, sampleRate: sampleRate, sessionID: generation, now: ProcessInfo.processInfo.systemUptime)
                session?.sendAudio(chunk)
                DispatchQueue.main.async {
                    guard let self, self.runID == generation, self.phase == .recording, !self.startCuePlayed else { return }
                    self.startCuePlayed = true
                    self.soundPlayer(.start)
                }
            }
            audio.onError = { [weak self] error in
                guard let self, self.runID == generation, self.phase == .recording else { return }
                self.fail(error.localizedDescription)
            }
            audio.onInterruption = { [weak self] message in
                guard let self, self.runID == generation, self.phase == .recording else { return }
                self.preserveRecovery = true
                self.lastError = message
                self.overlay.statusDetail = message
                self.statusLine = message
            }
            do {
                try audio.start(sampleRate: session.sampleRate)
                timings.audioStarted = Date()
            } catch {
                fail(error.localizedDescription)
                return
            }
        }

        overlay.showPreview = settings.showPreview
        overlay.modeLabel = mode == .rewrite ? "rewrite" : (mode == .clean ? "" : (mode == .light ? "light" : "verbatim"))
        overlay.accent = mode == .clean || mode == .rewrite ? OverlayModel.blue : OverlayModel.teal
        overlay.text = ""
        overlay.handsFree = false
        overlay.hotkeyActive = hotkey?.isRunning ?? false
        overlay.state = .listening
        overlay.startAnimating()
        panel.present()
        statusLine = "Listening…"

        recordingTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.phase == .recording else { return }
            self.recordingSeconds = self.activeRecording?.capturedSeconds ?? Date().timeIntervalSince(self.timings.audioStarted ?? self.timings.keyDown)
            self.overlay.elapsedSeconds = self.recordingSeconds
            self.checkCaptureHealth()
            self.checkSilence()
            guard self.phase == .recording else { return }
            let remaining = self.settings.maxDurationSeconds - self.recordingSeconds
            if remaining <= 60 { self.overlay.statusDetail = "Recording limit in \(max(0, Int(remaining))) seconds — audio is saved" }
        }
        recordingTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        maxTimer?.invalidate()
        maxTimer = Timer.scheduledTimer(withTimeInterval: settings.maxDurationSeconds, repeats: false) { [weak self] _ in
            Log.info("Maximum duration reached; finishing")
            self?.finish()
        }
        Log.info("Recording started (mode=\(mode.rawValue), engine=\(session.engineName), app=\(target.bundleID ?? "?"))")
    }

    private var acceptsTargetCapture: Bool {
        phase == .recording || phase == .finishing || phase == .processing
    }

    private func beginTargetCapture() {
        targetCapturePending = true
        let generation = runID
        let originalPID = target.processIdentifier
        let readTarget = targetReader
        let enrichTarget = targetEnricher
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let identity = readTarget()
            DispatchQueue.main.async {
                guard let self, self.runID == generation, self.targetCapturePending,
                      self.acceptsTargetCapture else { return }
                self.targetCapturePending = false
                guard let originalPID, identity.processIdentifier == originalPID else {
                    Log.info("Original insertion target unavailable: application changed during capture")
                    return
                }
                self.target = identity
            }
            // Publish identity before querying optional caret context. Enrichment reads
            // only that captured element; it must never choose a new focused field.
            guard let enrichTarget, identity.element != nil else { return }
            let enriched = enrichTarget(identity)
            DispatchQueue.main.async {
                guard let self, self.runID == generation, self.acceptsTargetCapture,
                      let originalPID, self.target.processIdentifier == originalPID,
                      enriched.processIdentifier == originalPID,
                      let acceptedElement = self.target.element, let enrichedElement = enriched.element,
                      CFEqual(acceptedElement, enrichedElement) else { return }
                self.target = enriched
            }
        }
    }

    @MainActor
    private func waitForInitialTarget(generation: UUID) async {
        let deadline = ProcessInfo.processInfo.systemUptime + targetCaptureWaitTimeout
        while targetCapturePending, runID == generation, phase == .processing, !Task.isCancelled,
              ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard runID == generation, phase == .processing, !Task.isCancelled, targetCapturePending else { return }
        // Freeze the unknown original target. A late AX reply cannot trigger a second
        // insertion or replace it with whatever field happens to be focused later.
        targetCapturePending = false
        Log.info("Original insertion target unavailable: initial capture timed out; retaining text for Copy")
    }

    func checkCaptureHealth(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard phase == .recording else { return }
        if !useMockSTT, Permissions.microphoneStatus != .authorized {
            fail("Microphone permission was removed. The captured portion is saved; further audio could not be recorded.")
        } else if captureHeartbeat.elapsed(for: runID, now: now) >= 5 {
            fail("Microphone audio stopped arriving. The captured portion is saved; audio after the interruption was not recorded.")
        }
    }

    func checkSilence(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard phase == .recording, silenceMonitor.shouldFinish(sessionID: runID, now: now) else { return }
        // Silence only requests provider finalization. Quiet speech already captured is
        // still transcribed, and a genuinely empty final takes the normal silent reset.
        Log.info("Finishing after 12 seconds without speech activity")
        finish()
    }

    private final class CaptureHeartbeat {
        private let lock = NSLock()
        private var generation = UUID()
        private var latest: TimeInterval = 0
        func begin(_ value: UUID) {
            lock.lock(); defer { lock.unlock() }
            generation = value
            latest = ProcessInfo.processInfo.systemUptime
        }
        func mark(_ value: UUID) {
            lock.lock(); defer { lock.unlock() }
            guard generation == value else { return }
            latest = ProcessInfo.processInfo.systemUptime
        }
        func elapsed(for value: UUID, now: TimeInterval) -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return generation == value ? max(0, now - latest) : 0
        }
    }

    private func gotPartial(_ text: String) {
        guard phase == .recording || phase == .finishing else { return }
        if timings.firstPartial == nil && !text.isEmpty { timings.firstPartial = Date() }
        silenceMonitor.noteTranscriptActivity(text, sessionID: runID, now: ProcessInfo.processInfo.systemUptime)
        partial = text
        overlay.text = text
    }

    private func attachSession(_ session: STTSession) {
        let generation = runID
        session.onPartial = { [weak self, weak session] text in
            guard let self, let session, self.runID == generation, self.session === session else { return }
            self.gotPartial(text)
        }
        session.onFinal = { [weak self, weak session] result in
            guard let self, let session, self.runID == generation, self.session === session else { return }
            self.gotFinal(result)
        }
        (session as? DurableSTTSession)?.onProgress = { [weak self, weak session] text in
            guard let self, let session, self.runID == generation, self.session === session else { return }
            self.statusLine = text
            self.overlay.statusDetail = text
        }
    }

    func finish() {
        guard phase == .recording, let session else { return }
        fnTranslationGesture.reset()
        phase = .finishing
        timings.keyUp = Date()
        hotkey?.wantsKeyDowns = true
        recordingTimer?.invalidate()
        maxTimer?.invalidate()
        startSound?.cancel()
        stopMockAudio()
        audio.stop(keepWarm: settings.keepMicWarm)
        overlay.stopAnimating()
        overlay.state = .transcribing
        statusLine = "Transcribing…"
        soundPlayer(.stop)
        session.finish()
    }

    func cancel(reason: String) {
        fnTranslationGesture.reset()
        guard phase == .recording || phase == .finishing || phase == .processing else { return }
        runID = UUID()
        targetCapturePending = false
        processingTask?.cancel()
        recordingTimer?.invalidate()
        Log.info("Recording cancelled (\(reason))")
        let longEnough = Date().timeIntervalSince(pressedAt ?? Date()) > 0.3
        startSound?.cancel()
        maxTimer?.invalidate()
        stopMockAudio()
        audio.stop(keepWarm: settings.keepMicWarm)
        session?.onFinal = nil
        session?.onPartial = nil
        session?.cancel()
        if replayingSavedRecording { activeRecording?.checkpointRecording() }
        else { activeRecording?.discardRecording() }
        refreshRecovery()
        activeRecording = nil
        session = nil
        overlay.stopAnimating()
        if longEnough { soundPlayer(.cancel) }
        reset()
    }

    private func gotFinal(_ result: Result<String, Error>) {
        if (phase == .recording || phase == .finishing), Self.isEmptyRecording(result) {
            finishSilently()
            return
        }
        switch phase {
        case .recording:
            if case .failure(let e) = result { fail(e.localizedDescription) }
        case .finishing:
            timings.transcript = Date()
            switch result {
            case .failure(let e):
                if case STTError.server(let msg) = e { providerNotice = msg }
                fail(e.localizedDescription)
            case .success(let raw):
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let generation = runID
                processingTask = Task { @MainActor in
                    guard self.runID == generation, self.phase == .finishing else { return }
                    await self.process(raw: text)
                }
            }
        default:
            break
        }
    }

    static func isEmptyRecording(_ result: Result<String, Error>) -> Bool {
        switch result {
        case .success(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .failure(let error):
            if case STTError.noAudio = error { return true }
            return false
        }
    }

    private func finishSilently() {
        maxTimer?.invalidate()
        startSound?.cancel()
        stopMockAudio()
        audio.stop(keepWarm: settings.keepMicWarm)
        session?.onFinal = nil
        session?.onPartial = nil
        session?.cancel()
        activeRecording?.discardRecording()
        activeRecording = nil
        refreshRecovery()
        session = nil
        overlay.stopAnimating()
        lastError = nil
        lastRaw = nil
        statusLine = "Ready"
        reset()
    }

    @MainActor
    private func process(raw: String) async {
        let generation = runID
        phase = .processing
        statusLine = "Cleaning up…"
        overlay.state = activeMode == .clean || activeMode == .rewrite ? .cleaning : .transcribing
        lastRaw = raw
        let mode = activeMode
        let cjk = settings.cjkSpacing
        var output: String
        var usedLLM = false
        var note = ""

        if translating {
            let target = TranslationLanguage.find(activeTranslationLanguage ?? settings.translationLanguage)
            do {
                let source = Replacements.apply(settings.replacements, to: raw)
                let (translated, modelName) = try await Translator.translate(source, to: target, settings: settings, timeout: max(settings.llmTimeout, 8))
                output = LocalCleanup.normalize(translated, cjkSpacing: cjk)
                usedLLM = true
                note = "translated to \(target.code) with \(modelName)"
                Log.info("Translation completed (\(target.code), \(output.count) characters)")
            } catch {
                guard runID == generation, !Task.isCancelled else { return }
                Log.warn("Translation failed (\(error.localizedDescription)); typing the original")
                output = LocalCleanup.normalize(raw, cjkSpacing: cjk)
                preserveRecovery = true
                note = "translation failed"
                lastError = error.localizedDescription
            }
        } else {
        switch mode {
        case .verbatim:
            output = raw
        case .light:
            output = LocalCleanup.light(raw, cjkSpacing: cjk)
        case .clean, .rewrite:
            if mode == .clean && settings.skipLLMForShort && LocalCleanup.isShort(raw)
                && !CleanupPolicy.hasExplicitEnumeration(raw) {
                output = LocalCleanup.light(raw, cjkSpacing: cjk)
                note = "short, no LLM"
            } else if mode == .clean, settings.skipLLMWhenClean,
                      !CleanupPolicy.decide(raw: raw, cjkSpacing: cjk, spokenCommands: settings.spokenCommands).needsModel {
                // Nothing for the model to fix: type the transcript as the transcriber punctuated it.
                output = LocalCleanup.light(raw, cjkSpacing: cjk)
                note = "already clean, no LLM"
            } else {
                var ctx = CleanupContext(precedingText: target.precedingText,
                                         dictionary: settings.dictionaryTerms,
                                         chineseVariant: settings.chineseVariant,
                                         allowFormatting: settings.allowFormatting,
                                         spokenCommands: settings.spokenCommands,
                                         cjkSpacing: cjk,
                                         customInstructions: settings.customInstructions,
                                         replacements: settings.replacements)
                ctx.rewriteStyle = mode == .rewrite ? .full : .light
                ctx.rewritePromptOverride = activeRewritePromptOverride
                ctx.compact = settings.compactPrompt && mode == .clean
                do {
                    let cleaned = try await LongTextProcessing.cleanup(raw, context: ctx, settings: settings, client: cleanupClient) { [weak self] index, count in
                        DispatchQueue.main.async {
                            guard let self, self.runID == generation, self.phase == .processing else { return }
                            self.statusLine = "Cleaning section \(index) of \(count)…"
                            self.overlay.statusDetail = self.statusLine
                        }
                    }
                    guard runID == generation, !Task.isCancelled else { return }
                    output = LocalCleanup.normalize(cleaned.text, cjkSpacing: cjk)
                    usedLLM = cleaned.usedLLM
                    note = "cleanup original sections=\(cleaned.guardFallbackCount) provider fallback sections=\(cleaned.providerFallbackCount)"
                    if cleaned.requiresRecovery {
                        preserveRecovery = true
                        lastError = cleaned.lastError
                    }
                } catch {
                    guard runID == generation, !Task.isCancelled else { return }
                    Log.warn("LLM clean-up failed (\(error.localizedDescription)); using local clean-up")
                    output = LocalCleanup.normalize(raw, cjkSpacing: cjk)
                    preserveRecovery = true
                    note = "LLM failed"
                    lastError = error.localizedDescription
                }
            }
        }
        }
        if !translating && mode != .verbatim { output = Replacements.apply(settings.replacements, to: output) }
        timings.cleaned = Date()
        guard phase == .processing, runID == generation, !Task.isCancelled else { return }
        if output.isEmpty {
            finishSilently()
            return
        }
        await waitForInitialTarget(generation: generation)
        guard phase == .processing, runID == generation, !Task.isCancelled else { return }
        var inserted = output
        var insertionError: String?
        var noTarget = false
        do {
            if let insertionHandler { inserted = try insertionHandler(output, target, activeDryRun) }
            else { inserted = try TextInserter.insert(output, method: settings.insertionMethod, smartSpacing: settings.smartSpacing && (translating || mode != .verbatim),
                                               restoreClipboard: settings.restoreClipboard, cjkSpacing: cjk,
                                               dryRun: activeDryRun, expectedTarget: target, targetReader: insertionTargetReader) }
        } catch InsertionError.noTarget {
            noTarget = true
        } catch InsertionError.targetChanged {
            insertionError = InsertionError.targetChanged.localizedDescription
        } catch {
            insertionError = error.localizedDescription
            if !preserveRecovery { lastError = error.localizedDescription }
        }
        if !activeDryRun, !noTarget, insertionError == nil { successfulInsertionCount += 1 }
        timings.inserted = Date()
        lastInserted = inserted
        let seconds = timings.keyUp.map { $0.timeIntervalSince(timings.keyDown) } ?? 0
        if settings.saveHistory && !activeDryRun {
            History.shared.append(HistoryItem(id: UUID().uuidString, date: Date(), raw: raw, text: inserted,
                                              mode: translating ? "translate→\(activeTranslationLanguage ?? settings.translationLanguage)" : mode.rawValue,
                                              engine: session?.engineName ?? "", app: target.appName, seconds: seconds,
                                              latencyMs: timings.releaseToTypedMs))
        }
        Log.info("Done: \(timings.summary) | mode=\(mode.rawValue) llm=\(usedLLM) \(note) chars=\(inserted.count)")
        if !preserveRecovery && !noTarget && insertionError == nil {
            activeRecording?.discardRecording()
        } else {
            activeRecording?.releaseRecoveryOwnership()
        }
        refreshRecovery()
        overlay.canRetry = recoveryAvailable
        if noTarget || insertionError != nil {
            let reason = insertionError ?? "No text field is selected. Copy your text and paste it where you want."
            showResultCard(inserted, reason: reason, recording: activeRecording, requiresRecovery: preserveRecovery)
        } else if preserveRecovery, let detail = lastError {
            let title = activeDryRun ? "Text ready — recording saved" : "Text sent — recording saved"
            statusLine = title
            showBrief(.error(title: title, message: detail + " The captured audio is saved for retry."), sound: nil)
        } else {
            statusLine = activeDryRun ? "Test complete — \(inserted.count) characters ready; nothing typed" : "Sent \(inserted.count) characters in \(timings.releaseToTypedMs) ms"
            showBrief(.success, sound: nil)
        }
    }

    private func fail(_ message: String) {
        Log.error("Dictation failed: \(message)")
        lastError = message
        recordingTimer?.invalidate()
        processingTask?.cancel()
        maxTimer?.invalidate()
        startSound?.cancel()
        stopMockAudio()
        audio.stop(keepWarm: settings.keepMicWarm)
        session?.onFinal = nil
        session?.cancel()
        activeRecording?.checkpointRecording()
        refreshRecovery()
        session = nil
        phase = .idle
        targetCapturePending = false
        overlay.stopAnimating()
        hotkey?.wantsKeyDowns = false
        let detail = recoveryAvailable ? message + " Your audio is saved. Use Retry to recover it." : message
        statusLine = detail
        overlay.canRetry = recoveryAvailable
        showBrief(.error(title: recoveryAvailable ? "Recording saved" : "Dictation failed", message: detail), sound: .error, duration: 6)
    }

    private func showBrief(_ state: OverlayState, sound: Sounds.Kind?, duration: TimeInterval = 0.7) {
        // A terminal card is immediately dismissible/retryable, regardless of which pipeline
        // stage produced it. Only the display timeout remains pending.
        session?.onFinal = nil
        session?.onPartial = nil
        session?.cancel()
        session = nil
        maxTimer?.invalidate()
        recordingTimer?.invalidate()
        startSound?.cancel()
        stopMockAudio()
        audio.stop(keepWarm: settings.keepMicWarm)
        overlay.stopAnimating()
        phase = .idle
        targetCapturePending = false
        triggerHeld = false
        handsFree = false
        hotkey?.wantsKeyDowns = state.isCard   // Esc dismisses a card
        overlay.state = state
        panel.present()
        if let sound { soundPlayer(sound) }
        resetWork?.cancel()
        resetWork = nil
        // Cards stay until Dismiss, Esc, Copy + a new dictation, or Settings.
        if state.isCard { return }
        let work = DispatchWorkItem { [weak self] in self?.reset() }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func reset() {
        resetWork?.cancel()
        targetCapturePending = false
        phase = .idle
        handsFree = false
        triggerHeld = false
        activeDryRun = false
        recordingTimer?.invalidate()
        session = nil
        overlay.state = .idle
        overlay.text = ""
        overlay.statusDetail = ""
        overlay.resultWarning = ""
        overlay.copied = false
        pendingCopyRecording = nil
        pendingCopyRequiresRecovery = false
        overlay.elapsedSeconds = 0
        overlay.canRetry = false
        overlay.handsFree = false
        overlay.translating = false
        translating = false
        fnTranslationGesture.reset()
        secondPressPending = false
        overlay.hotkeyActive = hotkey?.isRunning ?? false
        if settings.showIdleHandle { panel.present() } else { panel.dismiss() }
        hotkey?.wantsKeyDowns = false
        if statusLine.hasPrefix("Listening") || statusLine.hasPrefix("Transcribing") || statusLine.hasPrefix("Cleaning") { statusLine = "Ready" }
        warmUp()
    }

    func handleSystemSleep() {
        guard phase != .idle else { return }
        runID = UUID()
        processingTask?.cancel()
        fail("Recording interrupted because the Mac went to sleep")
    }

    func handleAppTermination() {
        runID = UUID()
        processingTask?.cancel()
        recordingTimer?.invalidate()
        maxTimer?.invalidate()
        audio.stop(keepWarm: false)
        session?.cancel()
        activeRecording?.checkpointRecording()
        warm?.cancel()
    }

    // MARK: - Mock audio (simulation)

    private var mockTimer: Timer?

    private func startMockAudio(session: STTSession) {
        mockTimer?.invalidate()
        let overlay = self.overlay
        var t: Double = 0
        let generation = runID
        let sampleRate = session.sampleRate
        mockTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self, weak session] _ in
            self?.captureHeartbeat.mark(generation)
            t += 0.05
            overlay.pushLevel(Float(0.35 + 0.35 * sin(t * 7)))
            let chunk = Data(count: Int(sampleRate * 0.05) * 2)
            self?.silenceMonitor.observe(pcm16: chunk, sampleRate: sampleRate, sessionID: generation, now: ProcessInfo.processInfo.systemUptime)
            session?.sendAudio(chunk)
        }
    }

    private func stopMockAudio() {
        mockTimer?.invalidate()
        mockTimer = nil
    }

    // MARK: - Tests from the settings window

    /// Records for `seconds`, runs the normal pipeline, but does not type anything.
    func runTest(seconds: Double) {
        guard phase == .idle else { return }
        start(mode: settings.dictationMode, previewOnly: true)
        let generation = runID
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.runID == generation else { return }
            self.finish()
        }
    }

    func repeatLastInsert() {
        guard phase == .idle else { return }
        guard let text = lastInserted ?? History.shared.last?.text else { return }
        do {
            try TextInserter.insert(text, method: settings.insertionMethod, smartSpacing: settings.smartSpacing,
                                   restoreClipboard: settings.restoreClipboard, cjkSpacing: settings.cjkSpacing, dryRun: false)
        } catch InsertionError.noTarget {
            showResultCard(text)
        } catch InsertionError.targetChanged {
            showResultCard(text, reason: InsertionError.targetChanged.localizedDescription)
        } catch {
            lastError = error.localizedDescription
            showResultCard(text, reason: error.localizedDescription)
        }
    }
}
