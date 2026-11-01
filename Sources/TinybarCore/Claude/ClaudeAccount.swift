import CryptoKit
import Foundation

/// One Claude Code login: a config dir and the credentials Claude Code keeps for it.
///
/// Claude Code stores the login of the default `~/.claude` in the Keychain item
/// `Claude Code-credentials`, and of any other `CLAUDE_CONFIG_DIR` in
/// `Claude Code-credentials-<first 8 hex of SHA-256 of the dir path>`.
public struct ClaudeAccount: Sendable, Hashable {
    public var configDir: URL
    public var label: String
    public var email: String?

    public init(configDir: URL, label: String, email: String?) {
        self.configDir = configDir
        self.label = label
        self.email = email
    }

    var credentialsFile: URL { configDir.appendingPathComponent(".credentials.json") }

    var keychainServices: [String] {
        let hashed = "\(ClaudeCredentials.keychainService)-\(Self.pathHash(configDir.path))"
        return isDefaultDir ? [ClaudeCredentials.keychainService, hashed] : [hashed]
    }

    /// The command that renews this login.
    public var cliCommand: String {
        isDefaultDir ? "claude" : "CLAUDE_CONFIG_DIR=\(configDir.path) claude"
    }

    private var isDefaultDir: Bool {
        let name = configDir.lastPathComponent
        return name == ".claude" || configDir.path.hasSuffix("/.config/claude")
    }

    static func pathHash(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    static func label(for dir: URL) -> String {
        let name = dir.lastPathComponent
        if name.hasPrefix(".claude-") { return String(name.dropFirst(".claude-".count)) }
        if name == ".claude" || name == "claude" { return "default" }
        return name.hasPrefix(".") ? String(name.dropFirst()) : name
    }

    static func email(for dir: URL, home: URL = Paths.home) -> String? {
        let candidates = [
            dir.appendingPathComponent(".claude.json"),
            home.appendingPathComponent(".claude.json"),
        ]
        let files = dir.lastPathComponent == ".claude" ? candidates.reversed() : [candidates[0]]
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = json["oauthAccount"] as? [String: Any],
                  let email = account["emailAddress"] as? String, !email.isEmpty
            else { continue }
            return email
        }
        return nil
    }

    /// Every config dir with a stored login, one per account email, in config dir order.
    public static func discover(
        dirs: [URL] = Paths.claudeConfigDirs(),
        hasLogin: ((ClaudeAccount) -> Bool)? = nil
    ) -> [ClaudeAccount] {
        let hasLogin = hasLogin ?? { account in
            FileManager.default.fileExists(atPath: account.credentialsFile.path)
                || account.keychainServices.contains(where: ClaudeCredentials.keychainItemExists)
        }
        var seen = Set<String>()
        var out: [ClaudeAccount] = []
        for dir in dirs {
            let account = ClaudeAccount(configDir: dir, label: label(for: dir), email: email(for: dir))
            guard hasLogin(account) else { continue }
            if let email = account.email {
                guard seen.insert(email.lowercased()).inserted else { continue }
            }
            out.append(account)
        }
        return out
    }
}
