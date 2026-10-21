import AppKit
import CmuxAgentHome
import Foundation
import Observation

/// Provider usage in Agent Home: each account's rate limits, and token use and
/// cost over a chosen period.
///
/// T3 Code tracks both. This reads them through the agent-chat sidecar
/// (`GET /api/t3/usage`) every minute while Agent Home is on screen and cmux
/// is active, so the sidebar meter stays current and the Usage page opens
/// with data. Those background reads never start the sidecar; opening the
/// Usage page does.
@MainActor
@Observable
final class AgentHomeUsageModel {
    static let shared = AgentHomeUsageModel()

    /// How far back the spend part of the Usage page looks.
    enum Period: String, CaseIterable, Identifiable {
        case day, week, month

        var id: String { rawValue }

        var title: String {
            switch self {
            case .day: return String(localized: "agentHome.usage.period.day", defaultValue: "24 hours")
            case .week: return String(localized: "agentHome.usage.period.week", defaultValue: "7 days")
            case .month: return String(localized: "agentHome.usage.period.month", defaultValue: "30 days")
            }
        }
    }

    private(set) var report: ProviderUsageReport?
    /// The spend breakdown for ``report``'s summary, worked out once per read.
    private(set) var digest: ProviderUsageDigest?
    /// The period ``report``'s summary covers.
    private(set) var reportPeriod: Period?
    private(set) var lastUpdated: Date?
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    var period: Period {
        didSet {
            guard period != oldValue else { return }
            UserDefaults.standard.set(period.rawValue, forKey: Self.periodDefaultsKey)
            Task { await refresh(startsSidecar: true) }
        }
    }

    /// Reads usage every minute while Agent Home is on screen.
    @ObservationIgnored let poller = AgentHomePoller(interval: AgentHomeUsageModel.pollInterval)

    private weak var tabManager: TabManager?
    private var refreshAgain = false
    private var refreshAgainStartsSidecar = false

    private static let pollInterval: Duration = .seconds(60)
    private static let periodDefaultsKey = "agentHomeUsagePeriod"

    /// The command that gives cmux's T3 token the scope spend needs, replacing the Keychain item.
    static let diagnosticsScopeCommand = #"security add-generic-password -U -a "$USER" -s cmux-agent-home-t3-token -w "$(t3 auth session issue --scope orchestration:read --scope orchestration:operate --scope diagnostics:read --label "cmux Agent Home" --token-only)""#

    private init() {
        period = UserDefaults.standard.string(forKey: Self.periodDefaultsKey).flatMap(Period.init(rawValue:)) ?? .week
        poller.action = { [weak self] in await self?.refresh() }
    }

    // MARK: - Loading

    /// Remembers the window's tab manager for sidecar lookups.
    func use(tabManager: TabManager) {
        let isFirst = self.tabManager == nil
        self.tabManager = tabManager
        // A poll that ran before any window was known skipped; catch up now.
        if isFirst, report == nil { Task { await refresh() } }
    }

    /// Reads usage now. A call while a read is running reads again once it's done.
    ///
    /// - Parameter startsSidecar: Whether to start the agent-chat sidecar if no
    ///   user action has yet; only user actions (opening the Usage page,
    ///   Refresh, a new period) pass `true`.
    func refresh(startsSidecar: Bool = false) async {
        guard let tabManager else { return }
        guard !isLoading else {
            refreshAgain = true
            refreshAgainStartsSidecar = refreshAgainStartsSidecar || startsSidecar
            return
        }
        isLoading = true
        defer { isLoading = false }
        var startsSidecar = startsSidecar
        repeat {
            refreshAgain = false
            let period = self.period
            do {
                let (data, status) = try await AgentHomeT3Model.shared.sidecarGET(
                    Self.path(for: period),
                    tabManager: tabManager,
                    startsSidecar: startsSidecar
                )
                if status == 200, let fetched = ProviderUsageReport.parse(data) {
                    if fetched != report || period != reportPeriod {
                        report = fetched
                        reportPeriod = period
                        digest = fetched.summary.map { ProviderUsageDigest(summary: $0, accounts: fetched.limits) }
                    }
                    errorMessage = nil
                    lastUpdated = Date()
                } else {
                    let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    errorMessage = body?["error"] as? String
                        ?? String(localized: "agentHome.usage.failed", defaultValue: "T3 didn't report usage. Will try again shortly.")
                }
            } catch AgentHomeT3Model.NewChatError.sidecarNotStarted {
                // Nothing has started the sidecar yet; keep what's shown.
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "agentHome.usage.unreachable", defaultValue: "Couldn't reach T3 Code. Is it running?")
            }
            startsSidecar = refreshAgainStartsSidecar
            refreshAgainStartsSidecar = false
        } while refreshAgain
    }

    /// The sidecar path for a period, in the user's time zone.
    static func path(for period: Period, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        var items = [
            URLQueryItem(name: "until", value: formatter.string(from: now)),
            URLQueryItem(name: "tz", value: calendar.timeZone.identifier),
        ]
        switch period {
        case .day:
            // The last 24 whole hours, ending with the current one.
            let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            let since = hour.addingTimeInterval(-23 * 3600)
            items += [
                URLQueryItem(name: "since", value: formatter.string(from: since)),
                URLQueryItem(name: "resolution", value: "hour"),
                URLQueryItem(name: "sinceTime", value: since.formatted(.iso8601)),
                URLQueryItem(name: "untilTime", value: now.formatted(.iso8601)),
            ]
        case .week, .month:
            let days = period == .week ? 6 : 29
            let since = calendar.date(byAdding: .day, value: -days, to: now) ?? now
            items.append(URLQueryItem(name: "since", value: formatter.string(from: since)))
        }
        var components = URLComponents()
        components.path = "api/t3/usage"
        components.queryItems = items
        return components.string ?? "api/t3/usage"
    }

    // MARK: - Actions

    func copyDiagnosticsScopeCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.diagnosticsScopeCommand, forType: .string)
    }
}
