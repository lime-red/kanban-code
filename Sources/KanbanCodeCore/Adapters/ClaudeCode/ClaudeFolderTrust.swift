import Foundation

/// Whether Claude Code trusts a folder: before its first run in a folder it
/// shows a trust screen that holds everything until it is answered. Claude
/// records the answer as `projects["<folder>"].hasTrustDialogAccepted` in
/// `~/.claude.json` (`$CLAUDE_CONFIG_DIR/.claude.json` when set), and trusting
/// a folder trusts every folder inside it. Only ever read here: running
/// Claude sessions rewrite that file.
public enum ClaudeFolderTrust {
    /// The config file Claude reads trust from.
    public static func configPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return (dir as NSString).appendingPathComponent(".claude.json")
        }
        return (home as NSString).appendingPathComponent(".claude.json")
    }

    /// `folder` or a folder above it is trusted. Nil when the config cannot
    /// be read, so a caller can tell "not trusted" from "don't know".
    public static func isTrusted(_ folder: String, configPath: String = configPath()) -> Bool? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let projects = object["projects"] as? [String: Any] ?? [:]
        var path = (folder as NSString).standardizingPath
        while true {
            if let entry = projects[path] as? [String: Any],
               entry["hasTrustDialogAccepted"] as? Bool == true {
                return true
            }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { return false }
            path = parent
        }
    }
}
