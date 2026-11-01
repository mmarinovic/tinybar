import Foundation

public enum Paths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Tinybar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func codexHome(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Claude Code config dirs: `CLAUDE_CONFIG_DIR` (comma-separated) and `~/.claude`,
    /// `~/.config/claude` and every `~/.claude-*` dir (one per `CLAUDE_CONFIG_DIR` login), whichever exist.
    public static func claudeConfigDirs(
        env: [String: String] = ProcessInfo.processInfo.environment, home: URL = Paths.home
    ) -> [URL] {
        let custom = (env["CLAUDE_CONFIG_DIR"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL }
        let fm = FileManager.default
        let candidates = [
            home.appendingPathComponent(".claude", isDirectory: true),
            home.appendingPathComponent(".config/claude", isDirectory: true),
        ]
        let extra = ((try? fm.contentsOfDirectory(atPath: home.path)) ?? [])
            .filter { $0.hasPrefix(".claude-") }
            .sorted()
            .map { home.appendingPathComponent($0, isDirectory: true) }
        let existing = (candidates + extra).filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
        }
        var seen = Set<String>()
        let all = (custom + existing).filter { seen.insert($0.path).inserted }
        return all.isEmpty ? [candidates[0]] : all
    }
}
