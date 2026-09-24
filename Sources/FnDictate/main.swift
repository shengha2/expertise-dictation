import AppKit

let arguments = CommandLine.arguments
if CLI.run(arguments) {
    exit(0)
}

FontLoader.registerBundledFonts()
let app = NSApplication.shared
let delegate = AppDelegate()
delegate.simulate = arguments.contains("--simulate")
delegate.mock = arguments.contains("--mock")
if let i = arguments.firstIndex(of: "--show"), i + 1 < arguments.count { delegate.showAtLaunch = arguments[i + 1] }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
