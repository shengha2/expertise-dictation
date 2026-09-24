import Foundation
import Combine

enum STTEngine: String, CaseIterable, Identifiable {
    case openAILive = "openai-live"
    case openAIPost = "openai-post"
    case assemblyAI = "assemblyai"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAILive: return "OpenAI gpt-live-transcribe — streams while you talk (fastest)"
        case .openAIPost: return "OpenAI gpt-transcribe — transcribes after release (more accurate)"
        case .assemblyAI: return "AssemblyAI Universal-3.5 Pro Realtime — strongest on mixed 中/English"
        }
    }

    var shortTitle: String {
        switch self {
        case .openAILive: return "OpenAI live"
        case .openAIPost: return "OpenAI post"
        case .assemblyAI: return "AssemblyAI"
        }
    }

    var providerName: String { self == .assemblyAI ? "AssemblyAI" : "OpenAI" }
    var keychainAccount: String { self == .assemblyAI ? "assemblyai" : "openai" }
    var sampleRate: Double { self == .assemblyAI ? 16000 : 24000 }
}

enum LiveDelay: String, CaseIterable, Identifiable {
    case minimal, low, medium, high, xhigh
    var id: String { rawValue }
    var title: String {
        switch self {
        case .minimal: return "Minimal — earliest text, most revisions"
        case .low: return "Low (recommended)"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high — best quality, slowest"
        }
    }
}

enum ChineseVariant: String, CaseIterable, Identifiable {
    case simplified, traditional
    var id: String { rawValue }
    var title: String { self == .simplified ? "Simplified (简体)" : "Traditional (繁體)" }
    var openAICode: String { self == .simplified ? "zh-cn" : "zh-tw" }
    var description: String { self == .simplified ? "Simplified Chinese" : "Traditional Chinese" }
}

/// What happens to the transcript before it is typed.
enum DictationMode: String, CaseIterable, Identifiable {
    case clean, light, verbatim, rewrite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clean: return "Clean — remove fillers and false starts with the LLM, keep your wording"
        case .light: return "Light — local filler removal only, no LLM (fastest)"
        case .verbatim: return "Verbatim — exactly what the transcriber heard"
        case .rewrite: return "Full rewrite — improve wording and structure, keep every detail"
        }
    }
    var menuTitle: String {
        switch self {
        case .clean: return "Light cleanup"
        case .light: return "Light (no LLM)"
        case .verbatim: return "Verbatim dictation"
        case .rewrite: return "Full rewrite"
        }
    }

    var usesLLM: Bool { self == .clean || self == .rewrite }
    var rewriteHelp: String {
        switch self {
        case .clean: return "Fix punctuation, fillers and false starts. Keep your wording."
        case .rewrite: return "Improve wording, use short paragraphs and list action items when helpful. Keep your meaning and details. Takes a little longer."
        case .light: return "Remove fillers locally without sending text for cleanup."
        case .verbatim: return "Keep the words returned by the transcriber."
        }
    }
}

enum CleanupModel: String, CaseIterable, Identifiable {
    case auto = "auto"
    case sonnet5 = "claude-sonnet-5"
    case haiku45 = "claude-haiku-4-5"
    case luna6 = "gpt-6-luna"
    case luna = "gpt-5.6-luna"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto — Claude Sonnet 5 when an Anthropic key is saved, otherwise GPT-6 Luna with the OpenAI key"
        case .sonnet5: return "Claude Sonnet 5 (Anthropic) — best judgement"
        case .haiku45: return "Claude Haiku 4.5 (Anthropic) — fastest Claude"
        case .luna6: return "GPT-6 Luna (OpenAI) — fast and efficient"
        case .luna: return "GPT-5.6 Luna (OpenAI) — legacy"
        }
    }

    var shortTitle: String {
        switch self {
        case .auto: return "Auto"
        case .sonnet5: return "Claude Sonnet 5"
        case .haiku45: return "Claude Haiku 4.5"
        case .luna6: return "GPT-6 Luna"
        case .luna: return "GPT-5.6 Luna (legacy)"
        }
    }

    /// The concrete model Auto stands for right now, given which keys exist.
    var resolved: CleanupModel {
        guard self == .auto else { return self }
        return resolved(hasAnthropicKey: Keychain.apiKey("anthropic") != nil)
    }
    /// Pure routing also lets migration checks run without reading real credentials.
    func resolved(hasAnthropicKey: Bool) -> CleanupModel {
        self == .auto ? (hasAnthropicKey ? .sonnet5 : .luna6) : self
    }
    var isAnthropic: Bool {
        let model = resolved
        return model == .sonnet5 || model == .haiku45
    }
    var keychainAccount: String { isAnthropic ? "anthropic" : "openai" }
    var providerName: String { isAnthropic ? "Anthropic" : "OpenAI" }
}

enum GuardStrictness: String, CaseIterable, Identifiable {
    case loose, normal, strict
    var id: String { rawValue }
    /// Maximum allowed edit ratio between the transcript skeleton and the LLM output skeleton.
    var threshold: Double {
        switch self {
        case .loose: return 0.50
        case .normal: return 0.35
        case .strict: return 0.22
        }
    }
    var title: String {
        switch self {
        case .loose: return "Loose — allow more rewording"
        case .normal: return "Normal"
        case .strict: return "Strict — reject anything beyond filler removal"
        }
    }
}

enum TriggerKey: String, CaseIterable, Identifiable {
    case fn, controlOptionSpace, rightOption, rightCommand, rightControl
    /// New or unreadable preferences use Fn. Every valid saved choice remains intact.
    /// Pure restoration keeps migration checks independent of the user's defaults.
    static func restoring(savedValue: String?) -> TriggerKey {
        savedValue.flatMap(TriggerKey.init(rawValue:)) ?? .fn
    }

    var id: String { rawValue }
    var title: String {
        switch self {
        case .controlOptionSpace: return "Control + Option + Space"
        case .fn: return "Fn / Globe key"
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        }
    }
    var shortName: String {
        switch self {
        case .controlOptionSpace: return "⌃⌥Space"
        case .fn: return "Fn"
        case .rightOption: return "right ⌥"
        case .rightCommand: return "right ⌘"
        case .rightControl: return "right ⌃"
        }
    }
    var keyCode: Int64 {
        switch self {
        case .controlOptionSpace: return 49
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }
    var isModifierOnly: Bool { self != .controlOptionSpace }

    /// Device-specific flags distinguish right-key release while the left counterpart is held.
    /// The chord uses ordinary, side-independent flags so either Control/Option key works.
    var flagMask: UInt64 {
        switch self {
        case .controlOptionSpace: return 0x000C_0000 // Control + Option
        case .fn: return 0x0080_0000            // NX_SECONDARYFNMASK (CGEventFlags.maskSecondaryFn)
        case .rightOption: return 0x0000_0040   // NX_DEVICERALTKEYMASK
        case .rightCommand: return 0x0000_0010  // NX_DEVICERCMDKEYMASK
        case .rightControl: return 0x0000_2000  // NX_DEVICERCTLKEYMASK
        }
    }

    /// Ordinary modifier flags allowed when starting this shortcut. Caps Lock is irrelevant.
    var shortcutModifiers: UInt64 {
        switch self {
        case .controlOptionSpace: return 0x000C_0000
        case .fn: return 0
        case .rightOption: return 0x0008_0000
        case .rightCommand: return 0x0010_0000
        case .rightControl: return 0x0004_0000
        }
    }
}

enum SecondaryTrigger: String, CaseIterable, Identifiable {
    case none, rightOption, rightCommand, rightControl
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        }
    }
    var triggerKey: TriggerKey? {
        switch self {
        case .none: return nil
        case .rightOption: return .rightOption
        case .rightCommand: return .rightCommand
        case .rightControl: return .rightControl
        }
    }
}

enum InsertionMethod: String, CaseIterable, Identifiable {
    case auto, paste
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto — direct insert in native apps, paste elsewhere"
        case .paste: return "Always paste (⌘V, clipboard restored afterwards)"
        }
    }
}

enum MicPreference: String, CaseIterable, Identifiable {
    case builtIn, systemDefault
    var id: String { rawValue }
    var title: String { self == .builtIn ? "Prefer the built-in microphone (avoids low-quality Bluetooth mics)" : "System default input" }
}

/// Release configuration is separate from the user's saved connection choice.
/// An older bundle without this key retains the original hosted-capable behavior.
enum ServiceDistributionMode: String {
    case personal, hosted

    static func resolve(_ value: String?) -> Self {
        value == "personal" ? .personal : .hosted
    }

    static var bundled: Self {
        resolve(Bundle.main.object(forInfoDictionaryKey: "ExpertiseServiceMode") as? String)
    }
}

/// All user preferences. Backed by UserDefaults; API keys live in the Keychain (see Keychain.swift).
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults: UserDefaults
    let serviceDistributionMode: ServiceDistributionMode
    var offersHostedService: Bool { serviceDistributionMode == .hosted }

    // Transcription
    @Published var sttEngine: STTEngine { didSet { save("sttEngine", sttEngine.rawValue) } }
    @Published var liveDelay: LiveDelay { didSet { save("liveDelay", liveDelay.rawValue) } }
    @Published var chineseVariant: ChineseVariant { didSet { save("chineseVariant", chineseVariant.rawValue) } }
    @Published var dictationLanguages: [String] {
        didSet {
            let normalized = DictationLanguage.normalized(dictationLanguages)
            if normalized != dictationLanguages { dictationLanguages = normalized }
            save("dictationLanguages", normalized)
        }
    }
    @Published var keepConnectionWarm: Bool { didSet { save("keepConnectionWarm", keepConnectionWarm) } }
    @Published var usesHostedService: Bool {
        didSet {
            // A personal-only release cannot route to an unavailable service,
            // even if a stale binding tries to enable it. Keep the saved choice
            // dormant so installing a hosted-capable build can restore it.
            guard offersHostedService else {
                if usesHostedService { usesHostedService = false }
                return
            }
            save("usesHostedService", usesHostedService)
        }
    }

    // Clean-up
    @Published var dictationMode: DictationMode { didSet { save("dictationMode", dictationMode.rawValue) } }
    @Published var cleanupModel: CleanupModel { didSet { save("cleanupModel", cleanupModel.rawValue) } }
    @Published var guardStrictness: GuardStrictness { didSet { save("guardStrictness", guardStrictness.rawValue) } }
    @Published var allowFormatting: Bool { didSet { save("allowFormatting", allowFormatting) } }
    @Published var spokenCommands: Bool { didSet { save("spokenCommands", spokenCommands) } }
    @Published var cjkSpacing: Bool { didSet { save("cjkSpacing", cjkSpacing) } }
    @Published var skipLLMForShort: Bool { didSet { save("skipLLMForShort", skipLLMForShort) } }
    /// Speed: type transcripts that already look clean without a model round-trip.
    @Published var skipLLMWhenClean: Bool { didSet { save("skipLLMWhenClean", skipLLMWhenClean) } }
    /// Speed: short prompt for Light clean-up (Full rewrite keeps the long one).
    @Published var compactPrompt: Bool { didSet { save("compactPrompt", compactPrompt) } }
    /// Speed: OpenAI priority processing for clean-up and translation requests.
    @Published var openAIPriorityTier: Bool { didSet { save("openAIPriorityTier", openAIPriorityTier) } }
    /// Speed: Full rewrite skips its second (semantic) request when the rewrite only removed fillers or changed layout.
    @Published var skipVerifierWhenVerbatim: Bool { didSet { save("skipVerifierWhenVerbatim", skipVerifierWhenVerbatim) } }
    @Published var llmTimeout: Double { didSet { save("llmTimeout", llmTimeout) } }
    @Published var dictionaryText: String { didSet { save("dictionaryText", dictionaryText) } }
    @Published var replacementsText: String { didSet { save("replacementsText", replacementsText) } }
    @Published var customInstructions: String { didSet { save("customInstructions", customInstructions) } }
    /// Empty means use the current built-in instructions, including future improvements.
    @Published var rewritePromptOverride: String { didSet { save("rewritePromptOverride", rewritePromptOverride) } }

    // Hotkey
    @Published var triggerKey: TriggerKey { didSet { save("triggerKey", triggerKey.rawValue) } }
    @Published var secondaryTrigger: SecondaryTrigger { didSet { save("secondaryTrigger", secondaryTrigger.rawValue) } }
    @Published var tapTogglesHandsFree: Bool { didSet { save("tapTogglesHandsFree", tapTogglesHandsFree) } }
    @Published var interceptTrigger: Bool { didSet { save("interceptTrigger", interceptTrigger) } }
    @Published var holdThreshold: Double { didSet { save("holdThreshold", holdThreshold) } }
    @Published var maxDurationSeconds: Double { didSet { save("maxDurationSeconds", maxDurationSeconds) } }
    @Published var doubleTapTranslates: Bool { didSet { save("doubleTapTranslates", doubleTapTranslates) } }
    /// Last language chosen for translation; the dropdown starts on it next time.
    @Published var translationLanguage: String { didSet { save("translationLanguage", translationLanguage) } }

    // Insertion
    @Published var insertionMethod: InsertionMethod { didSet { save("insertionMethod", insertionMethod.rawValue) } }
    @Published var smartSpacing: Bool { didSet { save("smartSpacing", smartSpacing) } }
    @Published var restoreClipboard: Bool { didSet { save("restoreClipboard", restoreClipboard) } }

    // Audio & feedback
    @Published var micPreference: MicPreference { didSet { save("micPreference", micPreference.rawValue) } }
    @Published var keepMicWarm: Bool { didSet { save("keepMicWarm", keepMicWarm) } }
    @Published var playSounds: Bool { didSet { save("playSounds", playSounds) } }
    @Published var showPreview: Bool { didSet { save("showPreview", showPreview) } }
    @Published var showIdleHandle: Bool { didSet { save("showIdleHandle", showIdleHandle) } }
    @Published var saveHistory: Bool { didSet { save("saveHistory", saveHistory) } }

    // Advanced endpoints
    @Published var openAIBaseURL: String { didSet { save("openAIBaseURL", openAIBaseURL) } }
    @Published var anthropicBaseURL: String { didSet { save("anthropicBaseURL", anthropicBaseURL) } }

    // App state
    @Published var hasCompletedSetup: Bool { didSet { save("hasCompletedSetup", hasCompletedSetup) } }

    init(defaults: UserDefaults = .standard, serviceDistributionMode: ServiceDistributionMode = .bundled) {
        self.defaults = defaults
        self.serviceDistributionMode = serviceDistributionMode
        func raw<T: RawRepresentable>(_ key: String, _ def: T) -> T where T.RawValue == String {
            if let s = defaults.string(forKey: key), let v = T(rawValue: s) { return v }
            return def
        }
        func bool(_ key: String, _ def: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? def : defaults.bool(forKey: key)
        }
        func double(_ key: String, _ def: Double) -> Double {
            defaults.object(forKey: key) == nil ? def : defaults.double(forKey: key)
        }
        func string(_ key: String, _ def: String) -> String {
            defaults.string(forKey: key) ?? def
        }

        sttEngine = raw("sttEngine", STTEngine.openAILive)
        liveDelay = raw("liveDelay", LiveDelay.low)
        chineseVariant = raw("chineseVariant", ChineseVariant.simplified)
        dictationLanguages = DictationLanguage.normalized(defaults.stringArray(forKey: "dictationLanguages") ?? DictationLanguage.systemDefault)
        keepConnectionWarm = bool("keepConnectionWarm", true)
        // Existing provider selections keep their keys and routing. Only a hosted
        // distribution defaults a fresh installation to the included service.
        let existingConnection = defaults.bool(forKey: "hasCompletedSetup") ||
            defaults.object(forKey: "sttEngine") != nil || defaults.object(forKey: "cleanupModel") != nil
        let initialHostedChoice = bool("usesHostedService", serviceDistributionMode == .hosted && !existingConnection)
        usesHostedService = serviceDistributionMode == .hosted && initialHostedChoice
        // Persist the one-time migration. Property observers do not run during
        // initialization; otherwise finishing a fresh setup would make its next
        // launch look like a legacy personal-key installation.
        if defaults.object(forKey: "usesHostedService") == nil {
            defaults.set(initialHostedChoice, forKey: "usesHostedService")
        }

        dictationMode = raw("dictationMode", DictationMode.rewrite)
        cleanupModel = raw("cleanupModel", CleanupModel.auto)
        guardStrictness = raw("guardStrictness", GuardStrictness.normal)
        allowFormatting = bool("allowFormatting", false)
        spokenCommands = bool("spokenCommands", true)
        cjkSpacing = bool("cjkSpacing", true)
        skipLLMForShort = bool("skipLLMForShort", true)
        skipLLMWhenClean = bool("skipLLMWhenClean", true)
        compactPrompt = bool("compactPrompt", true)
        openAIPriorityTier = bool("openAIPriorityTier", true)
        skipVerifierWhenVerbatim = bool("skipVerifierWhenVerbatim", true)
        llmTimeout = double("llmTimeout", 6.0)
        dictionaryText = string("dictionaryText", "")
        replacementsText = string("replacementsText", "")
        customInstructions = string("customInstructions", "")
        rewritePromptOverride = string("rewritePromptOverride", "")

        triggerKey = TriggerKey.restoring(savedValue: defaults.string(forKey: "triggerKey"))
        secondaryTrigger = .none
        tapTogglesHandsFree = true
        interceptTrigger = true
        holdThreshold = 0.35
        // Retire the old five-minute cutoff.
        // Long sessions have a two-hour safety limit; the controller warns before finishing.
        maxDurationSeconds = 7_200
        doubleTapTranslates = bool("doubleTapTranslates", true)
        translationLanguage = string("translationLanguage", "en")

        insertionMethod = raw("insertionMethod", InsertionMethod.auto)
        smartSpacing = bool("smartSpacing", true)
        restoreClipboard = bool("restoreClipboard", true)

        micPreference = raw("micPreference", MicPreference.systemDefault)
        keepMicWarm = bool("keepMicWarm", false)
        playSounds = bool("playSounds", true)
        showPreview = bool("showPreview", false)
        showIdleHandle = bool("showIdleHandle", false)
        saveHistory = bool("saveHistory", true)

        openAIBaseURL = string("openAIBaseURL", "https://api.openai.com")
        anthropicBaseURL = string("anthropicBaseURL", "https://api.anthropic.com")

        hasCompletedSetup = bool("hasCompletedSetup", false)
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }

    /// Personal dictionary entries, one per line (or comma separated), trimmed and de-duplicated.
    var dictionaryTerms: [String] {
        var seen = Set<String>()
        return dictionaryText
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("<") && !$0.contains(">") && seen.insert($0.lowercased()).inserted }
    }

    var replacements: [Replacement] { Replacements.parse(replacementsText) }

    var languageSummary: String {
        let names = dictationLanguages.map(DictationLanguage.name(for:))
        let visible = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(visible) +\(names.count - 2)" : visible
    }

    var dictationLanguageNames: [String] {
        dictationLanguages.compactMap { code in DictationLanguage.all.first { $0.code == code }?.englishName }
    }

    /// Live transcription supports Chinese script hints alongside spoken language codes.
    var transcriptionLanguageCodes: [String] {
        dictationLanguages.map { $0 == "zh" ? chineseVariant.openAICode : $0 }
    }

    /// Dictionary terms plus the written side of every replacement, for the transcriber's keyword hints.
    var keywordHints: [String] {
        var seen = Set<String>()
        return (dictionaryTerms + replacements.map { $0.written })
            .filter { !$0.contains("\n") && seen.insert($0.lowercased()).inserted }
    }

    /// All keys that start a dictation (primary first).
    var activeTriggerKeys: [TriggerKey] {
        var keys = [triggerKey]
        if let s = secondaryTrigger.triggerKey, s != triggerKey { keys.append(s) }
        return keys
    }
}

/// A sheet-local editing transaction. Typing and restoring a draft never persist settings;
/// only Save commits. An unchanged/restored default stores no frozen copy of built-in text.
struct RewritePromptDraft {
    var text: String
    private let builtInDefault: String

    init(savedOverride: String, builtInDefault: String = CleanupPrompt.defaultFullRewriteInstructions) {
        self.builtInDefault = builtInDefault
        let saved = savedOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        text = saved.isEmpty ? builtInDefault : saved
    }

    var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var usesDefault: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == builtInDefault.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func restoreDefault() { text = builtInDefault }

    @discardableResult
    func save(to settings: Settings) -> Bool {
        guard canSave else { return false }
        settings.rewritePromptOverride = usesDefault ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines)
        return true
    }
}
