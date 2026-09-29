import Foundation

/// Writing style applied to a dictation, chosen per frontmost app.
public enum Style: String, Codable, CaseIterable, Sendable {
    case casual
    case neutral
    case formal

    public var displayName: String {
        switch self {
        case .casual: return UILanguage.text("Casual", de: "Locker")
        case .neutral: return "Neutral"
        case .formal: return UILanguage.text("Formal", de: "Förmlich")
        }
    }
}

/// Maps app bundle identifiers to styles. User overrides win over built-in defaults.
public struct StyleMap: Codable, Equatable, Sendable {
    public var overrides: [String: Style]

    public init(overrides: [String: Style] = [:]) {
        self.overrides = overrides
    }

    public static let defaults: [String: Style] = [
        // casual
        "net.whatsapp.WhatsApp": .casual,
        "desktop.WhatsApp": .casual,
        "com.apple.MobileSMS": .casual,
        "com.tinyspeck.slackmacgap": .casual,
        "ru.keepcoder.Telegram": .casual,
        "org.telegram.desktop": .casual,
        "com.hnc.Discord": .casual,
        "org.whispersystems.signal-desktop": .casual,
        // formal
        "com.apple.mail": .formal,
        "com.microsoft.Outlook": .formal,
        "com.microsoft.Word": .formal,
        "com.apple.iWork.Pages": .formal,
        "com.readdle.smartemail-Mac": .formal,
        "com.readdle.SparkDesktop": .formal,
    ]

    public func style(for bundleID: String?) -> Style {
        guard let bundleID else { return .neutral }
        if let style = overrides[bundleID] { return style }
        return Self.defaults[bundleID] ?? .neutral
    }

    /// All known mappings (defaults merged with overrides), for display in settings.
    public var effectiveMappings: [String: Style] {
        Self.defaults.merging(overrides) { _, override in override }
    }
}
