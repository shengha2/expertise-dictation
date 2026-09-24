import Foundation

enum LongTextProcessing {
    /// Keep provider output budgets and edit-distance checks bounded. Concatenating these
    /// chunks reproduces the input byte-for-byte; no prefix or suffix is dropped.
    static func chunks(_ text: String, limit: Int = 1800) -> [String] {
        precondition(limit > 0)
        let characters = Array(text)
        let literalRanges = DictationPunctuation.literalRanges(in: text)
        let emailRanges = EmailAddressFormatting.ranges(in: text)
        // Convert only requested UTF-16 endpoints in one pass. Repeated String.distance
        // from the start for every literal becomes quadratic on long dictations.
        let endpoints = Set((literalRanges + emailRanges).flatMap { [$0.location, NSMaxRange($0)] })
        var characterOffsets: [Int: Int] = [:]
        var utf16Offset = 0
        for (index, character) in characters.enumerated() {
            if endpoints.contains(utf16Offset) { characterOffsets[utf16Offset] = index }
            utf16Offset += String(character).utf16.count
        }
        characterOffsets[utf16Offset] = characters.count
        func characterRange(_ range: NSRange) -> Range<Int>? {
            guard let start = characterOffsets[range.location], let end = characterOffsets[NSMaxRange(range)] else { return nil }
            return start..<end
        }
        // Huge code blocks, quotations and URLs cannot exempt a request from its budget.
        // Existing bounded email addresses retain their atomic exemption for small test
        // limits; with the production limit they too are always within budget.
        let literals = literalRanges.compactMap(characterRange).filter { $0.count <= limit }
        let emails = emailRanges.compactMap(characterRange)
        let protected = literals + emails
        var safeBoundary = [Bool](repeating: true, count: characters.count + 1)
        for range in protected where range.count > 1 {
            for index in (range.lowerBound + 1)..<range.upperBound { safeBoundary[index] = false }
        }
        var result: [String] = []
        var offset = 0
        while offset < characters.count {
            var end = min(offset + limit, characters.count)
            if end < characters.count {
                let lower = max(offset + limit / 2, offset + 1)
                let candidates = (lower..<end).reversed()
                // Preserve existing paragraphs/lines before considering sentence endings
                // or ordinary spaces. A fragment plus preceding context can tempt a model
                // to repeat or invent the remainder of an adjacent paragraph.
                let boundary = candidates.first(where: { safeBoundary[$0 + 1] && characters[$0].isNewline }) ??
                    candidates.first(where: { safeBoundary[$0 + 1] && ".!?。！？".contains(characters[$0]) }) ??
                    candidates.first(where: { safeBoundary[$0 + 1] && characters[$0].isWhitespace })
                if let boundary {
                    end = boundary + 1
                }
            }
            if !safeBoundary[end], let literal = protected.first(where: { $0.lowerBound < end && end < $0.upperBound }) {
                end = literal.lowerBound > offset ? literal.lowerBound : literal.upperBound
            }
            result.append(String(characters[offset..<end]))
            offset = end
        }
        return result
    }

    struct CleanupResult {
        var text: String
        var usedLLM: Bool
        var fallbackCount: Int
        var guardFallbackCount: Int
        var lastError: String?
        var providerFallbackCount: Int { fallbackCount - guardFallbackCount }
        var requiresRecovery: Bool { lastError != nil }
    }

    private static func startsBullet(_ text: String) -> Bool {
        let characters = text.drop(while: { $0.isWhitespace })
        guard let marker = characters.first, "-•*".contains(marker) else { return false }
        let remainder = characters.dropFirst()
        return remainder.first == " " || remainder.first == "\t"
    }

    private static let numberedItem = try! NSRegularExpression(pattern: #"^\s*([0-9]{1,6})[.)、][ \t]+"#)
    private static func leadingItemNumber(_ text: String) -> Int? {
        let source = text as NSString
        guard let match = numberedItem.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else { return nil }
        return Int(source.substring(with: match.range(at: 1)))
    }

    private static func continuesNumberedList(previous: String, next: String) -> Bool {
        guard let nextNumber = leadingItemNumber(next),
              let previousNumber = previous.components(separatedBy: .newlines).reversed().compactMap({ leadingItemNumber($0) }).first else { return false }
        return nextNumber == previousNumber + 1
    }

    private static func join(_ outputs: [String], source pieces: [String],
                             rewriteStyle: RewriteStyle, acceptedSections: Set<Int>) -> String {
        guard var result = outputs.first else { return "" }
        for index in 1..<outputs.count {
            let left = String(pieces[index - 1].reversed().prefix(while: { $0.isWhitespace }).reversed())
            let right = String(pieces[index].prefix(while: { $0.isWhitespace }))
            let originalSeparator = left + right
            let sentenceBoundary = pieces[index - 1].last.map { ".!?。！？".contains($0) } ?? false
            let newBullet = startsBullet(outputs[index]) && !startsBullet(pieces[index])
            // Existing numbered markers are content, so they pass the numeric checks
            // unchanged. A consecutive item continues a list only when the preceding
            // approved section already contains a numbered item; a date/amount at an
            // ordinary prose boundary must not invent a new paragraph.
            let nextNumberedItem = acceptedSections.contains(index - 1) &&
                continuesNumberedList(previous: outputs[index - 1], next: outputs[index])
            if acceptedSections.contains(index), newBullet || nextNumberedItem,
               !originalSeparator.contains(where: { $0.isNewline }),
               !originalSeparator.isEmpty || sentenceBoundary {
                // An approved new list item must stay on its own line. Raw fallback
                // sections and forced mid-word cuts keep their original boundaries.
                while result.last?.isWhitespace == true { result.removeLast() }
                result += "\n" + outputs[index].drop(while: { $0.isWhitespace })
            } else if originalSeparator.isEmpty {
                // A forced cut can occur inside CJK text or an unbroken identifier.
                result += outputs[index]
            } else {
                // Postprocessing trims sections, while a raw fallback retains whitespace.
                // Restore exactly the original boundary once, including any newline.
                while result.last?.isWhitespace == true { result.removeLast() }
                result += originalSeparator + outputs[index].drop(while: { $0.isWhitespace })
            }
        }
        return result
    }

    private struct CleanupOptions {
        let timeout: TimeInterval
        let skipVerifierWhenVerbatim: Bool
        let guardThreshold: Double
    }

    private struct SectionResult {
        let index: Int
        let proposed: String?
        let accepted: Bool
        let reason: String
        let error: String?
    }

    private static func startsParagraph(_ index: Int, pieces: [String]) -> Bool {
        guard index > 0 else { return false }
        return pieces[index - 1].reversed().prefix(while: { $0.isWhitespace }).contains(where: { $0.isNewline }) ||
            pieces[index].prefix(while: { $0.isWhitespace }).contains(where: { $0.isNewline })
    }

    private static func cleanSection(index: Int, piece: String, ctx: CleanupContext,
                                     options: CleanupOptions, client: LLMClient) async throws -> SectionResult {
        try Task.checkCancellation()
        do {
            let requestStart = Date()
            let response = try await client.complete(system: CleanupPrompt.system(ctx), user: CleanupPrompt.user(transcript: piece, ctx),
                                                      maxTokens: CleanupPrompt.maxTokens(for: piece), timeout: options.timeout)
            try Task.checkCancellation()
            let modelMs = Int(Date().timeIntervalSince(requestStart) * 1000)
            let cleaned = DictationPunctuation.normalizeChinese(DictationPunctuation.formatSpokenAddresses(CleanupPrompt.postprocess(response)))
            let accepted: Bool
            let reason: String
            if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // An empty completed model response can be correct for hesitation-only
                // speech. Never let broad filler skeletons erase meaningful short text.
                accepted = LocalCleanup.isEmptyOrHesitationOnly(Replacements.apply(ctx.replacements, to: piece))
                reason = accepted ? "empty or hesitation-only transcript" : "non-filler content would be erased"
            } else if ctx.rewriteStyle == .full {
                if options.skipVerifierWhenVerbatim,
                   RewriteVerification.isNearVerbatim(raw: piece, rewritten: cleaned, replacements: ctx.replacements) {
                    accepted = true
                    reason = "near-verbatim rewrite, semantic check skipped"
                    Log.info("Cleanup section \(index + 1): rewrite \(modelMs) ms, semantic check skipped (near-verbatim)")
                } else {
                    let verifyStart = Date()
                    accepted = try await RewriteVerification.accepts(raw: Replacements.apply(ctx.replacements, to: piece), rewritten: cleaned,
                                                                     client: client, timeout: options.timeout)
                    reason = accepted ? "semantic check accepted" : "semantic check rejected"
                    Log.info("Cleanup section \(index + 1): rewrite \(modelMs) ms, semantic check \(Int(Date().timeIntervalSince(verifyStart) * 1000)) ms")
                }
            } else {
                Log.info("Cleanup section \(index + 1): model \(modelMs) ms\(ctx.compact ? " (compact prompt)" : "")")
                let verdict = MeaningGuard.evaluate(raw: piece, cleaned: cleaned, threshold: options.guardThreshold,
                                                    replacements: ctx.replacements)
                let literalsMatch = DictationPunctuation.preservesLiterals(from: Replacements.apply(ctx.replacements, to: piece), in: cleaned)
                let languagesMatch = MixedLanguageGuard.preservesEnglishWords(from: Replacements.apply(ctx.replacements, to: piece), in: cleaned)
                if !verdict.accepted && verdict.canVerifyFalseStart && literalsMatch && languagesMatch {
                    accepted = try await RewriteVerification.accepts(raw: Replacements.apply(ctx.replacements, to: piece),
                                                                     rewritten: cleaned, client: client,
                                                                     timeout: options.timeout, lightFalseStart: true)
                    reason = accepted ? "Light false-start semantic check accepted" : "Light false-start semantic check rejected"
                } else {
                    accepted = verdict.accepted && literalsMatch && languagesMatch
                    reason = !literalsMatch ? "a URL, code fragment or literal value changed" :
                        (!languagesMatch ? "English words in a mixed-language transcript changed" : verdict.reason)
                }
            }

            try Task.checkCancellation()
            return SectionResult(index: index, proposed: cleaned, accepted: accepted, reason: reason, error: nil)
        } catch is CancellationError { throw CancellationError() }
        catch {
            // URLSession may report cancellation as URLError.cancelled. A cancelled
            // dictation must never deliver a partial batch or a provider-failure banner.
            try Task.checkCancellation()
            return SectionResult(index: index, proposed: nil, accepted: false, reason: "", error: error.localizedDescription)
        }
    }

    static func cleanup(_ raw: String, context: CleanupContext, settings: Settings,
                        client suppliedClient: LLMClient? = nil,
                        inspectSection: ((Int, String, String, Bool, String) -> Void)? = nil,
                        progress: @escaping (Int, Int) -> Void) async throws -> CleanupResult {
        let formatted = DictationPunctuation.formatSpokenAddresses(raw)
        let pieces = chunks(formatted)
        let client: LLMClient
        do { client = try suppliedClient ?? LLMFactory.make(model: settings.cleanupModel, settings: settings) }
        catch { return CleanupResult(text: formatted, usedLLM: false, fallbackCount: pieces.count, guardFallbackCount: 0, lastError: error.localizedDescription) }
        var outputs: [String] = []
        var acceptedSections: Set<Int> = []
        var fallbackCount = 0
        var guardFallbackCount = 0
        var lastError: String?
        // Snapshot preferences once: workers never read mutable settings while awaiting
        // the provider. Custom/stateful clients keep serial execution unless they opt in.
        let options = CleanupOptions(timeout: max(settings.llmTimeout, 15),
                                     skipVerifierWhenVerbatim: settings.skipVerifierWhenVerbatim,
                                     guardThreshold: settings.guardStrictness.threshold)
        var index = 0
        while index < pieces.count {
            try Task.checkCancellation()
            if lastError != nil {
                // After one provider failure, keep every remaining section immediately.
                outputs.append(contentsOf: pieces[index...])
                fallbackCount += pieces.count - index
                break
            }
            var firstContext = context
            if index > 0 {
                firstContext.precedingText = startsParagraph(index, pieces: pieces) ? nil : String(outputs.last?.suffix(300) ?? "")
            }
            // Only a new source paragraph is independent of the previous output. A
            // continuation, sentence split, URL or forced CJK cut stays strictly serial.
            let batchEnd = client.supportsConcurrentRequests && index + 1 < pieces.count && startsParagraph(index + 1, pieces: pieces)
                ? index + 2 : index + 1
            var results: [SectionResult] = []
            if batchEnd == index + 1 {
                progress(index + 1, pieces.count)
                results = [try await cleanSection(index: index, piece: pieces[index], ctx: firstContext, options: options, client: client)]
            } else {
                progress(batchEnd, pieces.count)
                var secondContext = context
                secondContext.precedingText = nil
                let firstIndex = index
                let contexts = (firstContext, secondContext)
                results = try await withThrowingTaskGroup(of: SectionResult.self) { group in
                    group.addTask { try await cleanSection(index: firstIndex, piece: pieces[firstIndex], ctx: contexts.0, options: options, client: client) }
                    group.addTask { try await cleanSection(index: firstIndex + 1, piece: pieces[firstIndex + 1], ctx: contexts.1, options: options, client: client) }
                    var completed: [SectionResult] = []
                    for try await result in group { completed.append(result) }
                    return completed.sorted { $0.index < $1.index }
                }
            }
            try Task.checkCancellation()
            // Results and callbacks always follow source order, even when the second
            // request finishes first. If an earlier request failed, discard its in-flight
            // sibling's output too and preserve the same raw suffix as serial processing.
            for result in results {
                let piece = pieces[result.index]
                if lastError != nil {
                    outputs.append(piece)
                    fallbackCount += 1
                } else if let error = result.error {
                    outputs.append(piece)
                    fallbackCount += 1
                    lastError = error
                } else if let proposed = result.proposed {
                    inspectSection?(result.index + 1, piece, proposed, result.accepted, result.reason)
                    if result.accepted {
                        outputs.append(proposed)
                        acceptedSections.insert(result.index)
                    } else {
                        outputs.append(piece)
                        fallbackCount += 1
                        guardFallbackCount += 1
                        Log.info("Cleanup section \(result.index + 1) retained its original wording")
                    }
                }
            }
            index = batchEnd
        }
        let joined = fallbackCount == pieces.count ? formatted : join(outputs, source: pieces, rewriteStyle: context.rewriteStyle, acceptedSections: acceptedSections)
        if fallbackCount < pieces.count {
            // A literal or language switch can cross a section boundary. Validate the
            // complete result without enlarging requests or making a repair/retry call.
            let expected = Replacements.apply(context.replacements, to: formatted)
            let proposed = Replacements.apply(context.replacements, to: joined)
            if !DictationPunctuation.preservesLiterals(from: expected, in: proposed) ||
                !MixedLanguageGuard.preservesEnglishWords(from: expected, in: proposed) {
                Log.info("Joined cleanup retained its original: cross-section literal or mixed-language integrity check rejected")
                let acceptedCount = pieces.count - fallbackCount
                return CleanupResult(text: formatted, usedLLM: false, fallbackCount: pieces.count,
                                     guardFallbackCount: guardFallbackCount + acceptedCount, lastError: lastError)
            }
        }
        return CleanupResult(text: joined, usedLLM: fallbackCount < pieces.count,
                             fallbackCount: fallbackCount, guardFallbackCount: guardFallbackCount, lastError: lastError)
    }
}
