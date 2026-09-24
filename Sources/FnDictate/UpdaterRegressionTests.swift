import Foundation
import Sparkle

enum UpdaterRegressionTests {
    static func run(check: (String, Bool, String) -> Void) {
        let key = Data(repeating: 42, count: 32).base64EncodedString()
        let valid: [String: Any] = ["SUFeedURL": "https://updates.sparkle-project.org/appcast.xml",
                                    "SUPublicEDKey": key, "SUVerifyUpdateBeforeExtraction": true,
                                    "SURequireSignedFeed": true]
        func expect(_ name: String, _ value: Bool) { check("updater: " + name, value, "") }
        expect("signed HTTPS configuration accepted without network", AppUpdater.validConfiguration(valid))
        expect("unconfigured build cannot enable updates", !AppUpdater.validConfiguration([:]))
        for (name, field, value) in [
            ("HTTP rejected", "SUFeedURL", "http://updates.sparkle-project.org/appcast.xml"),
            ("embedded credentials rejected", "SUFeedURL", "https://user:secret@updates.sparkle-project.org/feed"),
            ("fragment rejected", "SUFeedURL", "https://updates.sparkle-project.org/feed#fragment"),
            ("query credentials rejected", "SUFeedURL", "https://updates.sparkle-project.org/feed?token=fixture"),
            ("placeholder host rejected", "SUFeedURL", "https://example.com/feed"),
            ("loopback host rejected", "SUFeedURL", "https://127.0.0.1/feed"),
            ("invalid public key rejected", "SUPublicEDKey", "not-base64"),
            ("short public key rejected", "SUPublicEDKey", Data(repeating: 1, count: 31).base64EncodedString())
        ] {
            var info = valid; info[field] = value
            expect(name, !AppUpdater.validConfiguration(info))
        }
        for flag in ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"] {
            var info = valid; info[flag] = false
            expect(flag + " required", !AppUpdater.validConfiguration(info))
        }
        var gate = UpdateRelaunchGate()
        var calls = 0
        expect("idle install does not need postponement", !gate.postponeIfBusy { calls += 1 })
        expect("install intent retained for termination guard", gate.installationStarted)
        gate.recordingBusy = true
        expect("active dictation postpones installation", gate.postponeIfBusy { calls += 1 })
        expect("busy gate cannot drain pending installation", gate.takeReadyInstall() == nil && calls == 0)
        gate.recordingBusy = false
        let install = gate.takeReadyInstall()
        expect("idle gate releases exactly one pending callback", install != nil && gate.takeReadyInstall() == nil)
        expect("queued installation remains pending before delivery", gate.hasPendingInstall)
        gate.recordingBusy = true
        expect("new recording before scheduled callback postpones again", gate.prepareQueuedInstall(install!) == nil && gate.hasPendingInstall && calls == 0)
        gate.recordingBusy = false
        let resumedInstall = gate.takeReadyInstall()!
        gate.prepareQueuedInstall(resumedInstall)?()
        expect("installation resumes once recording finishes", calls == 1)
        expect("duplicate queued delivery cannot install twice", gate.prepareQueuedInstall(resumedInstall) == nil && !gate.hasPendingInstall && calls == 1)
        gate.recordingBusy = true
        _ = gate.postponeIfBusy { calls += 1 }
        gate.cancel()
        gate.recordingBusy = false
        expect("aborted update clears pending relaunch", !gate.installationStarted && gate.takeReadyInstall() == nil && calls == 1)

        gate.recordingBusy = true
        _ = gate.postponeIfBusy { calls += 1 }
        gate.recordingBusy = false
        let canceledInstall = gate.takeReadyInstall()!
        gate.cancel() // The main queue already holds this ticket; cancellation must reach it.
        gate.prepareQueuedInstall(canceledInstall)?()
        expect("abort after dequeue prevents queued installation", calls == 1 && !gate.installationStarted && !gate.hasPendingInstall)

        gate.recordingBusy = true
        _ = gate.postponeIfBusy { calls += 10 }
        gate.prepareQueuedInstall(canceledInstall)?()
        expect("old cycle delivery cannot replace new pending installation", gate.hasPendingInstall && gate.installationStarted && calls == 1)
        gate.recordingBusy = false
        let nextCycleInstall = gate.takeReadyInstall()!
        gate.prepareQueuedInstall(canceledInstall)?()
        expect("old cycle delivery cannot consume new queued installation", gate.hasPendingInstall && calls == 1)
        gate.prepareQueuedInstall(nextCycleInstall)?()
        expect("new cycle still installs exactly once after stale delivery", calls == 11 && !gate.hasPendingInstall)

        gate.recordingBusy = true
        _ = gate.postponeIfBusy { calls += 100 }
        gate.recordingBusy = false
        let supersededInstall = gate.takeReadyInstall()!
        gate.recordingBusy = true
        _ = gate.postponeIfBusy { calls += 1000 }
        gate.prepareQueuedInstall(supersededInstall)?()
        gate.recordingBusy = false
        let latestInstall = gate.takeReadyInstall()!
        gate.prepareQueuedInstall(latestInstall)?()
        expect("new request supersedes queued callback without explicit abort", calls == 1011 && !gate.hasPendingInstall)
        expect("up-to-date outcome is not an error", AppUpdater.cycleStatus(for: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))) == "You're up to date.")
        expect("user cancellation is not an error", AppUpdater.cycleStatus(for: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue))) == "Update installation canceled.")
        expect("real update failure remains visible", AppUpdater.cycleStatus(for: NSError(domain: NSURLErrorDomain, code: -1009)).contains("did not complete"))
        expect("idle manual update check has no disabled explanation", AppUpdater.checkUnavailableReason(configured: true, dictationBusy: false, ready: false, installing: false, sparkleCanCheck: true) == nil)
        expect("recording explains why manual checking waits", AppUpdater.checkUnavailableReason(configured: true, dictationBusy: true, ready: false, installing: false, sparkleCanCheck: true)?.contains("Finish your dictation") == true)
        expect("concurrent check remains visibly in progress", AppUpdater.checkUnavailableReason(configured: true, dictationBusy: false, ready: false, installing: false, sparkleCanCheck: false)?.contains("already in progress") == true)
        expect("staged update uses restart status rather than another check", AppUpdater.checkUnavailableReason(configured: true, dictationBusy: false, ready: true, installing: false, sparkleCanCheck: false) == nil)
        expect("installation explains reopening instead of disabled check", AppUpdater.checkUnavailableReason(configured: true, dictationBusy: false, ready: false, installing: true, sparkleCanCheck: false)?.contains("reopen") == true)
        expect("unconfigured check gives installation guidance", AppUpdater.checkUnavailableReason(configured: false, dictationBusy: false, ready: false, installing: false, sparkleCanCheck: false)?.contains("published app") == true)
        stagedInstallChecks(expect: expect)
        inlineDraftChecks(expect: expect)
    }

    private static func inlineDraftChecks(expect: (String, Bool) -> Void) {
        let notifications = NotificationCenter()
        let drafts = InlineUpdateDrafts(notifications: notifications)
        var keyDraft: InlineUpdateDraft? = InlineUpdateDraft(drafts: drafts)
        var dictionaryDraft: InlineUpdateDraft? = InlineUpdateDraft(drafts: drafts)
        expect("new inline editors do not block restart", !drafts.hasUnsavedChanges)
        keyDraft?.setUnsaved(true)
        dictionaryDraft?.setUnsaved(true)
        expect("inline edit protection is synchronously readable", drafts.hasUnsavedChanges)
        keyDraft?.setUnsaved(false)
        expect("saving one inline draft cannot clear another editor", drafts.hasUnsavedChanges)
        keyDraft = nil
        expect("discarding a saved editor cannot clear another draft", drafts.hasUnsavedChanges)

        var state = StagedUpdateState()
        var calls = 0
        state.stage(version: "16", now: 0) { calls += 1 }
        state.setContext(dictationBusy: false, presentationBusy: false, settingsVisible: true,
                         settingsEditing: drafts.hasUnsavedChanges, now: 0)
        expect("unsaved dictionary draft blocks explicit Restart", !state.canRestart && state.takeInstallation(now: 0, userInitiated: true) == nil)
        dictionaryDraft = nil
        expect("destroying the last draft releases protection", !drafts.hasUnsavedChanges)
        state.setContext(dictationBusy: false, presentationBusy: false, settingsVisible: true,
                         settingsEditing: drafts.hasUnsavedChanges, now: 1)
        let queued = state.takeInstallation(now: 1, userInitiated: true)!
        let lateDraft = InlineUpdateDraft(drafts: drafts)
        lateDraft.setUnsaved(true)
        state.setContext(dictationBusy: false, presentationBusy: false, settingsVisible: true,
                         settingsEditing: drafts.hasUnsavedChanges, now: 1)
        expect("new inline edit before queued restart keeps the callback staged", state.prepareInstallation(queued, now: 1) == nil && calls == 0 && state.hasStagedInstall)
        state.willInstall(version: "16")
        expect("final termination snapshot protects a late inline edit", !state.canRelaunchNow)
        lateDraft.setUnsaved(false)
        state.setContext(dictationBusy: false, presentationBusy: false, settingsVisible: true,
                         settingsEditing: drafts.hasUnsavedChanges, now: 2)
        expect("saving the final inline edit allows explicit relaunch", state.canRelaunchNow)
    }

    private static func stagedInstallChecks(expect: (String, Bool) -> Void) {
        // Only pure state and local closures: never construct an updater, touch
        // NSUserDefaults, access a feed, terminate an app or execute an installer.
        var state = StagedUpdateState()
        var calls = 0
        state.beginCheck()
        expect("new check has a checking state", state.phase == .checking)
        state.found(version: "9.1")
        state.finish(.completed)
        expect("completed check retains available version, not generic success", state.phase == .available && state.version == "9.1")
        state.downloading(version: "9.1")
        expect("download progress retains version", state.phase == .downloading && state.statusText.contains("9.1"))
        state.downloaded(version: "9.1")
        state.finish(.completed)
        expect("downloaded update is not reported as installed", state.phase == .downloaded && state.statusText.contains("Preparing"))
        state.stage(version: "9.1", now: 0) { calls += 1 }
        state.finish(.completed)
        expect("completed cycle retains staged callback and version", state.phase == .ready && state.version == "9.1" && state.hasStagedInstall)
        expect("existing automatic install opt-out does not restart", state.takeInstallation(now: 100) == nil && calls == 0)
        expect("opt-out still permits an explicit restart", state.canRestart)
        state.setAutomaticInstallEnabled(true, now: 100)
        expect("enabling automatic install starts a fresh idle interval", state.takeInstallation(now: 114.9) == nil)
        state.setContext(dictationBusy: false, presentationBusy: false, settingsVisible: false, settingsEditing: false, now: 110)
        expect("identical safe context does not restart idle interval", state.takeInstallation(now: 115) != nil)
        // Re-stage supersedes the queued ticket without invoking it.
        state.stage(version: "9.2", now: 200) { calls += 1 }
        state.setContext(dictationBusy: true, presentationBusy: false, settingsVisible: false, settingsEditing: false, now: 212)
        expect("recording blocks staged auto install and manual restart", state.takeInstallation(now: 300) == nil && !state.canRestart && state.hasStagedInstall)
        state.setContext(dictationBusy: false, presentationBusy: false, settingsVisible: false, settingsEditing: false, now: 301)
        expect("finishing recording does not immediately restart", state.takeInstallation(now: 315.9) == nil)
        let first = state.takeInstallation(now: 316)!
        expect("safe idle releases one queued attempt", state.takeInstallation(now: 317) == nil && state.hasQueuedInstall)
        state.setContext(dictationBusy: false, presentationBusy: true, settingsVisible: false, settingsEditing: false, now: 317)
        expect("Copy card appearing before delivery preserves handler without invoking it", state.prepareInstallation(first, now: 317) == nil && state.hasStagedInstall && calls == 0)
        state.setContext(dictationBusy: false, presentationBusy: false, settingsVisible: false, settingsEditing: false, now: 320)
        let resumed = state.takeInstallation(now: 335)!
        state.prepareInstallation(resumed, now: 335)?()
        expect("staged busy idle resumes exactly once", calls == 1 && state.phase == .installing)
        expect("duplicate queued delivery cannot repeat staged handler", state.prepareInstallation(resumed, now: 336) == nil && state.takeInstallation(now: 400) == nil && calls == 1)
        expect("automatic install final guard allows safe context", state.canRelaunchNow)
        state.setContext(dictationBusy: true, presentationBusy: false, settingsVisible: false, settingsEditing: false, now: 400)
        expect("late dictation blocks final relaunch", !state.canRelaunchNow)
        state.terminationCancelled(now: 400)
        expect("cancelled termination preserves ready handler for a later safe attempt", state.phase == .ready && state.hasStagedInstall && !state.canRestart)
        state.setContext(dictationBusy: false, presentationBusy: false, settingsVisible: false, settingsEditing: false, now: 410)
        expect("cancelled termination never immediately loops", state.takeInstallation(now: 424.9) == nil)
        let retry = state.takeInstallation(now: 425)!
        state.prepareInstallation(retry, now: 425)?()
        expect("documented retry after cancelled termination runs once", calls == 2 && state.takeInstallation(now: 450) == nil)

        for (name, presentation, visible, editing) in [
            ("result or recovery controls", true, false, false),
            ("settings window", false, true, false),
            ("editing sheet", false, false, true)
        ] {
            var busy = StagedUpdateState()
            busy.setAutomaticInstallEnabled(true, now: 0)
            busy.stage(version: "9.3", now: 0) { calls += 100 }
            busy.setContext(dictationBusy: false, presentationBusy: presentation, settingsVisible: visible, settingsEditing: editing, now: 10)
            expect(name + " blocks automatic restart", busy.takeInstallation(now: 50) == nil && busy.hasStagedInstall)
            let explicit = busy.takeInstallation(now: 50, userInitiated: true)
            if visible {
                expect("Restart action bypasses only window visibility", explicit != nil)
                busy.prepareInstallation(explicit!, now: 50)?()
                expect("explicit Restart can relaunch from Preferences", busy.canRelaunchNow)
            } else {
                expect(name + " also blocks explicit Restart", explicit == nil)
            }
        }
        expect("only allowed explicit settings restart invoked the fixture", calls == 102)

        var optedOut = StagedUpdateState()
        optedOut.setAutomaticInstallEnabled(true, now: 0)
        optedOut.stage(version: "10", now: 0) { calls += 1000 }
        let optOutTicket = optedOut.takeInstallation(now: 15)!
        optedOut.setAutomaticInstallEnabled(false, now: 15)
        expect("opting out after queue prevents automatic install", optedOut.prepareInstallation(optOutTicket, now: 15) == nil && optedOut.hasStagedInstall && calls == 102)
        let manual = optedOut.takeInstallation(now: 16, userInitiated: true)!
        optedOut.prepareInstallation(manual, now: 16)?()
        expect("explicit Restart remains usable after automatic opt-out", calls == 1102 && optedOut.canRelaunchNow)

        var failed = StagedUpdateState()
        failed.downloading(version: "11")
        failed.finish(.failed, errorDescription: "The update signature is invalid.")
        failed.finish(.completed)
        expect("failed download keeps error and attempted version through cycle completion", failed.phase == .failed && failed.version == "11" && failed.statusText.contains("signature is invalid"))
        failed.beginCheck()
        failed.found(version: "11")
        failed.finish(.cancelled)
        failed.finish(.completed)
        expect("cancelled check is not overwritten with generic success", failed.phase == .cancelled && failed.version == "11")
        failed.beginCheck()
        failed.finish(.upToDate)
        expect("genuine no-update result clears stale available version", failed.phase == .upToDate && failed.version == nil)
        failed.stage(version: "11", now: 0) { calls += 10000 }
        let abandoned = failed.takeInstallation(now: 0, userInitiated: true)!
        failed.finish(.failed)
        expect("terminal Sparkle failure invalidates captured install handler", failed.prepareInstallation(abandoned, now: 1) == nil && !failed.hasStagedInstall && calls == 1102)
        failed.stage(version: "12", now: 0) { calls += 10000 }
        let newer = failed.takeInstallation(now: 0, userInitiated: true)!
        expect("superseded stage ticket cannot consume newer staged callback", failed.prepareInstallation(abandoned, now: 1) == nil && failed.hasQueuedInstall)
        failed.prepareInstallation(newer, now: 1)?()
        expect("new stage callback survives stale delivery", calls == 11102)

        var delayed = StagedUpdateState()
        delayed.setAutomaticInstallEnabled(true, now: 0)
        delayed.stage(version: "13", now: 0) {}
        let initial = delayed.takeInstallation(now: 15)!
        delayed.prepareInstallation(initial, now: 15)?()
        delayed.setContext(dictationBusy: false, presentationBusy: false, settingsVisible: true, settingsEditing: false, now: 16)
        var relaunch = UpdateRelaunchGate()
        relaunch.recordingBusy = !delayed.canResumeRelaunch(now: 16)
        expect("late window opening postpones automatic relaunch", relaunch.postponeIfBusy { calls += 100000 })
        delayed.setContext(dictationBusy: false, presentationBusy: false, settingsVisible: false, settingsEditing: false, now: 20)
        relaunch.recordingBusy = !delayed.canResumeRelaunch(now: 34.9)
        expect("deferred automatic relaunch also waits for safe idle", relaunch.takeReadyInstall() == nil)
        relaunch.recordingBusy = !delayed.canResumeRelaunch(now: 35)
        let ready = relaunch.takeReadyInstall()!
        delayed.setContext(dictationBusy: false, presentationBusy: false, settingsVisible: false, settingsEditing: true, now: 35)
        relaunch.recordingBusy = !delayed.canResumeRelaunch(now: 35)
        expect("late editing sheet requeues deferred relaunch", relaunch.prepareQueuedInstall(ready) == nil && relaunch.hasPendingInstall)
        delayed.setContext(dictationBusy: false, presentationBusy: false, settingsVisible: false, settingsEditing: false, now: 40)
        relaunch.recordingBusy = !delayed.canResumeRelaunch(now: 55)
        let final = relaunch.takeReadyInstall()!
        relaunch.prepareQueuedInstall(final)?()
        expect("deferred relaunch eventually executes once", calls == 111102 && !relaunch.hasPendingInstall)
        var ordinaryQuit = StagedUpdateState()
        ordinaryQuit.setContext(dictationBusy: false, presentationBusy: false, settingsVisible: true, settingsEditing: false, now: 0)
        ordinaryQuit.willInstall(version: "14")
        expect("ordinary quit or Sparkle user install can close Preferences", ordinaryQuit.canRelaunchNow)
        ordinaryQuit.setContext(dictationBusy: false, presentationBusy: false, settingsVisible: true, settingsEditing: true, now: 0)
        expect("ordinary install still cannot interrupt an editing sheet", !ordinaryQuit.canRelaunchNow)

        var paused = StagedUpdateState()
        paused.setAutomaticInstallEnabled(true, now: 0)
        paused.stage(version: "15", now: 0) {}
        let begun = paused.takeInstallation(now: 15)!
        paused.prepareInstallation(begun, now: 15)?()
        paused.setContext(dictationBusy: false, presentationBusy: false, settingsVisible: true, settingsEditing: false, now: 16)
        var pausedRelaunch = UpdateRelaunchGate()
        pausedRelaunch.recordingBusy = !paused.canResumeRelaunch(now: 16)
        _ = pausedRelaunch.postponeIfBusy { calls += 1000000 }
        paused.setAutomaticInstallEnabled(false, now: 17)
        expect("opt-out during delayed relaunch keeps install waiting", !paused.canResumeRelaunch(now: 100) && pausedRelaunch.hasPendingInstall)
        expect("explicit Restart can resume an already postponed auto install", paused.requestExplicitRelaunch() && paused.canResumeRelaunch(now: 100))
        pausedRelaunch.recordingBusy = !paused.canResumeRelaunch(now: 100)
        let explicitResume = pausedRelaunch.takeReadyInstall()!
        pausedRelaunch.prepareQueuedInstall(explicitResume)?()
        expect("explicit resumed relaunch uses existing callback once", calls == 1111102 && !pausedRelaunch.hasPendingInstall)
    }

}
