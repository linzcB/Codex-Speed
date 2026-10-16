import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public static let preferenceKey = "appLanguage"

    public func resolvedCode(preferredLanguages: [String]) -> String {
        guard self == .system else { return rawValue }
        for language in preferredLanguages {
            let code = language.replacingOccurrences(of: "_", with: "-").lowercased()
            if code == "zh" || code.hasPrefix("zh-") { return "zh-Hans" }
            if code == "en" || code.hasPrefix("en-") { return "en" }
        }
        return "en"
    }
}

/// UI strings are resolved at presentation time. Model IDs, chat titles, dates
/// used as aggregation keys, and exported column names remain language-neutral.
public struct AppLocalizer: Sendable {
    public let languageCode: String
    public var locale: Locale { Locale(identifier: languageCode) }

    public init(language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) {
        languageCode = language.resolvedCode(preferredLanguages: preferredLanguages)
    }

    static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    static func localizedBundle(for code: String) -> Bundle {
        // SwiftPM normalizes lproj names to lowercase; the standalone app keeps
        // their conventional spelling. Resolve both without relying on the OS
        // language, so an explicit override also works in either build.
        for name in [code, code.lowercased()] {
            if let url = resourceBundle.resourceURL?.appendingPathComponent(name + ".lproj"),
               let bundle = Bundle(url: url) { return bundle }
        }
        return resourceBundle
    }

    public func text(_ key: String, _ arguments: CustomStringConvertible...) -> String {
        format(key, arguments: arguments.map(\.description))
    }

    func format(_ key: String, arguments: [String]) -> String {
        let bundle = Self.localizedBundle(for: languageCode)
        let template = bundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: locale, arguments: arguments)
    }
}

public enum L10n {
    public static var preference: AppLanguage {
        get { UserDefaults.standard.string(forKey: AppLanguage.preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: AppLanguage.preferenceKey) }
    }
    public static var current: AppLocalizer { AppLocalizer(language: preference) }
    public static var locale: Locale { current.locale }
    public static func text(_ key: String, _ arguments: CustomStringConvertible...) -> String {
        current.format(key, arguments: arguments.map(\.description))
    }
    public static func modelName(_ value: String) -> String {
        value == "未知模型" ? text("未知模型") : value
    }
}
