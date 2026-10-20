import Foundation

/// Turns agent prompts and replies into short plain text for cards.
public enum AgentHomeText {
    /// A card title from a prompt: its first line, trimmed to `maximumLength` characters.
    ///
    /// - Parameters:
    ///   - prompt: The user's prompt.
    ///   - maximumLength: The longest title, including the ellipsis.
    /// - Returns: The title, or `nil` for an empty prompt.
    public static func title(fromPrompt prompt: String, maximumLength: Int = 48) -> String? {
        let firstLine = prompt
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let firstLine else { return nil }
        return truncate(collapseWhitespace(firstLine), to: maximumLength)
    }

    /// A plain-text summary of a Markdown reply: its first paragraph without
    /// emphasis, code fences or headings, trimmed to `maximumLength` characters.
    ///
    /// - Parameters:
    ///   - markdown: The agent's reply.
    ///   - maximumLength: The longest summary, including the ellipsis.
    /// - Returns: The summary, or `nil` when the reply has no text.
    public static func summary(fromMarkdown markdown: String, maximumLength: Int = 220) -> String? {
        let paragraphs = markdown
            .components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph
                    .split(whereSeparator: \.isNewline)
                    .map { line in
                        var text = line.trimmingCharacters(in: .whitespaces)
                        while text.hasPrefix("#") { text.removeFirst() }
                        return text.trimmingCharacters(in: .whitespaces)
                    }
                    .filter { !$0.hasPrefix("```") }
                    .joined(separator: " ")
            }
            .map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "") }
            .map(collapseWhitespace)
        guard let first = paragraphs.first(where: { !$0.isEmpty }) else { return nil }
        return truncate(first, to: maximumLength)
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func truncate(_ text: String, to maximumLength: Int) -> String {
        guard text.count > maximumLength, maximumLength > 1 else { return text }
        return String(text.prefix(maximumLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
