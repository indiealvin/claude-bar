// Claude Code status line command installed by UsageBar.
//
// Claude Code runs it with the status line JSON on stdin. It:
//   1. saves only the rate_limits windows (used_percentage, resets_at) to ~/.claude/usage-bar.json,
//      and only when this session has completed a reply since its last write (see isNewReply),
//   2. records that it ran, whether limits were present and whether it wrote, in
//      ~/.claude/usagebar/last-run.json,
//   3. runs the status line command the user had before, with the same stdin, and passes its
//      output through, so their status line looks exactly as it did.
// Foundation only, so it starts fast and needs neither jq nor the app to be running.
import CryptoKit
import Foundation

// The user's status line may exit without reading stdin; writing to its closed pipe must not kill us.
signal(SIGPIPE, SIG_IGN)

// $HOME first, as Claude Code itself resolves ~/.claude.
let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser
let claudeDir = home.appendingPathComponent(".claude")
let hookDir = claudeDir.appendingPathComponent("usagebar")
// One marker per session, named by a hash of its ID, holding the api time of its last snapshot.
// Shared with scripts/usage-snapshot.sh so a status line that runs both writes once.
let markersDir = hookDir.appendingPathComponent("sessions")
let input = FileHandle.standardInput.readDataToEndOfFile()

func writeJSON(_ object: Any, to url: URL) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    try? data.write(to: url, options: .atomic)
}

/// Claude Code also re-renders the status line without a new reply: on a timer, after /usage, when a
/// setting changes. Those runs repeat the rate-limit headers of this session's last reply, which may be
/// hours old, and must not overwrite a fresher snapshot written by another session. The session's
/// cost.total_api_duration_ms only moves when a reply completes, so a run whose value matches this
/// session's last write is a re-render. Without a session ID or cost block, every run counts as new.
func isNewReply(_ status: [String: Any]) -> Bool {
    guard let sessionID = status["session_id"] as? String,
          let cost = status["cost"] as? [String: Any],
          let apiMs = cost["total_api_duration_ms"] as? Double else { return true }
    let digest = SHA256.hash(data: Data(sessionID.utf8)).map { String(format: "%02x", $0) }.joined()
    let marker = markersDir.appendingPathComponent(String(digest.prefix(16)))
    let stamp = "\(Int(apiMs))"
    if (try? String(contentsOf: marker, encoding: .utf8)) == stamp { return false }
    let fm = FileManager.default
    try? fm.createDirectory(at: markersDir, withIntermediateDirectories: true)
    try? stamp.write(to: marker, atomically: true, encoding: .utf8)
    // Markers of sessions not seen for a week are of no use.
    let stale = Date().addingTimeInterval(-7 * 86_400)
    for file in (try? fm.contentsOfDirectory(at: markersDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
        if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           modified < stale, file != marker {
            try? fm.removeItem(at: file)
        }
    }
    return true
}

var hadLimits = false
var wroteSnapshot = false
if let status = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
   let limits = status["rate_limits"] as? [String: Any] {
    var windows: [String: Any] = [:]
    for key in ["five_hour", "seven_day"] {
        guard let w = limits[key] as? [String: Any],
              let used = w["used_percentage"] as? Double,
              let resets = w["resets_at"] as? Double else { continue }
        windows[key] = ["used_percentage": used, "resets_at": resets]
    }
    if !windows.isEmpty {
        hadLimits = true
        if isNewReply(status) {
            wroteSnapshot = true
            writeJSON(["rate_limits": windows, "captured_at": Int(Date().timeIntervalSince1970)],
                      to: claudeDir.appendingPathComponent("usage-bar.json"))
        }
    }
}
writeJSON(["ran_at": Int(Date().timeIntervalSince1970), "had_rate_limits": hadLimits, "wrote_snapshot": wroteSnapshot],
          to: hookDir.appendingPathComponent("last-run.json"))

// The status line the user had before connecting, saved by the app.
let config = (try? Data(contentsOf: hookDir.appendingPathComponent("config.json")))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
guard let original = config?["original_status_line"] as? [String: Any],
      original["type"] as? String == "command",
      let command = original["command"] as? String, !command.isEmpty else { exit(0) }

let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/sh")
process.arguments = ["-c", command]
let stdin = Pipe()
process.standardInput = stdin
do {
    try process.run()
} catch {
    exit(0)
}
// Throwing variant: the legacy write(_:) raises an uncaught exception on a closed pipe.
try? stdin.fileHandleForWriting.write(contentsOf: input)
try? stdin.fileHandleForWriting.close()
process.waitUntilExit()
exit(process.terminationStatus)
