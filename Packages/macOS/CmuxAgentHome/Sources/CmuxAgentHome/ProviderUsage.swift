import Foundation

/// Provider usage as T3 Code reports it: each account's rate-limit windows,
/// plus token use and cost by day when cmux's T3 token may read them.
///
/// Read from the agent-chat sidecar's `GET /api/t3/usage`, which relays T3's
/// `server.getConfig` providers and `server.getUsageSummary`.
public struct ProviderUsageReport: Equatable, Sendable {
    public var limits: [ProviderAccountLimits]
    public var summary: ProviderUsageSummary?
    /// Why the summary is missing: ``needsDiagnosticsScopeCode`` or T3's message.
    public var summaryError: String?

    /// The sidecar's `summaryError` when the token lacks T3's `diagnostics:read` scope.
    public static let needsDiagnosticsScopeCode = "needsDiagnosticsScope"

    public init(limits: [ProviderAccountLimits], summary: ProviderUsageSummary? = nil, summaryError: String? = nil) {
        self.limits = limits
        self.summary = summary
        self.summaryError = summaryError
    }

    /// Whether spend is hidden only because the token can't read it.
    public var needsDiagnosticsScope: Bool { summaryError == Self.needsDiagnosticsScopeCode }

    /// Accounts that report windows, in T3's order.
    public var accountsWithWindows: [ProviderAccountLimits] { limits.filter { !$0.windows.isEmpty } }

    /// Accounts that never report windows, such as API keys.
    public var accountsWithoutWindows: [ProviderAccountLimits] { limits.filter { $0.windows.isEmpty } }

    /// The account with the most room left, when more than one of a kind could take the next run.
    ///
    /// An account's room is its tightest window. Ties keep T3's order.
    public func mostHeadroomAccountId(now: Date) -> String? {
        let candidates = accountsWithWindows
        guard candidates.count > 1 else { return nil }
        let best = candidates.max { $0.tightestRemainingPercent(now: now) < $1.tightestRemainingPercent(now: now) }
        guard let best,
              candidates.contains(where: {
                  $0.driver == best.driver && $0.id != best.id
                      && $0.tightestRemainingPercent(now: now) < best.tightestRemainingPercent(now: now)
              })
        else { return nil }
        return best.id
    }

    /// The window closest to running out across every account, for the sidebar meter.
    public func tightestWindow(now: Date) -> (account: ProviderAccountLimits, window: ProviderUsageWindow)? {
        accountsWithWindows
            .flatMap { account in account.windows.map { (account: account, window: $0) } }
            .max { $0.window.remainingPercent(now: now) > $1.window.remainingPercent(now: now) }
    }

    /// Parses the sidecar's response; `nil` when it isn't a usage report.
    public static func parse(_ data: Data) -> ProviderUsageReport? {
        guard let wire = try? JSONDecoder().decode(Wire.Report.self, from: data) else { return nil }
        return ProviderUsageReport(
            limits: wire.limits.map(ProviderAccountLimits.init(wire:)),
            summary: wire.summary.map(ProviderUsageSummary.init(wire:)),
            summaryError: wire.summaryError
        )
    }
}

/// One provider account's limits, such as a Claude subscription signed in to its own config folder.
public struct ProviderAccountLimits: Identifiable, Equatable, Sendable {
    /// T3's provider instance id, such as `claudeAgent_2`.
    public var id: String
    /// T3's driver, such as `claudeAgent` or `codex`.
    public var driver: String
    public var name: String
    public var email: String?
    public var plan: String?
    /// The account's config folder; spend recorded under it belongs to this account.
    public var homePath: String?
    public var checkedAt: Date?
    public var windows: [ProviderUsageWindow]
    /// `unsupported` (an API key never has windows) or `probeFailed`.
    public var unavailableReason: String?
    public var unavailableMessage: String?
    public var externalUsageURL: URL?
    public var externalUsageLabel: String?

    public init(
        id: String,
        driver: String,
        name: String,
        email: String? = nil,
        plan: String? = nil,
        homePath: String? = nil,
        checkedAt: Date? = nil,
        windows: [ProviderUsageWindow] = [],
        unavailableReason: String? = nil,
        unavailableMessage: String? = nil,
        externalUsageURL: URL? = nil,
        externalUsageLabel: String? = nil
    ) {
        self.id = id
        self.driver = driver
        self.name = name
        self.email = email
        self.plan = plan
        self.homePath = homePath
        self.checkedAt = checkedAt
        self.windows = windows
        self.unavailableReason = unavailableReason
        self.unavailableMessage = unavailableMessage
        self.externalUsageURL = externalUsageURL
        self.externalUsageLabel = externalUsageLabel
    }

    /// The usage provider kind this account's spend is recorded under (`claudeAgent` → `claude`).
    public var usageProvider: String { ProviderUsageSummary.usageProvider(forDriver: driver) }

    /// Percent left in the account's tightest window, 100 when it has none.
    public func tightestRemainingPercent(now: Date) -> Int {
        windows.map { $0.remainingPercent(now: now) }.min() ?? 100
    }
}

/// A rate-limit window, such as Claude's five-hour session or a weekly cap.
public struct ProviderUsageWindow: Identifiable, Equatable, Sendable {
    /// How spending compares with the time gone in the window.
    public enum Pace: String, Sendable {
        /// Spending faster than the window elapses.
        case ahead
        case on
        /// Headroom left for the rest of the window.
        case under
    }

    /// Stable per provider, such as `five_hour` or `seven_day_opus`.
    public var id: String
    /// `session`, `weekly`, `monthly` or `other`.
    public var kind: String
    public var label: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var durationMinutes: Int?

    public init(id: String, kind: String, label: String, usedPercent: Double, resetsAt: Date? = nil, durationMinutes: Int? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.durationMinutes = durationMinutes
    }

    /// Whole percent left, as T3 rounds it.
    public var remainingPercent: Int { Int((100 - min(100, max(0, usedPercent))).rounded()) }

    /// Whether the window has reset since T3 last checked it, so none of it is used now.
    public func hasReset(now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }

    /// Percent left now: all of it once the window has reset since T3's check.
    public func remainingPercent(now: Date) -> Int {
        hasReset(now: now) ? 100 : remainingPercent
    }

    /// How much of the window has gone by, 0...1, when its length and reset are known.
    public func elapsedShare(now: Date) -> Double? {
        guard let resetsAt, let durationMinutes, durationMinutes > 0 else { return nil }
        let length = Double(durationMinutes) * 60
        return min(1, max(0, (length - resetsAt.timeIntervalSince(now)) / length))
    }

    /// Ahead when more than 5 points over even spending, under when more than 5 below.
    public func pace(now: Date) -> Pace? {
        guard !hasReset(now: now), let elapsed = elapsedShare(now: now) else { return nil }
        let gap = usedPercent - elapsed * 100
        if gap > 5 { return .ahead }
        if gap < -5 { return .under }
        return .on
    }

    /// Seconds until the window resets; zero once it's due.
    public func timeUntilReset(now: Date) -> TimeInterval? {
        resetsAt.map { max(0, $0.timeIntervalSince(now)) }
    }
}

/// Token use and cost from the agents' own transcripts, bucketed by day (or hour) and model.
public struct ProviderUsageSummary: Equatable, Sendable {
    public struct Bucket: Equatable, Sendable {
        /// `YYYY-MM-DD` in the summary's time zone.
        public var day: String
        /// The hour's start for hourly summaries, as T3 sends it.
        public var hourStart: String?
        /// The usage provider kind: `claude`, `codex`, `cursor`, …
        public var provider: String
        public var model: String
        /// The transcript folder the use was read from.
        public var sourcePath: String?
        public var inputTokens: Int
        public var cachedInputTokens: Int
        public var cacheCreationTokens: Int
        public var outputTokens: Int
        public var costUsd: Double
        public var cacheSavingsUsd: Double
        public var sessions: Int
        public var unpricedRecords: Int

        public init(
            day: String,
            hourStart: String? = nil,
            provider: String,
            model: String,
            sourcePath: String? = nil,
            inputTokens: Int = 0,
            cachedInputTokens: Int = 0,
            cacheCreationTokens: Int = 0,
            outputTokens: Int = 0,
            costUsd: Double = 0,
            cacheSavingsUsd: Double = 0,
            sessions: Int = 0,
            unpricedRecords: Int = 0
        ) {
            self.day = day
            self.hourStart = hourStart
            self.provider = provider
            self.model = model
            self.sourcePath = sourcePath
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.cacheCreationTokens = cacheCreationTokens
            self.outputTokens = outputTokens
            self.costUsd = costUsd
            self.cacheSavingsUsd = cacheSavingsUsd
            self.sessions = sessions
            self.unpricedRecords = unpricedRecords
        }

        /// Every token: uncached, cache-read and cache-write input plus output.
        public var totalTokens: Int { inputTokens + cachedInputTokens + cacheCreationTokens + outputTokens }
    }

    public struct Source: Equatable, Sendable {
        public var provider: String
        public var path: String
        /// `ok`, `missing`, `partial` or `failed`.
        public var status: String
        public var distinctSessions: Int
        public var message: String?

        public init(provider: String, path: String, status: String = "ok", distinctSessions: Int = 0, message: String? = nil) {
            self.provider = provider
            self.path = path
            self.status = status
            self.distinctSessions = distinctSessions
            self.message = message
        }
    }

    public var sinceDay: String
    public var untilDay: String
    public var buckets: [Bucket]
    public var sources: [Source]
    /// `fresh`, `cached` or `unavailable`.
    public var pricingStatus: String?

    public init(sinceDay: String, untilDay: String, buckets: [Bucket], sources: [Source] = [], pricingStatus: String? = nil) {
        self.sinceDay = sinceDay
        self.untilDay = untilDay
        self.buckets = buckets
        self.sources = sources
        self.pricingStatus = pricingStatus
    }

    /// The usage provider kind T3 records a driver's spend under.
    public static func usageProvider(forDriver driver: String) -> String {
        driver == "claudeAgent" ? "claude" : driver
    }
}

// MARK: - Digest

/// Spend totals and breakdowns for the Usage page, worked out once per report.
public struct ProviderUsageDigest: Equatable, Sendable {
    /// Where spend was recorded: a known account, or a provider's other folders.
    public struct Spender: Identifiable, Equatable, Sendable {
        /// The account id, or `provider:<kind>` for spend no account claims.
        public var id: String
        public var label: String
        /// The usage provider kind, for its colour.
        public var provider: String
        public var costUsd: Double
        public var tokens: Int
        /// Whether this is a known account rather than leftover spend.
        public var isAccount: Bool
    }

    /// One bar segment: a spender's cost in one day or hour.
    public struct Point: Equatable, Sendable {
        /// `YYYY-MM-DD`, or the hour's start for hourly summaries.
        public var slot: String
        public var spenderId: String
        public var costUsd: Double
        public var tokens: Int
    }

    public struct ModelRow: Identifiable, Equatable, Sendable {
        public var id: String { "\(provider)/\(model)" }
        public var provider: String
        public var model: String
        public var costUsd: Double
        public var tokens: Int
        public var outputTokens: Int
    }

    public var costUsd: Double = 0
    public var tokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheSavingsUsd: Double = 0
    public var sessions: Int = 0
    /// Records T3 couldn't price, so the cost is a floor.
    public var unpricedRecords: Int = 0
    /// Spenders by cost, highest first.
    public var spenders: [Spender] = []
    /// Points in slot order, spenders in ``spenders`` order within a slot.
    public var points: [Point] = []
    /// Models by cost, highest first.
    public var models: [ModelRow] = []
    /// Transcript folders T3 couldn't fully read, with its message.
    public var sourceProblems: [ProviderUsageSummary.Source] = []

    public init(summary: ProviderUsageSummary, accounts: [ProviderAccountLimits]) {
        var spenders: [String: Spender] = [:]
        var points: [String: Point] = [:]
        var models: [String: ModelRow] = [:]
        for bucket in summary.buckets {
            let spender = Self.spender(for: bucket, accounts: accounts)
            costUsd += bucket.costUsd
            tokens += bucket.totalTokens
            outputTokens += bucket.outputTokens
            cacheSavingsUsd += bucket.cacheSavingsUsd
            unpricedRecords += bucket.unpricedRecords

            spenders[spender.id, default: spender].costUsd += bucket.costUsd
            spenders[spender.id, default: spender].tokens += bucket.totalTokens

            let slot = bucket.hourStart ?? bucket.day
            let pointKey = "\(slot)\u{1}\(spender.id)"
            points[pointKey, default: Point(slot: slot, spenderId: spender.id, costUsd: 0, tokens: 0)].costUsd += bucket.costUsd
            points[pointKey, default: Point(slot: slot, spenderId: spender.id, costUsd: 0, tokens: 0)].tokens += bucket.totalTokens

            let model = ModelRow(provider: bucket.provider, model: bucket.model, costUsd: 0, tokens: 0, outputTokens: 0)
            models[model.id, default: model].costUsd += bucket.costUsd
            models[model.id, default: model].tokens += bucket.totalTokens
            models[model.id, default: model].outputTokens += bucket.outputTokens
        }
        // A session spans days and models, so the sources' distinct counts are the ones to total.
        sessions = summary.sources.reduce(0) { $0 + $1.distinctSessions }
        sourceProblems = summary.sources.filter { $0.status == "partial" || $0.status == "failed" }

        self.spenders = spenders.values.sorted { ($0.costUsd, $1.label) > ($1.costUsd, $0.label) }
        let order = Dictionary(uniqueKeysWithValues: self.spenders.enumerated().map { ($1.id, $0) })
        self.points = points.values.sorted {
            $0.slot != $1.slot ? $0.slot < $1.slot : (order[$0.spenderId] ?? 0) < (order[$1.spenderId] ?? 0)
        }
        self.models = models.values.sorted { ($0.costUsd, $0.tokens) > ($1.costUsd, $1.tokens) }
    }

    /// The account whose config folder holds the bucket's transcripts (the
    /// deepest match), else the provider's leftover spender.
    static func spender(for bucket: ProviderUsageSummary.Bucket, accounts: [ProviderAccountLimits]) -> Spender {
        let owner = bucket.sourcePath.flatMap { path in
            accounts
                .filter { $0.usageProvider == bucket.provider }
                .compactMap { account -> (ProviderAccountLimits, Int)? in
                    guard let home = account.homePath.map(Self.trimmingTrailingSlash), !home.isEmpty,
                          path == home || path.hasPrefix(home + "/")
                    else { return nil }
                    return (account, home.count)
                }
                .max { $0.1 < $1.1 }?.0
        }
        if let owner {
            return Spender(id: owner.id, label: owner.name, provider: bucket.provider, costUsd: 0, tokens: 0, isAccount: true)
        }
        return Spender(
            id: "provider:\(bucket.provider)",
            label: ProviderUsageDigest.providerName(bucket.provider),
            provider: bucket.provider,
            costUsd: 0,
            tokens: 0,
            isAccount: false
        )
    }

    /// T3's display name for a usage provider kind.
    public static func providerName(_ provider: String) -> String {
        switch provider {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "grok": return "Grok Build"
        case "cursor": return "Cursor"
        case "opencode": return "OpenCode"
        case "antigravity": return "Antigravity"
        case "pi": return "Pi"
        default: return provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }

    private static func trimmingTrailingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

// MARK: - Wire format

private enum Wire {
    struct Report: Decodable {
        var limits: [Limits]
        var summary: Summary?
        var summaryError: String?
    }

    struct Limits: Decodable {
        var instanceId: String
        var driver: String
        var name: String
        var email: String?
        var plan: String?
        var homePath: String?
        var checkedAt: String?
        var windows: [Window]
        var unavailable: Unavailable?
        var externalUsage: External?
    }

    struct Window: Decodable {
        var id: String
        var kind: String
        var label: String
        var usedPercent: Double
        var resetsAt: String?
        var windowDurationMins: Int?
    }

    struct Unavailable: Decodable {
        var reason: String
        var message: String?
    }

    struct External: Decodable {
        var label: String
        var url: String
    }

    struct Summary: Decodable {
        var sinceDay: String
        var untilDay: String
        var buckets: [Lossy<Bucket>]
        var sources: [Lossy<Source>]?
        var pricing: Pricing?
    }

    struct Pricing: Decodable {
        var status: String
    }

    struct Bucket: Decodable {
        var day: String
        var hourStart: String?
        var provider: String
        var model: String
        var sourcePath: String?
        var totals: Totals
        var costUsd: Double
        var cacheSavingsUsd: Double?
        var sessions: Int?
        var unpricedRecords: Int?
    }

    struct Totals: Decodable {
        var uncachedInputTokens: Int
        var cachedInputTokens: Int
        var cacheCreationTokens: Int
        var outputTokens: Int
    }

    struct Source: Decodable {
        struct Fingerprint: Decodable {
            var provider: String
            var resolvedHomePath: String
        }

        var fingerprint: Fingerprint
        var status: String
        var distinctSessions: Int
        var message: String?
    }

    /// Skips array entries a newer T3 sends in a shape this build doesn't know.
    struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

private extension ProviderAccountLimits {
    init(wire: Wire.Limits) {
        self.init(
            id: wire.instanceId,
            driver: wire.driver,
            name: wire.name,
            email: wire.email,
            plan: wire.plan,
            homePath: wire.homePath,
            checkedAt: Wire.date(wire.checkedAt),
            windows: wire.windows.map {
                ProviderUsageWindow(
                    id: $0.id,
                    kind: $0.kind,
                    label: $0.label,
                    usedPercent: $0.usedPercent,
                    resetsAt: Wire.date($0.resetsAt),
                    durationMinutes: $0.windowDurationMins
                )
            },
            unavailableReason: wire.unavailable?.reason,
            unavailableMessage: wire.unavailable?.message,
            externalUsageURL: wire.externalUsage.flatMap { URL(string: $0.url) },
            externalUsageLabel: wire.externalUsage?.label
        )
    }
}

private extension ProviderUsageSummary {
    init(wire: Wire.Summary) {
        self.init(
            sinceDay: wire.sinceDay,
            untilDay: wire.untilDay,
            buckets: wire.buckets.compactMap(\.value).map {
                Bucket(
                    day: $0.day,
                    hourStart: $0.hourStart,
                    provider: $0.provider,
                    model: $0.model,
                    sourcePath: $0.sourcePath,
                    inputTokens: $0.totals.uncachedInputTokens,
                    cachedInputTokens: $0.totals.cachedInputTokens,
                    cacheCreationTokens: $0.totals.cacheCreationTokens,
                    outputTokens: $0.totals.outputTokens,
                    costUsd: $0.costUsd,
                    cacheSavingsUsd: $0.cacheSavingsUsd ?? 0,
                    sessions: $0.sessions ?? 0,
                    unpricedRecords: $0.unpricedRecords ?? 0
                )
            },
            sources: (wire.sources ?? []).compactMap(\.value).map {
                Source(
                    provider: $0.fingerprint.provider,
                    path: $0.fingerprint.resolvedHomePath,
                    status: $0.status,
                    distinctSessions: $0.distinctSessions,
                    message: $0.message
                )
            },
            pricingStatus: wire.pricing?.status
        )
    }
}
