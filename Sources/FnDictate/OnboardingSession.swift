import Foundation
import Combine

/// Receives the same events as dictation, before the controller. A shortcut check
/// must prove a real down/up pair without also starting a recording.
final class OnboardingSession: ObservableObject {
    static let shared = OnboardingSession()

    @Published private(set) var isActive = false
    @Published private(set) var isCheckingShortcut = false
    @Published private(set) var shortcutIsDown = false
    @Published private(set) var verifiedShortcut: TriggerKey?
    private var checkingKey: TriggerKey?
    private var practicing = false

    func begin() {
        end()
        isActive = true
    }

    /// A hidden walkthrough stops intercepting keys but keeps this attempt's
    /// evidence. The view revalidates its device, shortcut and permissions on resume.
    func suspend() {
        pausePractice()
        isActive = false
    }

    func resume() { isActive = true }

    func invalidateShortcut() {
        verifiedShortcut = nil
        shortcutIsDown = false
    }

    func beginShortcutCheck(_ key: TriggerKey) {
        guard isActive else { return }
        practicing = false
        isCheckingShortcut = true
        checkingKey = key
        shortcutIsDown = false
        if verifiedShortcut != key { verifiedShortcut = nil }
    }

    func beginPractice() {
        guard isActive, verifiedShortcut != nil else { return }
        isCheckingShortcut = false
        shortcutIsDown = false
        checkingKey = nil
        practicing = true
    }

    func pausePractice() {
        practicing = false
        isCheckingShortcut = false
        shortcutIsDown = false
        checkingKey = nil
    }

    func end() {
        pausePractice()
        verifiedShortcut = nil
        isActive = false
    }

    @discardableResult
    func handleHotkey(_ event: HotkeyEvent) -> Bool {
        guard isActive, !practicing else { return false }
        switch event {
        case .triggerDown(let key):
            shortcutIsDown = isCheckingShortcut && key == checkingKey
            return true
        case .triggerUp(let key):
            if isCheckingShortcut, key == checkingKey, shortcutIsDown {
                shortcutIsDown = false
                verifiedShortcut = key
            }
            return true
        case .otherKeyDown, .escape:
            shortcutIsDown = false
            return false
        case .monitorInterrupted:
            shortcutIsDown = false
            if isCheckingShortcut { verifiedShortcut = nil }
            return false
        }
    }
}

/// Current-attempt proof survives navigation, not changes to the input that was
/// tested. No evidence is fabricated or persisted as a substitute for a real test.
struct OnboardingAttempt {
    struct Configuration: Equatable {
        var microphone: String
        var inputDeviceID: UInt32?
        var shortcut: String
        var microphoneAllowed: Bool
        var accessibilityAllowed: Bool
    }
    var microphone = OnboardingMicrophoneEvidence()
    var practiceSucceeded = false
    private var configuration: Configuration?

    /// Returns true when the physical shortcut must be verified again.
    mutating func refresh(_ current: Configuration, listenerRunning: Bool) -> Bool {
        let microphoneChanged = configuration.map {
            $0.microphone != current.microphone || $0.inputDeviceID != current.inputDeviceID
        } ?? false
        let shortcutChanged = configuration.map { $0.shortcut != current.shortcut } ?? false
        if microphoneChanged || !current.microphoneAllowed {
            microphone.reset()
            practiceSucceeded = false
        }
        let shortcutInvalid = shortcutChanged || !current.accessibilityAllowed || !listenerRunning
        if shortcutInvalid { practiceSucceeded = false }
        configuration = current
        return shortcutInvalid
    }

    func canFinish(permissionsReady: Bool, shortcutReady: Bool) -> Bool {
        permissionsReady && microphone.heardAudio && shortcutReady && practiceSucceeded
    }
}

/// Local setup and remote service availability lead to different recovery actions.
enum DictationReadiness: Equatable {
    case permissions, shortcut, setup, connection, ready

    static func evaluate(completedSetup: Bool, permissionsReady: Bool,
                         shortcutReady: Bool, connectionReady: Bool) -> Self {
        if !permissionsReady { return .permissions }
        if !shortcutReady { return .shortcut }
        if !completedSetup { return .setup }
        if !connectionReady { return .connection }
        return .ready
    }
}

/// Several meter samples are required so a single spike cannot complete the check.
/// This only proves that the selected microphone delivers audio, not its language.
struct OnboardingMicrophoneEvidence {
    private var audibleSamples = 0
    private(set) var heardAudio = false

    mutating func receive(level: Float, testing: Bool) {
        guard testing, level.isFinite, level >= 0, level <= 1 else { return }
        if level > 0.04 {
            audibleSamples += 1
            if audibleSamples >= 3 { heardAudio = true }
        } else {
            audibleSamples = 0
        }
    }

    mutating func reset() { self = Self() }
}

/// Completing practice requires a controller-confirmed insertion into the field
/// that held focus when recording began. Merely typing the example is insufficient.
struct OnboardingPracticeEvidence {
    private var beganInField = false
    private var insertionBaseline = 0
    private var beforeRecording = ""

    mutating func begin(focused: Bool, insertionCount: Int, text: String) {
        beganInField = focused
        insertionBaseline = insertionCount
        beforeRecording = text
    }

    func succeeded(insertionCount: Int, inserted: String?, fieldText: String) -> Bool {
        guard beganInField, insertionCount > insertionBaseline, fieldText != beforeRecording,
              let inserted = inserted?.trimmingCharacters(in: .whitespacesAndNewlines),
              !inserted.isEmpty else { return false }
        return fieldText.contains(inserted)
    }
}
