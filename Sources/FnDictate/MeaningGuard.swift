import Foundation

/// Guards against the LLM rewriting what the user said. Both texts are reduced to a "skeleton"
/// (content tokens with fillers, punctuation and case removed) and compared with an edit
/// distance; unsafe changes retain the complete original section.
enum MeaningGuard {
    struct Verdict {
        let accepted: Bool
        let ratio: Double
        let reason: String
        var canVerifyFalseStart = false
    }

    static let fillerTokens: Set<String> = [
        "um", "uh", "uhm", "umm", "er", "erm", "ah", "mm", "hmm", "huh",
        "basically", "actually", "literally", "okay", "ok", "so", "yeah",
        "嗯", "呃", "啊", "哦",
    ]

    // These are comparison-only repairs, never edits to the user's transcript. Each
    // correction has an explicit marker; unresolved alternatives stay in the source.
    // A non-Han word boundary keeps adjacent Chinese prose out of a corrected name,
    // while retaining accented, Cyrillic and other alphabetic names supported before.
    private static let correctionWord = #"[\p{L}\p{N}&&[^\p{Han}]]"#
    private static let repairs: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"(?i)(?<!\#(correctionWord))(\#(correctionWord)+)[\s,?.!—–-]+(?:no[\s,]+)+not\s+\1\s*[,，—–]\s*(\#(correctionWord)+)(?!\#(correctionWord))"#), "$2"),
        (try! NSRegularExpression(pattern: #"(?i)(?<!\#(correctionWord))(\#(correctionWord)+)[\s,—–-]+no\s*,?\s*(?:wait|make\s+that)\s*[,—–-]?\s*(\#(correctionWord)+)(?!\#(correctionWord))"#), "$2"),
        (try! NSRegularExpression(pattern: #"(?i)(?<!\#(correctionWord))(\#(correctionWord)+)\s*[,，—–]\s*sorry(?:\s+i\s+mean)?\s*[,，—–]\s*(\#(correctionWord)+)(?!\#(correctionWord))"#), "$2"),
        (try! NSRegularExpression(pattern: #"(周[一二三四五六日天])\s*[,，]\s*不[对對]\s*[,，]\s*(周[一二三四五六日天])"#), "$2"),
        // A duration correction must name the same unit twice and include both
        // separators around its explicit correction marker. Independent durations
        // and negations outside that exact span remain in the comparison.
        (try! NSRegularExpression(pattern: #"([零〇一二三四五六七八九十百千万兩两0-9]+)(周|週|天|小时|小時|分钟|分鐘|个月|個月|年)\s*[,，]\s*不[对對]\s*[,，]\s*([零〇一二三四五六七八九十百千万兩两0-9]+)\2"#), "$3$2"),
        // A common ASR omission is both commas around an explicit weekday correction.
        // Require a following action; a question or comparison of weekday arrangements
        // ("周二不对吗", "周二不对周三的安排也有问题") is not this repair.
        (try! NSRegularExpression(pattern: #"(?<!不是)(周[一二三四五六日天])\s*不[对對]\s*(周[一二三四五六日天])(?=去|来|來|开会|開會|测试|測試|发布|發布|提交|交付|见面|見面|出发|出發|到达|到達|上线|上線)"#), "$2"),
    ]
    private static let protectedValues = try! NSRegularExpression(
        pattern: #"(?i)[+-]?[0-9]+(?:[.,:/-][0-9]+)*|\b(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion)\b"#)
    private static let durationValues = try! NSRegularExpression(
        pattern: #"[零〇一二三四五六七八九十百千万兩两0-9]+(?:周|週|天|小时|小時|分钟|分鐘|个月|個月|年)"#)
    private static let negations = try! NSRegularExpression(
        pattern: #"(?i)\b(?:no|not|never|neither|nor|without|cannot|[a-z]+n['’]t)\b|[不沒没無无未別别]"#)
    private static let currencies = try! NSRegularExpression(pattern: #"(?i)[$€£¥]|\b(?:dollars?|euros?|pounds?|yen|yuan|usd|eur|gbp|jpy|cny|cad|aud)\b"#)
    private static let smallNumbers = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10"]

    private static func matches(_ expression: NSRegularExpression, in text: String) -> [String] {
        let source = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range).lowercased() }
    }

    static func resolveExplicitCorrections(_ text: String) -> String {
        repairs.reduce(text) { value, repair in
            repair.0.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: repair.1)
        }
    }

    // "One more thing:" is a sentence-introducing discourse marker, not an amount.
    // Require a statement boundary and a colon; "one more thing is missing" and
    // "please buy one more thing" remain ordinary content with a protected number.
    private static let additionalPoint = try! NSRegularExpression(pattern: #"(?im)(^|[.!?][ \t]+|\n)(?:actually,[ \t]+)?one more thing[ \t]*:[ \t]*"#)
    private static func withoutAdditionalPointMarker(_ text: String) -> String {
        additionalPoint.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    }
    private static func retainsAdditionalPointPhrase(_ text: String) -> Bool {
        let words = tokens(DictationPunctuation.proseWithoutLiterals(text))
        guard words.count >= 3 else { return false }
        return (0...(words.count - 3)).contains { Array(words[$0..<($0 + 3)]) == ["one", "more", "thing"] }
    }

    // Used only by the optional discourse-marker comparison. A retained/rephrased
    // marker's "one" must not stand in for a deleted real quantity such as "one
    // backup". Preserve ordered numeric anchors and their next two content tokens.
    // Conservative fallback is preferable when that surrounding context changes.
    private static func numberContextSignature(_ text: String) -> [[String]] {
        let grammar: Set<String> = ["a", "an", "the", "i", "we", "you", "it", "is", "are", "was", "were", "be", "been", "to", "of", "and", "that", "this", "there"]
        let words = comparisonTokens(text).filter { !grammar.contains($0) }
        return words.indices.compactMap { index in
            guard !matches(protectedValues, in: words[index]).isEmpty else { return nil }
            return Array(words[index..<min(words.count, index + 3)])
        }
    }

    private static let falseStart = try! NSRegularExpression(pattern: #"(?i)[,，—–]\s*i\s+mean(?:\s*[,，]\s*|\s+)"#)
    private static func hasExplicitFalseStart(_ text: String) -> Bool {
        let prose = DictationPunctuation.proseWithoutLiterals(text)
        return falseStart.firstMatch(in: prose, range: NSRange(prose.startIndex..., in: prose)) != nil
    }

    private static func collapseStutters(_ source: [String]) -> [String] {
        var result = source
        let restartArticles: Set<String> = ["a", "an", "the"]
        let repeatableWords: Set<String> = ["a", "an", "the", "i", "we", "you", "it", "is", "are", "to", "on", "please", "can", "could", "would"]
        var start = 0
        while start < result.count {
            var removed = false
            let maximum = min(12, (result.count - start) / 2)
            if maximum > 0 {
                for length in stride(from: maximum, through: 1, by: -1) {
                    // Restrict repairs to conversational restarts. Repeated item names or
                    // whole anchored clauses may be deliberate and must remain counted.
                    if !repeatableWords.contains(result[start]) { continue }
                    for gap in 0...2 {
                        let next = start + length + gap
                        guard next + length <= result.count,
                              result[(start + length)..<next].allSatisfy({ restartArticles.contains($0) }),
                              result[start..<(start + length)].elementsEqual(result[next..<(next + length)]) else { continue }
                        result.removeSubrange(start..<next)
                        removed = true
                        break
                    }
                    if removed { break }
                }
            }
            if !removed { start += 1 }
        }
        return result
    }

    static func tokens(_ text: String) -> [String] {
        let lowered = text.lowercased().applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text.lowercased()
        var out: [String] = []
        var word = ""
        func flush() {
            if !word.isEmpty { out.append(word); word = "" }
        }
        for scalar in lowered.unicodeScalars {
            if scalar.properties.isIdeographic {
                flush()
                out.append(String(scalar))
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                word.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    static func skeleton(_ text: String) -> [String] {
        tokens(text).filter { !fillerTokens.contains($0) }
    }

    private static func comparisonTokens(_ text: String) -> [String] {
        // Amounts and currency identity are checked separately below. Their conventional
        // formatting must compare consistently in content and ending checks as well.
        skeleton(text).filter { $0 != "dollar" && $0 != "dollars" }.map { smallNumbers[$0] ?? $0 }
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    static func evaluate(raw: String, cleaned: String, threshold: Double, replacements: [Replacement] = []) -> Verdict {
        let original = DictationPunctuation.formatSpokenAddresses(Replacements.apply(replacements, to: raw))
        guard EmailAddressFormatting.preservesAddresses(from: original, in: cleaned) else {
            return Verdict(accepted: false, ratio: 1, reason: "an email address changed")
        }
        let repaired = resolveExplicitCorrections(original)
        let additionalPointRemoved = withoutAdditionalPointMarker(repaired)
        var candidates = repaired == original ? [original] : [original, repaired]
        // If the output kept the marker, its "one" must still match the marker's
        // own "one", not compensate for a missing independent quantity elsewhere.
        if additionalPointRemoved != repaired && !retainsAdditionalPointPhrase(cleaned) {
            candidates.append(additionalPointRemoved)
        }
        let b = comparisonTokens(cleaned)
        var best = Verdict(accepted: false, ratio: 1, reason: "output did not preserve the transcript")
        var semanticCandidate: Verdict?
        for source in candidates {
            // A tiny edit ratio in a long paragraph must never excuse a changed amount,
            // reference code, or dropped negation. Ambiguous formatting safely keeps raw text.
            let sourceNumbers = matches(protectedValues, in: source).map { smallNumbers[$0] ?? $0 }
            let outputNumbers = matches(protectedValues, in: cleaned).map { smallNumbers[$0] ?? $0 }
            guard sourceNumbers == outputNumbers else {
                best = Verdict(accepted: false, ratio: 1, reason: "a number changed"); continue
            }
            if source == additionalPointRemoved && source != repaired,
               numberContextSignature(source) != numberContextSignature(cleaned) {
                best = Verdict(accepted: false, ratio: 1, reason: "a number's context changed"); continue
            }
            // Chinese numerals are single-character tokens, so edit distance alone
            // could excuse 八周 becoming 九周 after removing a correction marker.
            // Keep every final duration, including independent repeated mentions.
            func durationSignature(_ text: String) -> [String] {
                matches(durationValues, in: text).map {
                    $0.replacingOccurrences(of: "週", with: "周").replacingOccurrences(of: "時", with: "时")
                        .replacingOccurrences(of: "鐘", with: "钟").replacingOccurrences(of: "個", with: "个")
                        .replacingOccurrences(of: "兩", with: "两")
                }
            }
            guard durationSignature(source) == durationSignature(cleaned) else {
                best = Verdict(accepted: false, ratio: 1, reason: "a duration changed"); continue
            }
            func currencySignature(_ text: String) -> [String] {
                matches(currencies, in: text).map { $0 == "dollar" || $0 == "dollars" ? "$" : $0 }
            }
            guard currencySignature(source) == currencySignature(cleaned) else {
                best = Verdict(accepted: false, ratio: 1, reason: "a currency changed"); continue
            }
            func polarity(_ text: String) -> [String] {
                matches(negations, in: text).map { $0 == "cannot" || $0.hasSuffix("n't") || $0.hasSuffix("n’t") ? "not" : $0 }
            }
            guard polarity(source) == polarity(cleaned) else {
                best = Verdict(accepted: false, ratio: 1, reason: "a negation changed"); continue
            }
            let originalTokens = comparisonTokens(source)
            for a in [originalTokens, collapseStutters(originalTokens)] {
                if a.isEmpty {
                    if b.isEmpty { return Verdict(accepted: true, ratio: 0, reason: "nothing to compare") }
                    continue
                }
                if b.isEmpty { best = Verdict(accepted: false, ratio: 1, reason: "output empty"); continue }
                let lenRatio = Double(b.count) / Double(a.count)
                guard lenRatio >= 0.35 && lenRatio <= 1.6 else {
                    best = Verdict(accepted: false, ratio: 1, reason: "output length changed too much"); continue
                }
                // An edit ratio can hide a single lost name or instruction in a long text.
                // Allow grammatical tightening, but not removal of a unique content word.
                // CJK is tokenized by character, so whole-word uniqueness is not inferred.
                let grammar: Set<String> = ["a", "an", "the", "i", "we", "you", "it", "is", "are", "was", "were", "be", "been", "to", "of", "and", "that", "this", "there"]
                let outputWords = Set(b)
                let missingContent = a.contains(where: { $0.count > 1 && !grammar.contains($0) && !outputWords.contains($0) })
                // End-of-response truncation can affect a tiny fraction of a long section.
                // Keep its final content tokens even when the global ratio would pass.
                let ending = Array(a.suffix(min(3, a.count)))
                let outputEnding = Array(b.suffix(max(12, ending.count)))
                var matched = 0
                for token in outputEnding where matched < ending.count {
                    if token == ending[matched] { matched += 1 }
                }
                guard matched == ending.count else {
                    best = Verdict(accepted: false, ratio: 1, reason: "the ending changed or is missing"); continue
                }
                let dist = editDistance(a, b)
                let ratio = Double(dist) / Double(a.count)
                if missingContent {
                    // The exact-word guard cannot judge a false-start repair such as
                    // "the thing about X, I mean the important part". Never accept it
                    // locally: permit a semantic check only for a small edit after all
                    // protected facts and the complete ending passed their checks.
                    let canVerify = hasExplicitFalseStart(source) && dist <= 12 &&
                        ratio <= min(threshold, GuardStrictness.strict.threshold)
                    best = Verdict(accepted: false, ratio: ratio, reason: "a content word is missing", canVerifyFalseStart: canVerify)
                    // Each comparison spelling is an alternative, not an extra
                    // requirement. A later optional discourse-marker removal may
                    // fail its number check when the output retained that marker;
                    // it must not erase an earlier fully checked eligible spelling.
                    if canVerify, ratio < (semanticCandidate?.ratio ?? .infinity) {
                        semanticCandidate = best
                    }
                    continue
                }
                let slack = a.count < 8 ? 0.15 : 0.0
                let ok = ratio <= threshold + slack
                let verdict = Verdict(accepted: ok, ratio: ratio, reason: ok ? "ok" : "changed \(Int(ratio * 100))% of content words")
                if ok { return verdict }
                if ratio < best.ratio { best = verdict }
            }
        }
        return semanticCandidate ?? best
    }
}
