import Foundation

/// In mixed Chinese/English prose, an English function word can carry a deadline or
/// condition. A semantic model must not silently approve translating or dropping it.
enum MixedLanguageGuard {
    private static let words = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])[A-Za-z][A-Za-z0-9]*(?:['’][A-Za-z]+)?"#)
    private static let fillerSounds: Set<String> = ["um", "uh", "uhm", "umm", "erm", "hmm"]

    static func preservesEnglishWords(from source: String, in output: String) -> Bool {
        let original = DictationPunctuation.proseWithoutLiterals(source)
        guard original.unicodeScalars.contains(where: { $0.properties.isIdeographic }) else { return true }
        func tokens(_ text: String) -> [String] {
            let prose = DictationPunctuation.proseWithoutLiterals(text)
            let string = prose as NSString
            return words.matches(in: prose, range: NSRange(prose.startIndex..., in: prose))
                .map { string.substring(with: $0.range).lowercased().replacingOccurrences(of: "’", with: "'") }
                .filter { !fillerSounds.contains($0) }
        }
        let proposed = tokens(output)
        if tokens(original) == proposed { return true }
        // Compare the final explicitly corrected wording as well. This does not
        // remove independent occurrences of an abandoned name/day elsewhere, and
        // literal integrity remains a separate mandatory check in both modes.
        return tokens(MeaningGuard.resolveExplicitCorrections(original)) == proposed
    }
}
