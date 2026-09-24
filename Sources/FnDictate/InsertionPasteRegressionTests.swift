import AppKit

/// Exercises the production paste transaction with a private named pasteboard.
/// No global clipboard, keyboard events, app focus, credentials or user drafts.
enum InsertionPasteRegressionTests {
    static func run(check: (String, Bool, String) -> Void) {
        let board = NSPasteboard(name: NSPasteboard.Name("ExpertiseDictation-paste-regression-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let originalText = "Synthetic clipboard before dictation."
        let originalRichData = Data("{\\rtf1 Synthetic clipboard before dictation.}".utf8)
        func seedClipboard() {
            board.clearContents()
            let item = NSPasteboardItem()
            item.setString(originalText, forType: .string)
            item.setData(originalRichData, forType: .rtf)
            board.writeObjects([item])
        }
        func isRestored() -> Bool {
            board.string(forType: .string) == originalText && board.data(forType: .rtf) == originalRichData
        }
        let longText = (1...120).map {
            "Section \($0): Keep the entire unsent draft, including 跨语言文字 and reference \($0)."
        }.joined(separator: "\n\n")
        var scheduled: [() -> Void] = []
        var postedTexts: [String] = []
        func runScheduledRestore() {
            guard !scheduled.isEmpty else { return }
            scheduled.removeFirst()()
        }
        seedClipboard()
        do {
            let submitted = try TextInserter.paste(longText, restore: true, targetIsCurrent: { true }, pasteboard: board,
                                                   postPaste: { postedTexts.append(board.string(forType: .string) ?? ""); return true },
                                                   scheduleRestore: { scheduled.append($0) })
            check("paste: a long multiline draft is submitted once and completely", submitted && postedTexts == [longText], "")
            check("paste: clipboard remains available until the restoration callback", board.string(forType: .string) == longText && scheduled.count == 1, "")
            runScheduledRestore()
            check("paste: successful restoration preserves every original clipboard format", isRestored(), "")
        } catch { check("paste: successful long-draft transaction", false, error.localizedDescription) }

        seedClipboard()
        postedTexts = []
        do {
            _ = try TextInserter.paste(longText, restore: true, targetIsCurrent: { false }, pasteboard: board,
                                       postPaste: { postedTexts.append("unexpected"); return true }, scheduleRestore: { scheduled.append($0) })
            check("paste: changed focus is refused before the clipboard is touched", false, "")
        } catch InsertionError.targetChanged {
            check("paste: changed focus is refused before the clipboard is touched", isRestored() && postedTexts.isEmpty && scheduled.isEmpty, "")
        } catch { check("paste: changed focus reports the typed target error", false, error.localizedDescription) }

        for restore in [false, true] {
            seedClipboard()
            var focusChecks = 0
            var postCount = 0
            do {
                _ = try TextInserter.paste(longText, restore: restore, targetIsCurrent: {
                    focusChecks += 1
                    return focusChecks == 1
                }, pasteboard: board, postPaste: { postCount += 1; return true }, scheduleRestore: { scheduled.append($0) })
                check("paste: late field change cancels submission (restore=\(restore))", false, "")
            } catch InsertionError.targetChanged {
                check("paste: late field change cancels submission (restore=\(restore))", focusChecks == 2 && postCount == 0 && isRestored() && scheduled.isEmpty, "")
            } catch { check("paste: late field change reports the typed target error", false, error.localizedDescription) }

            seedClipboard()
            do {
                let submitted = try TextInserter.paste(longText, restore: restore, targetIsCurrent: { true }, pasteboard: board,
                                                       postPaste: { false }, scheduleRestore: { scheduled.append($0) })
                check("paste: failed keyboard submission restores the clipboard (restore=\(restore))", !submitted && isRestored() && scheduled.isEmpty, "")
            } catch { check("paste: failed submission returns a recoverable failure", false, error.localizedDescription) }

            seedClipboard()
            do {
                let submitted = try TextInserter.paste(longText, restore: restore, targetIsCurrent: { true }, pasteboard: board,
                                                       writeText: { _, _ in false }, postPaste: { postCount += 1; return true },
                                                       scheduleRestore: { scheduled.append($0) })
                check("paste: failed clipboard write restores prior formats without posting (restore=\(restore))", !submitted && postCount == 0 && isRestored() && scheduled.isEmpty, "")
            } catch { check("paste: failed clipboard write returns a recoverable failure", false, error.localizedDescription) }
        }

        seedClipboard()
        do {
            _ = try TextInserter.paste("Synthetic submitted text.", restore: true, targetIsCurrent: { true }, pasteboard: board,
                                       postPaste: { true }, scheduleRestore: { scheduled.append($0) })
            board.clearContents()
            board.setString("A later independent copy.", forType: .string)
            runScheduledRestore()
            check("paste: delayed restoration never overwrites a newer clipboard copy", board.string(forType: .string) == "A later independent copy.", "")
        } catch { check("paste: later-copy ownership fixture", false, error.localizedDescription) }

        seedClipboard()
        do {
            let submitted = try TextInserter.paste(longText, restore: false, targetIsCurrent: { true }, pasteboard: board,
                                                   postPaste: { true }, scheduleRestore: { scheduled.append($0) })
            check("paste: disabling successful restoration leaves the complete dictated text", submitted && board.string(forType: .string) == longText && scheduled.isEmpty, "")
        } catch { check("paste: disabled restoration fixture", false, error.localizedDescription) }

        board.clearContents()
        do {
            _ = try TextInserter.paste(longText, restore: true, targetIsCurrent: { true }, pasteboard: board,
                                       postPaste: { true }, scheduleRestore: { scheduled.append($0) })
            runScheduledRestore()
            check("paste: restoring an originally empty clipboard leaves it empty", (board.pasteboardItems ?? []).isEmpty, "")
        } catch { check("paste: empty original clipboard fixture", false, error.localizedDescription) }

        for reverseCallbacks in [false, true] {
            seedClipboard()
            scheduled = []
            do {
                _ = try TextInserter.paste("First overlapping insertion.", restore: true, targetIsCurrent: { true }, pasteboard: board,
                                           postPaste: { true }, scheduleRestore: { scheduled.append($0) })
                _ = try TextInserter.paste("Second overlapping insertion.", restore: true, targetIsCurrent: { true }, pasteboard: board,
                                           postPaste: { true }, scheduleRestore: { scheduled.append($0) })
                if reverseCallbacks { scheduled.reverse() }
                while !scheduled.isEmpty { runScheduledRestore() }
                check("paste: overlapping successful pastes restore the user's original formats (reverseCallbacks=\(reverseCallbacks))", isRestored(), "")
            } catch { check("paste: overlapping success fixture", false, error.localizedDescription) }
        }
        seedClipboard()
        scheduled = []
        do {
            _ = try TextInserter.paste("First temporary insertion.", restore: true, targetIsCurrent: { true }, pasteboard: board,
                                       postPaste: { true }, scheduleRestore: { scheduled.append($0) })
            let secondSubmitted = try TextInserter.paste("Second failed insertion.", restore: true, targetIsCurrent: { true }, pasteboard: board,
                                                         postPaste: { false }, scheduleRestore: { scheduled.append($0) })
            while !scheduled.isEmpty { runScheduledRestore() }
            check("paste: failure during overlapping insertion restores the original clipboard", !secondSubmitted && isRestored(), "")
        } catch { check("paste: overlapping failure fixture", false, error.localizedDescription) }

        seedClipboard()
        scheduled = []
        do {
            _ = try TextInserter.paste("Earlier temporary insertion.", restore: true, targetIsCurrent: { true }, pasteboard: board,
                                       postPaste: { true }, scheduleRestore: { scheduled.append($0) })
            board.clearContents()
            board.setString("Independent clipboard between dictations.", forType: .string)
            _ = try TextInserter.paste("Later temporary insertion.", restore: true, targetIsCurrent: { true }, pasteboard: board,
                                       postPaste: { true }, scheduleRestore: { scheduled.append($0) })
            while !scheduled.isEmpty { runScheduledRestore() }
            check("paste: an external copy breaks the ownership chain between dictations", board.string(forType: .string) == "Independent clipboard between dictations.", "")
        } catch { check("paste: external copy between overlapping pastes", false, error.localizedDescription) }

        seedClipboard()
        scheduled = []
        do {
            _ = try TextInserter.paste("Earlier temporary insertion.", restore: true, targetIsCurrent: { true }, pasteboard: board,
                                       postPaste: { true }, scheduleRestore: { scheduled.append($0) })
            _ = try TextInserter.paste("The user chose to retain this insertion.", restore: false, targetIsCurrent: { true }, pasteboard: board,
                                       postPaste: { true }, scheduleRestore: { scheduled.append($0) })
            while !scheduled.isEmpty { runScheduledRestore() }
            check("paste: a later restore-disabled insertion stays on the clipboard", board.string(forType: .string) == "The user chose to retain this insertion.", "")
        } catch { check("paste: mixed restoration preferences fixture", false, error.localizedDescription) }

        seedClipboard()
        scheduled = []
        var validationCount = 0
        do {
            _ = try TextInserter.paste("A new temporary insertion.", restore: true, targetIsCurrent: {
                validationCount += 1
                if validationCount == 1 {
                    board.clearContents()
                    board.setString("Copied during the initial focus check.", forType: .string)
                }
                return true
            }, pasteboard: board, postPaste: { true }, scheduleRestore: { scheduled.append($0) })
            while !scheduled.isEmpty { runScheduledRestore() }
            check("paste: initial focus validation cannot make the clipboard snapshot stale", board.string(forType: .string) == "Copied during the initial focus check.", "")
        } catch { check("paste: copy during initial focus validation fixture", false, error.localizedDescription) }

        seedClipboard()
        scheduled = []
        validationCount = 0
        var wrongTextPostCount = 0
        do {
            let submitted = try TextInserter.paste("Only this dictated text may be submitted.", restore: true, targetIsCurrent: {
                validationCount += 1
                if validationCount == 2 {
                    board.clearContents()
                    board.setString("An independent copy before key submission.", forType: .string)
                }
                return true
            }, pasteboard: board, postPaste: { wrongTextPostCount += 1; return true }, scheduleRestore: { scheduled.append($0) })
            while !scheduled.isEmpty { runScheduledRestore() }
            check("paste: a clipboard change before Cmd-V prevents the wrong text being sent", !submitted && wrongTextPostCount == 0 && board.string(forType: .string) == "An independent copy before key submission.", "")
        } catch { check("paste: clipboard ownership loss before submission fixture", false, error.localizedDescription) }
    }
}
