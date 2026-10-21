import Foundation

enum AgentHomeFormat {
    private static let elapsedFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Elapsed time such as "38m" or "2h 14m"; under a minute reads "now".
    static func elapsed(since date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        guard interval >= 60 else { return String(localized: "agentHome.time.now", defaultValue: "now") }
        return elapsedFormatter.string(from: interval) ?? ""
    }

    /// Relative time such as "23 hr. ago".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: now)
    }
}
