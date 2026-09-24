/// Migration checks exercise the production restoration policy without accessing UserDefaults.
enum ShortcutPreferenceRegressionTests {
    static func run(check: (String, Bool, String) -> Void) {
        check("shortcut default: an unset preference uses Fn",
              TriggerKey.restoring(savedValue: nil) == .fn, "")
        check("shortcut default: an empty preference uses Fn",
              TriggerKey.restoring(savedValue: "") == .fn, "")
        check("shortcut default: an unknown saved value uses Fn",
              TriggerKey.restoring(savedValue: "removed-shortcut-value") == .fn, "")
        for saved in TriggerKey.allCases {
            let restored = TriggerKey.restoring(savedValue: saved.rawValue)
            check("shortcut migration: saved \(saved.rawValue) remains selected",
                  restored == saved, "restored=\(restored.rawValue)")
        }
    }
}
