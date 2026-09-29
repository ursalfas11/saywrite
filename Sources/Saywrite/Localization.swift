import SaywriteCore
import SwiftUI

/// Interface text: English by default, German when the system language is German.
func L(_ english: String, _ german: String) -> String {
    UILanguage.text(english, de: german)
}

/// Same, for texts with **bold** markdown.
func LM(_ english: String, _ german: String) -> LocalizedStringKey {
    LocalizedStringKey(L(english, german))
}
