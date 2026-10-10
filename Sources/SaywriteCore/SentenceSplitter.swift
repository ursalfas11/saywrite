import Foundation

/// Splits text into sentences after `.`, `?` or `!` followed by whitespace, and at line breaks.
/// Line breaks stay attached to the following sentence so joining restores the layout.
public enum SentenceSplitter {
    public static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            let next = text.index(after: index)
            if char == "\n" {
                if current.allSatisfy({ $0 == "\n" }) {
                    current.append(char)
                } else {
                    if !current.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(current.trimmingCharacters(in: .whitespaces)) }
                    current = "\n"
                }
                index = next
                continue
            }
            current.append(char)
            let lastToken = current.split(separator: " ").last ?? ""
            let isSentenceEnd = char != "." || !RuleCleaner.isNonTerminalPeriod(lastToken, following: text[next...])
            if ".?!".contains(char), isSentenceEnd, next == text.endIndex || text[next] == " " {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
            index = next
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(current.trimmingCharacters(in: .whitespaces)) }
        return sentences.filter { !$0.isEmpty }
    }
}
