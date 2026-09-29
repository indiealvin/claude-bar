import Foundation

/// Connects UsageBar to Claude Code by pointing Claude Code's status line at usagebar-hook,
/// which saves the usage limits and then runs the user's own status line unchanged.
enum ClaudeSetup {
    // $HOME first, as Claude Code itself resolves ~/.claude.
    static let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser
    static let claudeDir = home.appendingPathComponent(".claude")
    /// Claude Code's own state file. Its cached /usage data is the only place the per-model weekly
    /// windows (such as Fable) are written, as the status line JSON carries just the 5h and 7d ones.
    static let claudeJSONURL = home.appendingPathComponent(".claude.json")
    static let settingsURL = claudeDir.appendingPathComponent("settings.json")
    static let hookDir = claudeDir.appendingPathComponent("usagebar")
    // Installed outside the app bundle so the status line keeps working if the app is moved or deleted.
    static let hookURL = hookDir.appendingPathComponent("usagebar-hook")
    static let configURL = hookDir.appendingPathComponent("config.json")
    static let lastRunURL = hookDir.appendingPathComponent("last-run.json")
    static let backupURL = claudeDir.appendingPathComponent("settings.json.usagebar-backup")

    struct SetupError: LocalizedError {
        let errorDescription: String?
    }

    struct LastRun: Decodable {
        let ran_at: TimeInterval
        let had_rate_limits: Bool
    }

    static var hookCommand: String { "'\(hookURL.path)'" }

    static var bundledHook: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "usagebar-hook")
    }

    /// Claude Code's status line currently runs our hook.
    static var isConnected: Bool {
        guard let settings = try? readSettings(),
              let statusLine = settings["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else { return false }
        return command.contains("usagebar/usagebar-hook")
    }

    static var lastRun: LastRun? {
        (try? Data(contentsOf: lastRunURL)).flatMap { try? JSONDecoder().decode(LastRun.self, from: $0) }
    }

    static func connect() throws {
        try installHook()
        var settings = try readSettings()
        let current = settings["statusLine"] as? [String: Any]
        if !isOurs(current) {
            // Remember the user's status line so the hook can keep running it and disconnect can restore it.
            let original: Any = current ?? NSNull()
            let data = try JSONSerialization.data(withJSONObject: ["original_status_line": original],
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configURL, options: .atomic)
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                // Copy the contents, not the file: a symlinked settings.json would otherwise back up as a link.
                try Data(contentsOf: settingsURL).write(to: backupURL, options: .atomic)
            }
        }
        // Keep the user's other status line options, such as padding.
        var statusLine = current ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = hookCommand
        settings["statusLine"] = statusLine
        try writeSettings(settings)
    }

    static func disconnect() throws {
        var settings = try readSettings()
        let config = (try? Data(contentsOf: configURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if let original = config?["original_status_line"] as? [String: Any] {
            settings["statusLine"] = original
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try writeSettings(settings)
        try? FileManager.default.removeItem(at: hookDir)
    }

    /// After an app update, replace the installed hook with the bundled one.
    static func refreshHookIfNeeded() {
        guard isConnected, let bundled = bundledHook,
              FileManager.default.contentsEqual(atPath: bundled.path, andPath: hookURL.path) == false else { return }
        try? installHook()
    }

    private static func isOurs(_ statusLine: [String: Any]?) -> Bool {
        (statusLine?["command"] as? String)?.contains("usagebar/usagebar-hook") == true
    }

    private static func installHook() throws {
        guard let bundled = bundledHook else {
            throw SetupError(errorDescription: "usagebar-hook is missing from the app bundle.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: hookDir, withIntermediateDirectories: true)
        let tmp = hookDir.appendingPathComponent("usagebar-hook.new")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: bundled, to: tmp)
        // A copy from a downloaded app inherits its quarantine flag, and Gatekeeper would then
        // block Claude Code from running it. The user already chose to open this app.
        removexattr(tmp.path, "com.apple.quarantine", 0)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        _ = try fm.replaceItemAt(hookURL, withItemAt: tmp)
    }

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09 }) { return [:] }
        guard let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Never overwrite a file we cannot parse.
            throw SetupError(errorDescription: "~/.claude/settings.json isn't valid JSON, so it was left unchanged.")
        }
        return settings
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // Write through a symlink (settings kept in a dotfiles repo) instead of replacing it.
        try data.write(to: settingsURL.resolvingSymlinksInPath(), options: .atomic)
    }
}
