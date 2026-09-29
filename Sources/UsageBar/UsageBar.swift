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

/// A usage window's reading: how much of it is used and when it resets.
struct Reading: Equatable {
    let percent: Double
    let resetsAt: TimeInterval

    static func from(percent: Double?, resetsAt: TimeInterval?) -> Reading? {
        guard let percent, let resetsAt else { return nil }
        return Reading(percent: percent, resetsAt: resetsAt)
    }
}

// The parts of ~/.claude.json UsageBar reads: Claude Code's cache of its /usage endpoint. Every field
// is optional so a row of an unexpected shape drops out instead of failing the whole decode.
struct ClaudeConfig: Decodable {
    struct UsageCache: Decodable {
        struct Bucket: Decodable {
            let utilization: Double?
            let resets_at: String?
        }
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
            let five_hour: Bucket?
            let seven_day: Bucket?
            let limits: [Limit]?
        }
        let fetchedAtMs: Double
        let utilization: Utilization?

        var fetchedAt: Date { Date(timeIntervalSince1970: fetchedAtMs / 1000) }

        /// The 5-hour window, "Current session" in /usage.
        var fiveHour: Reading? { reading(kind: "session", bucket: utilization?.five_hour) }
        /// The weekly window for all models, "Current week (all models)".
        var sevenDay: Reading? { reading(kind: "weekly_all", bucket: utilization?.seven_day) }

        /// The per-model weekly windows, "Current week (<model>)".
        var modelWindows: [ModelWindow] {
            (utilization?.limits ?? []).compactMap { limit in
                guard limit.kind == "weekly_scoped", let percent = limit.percent,
                      let name = limit.scope?.model?.display_name, !name.isEmpty else { return nil }
                return ModelWindow(name: name, percent: percent,
                                   resetsAt: limit.resets_at.flatMap(parseISODate)?.timeIntervalSince1970)
            }
        }

        /// The limits[] row of a kind, or the older top-level bucket when there is no such row.
        private func reading(kind: String, bucket: Bucket?) -> Reading? {
            if let row = utilization?.limits?.first(where: { $0.kind == kind }) {
                return .from(percent: row.percent,
                             resetsAt: row.resets_at.flatMap(parseISODate)?.timeIntervalSince1970)
            }
            return .from(percent: bucket?.utilization,
                         resetsAt: bucket?.resets_at.flatMap(parseISODate)?.timeIntervalSince1970)
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
    var id: String { "\(name)@\(resetsAt ?? 0)" }
}

/// Claude Code writes "2026-09-30T04:59:59.599373+00:00". ISO8601DateFormatter only reliably parses
/// three fractional digits, so the fraction is split off and rounded back in as whole seconds, which
/// also lands on the same second the rate-limit headers report (5:00:00 for that example).
func parseISODate(_ s: String) -> Date? {
    var whole = s
    var fraction = 0.0
    if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
        fraction = Double("0" + s[r]) ?? 0
        whole.removeSubrange(r)
    }
    return ISO8601DateFormatter().date(from: whole)?.addingTimeInterval(fraction.rounded())
}

@MainActor
final class UsageStore: ObservableObject {
    static let fileURL = ClaudeSetup.claudeDir.appendingPathComponent("usage-bar.json")

    @Published var snapshot: Snapshot?
    @Published var cache: ClaudeConfig.UsageCache?
    /// The last answer from fetching usage directly, when that is turned on.
    @Published var direct: ClaudeConfig.UsageCache?
    @Published var directError: UsageFetcher.Failure?
    @Published var now = Date()
    @Published var connected = ClaudeSetup.isConnected
    @Published var lastRun = ClaudeSetup.lastRun
    @Published var setupError: String?
    private var lastModified: Date?
    private var claudeJSONModified: Date?
    private var timer: Timer?
    private var nextFetch = Date.distantPast
    private var fetching = false

    nonisolated static let fetchDirectlyKey = "fetchDirectly"
    var fetchDirectly: Bool { UserDefaults.standard.bool(forKey: Self.fetchDirectlyKey) }

    init() {
        ClaudeSetup.refreshHookIfNeeded()
        reload()
        reloadCache()
        fetchIfDue()
        // Polling a single small file is cheap and survives the hook's atomic rename,
        // which would break a file-descriptor based watcher.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
                self?.reload()
                self?.reloadCache()
                self?.fetchIfDue()
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

    /// Claude Code's cached /usage data in ~/.claude.json.
    func reloadCache() {
        let url = ClaudeSetup.claudeJSONURL
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attrs?[.modificationDate] as? Date
        guard modified != claudeJSONModified else { return }
        claudeJSONModified = modified
        guard let data = try? Data(contentsOf: url) else { cache = nil; return }
        // Claude Code rewrites this file often; a read that lands mid-write keeps the last good value.
        guard let config = try? JSONDecoder().decode(ClaudeConfig.self, from: data) else { return }
        cache = config.cachedUsageUtilization
    }

    /// Fetches usage directly when that is on and the interval has passed. Turning it on fetches at once.
    func fetchIfDue(force: Bool = false) {
        guard fetchDirectly else {
            direct = nil; directError = nil; nextFetch = .distantPast
            return
        }
        guard !fetching, force || Date() >= nextFetch else { return }
        fetching = true
        Task { @MainActor in
            let result = await UsageFetcher.fetch()
            fetching = false
            guard fetchDirectly else { return }
            switch result {
            case .success(let usage):
                direct = usage; directError = nil
                nextFetch = Date().addingTimeInterval(UsageFetcher.interval)
            case .failure(let failure):
                // Keep the last answer; the footer shows its age.
                directError = failure
                let wait = failure == .rateLimited ? UsageFetcher.backoff
                    // An expired login is renewed by Claude Code; look again soon so it is picked up.
                    : failure == .loginExpired || failure == .noLogin ? 60 : UsageFetcher.interval
                nextFetch = Date().addingTimeInterval(wait)
            }
        }
    }

    /// Something to show: a status line snapshot, or a direct fetch. The /usage cache alone isn't
    /// enough, so a fresh install still walks through Connect.
    var hasData: Bool { snapshot != nil || direct != nil }

    /// The dated readings each source has for a window.
    private func readings(_ window: (Snapshot.Limits) -> Snapshot.Window?,
                          _ cached: (ClaudeConfig.UsageCache) -> Reading?) -> [(at: TimeInterval, reading: Reading)] {
        var out: [(TimeInterval, Reading)] = []
        if let snapshot, let w = window(snapshot.rate_limits) {
            out.append((snapshot.captured_at, Reading(percent: w.used_percentage, resetsAt: w.resets_at)))
        }
        for source in [cache, direct].compactMap({ $0 }) {
            if let r = cached(source) { out.append((source.fetchedAt.timeIntervalSince1970, r)) }
        }
        return out
    }

    /// The 5-hour and weekly windows, each from whichever source is newest. Every timestamp means
    /// "time of real data": the hook writes only after a reply, and the /usage cache and a direct
    /// fetch are stamped when fetched. The status line measures a few points apart from the other
    /// two, so a row can step by that much when a newer source takes over.
    var fiveHour: Reading? { newest(readings({ $0.five_hour }, { $0.fiveHour })) }
    var sevenDay: Reading? { newest(readings({ $0.seven_day }, { $0.sevenDay })) }

    private func newest(_ readings: [(at: TimeInterval, reading: Reading)]) -> Reading? {
        guard hasData else { return nil }
        return readings.max(by: { $0.at < $1.at })?.reading
    }

    /// The newer of the /usage cache and a direct fetch, which are the only sources of model windows.
    var newestUsage: ClaudeConfig.UsageCache? {
        [cache, direct].compactMap { $0 }.max(by: { $0.fetchedAtMs < $1.fetchedAtMs })
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
    func live(_ r: Reading?) -> Reading? {
        guard let r, r.resetsAt > now.timeIntervalSince1970 else { return nil }
        return r
    }

    /// Model windows still in their window; one with no reset time is kept.
    var liveModelWindows: [ModelWindow] {
        guard hasData else { return [] }
        return (newestUsage?.modelWindows ?? []).filter { $0.resetsAt.map { $0 > now.timeIntervalSince1970 } ?? true }
    }

    /// The windows chosen in settings, paired with their short labels.
    func shown(_ windows: ShownWindows) -> [(label: String, reading: Reading?)] {
        var out: [(String, Reading?)] = []
        if windows != .weekly { out.append(("5h", live(fiveHour))) }
        if windows != .fiveHour { out.append(("7d", live(sevenDay))) }
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
                barsImage(items.map { $0.reading?.percent }, icon: showIcon)
            }
            let label = !hasBars && showIcon ? (text.isEmpty ? "✳︎" : "✳︎ " + text) : text
            if !label.isEmpty {
                Text(label).monospacedDigit()
            }
        }
    }

    private func text(_ items: [(label: String, reading: Reading?)]) -> String {
        let parts: [String] = items.compactMap { item in
            let pct = item.reading.map { "\(Int($0.percent.rounded()))%" } ?? "–"
            let countdown = showCountdown ? item.reading.map { " (\(shortCountdown(to: $0.resetsAt, from: store.now)))" } ?? "" : ""
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

/// The opt-in switch for fetching usage directly from Anthropic.
struct FetchSetting: View {
    @ObservedObject var store: UsageStore
    @AppStorage(UsageStore.fetchDirectlyKey) private var fetchDirectly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Fetch usage every 5 min", isOn: $fetchDirectly)
                .onChange(of: fetchDirectly) { _ in store.fetchIfDue(force: true) }
            Text("""
                Asks Anthropic directly with Claude Code's login on this Mac, so usage stays current \
                while you use Claude Code on another host.
                """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .controlSize(.small)
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

    init(label: String, reading: Reading?, now: Date) {
        self.init(label: label, percent: reading?.percent, resetsAt: reading?.resetsAt, now: now)
    }

    init(label: String, percent: Double?, resetsAt: TimeInterval?, now: Date) {
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
        self.now = now
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
            // Without fixedSize the popover gives the caption one line and truncates it with "…".
            Text(caption)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var caption: String {
        var parts: [String] = []
        if let resetsAt { parts.append("Resets \(relative(Date(timeIntervalSince1970: resetsAt), to: now))") }
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
            if store.hasData {
                WindowRow(label: "5-hour", reading: store.live(store.fiveHour), now: store.now)
                WindowRow(label: "Weekly", reading: store.live(store.sevenDay), now: store.now)
                // Only /usage and a direct fetch report these, as "Current week (Fable)".
                ForEach(store.liveModelWindows) { m in
                    WindowRow(label: "Weekly (\(m.name))", percent: m.percent, resetsAt: m.resetsAt, now: store.now)
                }
                Text(updated)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SetupStatus(store: store)
            }
            if let error = store.setupError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let failure = store.directError {
                Text(failure.message).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            FetchSetting(store: store)
            Divider()
            DisplaySettings()
            Divider()
            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                if store.connected {
                    Button("Disconnect") { store.disconnect() }
                        .help("Restore your previous Claude Code status line")
                } else if store.snapshot != nil || store.direct != nil {
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

    /// How old each source is, e.g. "Fetched 20 s ago · status line 3 min ago · /usage 1 h ago".
    private var updated: String {
        var parts: [String] = []
        if let d = store.direct { parts.append("fetched \(relative(d.fetchedAt, to: store.now))") }
        if let s = store.snapshot {
            parts.append("status line \(relative(Date(timeIntervalSince1970: s.captured_at), to: store.now))")
        }
        if let c = store.cache { parts.append("/usage \(relative(c.fetchedAt, to: store.now))") }
        guard let first = parts.first else { return "" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: " · ")
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
