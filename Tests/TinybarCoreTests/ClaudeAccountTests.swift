import Foundation
import Testing
@testable import TinybarCore

@Test func claudeAccountKeychainServiceMatchesClaudeCode() {
    let work = ClaudeAccount(configDir: URL(fileURLWithPath: "/Users/x/.claude-work"), label: "work", email: nil)
    #expect(work.keychainServices == ["Claude Code-credentials-74ed04d5"])
    let main = ClaudeAccount(configDir: URL(fileURLWithPath: "/Users/x/.claude"), label: "default", email: nil)
    #expect(main.keychainServices.first == "Claude Code-credentials")
}

@Test func claudeAccountLabels() {
    #expect(ClaudeAccount.label(for: URL(fileURLWithPath: "/Users/x/.claude-work")) == "work")
    #expect(ClaudeAccount.label(for: URL(fileURLWithPath: "/Users/x/.claude")) == "default")
}

@Test func claudeConfigDirsFindsEveryClaudeDir() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    for name in [".claude", ".claude-a", ".claude-b", ".claude-json-not-dir"] where name != ".claude-json-not-dir" {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try Data().write(to: home.appendingPathComponent(".claude-json-not-dir"))
    let dirs = Paths.claudeConfigDirs(env: [:], home: home).map(\.lastPathComponent)
    #expect(dirs == [".claude", ".claude-a", ".claude-b"])
}

@Test func claudeAccountsDedupeByEmailAndSkipLoggedOut() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    func dir(_ name: String, email: String) throws -> URL {
        let d = home.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Data(#"{"oauthAccount":{"emailAddress":"\#(email)"}}"#.utf8).write(to: d.appendingPathComponent(".claude.json"))
        return d
    }
    let dirs = [try dir(".claude-a", email: "a@x"), try dir(".claude-b", email: "A@x"),
                try dir(".claude-c", email: "c@x"), try dir(".claude-d", email: "d@x")]
    let found = ClaudeAccount.discover(dirs: dirs, hasLogin: { $0.label != "d" })
    #expect(found.map(\.label) == ["a", "c"])
    #expect(found.first?.email == "a@x")
}

@Test func claudeMergePrefixesWindowsAndKeepsPartialFailures() throws {
    let a = ClaudeAccount(configDir: URL(fileURLWithPath: "/h/.claude-a"), label: "a", email: nil)
    let b = ClaudeAccount(configDir: URL(fileURLWithPath: "/h/.claude-b"), label: "b", email: nil)
    let snap = ProviderSnapshot(provider: .claude, plan: "Max 20x", windows: [
        LimitWindow(id: "session", title: "5-hour", usedPercent: 40, resetsAt: nil, durationSeconds: 5 * 3600),
    ])
    let merged = try ClaudeProvider.merge([(a, .success(snap)), (b, .failure(ProviderError.loginExpired))])
    #expect(merged.windows.map(\.id) == ["a:session"])
    #expect(merged.windows.first?.title == "a · 5-hour")
    #expect(merged.windows.first?.account == "a")
    #expect(merged.accountErrors?.first?.hasPrefix("b: Login expired") == true)
    #expect(throws: ProviderError.self) {
        try ClaudeProvider.merge([(b, .failure(ProviderError.loginExpired))])
    }
}

@Test func claudeConfigDirEnvAddsToDiscoveredDirs() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    for name in [".claude", ".claude-a", ".claude-b"] {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let env = ["CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude-b").path]
    let dirs = Paths.claudeConfigDirs(env: env, home: home).map(\.lastPathComponent)
    #expect(dirs == [".claude-b", ".claude", ".claude-a"])
}
