import Foundation
import Testing
@testable import CmuxAgentHome

@Suite struct ProviderUsageTests {
    /// Shaped like the sidecar's `/api/t3/usage` answer on the owner's machine.
    let sample = """
    {
      "limits": [
        { "instanceId": "codex", "driver": "codex", "name": "Codex", "checkedAt": "2026-10-20T10:42:56.006Z",
          "windows": [], "unavailable": { "reason": "unsupported" } },
        { "instanceId": "claudeAgent", "driver": "claudeAgent", "name": "Claude", "email": "a@example.com",
          "plan": "Claude Team", "homePath": "/Users/me/.claude", "checkedAt": "2026-10-20T10:42:59.071Z",
          "windows": [
            { "id": "five_hour", "kind": "session", "label": "Session", "usedPercent": 31,
              "resetsAt": "2026-10-20T14:10:00.431Z", "windowDurationMins": 300 },
            { "id": "seven_day", "kind": "weekly", "label": "Weekly", "usedPercent": 12.4,
              "resetsAt": "2026-10-23T01:00:00Z", "windowDurationMins": 10080 }
          ] },
        { "instanceId": "claudeAgent_2", "driver": "claudeAgent", "name": "Claude Agent",
          "homePath": "/Users/me/.claude_team2",
          "windows": [ { "id": "five_hour", "kind": "session", "label": "Session", "usedPercent": 3 } ] }
      ],
      "summary": {
        "contractVersion": 6, "readAt": "2026-10-20T10:46:00Z", "timeZone": "Asia/Kolkata",
        "sinceDay": "2026-10-19", "untilDay": "2026-10-20", "scanDurationMs": 10,
        "pricing": { "status": "fresh", "source": "litellm", "fetchedAt": null, "knownModels": 10 },
        "buckets": [
          { "day": "2026-10-19", "provider": "claude", "model": "claude-opus-5-5", "sourcePath": "/Users/me/.claude/projects",
            "totals": { "uncachedInputTokens": 10, "cachedInputTokens": 1000, "cacheCreationTokens": 100, "outputTokens": 50, "reasoningTokens": 0 },
            "costUsd": 4.5, "cacheSavingsUsd": 9, "costSource": "modelPriced", "records": 3, "unpricedRecords": 0, "sessions": 2 },
          { "day": "2026-10-20", "provider": "claude", "model": "claude-opus-5-5", "sourcePath": "/Users/me/.claude_team2/projects",
            "totals": { "uncachedInputTokens": 0, "cachedInputTokens": 2000, "cacheCreationTokens": 0, "outputTokens": 100, "reasoningTokens": 0 },
            "costUsd": 6, "cacheSavingsUsd": 1, "costSource": "modelPriced", "records": 3, "unpricedRecords": 1, "sessions": 1 },
          { "day": "2026-10-20", "provider": "claude", "model": "claude-haiku-5-5", "sourcePath": "/Users/me/.claude_old/projects",
            "totals": { "uncachedInputTokens": 0, "cachedInputTokens": 0, "cacheCreationTokens": 0, "outputTokens": 10, "reasoningTokens": 0 },
            "costUsd": 0.5, "cacheSavingsUsd": 0, "costSource": "modelPriced", "records": 1, "unpricedRecords": 0, "sessions": 1 },
          { "day": "2026-10-20", "provider": "someNewProvider", "model": "x", "totals": { "bogus": true }, "costUsd": 1 }
        ],
        "sources": [
          { "fingerprint": { "hostId": "h", "provider": "claude", "resolvedHomePath": "/Users/me/.claude/projects", "volumeId": "1:1" },
            "status": "ok", "scannedFiles": 1, "skippedFiles": 0, "malformedRecords": 0, "distinctSessions": 4, "message": null },
          { "fingerprint": { "hostId": "h", "provider": "claude", "resolvedHomePath": "/Users/me/.claude_team2/projects", "volumeId": "1:2" },
            "status": "partial", "scannedFiles": 1, "skippedFiles": 1, "malformedRecords": 0, "distinctSessions": 3, "message": "One file was too large." }
        ]
      }
    }
    """

    func report() throws -> ProviderUsageReport {
        try #require(ProviderUsageReport.parse(Data(sample.utf8)))
    }

    @Test func parsesLimitsWithDatesAndUnsupportedAccounts() throws {
        let report = try report()
        #expect(report.limits.map(\.id) == ["codex", "claudeAgent", "claudeAgent_2"])
        #expect(report.accountsWithoutWindows.map(\.id) == ["codex"])
        #expect(report.accountsWithoutWindows.first?.unavailableReason == "unsupported")
        let claude = try #require(report.limits.first { $0.id == "claudeAgent" })
        #expect(claude.plan == "Claude Team")
        #expect(claude.windows.map(\.remainingPercent) == [69, 88])
        #expect(claude.windows.first?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-20T14:10:00Z")?.addingTimeInterval(0.431))
        #expect(claude.windows.last?.resetsAt != nil)
        #expect(report.needsDiagnosticsScope == false)
    }

    @Test func pacesAWindowAgainstTheTimeGone() throws {
        let resets = Date(timeIntervalSince1970: 10_000)
        let window = ProviderUsageWindow(id: "five_hour", kind: "session", label: "Session", usedPercent: 50, resetsAt: resets, durationMinutes: 300)
        // 1 of 5 hours gone (20%) with half used: ahead.
        #expect(window.pace(now: resets.addingTimeInterval(-4 * 3600)) == .ahead)
        // 2.5 of 5 hours gone: on pace.
        #expect(window.pace(now: resets.addingTimeInterval(-2.5 * 3600)) == .on)
        // 4.5 of 5 hours gone: under.
        #expect(window.pace(now: resets.addingTimeInterval(-0.5 * 3600)) == .under)
        #expect(window.timeUntilReset(now: resets.addingTimeInterval(60)) == 0)
        let noLength = ProviderUsageWindow(id: "x", kind: "other", label: "X", usedPercent: 10)
        #expect(noLength.pace(now: resets) == nil)
    }

    @Test func picksTheTightestWindowAndTheAccountWithMostHeadroom() throws {
        let report = try report()
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-20T11:00:00Z"))
        #expect(report.tightestWindow(now: now)?.account.id == "claudeAgent")
        #expect(report.tightestWindow(now: now)?.window.id == "five_hour")
        #expect(report.mostHeadroomAccountId(now: now) == "claudeAgent_2")

        let single = ProviderUsageReport(limits: [report.limits[1]])
        #expect(single.mostHeadroomAccountId(now: now) == nil)

        // After the 31%-used session resets, the weekly window (12.4% used) is the tightest.
        let afterReset = try #require(ISO8601DateFormatter().date(from: "2026-10-20T15:00:00Z"))
        #expect(report.tightestWindow(now: afterReset)?.window.id == "seven_day")
    }

    @Test func treatsAWindowPastItsResetAsUnused() {
        let resets = Date(timeIntervalSince1970: 10_000)
        let window = ProviderUsageWindow(id: "five_hour", kind: "session", label: "Session", usedPercent: 80, resetsAt: resets, durationMinutes: 300)
        #expect(window.remainingPercent(now: resets.addingTimeInterval(-60)) == 20)
        #expect(window.remainingPercent(now: resets.addingTimeInterval(60)) == 100)
        #expect(window.pace(now: resets.addingTimeInterval(60)) == nil)
    }

    @Test func attributesSpendToTheAccountWhoseFolderHoldsIt() throws {
        let report = try report()
        let digest = ProviderUsageDigest(summary: try #require(report.summary), accounts: report.limits)
        #expect(digest.spenders.map(\.id) == ["claudeAgent_2", "claudeAgent", "provider:claude"])
        #expect(digest.spenders.map(\.label) == ["Claude Agent", "Claude", "Claude Code"])
        #expect(digest.spenders.last?.isAccount == false)
        #expect(digest.costUsd == 11)
        #expect(digest.tokens == 1160 + 2100 + 10)
        #expect(digest.sessions == 7)
        #expect(digest.unpricedRecords == 1)
        #expect(digest.cacheSavingsUsd == 10)
        #expect(digest.models.map(\.model) == ["claude-opus-5-5", "claude-haiku-5-5"])
        #expect(digest.models.first?.costUsd == 10.5)
        #expect(digest.points.map(\.slot) == ["2026-10-19", "2026-10-20", "2026-10-20"])
        #expect(digest.points.map(\.spenderId) == ["claudeAgent", "claudeAgent_2", "provider:claude"])
        #expect(digest.sourceProblems.map(\.message) == ["One file was too large."])
    }

    @Test func slotsStartAtLocalMidnightOrTheirHour() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let daily = ProviderUsageDigest(
            summary: ProviderUsageSummary(sinceDay: "2026-10-19", untilDay: "2026-10-20", buckets: [
                ProviderUsageSummary.Bucket(day: "2026-10-20", provider: "claude", model: "m", costUsd: 1),
            ]),
            accounts: [],
            timeZone: tokyo
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        #expect(daily.points.first?.slotStart == calendar.date(from: DateComponents(year: 2026, month: 10, day: 20)))

        let hourly = ProviderUsageDigest(
            summary: ProviderUsageSummary(sinceDay: "2026-10-20", untilDay: "2026-10-20", buckets: [
                ProviderUsageSummary.Bucket(day: "2026-10-20", hourStart: "2026-10-20T05:00:00.000Z", provider: "claude", model: "m", costUsd: 1),
                ProviderUsageSummary.Bucket(day: "2026-10-20", hourStart: "not a date", provider: "claude", model: "m", costUsd: 1),
            ]),
            accounts: []
        )
        #expect(hourly.points.map(\.slotStart) == [Date(timeIntervalSince1970: 1_792_472_400), nil])
    }

    @Test func doesNotTreatASiblingFolderAsTheAccountsOwn() {
        let account = ProviderAccountLimits(id: "a", driver: "claudeAgent", name: "A", homePath: "/Users/me/.claude/")
        let bucket = ProviderUsageSummary.Bucket(day: "2026-10-20", provider: "claude", model: "m", sourcePath: "/Users/me/.claude_team2/projects")
        #expect(ProviderUsageDigest.spender(for: bucket, accounts: [account]).id == "provider:claude")
        let codexBucket = ProviderUsageSummary.Bucket(day: "2026-10-20", provider: "codex", model: "m", sourcePath: "/Users/me/.claude/projects")
        #expect(ProviderUsageDigest.spender(for: codexBucket, accounts: [account]).id == "provider:codex")
    }

    @Test func reportsAMissingScopeInsteadOfASummary() throws {
        let data = Data(#"{"limits":[],"summary":null,"summaryError":"needsDiagnosticsScope"}"#.utf8)
        let report = try #require(ProviderUsageReport.parse(data))
        #expect(report.summary == nil)
        #expect(report.needsDiagnosticsScope)
        #expect(ProviderUsageReport.parse(Data("{}".utf8)) == nil)
    }
}
