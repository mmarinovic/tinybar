import Foundation

/// Claude limits. Source order (SPEC §4): Claude Code's OAuth login → claude.ai browser
/// session (opt-in). With several logins (`~/.claude-*` config dirs), each one's windows are
/// shown, prefixed with its label.
public struct ClaudeProvider: UsageProvider {
    public let id = ProviderID.claude
    private let session: URLSession
    private let allowBrowser: @Sendable () -> Bool

    public init(session: URLSession = .tinybar, allowBrowser: @escaping @Sendable () -> Bool = { false }) {
        self.session = session
        self.allowBrowser = allowBrowser
    }

    public func isConfigured() -> Bool {
        ClaudeCredentials.hasStoredLogin()
    }

    public func fetch() async throws -> ProviderSnapshot {
        let accounts = ClaudeAccount.discover()
        guard accounts.count > 1 else { return try await fetchSingle(accounts.first) }

        let session = session
        let results = await withTaskGroup(of: (Int, Result<ProviderSnapshot, Error>).self) { group in
            for (i, account) in accounts.enumerated() {
                group.addTask {
                    do { return (i, .success(try await Self.fetch(account, session: session))) }
                    catch { return (i, .failure(error)) }
                }
            }
            var out: [(Int, Result<ProviderSnapshot, Error>)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }
        }
        return try Self.merge(zip(accounts, results.map(\.1)).map { ($0, $1) })
    }

    private func fetchSingle(_ account: ClaudeAccount?) async throws -> ProviderSnapshot {
        do {
            guard let account else { throw ProviderError.notConfigured }
            return try await Self.fetch(account, session: session)
        } catch let error as ProviderError {
            guard error == .loginExpired || error == .notConfigured, allowBrowser() else { throw error }
            guard let found = BrowserCookies.find(domain: "claude.ai", required: ["sessionKey"]),
                  let key = found.cookies["sessionKey"]
            else { throw error }
            return try await ClaudeWebAPI.fetch(sessionKey: key, session: session)
        }
    }

    static func fetch(_ account: ClaudeAccount, session: URLSession) async throws -> ProviderSnapshot {
        let creds = try ClaudeCredentials.load(account)
        // An expired token would just 401. Claude Code refreshes it on its next run.
        guard !creds.isExpired else { throw ProviderError.loginExpired }
        let usage = try await ClaudeUsageAPI.fetchUsage(accessToken: creds.accessToken, session: session)
        return ClaudeUsageAPI.snapshot(from: usage, plan: creds.planName)
    }

    /// One snapshot from several logins' results. Throws only when none could be read.
    static func merge(_ results: [(ClaudeAccount, Result<ProviderSnapshot, Error>)]) throws -> ProviderSnapshot {
        var windows: [LimitWindow] = []
        var banked: [BankedReset] = []
        var extra: ExtraUsageSpend?
        var plans: [String: String] = [:]
        var errors: [String] = []
        var fetchedAt: Date?
        var firstError: Error?

        for (account, result) in results {
            switch result {
            case let .failure(error):
                firstError = firstError ?? error
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let hint = (error as? ProviderError) == .loginExpired ? ": run `\(account.cliCommand)` once" : ""
                errors.append("\(account.label): \(message)\(hint)")
            case let .success(s):
                fetchedAt = min(fetchedAt ?? s.fetchedAt, s.fetchedAt)
                plans[account.label] = s.plan
                windows += s.windows.map { w in
                    var w = w
                    w.id = "\(account.label):\(w.id)"
                    w.title = "\(account.label) · \(w.title)"
                    w.account = account.label
                    return w
                }
                banked += (s.bankedResets ?? []).map { r in
                    var r = r
                    r.id = "\(account.label):\(r.id)"
                    return r
                }
                if let e = s.extraUsage {
                    if let current = extra, current.currency == e.currency {
                        extra = ExtraUsageSpend(
                            used: current.used + e.used,
                            limit: current.limit.flatMap { a in e.limit.map { a + $0 } },
                            currency: e.currency)
                    } else if extra == nil {
                        extra = e
                    }
                }
            }
        }
        guard let fetchedAt else { throw firstError ?? ProviderError.notConfigured }
        var snapshot = ProviderSnapshot(
            provider: .claude, plan: "\(results.count) accounts",
            windows: windows, bankedResets: banked.isEmpty ? nil : banked, extraUsage: extra,
            fetchedAt: fetchedAt, accountErrors: errors.isEmpty ? nil : errors)
        snapshot.accountPlans = plans
        return snapshot
    }
}
