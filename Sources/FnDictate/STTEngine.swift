import Foundation

struct STTConfig {
    var languages: [String]          // e.g. ["en", "zh-cn"]
    var prompt: String               // short description of the audio
    var keywords: [String]           // personal dictionary
    var delay: LiveDelay
    var chineseVariant: ChineseVariant
}

enum STTError: LocalizedError {
    case notConfigured(String)
    case connection(String)
    case server(String)
    case timeout
    case noAudio

    var errorDescription: String? {
        switch self {
        case .notConfigured(let s): return s
        case .connection(let s): return "Connection failed: \(s)"
        case .server(let s): return s
        case .timeout: return "Transcription timed out"
        case .noAudio: return "No audio was captured"
        }
    }
}

/// One streaming transcription session: connect (possibly ahead of time), stream PCM16 audio,
/// then `finish()` to get the final transcript. All callbacks are delivered on the main thread.
protocol STTSession: AnyObject {
    var sampleRate: Double { get }
    /// Whole partial transcript so far.
    var onPartial: ((String) -> Void)? { get set }
    /// Delivered exactly once after `finish()` (or on a fatal error before that).
    var onFinal: ((Result<String, Error>) -> Void)? { get set }
    var isUsable: Bool { get }
    var engineName: String { get }
    func connect()
    func sendAudio(_ pcm16: Data)
    func finish()
    func cancel()
}

enum STTFactory {
    static func make(settings: Settings) throws -> STTSession {
        let factory = try providerFactory(settings: settings)
        return DurableSTTSession(first: factory(), configuration: transcriptionConfig(settings: settings), factory: factory)
    }

    static func recover(directory: URL, settings: Settings) throws -> DurableSTTSession {
        let saved = try RecordingArchive(directory: directory)
        let engine: STTEngine = saved.manifest.engine.hasPrefix("universal") ? .assemblyAI : (saved.manifest.engine == "gpt-transcribe" ? .openAIPost : .openAILive)
        let factory = try providerFactory(settings: settings, engine: engine, configuration: saved.manifest.configuration?.stt)
        return try DurableSTTSession(recovering: directory, factory: factory)
    }

    private static func transcriptionConfig(settings: Settings) -> STTConfig {
        STTConfig(languages: settings.transcriptionLanguageCodes,
                               prompt: transcriptionPrompt(settings: settings),
                               keywords: validKeywords(settings.keywordHints),
                               delay: settings.liveDelay,
                               chineseVariant: settings.chineseVariant)
    }

    private static func providerFactory(settings: Settings, engine override: STTEngine? = nil,
                                        configuration: STTConfig? = nil) throws -> () -> STTSession {
        let config = configuration ?? transcriptionConfig(settings: settings)
        if settings.usesHostedService {
            guard let base = HostedService.baseURL else {
                throw STTError.notConfigured("The free service has not been connected to this build yet.")
            }
            return {
                OpenAIRealtimeSTT(apiKey: "", baseURL: base, config: config, model: "gpt-live-transcribe",
                    socketFactory: { url, _ in HostedSocket(url: url, base: base) })
            }
        }
        let engine = override ?? settings.sttEngine
        switch engine {
        case .openAILive, .openAIPost:
            guard let key = Keychain.apiKey("openai") else {
                throw STTError.notConfigured("Add your OpenAI API key in Preferences → More options → Connection")
            }
            let base = settings.openAIBaseURL
            let model = engine == .openAILive ? "gpt-live-transcribe" : "gpt-transcribe"
            return { OpenAIRealtimeSTT(apiKey: key, baseURL: base, config: config, model: model) }
        case .assemblyAI:
            guard let key = Keychain.apiKey("assemblyai") else {
                throw STTError.notConfigured("Add your AssemblyAI API key in Preferences → More options → Connection")
            }
            return { AssemblyAISTT(apiKey: key, config: config) }
        }
    }

    static func validKeywords(_ keywords: [String]) -> [String] {
        Array(keywords.filter { !$0.isEmpty && $0.rangeOfCharacter(from: CharacterSet(charactersIn: "<>\r\n")) == nil }.prefix(100))
    }

    static func transcriptionPrompt(settings: Settings) -> String {
        var p = "Dictation by one speaker using \(settings.dictationLanguageNames.joined(separator: ", ")). Transcribe the spoken language without translating."
        p += " " + EmailAddressFormatting.recognitionHint
        if settings.dictationLanguages.contains("zh"), settings.chineseVariant == .simplified {
            p += " Write Chinese in Simplified characters."
        } else if settings.dictationLanguages.contains("zh") {
            p += " Write Chinese in Traditional characters."
        }
        return p
    }
}

/// Fake session used by `--simulate` and the UI self-test: returns a canned transcript.
final class MockSTTSession: STTSession {
    let sampleRate: Double = 24000
    var onPartial: ((String) -> Void)?
    var onFinal: ((Result<String, Error>) -> Void)?
    var isUsable: Bool { true }
    let engineName = "mock"
    private var bytes = 0
    private let text: String

    init(text: String = "um so this is uh this is a test of the the dictation system 然后呃我们看看中文行不行") {
        self.text = text
    }

    func connect() {}
    func sendAudio(_ pcm16: Data) {
        bytes += pcm16.count
        let words = text.split(separator: " ")
        let shown = min(words.count, bytes / 12000)
        if shown > 0 {
            let partial = words.prefix(shown).joined(separator: " ")
            DispatchQueue.main.async { self.onPartial?(partial) }
        }
    }
    func finish() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.onFinal?(.success(self.text)) }
    }
    func cancel() {}
}
