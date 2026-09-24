import AppKit
import SwiftUI
import Combine

extension Notification.Name {
    static let fnDictateOpenSettings = Notification.Name("fnDictateOpenSettings")
    static let fnDictateShowOnboarding = Notification.Name("fnDictateShowOnboarding")
    static let fnDictateResumeOnboarding = Notification.Name("fnDictateResumeOnboarding")
}

final class UIState: ObservableObject {
    @Published var tab: SettingsTab = .setup
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case home, setup, dictation, transcription, cleanup, dictionary, history, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .setup: return "Setup"
        case .dictation: return "Dictation"
        case .transcription: return "Transcription"
        case .cleanup: return "Clean-up"
        case .dictionary: return "Dictionary"
        case .history: return "History"
        case .advanced: return "Advanced"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house"
        case .setup: return "checklist"
        case .dictation: return "keyboard"
        case .transcription: return "waveform"
        case .cleanup: return "sparkles"
        case .dictionary: return "character.book.closed"
        case .history: return "clock"
        case .advanced: return "gearshape.2"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSMenuItemValidation {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    let settings = Settings.shared
    let controller = DictationController()
    let hotkey = HotkeyMonitor()
    let uiState = UIState()
    var simulate = false
    /// Mock transcriber + dry-run insertion, but dictation is triggered by the real hotkey.
    var mock = false
    /// Developer-only UI inspection: never register a global shortcut or start services.
    private let uiTesting = CommandLine.arguments.contains("--ui-test")

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    /// `--show hub|onboarding` opens a window at launch (used for screenshots and tests).
    var showAtLaunch: String?
    private var permissionTimer: Timer?
    private var statusMenuOpen = false
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("FnDictate \(Self.version) starting (pid \(ProcessInfo.processInfo.processIdentifier))")
        controller.hotkey = hotkey
        if simulate || mock || uiTesting {
            controller.dryRun = true
            controller.useMockSTT = true
        }
        setupStatusItem()
        installMainMenu()
        if !simulate && !mock && !uiTesting { AppUpdater.shared.start() }

        hotkey.triggerKeys = settings.activeTriggerKeys
        hotkey.interceptTrigger = settings.interceptTrigger
        hotkey.handler = { [weak self] event in
            if OnboardingSession.shared.handleHotkey(event) { return true }
            return self?.controller.handleHotkey(event) ?? false
        }
        settings.$triggerKey.combineLatest(settings.$secondaryTrigger)
            .dropFirst()
            .sink { [weak self] primary, secondary in
                guard let self else { return }
                // @Published emits before the property is stored. Reading settings here leaves
                // the monitor one selection behind the visible picker.
                self.hotkey.triggerKeys = [primary] + [secondary.triggerKey].compactMap { $0 }.filter { $0 != primary }
                Log.info("Trigger keys now: \(self.hotkey.triggerKeys.map { $0.shortName })")
            }
            .store(in: &cancellables)
        settings.$interceptTrigger.sink { [weak self] value in self?.hotkey.interceptTrigger = value }.store(in: &cancellables)
        settings.$sttEngine.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, !self.uiTesting else { return }
            self.controller.warmUp()
        }.store(in: &cancellables)
        settings.$usesHostedService.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, !self.uiTesting else { return }
            self.controller.retryProviders()
            if self.settings.usesHostedService { Task { await HostedService.shared.refresh() } }
        }.store(in: &cancellables)
        controller.$phase.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateStatusIcon()
            self?.refreshUpdateInteractionState()
        }.store(in: &cancellables)
        controller.overlay.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshUpdateInteractionState()
        }.store(in: &cancellables)
        controller.$micTesting.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshUpdateInteractionState()
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: InlineUpdateDrafts.didChange, object: InlineUpdateDrafts.shared)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshUpdateInteractionState() }
            .store(in: &cancellables)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshUpdateInteractionState() }
                .store(in: &cancellables)
        }

        if !uiTesting {
            if settings.usesHostedService { Task { await HostedService.shared.refresh() } }
            startHotkeyWhenAllowed()
            if Permissions.microphoneStatus == .authorized { controller.audio.prepare() }
            controller.warmUp()
            controller.showHandle()
        }
        settings.$showIdleHandle.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, !self.uiTesting else { return }
            self.controller.showHandle()
        }.store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: .fnDictateOpenSettings, object: nil, queue: .main) { [weak self] notification in
            let tab = (notification.userInfo?["tab"] as? String).flatMap(SettingsTab.init(rawValue:)) ?? .setup
            self?.showSettings(tab: tab)
        }
        NotificationCenter.default.addObserver(forName: .fnDictateShowOnboarding, object: nil, queue: .main) { [weak self] _ in
            self?.showOnboarding()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.controller.handleSystemSleep()
        }

        if uiTesting && showAtLaunch == nil {
            showSettings(tab: .dictation)
        } else if let show = showAtLaunch {
            if show == "none" {
                // Relaunched in the background: no window, the hotkey simply keeps working.
            } else if show == "onboarding" { showOnboarding() } else { showSettings(tab: SettingsTab(rawValue: show) ?? .home) }
        } else if !settings.hasCompletedSetup && !simulate && !mock {
            showOnboarding()
        } else if (!Permissions.accessibilityGranted || Permissions.microphoneStatus != .authorized || !hasAnyKeys) && !simulate && !mock {
            showSettings(tab: .setup)
        }
        if simulate {
            Log.info("Simulation: a mock dictation runs in 3 seconds")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                _ = self.controller.handleHotkey(.triggerDown(.fn))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    _ = self.controller.handleHotkey(.triggerUp(.fn))
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.handleAppTermination()
        History.shared.flush()
        hotkey.stop()
        Log.info("FnDictate quitting")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettings(tab: .home) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Sparkle may also install without relaunching, which does not always invoke
        // its postpone-relaunch delegate. Recheck at the last possible moment so a
        // new dictation, Copy card or unsaved prompt cannot be lost to an update.
        refreshUpdateInteractionState()
        if AppUpdater.shared.isInstallingUpdate && !AppUpdater.shared.canRelaunchNow {
            AppUpdater.shared.deferAfterCancelledTermination()
            return .terminateCancel
        }
        return .terminateNow
    }

    private func refreshUpdateInteractionState() {
        let presentationBusy: Bool
        switch controller.overlay.state {
        case .result, .error: presentationBusy = true
        default: presentationBusy = false
        }
        // AppKit lifecycle callbacks and the subscriptions above all run on main.
        // Keep this recheck synchronous, especially inside applicationShouldTerminate.
        MainActor.assumeIsolated {
            AppUpdater.shared.setRecordingBusy(controller.phase != .idle || controller.micTesting)
            AppUpdater.shared.setInteractionState(
                presentationBusy: presentationBusy,
                settingsVisible: statusMenuOpen || settingsWindow?.isVisible == true || onboardingWindow?.isVisible == true,
                settingsEditing: InlineUpdateDrafts.shared.hasUnsavedChanges || settingsWindow?.attachedSheet != nil ||
                    onboardingWindow?.attachedSheet != nil || NSApp.modalWindow != nil)
        }
    }

    var hasAnyKeys: Bool {
        settings.usesHostedService ? HostedService.baseURL != nil : Keychain.apiKey(settings.sttEngine.keychainAccount) != nil
    }

    // MARK: - Hotkey permission polling

    private func startHotkeyWhenAllowed() {
        if Permissions.accessibilityGranted, hotkey.start() { return }
        Log.info("Waiting for Accessibility permission before installing the hotkey")
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if Permissions.accessibilityGranted, self.hotkey.start() {
                t.invalidate()
                self.permissionTimer = nil
                self.controller.audio.prepare()
                self.updateStatusIcon()
                self.controller.showHandle()
            }
        }
    }

    // MARK: - Main menu

    /// A menu-bar-only app has no menu bar of its own, so without this ⌘C / ⌘V / ⌘A do nothing in
    /// its text fields (the API-key fields could not be pasted into).
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Preferences…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Expertise Typer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Expertise Typer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let dictationItem = NSMenuItem()
        let dictation = NSMenu(title: "Dictation")
        dictation.addItem(withTitle: "Start Dictation", action: #selector(toggleDictation), keyEquivalent: "").target = self
        dictation.addItem(withTitle: "Cancel Dictation", action: #selector(cancelDictation), keyEquivalent: "").target = self
        dictationItem.submenu = dictation
        main.addItem(dictationItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let name: String
        switch controller.phase {
        case .idle: name = hotkey.isRunning ? "waveform.and.mic" : "mic.slash"
        case .recording: name = "waveform"
        case .finishing, .processing: name = "sparkles"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Expertise Typer")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Expertise Typer — \(controller.statusLine)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshUpdateInteractionState()
        menu.removeAllItems()
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if !hotkey.isRunning {
            let title = Permissions.accessibilityGranted ? "Check shortcut setup…" : "Grant Accessibility permission…"
            let fix = NSMenuItem(title: title, action: #selector(fixPermissions), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        }
        menu.addItem(.separator())
        if controller.phase == .idle || controller.phase == .recording {
            let record = NSMenuItem(title: controller.phase == .recording ? "Finish Dictation" : "Start Dictation", action: #selector(toggleDictation), keyEquivalent: "")
            record.target = self
            menu.addItem(record)
        }
        if controller.recoveryAvailable {
            let recovery = NSMenuItem(title: "Recover Saved Recording…", action: #selector(openHome), keyEquivalent: "")
            recovery.target = self
            menu.addItem(recovery)
        }
        let translateStart = NSMenuItem(title: "Start Translation to \(TranslationLanguage.find(settings.translationLanguage).native)", action: #selector(startTranslation), keyEquivalent: "")
        translateStart.target = self
        translateStart.isEnabled = controller.phase == .idle
        menu.addItem(translateStart)
        menu.addItem(.separator())
        let home = NSMenuItem(title: "Open Expertise Typer", action: #selector(openHome), keyEquivalent: "")
        home.target = self
        menu.addItem(home)
        if AppUpdater.shared.updateReady && InlineUpdateDrafts.shared.hasUnsavedChanges {
            let draftHint = NSMenuItem(title: "Save, add or clear unfinished edits to update", action: nil, keyEquivalent: "")
            draftHint.isEnabled = false
            menu.addItem(draftHint)
        }
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Expertise Typer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        statusMenuOpen = true
        refreshUpdateInteractionState()
    }

    func menuDidClose(_ menu: NSMenu) {
        statusMenuOpen = false
        refreshUpdateInteractionState()
    }

    private var statusTitle: String {
        switch controller.phase {
        case .idle:
            switch DictationReadiness.evaluate(completedSetup: settings.hasCompletedSetup,
                    permissionsReady: Permissions.accessibilityGranted && Permissions.microphoneStatus == .authorized,
                    shortcutReady: hotkey.isRunning, connectionReady: connectionIsConfigured(settings)) {
            case .permissions: return "Permissions need attention"
            case .shortcut: return "Shortcut needs attention"
            case .setup: return "Finish setup to get started"
            case .connection: return "Dictation connection unavailable"
            case .ready: return "Ready · \(settings.triggerKey.shortName) to dictate"
            }
        case .recording: return controller.handsFree ? "Listening (hands-free)…" : "Listening…"
        case .finishing, .processing: return "Finishing…"
        }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = DictationMode(rawValue: raw) {
            settings.dictationMode = mode
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { controller.setTranslationLanguage(code) }
    }

    @objc private func toggleDictation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            if self.controller.phase == .recording { self.controller.finish() }
            else if self.controller.phase == .idle {
                _ = self.controller.handleHotkey(.triggerDown(self.settings.triggerKey))
                _ = self.controller.handleHotkey(.triggerUp(self.settings.triggerKey))
            }
        }
    }

    @objc private func cancelDictation() { controller.cancel(reason: "Menu cancellation") }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleDictation):
            item.title = controller.phase == .recording ? "Finish Dictation" : "Start Dictation"
            return controller.phase == .idle || controller.phase == .recording
        case #selector(cancelDictation): return controller.phase != .idle
        case #selector(startTranslation): return controller.phase == .idle
        case #selector(pasteLast): return controller.lastInserted != nil || History.shared.last != nil
        case #selector(checkForUpdates):
            item.title = AppUpdater.shared.updateReady ? "Restart to Update…" : "Check for Updates…"
            // Always allow opening the visible update status. The Home action
            // explains work-in-progress and protects an unsafe restart.
            return true
        default: return true
        }
    }

    @objc private func startTranslation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.controller.startTranslation() }
    }

    @objc private func pasteLast() {
        // Give the menu time to close so the paste lands in the previously focused app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.controller.repeatLastInsert() }
    }

    @objc private func openHistory() { showSettings(tab: .history) }
    @MainActor @objc private func checkForUpdates() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let editingWindow = [self.settingsWindow, self.onboardingWindow]
                .compactMap { $0 }.first { $0.attachedSheet != nil }
            let hasDrafts = InlineUpdateDrafts.shared.hasUnsavedChanges
            if hasDrafts || editingWindow != nil {
                // Changing tabs destroys SwiftUI draft views. A manual check
                // must preserve their current tab and any presented editor.
                NSApp.activate(ignoringOtherApps: true)
                (editingWindow ?? self.settingsWindow)?.makeKeyAndOrderFront(nil)
                if AppUpdater.shared.updateReady || editingWindow != nil {
                    let alert = NSAlert()
                    alert.messageText = "Finish your edits first"
                    alert.informativeText = "Save, add or cancel your unfinished edit, then try again. Your changes have been kept."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }
            } else {
                self.showSettings(tab: .home)
            }
            self.refreshUpdateInteractionState()
            if AppUpdater.shared.updateReady { AppUpdater.shared.restartToUpdate() }
            else { AppUpdater.shared.checkForUpdates() }
        }
    }
    @objc private func openDictionary() { showSettings(tab: .dictionary) }
    @objc private func openHome() { showSettings(tab: .home) }
    @objc private func openSettings() { showSettings(tab: settings.hasCompletedSetup ? .dictation : .setup) }
    @objc private func fixPermissions() { showSettings(tab: .setup) }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
        } catch {
            Log.error("Launch at login failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMove Expertise Typer to the Applications folder and try again."
            alert.runModal()
        }
    }

    // MARK: - Onboarding window

    func showOnboarding() {
        guard controller.phase == .idle else {
            let alert = NSAlert()
            alert.messageText = "Finish this dictation first"
            alert.informativeText = "Setup will be available after your current dictation finishes. Press your shortcut to finish recording, or Escape to cancel."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        controller.stopMicTest()
        settingsWindow?.orderOut(nil)
        let root = OnboardingView(controller: controller, hotkey: hotkey, onFinish: { [weak self] in
            self?.onboardingWindow?.orderOut(nil)
            self?.showSettings(tab: .home)
        })
        .environmentObject(settings)
        if onboardingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: min(720, (NSScreen.main?.visibleFrame.height ?? 820) - 24)),
                                  styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Welcome to Expertise Typer"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 0x13 / 255, green: 0x14 / 255, blue: 0x16 / 255, alpha: 1)
                    : NSColor(srgbRed: 0xFA / 255, green: 0xF8 / 255, blue: 0xF5 / 255, alpha: 1)
            }
            window.minSize = NSSize(width: 720, height: 600)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = InteractiveHostingView(rootView: root)
            window.center()
            onboardingWindow = window
        }
        // Retain a current attempt while the user repairs a connection or returns
        // later. Its own resume handler revalidates changed devices and permissions.
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .fnDictateResumeOnboarding, object: nil)
        refreshUpdateInteractionState()
    }

    // MARK: - Settings window

    func showSettings(tab: SettingsTab?) {
        OnboardingSession.shared.suspend()
        controller.stopMicTest()
        onboardingWindow?.orderOut(nil)
        if let tab { uiState.tab = tab }
        if settingsWindow == nil {
            let root = SettingsView(controller: controller, hotkey: hotkey)
                .environmentObject(settings)
                .environmentObject(uiState)
                .environmentObject(History.shared)
            // No fullSizeContentView: content that scrolls under an invisible title bar cannot be
            // clicked there (the title bar keeps the clicks for window dragging).
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Expertise Typer"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 0x13 / 255, green: 0x14 / 255, blue: 0x16 / 255, alpha: 1)
                    : NSColor(srgbRed: 0xFA / 255, green: 0xF8 / 255, blue: 0xF5 / 255, alpha: 1)
            }
            window.minSize = NSSize(width: 720, height: 560)
            window.contentView = InteractiveHostingView(rootView: root)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        refreshUpdateInteractionState()
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === onboardingWindow { OnboardingSession.shared.suspend() }
        // Retained NSWindows can disappear without destroying their SwiftUI view.
        // Closing Setup must still release a running microphone test.
        controller.stopMicTest()
        DispatchQueue.main.async { [weak self] in self?.refreshUpdateInteractionState() }
    }
}

/// Settings should accept the first click even when the menu-bar app was inactive.
final class InteractiveHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
