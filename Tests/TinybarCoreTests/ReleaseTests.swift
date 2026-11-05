import Foundation
@testable import TinybarCore
import Testing

// Claude Banked Resets and Long-context Prices (0.5.0).

private let gptPrices = Data(#"""
{"openai": {"models": {
  "gpt-6.1-sol": {"cost": {"input": 2, "output": 10, "cache_read": 0.1,
    "tiers": [{"input": 4, "output": 15, "cache_read": 0.2, "tier": {"type": "context", "size": 272000}}]}},
  "gpt-old": {"cost": {"input": 1, "output": 2, "context_over_200k": {"input": 3, "output": 4}}}
}}, "anthropic": {"models": {}}}
"""#.utf8)

@Test func parsesContextTiers() throws {
    let table = try PriceTable.parse(gptPrices, fetchedAt: nil)
    let sol = try #require(table.price(provider: .codex, model: "gpt-6.1-sol"))
    #expect(sol.tiers?.map(\.size) == [272_000])
    #expect(sol.tiers?.first?.price.output == 15)
    // The older field reads as a tier at 200K.
    #expect(table.price(provider: .codex, model: "gpt-old")?.tiers?.first?.size == 200_000)
}

@Test func longRequestsTakeTheirTier() throws {
    let sol = try #require(try PriceTable.parse(gptPrices, fetchedAt: nil).price(provider: .codex, model: "gpt-6.1-sol"))
    let long = TokenCounts(input: 1_000_000, output: 1_000_000)
    let short = TokenCounts(input: 1_000_000)
    let total = TokenCounts(input: 2_000_000, output: 1_000_000)
    // Short at $2/M; long at $4 + $15.
    #expect(sol.cost(total, long: [272_000: long]) == 2 + 4 + 15)
    // A band above the tier takes it too; a band below it doesn't.
    #expect(sol.cost(total, long: [400_000: long]) == 21)
    #expect(sol.cost(total, long: [200_000: long]) == sol.cost(total))
    #expect(sol.cost(short) == 2)
}

@Test func contextBands() {
    #expect(ContextBand.of(TokenCounts(input: 99_000)) == nil)
    #expect(ContextBand.of(TokenCounts(input: 1_000, cacheRead: 150_000)) == 100_000)
    #expect(ContextBand.of(TokenCounts(input: 272_000)) == 200_000)
    #expect(ContextBand.of(TokenCounts(input: 2_000, cacheRead: 280_000)) == 272_000)
}

private func codexLines(context: Int, output: Int) -> String {
    """
    {"timestamp":"2026-09-25T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-6.1-sol","cwd":"/nonexistent/p"}}
    {"timestamp":"2026-09-25T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(context),"cached_input_tokens":\(context - 1000),"output_tokens":\(output)}}}}
    """
}

@Test func storeFilesLongRequestsByBand() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sessions = dir.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try (codexLines(context: 300_000, output: 10) + "\n" + codexLines(context: 50_000, output: 5) + "\n")
        .write(to: sessions.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)

    let store = try UsageStore(path: dir.appendingPathComponent("db.sqlite"))
    try await store.ingestCodex(roots: [sessions])
    let rows = try await store.daily(since: "2026-01-01")
    #expect(rows.count == 1)
    #expect(rows[0].tokens.total == 350_015)
    #expect(rows[0].long == [272_000: TokenCounts(input: 1000, output: 10, cacheRead: 299_000)])

    // The one-time backfill (for stores from before schema 6) re-reads up to the saved offset
    // and adds only long requests: token totals and activity stay as they are.
    let stats = try await store.stats(since: "2026-01-01")
    try await store.backfillLongContext()
    #expect(try await store.daily(since: "2026-01-01")[0].tokens == rows[0].tokens)
    #expect(try await store.stats(since: "2026-01-01").sorted { $0.key < $1.key } == stats.sorted { $0.key < $1.key })
}

// MARK: Claude Banked Resets

@Test func claudeResetGrantsCountAvailableResets() throws {
    let json = Data(#"""
    {"five_hour": {"utilization": 12},
     "cedar_ember": {"eligible": true, "grants": [
       {"id": "handle", "resets_left": 2, "resets_total": 2, "starts_at": "2020-01-01T00:00:00Z",
        "ends_at": "2099-01-01T00:00:00Z", "paused": false},
       {"resets_left": 1, "paused": true},
       {"resets_left": 1, "paused": false, "ends_at": "2020-01-01T00:00:00Z"},
       {"resets_left": 1, "paused": false, "starts_at": "2099-01-01T00:00:00Z"},
       {"resets_left": 1}
     ]}}
    """#.utf8)
    let usage = try JSONDecoder().decode(ClaudeUsageAPI.UsageResponse.self, from: json)
    let snapshot = ClaudeUsageAPI.snapshot(from: usage, plan: nil)
    #expect(snapshot.bankedResets?.count == 2)
    #expect(snapshot.bankedResets?.allSatisfy(\.isAvailable) == true)
    #expect(snapshot.bankedResets?.first?.expiresAt == parseISODate("2099-01-01T00:00:00Z"))
    #expect(snapshot.windows.first?.usedPercent == 12)

    let ineligible = try JSONDecoder().decode(
        ClaudeUsageAPI.UsageResponse.self,
        from: Data(#"{"five_hour": {"utilization": 1}, "cedar_ember": {"eligible": false, "grants": []}}"#.utf8))
    #expect(ClaudeUsageAPI.snapshot(from: ineligible, plan: nil).bankedResets == nil)
}

@Test func resetGrantQueryFallsBackOnRefusal() async throws {
    let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    var asked: [String?] = []
    let data = try await ClaudeUsageAPI.withResetGrants(url) { u, passing in
        asked.append(u.query)
        if u.query != nil, passing.contains(403) { throw HTTP.Status(code: 403) }
        return Data("ok".utf8)
    }
    #expect(asked == ["cedar_ember=1", nil])
    #expect(String(decoding: data, as: UTF8.self) == "ok")
}
