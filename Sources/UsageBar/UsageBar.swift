import SwiftUI

// Snapshot written by the Claude Code status line hook (usagebar-hook, or scripts/usage-snapshot.sh).
struct Snapshot: Decodable {
    struct Window: Decodable {
        let used_percentage: Double
        let resets_at: TimeInterval
    }
    struct Limits: Decodable {
        let five_hour: Window?
        let seven_day: Window?
    }
    let rate_limits: Limits
    let captured_at: TimeInterval
}

// The parts of ~/.claude.json UsageBar reads: Claude Code's cache of its /usage endpoint. Every field
// is optional so a row of an unexpected shape drops out instead of failing the whole decode.
struct ClaudeConfig: Decodable {
    struct UsageCache: Decodable {
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable {
                    let display_name: String?
                }
                let model: Model?
            }
            let kind: String?
            let percent: Double?
            let resets_at: String?
            let scope: Scope?
        }
        struct Utilization: Decodable {
            let limits: [Limit]?
        }
        let fetchedAtMs: Double
        let utilization: Utilization?

        /// The per-model weekly windows, as /usage lists them under "Current week (<model>)".
        var modelWindows: [ModelWindow] {
            let fetchedAt = Date(timeIntervalSince1970: fetchedAtMs / 1000)
            return (utilization?.limits ?? []).compactMap { limit in
                guard limit.kind == "weekly_scoped", let percent = limit.percent,
                      let name = limit.scope?.model?.display_name, !name.isEmpty else { return nil }
                return ModelWindow(name: name, percent: percent,
                                   resetsAt: limit.resets_at.flatMap(parseISODate)?.timeIntervalSince1970,
                                   fetchedAt: fetchedAt)
            }
        }
    }
    let cachedUsageUtilization: UsageCache?
}

/// A weekly window for one model, e.g. Fable, from Claude Code's cached /usage data.
struct ModelWindow: Identifiable {
    let name: String
    let percent: Double
    /// Nil when Claude Code reported no reset time for the window.
    let resetsAt: TimeInterval?
    /// When Claude Code fetched the numbers, usually the last time /usage ran.
    let fetchedAt: Date
    var id: String { "\(name)@\(resetsAt ?? 0)" }
}

/// Claude Code writes "2026-09-30T12:00:00.016111+00:00". ISO8601DateFormatter only reliably parses
/// three fractional digits, so the fraction is dropped first.
func parseISODate(_ s: String) -> Date? {
    let whole = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return ISO8601DateFormatter().date(from: whole)
}

@MainActor
final class UsageStore: ObservableObject {
    static let fileURL = ClaudeSetup.claudeDir.appendingPathComponent("usage-bar.json")

    @Published var snapshot: Snapshot?
    @Published var modelWindows: [ModelWindow] = []
    @Published var now = Date()
    @Published var connected = ClaudeSetup.isConnected
    @Published var lastRun = ClaudeSetup.lastRun
    @Published var setupError: String?
    private var lastModified: Date?
    private var claudeJSONModified: Date?
    private var timer: Timer?

    init() {
        ClaudeSetup.refreshHookIfNeeded()
        reload()
        reloadModelWindows()
        // Polling a single small file is cheap and survives the hook's atomic rename,
        // which would break a file-descriptor based watcher.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
                self?.reload()
                self?.reloadModelWindows()
                self?.connected = ClaudeSetup.isConnected
                self?.lastRun = ClaudeSetup.lastRun
            }
        }
    }

    func reload() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Self.fileURL.path)
        let modified = attrs?[.modificationDate] as? Date
        guard modified != lastModified else { return }
        lastModified = modified
        guard let data = try? Data(contentsOf: Self.fileURL) else { snapshot = nil; return }
        snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Per-model weekly windows from Claude Code's cached /usage data in ~/.claude.json.
    func reloadModelWindows() {
        let url = ClaudeSetup.claudeJSONURL
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attrs?[.modificationDate] as? Date
        guard modified != claudeJSONModified else { return }
        claudeJSONModified = modified
        guard let data = try? Data(contentsOf: url) else { modelWindows = []; return }
        // Claude Code rewrites this file often; a read that lands mid-write keeps the last good value.
        guard let config = try? JSONDecoder().decode(ClaudeConfig.self, from: data) else { return }
        modelWindows = config.cachedUsageUtilization?.modelWindows ?? []
    }

    func connect() {
        do {
            try ClaudeSetup.connect()
            setupError = nil
        } catch {
            setupError = error.localizedDescription
        }
        connected = ClaudeSetup.isConnected
    }

    func disconnect() {
        do {
            try ClaudeSetup.disconnect()
            setupError = nil
        } catch {
            setupError = error.localizedDescription
        }
        connected = ClaudeSetup.isConnected
        lastRun = ClaudeSetup.lastRun
    }

    /// A window whose reset time has passed no longer describes current usage.
    func live(_ w: Snapshot.Window?) -> Snapshot.Window? {
        guard let w, w.resets_at > now.timeIntervalSince1970 else { return nil }
        return w
    }

    /// Model windows still in their window; one with no reset time is kept.
    var liveModelWindows: [ModelWindow] {
        modelWindows.filter { $0.resetsAt.map { $0 > now.timeIntervalSince1970 } ?? true }
    }

    /// The windows chosen in settings, paired with their short labels.
    func shown(_ windows: ShownWindows) -> [(label: String, window: Snapshot.Window?)] {
        let s = snapshot?.rate_limits
        var out: [(String, Snapshot.Window?)] = []
        if windows != .weekly { out.append(("5h", live(s?.five_hour))) }
        if windows != .fiveHour { out.append(("7d", live(s?.seven_day))) }
        return out
    }
}

// MARK: - Menu bar label settings

enum ShownWindows: String, CaseIterable, Identifiable {
    case fiveHour, weekly, both
    var id: Self { self }
    var name: String {
        switch self {
        case .fiveHour: return "5h"
        case .weekly: return "7d"
        case .both: return "Both"
        }
    }
}

enum LabelStyle: String, CaseIterable, Identifiable {
    case labeled, compact, bars, barsAndPercent
    var id: Self { self }
    var name: String {
        switch self {
        case .labeled: return "5h 60%"
        case .compact: return "60%"
        case .bars: return "Bars"
        case .barsAndPercent: return "Bars + %"
        }
    }
}

/// Short countdown for the menu bar, e.g. "2h", "35m", "3d".
func shortCountdown(to resetsAt: TimeInterval, from now: Date) -> String {
    let secs = max(0, resetsAt - now.timeIntervalSince1970)
    if secs >= 86_400 { return "\(Int(secs / 86_400))d" }
    if secs >= 3_600 { return "\(Int(secs / 3_600))h" }
    return "\(Int(secs / 60))m"
}

/// Tiny horizontal meters, rendered as a template image so they follow the menu bar's appearance.
struct MiniBars: View {
    let values: [Double?]

    var body: some View {
        VStack(spacing: values.count > 1 ? 2 : 0) {
            ForEach(values.indices, id: \.self) { i in
                let h: CGFloat = values.count > 1 ? 5 : 7
                ZStack(alignment: .leading) {
                    Capsule().stroke(lineWidth: 1).frame(width: 26, height: h)
                    Capsule()
                        .frame(width: max(0, 26 * CGFloat(min(values[i] ?? 0, 100) / 100)), height: h)
                }
            }
        }
        .foregroundStyle(.black)
        .padding(.vertical, 1)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore
    @AppStorage("shownWindows") private var windows: ShownWindows = .both
    @AppStorage("labelStyle") private var style: LabelStyle = .labeled
    @AppStorage("showIcon") private var showIcon = true
    @AppStorage("showCountdown") private var showCountdown = false

    var body: some View {
        let items = store.shown(windows)
        let hasBars = style == .bars || style == .barsAndPercent
        let text = text(items)
        // The icon always leads. A menu bar label shows one image and one text, so with bars the
        // icon is drawn into the bars image; otherwise it starts the text.
        HStack(spacing: 4) {
            if hasBars {
                barsImage(items.map { $0.window?.used_percentage }, icon: showIcon)
            }
            let label = !hasBars && showIcon ? (text.isEmpty ? "✳︎" : "✳︎ " + text) : text
            if !label.isEmpty {
                Text(label).monospacedDigit()
            }
        }
    }

    private func text(_ items: [(label: String, window: Snapshot.Window?)]) -> String {
        let parts: [String] = items.compactMap { item in
            let pct = item.window.map { "\(Int($0.used_percentage.rounded()))%" } ?? "–"
            let countdown = showCountdown ? item.window.map { " (\(shortCountdown(to: $0.resets_at, from: store.now)))" } ?? "" : ""
            switch style {
            case .labeled: return "\(item.label) \(pct)\(countdown)"
            case .compact, .barsAndPercent: return "\(pct)\(countdown)"
            case .bars: return countdown.isEmpty ? nil : countdown.trimmingCharacters(in: .whitespaces)
            }
        }
        return parts.joined(separator: style == .labeled ? " · " : "/")
    }

    @MainActor
    private func barsImage(_ values: [Double?], icon: Bool) -> Image {
        let renderer = ImageRenderer(content: HStack(spacing: 3) {
            if icon {
                Text("✳︎").font(.system(size: 13)).foregroundStyle(.black)
            }
            MiniBars(values: values)
        })
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let ns = renderer.nsImage else { return Image(systemName: "chart.bar") }
        ns.isTemplate = true
        return Image(nsImage: ns)
    }
}

struct DisplaySettings: View {
    @AppStorage("shownWindows") private var windows: ShownWindows = .both
    @AppStorage("labelStyle") private var style: LabelStyle = .labeled
    @AppStorage("showIcon") private var showIcon = true
    @AppStorage("showCountdown") private var showCountdown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu bar").font(.caption).foregroundStyle(.secondary)
            Picker("Show", selection: $windows) {
                ForEach(ShownWindows.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Style", selection: $style) {
                ForEach(LabelStyle.allCases) { Text($0.name).tag($0) }
            }
            Toggle("Show ✳︎ icon", isOn: $showIcon)
            Toggle("Show time until reset", isOn: $showCountdown)
        }
        .controlSize(.small)
    }
}

/// "v1.2.3 · 2e3bc52" for a release, "dev · 2e3bc52" for a local build.
let buildVersion: String = {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["UBBuildVersion"] as? String ?? "dev"
    guard let commit = info["UBBuildCommit"] as? String else { return version }
    return "\(version) · \(commit)"
}()

/// "in 22m" / "4s ago". RelativeDateTimeFormatter's short style can render these as "+22 min" / "-4 s".
func relative(_ date: Date, to now: Date) -> String {
    let secs = date.timeIntervalSince(now)
    if abs(secs) < 5 { return "just now" }
    let f = DateComponentsFormatter()
    f.unitsStyle = .abbreviated
    f.maximumUnitCount = 2
    f.allowedUnits = abs(secs) < 60 ? [.second] : [.day, .hour, .minute]
    let span = f.string(from: abs(secs)) ?? ""
    return secs > 0 ? "in \(span)" : "\(span) ago"
}

struct WindowRow: View {
    let label: String
    let percent: Double?
    let resetsAt: TimeInterval?
    let now: Date
    /// Where the numbers came from, when it isn't the status line.
    let source: String?

    init(label: String, window: Snapshot.Window?, now: Date) {
        self.init(label: label, percent: window?.used_percentage, resetsAt: window?.resets_at, now: now)
    }

    init(label: String, percent: Double?, resetsAt: TimeInterval?, now: Date, source: String? = nil) {
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
        self.now = now
        self.source = source
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.headline)
                Spacer()
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "–")
                    .monospacedDigit()
            }
            ProgressView(value: min(percent ?? 0, 100), total: 100)
                .tint(tint)
            Text(caption)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        var parts: [String] = []
        if let resetsAt { parts.append("Resets \(relative(Date(timeIntervalSince1970: resetsAt), to: now))") }
        if let source { parts.append(source) }
        if parts.isEmpty { return percent == nil ? "Window reset or not reported yet" : "No reset time reported" }
        return parts.joined(separator: " · ")
    }

    private var tint: Color {
        switch percent ?? 0 {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }
}

/// Shown until the first usage data arrives: what to do next, depending on how far setup got.
struct SetupStatus: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !store.connected {
                Text("Connect to Claude Code").font(.headline)
                Text("""
                    UsageBar reads your limits from Claude Code's status line. Connecting sets \
                    ~/.claude/settings.json to run UsageBar's helper, which keeps running your \
                    current status line. A backup is saved and Disconnect restores it.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Connect") { store.connect() }
                    .buttonStyle(.borderedProminent)
            } else if let run = store.lastRun, !run.had_rate_limits {
                Text("No usage limits reported").font(.headline)
                Text("""
                    Claude Code ran the helper \(relative(Date(timeIntervalSince1970: run.ran_at), to: store.now)) \
                    but sent no limits. They're only available when Claude Code is signed in with a \
                    Claude Pro or Max plan (run /login), not an API key, Bedrock or Vertex, and appear \
                    after the first reply in a session. Updating Claude Code can also help.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Waiting for Claude Code").font(.headline)
                Text("Connected. Send a prompt in Claude Code (start a new session if one was already open) and usage appears here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct UsageMenu: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let s = store.snapshot {
                WindowRow(label: "5-hour", window: store.live(s.rate_limits.five_hour), now: store.now)
                WindowRow(label: "Weekly", window: store.live(s.rate_limits.seven_day), now: store.now)
                // Claude Code's /usage lists these as "Current week (Fable)" and refreshes them mainly when
                // it runs, so each row carries the age of its own numbers.
                ForEach(store.liveModelWindows) { m in
                    WindowRow(label: "Weekly (\(m.name))", percent: m.percent, resetsAt: m.resetsAt, now: store.now,
                              source: "from /usage \(relative(m.fetchedAt, to: store.now))")
                }
                Text("Updated \(relative(Date(timeIntervalSince1970: s.captured_at), to: store.now)) by Claude Code")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                SetupStatus(store: store)
            }
            if let error = store.setupError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Divider()
            DisplaySettings()
            Divider()
            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                if store.connected {
                    Button("Disconnect") { store.disconnect() }
                        .help("Restore your previous Claude Code status line")
                } else if store.snapshot != nil {
                    // Data from a hand-made hook; offer the managed one.
                    Button("Connect") { store.connect() }
                        .help("Let UsageBar manage the Claude Code status line hook")
                }
                Spacer()
                Text(buildVersion)
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .help("Build version and commit")
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

@main
struct UsageBarApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            UsageMenu(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
