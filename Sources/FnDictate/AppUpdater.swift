import AppKit
import Combine
import Sparkle

struct UpdateRelaunchGate {
    struct DeferredInstall {
        fileprivate let generation: UInt64
        fileprivate let handler: () -> Void
    }

    var recordingBusy = false
    private(set) var installationStarted = false
    private var generation: UInt64 = 0
    private var pending: DeferredInstall?
    private var queuedGeneration: UInt64?
    var hasPendingInstall: Bool { pending != nil || queuedGeneration != nil }

    mutating func markInstallationStarted() { installationStarted = true }
    mutating func postponeIfBusy(_ install: @escaping () -> Void) -> Bool {
        // A new installation request supersedes callbacks from an earlier request.
        generation &+= 1
        pending = nil
        queuedGeneration = nil
        installationStarted = true
        guard recordingBusy else { return false }
        pending = DeferredInstall(generation: generation, handler: install)
        return true
    }
    mutating func takeReadyInstall() -> DeferredInstall? {
        guard !recordingBusy, let pending else { return nil }
        self.pending = nil
        queuedGeneration = pending.generation
        return pending
    }
    mutating func prepareQueuedInstall(_ install: DeferredInstall) -> (() -> Void)? {
        guard install.generation == generation, queuedGeneration == generation else { return nil }
        queuedGeneration = nil
        if recordingBusy {
            pending = install
            return nil
        }
        return install.handler
    }
    mutating func cancel() {
        generation &+= 1
        pending = nil
        queuedGeneration = nil
        installationStarted = false
    }
}

/// Pure state for the staged-install callback. No Sparkle object or preferences are
/// needed to test queue races, opt-out, status preservation and the idle interval.
struct StagedUpdateState {
    enum Phase { case idle, checking, available, downloading, downloaded, ready, installing, upToDate, finished, cancelled, failed }
    enum Intent { case automatic, user }
    enum Outcome { case completed, upToDate, cancelled, failed }
    struct InstallTicket {
        fileprivate let generation: UInt64
        fileprivate let intent: Intent
    }

    static let idleDelay: TimeInterval = 15
    private(set) var phase: Phase = .idle
    private(set) var version: String?
    private(set) var failureDescription: String?
    private(set) var automaticInstallEnabled = false
    private(set) var dictationBusy = false
    private(set) var presentationBusy = false
    private(set) var settingsVisible = false
    private(set) var settingsEditing = false
    private(set) var intent: Intent?
    private var generation: UInt64 = 0
    private var handler: (() -> Void)?
    private var queued = false
    private var inFlight = false
    private var idleSince: TimeInterval?

    var hasStagedInstall: Bool { handler != nil }
    var hasQueuedInstall: Bool { queued }
    var hasProtectedWork: Bool { dictationBusy || presentationBusy || settingsEditing }
    var canRestart: Bool { handler != nil && !inFlight && !hasProtectedWork }
    var canRequestExplicitRelaunch: Bool { inFlight && !hasProtectedWork }
    var canRelaunchNow: Bool {
        !hasProtectedWork && (intent == .user || (!settingsVisible && automaticInstallEnabled))
    }

    mutating func setAutomaticInstallEnabled(_ enabled: Bool, now: TimeInterval) {
        if automaticInstallEnabled != enabled { idleSince = nil }
        automaticInstallEnabled = enabled
        updateIdle(now: now)
    }

    mutating func setContext(dictationBusy: Bool, presentationBusy: Bool, settingsVisible: Bool,
                             settingsEditing: Bool, now: TimeInterval) {
        self.dictationBusy = dictationBusy
        self.presentationBusy = presentationBusy
        self.settingsVisible = settingsVisible
        self.settingsEditing = settingsEditing
        updateIdle(now: now)
    }

    private mutating func updateIdle(now: TimeInterval) {
        if hasProtectedWork || settingsVisible || !automaticInstallEnabled {
            idleSince = nil
        } else if idleSince == nil {
            idleSince = now
        }
    }

    func canResumeRelaunch(now: TimeInterval) -> Bool {
        guard canRelaunchNow else { return false }
        return intent == .user || idleSince.map { now - $0 >= Self.idleDelay } == true
    }

    mutating func beginCheck() {
        guard handler == nil, !inFlight else { return }
        failureDescription = nil
        phase = .checking
        version = nil
    }
    mutating func found(version: String) {
        guard handler == nil, !inFlight else { return }
        self.version = version
        phase = .available
    }
    mutating func downloading(version: String) {
        guard handler == nil, !inFlight else { return }
        self.version = version
        phase = .downloading
    }
    mutating func downloaded(version: String) {
        guard handler == nil, !inFlight else { return }
        self.version = version
        phase = .downloaded
    }
    mutating func stage(version: String, now: TimeInterval, handler: @escaping () -> Void) {
        generation &+= 1
        queued = false
        inFlight = false
        intent = nil
        self.version = version
        self.handler = handler
        failureDescription = nil
        phase = .ready
        idleSince = nil
        updateIdle(now: now)
    }

    private func eligible(_ intent: Intent, now: TimeInterval) -> Bool {
        guard !hasProtectedWork else { return false }
        if intent == .user { return true }
        return automaticInstallEnabled && !settingsVisible && idleSince.map { now - $0 >= Self.idleDelay } == true
    }
    mutating func takeInstallation(now: TimeInterval, userInitiated: Bool = false) -> InstallTicket? {
        updateIdle(now: now)
        let intent: Intent = userInitiated ? .user : .automatic
        guard handler != nil, !queued, !inFlight, eligible(intent, now: now) else { return nil }
        queued = true
        return InstallTicket(generation: generation, intent: intent)
    }
    mutating func prepareInstallation(_ ticket: InstallTicket, now: TimeInterval) -> (() -> Void)? {
        guard generation == ticket.generation, queued else { return nil }
        queued = false
        guard eligible(ticket.intent, now: now), let handler else { return nil }
        inFlight = true
        intent = ticket.intent
        phase = .installing
        return handler
    }
    mutating func requestExplicitRelaunch() -> Bool {
        guard canRequestExplicitRelaunch else { return false }
        intent = .user
        return true
    }
    mutating func willInstall(version: String) {
        self.version = version
        // An install not initiated by our idle gate was explicitly accepted in Sparkle's UI.
        if intent == nil { intent = .user }
        inFlight = true
        phase = .installing
    }
    mutating func terminationCancelled(now: TimeInterval) {
        // Sparkle documents that its staged handler may be invoked again after a
        // canceled termination. A fresh idle interval prevents immediate retry loops.
        generation &+= 1
        queued = false
        inFlight = false
        intent = nil
        phase = handler == nil ? .cancelled : .ready
        idleSince = nil
        updateIdle(now: now)
    }
    mutating func finish(_ outcome: Outcome, errorDescription: String? = nil) {
        if outcome == .completed {
            // A completed check can mean available, downloaded, staged or dismissed.
            // It is not proof that an installation succeeded, nor that no update exists.
            if phase == .checking || phase == .idle { phase = .finished }
            return
        }
        generation &+= 1
        queued = false
        inFlight = false
        handler = nil
        intent = nil
        switch outcome {
        case .completed: break
        case .upToDate: phase = .upToDate; version = nil; failureDescription = nil
        case .cancelled: phase = .cancelled; failureDescription = nil
        case .failed:
            phase = .failed
            failureDescription = errorDescription.map { String($0.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(300)) }
        }
    }

    var statusText: String {
        let release = version.map { "Version \($0)" } ?? "The update"
        switch phase {
        case .idle: return "Updates are checked securely in the background."
        case .checking: return "Checking for updates…"
        case .available: return "\(release) is available. Choose Check for updates to download it."
        case .downloading: return "Downloading \(version.map { "version " + $0 } ?? "the update")…"
        case .downloaded: return "\(release) is downloaded. Preparing installation…"
        case .ready:
            if dictationBusy { return "\(release) is ready. Finish dictation before restarting to update." }
            if presentationBusy { return "\(release) is ready. Finish with your result or recovery controls before restarting." }
            if settingsEditing { return "\(release) is ready. Finish editing before restarting to update." }
            if settingsVisible && automaticInstallEnabled {
                return "\(release) is ready. Restart to update, or close this window to install after a short idle period."
            }
            if automaticInstallEnabled { return "\(release) is ready. It will install after 15 seconds of idle time." }
            return "\(release) is ready. Restart to update when you are ready."
        case .installing: return "Installing \(version.map { "version " + $0 } ?? "the update")…"
        case .upToDate: return "You're up to date."
        case .finished: return "Update check completed."
        case .cancelled: return "\(release) installation was canceled. You can check again when ready."
        case .failed:
            let detail = failureDescription.map { " " + $0 } ?? " The update could not complete."
            return "\(version.map { "Update to version " + $0 } ?? "Update check") failed.\(detail) You can try Check for updates again."
        }
    }
}

/// Sparkle owns transport, verification and installation. This adapter retains
/// its staged callback and only requests an automatic restart during safe idle.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    @Published private(set) var isConfigured = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var canRestartToUpdate = false
    @Published private(set) var updateReady = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var statusText = "Automatic updates are not configured for this build."
    @Published var automaticallyChecksForUpdates = false {
        didSet {
            if !synchronizing { updaterController?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
            synchronizeInstallPreference()
        }
    }
    @Published var automaticallyDownloadsUpdates = false {
        didSet {
            if !synchronizing { updaterController?.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
            synchronizeInstallPreference()
        }
    }

    private var updaterController: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()
    private var synchronizing = false
    private var relaunchGate = UpdateRelaunchGate()
    private var staged = StagedUpdateState()
    private var idleTimer: Timer?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var isInstallingUpdate: Bool { relaunchGate.installationStarted }
    var canRelaunchNow: Bool { staged.canRelaunchNow }

    func start() {
        guard updaterController == nil else { return }
        guard Self.validConfiguration(Bundle.main.infoDictionary ?? [:]) else {
            statusText = "Automatic updates are not configured for this build. Install a published release to receive them."
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        updaterController = controller
        do {
            try controller.updater.start()
            isConfigured = true
            controller.updater.publisher(for: \.canCheckForUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshState() }
                .store(in: &cancellables)
            controller.updater.publisher(for: \.automaticallyChecksForUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] value in
                    guard let self else { return }
                    self.synchronizing = true
                    self.automaticallyChecksForUpdates = value
                    self.synchronizing = false
                }.store(in: &cancellables)
            controller.updater.publisher(for: \.automaticallyDownloadsUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] value in
                    guard let self else { return }
                    self.synchronizing = true
                    self.automaticallyDownloadsUpdates = value
                    self.synchronizing = false
                }.store(in: &cancellables)
            refreshState()
        } catch {
            updaterController = nil
            isConfigured = false
            statusText = "Automatic updates could not start. Reinstall the latest published release."
        }
    }

    func checkForUpdates() {
        guard isConfigured, canCheckForUpdates else { return }
        staged.beginCheck()
        refreshState()
        updaterController?.checkForUpdates(nil)
    }

    func restartToUpdate() {
        guard isConfigured else { return }
        if relaunchGate.hasPendingInstall {
            guard staged.requestExplicitRelaunch() else { return }
            advanceInstallation()
        } else if let ticket = staged.takeInstallation(now: now, userInitiated: true) {
            queueInstallation(ticket)
        }
    }

    func setRecordingBusy(_ busy: Bool) {
        staged.setContext(dictationBusy: busy, presentationBusy: staged.presentationBusy,
                          settingsVisible: staged.settingsVisible, settingsEditing: staged.settingsEditing, now: now)
        advanceInstallation()
    }

    func setInteractionState(presentationBusy: Bool, settingsVisible: Bool, settingsEditing: Bool) {
        staged.setContext(dictationBusy: staged.dictationBusy, presentationBusy: presentationBusy,
                          settingsVisible: settingsVisible, settingsEditing: settingsEditing, now: now)
        advanceInstallation()
    }

    func deferAfterCancelledTermination() {
        relaunchGate.cancel()
        staged.terminationCancelled(now: now)
        advanceInstallation()
    }

    private func synchronizeInstallPreference() {
        // Read Sparkle's saved choices; never force a stored opt-out back on at launch.
        staged.setAutomaticInstallEnabled(automaticallyChecksForUpdates && automaticallyDownloadsUpdates, now: now)
        advanceInstallation()
    }

    private func queueInstallation(_ ticket: StagedUpdateState.InstallTicket) {
        refreshState()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let handler = self.staged.prepareInstallation(ticket, now: self.now) else {
                self.refreshState()
                return
            }
            self.relaunchGate.markInstallationStarted()
            self.refreshState()
            handler()
        }
    }

    private func advanceInstallation() {
        relaunchGate.recordingBusy = !staged.canResumeRelaunch(now: now)
        if let install = relaunchGate.takeReadyInstall() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.relaunchGate.recordingBusy = !self.staged.canResumeRelaunch(now: self.now)
                guard let handler = self.relaunchGate.prepareQueuedInstall(install) else {
                    self.refreshState()
                    return
                }
                self.refreshState()
                handler()
            }
        } else if !relaunchGate.hasPendingInstall,
                  let ticket = staged.takeInstallation(now: now) {
            queueInstallation(ticket)
        }
        refreshState()
    }

    private func refreshState() {
        canCheckForUpdates = isConfigured && !staged.dictationBusy && !staged.hasStagedInstall &&
            !isInstallingUpdate && (updaterController?.updater.canCheckForUpdates ?? false)
        canRestartToUpdate = isConfigured && !staged.hasQueuedInstall &&
            (staged.canRestart || (relaunchGate.hasPendingInstall && staged.canRequestExplicitRelaunch))
        updateReady = staged.hasStagedInstall || relaunchGate.hasPendingInstall
        availableVersion = staged.version
        if isConfigured {
            statusText = relaunchGate.hasPendingInstall
                ? "\(staged.version.map { "Version " + $0 } ?? "The update") is ready. Restart is waiting until your work is finished."
                : staged.statusText
        }
        let needsTimer = staged.hasStagedInstall || relaunchGate.hasPendingInstall
        if needsTimer && idleTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.advanceInstallation() }
            }
            idleTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if !needsTimer {
            idleTimer?.invalidate()
            idleTimer = nil
        }
    }

    nonisolated static func validConfiguration(_ info: [String: Any]) -> Bool {
        guard let text = info["SUFeedURL"] as? String,
              let url = URLComponents(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
              let key = info["SUPublicEDKey"] as? String,
              let decoded = Data(base64Encoded: key), decoded.count == 32,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SURequireSignedFeed"] as? Bool == true else { return false }
        let name = host.lowercased()
        return name != "localhost" && name != "127.0.0.1" && name != "::1" &&
            ![".localhost", ".local", ".invalid", ".test", ".example"].contains(where: name.hasSuffix) &&
            !["example.com", "example.org", "example.net"].contains(name)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        staged.found(version: item.displayVersionString)
        refreshState()
    }
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        staged.downloading(version: item.displayVersionString)
        refreshState()
    }
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        staged.downloaded(version: item.displayVersionString)
        refreshState()
    }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        staged.stage(version: item.displayVersionString, now: now, handler: immediateInstallHandler)
        advanceInstallation()
        return true
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        staged.willInstall(version: item.displayVersionString)
        relaunchGate.markInstallationStarted()
        refreshState()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        staged.willInstall(version: item.displayVersionString)
        relaunchGate.recordingBusy = !staged.canResumeRelaunch(now: now)
        guard relaunchGate.postponeIfBusy(installHandler) else { return false }
        refreshState()
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        finishCycle(error: error)
    }
    func userDidCancelDownload(_ updater: SPUUpdater) {
        relaunchGate.cancel()
        staged.finish(.cancelled)
        refreshState()
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        finishCycle(error: error)
    }
    private func finishCycle(error: Error?) {
        if error != nil { relaunchGate.cancel() }
        staged.finish(Self.cycleOutcome(for: error), errorDescription: error?.localizedDescription)
        refreshState()
    }

    nonisolated static func cycleOutcome(for error: Error?) -> StagedUpdateState.Outcome {
        guard let error = error as NSError? else { return .completed }
        if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue) { return .upToDate }
        if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.installationCanceledError.rawValue) { return .cancelled }
        return .failed
    }
    nonisolated static func cycleStatus(for error: Error?) -> String {
        switch cycleOutcome(for: error) {
        case .completed: return "Update check completed."
        case .upToDate: return "You're up to date."
        case .cancelled: return "Update installation canceled."
        case .failed: return "The update check did not complete. You can try again later."
        }
    }
}
