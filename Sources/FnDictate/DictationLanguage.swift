import Foundation

/// Spoken-language preferences. Chinese writing style is a separate, contextual choice.
struct DictationLanguage: Identifiable, Equatable {
    let code: String
    let name: String
    var id: String { code }
    var englishName: String { Locale(identifier: "en").localizedString(forLanguageCode: code) ?? name }

    static let all: [DictationLanguage] = [
        .init(code: "en", name: "English"), .init(code: "zh", name: "中文"),
        .init(code: "ja", name: "日本語"), .init(code: "ko", name: "한국어"),
        .init(code: "es", name: "Español"), .init(code: "fr", name: "Français"),
        .init(code: "de", name: "Deutsch"), .init(code: "it", name: "Italiano"),
        .init(code: "pt", name: "Português"), .init(code: "nl", name: "Nederlands"),
        .init(code: "ar", name: "العربية"), .init(code: "hi", name: "हिन्दी"),
        .init(code: "vi", name: "Tiếng Việt"), .init(code: "th", name: "ไทย"),
        .init(code: "id", name: "Bahasa Indonesia"), .init(code: "ms", name: "Bahasa Melayu"),
        .init(code: "ru", name: "Русский"), .init(code: "uk", name: "Українська"),
        .init(code: "pl", name: "Polski"), .init(code: "tr", name: "Türkçe"),
        .init(code: "sv", name: "Svenska"), .init(code: "da", name: "Dansk"),
        .init(code: "no", name: "Norsk"), .init(code: "fi", name: "Suomi"),
        .init(code: "el", name: "Ελληνικά"), .init(code: "he", name: "עברית"),
        .init(code: "cs", name: "Čeština"), .init(code: "sk", name: "Slovenčina"),
        .init(code: "hu", name: "Magyar"), .init(code: "ro", name: "Română"),
        .init(code: "bg", name: "Български"), .init(code: "hr", name: "Hrvatski"),
        .init(code: "sr", name: "Српски"), .init(code: "sl", name: "Slovenščina"),
        .init(code: "ca", name: "Català"), .init(code: "fa", name: "فارسی"),
        .init(code: "ta", name: "தமிழ்"), .init(code: "te", name: "తెలుగు"),
        .init(code: "bn", name: "বাংলা"), .init(code: "ur", name: "اردو"),
        .init(code: "tl", name: "Filipino"), .init(code: "sw", name: "Kiswahili"),
        .init(code: "af", name: "Afrikaans"), .init(code: "is", name: "Íslenska"),
        .init(code: "lt", name: "Lietuvių"), .init(code: "lv", name: "Latviešu"),
        .init(code: "et", name: "Eesti")
    ]

    static var systemDefault: [String] {
        for locale in Locale.preferredLanguages {
            let base = locale.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "en"
            let code = base == "nb" || base == "nn" ? "no" : base
            if all.contains(where: { $0.code == code }) { return [code] }
        }
        return ["en"]
    }

    static func normalized(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        let valid = codes.filter { code in all.contains(where: { $0.code == code }) && seen.insert(code).inserted }
        return valid.isEmpty ? systemDefault : valid
    }

    static func name(for code: String) -> String { all.first { $0.code == code }?.name ?? code }
}
