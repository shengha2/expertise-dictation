import Foundation
import AppKit
import CoreGraphics

enum HotkeyEvent: Equatable {
    case triggerDown(TriggerKey)
    case triggerUp(TriggerKey)
    case escape
    case monitorInterrupted
    case otherKeyDown(Int64)
}

/// Decides which keyboard events belong to dictation without performing recording or UI work.
/// Keeping this separate also lets the actual press/release sequences be regression tested.
struct HotkeyState {
    struct Decision {
        var events: [HotkeyEvent] = []
        var consume = false
    }

    private var held = Set<TriggerKey>()
    private var intercepted = Set<TriggerKey>()
    private var spaceIsDown = false
    private var interceptSpaceUp = false
    // Apple Globe taps can emit an additional key-code 179 pair after the Fn
    // modifier edges. That pair belongs to the same press, not a typed key.
    static let globeCompanionKeyCode: Int64 = 179
    private var expectsGlobeCompanion = false
    private var globeCompanionIsDown = false
    private var interceptGlobeCompanion = false
    private var interceptGlobeCompanionUp = false
    private static let ordinaryModifiers: UInt64 = 0x001E_0000 // Shift, Control, Option, Command

    mutating func reset() { self = HotkeyState() }

    mutating func process(type: CGEventType, keyCode: Int64, flags: UInt64, isRepeat: Bool = false,
                          triggerKeys: [TriggerKey], intercept: Bool, wantsKeyDowns: Bool) -> Decision {
        var decision = Decision()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            reset()
            return Decision(events: [.monitorInterrupted], consume: false)
        case .flagsChanged:
            // A new Fn press after switching shortcuts must not inherit an unmatched
            // companion from an earlier press. An original held Fn/pending key-up still
            // owns its pair even if selection or interception changes mid-press.
            if keyCode == TriggerKey.fn.keyCode, flags & TriggerKey.fn.flagMask != 0,
               !triggerKeys.contains(.fn), !held.contains(.fn) {
                expectsGlobeCompanion = false
                interceptGlobeCompanion = false
            }
            let chord = TriggerKey.controlOptionSpace
            // Users naturally release the modifiers and Space in either order.
            if held.contains(chord), flags & chord.flagMask != chord.flagMask {
                held.remove(chord)
                intercepted.remove(chord)
                decision.events.append(.triggerUp(chord))
            }
            if let key = TriggerKey.allCases.first(where: { $0.isModifierOnly && $0.keyCode == keyCode }),
               triggerKeys.contains(key) || held.contains(key) {
                let down = flags & key.flagMask != 0
                if down {
                    if held.contains(key) {
                        decision.consume = intercepted.contains(key)
                    } else if flags & Self.ordinaryModifiers == key.shortcutModifiers {
                        held.insert(key)
                        if intercept { intercepted.insert(key) }
                        if key == .fn {
                            expectsGlobeCompanion = true
                            interceptGlobeCompanion = intercept
                        }
                        decision.events.append(.triggerDown(key))
                        decision.consume = intercept
                    }
                } else if held.remove(key) != nil {
                    decision.events.append(.triggerUp(key))
                    // Keep each press/release pair consistent even if the setting changed mid-press.
                    decision.consume = intercepted.remove(key) != nil
                }
            } else if held.contains(where: { $0.isModifierOnly && flags & Self.ordinaryModifiers != $0.shortcutModifiers }) {
                decision.events.append(.otherKeyDown(keyCode))
            }
        case .keyDown:
            if keyCode == Self.globeCompanionKeyCode,
               expectsGlobeCompanion || globeCompanionIsDown {
                if !globeCompanionIsDown {
                    expectsGlobeCompanion = false
                    globeCompanionIsDown = true
                    interceptGlobeCompanionUp = interceptGlobeCompanion
                }
                return Decision(consume: interceptGlobeCompanionUp)
            }
            expectsGlobeCompanion = false
            if keyCode == TriggerKey.controlOptionSpace.keyCode {
                if spaceIsDown { return Decision(consume: interceptSpaceUp) }
                spaceIsDown = true
                let key = TriggerKey.controlOptionSpace
                if !isRepeat, triggerKeys.contains(key), flags & Self.ordinaryModifiers == key.shortcutModifiers {
                    held.insert(key)
                    if intercept { intercepted.insert(key) }
                    interceptSpaceUp = intercept
                    return Decision(events: [.triggerDown(key)], consume: intercept)
                }
            }
            if wantsKeyDowns || !held.isEmpty {
                decision.events.append(keyCode == 53 ? .escape : .otherKeyDown(keyCode))
                decision.consume = keyCode == 53
            }
        case .keyUp:
            if keyCode == Self.globeCompanionKeyCode, globeCompanionIsDown {
                globeCompanionIsDown = false
                let consume = interceptGlobeCompanionUp
                interceptGlobeCompanionUp = false
                return Decision(consume: consume)
            }
            if keyCode == TriggerKey.controlOptionSpace.keyCode {
                spaceIsDown = false
                decision.consume = interceptSpaceUp
                interceptSpaceUp = false
                if held.remove(.controlOptionSpace) != nil {
                    intercepted.remove(.controlOptionSpace)
                    decision.events.append(.triggerUp(.controlOptionSpace))
                }
            }
        default:
            break
        }
        return decision
    }
}

/// Eligibility is armed only by an Fn press that starts from idle. It expires after
/// one short tap, so a later stop press cannot change an established recording's mode.
struct FnTranslationGesture {
    static let interval: TimeInterval = 0.4
    private var firstDown: TimeInterval?
    private var firstRelease: TimeInterval?

    mutating func reset() { firstDown = nil; firstRelease = nil }

    mutating func beginIdlePress(_ key: TriggerKey, at timestamp: TimeInterval, enabled: Bool) {
        reset()
        if enabled && key == .fn { firstDown = timestamp }
    }

    mutating func releaseFirstTap(_ key: TriggerKey, at timestamp: TimeInterval, holdThreshold: TimeInterval) {
        guard key == .fn, firstRelease == nil, let firstDown,
              timestamp >= firstDown, timestamp - firstDown < holdThreshold else { reset(); return }
        firstRelease = timestamp
    }

    mutating func consumeSecondPress(_ key: TriggerKey, at timestamp: TimeInterval, enabled: Bool) -> Bool {
        defer { reset() }
        guard enabled, key == .fn, let firstRelease, timestamp >= firstRelease else { return false }
        return timestamp - firstRelease <= Self.interval
    }
}

/// Global keyboard monitor. Fn/Globe is optional: macOS can handle its emoji/dictation action
/// before a session event tap, so swallowing Fn here cannot reliably disable that system action.
final class HotkeyMonitor {
    /// Events we post ourselves (the ⌘V paste) carry this marker so the tap ignores them.
    static let syntheticMarker: Int64 = 0x464E4443 // "FNDC"

    var triggerKeys: [TriggerKey] = [.controlOptionSpace]
    var interceptTrigger = true
    /// Delivered asynchronously on the main thread, outside the time-sensitive tap callback.
    /// The return value is retained for controller compatibility; suppression is decided above.
    var handler: ((HotkeyEvent) -> Bool)?
    /// While true, key-down events are reported too (Esc to cancel, other keys while the trigger is held).
    var wantsKeyDowns = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var state = HotkeyState()
    private var generation = 0
    private(set) var isRunning = false
    private(set) var lastEventDescription = "—"
    /// Original event time, available only during handler delivery on the main thread.
    private(set) var eventTimestamp: TimeInterval?

    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: hotkeyTapCallback,
                                          userInfo: refcon) else {
            Log.warn("Event tap could not be created — Accessibility permission is probably missing")
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        Log.info("Hotkey monitor started for \(triggerKeys.map { $0.shortName }.joined(separator: ", "))")
        return true
    }

    func stop() {
        guard isRunning else { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        state.reset()
        generation += 1
        isRunning = false
    }

    /// Returns true when the event should be swallowed.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.warn("Event tap was disabled by the system (\(type.rawValue)); re-enabling")
            let decision = state.process(type: type, keyCode: 0, flags: 0,
                                         triggerKeys: triggerKeys, intercept: false, wantsKeyDowns: wantsKeyDowns)
            for event in decision.events { deliver(event) }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // CoreGraphics timestamps are nanoseconds since startup. Keep physical timing
        // when the main queue receives several delayed press/release events together.
        let timestamp = event.timestamp > 0 ? TimeInterval(event.timestamp) / 1_000_000_000 : ProcessInfo.processInfo.systemUptime

        let decision = state.process(type: type, keyCode: keyCode, flags: event.flags.rawValue,
                                     isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                     triggerKeys: triggerKeys, intercept: interceptTrigger && handler != nil,
                                     wantsKeyDowns: wantsKeyDowns)
        if (keyCode == TriggerKey.fn.keyCode || keyCode == HotkeyState.globeCompanionKeyCode), triggerKeys.contains(.fn) {
            // Log only this configured shortcut's shape, never ordinary key values or typed text.
            Log.shortcut("Fn input: code=\(keyCode) type=\(type.rawValue) flag=\(event.flags.rawValue & TriggerKey.fn.flagMask != 0) time=\(String(format: "%.3f", timestamp)) events=\(decision.events) consumed=\(decision.consume)")
        }
        for event in decision.events { deliver(event, timestamp: timestamp) }
        return decision.consume
    }

    private func deliver(_ event: HotkeyEvent, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        switch event {
        case .triggerDown(let key): lastEventDescription = "\(key.shortName) down"
        case .triggerUp(let key): lastEventDescription = "\(key.shortName) up"
        case .escape: lastEventDescription = "esc"
        case .monitorInterrupted: lastEventDescription = "keyboard listener interrupted"
        case .otherKeyDown(let code): lastEventDescription = "key \(code)"
        }
        let expectedGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.eventTimestamp = timestamp
            defer { self.eventTimestamp = nil }
            _ = self.handler?(event)
        }
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
