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
