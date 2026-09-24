import AppKit
import ApplicationServices

/// Opt-in integration fixture for a fresh, empty ChatGPT web composer in Chrome.
/// Uses the production inserter. Never records audio, sends a prompt, reads keys,
/// loads user settings/history, or targets the denied native Codex application.
enum InsertionHostTest {
    enum Scenario: String { case short, long, changedField = "changed-field" }
    static let allowedBundle = "com.google.Chrome"

    static func text(for scenario: Scenario) -> String {
        if scenario == .short { return "Expertise Dictation insertion test. This draft remains unsent." }
        return (1...80).map {
            "Section \($0): Preserve every word in this unsent insertion test. 这段文字也需要完整保留。"
        }.joined(separator: "\n\n") + "\nEND OF UNSENT INSERTION TEST"
    }

    static func run(_ args: [String]) -> Bool {
        func argument(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        guard let value = argument("--case"), let scenario = Scenario(rawValue: value),
              let reportPath = argument("--report") else {
            print("usage: --insertion-host-test --case short|long|changed-field --report PATH")
            return false
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let started = Date()
        let transcript = text(for: scenario)
        var report: [String: Any] = [
            "schemaVersion": 1, "scenario": scenario.rawValue,
            "scope": "Production TextInserter in a fresh unsent Chrome composer; no microphone, speech/cleanup provider, native Codex, user history or preferences. Exact page contents must be independently checked through the browser.",
            "allowedHostBundle": allowedBundle, "syntheticTextCharacters": transcript.count,
            "submitted": false, "observedExactText": false, "copyConfirmed": false,
            "messageSent": false, "success": false
        ]
        var finished = false
        var success = false
        var original: InsertionTarget?
        var browser: NSRunningApplication?
        let model = OverlayModel()
        let panel = OverlayPanel(model: model)
        var copiedClipboard: [[(NSPasteboard.PasteboardType, Data)]]?
        var ownedClipboardChange: Int?
        var timers: [Timer] = []

        func restoreCopiedClipboard() {
            let pasteboard = NSPasteboard.general
            guard let ownedClipboardChange, pasteboard.changeCount == ownedClipboardChange,
                  let copiedClipboard else { return }
            pasteboard.clearContents()
            let items = copiedClipboard.map { contents in
                let item = NSPasteboardItem()
                for (type, data) in contents { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
        func finish(_ passed: Bool, outcome: String) {
            guard !finished else { return }
            finished = true
            success = passed
            report["success"] = passed
            report["outcome"] = outcome
            report["elapsedSeconds"] = Date().timeIntervalSince(started)
            panel.dismiss()
            restoreCopiedClipboard()
            timers.forEach { $0.invalidate() }
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
                print(String(decoding: data, as: UTF8.self))
            } catch {
                success = false
                print("Insertion fixture could not write its evidence report.")
            }
            app.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                            timestamp: 0, windowNumber: 0, context: nil,
                                            subtype: 0, data1: 0, data2: 0) {
                app.postEvent(wake, atStart: false)
            }
        }
        func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) {
            let timer = Timer(timeInterval: seconds, repeats: false) { _ in if !finished { action() } }
            timers.append(timer)
            RunLoop.main.add(timer, forMode: .common)
        }
        func showCopyResult() {
            report["copyCardComplete"] = true
            model.state = .result(text: transcript)
            model.statusDetail = "The text field changed. This unsent synthetic test text is ready to copy."
            model.onCopy = {
                let pasteboard = NSPasteboard.general
                if ownedClipboardChange != pasteboard.changeCount {
                    copiedClipboard = (pasteboard.pasteboardItems ?? []).map { item in
                        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
                    }
                }
                pasteboard.clearContents()
                let copied = pasteboard.setString(transcript, forType: .string)
                    && pasteboard.string(forType: .string) == transcript
                ownedClipboardChange = pasteboard.changeCount
                model.copied = copied
                report["copyConfirmed"] = copied
            }
            model.onDismiss = {
                finish(scenario == .changedField && report["insertionError"] as? String == "targetChanged"
                       && report["copyConfirmed"] as? Bool == true,
                       outcome: "changed-field-copy-dismissed")
            }
            panel.present()
        }

        guard Permissions.accessibilityGranted else {
            // Do not create permission prompts or change system settings from a fixture.
            report["outcome"] = "accessibility-permission-unavailable"
            report["elapsedSeconds"] = Date().timeIntervalSince(started)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
                print(String(decoding: data, as: UTF8.self))
            }
            return false
        }
        print("INSERTION FIXTURE: focus the fresh empty Chrome composer; capture in 5 seconds. No message will be sent.")
        fflush(stdout)
        schedule(after: 5) {
            guard let focusedApp = NSWorkspace.shared.frontmostApplication,
                  focusedApp.bundleIdentifier == allowedBundle else {
                finish(false, outcome: "allowed-browser-not-frontmost")
                return
            }
            browser = focusedApp
            let captured = TextInserter.captureTarget(in: focusedApp)
            guard captured.processIdentifier == focusedApp.processIdentifier, let element = captured.element,
                  TextInserter.isEditableTarget(captured), !captured.isSecure else {
                finish(false, outcome: "empty-composer-identity-unavailable")
                return
            }
            // Fail closed if AX cannot prove the field is empty. Never replace a
            // user draft, selection or a browser address/search value.
            guard TextInserter.stringAttribute(element, kAXValueAttribute) == "", captured.selectedLength == 0 else {
                finish(false, outcome: "composer-not-provably-empty")
                return
            }
            original = captured
            report["capturedOriginalField"] = true
            report["capturedRole"] = captured.role ?? "unavailable"
            print("INSERTION FIXTURE: original empty field captured; \(scenario == .changedField ? "change focus now" : "keep this field focused"). Insertion check in 5 seconds.")
            fflush(stdout)
            schedule(after: 5) {
                guard let original, let browser, !browser.isTerminated else {
                    finish(false, outcome: "captured-browser-unavailable")
                    return
                }
                do {
                    // Every capture is pinned to Chrome. The shared resolver refuses
                    // a changed foreground process before querying another app.
                    let sent = try TextInserter.insert(transcript, method: .paste, smartSpacing: false,
                                                       restoreClipboard: true, cjkSpacing: false, dryRun: false,
                                                       expectedTarget: original,
                                                       targetReader: {
                        var current = TextInserter.captureTarget(in: browser)
                        // Recheck emptiness at every production focus validation too:
                        // typing into the test field during the countdown cancels it.
                        if let element = current.element,
                           TextInserter.stringAttribute(element, kAXValueAttribute) != "" || current.selectedLength != 0 {
                            current.element = nil
                        }
                        return current
                    })
                    report["submitted"] = true
                    report["submittedExactText"] = sent == transcript
                    schedule(after: 1) {
                        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == browser.processIdentifier,
                              let element = original.element else {
                            finish(false, outcome: "observation-host-changed")
                            return
                        }
                        let exact = TextInserter.stringAttribute(element, kAXValueAttribute) == transcript
                        report["observedExactText"] = exact
                        finish(scenario != .changedField && exact, outcome: exact ? "exact-unsent-text-observed" : "paste-not-observed-exactly")
                    }
                } catch InsertionError.targetChanged {
                    report["insertionError"] = "targetChanged"
                    showCopyResult()
                } catch {
                    report["insertionError"] = "insertionUnavailable"
                    showCopyResult()
                }
            }
        }
        schedule(after: 35) { finish(false, outcome: "bounded-fixture-timeout") }
        app.run()
        return success
    }
}
