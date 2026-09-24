import CoreGraphics

enum HotkeyRegressionTests {
    static func run(check: (String, Bool, String) -> Void) {
        let chord = TriggerKey.controlOptionSpace
        let modifiers = chord.shortcutModifiers
        var state = HotkeyState()
        func event(_ type: CGEventType, _ code: Int64, _ flags: UInt64 = 0,
                   repeatKey: Bool = false, keys: [TriggerKey] = [.controlOptionSpace],
                   intercept: Bool = true, recording: Bool = false) -> HotkeyState.Decision {
            state.process(type: type, keyCode: code, flags: flags, isRepeat: repeatKey,
                          triggerKeys: keys, intercept: intercept, wantsKeyDowns: recording)
        }
        func expect(_ name: String, _ result: HotkeyState.Decision, _ events: [HotkeyEvent], _ consume: Bool) {
            check(name, result.events == events && result.consume == consume,
                  "events=\(result.events), consumed=\(result.consume)")
        }

        expect("hotkey: Control/Option alone remain normal modifiers",
               event(.flagsChanged, 58, modifiers), [], false)
        expect("hotkey: chord starts on Space", event(.keyDown, 49, modifiers), [.triggerDown(chord)], true)
        expect("hotkey: held Space does not retrigger", event(.keyDown, 49, modifiers, repeatKey: true), [], true)
        expect("hotkey: Space release finishes", event(.keyUp, 49, modifiers), [.triggerUp(chord)], true)

        _ = event(.keyDown, 49, modifiers)
        expect("hotkey: modifiers may release before Space", event(.flagsChanged, 59, 0x0008_0000), [.triggerUp(chord)], false)
        expect("hotkey: early modifier release still consumes Space up", event(.keyUp, 49), [], true)

        expect("hotkey: Globe is untouched with recommended shortcut", event(.flagsChanged, 63, 0x0080_0000), [], false)
        expect("hotkey: normal Space remains typing", event(.keyDown, 49), [], false)
        _ = event(.keyUp, 49)
        expect("hotkey: emoji shortcut is not captured", event(.keyDown, 49, 0x0014_0000), [], false)
        _ = event(.keyUp, 49)

        _ = event(.keyDown, 49, modifiers)
        expect("hotkey: another key cancels without eating the key", event(.keyDown, 0, modifiers), [.otherKeyDown(0)], false)
        _ = event(.keyUp, 49)
        expect("hotkey: Esc cancels active recording", event(.keyDown, 53, recording: true), [.escape], true)
        expect("hotkey: Esc remains available while idle", event(.keyDown, 53), [], false)

        _ = event(.flagsChanged, 61, 0x0008_0040, keys: [.rightOption])
        expect("hotkey: right Option releases while left Option stays held",
               event(.flagsChanged, 61, 0x0008_0020, keys: [.rightOption]), [.triggerUp(.rightOption)], true)
        _ = event(.flagsChanged, 54, 0x0010_0010, keys: [.rightCommand])
        expect("hotkey: right Command releases while left Command stays held",
               event(.flagsChanged, 54, 0x0010_0008, keys: [.rightCommand]), [.triggerUp(.rightCommand)], true)
        _ = event(.flagsChanged, 62, 0x0004_2000, keys: [.rightControl])
        expect("hotkey: right Control releases while left Control stays held",
               event(.flagsChanged, 62, 0x0004_0001, keys: [.rightControl]), [.triggerUp(.rightControl)], true)

        expect("hotkey: right Option in an existing chord does not record",
               event(.flagsChanged, 61, 0x0018_0040, keys: [.rightOption]), [], false)
        _ = event(.flagsChanged, 61, 0, keys: [.rightOption])
        _ = event(.flagsChanged, 63, 0x0080_0000, keys: [.fn], intercept: false)
        expect("hotkey: repeated Fn flags honor pass-through setting",
               event(.flagsChanged, 63, 0x0080_0000, keys: [.fn], intercept: false), [], false)
        expect("hotkey: changing selection mid-hold cannot lose release",
               event(.flagsChanged, 63, 0), [.triggerUp(.fn)], false)

        _ = event(.keyDown, 49, modifiers)
        expect("hotkey: changing interception preserves matched key pair",
               event(.keyUp, 49, modifiers, intercept: false), [.triggerUp(chord)], true)

        _ = event(.keyDown, 49, modifiers)
        expect("hotkey: system timeout preserves recording instead of cancellation",
               event(.tapDisabledByTimeout, 0, recording: true), [.monitorInterrupted], false)
        expect("hotkey: interrupted listener forgets stale held keys",
               event(.keyUp, 49), [], false)
        expect("hotkey: listener accepts a fresh press after interruption",
               event(.keyDown, 49, modifiers), [.triggerDown(chord)], true)
        expect("hotkey: system disable is distinct from user Escape",
               event(.tapDisabledByUserInput, 0, recording: true), [.monitorInterrupted], false)

        func armed(_ key: TriggerKey = .fn, down: Double = 0, up: Double = 0.1, enabled: Bool = true) -> FnTranslationGesture {
            var gesture = FnTranslationGesture()
            gesture.beginIdlePress(key, at: down, enabled: enabled)
            gesture.releaseFirstTap(key, at: up, holdThreshold: 0.35)
            return gesture
        }
        var gesture = armed()
        check("hotkey timing: idle double Fn enables translation", gesture.consumeSecondPress(.fn, at: 0.25, enabled: true), "")
        check("hotkey timing: third Fn press cannot retrigger translation", !gesture.consumeSecondPress(.fn, at: 0.3, enabled: true), "")
        gesture = armed()
        check("hotkey timing: exactly 400ms after release remains a double tap", gesture.consumeSecondPress(.fn, at: 0.5, enabled: true), "")
        gesture = armed()
        check("hotkey timing: a late second press remains a stop", !gesture.consumeSecondPress(.fn, at: 0.501, enabled: true), "")
        gesture = armed(up: 0.36)
        check("hotkey timing: first press held for dictation cannot arm translation", !gesture.consumeSecondPress(.fn, at: 0.4, enabled: true), "")
        gesture = armed(.rightOption)
        check("hotkey timing: other shortcuts never arm Fn translation", !gesture.consumeSecondPress(.fn, at: 0.2, enabled: true), "")
        gesture = armed()
        check("hotkey timing: second press of another key is not translation", !gesture.consumeSecondPress(.rightOption, at: 0.2, enabled: true), "")
        check("hotkey timing: another key clears the pending Fn gesture", !gesture.consumeSecondPress(.fn, at: 0.3, enabled: true), "")
        gesture = armed(enabled: false)
        check("hotkey timing: disabled preference cannot arm a double tap", !gesture.consumeSecondPress(.fn, at: 0.2, enabled: true), "")
        gesture = armed()
        check("hotkey timing: disabling preference before the second press is respected", !gesture.consumeSecondPress(.fn, at: 0.2, enabled: false), "")
        gesture = armed()
        gesture.reset()
        check("hotkey timing: reset prevents stale gesture reuse", !gesture.consumeSecondPress(.fn, at: 0.2, enabled: true), "")
        gesture = armed()
        check("hotkey timing: out-of-order timestamps cannot start translation", !gesture.consumeSecondPress(.fn, at: 0.05, enabled: true), "")

        // Exercise the production parser and gesture together. These are CG-event-shaped
        // fixtures, not a claim that an actual Mac emitted each possible event shape.
        let fnMask = TriggerKey.fn.flagMask
        let fnPair = [
            PhysicalEvent(.flagsChanged, 63, fnMask, at: 100),
            PhysicalEvent(.flagsChanged, 63, 0, at: 100.08),
            PhysicalEvent(.flagsChanged, 63, fnMask, at: 100.2),
            PhysicalEvent(.flagsChanged, 63, 0, at: 100.26),
        ]
        let expectedEdges: [HotkeyEvent] = [.triggerDown(.fn), .triggerUp(.fn), .triggerDown(.fn), .triggerUp(.fn)]
        let parsedPair = parseFn(fnPair)
        check("hotkey parser/gesture: four Fn flag edges produce two complete suppressed presses",
              parsedPair.events.map(\.event) == expectedEdges && parsedPair.consumed.allSatisfy { $0 }, "")
        check("hotkey parser/gesture: decoded double Fn is eligible for translation",
              translationDecisions(parsedPair.events) == [true], "")

        let duplicates = [
            PhysicalEvent(.flagsChanged, 63, fnMask, at: 100),
            PhysicalEvent(.flagsChanged, 63, fnMask, at: 100.02),
            PhysicalEvent(.flagsChanged, 63, 0, at: 100.08),
            PhysicalEvent(.flagsChanged, 63, 0, at: 100.09),
            PhysicalEvent(.flagsChanged, 63, fnMask, at: 100.2),
            PhysicalEvent(.flagsChanged, 63, fnMask, at: 100.22),
            PhysicalEvent(.flagsChanged, 63, 0, at: 100.26),
            PhysicalEvent(.flagsChanged, 63, 0, at: 100.27),
        ]
        let parsedDuplicates = parseFn(duplicates)
        check("hotkey parser/gesture: duplicate flags cannot add a press or release",
              parsedDuplicates.events.map(\.event) == expectedEdges && translationDecisions(parsedDuplicates.events) == [true], "")
        check("hotkey parser/gesture: held duplicates stay suppressed and stray releases pass through",
              parsedDuplicates.consumed == [true, true, true, false, true, true, true, false], "")

        let caps: UInt64 = 0x0001_0000
        let shift: UInt64 = 0x0002_0000
        let unrelatedFlags = [fnPair[0], fnPair[1],
            PhysicalEvent(.flagsChanged, 56, shift, at: 100.1),
            PhysicalEvent(.flagsChanged, 56, 0, at: 100.12),
            PhysicalEvent(.flagsChanged, 57, caps, at: 100.14),
            PhysicalEvent(.flagsChanged, 63, caps | fnMask, at: 100.2),
            PhysicalEvent(.flagsChanged, 63, caps, at: 100.26),
        ]
        let parsedUnrelated = parseFn(unrelatedFlags)
        check("hotkey parser/gesture: released modifier-only events and Caps Lock do not invent an Fn release",
              parsedUnrelated.events.map(\.event) == expectedEdges && translationDecisions(parsedUnrelated.events) == [true], "")

        let chordDuringHold = [fnPair[0],
            PhysicalEvent(.flagsChanged, 56, fnMask | shift, at: 100.03),
            PhysicalEvent(.flagsChanged, 56, fnMask, at: 100.05),
            fnPair[1], fnPair[2], fnPair[3],
        ]
        let parsedChord = parseFn(chordDuringHold)
        check("hotkey parser/gesture: another modifier while Fn is held disarms translation",
              parsedChord.events.map(\.event).contains(.otherKeyDown(56)) && translationDecisions(parsedChord.events) == [false], "")

        // Characterize current handling if the OS/device also supplies keyDown/keyUp 63.
        // A physical trace is still needed before concluding that this shape occurs.
        let hypotheticalKeyDown = [fnPair[0],
            PhysicalEvent(.keyDown, 63, fnMask, at: 100.02),
            PhysicalEvent(.keyUp, 63, 0, at: 100.07),
            fnPair[1], fnPair[2], fnPair[3],
        ]
        let parsedKeyDown = parseFn(hypotheticalKeyDown)
        check("hotkey characterization: extra keyDown 63 currently becomes otherKeyDown, not another Fn press",
              parsedKeyDown.events.map(\.event) == [.triggerDown(.fn), .otherKeyDown(63), .triggerUp(.fn), .triggerDown(.fn), .triggerUp(.fn)], "")
        check("hotkey characterization: extra keyDown 63 currently disarms the translation gesture",
              translationDecisions(parsedKeyDown.events) == [false], "")

        let delayed = [
            PhysicalEvent(.flagsChanged, 63, fnMask, at: 100, deliveredAt: 200),
            PhysicalEvent(.flagsChanged, 63, 0, at: 100.08, deliveredAt: 200.01),
            PhysicalEvent(.flagsChanged, 63, fnMask, at: 100.2, deliveredAt: 200 + FnTranslationGesture.interval + 1),
            PhysicalEvent(.flagsChanged, 63, 0, at: 100.26, deliveredAt: 200 + FnTranslationGesture.interval + 1.01),
        ]
        let parsedDelayed = parseFn(delayed)
        check("hotkey parser/gesture: delayed delivery does not turn a physical double tap into a stop",
              translationDecisions(parsedDelayed.events) == [true] && translationDecisions(parsedDelayed.events, originalTimestamps: false) == [false], "")

        let late = 100.08 + FnTranslationGesture.interval + 0.2
        let compressed = [
            PhysicalEvent(.flagsChanged, 63, fnMask, at: 100, deliveredAt: 200),
            PhysicalEvent(.flagsChanged, 63, 0, at: 100.08, deliveredAt: 200.01),
            PhysicalEvent(.flagsChanged, 63, fnMask, at: late, deliveredAt: 200.02),
            PhysicalEvent(.flagsChanged, 63, 0, at: late + 0.06, deliveredAt: 200.03),
        ]
        let parsedCompressed = parseFn(compressed)
        check("hotkey parser/gesture: batched delivery cannot turn a physically late stop into translation",
              translationDecisions(parsedCompressed.events) == [false] && translationDecisions(parsedCompressed.events, originalTimestamps: false) == [true], "")

        let interrupted = [fnPair[0], fnPair[1],
            PhysicalEvent(.tapDisabledByTimeout, 0, 0, at: 100.15), fnPair[2], fnPair[3],
        ]
        check("hotkey parser/gesture: a listener interruption between taps invalidates eligibility",
              translationDecisions(parseFn(interrupted).events) == [false], "")

        // Globe companion pairs observed adjacent to the Fn flag edges belong to the
        // same physical press. Replaying their shape must not erase double-tap eligibility.
        let globePair = [fnPair[0], fnPair[1],
            PhysicalEvent(.keyDown, 179, 0, at: 100.081),
            PhysicalEvent(.keyUp, 179, 0, at: 100.082),
            fnPair[2], fnPair[3],
            PhysicalEvent(.keyDown, 179, 0, at: 100.261),
            PhysicalEvent(.keyUp, 179, 0, at: 100.262),
        ]
        let parsedGlobe = parseFn(globePair)
        check("hotkey Globe: companion pairs after both Fn releases produce only the four Fn edges",
              parsedGlobe.events.map(\.event) == expectedEdges && parsedGlobe.consumed.allSatisfy { $0 }, "")
        check("hotkey Globe: companion pairs preserve parser-to-gesture translation eligibility",
              translationDecisions(parsedGlobe.events) == [true], "")

        let globeThenLetter = Array(globePair.prefix(4)) + [
            PhysicalEvent(.keyDown, 0, 0, at: 100.12),
            PhysicalEvent(.keyUp, 0, 0, at: 100.14),
        ] + Array(globePair.suffix(4))
        let parsedLetter = parseFn(globeThenLetter)
        check("hotkey Globe: a real typed letter still passes through and disarms translation",
              parsedLetter.events.map(\.event).contains(.otherKeyDown(0)) && !parsedLetter.consumed[4] &&
                translationDecisions(parsedLetter.events) == [false], "")

        let letterBeforeCompanion = [fnPair[0], fnPair[1],
            PhysicalEvent(.keyDown, 0, 0, at: 100.09),
            PhysicalEvent(.keyDown, 179, 0, at: 100.10),
            PhysicalEvent(.keyUp, 179, 0, at: 100.11), fnPair[2], fnPair[3],
        ]
        let parsedCleared = parseFn(letterBeforeCompanion)
        check("hotkey Globe: an intervening ordinary key clears companion eligibility",
              parsedCleared.events.map(\.event).contains(.otherKeyDown(179)) && !parsedCleared.consumed[3] &&
                !parsedCleared.consumed[4] && translationDecisions(parsedCleared.events) == [false], "")

        let fnUnselected = parseFn(globePair, triggerKeys: [.controlOptionSpace])
        check("hotkey Globe: selecting another shortcut preserves the system Globe pairs",
              fnUnselected.events.map(\.event) == [.otherKeyDown(179), .otherKeyDown(179)] &&
                fnUnselected.consumed.allSatisfy { !$0 }, "")

        let unrelatedGlobe = parseFn([
            PhysicalEvent(.keyDown, 179, 0, at: 100),
            PhysicalEvent(.keyDown, 179, 0, at: 100.02, repeatKey: true),
            PhysicalEvent(.keyUp, 179, 0, at: 100.04),
        ])
        check("hotkey Globe: standalone and repeated 179 events cannot invent a captured Fn pair",
              unrelatedGlobe.events.map(\.event) == [.otherKeyDown(179), .otherKeyDown(179)] &&
                unrelatedGlobe.consumed.allSatisfy { !$0 }, "")

        let repeatingGlobe = [fnPair[0], fnPair[1],
            PhysicalEvent(.keyDown, 179, 0, at: 100.081),
            PhysicalEvent(.keyDown, 179, 0, at: 100.083, repeatKey: true),
            PhysicalEvent(.keyDown, 179, 0, at: 100.084),
            PhysicalEvent(.keyUp, 179, 0, at: 100.085), fnPair[2], fnPair[3],
        ]
        let parsedRepeats = parseFn(repeatingGlobe)
        check("hotkey Globe: repeated companion downs stay in one suppressed pair",
              parsedRepeats.events.map(\.event) == expectedEdges && parsedRepeats.consumed.allSatisfy { $0 } &&
                translationDecisions(parsedRepeats.events) == [true], "")

        for initiallyIntercepted in [true, false] {
            var changingParser = HotkeyState()
            _ = changingParser.process(type: .flagsChanged, keyCode: 63, flags: fnMask,
                                       triggerKeys: [.fn], intercept: initiallyIntercepted, wantsKeyDowns: true)
            let stillHeld = changingParser.process(type: .flagsChanged, keyCode: 63, flags: fnMask,
                                                   triggerKeys: [.controlOptionSpace], intercept: !initiallyIntercepted, wantsKeyDowns: true)
            _ = changingParser.process(type: .flagsChanged, keyCode: 63, flags: 0,
                                       triggerKeys: [.controlOptionSpace], intercept: !initiallyIntercepted, wantsKeyDowns: true)
            let companionDown = changingParser.process(type: .keyDown, keyCode: 179, flags: 0,
                                                       triggerKeys: [.controlOptionSpace], intercept: !initiallyIntercepted, wantsKeyDowns: true)
            let companionRepeat = changingParser.process(type: .keyDown, keyCode: 179, flags: 0, isRepeat: true,
                                                         triggerKeys: [.controlOptionSpace], intercept: !initiallyIntercepted, wantsKeyDowns: true)
            let companionUp = changingParser.process(type: .keyUp, keyCode: 179, flags: 0,
                                                     triggerKeys: [.controlOptionSpace], intercept: !initiallyIntercepted, wantsKeyDowns: true)
            let strayUp = changingParser.process(type: .keyUp, keyCode: 179, flags: 0,
                                                 triggerKeys: [.fn], intercept: true, wantsKeyDowns: true)
            check("hotkey Globe: preference changes preserve the original \(initiallyIntercepted ? "suppressed" : "pass-through") companion pair",
                  [stillHeld, companionDown, companionRepeat, companionUp].allSatisfy { $0.events.isEmpty && $0.consume == initiallyIntercepted } &&
                    strayUp.events.isEmpty && !strayUp.consume, "")
        }

        for companionAlreadyDown in [false, true] {
            var changedSelection = HotkeyState()
            _ = changedSelection.process(type: .flagsChanged, keyCode: 63, flags: fnMask,
                                         triggerKeys: [.fn], intercept: true, wantsKeyDowns: true)
            _ = changedSelection.process(type: .flagsChanged, keyCode: 63, flags: 0,
                                         triggerKeys: [.fn], intercept: true, wantsKeyDowns: true)
            if companionAlreadyDown {
                _ = changedSelection.process(type: .keyDown, keyCode: 179, flags: 0,
                                             triggerKeys: [.fn], intercept: true, wantsKeyDowns: true)
            }
            // A mouse selection change produces no keyboard event before this fresh,
            // unconfigured Fn press. The old expected companion must not capture it.
            let newDown = changedSelection.process(type: .flagsChanged, keyCode: 63, flags: fnMask,
                                                   triggerKeys: [.controlOptionSpace], intercept: false, wantsKeyDowns: true)
            let newUp = changedSelection.process(type: .flagsChanged, keyCode: 63, flags: 0,
                                                 triggerKeys: [.controlOptionSpace], intercept: false, wantsKeyDowns: true)
            if companionAlreadyDown {
                let oldUp = changedSelection.process(type: .keyUp, keyCode: 179, flags: 0,
                                                     triggerKeys: [.controlOptionSpace], intercept: false, wantsKeyDowns: true)
                check("hotkey Globe: a fresh unconfigured Fn press cannot unbalance an already captured companion",
                      newDown.events.isEmpty && !newDown.consume && newUp.events.isEmpty && !newUp.consume &&
                        oldUp.events.isEmpty && oldUp.consume, "")
            } else {
                let freshDown = changedSelection.process(type: .keyDown, keyCode: 179, flags: 0,
                                                         triggerKeys: [.controlOptionSpace], intercept: false, wantsKeyDowns: true)
                let freshUp = changedSelection.process(type: .keyUp, keyCode: 179, flags: 0,
                                                       triggerKeys: [.controlOptionSpace], intercept: false, wantsKeyDowns: true)
                check("hotkey Globe: fresh Fn after a mouse shortcut change clears a stale companion expectation",
                      newDown.events.isEmpty && !newDown.consume && newUp.events.isEmpty && !newUp.consume &&
                        freshDown.events == [.otherKeyDown(179)] && !freshDown.consume && freshUp.events.isEmpty && !freshUp.consume, "")
            }
        }

        let interruptedCompanion = parseFn([fnPair[0], fnPair[1],
            PhysicalEvent(.tapDisabledByTimeout, 0, 0, at: 100.081),
            PhysicalEvent(.keyDown, 179, 0, at: 100.082),
            PhysicalEvent(.keyUp, 179, 0, at: 100.083),
        ])
        check("hotkey Globe: listener reset clears an unmatched companion expectation",
              interruptedCompanion.events.map(\.event).suffix(2).elementsEqual([.monitorInterrupted, .otherKeyDown(179)]) &&
                !interruptedCompanion.consumed[3] && !interruptedCompanion.consumed[4], "")
    }

    private struct PhysicalEvent {
        let type: CGEventType
        let keyCode: Int64
        let flags: UInt64
        let timestamp: Double
        let deliveryTimestamp: Double
        let isRepeat: Bool
        init(_ type: CGEventType, _ keyCode: Int64, _ flags: UInt64, at timestamp: Double, deliveredAt: Double? = nil, repeatKey: Bool = false) {
            self.type = type; self.keyCode = keyCode; self.flags = flags
            self.timestamp = timestamp; self.deliveryTimestamp = deliveredAt ?? timestamp
            self.isRepeat = repeatKey
        }
    }

    private struct ParsedEvent {
        let event: HotkeyEvent
        let timestamp: Double
        let deliveryTimestamp: Double
    }

    private static func parseFn(_ inputs: [PhysicalEvent], triggerKeys: [TriggerKey] = [.fn]) -> (events: [ParsedEvent], consumed: [Bool]) {
        var parser = HotkeyState()
        var events: [ParsedEvent] = []
        var consumed: [Bool] = []
        for input in inputs {
            let decision = parser.process(type: input.type, keyCode: input.keyCode, flags: input.flags,
                                          isRepeat: input.isRepeat, triggerKeys: triggerKeys, intercept: true, wantsKeyDowns: true)
            consumed.append(decision.consume)
            events += decision.events.map { ParsedEvent(event: $0, timestamp: input.timestamp, deliveryTimestamp: input.deliveryTimestamp) }
        }
        return (events, consumed)
    }

    /// One idle-started gesture only. Feed decoded edges into the real gesture helper; do
    /// not simulate audio/UI/controller state. Arrival-time mode is a negative control for
    /// preserving the original CG timestamp, not an alternative production behavior.
    private static func translationDecisions(_ events: [ParsedEvent], originalTimestamps: Bool = true) -> [Bool] {
        var gesture = FnTranslationGesture()
        var began = false
        var released = false
        var results: [Bool] = []
        for input in events {
            let timestamp = originalTimestamps ? input.timestamp : input.deliveryTimestamp
            switch input.event {
            case .triggerDown(let key):
                if !began { began = true; gesture.beginIdlePress(key, at: timestamp, enabled: true) }
                else { results.append(gesture.consumeSecondPress(key, at: timestamp, enabled: true)) }
            case .triggerUp(let key):
                if !released { released = true; gesture.releaseFirstTap(key, at: timestamp, holdThreshold: 0.35) }
            case .otherKeyDown, .escape, .monitorInterrupted:
                gesture.reset()
            }
        }
        return results
    }
}
