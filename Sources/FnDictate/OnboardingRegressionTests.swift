import Foundation

/// Offline checks of the onboarding event and evidence gates. No microphone,
/// provider, Accessibility permission, or window is accessed by these fixtures.
enum OnboardingRegressionTests {
    static func run(check: (String, Bool, String) -> Void) {
        let session = OnboardingSession()
        check("onboarding: inactive setup leaves dictation events alone",
              !session.handleHotkey(.triggerDown(.fn)) && !session.isActive, "")
        session.begin()
        check("onboarding: setup consumes trigger presses before practice",
              session.handleHotkey(.triggerDown(.fn)) && session.handleHotkey(.triggerUp(.fn)) &&
              session.verifiedShortcut == nil && !session.isCheckingShortcut, "")
        session.beginPractice()
        check("onboarding: unverified shortcut cannot enter practice",
              session.handleHotkey(.triggerDown(.fn)), "")

        session.beginShortcutCheck(.fn)
        _ = session.handleHotkey(.triggerUp(.fn))
        check("onboarding: stray release is not a verified shortcut", session.verifiedShortcut == nil, "")
        _ = session.handleHotkey(.triggerDown(.rightOption))
        _ = session.handleHotkey(.triggerUp(.rightOption))
        check("onboarding: another shortcut cannot verify Fn",
              !session.shortcutIsDown && session.verifiedShortcut == nil, "")
        _ = session.handleHotkey(.triggerDown(.fn))
        check("onboarding: key down updates feedback without completing the check",
              session.shortcutIsDown && session.verifiedShortcut == nil, "")
        _ = session.handleHotkey(.triggerDown(.fn))
        _ = session.handleHotkey(.triggerUp(.fn))
        check("onboarding: matching down and up verify the selected shortcut",
              session.verifiedShortcut == .fn && !session.shortcutIsDown, "")
        session.beginPractice()
        check("onboarding: practice forwards the real start and stop events",
              !session.handleHotkey(.triggerDown(.fn)) && !session.handleHotkey(.triggerUp(.fn)) &&
              !session.handleHotkey(.escape) && !session.isCheckingShortcut, "")
        session.pausePractice()
        check("onboarding: navigating away stops shortcut-triggered recording",
              session.handleHotkey(.triggerDown(.fn)), "")

        session.beginShortcutCheck(.rightOption)
        check("onboarding: changing shortcut invalidates its previous proof",
              session.verifiedShortcut == nil && !session.shortcutIsDown, "")
        _ = session.handleHotkey(.triggerDown(.rightOption))
        _ = session.handleHotkey(.otherKeyDown(0))
        _ = session.handleHotkey(.triggerUp(.rightOption))
        check("onboarding: using the modifier in a chord does not complete setup",
              session.verifiedShortcut == nil && !session.shortcutIsDown, "")
        _ = session.handleHotkey(.triggerDown(.rightOption))
        _ = session.handleHotkey(.triggerDown(.fn))
        _ = session.handleHotkey(.triggerUp(.rightOption))
        check("onboarding: a second trigger cancels a pending shortcut check",
              session.verifiedShortcut == nil, "")
        _ = session.handleHotkey(.triggerDown(.rightOption))
        _ = session.handleHotkey(.monitorInterrupted)
        _ = session.handleHotkey(.triggerUp(.rightOption))
        check("onboarding: interrupted listener cannot complete a stale press",
              session.verifiedShortcut == nil && !session.shortcutIsDown, "")
        _ = session.handleHotkey(.triggerDown(.rightOption))
        _ = session.handleHotkey(.triggerUp(.rightOption))
        check("onboarding: listener recovery accepts a new complete press",
              session.verifiedShortcut == .rightOption, "")
        session.end()
        check("onboarding: closing setup clears proof and releases shortcut routing",
              !session.isActive && !session.isCheckingShortcut && session.verifiedShortcut == nil &&
              !session.handleHotkey(.triggerDown(.rightOption)), "")
        session.beginShortcutCheck(.fn)
        check("onboarding: a hidden setup cannot re-arm the shortcut probe",
              !session.isCheckingShortcut && !session.handleHotkey(.triggerDown(.fn)), "")

        var microphone = OnboardingMicrophoneEvidence()
        for _ in 0..<5 { microphone.receive(level: 0.5, testing: false) }
        for level in [Float.nan, Float.infinity, -1, 2, 0, 0.01] { microphone.receive(level: level, testing: true) }
        check("onboarding: silence, invalid samples and stopped checks cannot verify a microphone",
              !microphone.heardAudio, "")
        microphone.receive(level: 0.5, testing: true)
        microphone.receive(level: 0, testing: true)
        microphone.receive(level: 0.5, testing: true)
        microphone.receive(level: 0, testing: true)
        check("onboarding: isolated spikes do not verify microphone input", !microphone.heardAudio, "")
        for _ in 0..<3 { microphone.receive(level: 0.2, testing: true) }
        check("onboarding: repeated live audio samples verify microphone input", microphone.heardAudio, "")
        microphone.reset()
        check("onboarding: selecting another microphone requires fresh audio evidence", !microphone.heardAudio, "")

        var practice = OnboardingPracticeEvidence()
        practice.begin(focused: true, insertionCount: 7, text: "")
        check("onboarding: typing the example does not count as dictation",
              !practice.succeeded(insertionCount: 7, inserted: "A message.", fieldText: "A message."), "")
        practice.begin(focused: false, insertionCount: 7, text: "")
        check("onboarding: recording outside the practice field cannot complete setup",
              !practice.succeeded(insertionCount: 8, inserted: "A message.", fieldText: "A message."), "")
        practice.begin(focused: true, insertionCount: 7, text: "Previous message.")
        check("onboarding: stale unchanged text cannot complete another trial",
              !practice.succeeded(insertionCount: 8, inserted: "Previous message.", fieldText: "Previous message."), "")
        check("onboarding: an insertion elsewhere cannot complete the practice field",
              !practice.succeeded(insertionCount: 8, inserted: "Different message.", fieldText: "My typed message."), "")
        check("onboarding: empty and missing results cannot complete practice",
              !practice.succeeded(insertionCount: 8, inserted: " \n ", fieldText: "Changed") &&
              !practice.succeeded(insertionCount: 8, inserted: nil, fieldText: "Changed"), "")
        check("onboarding: a confirmed multilingual insertion completes practice",
              practice.succeeded(insertionCount: 8, inserted: "  Hello. 你好。\n", fieldText: "Previous message. Hello. 你好。"), "")

        session.begin()
        session.beginShortcutCheck(.fn)
        _ = session.handleHotkey(.triggerDown(.fn))
        _ = session.handleHotkey(.triggerUp(.fn))
        session.suspend()
        check("onboarding: postponing setup keeps verified shortcut but releases all key interception",
              !session.isActive && session.verifiedShortcut == .fn && !session.handleHotkey(.triggerDown(.fn)), "")
        session.resume()
        session.beginPractice()
        check("onboarding: resuming a verified attempt can continue practice without replaying the shortcut check",
              session.isActive && session.verifiedShortcut == .fn && !session.handleHotkey(.triggerDown(.fn)), "")
        session.invalidateShortcut()
        session.pausePractice()
        session.beginPractice()
        check("onboarding: invalidated shortcut proof cannot resume practice",
              session.verifiedShortcut == nil && session.handleHotkey(.triggerDown(.fn)), "")
        session.end()

        var attempt = OnboardingAttempt()
        var configuration = OnboardingAttempt.Configuration(microphone: "systemDefault", inputDeviceID: 10,
                                                            shortcut: "fn", microphoneAllowed: true,
                                                            accessibilityAllowed: true)
        _ = attempt.refresh(configuration, listenerRunning: true)
        for _ in 0..<3 { attempt.microphone.receive(level: 0.2, testing: true) }
        attempt.practiceSucceeded = practice.succeeded(insertionCount: 8, inserted: "Hello. 你好。",
                                                      fieldText: "Previous message. Hello. 你好。")
        let shortcutInvalidated = attempt.refresh(configuration, listenerRunning: true)
        check("onboarding: navigating away and returning with unchanged inputs retains real microphone and insertion proof",
              !shortcutInvalidated && attempt.canFinish(permissionsReady: true, shortcutReady: true), "")
        let outage = DictationReadiness.evaluate(completedSetup: true, permissionsReady: true,
                                                shortcutReady: true, connectionReady: false)
        check("onboarding: an outage after successful practice permits finishing and directs Home to connection recovery",
              attempt.canFinish(permissionsReady: true, shortcutReady: true) && outage == .connection, "")
        configuration.inputDeviceID = 11
        _ = attempt.refresh(configuration, listenerRunning: true)
        check("onboarding: switching the system input device invalidates microphone and practice proof",
              !attempt.microphone.heardAudio && !attempt.practiceSucceeded && !attempt.canFinish(permissionsReady: true, shortcutReady: true), "")
        for _ in 0..<3 { attempt.microphone.receive(level: 0.2, testing: true) }
        attempt.practiceSucceeded = true
        configuration.microphone = "builtIn"
        _ = attempt.refresh(configuration, listenerRunning: true)
        check("onboarding: changing microphone preference requires a new microphone check even for the same device",
              !attempt.microphone.heardAudio && !attempt.practiceSucceeded, "")
        for _ in 0..<3 { attempt.microphone.receive(level: 0.2, testing: true) }
        attempt.practiceSucceeded = true
        configuration.shortcut = "rightOption"
        let changedKey = attempt.refresh(configuration, listenerRunning: true)
        check("onboarding: changing shortcut invalidates shortcut and practice but retains unchanged microphone proof",
              changedKey && attempt.microphone.heardAudio && !attempt.practiceSucceeded, "")
        attempt.practiceSucceeded = true
        configuration.microphoneAllowed = false
        _ = attempt.refresh(configuration, listenerRunning: true)
        configuration.microphoneAllowed = true
        _ = attempt.refresh(configuration, listenerRunning: true)
        check("onboarding: revoking then restoring microphone permission cannot restore old proof",
              !attempt.microphone.heardAudio && !attempt.practiceSucceeded, "")
        for _ in 0..<3 { attempt.microphone.receive(level: 0.2, testing: true) }
        attempt.practiceSucceeded = true
        configuration.accessibilityAllowed = false
        let revokedAccessibility = attempt.refresh(configuration, listenerRunning: true)
        check("onboarding: Accessibility revocation invalidates insertion and shortcut proof",
              revokedAccessibility && !attempt.practiceSucceeded && attempt.microphone.heardAudio, "")
        configuration.accessibilityAllowed = true
        attempt.practiceSucceeded = true
        let stoppedListener = attempt.refresh(configuration, listenerRunning: false)
        check("onboarding: lost shortcut listener invalidates completion while retaining microphone proof",
              stoppedListener && !attempt.practiceSucceeded && attempt.microphone.heardAudio, "")
        check("home: incomplete setup is distinct from a completed setup with a service outage",
              DictationReadiness.evaluate(completedSetup: false, permissionsReady: true, shortcutReady: true, connectionReady: false) == .setup &&
              DictationReadiness.evaluate(completedSetup: true, permissionsReady: true, shortcutReady: true, connectionReady: false) == .connection, "")
        check("home: missing permissions and shortcut route to local setup before connection repair",
              DictationReadiness.evaluate(completedSetup: true, permissionsReady: false, shortcutReady: true, connectionReady: false) == .permissions &&
              DictationReadiness.evaluate(completedSetup: true, permissionsReady: true, shortcutReady: false, connectionReady: false) == .shortcut, "")
        check("home: dictation instructions appear only after setup, permissions, shortcut and connection are ready",
              DictationReadiness.evaluate(completedSetup: true, permissionsReady: true, shortcutReady: true, connectionReady: true) == .ready, "")
    }
}
