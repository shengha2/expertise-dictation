import Foundation
import AppKit
import ApplicationServices

struct InsertionTarget {
    var processIdentifier: pid_t?
    var bundleID: String?
    var appName: String?
    var element: AXUIElement?
    var role: String?
    var subrole: String?
    var charBefore: Character?
    var charAfter: Character?
    var precedingText: String?
    var selectedLength = 0

    var isSecure: Bool { role == "AXSecureTextField" || subrole == "AXSecureTextField" }
}

enum InsertionError: LocalizedError {
    case unavailable(String)
    case targetChanged
    /// Nothing that accepts text is focused (desktop, a button, a web page with no field…).
    case noTarget
    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .targetChanged: return "The text field changed. Copy your text and paste it where you want."
        case .noTarget: return "No text field is focused."
        }
    }
}

/// Puts text where the cursor is. Native Cocoa text views accept a direct Accessibility insert
/// (no clipboard involved); browsers, Electron apps and terminals get a ⌘V paste with the
/// clipboard restored afterwards.
enum TextInserter {
    private typealias ClipboardSnapshot = [[(NSPasteboard.PasteboardType, Data)]]
    private struct ClipboardRestoration {
        let id: UUID
        let change: Int
        let snapshot: ClipboardSnapshot
    }
    private static let restorationLock = NSLock()
    private static var pendingRestorations: [NSPasteboard.Name: ClipboardRestoration] = [:]

    /// Apps where the Accessibility insert is unreliable, so we paste straight away.
    static let pasteOnlyPrefixes: [String] = [
        "com.google.Chrome", "org.chromium", "com.microsoft.Edge", "com.brave.Browser", "company.thebrowser",
        "com.vivaldi", "org.mozilla", "com.apple.Safari", "com.microsoft.VSCode", "com.tinyspeck.slackmacgap",
        "notion.id", "com.hnc.Discord", "com.microsoft.teams", "us.zoom", "com.apple.Terminal", "com.googlecode.iterm2",
        "dev.warp", "com.figma", "com.electron", "com.todesktop", "md.obsidian", "com.linear", "com.spotify",
        "com.openai", "com.anthropic", "com.microsoft.Outlook", "com.microsoft.Word", "com.microsoft.Excel",
        "com.tencent", "com.alibaba", "com.jetbrains", "com.sublimetext", "io.zed", "com.exafunction.windsurf",
        "com.cursor", "com.readdle.smartemail", "com.superhuman", "com.apple.dt.Xcode",
    ]

    // MARK: - Reading the focused element

    static func focusedElement(in owner: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(owner, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(owner, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let element = v as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    /// Application-local focus is a bounded second read when the system-wide query
    /// is temporarily unavailable. Neither source may identify a different process.
    static func resolveFocusedElement(pid: pid_t, systemRead: () -> AXUIElement?,
                                      applicationRead: () -> AXUIElement?,
                                      foregroundPID: () -> pid_t?,
                                      elementPID: (AXUIElement) -> pid_t?) -> AXUIElement? {
        guard foregroundPID() == pid else { return nil }
        let systemCandidate = systemRead()
        guard foregroundPID() == pid else { return nil }
        // A known foreign element is evidence that a nonactivating panel or other
        // process has keyboard focus. Do not replace it with stale app-local focus.
        if let systemCandidate { return elementPID(systemCandidate) == pid ? systemCandidate : nil }
        let applicationCandidate = applicationRead()
        guard foregroundPID() == pid else { return nil }
        if let applicationCandidate, elementPID(applicationCandidate) == pid { return applicationCandidate }
        return nil
    }

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        let application = AXUIElementCreateApplication(pid)
        return resolveFocusedElement(pid: pid, systemRead: { focusedElement(in: system) },
                                     applicationRead: { focusedElement(in: application) },
                                     foregroundPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                                     elementPID: { element in
            var owner: pid_t = 0
            return AXUIElementGetPid(element, &owner) == .success ? owner : nil
        })
    }

    static func stringAttribute(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func numberAttribute(_ el: AXUIElement, _ attr: String) -> Int? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return (v as? NSNumber)?.intValue
    }

    static func rangeAttribute(_ el: AXUIElement, _ attr: String) -> CFRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let val = v,
              CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(val as! AXValue, .cfRange, &r) else { return nil }
        return r
    }

    static func string(for el: AXUIElement, range: CFRange) -> String? {
        var r = range
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, param, &v) == .success else { return nil }
        return v as? String
    }

    /// Request Electron's documented accessibility support before taking the original
    /// snapshot. Do this only at recording start, never while revalidating a paste.
    static func captureRecordingTarget() -> InsertionTarget {
        let app = NSWorkspace.shared.frontmostApplication
        if let app, let bundle = app.bundleURL,
           FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.25)
            _ = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        return captureIdentity(app: app)
    }

    static func captureIdentity() -> InsertionTarget {
        captureIdentity(app: NSWorkspace.shared.frontmostApplication)
    }

    static func captureFocusIdentity() -> InsertionTarget {
        captureIdentity(app: NSWorkspace.shared.frontmostApplication, includeAttributes: false)
    }

    private static func captureIdentity(app: NSRunningApplication?, includeAttributes: Bool = true) -> InsertionTarget {
        var t = InsertionTarget()
        t.processIdentifier = app?.processIdentifier
        t.bundleID = app?.bundleIdentifier
        t.appName = app?.localizedName
        guard let pid = t.processIdentifier, let el = focusedElement(pid: pid) else { return t }
        t.element = el
        if includeAttributes {
            t.role = stringAttribute(el, kAXRoleAttribute)
            t.subrole = stringAttribute(el, kAXSubroleAttribute)
        }
        // Focus may have moved while an app answered role/subrole queries.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            t.element = nil
            return t
        }
        return t
    }

    /// Optional text around the SAME captured element. Recording publishes identity
    /// first, so a slow context query cannot discard the original field on Finish.
    static func enrichTarget(_ identity: InsertionTarget) -> InsertionTarget {
        var t = identity
        guard let el = t.element, !t.isSecure else { return t }
        guard let sel = rangeAttribute(el, kAXSelectedTextRangeAttribute), sel.location >= 0, sel.length >= 0 else { return t }
        t.selectedLength = sel.length
        let count = numberAttribute(el, kAXNumberOfCharactersAttribute)
        let beforeLen = min(sel.location, 400)
        var before: String?
        if beforeLen > 0 {
            before = string(for: el, range: CFRange(location: sel.location - beforeLen, length: beforeLen))
        }
        var after: String?
        if let count, sel.location + sel.length < count {
            after = string(for: el, range: CFRange(location: sel.location + sel.length, length: 1))
        }
        if before == nil && (count ?? 0) <= 20000, let value = stringAttribute(el, kAXValueAttribute) {
            let ns = value as NSString
            if sel.location <= ns.length {
                let start = max(0, sel.location - 400)
                before = ns.substring(with: NSRange(location: start, length: sel.location - start))
                let afterStart = sel.location + sel.length
                if afterStart < ns.length { after = ns.substring(with: NSRange(location: afterStart, length: 1)) }
            }
        }
        t.precedingText = before
        t.charBefore = before?.last
        t.charAfter = after?.first
        return t
    }

    static func captureTarget() -> InsertionTarget { enrichTarget(captureIdentity()) }

    /// A diagnostic host can pin its approved process rather than recapturing
    /// whichever application becomes frontmost during a countdown.
    static func captureTarget(in application: NSRunningApplication) -> InsertionTarget {
        enrichTarget(captureIdentity(app: application))
    }

    // MARK: - Spacing

    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.first.map { $0.properties.isIdeographic } ?? false
    }

    static func isCJKPunct(_ c: Character) -> Bool { "，。！？、；：（）「」『』“”‘’…—".contains(c) }

    static func applySpacing(_ text: String, target: InsertionTarget, cjkSpacing: Bool) -> String {
        guard let first = text.first else { return text }
        var out = text
        let latinFirst = first.isLetter && !isCJK(first) || first.isNumber
        if let before = target.charBefore, !before.isWhitespace && !"([{\"'“‘「『（".contains(before) {
            if isCJK(first) {
                if !isCJK(before) && !isCJKPunct(before) && (before.isLetter || before.isNumber) && cjkSpacing { out = " " + out }
                else if ".,!?;:".contains(before) { out = " " + out }
            } else if latinFirst {
                if isCJK(before) { if cjkSpacing { out = " " + out } }
                else if !isCJKPunct(before) { out = " " + out }
            }
            // Continue a sentence in lower case when the previous text has not ended one.
            if latinFirst, before.isLetter || before == "," , !isCJK(before),
               EmailAddressFormatting.ranges(in: text).first?.location != 0,
               let second = text.dropFirst().first, second.isLowercase,
               !text.hasPrefix("I ") && !text.hasPrefix("I'") && !text.hasPrefix("I’") {
                let leading = String(out.prefix(while: { $0 == " " }))
                out = leading + String(text.prefix(1)).lowercased() + String(text.dropFirst())
            }
        }
        if let after = target.charAfter, let last = out.last, target.selectedLength == 0 {
            let afterIsWord = (after.isLetter || after.isNumber) && !isCJK(after)
            let lastIsWordish = last.isLetter || last.isNumber || ".,!?;:".contains(last)
            if afterIsWord && lastIsWordish && !isCJK(last) { out += " " }
        }
        return out
    }

    // MARK: - Inserting

    /// Returns the text submitted for insertion. A posted paste cannot be acknowledged by every app.
    @discardableResult
    static func insert(_ text: String, method: InsertionMethod, smartSpacing: Bool, restoreClipboard: Bool,
                       cjkSpacing: Bool, dryRun: Bool, expectedTarget: InsertionTarget? = nil,
                       targetReader: (() -> InsertionTarget)? = nil) throws -> String {
        let target = (targetReader ?? captureTarget)()
        // Revalidation needs identity only, not repeated caret/text queries.
        let readIdentity = targetReader ?? captureFocusIdentity
        let toInsert = smartSpacing ? applySpacing(text, target: target, cjkSpacing: cjkSpacing) : text
        if dryRun {
            guard isEditableTarget(target) || ProcessInfo.processInfo.environment["FNDICTATE_FORCE_NO_TARGET"] != "1" else {
                throw InsertionError.noTarget
            }
            Log.info("dry run — prepared \(toInsert.count) characters")
            return toInsert
        }
        guard Permissions.accessibilityGranted else {
            throw InsertionError.unavailable("Enable Expertise Typer in System Settings → Privacy & Security → Accessibility to type automatically.")
        }
        if let expectedTarget, !validateOriginalTarget(expectedTarget, current: target) {
            throw InsertionError.targetChanged
        }
        guard !target.isSecure else {
            throw InsertionError.unavailable("Select a regular text field. Dictation is unavailable in password fields.")
        }
        guard isEditableTarget(target) else {
            Log.info("no editable target in \(target.bundleID ?? "?") (role \(target.role ?? "none")); keeping the text")
            throw InsertionError.noTarget
        }
        if method == .auto, let el = target.element, canUseAccessibility(target),
           axInsert(el, toInsert, target: target,
                    targetIsCurrent: { validateOriginalTarget(target, current: readIdentity()) }) {
            Log.info("inserted via Accessibility into \(target.bundleID ?? "?")")
            return toInsert
        }
        // AX calls may take long enough for focus to move while an attempted direct
        // insertion fails. Recheck before falling back to a keyboard paste.
        guard validateOriginalTarget(target, current: readIdentity()) else { throw InsertionError.targetChanged }
        guard try paste(toInsert, restore: restoreClipboard,
                        targetIsCurrent: { validateOriginalTarget(target, current: readIdentity()) }) else {
            throw InsertionError.unavailable("macOS could not send the paste shortcut. Copy your text and paste it where you want.")
        }
        Log.info("paste submitted to \(target.bundleID ?? "?")")
        return toInsert
    }

    static func matchesOriginalTarget(_ original: InsertionTarget, current: InsertionTarget) -> Bool {
        targetMismatch(original, current: current) == nil
    }

    enum TargetMismatch: String {
        case originalAppUnavailable, applicationChanged, originalFieldUnavailable, currentFieldUnavailable, fieldChanged
    }

    static func targetMismatch(_ original: InsertionTarget, current: InsertionTarget) -> TargetMismatch? {
        guard let pid = original.processIdentifier else { return .originalAppUnavailable }
        guard pid == current.processIdentifier else { return .applicationChanged }
        // An app can contain many fields. A missing original AX element is not evidence
        // that the field focused now is where recording began; keep the result for copy.
        guard let element = original.element else { return .originalFieldUnavailable }
        guard let currentElement = current.element else { return .currentFieldUnavailable }
        return CFEqual(element, currentElement) ? nil : .fieldChanged
    }

    private static func validateOriginalTarget(_ original: InsertionTarget, current: InsertionTarget) -> Bool {
        guard let reason = targetMismatch(original, current: current) else { return true }
        // No transcript, field text, title or element identifiers in diagnostics.
        Log.info("keeping text for copy: \(reason.rawValue)")
        return false
    }

    static let editableRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
    static let nonEditableRoles: Set<String> = [
        "AXWindow", "AXGroup", "AXButton", "AXStaticText", "AXList", "AXTable", "AXImage", "AXScrollArea",
        "AXSplitGroup", "AXToolbar", "AXMenu", "AXMenuItem", "AXMenuBar", "AXMenuBarItem", "AXTabGroup", "AXOutline",
        "AXRow", "AXCell", "AXLink", "AXCheckBox", "AXRadioButton", "AXRadioGroup", "AXPopUpButton", "AXSlider",
        "AXDisclosureTriangle", "AXApplication", "AXWebArea", "AXSheet", "AXDrawer", "AXBrowser", "AXColumn",
        "AXHeading", "AXIncrementor", "AXProgressIndicator", "AXRuler", "AXSplitter", "AXLayoutArea",
        "AXLayoutItem", "AXHandle", "AXGrid", "AXDockItem", "AXMatte", "AXValueIndicator", "AXGrowArea",
        "AXHelpTag", "AXBusyIndicator", "AXLevelIndicator", "AXRuleMarker", "AXTimeline", "AXSelection", "AXUnknown",
    ]

    /// Whether the focused element will accept typed text. Text roles are trusted; anything else must
    /// expose a writable selected-text or value attribute (editable web content and custom views do).
    /// When in doubt the answer is no: the transcript then goes to a card and the clipboard instead of
    /// being pasted into nothing.
    static func isEditableTarget(_ t: InsertionTarget) -> Bool {
        if ProcessInfo.processInfo.environment["FNDICTATE_FORCE_NO_TARGET"] == "1" { return false }
        guard let el = t.element else { return false }
        let role = t.role ?? ""
        if editableRoles.contains(role) { return true }
        if t.subrole == "AXContentEditable" { return true }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue { return true }
        if !nonEditableRoles.contains(role),
           AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue { return true }
        return false
    }

    static func canUseAccessibility(_ t: InsertionTarget) -> Bool {
        guard let role = t.role, role == kAXTextAreaRole as String || role == kAXTextFieldRole as String else { return false }
        guard let bundle = t.bundleID else { return false }
        return !pasteOnlyPrefixes.contains { bundle.hasPrefix($0) }
    }

    static func axInsert(_ el: AXUIElement, _ text: String, target: InsertionTarget,
                         targetIsCurrent: () -> Bool) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue else { return false }
        let before = numberAttribute(el, kAXNumberOfCharactersAttribute)
        guard targetIsCurrent() else { return false }
        guard AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success else { return false }
        if let before, let after = numberAttribute(el, kAXNumberOfCharactersAttribute) {
            let expected = before - target.selectedLength + (text as NSString).length
            if abs(after - expected) > 2 {
                // A successful AX write may be normalized or reported asynchronously. Pasting
                // again here can duplicate text or overwrite a second selection.
                Log.warn("Accessibility insert returned success with a different character count (\(before)→\(after), expected \(expected))")
            }
        }
        return true
    }

    static func paste(_ text: String, restore: Bool, targetIsCurrent: () -> Bool,
                      pasteboard pb: NSPasteboard = .general,
                      writeText: (NSPasteboard, String) -> Bool = { $0.setString($1, forType: .string) },
                      postPaste: () -> Bool = postCommandV,
                      scheduleRestore: (@escaping () -> Void) -> Void = { restore in
                          DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: restore)
                      }) throws -> Bool {
        // AX validation can be slow. Take the clipboard snapshot afterwards so a
        // user's independent copy during that query is retained, not rolled back.
        guard targetIsCurrent() else { throw InsertionError.targetChanged }
        // Even when successful-paste restoration is disabled, a failed submission
        // should return the clipboard to its prior value if we still own it.
        let priorChange = pb.changeCount
        restorationLock.lock()
        let pending = pendingRestorations[pb.name]
        let inherited = pending?.change == priorChange ? pending?.snapshot : nil
        // An independent clipboard copy starts a new ownership chain. Never replace
        // it with an earlier dictation's saved clipboard when its timer runs.
        if inherited == nil { pendingRestorations.removeValue(forKey: pb.name) }
        restorationLock.unlock()
        let snapshot: ClipboardSnapshot = inherited ?? (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let ownership = UUID()
        func releaseOwnership() -> Bool {
            restorationLock.lock(); defer { restorationLock.unlock() }
            guard pendingRestorations[pb.name]?.id == ownership else { return false }
            pendingRestorations.removeValue(forKey: pb.name)
            return true
        }
        func restoreIfOwned(_ change: Int) {
            guard releaseOwnership(), pb.changeCount == change else { return }
            pb.clearContents()
            let items: [NSPasteboardItem] = snapshot.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        // Reading rich clipboard formats may itself span a new independent copy.
        // Fail closed rather than clearing a clipboard we no longer own a snapshot of.
        guard pb.changeCount == priorChange else { return false }
        pb.clearContents()
        let wrote = writeText(pb, text)
        let change = pb.changeCount
        restorationLock.lock()
        pendingRestorations[pb.name] = ClipboardRestoration(id: ownership, change: change, snapshot: snapshot)
        restorationLock.unlock()
        guard wrote else { restoreIfOwned(change); return false }
        guard targetIsCurrent() else {
            restoreIfOwned(change)
            throw InsertionError.targetChanged
        }
        guard pb.changeCount == change else {
            _ = releaseOwnership()
            return false
        }
        guard postPaste() else { restoreIfOwned(change); return false }
        if restore {
            scheduleRestore { restoreIfOwned(change) }
        } else {
            // Keeping a successful paste is an explicit preference; an older timer
            // must not later resurrect either a temporary transcript or old clipboard.
            _ = releaseOwnership()
        }
        return true
    }

    static func postCommandV() -> Bool {
        guard let src = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else { return false }
        for e in [down, up] {
            e.flags = .maskCommand
            e.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.syntheticMarker)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
