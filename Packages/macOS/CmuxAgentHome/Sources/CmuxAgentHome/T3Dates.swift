import Foundation

/// Parses the ISO 8601 timestamps T3 and the sidecar send, with or without
/// fractional seconds.
///
/// The format styles are `Sendable` values made once, so parsing a whole
/// read's worth of timestamps doesn't build a formatter per date.
enum T3Dates {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return (try? fractional.parse(text)) ?? (try? whole.parse(text))
    }
}
