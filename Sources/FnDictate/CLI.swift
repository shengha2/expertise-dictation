import Foundation
import AppKit
import AVFoundation
import SwiftUI

/// Headless helpers: `--selftest`, `--cleanup "text"`, `--transcribe file.wav`, `--version`.
enum CLI {
    static func run(_ args: [String]) -> Bool {
        guard args.count > 1 else { return false }
        switch args[1] {
        case "--version":
            print("Expertise Typer \(AppDelegate.version)")
            return true
        case "--help", "-h":
            print("""
            Expertise Typer — tap Fn, speak, then tap Fn again (default shortcut).
              --selftest             run the built-in checks for local clean-up and the meaning guard
              --cleanup "text"       run bounded LLM clean-up (uses saved keys)
              --cleanup-file PATH    clean a UTF-8 transcript, with --report JSON_PATH evidence
              --transcribe file.wav  stream a 16-bit PCM WAV through the transcription engine
              --simulate             launch the app with a mock transcriber; nothing is typed
            """)
            return true
        case "--selftest":
            exit(SelfTest.run() ? 0 : 1)
        case "--insertion-host-test":
            exit(InsertionHostTest.run(args) ? 0 : 1)
        case "--hosted-selftest":
            exit(NativeHostedServiceTest.run(args) ? 0 : 1)
        case "--archive-lease-fixture":
            // Bounded subprocess used only by cross-process ownership regression checks.
            guard args.count == 4 else { exit(1) }
            do {
                let archive = try RecordingArchive(directory: URL(fileURLWithPath: args[2]), acquireOwnership: true)
                archive.recordFailure("cross-process fixture owns this checkpoint")
                try Data("ready".utf8).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
                withExtendedLifetime(archive) { wait({ false }, timeout: 15) }
                exit(0)
            } catch { print(error.localizedDescription); exit(1) }
        case "--controller-selftest":
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.finishLaunching()
            exit(ControllerRegressionTests.run() ? 0 : 1)
        case "--cleanup":
            let text = args.dropFirst(2).joined(separator: " ")
            exit(runCleanup(text, inputFile: nil, reportPath: nil) ? 0 : 1)
        case "--cleanup-file":
            guard args.count > 2 else { print("usage: --cleanup-file PATH [--report JSON_PATH]"); exit(1) }
            let reportIndex = args.firstIndex(of: "--report")
            let reportPath = reportIndex.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            do {
                let text = try String(contentsOfFile: args[2], encoding: .utf8)
                exit(runCleanup(text, inputFile: URL(fileURLWithPath: args[2]).standardizedFileURL.path, reportPath: reportPath) ? 0 : 1)
            } catch { print("Could not read transcript: \(error.localizedDescription)"); exit(1) }
        case "--verify":
            guard args.count > 3 else { print("usage: --verify openai|anthropic|assemblyai KEY"); return true }
            var done = false
            Task { @MainActor in
                let result = await KeyVerifier.verify(account: args[2], key: args[3], settings: Settings.shared)
                switch result {
                case .success(let s): print("ok: \(s)")
                case .failure(let e): print("rejected: \(e.localizedDescription)")
                }
                done = true
            }
            wait({ done }, timeout: 40)
            return true
        case "--overlay-selftest":
            // Opens an isolated floating panel and checks sizing, focus and recovery from synthetic
            // workspace notifications. This does not perform an actual desktop swipe or touch a
            // running FnDictate, the microphone, providers, history or user settings.
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.finishLaunching()
            let model = OverlayModel()
            let panel = OverlayPanel(model: model)
            model.showHandle = true
            model.state = .listening
            model.targetLanguage = "English"
            panel.present()
            wait({ false }, timeout: 0.6)
            let plain = panel.frame.size
            model.translating = true
            wait({ false }, timeout: 0.6)
            let translating = panel.frame.size
            model.state = .cleaning
            wait({ false }, timeout: 0.4)
            let cleaning = panel.frame.size
            model.state = .result(text: "This is a test of the dictation system，然后我们看看中文行不行。")
            wait({ false }, timeout: 0.5)
            let card = panel.frame.size
            print("PREVIEW FOCUS BASELINE: \(OverlayVisibilityRegressionTests.diagnosticState(panel: panel, app: app))")
            panel.makeKey()
            let previewAcceptsFocus = panel.canBecomeKey && panel.isKeyWindow
            print("PREVIEW FOCUS RESULT: \(OverlayVisibilityRegressionTests.diagnosticState(panel: panel, app: app)) accepted=\(previewAcceptsFocus)")
            model.state = .listening
            panel.present()
            wait({ false }, timeout: 0.1)
            let recordingReleasesFocus = !panel.canBecomeKey && !panel.isKeyWindow
            print("RECORDING FOCUS RESULT: \(OverlayVisibilityRegressionTests.diagnosticState(panel: panel, app: app)) released=\(recordingReleasesFocus)")
            print("listening: \(Int(plain.width))×\(Int(plain.height))  translating: \(Int(translating.width))×\(Int(translating.height))  cleaning: \(Int(cleaning.width))×\(Int(cleaning.height))  card: \(Int(card.width))×\(Int(card.height))")
            // The window must equal the content's ideal size in every state; the chip adds its own
            // width, whatever that is, and the card is wider than the bar.
            let sizingAndFocusOK = translating.width > plain.width + 10 && card.width > translating.width && previewAcceptsFocus && recordingReleasesFocus
            print("preview accepts focus: \(previewAcceptsFocus); recording releases focus: \(recordingReleasesFocus)")
            let workspaceOK = runOverlayWorkspaceChecks(panel: panel, model: model, app: app)
            let copyLayoutOK = runOverlayCopyChecks(panel: panel, model: model)
            let visibilityOK = OverlayVisibilityRegressionTests.run(panel: panel, model: model, app: app)
            panel.dismiss()
            let ok = sizingAndFocusOK && workspaceOK && copyLayoutOK && visibilityOK
            print(ok ? "OVERLAY OK: sizing, focus, simulated workspace recovery and long Copy card passed" : "OVERLAY FAIL: sizing, focus, workspace recovery or long Copy card failed")
            exit(ok ? 0 : 1)
        case "--result-preview":
            // Isolated UI evidence: synthetic text only, no microphone/provider/history.
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.finishLaunching()
            let model = OverlayModel()
            let panel = OverlayPanel(model: model)
            let text = (1...80).map { "Section \($0): Keep every word available for copying. 这段文字也需要完整保留。" }.joined(separator: "\n\n") + "\nEND OF COPY FIXTURE"
            model.state = .result(text: text)
            model.statusDetail = "The text field changed. Copy your text and paste it where you want."
            var done = false
            var copied = false
            var originalClipboard: [[(NSPasteboard.PasteboardType, Data)]]?
            var ownedClipboardChange: Int?
            model.onCopy = {
                let clipboard = NSPasteboard.general
                if ownedClipboardChange != clipboard.changeCount {
                    originalClipboard = (clipboard.pasteboardItems ?? []).map { item in
                        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
                    }
                }
                clipboard.clearContents()
                copied = clipboard.setString(text, forType: .string) && clipboard.string(forType: .string) == text
                ownedClipboardChange = clipboard.changeCount
                model.copied = copied
                let endMarker = clipboard.string(forType: .string)?.hasSuffix("END OF COPY FIXTURE") == true
                print("RESULT COPY: complete=\(copied) characters=\(text.count) endMarker=\(endMarker)")
            }
            model.onDismiss = { done = true }
            panel.present()
            // Interactive fixtures need AppKit's event dispatcher. A RunLoop-only wait renders
            // the panel but never delivers its mouse/key events, leaving every control inert.
            let deadline = Date().addingTimeInterval(120)
            let completionTimer = Timer(timeInterval: 0.1, repeats: true) { _ in
                guard done || Date() >= deadline else { return }
                app.stop(nil)
                // stop() takes effect after the next event; wake an otherwise idle event queue.
                if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                                modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                context: nil, subtype: 0, data1: 0, data2: 0) {
                    app.postEvent(wake, atStart: false)
                }
            }
            RunLoop.main.add(completionTimer, forMode: .common)
            app.run()
            completionTimer.invalidate()
            panel.dismiss()
            // Restore only our own test copy, never a later clipboard change by the user.
            if let originalClipboard, ownedClipboardChange == NSPasteboard.general.changeCount {
                NSPasteboard.general.clearContents()
                let items = originalClipboard.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                NSPasteboard.general.writeObjects(items)
            }
            print("RESULT PREVIEW: dismissed=\(done) copyVerified=\(copied)")
            exit(done && (copied || args.contains("--dismiss-only")) ? 0 : 1)
        case "--bench-cleanup":
            // Times alternative clean-up strategies on real transcripts: streaming time-to-first-token
            // and total generation, so latency decisions rest on measurements, not guesses.
            CleanupBench.run()
            return true
        case "--translate":
            guard args.count > 3 else { print("usage: --translate LANGCODE \"text\""); return true }
            let target = TranslationLanguage.find(args[2])
            let text = args.dropFirst(3).joined(separator: " ")
            var done = false
            Task { @MainActor in
                let start = Date()
                do {
                    let (out, model) = try await Translator.translate(text, to: target, settings: Settings.shared, timeout: 20)
                    print("model:      \(model)  (\(Int(Date().timeIntervalSince(start) * 1000)) ms)")
                    print("raw:        \(text)")
                    print("\(target.name):  \(out)")
                } catch {
                    print("error: \(error.localizedDescription)")
                }
                done = true
            }
            wait({ done }, timeout: 60)
            return true
        case "--mic":
            let secs = Double(args.count > 2 ? args[2] : "3") ?? 3
            let cap = AudioCapture()
            var peak: Float = 0
            var count = 0
            cap.onLevel = { l in peak = max(peak, l); count += 1 }
            cap.onChunk = { _ in }
            print("microphone permission: \(Permissions.microphoneStatus.rawValue) (3 = authorized)")
            do { try cap.start(sampleRate: 16000) } catch { print("mic error: \(error.localizedDescription)"); return true }
            wait({ false }, timeout: secs)
            cap.stop(keepWarm: false)
            print("level callbacks: \(count), peak level: \(String(format: "%.2f", peak))")
            return true
        case "--transcribe":
            guard args.count > 2 else { print("usage: --transcribe file.wav"); return true }
            exit(runTranscribe(path: args[2], options: Array(args.dropFirst(3))) ? 0 : 1)
        default:
            return false
        }
    }

    private static func wait(_ done: @escaping () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private static func runOverlayWorkspaceChecks(panel: OverlayPanel, model: OverlayModel, app: NSApplication) -> Bool {
        print("WORKSPACE TEST SCOPE: real isolated NSPanel; simulated Space/display notifications; no actual desktop swipe, full-screen or Stage Manager transition")
        var passed = true
        func check(_ name: String, _ condition: Bool) {
            print("WORKSPACE \(condition ? "PASS" : "FAIL"): \(name)")
            passed = passed && condition
        }
        func notifySpaceChange() {
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification,
                                                       object: NSWorkspace.shared)
        }
        func onScreen() -> Bool {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
            return panel.isVisible && panel.isOnActiveSpace && windows?.contains {
                ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == panel.windowNumber
            } == true
        }
        let windowNumber = panel.windowNumber
        let panelCount = app.windows.filter { $0 is OverlayPanel }.count
        let expectedBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        check("configured for all desktops and other apps' full-screen/Stage Manager spaces",
              panel.collectionBehavior.isSuperset(of: expectedBehavior) && panel.styleMask.contains(.nonactivatingPanel) && !panel.hidesOnDeactivate)
        model.text = "Keep this live transcript. 保留文本。"
        model.targetLanguage = "English"
        model.elapsedSeconds = 127
        model.statusDetail = "Synthetic workspace recovery fixture"
        model.copied = true
        let modes: [(String, OverlayState, Bool)] = [
            ("idle handle", .idle, false),
            ("listening", .listening, false),
            ("translation", .listening, true),
            ("transcribing", .transcribing, false),
            ("cleaning", .cleaning, false),
            ("success", .success, false),
            ("error card", .error(title: "Fixture", message: "This is synthetic."), false),
            ("copy card", .result(text: "Complete transcript. 完整文本。"), false)
        ]
        for (name, state, translating) in modes {
            model.state = state
            model.translating = translating
            panel.present()
            wait({ false }, timeout: 0.1)
            let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            // WindowServer loss is simulated independently of the panel's presentation intent.
            panel.orderOut(nil)
            notifySpaceChange()
            wait({ false }, timeout: 0.9)
            let contentPreserved = model.state == state && model.translating == translating &&
                model.text == "Keep this live transcript. 保留文本。" && model.targetLanguage == "English" &&
                model.elapsedSeconds == 127 && model.statusDetail == "Synthetic workspace recovery fixture" && model.copied
            check("\(name) recovers visibility and preserves content without taking focus",
                  onScreen() && contentPreserved && !panel.isKeyWindow &&
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID)
        }
        for _ in 0..<20 { notifySpaceChange() }
        wait({ false }, timeout: 0.9)
        check("rapid Space notifications keep one visible panel",
              onScreen() && panel.windowNumber == windowNumber && app.windows.filter { $0 is OverlayPanel }.count == panelCount)

        notifySpaceChange()
        wait({ false }, timeout: 0.1)
        panel.orderOut(nil)
        wait({ false }, timeout: 0.25)
        check("visibility recovers when lost after the initial Space notification", onScreen())
        panel.orderOut(nil)
        wait({ false }, timeout: 0.5)
        check("visibility recovers again while the simulated transition settles", onScreen())

        panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: app)
        wait({ false }, timeout: 0.9)
        let correctlyPlaced = NSScreen.screens.contains { screen in
            abs(panel.frame.midX - screen.visibleFrame.midX) < 1 &&
            abs(panel.frame.minY - (screen.visibleFrame.minY + 12)) < 1
        }
        check("display-change notification restores on-screen geometry", onScreen() && correctlyPlaced)

        notifySpaceChange()
        panel.dismiss()
        wait({ false }, timeout: 1.0)
        check("dismiss cancels pending Space recovery", !panel.isVisible)
        notifySpaceChange()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: app)
        wait({ false }, timeout: 1.0)
        check("hidden panel stays hidden after Space and display notifications", !panel.isVisible)
        return passed
    }

    private static func runOverlayCopyChecks(panel: OverlayPanel, model: OverlayModel) -> Bool {
        var passed = true
        func check(_ name: String, _ condition: Bool) {
            print("COPY LAYOUT \(condition ? "PASS" : "FAIL"): \(name)")
            passed = passed && condition
        }
        func transcriptScrollView(_ view: NSView?) -> ResultTranscriptScrollView? {
            guard let view else { return nil }
            if let scroll = view as? ResultTranscriptScrollView { return scroll }
            return view.subviews.compactMap { transcriptScrollView($0) }.first
        }
        let marker = "END OF COMPLETE TRANSCRIPT 完整文本结束"
        let paragraphs = (1...400).map { "Section \($0): Keep every word available for copying. 这段文字也需要完整保留。" }.joined(separator: "\n\n") + "\n" + marker
        let singleParagraph = String(repeating: "Long transcription 中文 English 12345 ", count: 600) + marker
        let unbroken = String(repeating: "abcdef中文", count: 1500) + marker
        for (name, text) in [("400 bilingual paragraphs", paragraphs), ("long wrapped paragraph", singleParagraph), ("unbroken long text", unbroken)] {
            model.state = .result(text: text)
            model.statusDetail = "No text field is selected. Copy your text and paste it where you want."
            model.resultWarning = ""
            model.canRetry = false
            panel.present()
            wait({ false }, timeout: 0.3)
            guard let scroll = transcriptScrollView(panel.contentView) else {
                check("\(name) exposes the native transcript view", false)
                continue
            }
            let document = scroll.transcriptView
            check("\(name) retains every character in a selectable, noneditable view", document.string == text && document.isSelectable && !document.isEditable)
            check("\(name) shows a vertical scrollbar without horizontal clipping", scroll.hasVerticalScroller && !scroll.autohidesScrollers && !scroll.hasHorizontalScroller && document.frame.width <= scroll.contentSize.width + 1)
            document.scrollRangeToVisible(NSRange(location: text.utf16.count - 1, length: 1))
            wait({ false }, timeout: 0.15)
            var endVisible = false
            if let layout = document.layoutManager, let container = document.textContainer {
                layout.ensureLayout(for: container)
                let origin = document.textContainerOrigin
                let visible = document.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
                let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
                let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                endVisible = NSMaxRange(characters) >= text.utf16.count
            }
            check("\(name) can scroll to the rendered final character", endVisible)
            check("\(name) keeps the complete card within a visible display", NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) })
            model.copied.toggle()
            wait({ false }, timeout: 0.1)
            check("\(name) Copy feedback preserves full text and scroll position", document.string == text && document.visibleRect.maxY >= document.bounds.maxY - 2)
        }
        for size in [CGSize(width: 480, height: 360), CGSize(width: 800, height: 500), CGSize(width: 1440, height: 800)] {
            let detail = String(repeating: "No text field selected. ", count: 12)
            let warning = String(repeating: "The recording is saved for retry. ", count: 12)
            let layout = ResultCardLayout(text: paragraphs,
                statusDetail: detail, warning: warning,
                canRetry: true, availableSize: size)
            check("long result with warning and Retry fits \(Int(size.width))×\(Int(size.height))", layout.panelSize.width <= size.width && layout.panelSize.height <= size.height && layout.previewHeight > 0 && layout.showsScrollHint)
            let compact = OverlayModel()
            compact.availableScreenSize = size
            compact.state = .result(text: paragraphs)
            compact.statusDetail = detail
            compact.resultWarning = warning
            compact.canRetry = true
            let host = OverlayHostingView(rootView: OverlayView(model: compact))
            host.sizingOptions = [.intrinsicContentSize]
            host.layoutSubtreeIfNeeded()
            let actual = host.fittingSize
            check("actual card content with all controls fits \(Int(size.width))×\(Int(size.height))", actual.width > 0 && actual.height > 0 && actual.width <= size.width - 24 && actual.height <= size.height - 24)
        }
        return passed
    }

    private static func runCleanup(_ text: String, inputFile: String?, reportPath: String?) -> Bool {
        let settings = Settings.shared
        let start = Date()
        let pieces = LongTextProcessing.chunks(text)
        var finished = false
        var output = text
        var fallbackCount = pieces.count
        var guardFallbackCount = 0
        var sectionChecks: [[String: Any]] = []
        var errorMessage: String?
        let task = Task { @MainActor in
            defer { finished = true }
            do {
                var context = CleanupContext(precedingText: nil, dictionary: settings.dictionaryTerms, chineseVariant: settings.chineseVariant,
                                             allowFormatting: settings.allowFormatting, spokenCommands: settings.spokenCommands,
                                             cjkSpacing: settings.cjkSpacing, customInstructions: settings.customInstructions,
                                             replacements: settings.replacements,
                                             rewriteStyle: settings.dictationMode == .rewrite ? .full : .light,
                                             rewritePromptOverride: settings.rewritePromptOverride)
                context.compact = settings.compactPrompt && settings.dictationMode != .rewrite
                if settings.dictationMode != .rewrite {
                    let decision = CleanupPolicy.decide(raw: text, cjkSpacing: settings.cjkSpacing, spokenCommands: settings.spokenCommands)
                    print("cleanup: policy \(decision.needsModel ? "needs the model" : "would skip the model in the app") (\(decision.reason)); prompt \(context.compact ? "compact" : "full"); priority \(settings.openAIPriorityTier ? "on" : "off")")
                }
                let result = try await LongTextProcessing.cleanup(text, context: context, settings: settings, inspectSection: { index, raw, proposed, accepted, reason in
                    sectionChecks.append(["section": index, "original": raw, "proposed": proposed, "accepted": accepted, "reason": reason])
                }) { index, count in
                    print("cleanup: section \(index) of \(count)")
                }
                output = result.text
                fallbackCount = result.fallbackCount
                guardFallbackCount = result.guardFallbackCount
                errorMessage = result.lastError
            } catch { errorMessage = error.localizedDescription }
        }
        let requestsPerSection = settings.dictationMode == .rewrite ? 2.0 : 1.0
        wait({ finished }, timeout: max(60, Double(pieces.count) * (max(settings.llmTimeout, 15) * requestsPerSection + 5) + 30))
        if !finished {
            task.cancel()
            errorMessage = "Cleanup deadline exceeded; the complete original transcript was kept"
            output = text
            fallbackCount = pieces.count
        }
        let success = finished && errorMessage == nil
        let report: [String: Any] = [
            "success": success, "source": "text_file", "inputFile": inputFile as Any? ?? NSNull(),
            "model": settings.cleanupModel.resolved.rawValue, "elapsedSeconds": Date().timeIntervalSince(start),
            "inputText": text, "outputText": output, "inputCharacters": text.count, "outputCharacters": output.count,
            "chunkCount": pieces.count, "chunkInputCharacters": pieces.map(\.count), "fallbackCount": fallbackCount,
            "fullyCleaned": success && fallbackCount == 0, "guardFallbackCount": guardFallbackCount,
            "providerFallbackCount": fallbackCount - guardFallbackCount, "requiresRecovery": errorMessage != nil,
            "rewriteStyle": settings.dictationMode == .rewrite ? "full" : "light",
            "sectionChecks": sectionChecks,
            "error": errorMessage as Any? ?? NSNull(),
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            if let reportPath { try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic) }
            print(String(data: data, encoding: .utf8) ?? "")
        } catch { print("Could not write cleanup evidence: \(error.localizedDescription)"); return false }
        return success
    }

    private static func runTranscribe(path: String, options: [String]) -> Bool {
        let settings = Settings.shared
        func value(_ flag: String) -> String? {
            guard let index = options.firstIndex(of: flag), index + 1 < options.count else { return nil }
            return options[index + 1]
        }
        let realTime = options.contains("--realtime") || settings.sttEngine == .assemblyAI
        let injectAfter = value("--inject-disconnect-after").flatMap(Double.init)
        let reportPath = value("--report")
        let retry = options.contains("--retry-recovery")
        let start = Date()
        var duration: Double = 0
        var capturedSeconds: Double = 0
        var engine = settings.sttEngine.rawValue
        var transcript = ""
        var failure: String?
        var recoveryDirectory: String?
        var attempts: [[String: Any]] = []
        var faultInjected = false
        var finished = false
        var success = false
        var active: STTSession?
        var timer: Timer?
        var retryStarted = false
        var attemptStarted = Date()
        func complete(_ result: Result<String, Error>) {
            let durable = active as? DurableSTTSession
            capturedSeconds = max(capturedSeconds, durable?.capturedSeconds ?? 0)
            recoveryDirectory = durable?.recoveryURL?.path
            switch result {
            case .success(let text):
                transcript = text
                success = true
                attempts.append(["success": true, "error": NSNull(), "elapsedSeconds": Date().timeIntervalSince(attemptStarted)])
                durable?.discardRecording()
                recoveryDirectory = nil
                finished = true
            case .failure(let error):
                attempts.append(["success": false, "error": error.localizedDescription, "elapsedSeconds": Date().timeIntervalSince(attemptStarted)])
                if retry, !retryStarted, let url = durable?.recoveryURL {
                    retryStarted = true
                    do {
                        let recovery = try STTFactory.recover(directory: url, settings: settings)
                        active = recovery
                        attemptStarted = Date()
                        recovery.onFinal = complete
                        recovery.onProgress = { print("recovery: \($0)") }
                        recovery.connect()
                        return
                    } catch { failure = error.localizedDescription }
                } else { failure = error.localizedDescription }
                finished = true
            }
        }
        do {
            let session = try STTFactory.make(settings: settings)
            let reader = try PCMFileReader(url: URL(fileURLWithPath: path), sampleRate: session.sampleRate)
            duration = reader.duration
            active = session
            engine = session.engineName
            var sentBytes = 0
            var partialCount = 0
            session.onPartial = { text in
                partialCount += 1
                if partialCount == 1 || partialCount % 100 == 0 { print("partial: \(text.count) characters, \(Int(Date().timeIntervalSince(start))) seconds elapsed") }
            }
            session.onFinal = complete
            (session as? DurableSTTSession)?.onProgress = { print("progress: \($0)") }
            session.connect()
            print("engine: \(engine), audio: \(String(format: "%.3f", duration)) seconds, pacing: \(realTime ? "real time" : "4x")")
            let feed = Timer(timeInterval: realTime ? 0.1 : 0.025, repeats: true) { tick in
                guard !finished else { tick.invalidate(); return }
                do {
                    if let pcm = try reader.nextChunk() {
                        session.sendAudio(pcm)
                        sentBytes += pcm.count
                        if let injectAfter, !faultInjected, Double(sentBytes) / 2 / session.sampleRate >= injectAfter {
                            (session as? DurableSTTSession)?.injectDisconnect()
                            faultInjected = true
                            print("fault: injected transport disconnect after \(Double(sentBytes) / 2 / session.sampleRate) captured seconds")
                        }
                    } else {
                        tick.invalidate()
                        session.finish()
                    }
                } catch {
                    tick.invalidate()
                    session.cancel()
                    complete(.failure(error))
                }
            }
            timer = feed
            RunLoop.main.add(feed, forMode: .common)
            // Include actual audio time and a full possible replay, plus bounded finalization.
            wait({ finished }, timeout: max(180, duration * (realTime ? 2 : 1) + 180))
            if !finished {
                timer?.invalidate()
                active?.cancel()
                (active as? DurableSTTSession)?.checkpointRecording()
                recoveryDirectory = (active as? DurableSTTSession)?.recoveryURL?.path
                capturedSeconds = (active as? DurableSTTSession)?.capturedSeconds ?? capturedSeconds
                failure = "CLI deadline exceeded; saved recording retained"
            }
        } catch { failure = error.localizedDescription }
        let report: [String: Any] = [
            "success": success, "engine": engine, "source": "audio_file", "inputFile": URL(fileURLWithPath: path).standardizedFileURL.path,
            "audioDurationSeconds": duration, "capturedAudioSeconds": capturedSeconds, "elapsedSeconds": Date().timeIntervalSince(start),
            "transcript": transcript, "error": failure as Any? ?? NSNull(), "recoveryDirectory": recoveryDirectory as Any? ?? NSNull(),
            "realTime": realTime, "faultInjected": faultInjected, "attempts": attempts,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            if let reportPath { try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic) }
            print(String(data: data, encoding: .utf8) ?? "")
        } catch { print("Could not write evidence report: \(error.localizedDescription)"); return false }
        return success
    }

}

enum SelfTest {
    static func run() -> Bool {
        var failures = 0
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            print((cond ? "PASS " : "FAIL ") + name + (cond || detail.isEmpty ? "" : " — " + detail))
            if !cond { failures += 1 }
        }

        let l1 = LocalCleanup.light("um so I think we should uh ship it, hmm, on friday", cjkSpacing: true)
        check("english fillers removed", l1 == "So I think we should ship it, on friday", l1)
        let d1 = CleanupPolicy.decide(raw: "I have a meeting with Kevin at 3 p.m., and we need to discuss the Q3 roadmap.", cjkSpacing: true, spokenCommands: true)
        check("policy: clean sentence skips the model", !d1.needsModel, d1.reason)
        let d2 = CleanupPolicy.decide(raw: "um so I think we should uh ship it on friday", cjkSpacing: true, spokenCommands: true)
        check("policy: fillers need the model", d2.needsModel, d2.reason)
        let d3 = CleanupPolicy.decide(raw: "我今天下午三点要跟 Kevin 开会，然后我们要 discuss 一下 Q3 的 roadmap。", cjkSpacing: true, spokenCommands: true)
        check("policy: clean chinese sentence skips the model", !d3.needsModel, d3.reason)
        let d4 = CleanupPolicy.decide(raw: "please send it to alice at gmail dot com", cjkSpacing: true, spokenCommands: true)
        check("policy: spelled address needs the model", d4.needsModel, d4.reason)
        let d5 = CleanupPolicy.decide(raw: "so we talked about the roadmap and then kevin said he would handle the backend next week", cjkSpacing: true, spokenCommands: true)
        check("policy: long unpunctuated text needs the model", d5.needsModel, d5.reason)
        let d6 = CleanupPolicy.decide(raw: "Send it tomorrow, new paragraph, thanks.", cjkSpacing: true, spokenCommands: true)
        check("policy: spoken command needs the model", d6.needsModel, d6.reason)
        let d7 = CleanupPolicy.decide(raw: "Mail alice@example.com the deck.", cjkSpacing: true, spokenCommands: true)
        check("policy: existing address does not force the model", !d7.needsModel, d7.reason)
        var compactCtx = CleanupContext(precedingText: nil, dictionary: [], chineseVariant: .simplified, allowFormatting: false, spokenCommands: true, cjkSpacing: true, customInstructions: "", replacements: [])
        compactCtx.compact = true
        let compact = CleanupPrompt.system(compactCtx)
        let full = CleanupPrompt.system(CleanupContext(precedingText: nil, dictionary: [], chineseVariant: .simplified, allowFormatting: false, spokenCommands: true, cjkSpacing: true, customInstructions: "", replacements: []))
        check("compact prompt omits detailed examples while retaining shared fidelity rules",
              compact.count < full.count && compact.contains(PublicPromptDefaults.lightCleanup)
                && compact.contains(PublicPromptDefaults.punctuation)
                && !compact.contains("Examples of the expected amount of change:")
                && full.contains("Examples of the expected amount of change:"),
              "\(compact.count) vs \(full.count) chars")
        let l2 = LocalCleanup.light("嗯 那个 我今天 下午 三点 要跟 Kevin开会", cjkSpacing: true)
        check("cjk fillers + spacing", l2 == "我今天下午三点要跟 Kevin 开会", l2)
        let l3 = LocalCleanup.light("the the file is is ready", cjkSpacing: true)
        check("repeated words", l3 == "The file is ready", l3)
        let l4 = LocalCleanup.normalize("这个 feature 很好 ， but 就是有点慢 。", cjkSpacing: true)
        check("cjk punctuation spacing", l4 == "这个 feature 很好，but 就是有点慢。", l4)
        let l6 = LocalCleanup.light("um so this is uh this is a test of the the dictation system 然后呃我们看看", cjkSpacing: true)
        check("phrase stutter + glued 呃", l6 == "So this is a test of the dictation system 然后我们看看", l6)
        let l7 = LocalCleanup.light("金额是三百 额度不够", cjkSpacing: true)
        check("额 inside words is kept", l7 == "金额是三百额度不够", l7)
        let l5 = LocalCleanup.light("I like it. it is like the best", cjkSpacing: true)
        check("'like' is kept by local cleanup", l5.contains("like the best"), l5)
        check("short detection", LocalCleanup.isShort("okay") && LocalCleanup.isShort("好的") && !LocalCleanup.isShort("please send the file today"))

        let raw = "um so I think we should uh we should probably ship it on on friday no wait thursday because the demo is friday"
        let good = "So I think we should probably ship it on Thursday because the demo is Friday."
        let v1 = MeaningGuard.evaluate(raw: raw, cleaned: good, threshold: 0.35)
        check("guard accepts faithful cleanup", v1.accepted, "\(v1.ratio) \(v1.reason)")
        let para = "I believe the launch should happen Thursday since the presentation is Friday."
        let v2 = MeaningGuard.evaluate(raw: raw, cleaned: para, threshold: 0.35)
        check("guard rejects paraphrase", !v2.accepted, "\(v2.ratio)")
        let v3 = MeaningGuard.evaluate(raw: raw, cleaned: "", threshold: 0.35)
        check("guard rejects empty", !v3.accepted)
        let zhRaw = "嗯那个我今天下午三点要跟那个Kevin开会然后呃就是我们要discuss一下Q3的roadmap"
        let zhGood = "我今天下午三点要跟 Kevin 开会，然后我们要 discuss 一下 Q3 的 roadmap。"
        let v4 = MeaningGuard.evaluate(raw: zhRaw, cleaned: zhGood, threshold: 0.35)
        check("guard accepts faithful chinese cleanup", v4.accepted, "\(v4.ratio) \(v4.reason)")
        let zhBad = "我下午要和 Kevin 讨论第三季度的计划。"
        let v5 = MeaningGuard.evaluate(raw: zhRaw, cleaned: zhBad, threshold: 0.35)
        check("guard rejects chinese paraphrase", !v5.accepted, "\(v5.ratio)")
        let v6 = MeaningGuard.evaluate(raw: raw, cleaned: good + " Also, remember to email the team about it.", threshold: 0.35)
        check("guard rejects additions", !v6.accepted, "\(v6.ratio)")

        let rules = Replacements.parse("expertise a i => Expertise AI\nmy email => dictation@example.com\n那个平台 => ChatSimple\n# comment\nbad line")
        check("replacements parse", rules.count == 3, "\(rules)")
        let rep = Replacements.apply(rules, to: "Send it to my email, the Expertise A I team and 那个平台的人")
        check("replacements apply", rep == "Send it to dictation@example.com, the Expertise AI team and ChatSimple的人", rep)
        check("replacements respect word boundaries", Replacements.apply(rules, to: "myemail") == "myemail")
        check("postprocess strips output tags", CleanupPrompt.postprocess("<output>Hello there.</output>") == "Hello there.")
        check("postprocess strips quotes", CleanupPrompt.postprocess("\"Hello there.\"") == "Hello there.")
        check("prompt mentions no-translate", CleanupPrompt.system(CleanupContext(precedingText: nil, dictionary: [], chineseVariant: .simplified, allowFormatting: false, spokenCommands: true, cjkSpacing: true, customInstructions: "")).contains("Do not translate"))

        var probe = InsertionTarget()
        check("no element is not editable", !TextInserter.isEditableTarget(probe))
        probe.element = AXUIElementCreateSystemWide()
        probe.role = "AXTextField"
        check("text field is editable", TextInserter.isEditableTarget(probe))
        probe.role = "AXWindow"
        check("window is not editable", !TextInserter.isEditableTarget(probe))
        probe.role = "AXGroup"
        probe.subrole = "AXContentEditable"
        check("content-editable group is editable", TextInserter.isEditableTarget(probe))

        var t = InsertionTarget()
        t.charBefore = "d"
        check("spacing after word", TextInserter.applySpacing("Hello", target: t, cjkSpacing: true) == " hello")
        t.charBefore = "。"
        check("no space after cjk punct", TextInserter.applySpacing("我们", target: t, cjkSpacing: true) == "我们")
        t.charBefore = "字"
        check("space between cjk and latin", TextInserter.applySpacing("Kevin", target: t, cjkSpacing: true) == " Kevin")
        t.charBefore = "."
        check("space + keep capital after period", TextInserter.applySpacing("Next", target: t, cjkSpacing: true) == " Next")
        t.charBefore = "\n"
        check("nothing after newline", TextInserter.applySpacing("Next", target: t, cjkSpacing: true) == "Next")

        PersistenceRegressionTests.run(check: check)
        PipelineRegressionTests.run(check: check)
        InsertionFocusRegressionTests.run(check: check)
        PunctuationRegressionTests.run(check: check)
        OnboardingRegressionTests.run(check: check)
        HostedServiceRegressionTests.run(check: check)
        ReliabilityRegressionTests.run(check: check)
        AudioCaptureRegressionTests.run(check: check)
        CleanupConcurrencyRegressionTests.run(check: check)
        UsageStatisticsRegressionTests.run(check: check)
        HotkeyRegressionTests.run(check: check)
        ShortcutPreferenceRegressionTests.run(check: check)
        UpdaterRegressionTests.run(check: check)
        CleanupRegressionTests.run(check: check)
        RewriteRegressionTests.run(check: check)
        PromptModelRegressionTests.run(check: check)
        AudioSilenceMonitorTests.run(check: check)
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0
    }
}


enum CleanupBench {
    struct Config { let label: String; let model: String; let prediction: Bool; let priority: Bool; let compactPrompt: Bool }

    static let compactSystem = """
    You clean up a raw speech-to-text transcript from a speaker of Mandarin Chinese and English. Return only the cleaned text: remove filler sounds (um, uh, 嗯, 呃, 那个 when filler), stutters and false starts (keep the corrected version), add punctuation (Chinese punctuation for Chinese, English for English), format numbers and emails as typed. Never paraphrase, reorder, translate, or add words; keep mixed languages mixed. No quotes, no explanations.
    """

    static func run() {
        let settings = Settings.shared
        guard let key = Keychain.apiKey("openai") else { print("no OpenAI key saved"); return }
        let samples = [
            "um so I think we should uh we should probably ship it on on friday no wait thursday because the demo is friday 然后呃那个我们要 discuss 一下 Q3 的 roadmap",
            "okay so basically the the api returns like a four oh four when when the user id is is missing which is uh which is wrong it should be a four hundred and also 嗯我觉得我们需要在下周之前把那个 onboarding 的流程改一下因为现在用户 sign up 之后呃看不到任何提示 然后 Kevin 说他会负责 backend 的部分 我来负责 frontend 我们周三再 sync 一次",
        ]
        let ctx = CleanupContext(precedingText: nil, dictionary: settings.dictionaryTerms, chineseVariant: settings.chineseVariant,
                                 allowFormatting: settings.allowFormatting, spokenCommands: settings.spokenCommands,
                                 cjkSpacing: settings.cjkSpacing, customInstructions: settings.customInstructions,
                                 replacements: settings.replacements,
                                 rewritePromptOverride: settings.rewritePromptOverride)
        let fullSystem = CleanupPrompt.system(ctx)
        let configs = [
            Config(label: "luna (current)", model: "gpt-5.6-luna", prediction: false, priority: false, compactPrompt: false),
            Config(label: "luna compact + priority", model: "gpt-5.6-luna", prediction: false, priority: true, compactPrompt: true),
            Config(label: "gpt-4.1-mini + prediction", model: "gpt-4.1-mini", prediction: true, priority: false, compactPrompt: false),
            Config(label: "4.1-mini compact + prediction", model: "gpt-4.1-mini", prediction: true, priority: false, compactPrompt: true),
            Config(label: "gpt-4.1-nano + prediction", model: "gpt-4.1-nano", prediction: true, priority: false, compactPrompt: false),
        ]
        var done = false
        Task {
            for (i, sample) in samples.enumerated() {
                print("\n=== sample \(i + 1): \(sample.count) chars ===")
                for cfg in configs {
                    for attempt in 1...2 {
                        let r = await request(cfg: cfg, key: key, base: settings.openAIBaseURL, system: cfg.compactPrompt ? compactSystem : fullSystem, transcript: sample)
                        switch r {
                        case .success(let (ttft, total, text)):
                            let verdict = MeaningGuard.evaluate(raw: sample, cleaned: text, threshold: settings.guardStrictness.threshold)
                            print(String(format: "%-28@ run %d  first token %4d ms  total %4d ms  guard %@  → %@", cfg.label as NSString, attempt, ttft, total, verdict.accepted ? "ok " : "REJ", String(text.prefix(70)) as NSString))
                        case .failure(let e):
                            print("\(cfg.label) run \(attempt): \(e.localizedDescription.prefix(120))")
                        }
                    }
                }
            }
            done = true
        }
        let deadline = Date().addingTimeInterval(300)
        while !done && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    static func request(cfg: Config, key: String, base: String, system: String, transcript: String) async -> Result<(Int, Int, String), Error> {
        var body: [String: Any] = [
            "model": cfg.model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": "<transcript>\(transcript)</transcript>\nReturn only the cleaned transcript."]],
            "stream": true,
        ]
        if !cfg.prediction { body["max_completion_tokens"] = 1200 }   // rejected by Predicted Outputs
        if cfg.model.hasPrefix("gpt-5") { body["reasoning_effort"] = "none" }
        if cfg.prediction { body["prediction"] = ["type": "content", "content": transcript] }
        if cfg.priority { body["service_tier"] = "priority" }
        var req = URLRequest(url: URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let start = Date()
        var firstToken: Date?
        var text = ""
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code >= 300 {
                var errBody = ""
                for try await line in bytes.lines { errBody += line }
                return .failure(LLMError.http(code, errBody))
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = line.dropFirst(6)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let piece = delta["content"] as? String, !piece.isEmpty else { continue }
                if firstToken == nil { firstToken = Date() }
                text += piece
            }
        } catch {
            return .failure(error)
        }
        let end = Date()
        let ttft = Int(((firstToken ?? end).timeIntervalSince(start)) * 1000)
        return .success((ttft, Int(end.timeIntervalSince(start) * 1000), CleanupPrompt.postprocess(text)))
    }
}
