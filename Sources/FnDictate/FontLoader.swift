import AppKit
import CoreText
import SwiftUI

/// Registers the bundled Inter faces (SIL OFL) so the hub matches the Expertise AI design system.
enum FontLoader {
    private(set) static var interAvailable = false

    static func registerBundledFonts() {
        var dirs: [URL] = []
        if let u = Bundle.main.resourceURL?.appendingPathComponent("Fonts") { dirs.append(u) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        dirs.append(exe.appendingPathComponent("../Resources/Fonts").standardized)
        dirs.append(exe.appendingPathComponent("../../Resources/Fonts").standardized)
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            var any = false
            for f in files where f.pathExtension.lowercased() == "otf" || f.pathExtension.lowercased() == "ttf" {
                var error: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(f as CFURL, .process, &error) { any = true }
                else if let e = error?.takeRetainedValue(), CFErrorGetCode(e) == CTFontManagerError.alreadyRegistered.rawValue { any = true }
            }
            if any {
                interAvailable = NSFont(name: "Inter-Regular", size: 12) != nil
                if interAvailable { return }
            }
        }
    }
}

extension Font {
    /// Inter when bundled, the system font otherwise.
    static func hub(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard FontLoader.interAvailable else { return .system(size: size, weight: weight) }
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Inter-Bold"
        case .semibold: name = "Inter-SemiBold"
        case .medium: name = "Inter-Medium"
        default: name = "Inter-Regular"
        }
        return .custom(name, size: size)
    }
}
