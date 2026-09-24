import AppKit

enum Sounds {
    enum Kind: String { case start, stop, cancel, error }
    private static var cache: [Kind: NSSound] = [:]
    private static var active: NSSound?
    private static var sequence = 0

    static func play(_ kind: Kind) {
        sequence += 1
        active?.stop()
        // Cancellation and empty attempts intentionally have no extra sound.
        guard Settings.shared.playSounds, kind != .cancel else { return }
        playClip(kind)
    }

    /// An intentional preview is audible even when the saved preference is Silent.
    static func previewMinimalPair() {
        sequence += 1
        let expected = sequence
        active?.stop()
        playClip(.start)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            guard expected == sequence else { return }
            playClip(.stop)
        }
    }

    private static func playClip(_ kind: Kind) {
        guard let sound = sound(for: kind) else { return }
        active?.stop()
        sound.stop()
        sound.volume = kind == .error ? 0.3 : 0.45
        active = sound
        sound.play()
    }

    private static func sound(for kind: Kind) -> NSSound? {
        if let s = cache[kind] { return s }
        var candidates: [URL] = []
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for ext in ["mp3", "wav"] {
            if let u = Bundle.main.url(forResource: kind.rawValue, withExtension: ext, subdirectory: "Sounds") { candidates.append(u) }
            candidates.append(exe.appendingPathComponent("../Resources/Sounds/\(kind.rawValue).\(ext)").standardized)
            candidates.append(exe.appendingPathComponent("../../Resources/Sounds/\(kind.rawValue).\(ext)").standardized)
        }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let s = NSSound(contentsOf: url, byReference: false) {
                cache[kind] = s
                return s
            }
        }
        return nil
    }
}
