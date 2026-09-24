import ApplicationServices

/// Synthetic AX handles and injected reads: no access to real apps, clipboard or user text.
enum InsertionFocusRegressionTests {
    static func run(check: (String, Bool, String) -> Void) {
        let first = AXUIElementCreateApplication(100_001)
        let second = AXUIElementCreateApplication(100_002)
        var systemReads = 0
        var appReads = 0
        var foreground: pid_t? = 10
        func owner(_ element: AXUIElement) -> pid_t? { CFEqual(element, first) ? 10 : 20 }
        func readSystem() -> AXUIElement? { systemReads += 1; return first }
        func readApp() -> AXUIElement? { appReads += 1; return first }
        func resolve(_ system: () -> AXUIElement?, _ application: () -> AXUIElement?) -> AXUIElement? {
            TextInserter.resolveFocusedElement(pid: 10, systemRead: system, applicationRead: application,
                                               foregroundPID: { foreground }, elementPID: owner)
        }
        let stable = resolve(readSystem, readApp)
        check("focus: stable system field avoids unnecessary extra app queries", stable.map { CFEqual($0, first) } == true && systemReads == 1 && appReads == 0, "")
        let recovered = resolve({ nil }, readApp)
        check("focus: temporary system focus failure recovers from the same app", recovered.map { CFEqual($0, first) } == true && appReads == 1, "")
        let readsBeforeForeign = appReads
        let foreign = resolve({ second }, readApp)
        check("focus: a foreign system field cannot be replaced with stale app-local focus", foreign == nil && appReads == readsBeforeForeign, "")
        check("focus: both unavailable queries preserve an unknown field", resolve({ nil }, { nil }) == nil, "")
        check("focus: application fallback also rejects a foreign PID", resolve({ nil }, { second }) == nil, "")
        foreground = 20
        systemReads = 0; appReads = 0
        check("focus: app switched before capture does not inspect or rebind another app", resolve(readSystem, readApp) == nil && systemReads == 0 && appReads == 0, "")
        foreground = 10
        let switched = resolve({ foreground = 20; return first }, readApp)
        check("focus: app switch during the first query discards its result", switched == nil && appReads == 0, "")
        foreground = 10
        let fallbackSwitch = resolve({ nil }, { foreground = 20; return first })
        check("focus: app switch during fallback also discards its result", fallbackSwitch == nil, "")
        var original = InsertionTarget()
        var current = InsertionTarget()
        check("focus diagnostics distinguish missing original app", TextInserter.targetMismatch(original, current: current) == .originalAppUnavailable, "")
        original.processIdentifier = 10; current.processIdentifier = 10
        check("focus diagnostics distinguish missing original field", TextInserter.targetMismatch(original, current: current) == .originalFieldUnavailable, "")
        original.element = first
        check("focus diagnostics distinguish temporarily missing current field", TextInserter.targetMismatch(original, current: current) == .currentFieldUnavailable, "")
        current.element = second
        check("focus diagnostics distinguish a changed field in the same app", TextInserter.targetMismatch(original, current: current) == .fieldChanged, "")
        current.element = first; current.processIdentifier = 20
        check("focus diagnostics distinguish a changed app", TextInserter.targetMismatch(original, current: current) == .applicationChanged, "")
        current.processIdentifier = 10
        check("focus: only the same known app and field pass insertion validation", TextInserter.targetMismatch(original, current: current) == nil, "")
        InsertionPasteRegressionTests.run(check: check)
    }
}
