import AppKit

/// Offline AppKit integration checks: the production controller and overlay callbacks run,
/// while injected providers and generated PCM prevent microphone, network, or insertion work.
enum ControllerRegressionTests {
    static func run() -> Bool {
        var failures = 0
        var checks = 0
        func check(_ name: String, _ passed: Bool) {
            checks += 1
            if !passed { failures += 1 }
            print("\(passed ? "PASS" : "FAIL") controller: \(name)")
        }
        var controllers: [DictationController] = []
        var played: [Sounds.Kind] = []
        func controller(doubleTap: Bool = true, cleanupClient: LLMClient? = nil,
                        insertionHandler: ((String, InsertionTarget, Bool) throws -> String)? = nil,
                        _ factory: @escaping () throws -> STTSession) -> DictationController {
            let instance = DictationController(sessionFactory: factory, soundPlayer: { played.append($0) }, doubleTapEnabled: { doubleTap }, cleanupClient: cleanupClient,
                                               targetReader: { InsertionTarget() }, initialApplicationReader: { InsertionTarget() }, insertionHandler: insertionHandler)
            instance.useMockSTT = true
            instance.dryRun = true
            controllers.append(instance)
            return instance
        }
        defer {
            for instance in controllers {
                instance.handleAppTermination()
                instance.panel.dismiss()
            }
        }
        func silentIdle(_ instance: DictationController) -> Bool {
            instance.phase == .idle && instance.overlay.state == .idle && instance.lastError == nil
                && instance.lastRaw == nil && instance.lastInserted == nil
                && instance.successfulInsertionCount == 0 && !played.contains(.error)
        }

        for result: Result<String, Error> in [.success(""), .success(" \n\t "), .failure(STTError.noAudio)] {
            played.removeAll()
            let provider = Fixture()
            let instance = controller { provider }
            instance.start(mode: .verbatim)
            check("fixture starts actual recording lifecycle", instance.phase == .recording)
            provider.onPartial?("temporary partial")
            instance.finish()
            provider.onFinal?(result)
            pump()
            check("empty/no-audio finish resets silently without an error card or error cue", silentIdle(instance))
            check("empty finish clears preview and leaves no completion work", instance.overlay.text.isEmpty && provider.cancelCount > 0)
            instance.panel.dismiss()
        }

        let errorProvider = Fixture()
        let errorController = controller { errorProvider }
        errorController.start(mode: .verbatim)
        errorController.finish()
        errorProvider.onFinal?(.failure(STTError.connection("offline fixture failure")))
        check("provider failure is immediately idle with a dismissible error card", errorController.phase == .idle && errorController.overlay.state.isCard)
        errorController.overlay.onDismiss?()
        check("actual Dismiss callback clears the error and returns to idle", errorController.phase == .idle && errorController.overlay.state == .idle && errorController.lastError == nil)
        errorController.start(mode: .verbatim)
        errorController.finish()
        errorProvider.onFinal?(.failure(STTError.connection("second fixture failure")))
        check("Escape dismisses a real error card", errorController.handleHotkey(.escape) && errorController.overlay.state == .idle && errorController.lastError == nil)
        errorController.panel.dismiss()

        for finishing in [false, true] {
            let provider = Fixture()
            let instance = controller { provider }
            instance.start(mode: .verbatim)
            if finishing { instance.finish() }
            instance.overlay.onCancel?()
            check("Cancel stops \(finishing ? "finishing" : "recording") without an error card", instance.phase == .idle && instance.overlay.state == .idle && instance.lastError == nil && provider.cancelCount > 0)
            instance.panel.dismiss()
        }

        let staleProvider = Fixture()
        let currentProvider = Fixture()
        var next = 0
        let generationController = controller {
            defer { next += 1 }
            return next == 0 ? staleProvider : currentProvider
        }
        generationController.start(mode: .verbatim)
        let staleFinal = staleProvider.onFinal
        let stalePartial = staleProvider.onPartial
        generationController.finish()
        // Queue real process(raw:) work, then cancel it before MainActor can run it.
        staleFinal?(.success("This stale text must never be inserted."))
        generationController.cancel(reason: "offline regression")
        generationController.start(mode: .verbatim)
        stalePartial?("old preview")
        staleFinal?(.success("This delayed completion must also be ignored."))
        pump()
        check("a late provider final cannot finish a new recording", generationController.phase == .recording && generationController.overlay.state == .listening)
        check("canceled queued processing never inserts or overwrites the new preview", generationController.lastInserted == nil && generationController.successfulInsertionCount == 0 && generationController.overlay.text.isEmpty)
        generationController.cancel(reason: "offline teardown")
        generationController.panel.dismiss()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FnDictate-controller-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // Hold the original synthetic AX identity off the main thread. These checks
        // exercise actual controller phase changes without querying a running app.
        for scenario in ["finishing", "processing", "changed-field", "timeout", "changed-app"] {
            let provider = Fixture()
            let focus = FocusFixture()
            var captured = focus.read()
            if scenario == "changed-app" { captured.processIdentifier = 1_000_099 }
            let capture = DelayedTargetCapture(target: captured)
            var beganBeforeProviderSetup = false
            var insertionAttempts = 0
            var delivered: String?
            var deliveredToOriginalField = false
            let transcript = "Keep the original field and complete sentence."
            let instance = DictationController(sessionFactory: {
                beganBeforeProviderSetup = capture.waitUntilStarted()
                return provider
            }, soundPlayer: { _ in }, recoveryRoot: root.appendingPathComponent("capture-\(scenario)"),
               targetReader: { capture.read() }, initialApplicationReader: { focus.applicationMetadata() },
               targetCaptureWaitTimeout: scenario == "timeout" ? 0.1 : 0.5,
               insertionHandler: { text, original, _ in
                insertionAttempts += 1
                deliveredToOriginalField = focus.isOriginal(original)
                guard TextInserter.matchesOriginalTarget(original, current: focus.read()) else { throw InsertionError.targetChanged }
                delivered = text
                return text
            })
            instance.useMockSTT = true
            instance.dryRun = true
            controllers.append(instance)
            instance.start(mode: .verbatim)
            instance.panel.dismiss()
            check("\(scenario) original-field lookup begins before provider setup", beganBeforeProviderSetup)
            instance.finish()
            if scenario == "finishing" {
                capture.release()
                pump(seconds: 0.04)
                check("a pending original-field reply is retained during finishing", instance.phase == .finishing && insertionAttempts == 0)
            }
            if scenario == "changed-field" { focus.changeField() }
            provider.onFinal?(.success(transcript))
            if scenario != "finishing" {
                pump(seconds: 0.04)
                check("\(scenario) processing waits for the original lookup without inserting early", instance.phase == .processing && insertionAttempts == 0)
                if scenario != "timeout" { capture.release() }
            }
            let deadline = Date().addingTimeInterval(1.5)
            while instance.phase != .idle && Date() < deadline { pump(seconds: 0.01) }
            instance.panel.dismiss()
            if scenario == "finishing" || scenario == "processing" {
                check("\(scenario) delayed original identity permits one correct insertion", instance.phase == .idle && delivered == transcript && deliveredToOriginalField && insertionAttempts == 1 && capture.readCount == 1 && !instance.overlay.state.isCard)
            } else {
                check("\(scenario) fails closed to full-text Copy without rebinding focus", instance.phase == .idle && delivered == nil && insertionAttempts == 1 && capture.readCount == 1 && instance.overlay.state == .result(text: transcript) && instance.successfulInsertionCount == 0)
                if scenario == "changed-field" {
                    check("the changed-field check still receives the original captured element", deliveredToOriginalField)
                }
                if scenario == "timeout" {
                    check("capture timeout does not invent an original field", !deliveredToOriginalField)
                    capture.release()
                    pump(seconds: 0.08)
                    check("a reply after timeout cannot insert or replace the Copy result", insertionAttempts == 1 && delivered == nil && instance.overlay.state == .result(text: transcript))
                }
            }
            instance.panel.dismiss()
        }

        do {
            let focus = FocusFixture()
            let oldCapture = DelayedTargetCapture(target: focus.read())
            let newCapture = DelayedTargetCapture(target: focus.read())
            let captures = TargetCaptureSequence([oldCapture, newCapture])
            let oldProvider = Fixture()
            let newProvider = Fixture()
            var providerIndex = 0
            var insertionAttempts = 0
            var usedNewField = false
            let instance = DictationController(sessionFactory: {
                defer { providerIndex += 1 }
                return providerIndex == 0 ? oldProvider : newProvider
            }, soundPlayer: { _ in }, recoveryRoot: root.appendingPathComponent("capture-cancel"),
               targetReader: { captures.read() }, initialApplicationReader: { focus.applicationMetadata() },
               targetCaptureWaitTimeout: 0.5, insertionHandler: { text, original, _ in
                insertionAttempts += 1
                usedNewField = TextInserter.matchesOriginalTarget(original, current: focus.read())
                guard usedNewField else { throw InsertionError.targetChanged }
                return text
            })
            instance.useMockSTT = true
            instance.dryRun = true
            controllers.append(instance)
            instance.start(mode: .verbatim)
            instance.panel.dismiss()
            check("cancel-generation fixture starts its first original lookup", oldCapture.waitUntilStarted())
            instance.finish()
            oldProvider.onFinal?(.success("Canceled text must not be sent."))
            pump(seconds: 0.04)
            check("cancel-generation fixture reaches the pending-target insertion wait", instance.phase == .processing && insertionAttempts == 0)
            instance.cancel(reason: "cancel pending original-field lookup")
            focus.changeField()
            newCapture.replaceBeforeRead(with: focus.read())
            instance.start(mode: .verbatim)
            instance.panel.dismiss()
            check("new generation starts an independent original lookup", newCapture.waitUntilStarted())
            newCapture.release()
            pump(seconds: 0.04)
            oldCapture.release()
            pump(seconds: 0.04)
            check("canceled target reply cannot finish or insert into the new recording", instance.phase == .recording && insertionAttempts == 0)
            instance.finish()
            newProvider.onFinal?(.success("Only the new recording is sent."))
            let deadline = Date().addingTimeInterval(1.5)
            while instance.phase != .idle && Date() < deadline { pump(seconds: 0.01) }
            check("canceled original capture cannot overwrite the new generation's field", instance.phase == .idle && insertionAttempts == 1 && usedNewField && instance.lastInserted == "Only the new recording is sent.")
            instance.panel.dismiss()
        }

        do {
            let provider = Fixture()
            let cleanup = PromptSnapshotFixture()
            var savedPrompt = "Use the first saved rewrite style."
            let instance = DictationController(sessionFactory: { provider }, soundPlayer: { _ in }, cleanupClient: cleanup,
                                               rewritePromptReader: { savedPrompt }, recoveryRoot: root.appendingPathComponent("prompt-snapshot"),
                                               targetReader: { InsertionTarget() }, initialApplicationReader: { InsertionTarget() },
                                               insertionHandler: { text, _, _ in text })
            instance.useMockSTT = true
            instance.dryRun = true
            controllers.append(instance)
            for index in 0..<2 {
                instance.start(mode: .rewrite)
                instance.panel.dismiss()
                if index == 0 { savedPrompt = "Use the next saved rewrite style." }
                instance.finish()
                provider.onFinal?(.success(PromptSnapshotFixture.transcript))
                let deadline = Date().addingTimeInterval(1.5)
                while instance.phase != .idle && Date() < deadline { pump(seconds: 0.01) }
                instance.panel.dismiss()
            }
            check("saving a rewrite prompt during recording does not alter that recording", cleanup.prompts.count == 2 && cleanup.prompts[0].contains("Use the first saved rewrite style.") && !cleanup.prompts[0].contains("Use the next saved rewrite style."))
            check("the next dictation uses the newly saved rewrite prompt", cleanup.prompts.count == 2 && cleanup.prompts[1].contains("Use the next saved rewrite style.") && !cleanup.prompts[1].contains("Use the first saved rewrite style.") && instance.lastInserted == PromptSnapshotFixture.transcript)
        }

        for interruption in ["monitor", "stall", "cancel"] {
            let first = Fixture()
            let durable = DurableSTTSession(first: first, archiveRoot: root, factory: { Fixture() })
            let instance = controller { durable }
            instance.start(mode: .verbatim)
            // Actual generated PCM travels through controller -> durable archive; no microphone.
            pump(seconds: 0.16)
            let directory = durable.recoveryURL
            check("controller fixture journals PCM before interruption", directory != nil && durable.capturedSeconds > 0)
            if interruption == "monitor" { _ = instance.handleHotkey(.monitorInterrupted) }
            else if interruption == "stall" {
                instance.checkCaptureHealth()
                check("silent PCM callbacks keep the recording alive", instance.phase == .recording)
                instance.checkCaptureHealth(now: ProcessInfo.processInfo.systemUptime + 6)
            } else { instance.overlay.onCancel?() }
            pump()
            if interruption != "cancel" {
                let archive = directory.flatMap { try? RecordingArchive(directory: $0) }
                check("\(interruption) interruption preserves captured audio instead of canceling it", instance.phase == .idle && instance.overlay.state.isCard && (archive?.manifest.byteCount ?? 0) > 0)
                instance.overlay.onDismiss?()
                check("dismissing interruption leaves the saved recording intact", directory.map { FileManager.default.fileExists(atPath: $0.path) } == true)
            } else {
                check("explicit Cancel removes only that test recording", instance.phase == .idle && !instance.overlay.state.isCard && directory.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
            }
            instance.panel.dismiss()
        }
        let gestureFirst = Fixture()
        let gestureSession = DurableSTTSession(first: gestureFirst, archiveRoot: root, factory: { Fixture() })
        var gestureSessionCount = 0
        let gestureController = controller { gestureSessionCount += 1; return gestureSession }
        _ = gestureController.handleHotkey(.triggerDown(.fn), timestamp: 100)
        _ = gestureController.handleHotkey(.triggerUp(.fn), timestamp: 100.08)
        pump(seconds: 0.12)
        let firstDirectory = gestureSession.recoveryURL
        let firstBytes = gestureSession.capturedSeconds
        check("first Fn tap starts ordinary hands-free dictation immediately", gestureController.phase == .recording && gestureController.handsFree && !gestureController.translating && firstBytes > 0)
        _ = gestureController.handleHotkey(.triggerDown(.fn), timestamp: 100.2)
        _ = gestureController.handleHotkey(.triggerUp(.fn), timestamp: 100.26)
        pump(seconds: 0.12)
        check("double Fn promotes the same recording without discarding its audio", gestureController.phase == .recording && gestureController.translating && gestureController.handsFree && gestureSessionCount == 1 && gestureSession.recoveryURL == firstDirectory && gestureSession.capturedSeconds >= firstBytes && gestureFirst.cancelCount == 0)
        let translationMetadata = firstDirectory.flatMap { try? RecordingArchive(directory: $0).manifest }
        check("double Fn saves the selected translation target with captured audio", translationMetadata?.translationTarget == gestureController.settings.translationLanguage)
        _ = gestureController.handleHotkey(.triggerDown(.fn), timestamp: 100.3)
        check("third Fn press finishes translation even inside the original double-tap window", gestureController.phase == .finishing && gestureController.translating)
        gestureController.cancel(reason: "gesture teardown")
        gestureController.panel.dismiss()

        // Replay the raw Globe companion pair through the production parser, rather
        // than assuming every physical Fn press produces only a flagsChanged pair.
        let companionProvider = Fixture()
        var companionSessions = 0
        let companionController = controller { companionSessions += 1; return companionProvider }
        var rawState = HotkeyState()
        func rawFn(_ type: CGEventType, _ code: Int64, _ flags: UInt64, _ timestamp: TimeInterval) {
            let decision = rawState.process(type: type, keyCode: code, flags: flags, triggerKeys: [.fn], intercept: true,
                                            wantsKeyDowns: companionController.phase != .idle)
            for event in decision.events { _ = companionController.handleHotkey(event, timestamp: timestamp) }
        }
        rawFn(.flagsChanged, 63, 0x0080_0000, 150)
        rawFn(.flagsChanged, 63, 0, 150.06)
        rawFn(.keyDown, 179, 0, 150.061)
        rawFn(.keyUp, 179, 0, 150.062)
        rawFn(.flagsChanged, 63, 0x0080_0000, 150.16)
        rawFn(.flagsChanged, 63, 0, 150.22)
        rawFn(.keyDown, 179, 0, 150.221)
        rawFn(.keyUp, 179, 0, 150.222)
        check("raw Fn and paired Globe events keep the same recording in translation", companionController.phase == .recording && companionController.translating && companionController.handsFree && companionSessions == 1 && companionProvider.cancelCount == 0)
        rawFn(.flagsChanged, 63, 0x0080_0000, 151)
        check("third raw Fn press finishes the translated recording", companionController.phase == .finishing && companionController.translating && companionProvider.finishCount == 1)
        companionController.cancel(reason: "Globe fixture teardown")
        companionController.panel.dismiss()

        for scenario in ["late", "first-hold", "second-hold", "other-trigger", "typed-between", "disabled"] {
            let provider = Fixture()
            let instance = controller(doubleTap: scenario != "disabled") { provider }
            let key: TriggerKey = scenario == "other-trigger" ? .rightOption : .fn
            _ = instance.handleHotkey(.triggerDown(key), timestamp: 200)
            _ = instance.handleHotkey(.triggerUp(key), timestamp: scenario == "first-hold" ? 200.8 : 200.05)
            if scenario != "first-hold" {
                if scenario == "typed-between" { _ = instance.handleHotkey(.otherKeyDown(0), timestamp: 200.1) }
                _ = instance.handleHotkey(.triggerDown(key), timestamp: scenario == "late" ? 201 : 200.2)
                if scenario == "second-hold" { _ = instance.handleHotkey(.triggerUp(key), timestamp: 201) }
            }
            check("Fn gesture \(scenario) preserves finish semantics", instance.phase == .finishing && instance.translating == (scenario == "second-hold"))
            instance.cancel(reason: "gesture teardown")
            instance.panel.dismiss()
        }

        for (mode, providerFails) in [(DictationMode.verbatim, false), (.light, false), (.clean, false), (.rewrite, false), (.clean, true), (.rewrite, true)] {
            let provider = Fixture()
            let cleanup = CleanupRegressionTests.Fixture(failure: providerFails ? .http(503, "offline email fixture") : nil)
            let instance = controller(cleanupClient: cleanup) { provider }
            instance.start(mode: mode)
            instance.finish()
            provider.onFinal?(.success("Email is E X A M P L E at gmail dot com."))
            let deadline = Date().addingTimeInterval(3)
            while instance.phase != .idle && Date() < deadline { pump(seconds: 0.01) }
            let expectedEmail = mode == .verbatim ? "Email is E X A M P L E at gmail dot com." : "Email is example@gmail.com."
            check("email \(mode == .verbatim ? "stays as transcribed" : "formatting survives") \(mode.rawValue)\(providerFails ? " provider fallback" : "")", instance.phase == .idle && instance.lastInserted == expectedEmail)
            check("email fixture never inserts into a real application", instance.successfulInsertionCount == 0)
            instance.panel.dismiss()
        }

        do {
            let provider = Fixture()
            let cleanup = CleanupRegressionTests.Fixture()
            let instance = controller(cleanupClient: cleanup) { provider }
            let raw = "Um um 保留,原样.  And  repeated repeated words.\nS A R A at gmail dot com"
            instance.start(mode: .verbatim)
            instance.finish()
            provider.onFinal?(.success(raw))
            let deadline = Date().addingTimeInterval(3)
            while instance.phase != .idle && Date() < deadline { pump(seconds: 0.01) }
            check("No rewrite keeps punctuation, spaces, repetitions and spoken email text exactly", instance.lastInserted == raw)
            check("No rewrite never calls the rewrite model", cleanup.calls == 0)
            instance.panel.dismiss()
        }

        for actualFailure in [false, true] {
            let provider = Fixture()
            let durable = DurableSTTSession(first: provider, archiveRoot: root, factory: { Fixture() })
            let cleanup = actualFailure ? CleanupRegressionTests.Fixture(failure: .outputLimit)
                : CleanupRegressionTests.Fixture(response: "Call it Expertise Dictation.")
            let instance = controller(cleanupClient: cleanup) { durable }
            instance.start(mode: .clean)
            pump(seconds: 0.16)
            let directory = durable.recoveryURL
            instance.finish()
            pump()
            provider.onFinal?(.success(CleanupRegressionTests.disfluent))
            let deadline = Date().addingTimeInterval(3)
            while instance.phase != .idle && Date() < deadline { pump(seconds: 0.01) }
            check("cleanup \(actualFailure ? "provider failure" : "guard fallback") preserves the complete spoken text", cleanup.calls == 1 && MeaningGuard.tokens(instance.lastInserted ?? "") == MeaningGuard.tokens(CleanupRegressionTests.disfluent))
            if actualFailure {
                check("actual cleanup provider failure still shows a recoverable warning", instance.phase == .idle && instance.overlay.state.isCard && instance.lastError != nil && directory.map { FileManager.default.fileExists(atPath: $0.path) } == true)
            } else {
                check("benign cleanup guard fallback completes without a warning or saved-audio burden", instance.phase == .idle && instance.overlay.state == .success && instance.lastError == nil && directory.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
            }
            check("offline cleanup never counts as actual insertion", instance.successfulInsertionCount == 0)
            instance.panel.dismiss()
        }

        for spoken in [false, true] {
            played.removeAll()
            let provider = Fixture()
            let instance = controller { provider }
            instance.start(mode: .verbatim)
            if spoken { provider.onPartial?("A quiet sentence is still captured.") }
            let now = ProcessInfo.processInfo.systemUptime
            instance.checkSilence(now: now + 11.9)
            check("silence does not stop \(spoken ? "spoken" : "initial") capture before twelve seconds", instance.phase == .recording)
            instance.checkSilence(now: now + 12.1)
            check("twelve seconds of silence finalizes instead of canceling captured audio", instance.phase == .finishing && provider.finishCount == 1 && provider.cancelCount == 0)
            provider.onFinal?(.success(spoken ? "A quiet sentence is still captured." : ""))
            pump()
            if spoken {
                check("silence after speech sends the final transcript", instance.phase == .idle && instance.lastInserted == "A quiet sentence is still captured." && instance.lastError == nil && !instance.overlay.state.isCard)
            } else {
                check("initial silence closes quietly after the provider confirms no speech", silentIdle(instance))
            }
            instance.panel.dismiss()
        }

        for scenario in ["accepted-short", "negation-veto", "verifier-failure"] {
            let provider = Fixture()
            let durable = DurableSTTSession(first: provider, archiveRoot: root, factory: { Fixture() })
            let raw = scenario == "negation-veto" ? "Do not publish the draft." : "Thanks."
            let proposal = scenario == "negation-veto" ? "Publish the draft." : "Thank you."
            let cleanup = CleanupRegressionTests.RewriteFixture(response: proposal, verdict: scenario == "negation-veto" ? "FAIL" : "PASS",
                                                                 failure: scenario == "verifier-failure" ? .outputLimit : nil)
            let instance = controller(cleanupClient: cleanup) { durable }
            instance.start(mode: .rewrite)
            pump(seconds: 0.16)
            let directory = durable.recoveryURL
            instance.finish()
            pump()
            provider.onFinal?(.success(raw))
            let deadline = Date().addingTimeInterval(3)
            while instance.phase != .idle && Date() < deadline { pump(seconds: 0.01) }
            check("full rewrite \(scenario) uses cleanup and semantic verification even for short speech", cleanup.cleanupCalls == 1 && cleanup.verificationCalls == 1)
            let expected = scenario == "accepted-short" ? proposal : raw
            check("full rewrite \(scenario) delivers approved wording or the complete original", instance.lastInserted == expected)
            if scenario == "verifier-failure" {
                check("full rewrite verifier failure shows recovery without losing audio", instance.overlay.state.isCard && instance.lastError != nil && directory.map { FileManager.default.fileExists(atPath: $0.path) } == true)
            } else {
                check("full rewrite semantic result completes quietly", !instance.overlay.state.isCard && instance.lastError == nil && directory.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
            }
            instance.panel.dismiss()
        }

        for (name, raw, proposal) in [
            ("paragraphs", "The Mac build is ready, but we have not tested Windows. Mira is free Friday; the training date is undecided.",
             "The Mac build is ready, but we have not tested Windows.\n\nMira is free Friday. The training date is undecided."),
            ("flat bullets", "Mira reviews 12 cases by 4:30. Chen checks the installer. Do not remove the old guide.",
             "- Mira reviews 12 cases by 4:30.\n- Chen checks the installer.\n- Do not remove the old guide."),
            ("mixed-language email", "Hi Mira, 请把 review 发到 Hao.Chen+Mac@example.com，不要抄送客户。Thanks, Hao.",
             "Hi Mira,\n\n请把 review 发到 Hao.Chen+Mac@example.com，不要抄送客户。\n\nThanks, Hao.")
        ] {
            let provider = Fixture()
            let cleanup = CleanupRegressionTests.RewriteFixture(response: proposal)
            var delivered: String?
            let instance = controller(cleanupClient: cleanup, insertionHandler: { text, _, _ in delivered = text; return text }) { provider }
            instance.start(mode: .rewrite)
            instance.finish()
            provider.onFinal?(.success(raw))
            let deadline = Date().addingTimeInterval(3)
            while instance.phase != .idle && Date() < deadline { pump(seconds: 0.01) }
            check("full rewrite \(name) keeps exact layout through normalization and insertion", delivered == proposal && instance.lastInserted == proposal)
            check("full rewrite \(name) completes without a semantic round trip for a layout-only rewrite", cleanup.verificationCalls == 0 && instance.lastError == nil && !instance.overlay.state.isCard)
            instance.panel.dismiss()
        }

        do {
            let recoveryRoot = root.appendingPathComponent("silent-retry")
            let archive = try RecordingArchive(sampleRate: 24000, engine: "offline-controller-fixture", root: recoveryRoot)
            try archive.append(Data(count: 24_000))
            try archive.close()
            archive.releaseOwnership()
            let provider = Fixture()
            provider.finishResult = .success("")
            let instance = DictationController(soundPlayer: { played.append($0) }, recoveryRoot: recoveryRoot,
                                               recoveryFactory: { try DurableSTTSession(recovering: $0, factory: { provider }) },
                                               targetReader: { InsertionTarget() })
            instance.useMockSTT = true
            instance.dryRun = true
            controllers.append(instance)
            let pendingURL = instance.recoveryRecordingURLs.first
            check("silent saved recording is listed before retry", instance.recoveryAvailable && instance.recoveryRecordingURLs.count == 1 && pendingURL?.standardizedFileURL.path == archive.directory.standardizedFileURL.path)
            // Use the actual Home selection URL; FileManager's URL does not preserve the
            // directory-hint slash on the archive creator's URL, so URL == differs.
            if let pendingURL { instance.retryRecording(at: pendingURL) }
            let deadline = Date().addingTimeInterval(3)
            while instance.phase != .idle && Date() < deadline { pump(seconds: 0.01) }
            check("silent retry removes the deleted recording from Home recovery state", instance.phase == .idle && instance.overlay.state == .idle && instance.lastError == nil && !instance.recoveryAvailable && instance.recoveryRecordingURLs.isEmpty && instance.recoveryMessage == nil && !FileManager.default.fileExists(atPath: archive.directory.path))
            instance.panel.dismiss()
        } catch { check("silent retry fixture setup", false) }

        // Exercise the same terminal branches as real insertion failures. A synthetic
        // focus reader and clipboard sink avoid reading field contents or writing an
        // app, user history, or the system clipboard.
        let fullPreview = (1...80).map { "Section \($0): Keep this complete paragraph and its reference number \($0)." }.joined(separator: "\n\n")
        for scenario in ["changed-field", "insertion-unavailable", "provider-failure"] {
            played.removeAll()
            let archiveRoot = root.appendingPathComponent("preview-\(scenario)")
            let provider = Fixture()
            let durable = DurableSTTSession(first: provider, archiveRoot: archiveRoot, factory: { Fixture() })
            let focus = FocusFixture()
            var copiedTexts: [String] = []
            var clipboardAcceptsWrite = scenario != "changed-field"
            var insertionAttempts = 0
            var rejectedChangedTarget = false
            var capturedOriginalField = false
            let cleanup: LLMClient? = scenario == "provider-failure" ? CleanupRegressionTests.Fixture(failure: .outputLimit) : nil
            let instance = DictationController(sessionFactory: { durable }, soundPlayer: { played.append($0) },
                                               cleanupClient: cleanup, recoveryRoot: archiveRoot, targetReader: { focus.read() },
                                               initialApplicationReader: { focus.applicationMetadata() },
                                               insertionHandler: { _, original, _ in
                insertionAttempts += 1
                capturedOriginalField = focus.isOriginal(original)
                rejectedChangedTarget = !TextInserter.matchesOriginalTarget(original, current: focus.read())
                if scenario == "insertion-unavailable" { throw InsertionError.unavailable("Offline insertion is unavailable.") }
                throw InsertionError.targetChanged
            }, clipboardWriter: { text in copiedTexts.append(text); return clipboardAcceptsWrite })
            instance.useMockSTT = true
            instance.dryRun = true
            controllers.append(instance)
            instance.start(mode: scenario == "provider-failure" ? .rewrite : .verbatim)
            pump(seconds: 0.16)
            let directory = durable.recoveryURL
            focus.changeField()
            instance.finish()
            pump()
            provider.onFinal?(.success(fullPreview))
            let deadline = Date().addingTimeInterval(3)
            while instance.phase != .idle && Date() < deadline { pump(seconds: 0.01) }
            check("\(scenario) returns the complete long transcript in a preview", instance.phase == .idle && instance.overlay.state == .result(text: fullPreview) && instance.lastInserted == fullPreview)
            check("\(scenario) neither overwrites the clipboard nor counts a successful insertion", copiedTexts.isEmpty && insertionAttempts == 1 && capturedOriginalField && rejectedChangedTarget && instance.successfulInsertionCount == 0)
            check("\(scenario) retains captured audio until the text is received", directory.map { FileManager.default.fileExists(atPath: $0.path) } == true && instance.recoveryAvailable)
            if scenario == "changed-field" {
                check("changed focus is a neutral handoff without an error sound", instance.lastError == nil && instance.overlay.resultWarning.isEmpty && !played.contains(.error))
                // This RunLoop-driven fixture tests the model's timeout, not native
                // event dispatch. Keep its noninteractive panel off the user's screen.
                instance.panel.dismiss()
                pump(seconds: 45.5)
                check("unclaimed full-text preview survives the former 45-second dismissal deadline", instance.overlay.state == .result(text: fullPreview) && copiedTexts.isEmpty && directory.map { FileManager.default.fileExists(atPath: $0.path) } == true)
                instance.overlay.onCopy?()
                check("failed clipboard write keeps the full preview and its recovery", !instance.overlay.copied && instance.overlay.state == .result(text: fullPreview) && directory.map { FileManager.default.fileExists(atPath: $0.path) } == true)
                clipboardAcceptsWrite = true
            }
            instance.overlay.onCopy?()
            check("\(scenario) Copy receives the entire transcript including its final section", copiedTexts.last == fullPreview && instance.overlay.copied)
            if scenario == "provider-failure" {
                check("Copy preserves original audio and warning when cleanup failed", directory.map { FileManager.default.fileExists(atPath: $0.path) } == true && instance.recoveryAvailable && !instance.overlay.resultWarning.isEmpty && instance.lastError != nil)
            } else {
                check("confirmed Copy removes only the completed recording from recovery", directory.map { !FileManager.default.fileExists(atPath: $0.path) } == true && !instance.recoveryAvailable)
            }
            if scenario == "changed-field" {
                pump(seconds: 1.35)
                check("Copy leaves the preview open for review until explicitly dismissed", instance.overlay.state == .result(text: fullPreview))
            }
            instance.overlay.onDismiss?()
            check("\(scenario) preview Dismiss returns to idle", instance.overlay.state == .idle && instance.overlay.resultWarning.isEmpty)
            if scenario == "provider-failure" {
                check("preview dismissal does not discard recoverable provider-failure audio", directory.map { FileManager.default.fileExists(atPath: $0.path) } == true)
            }
            if scenario == "changed-field" {
                instance.start(mode: .verbatim)
                let beforeRepeat = insertionAttempts
                instance.repeatLastInsert()
                check("Paste Last cannot interrupt a new recording or replace its preview", instance.phase == .recording && instance.overlay.state == .listening && insertionAttempts == beforeRepeat)
                instance.cancel(reason: "preview fixture teardown")
            }
            instance.panel.dismiss()
        }

        print("CONTROLLER EVIDENCE: checks=\(checks) failures=\(failures) provider=offline-fixture microphone=false insertion=false")
        print(failures == 0 ? "ALL CONTROLLER CHECKS PASSED" : "CONTROLLER CHECKS FAILED")
        return failures == 0
    }

    private static func pump(seconds: TimeInterval = 0.08) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01))) }
    }

    private final class FocusFixture {
        private let lock = NSLock()
        private var changed = false
        private let originalElement = AXUIElementCreateApplication(1_000_001)
        private let changedElement = AXUIElementCreateApplication(1_000_002)
        private let processIdentifier: pid_t = 1_000_001
        func applicationMetadata() -> InsertionTarget {
            var target = InsertionTarget()
            target.processIdentifier = processIdentifier
            target.bundleID = "test.synthetic-editor"
            target.appName = "Synthetic editor"
            return target
        }
        func read() -> InsertionTarget {
            lock.lock(); defer { lock.unlock() }
            var target = InsertionTarget()
            target.processIdentifier = processIdentifier
            target.role = "AXTextArea"
            target.element = changed ? changedElement : originalElement
            return target
        }
        func changeField() { lock.lock(); changed = true; lock.unlock() }
        func isOriginal(_ target: InsertionTarget) -> Bool {
            guard let element = target.element else { return false }
            return CFEqual(element, originalElement)
        }
    }

    private final class DelayedTargetCapture {
        private let lock = NSLock()
        private var snapshot: InsertionTarget
        private var count = 0
        private let started = DispatchSemaphore(value: 0)
        private let ready = DispatchSemaphore(value: 0)
        init(target: InsertionTarget) { snapshot = target }
        var readCount: Int { lock.lock(); defer { lock.unlock() }; return count }
        func replaceBeforeRead(with target: InsertionTarget) {
            lock.lock(); defer { lock.unlock() }
            precondition(count == 0)
            snapshot = target
        }
        func read() -> InsertionTarget {
            lock.lock()
            count += 1
            let original = snapshot
            lock.unlock()
            started.signal()
            _ = ready.wait(timeout: .now() + 3)
            return original
        }
        func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 0.5) == .success }
        func release() { ready.signal() }
    }

    private final class TargetCaptureSequence {
        private let lock = NSLock()
        private let captures: [DelayedTargetCapture]
        private var index = 0
        init(_ captures: [DelayedTargetCapture]) { self.captures = captures }
        func read() -> InsertionTarget {
            lock.lock()
            let capture = captures[min(index, captures.count - 1)]
            index += 1
            lock.unlock()
            return capture.read()
        }
    }

    private final class PromptSnapshotFixture: LLMClient {
        static let transcript = "Please keep the complete request in this recording."
        let name = "offline-prompt-snapshot"
        var prompts: [String] = []
        func complete(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
            if system == RewriteVerification.systemPrompt { return "PASS" }
            prompts.append(system)
            return Self.transcript
        }
    }

    private final class Fixture: STTSession {
        let sampleRate: Double = 24000
        let engineName = "offline-controller-fixture"
        var onPartial: ((String) -> Void)?
        var onFinal: ((Result<String, Error>) -> Void)?
        var isUsable: Bool { true }
        var cancelCount = 0
        var finishCount = 0
        var finishResult: Result<String, Error>?
        func connect() {}
        func sendAudio(_ pcm16: Data) {}
        func finish() { finishCount += 1; if let finishResult { onFinal?(finishResult) } }
        func cancel() { cancelCount += 1 }
    }
}
