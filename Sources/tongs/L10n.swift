import Foundation

/// The UI speaks Chinese when the user's first preferred language is Chinese, English otherwise;
/// `TONGS_LANG=zh|en` overrides. Both texts sit side by side at each call site, which keeps a
/// single-binary CLI free of resource bundles.
enum L10n {
    static let chinese: Bool = {
        if let lang = ProcessInfo.processInfo.environment["TONGS_LANG"], !lang.isEmpty { return lang.hasPrefix("zh") }
        return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    }()
}

func tr(_ zh: String, _ en: String) -> String {
    L10n.chinese ? zh : en
}
