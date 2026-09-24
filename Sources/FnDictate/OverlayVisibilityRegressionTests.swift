import AppKit

/// Runs only from --overlay-selftest, using its isolated panel and synthetic content.
/// App notifications are simulated; the covering window and WindowServer visibility are real.
enum OverlayVisibilityRegressionTests {
    /// Diagnostic metadata for this fixture's own window only. No window titles,
    /// application names, other windows' contents, or accessibility data are read.
    static func diagnosticState(panel: OverlayPanel, app: NSApplication) -> String {
        let ownWindow = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(panel.windowNumber)) as? [[String: Any]])?
            .first { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == panel.windowNumber }
        let serverOnScreen = (ownWindow?[kCGWindowIsOnscreen as String] as? NSNumber).map { String($0.boolValue) } ?? "unknown"
        // Only documented console/login booleans: never dump the session's user
        // identifiers. These fields do not establish whether the screen is locked.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let onConsole = (session?[kCGSessionOnConsoleKey as String] as? NSNumber).map { String($0.boolValue) } ?? "unknown"
        let loginComplete = (session?[kCGSessionLoginDoneKey as String] as? NSNumber).map { String($0.boolValue) } ?? "unknown"
        let midpoint = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let ownWindowAtMidpoint = NSWindow.windowNumber(at: midpoint, belowWindowWithWindowNumber: 0) == panel.windowNumber
        return "visible=\(panel.isVisible) activeSpace=\(panel.isOnActiveSpace) unoccluded=\(panel.occlusionState.contains(.visible)) " +
            "occlusionRaw=\(panel.occlusionState.rawValue) windowServerListed=\(ownWindow != nil) windowServerOnScreen=\(serverOnScreen) " +
            "ownWindowAtMidpoint=\(ownWindowAtMidpoint) canBecomeKey=\(panel.canBecomeKey) isKey=\(panel.isKeyWindow) " +
            "appActive=\(app.isActive) appHidden=\(app.isHidden) appRunning=\(app.isRunning) appUnoccluded=\(app.occlusionState.contains(.visible)) " +
            "sessionAvailable=\(session != nil) sessionOnConsole=\(onConsole) loginComplete=\(loginComplete) " +
            "level=\(panel.level.rawValue) alpha=\(panel.alphaValue) screens=\(NSScreen.screens.count) frame=\(NSStringFromRect(panel.frame))"
    }

    static func run(panel: OverlayPanel, model: OverlayModel, app: NSApplication) -> Bool {
        print("VISIBILITY TEST SCOPE: isolated native panels, simulated foreground/wake notifications; no actual app switching, microphone or user data")
        var passed = true
        var foregroundPID: pid_t?
        func check(_ name: String, _ condition: Bool, detail: String = "") {
            print("VISIBILITY \(condition ? "PASS" : "FAIL"): \(name)")
            if !condition {
                let foregroundChanged = NSWorkspace.shared.frontmostApplication?.processIdentifier != foregroundPID
                print("VISIBILITY DIAGNOSTIC: \(diagnosticState(panel: panel, app: app)) foregroundChanged=\(foregroundChanged) \(detail)")
            }
            passed = passed && condition
        }
        func pump(_ duration: TimeInterval) {
            let deadline = Date().addingTimeInterval(duration)
            while Date() < deadline {
                while let event = app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                    app.sendEvent(event)
                }
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }
        func foregroundNotification() {
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
                                                       object: NSWorkspace.shared)
        }
        func visible() -> Bool {
            panel.isVisible && panel.isOnActiveSpace && panel.occlusionState.contains(.visible)
        }
        model.showHandle = true
        model.state = .listening
        model.text = "Keep the complete transcript. 保留完整文本。"
        model.elapsedSeconds = 321
        model.targetLanguage = "English"
        model.translating = true
        model.copied = false
        panel.present()
        pump(0.15)
        foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        print("VISIBILITY BASELINE: \(diagnosticState(panel: panel, app: app))")
        let windowNumber = panel.windowNumber
        let panelCount = app.windows.filter { $0 is OverlayPanel }.count
        func focusUnchanged() -> Bool {
            !panel.isKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID
        }
        check("hiding or deactivating the settings app cannot hide the overlay", !panel.canHide && !panel.hidesOnDeactivate)

        for (name, state) in [
            ("idle handle", OverlayState.idle),
            ("listening", .listening),
            ("processing", .transcribing),
            ("Copy card", .result(text: "The complete result. 完整结果。")),
            ("error card", .error(title: "Fixture", message: "Synthetic visibility fixture"))
        ] {
            model.state = state
            panel.present()
            pump(0.1)
            panel.orderOut(nil)
            foregroundNotification()
            pump(0.9)
            let statePreserved = model.state == state
            let textPreserved = model.text == "Keep the complete transcript. 保留完整文本。"
            let metadataPreserved = model.elapsedSeconds == 321 && model.translating && model.targetLanguage == "English"
            check("\(name) recovers on foreground notification with state and focus preserved",
                  visible() && statePreserved && textPreserved && metadataPreserved && focusUnchanged(),
                  detail: "statePreserved=\(statePreserved) textPreserved=\(textPreserved) metadataPreserved=\(metadataPreserved) focusPreserved=\(focusUnchanged())")
        }

        model.state = .listening
        panel.present()
        pump(1.1)
        panel.orderOut(nil)
        pump(1.3)
        check("a late visibility loss recovers without any Space or app notification", visible() && focusUnchanged())
        panel.orderOut(nil)
        pump(1.3)
        check("a second independent visibility loss recovers", visible() && focusUnchanged())

        // Cover the panel at its existing level. Recovery must fix ordering, not raise
        // the level above unrelated system UI or activate the dictation application.
        let coveringPanel = NSPanel(contentRect: panel.frame.insetBy(dx: -8, dy: -8),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        coveringPanel.isReleasedWhenClosed = false
        coveringPanel.level = panel.level
        coveringPanel.collectionBehavior = panel.collectionBehavior
        coveringPanel.backgroundColor = .black
        coveringPanel.isOpaque = true
        coveringPanel.hasShadow = false
        coveringPanel.hidesOnDeactivate = false
        coveringPanel.orderFrontRegardless()
        pump(1.3)
        let midpoint = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let frontWindow = NSWindow.windowNumber(at: midpoint, belowWindowWithWindowNumber: 0)
        check("a fully covered overlay returns above a same-level window without focus theft",
              visible() && frontWindow == panel.windowNumber && panel.level == .statusBar && focusUnchanged(),
              detail: "fixtureCoverOnTop=\(frontWindow == coveringPanel.windowNumber) levelPreserved=\(panel.level == .statusBar) focusPreserved=\(focusUnchanged())")
        coveringPanel.orderOut(nil)

        for _ in 0..<20 { foregroundNotification() }
        pump(0.9)
        check("rapid foreground notifications reuse the existing panel",
              visible() && panel.windowNumber == windowNumber && app.windows.filter { $0 is OverlayPanel }.count == panelCount && focusUnchanged(),
              detail: "sameWindow=\(panel.windowNumber == windowNumber) samePanelCount=\(app.windows.filter { $0 is OverlayPanel }.count == panelCount) focusPreserved=\(focusUnchanged())")
        print("VISIBILITY RECOVERED STATE: \(diagnosticState(panel: panel, app: app)) focusPreserved=\(focusUnchanged())")
        foregroundNotification()
        panel.dismiss()
        pump(1.3)
        check("dismiss cancels foreground recovery and the watchdog", !panel.isVisible)
        foregroundNotification()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: NSWorkspace.shared)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: panel)
        pump(1.3)
        check("dismissed panel stays hidden through app, session, wake and occlusion events", !panel.isVisible && focusUnchanged())
        print("VISIBILITY DISMISSED STATE: \(diagnosticState(panel: panel, app: app)) focusPreserved=\(focusUnchanged())")
        return passed
    }
}
