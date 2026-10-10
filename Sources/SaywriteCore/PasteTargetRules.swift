import Foundation

/// Where a paste would land in the frontmost app.
public enum PasteTarget: Sendable, Equatable {
    /// A real text field: paste, and ⌘Z undoes exactly that paste.
    case textField
    /// No accessible text field, but the app accepts ⌘V (Electron, terminals); ⌘Z is not reliable.
    case blind
    /// Nowhere to paste (Finder, the desktop, Preview): copy instead.
    case none
}

/// Decides the paste target from what Accessibility reports about the focused element. Kept free of
/// AX calls so the rules can be tested.
public enum PasteTargetRules {
    public struct Focus: Sendable {
        public var role: String?
        /// The selected text range can be set: an editable text of some kind.
        public var selectedRangeSettable: Bool
        /// For a web area: WebKit marks it as an editable document (Mail compose, iframe editors).
        public var editableDocument: Bool

        public init(role: String?, selectedRangeSettable: Bool, editableDocument: Bool = false) {
            self.role = role
            self.selectedRangeSettable = selectedRangeSettable
            self.editableDocument = editableDocument
        }
    }

    /// Apps whose windows expose no accessibility text field but accept ⌘V (Electron, Chromium).
    public static let blindPasteApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "notion.id", "com.spotify.client", "md.obsidian", "com.figma.Desktop",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "org.whispersystems.signal-desktop", "com.linear",
    ]

    /// Terminals: ⌘Z does not undo a paste there, so "Original" is not offered.
    public static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty",
    ]

    /// Native apps with little accessibility support that still accept ⌘V.
    public static let blindPasteEditors: Set<String> = [
        "dev.zed.Zed", "com.sublimetext.4", "com.sublimetext.3", "com.jetbrains.intellij", "com.jetbrains.pycharm",
    ]

    public static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Whether `editableDocument` is needed for this focus; asking WebKit costs extra AX calls.
    public static func needsEditableDocumentCheck(role: String?, selectedRangeSettable: Bool) -> Bool {
        role == "AXWebArea" && !selectedRangeSettable
    }

    public static func decide(bundleID: String, focus: Focus?, isElectron: Bool) -> PasteTarget {
        if let focus {
            // A web area only counts when it is editable (Mail compose, a focused input); a page or a
            // received mail in Safari/Mail is not a text field, and ⌘Z there could reopen a tab.
            let isEditableWebArea = focus.role == "AXWebArea" && (focus.selectedRangeSettable || focus.editableDocument)
            if textRoles.contains(focus.role ?? "") || focus.selectedRangeSettable || isEditableWebArea {
                return terminals.contains(bundleID) ? .blind : .textField
            }
        }
        if blindPasteApps.contains(bundleID) || blindPasteEditors.contains(bundleID) || terminals.contains(bundleID)
            || isElectron {
            return .blind
        }
        return .none
    }
}

/// What to do with a finished dictation once Accessibility has been asked about the focus.
public enum SecureInputRules {
    public enum Decision: Sendable, Equatable {
        /// Paste as usual.
        case proceed
        /// The focused element is a password field: nothing is inserted and the text is not saved.
        case secureField
        /// Secure event input is on and the focus is not a known text field (a terminal prompt, a
        /// browser field that exposes nothing): do not paste, but keep the text on the clipboard.
        case copyOnly
    }

    /// `secureInputEnabled` is system-wide: Terminal's Secure Keyboard Entry, a password manager or a
    /// stuck lock set it with no password field in sight. It only blocks the paste where the focus
    /// is not a recognised text field, and then the text is copied, never discarded.
    public static func decide(elementIsSecure: Bool, secureInputEnabled: Bool, target: PasteTarget) -> Decision {
        if elementIsSecure { return .secureField }
        if secureInputEnabled && target != .textField { return .copyOnly }
        return .proceed
    }
}

/// What Accessibility reports as the current selection of the focused element.
public enum SelectionReading: Sendable, Equatable {
    case text(String)
    /// A real "nothing selected".
    case empty
    /// The app does not expose its selection.
    case unavailable
}

public extension PasteTargetRules {
    /// A rewrite replaces the selection by paste. If the selection is no longer the one that was
    /// rewritten (the user clicked elsewhere meanwhile), pasting would overwrite the wrong text.
    /// When the app exposes no selection there is nothing to compare, so the paste goes ahead.
    static func rewriteMayReplace(captured: String, current: SelectionReading) -> Bool {
        switch current {
        case .text(let text): return text == captured
        case .empty: return false
        case .unavailable: return true
        }
    }

    /// Chromium and Electron apps only build their accessibility tree when asked; without it a
    /// password field is invisible to the secure-field check.
    static func shouldEnableManualAccessibility(bundleID: String, isElectron: Bool) -> Bool {
        blindPasteApps.contains(bundleID) || isElectron
    }

    /// Apps where a password field may not show up as one (see above, plus terminal prompts). With
    /// secure input on there, the text is not sent to the AI server: it could be a password.
    static func secureFieldMayBeInvisible(bundleID: String, isElectron: Bool) -> Bool {
        shouldEnableManualAccessibility(bundleID: bundleID, isElectron: isElectron) || terminals.contains(bundleID)
    }
}
