import Foundation

/// Opt-in: asks Anthropic for the account's usage directly, with the login Claude Code keeps on this Mac.
/// Usage belongs to the account, so this stays current while Claude Code runs on another host, where
/// neither the status line nor the /usage cache on this Mac is updated.
///
/// It reads Claude Code's access token but never renews it with the refresh token itself: two programs
/// renewing one login can sign Claude Code out. When the token has expired, it runs Claude Code's local
/// /usage command instead (`claude -p /usage`), which makes no model call, so it costs no usage, and
/// renews the login through Claude Code's own code. Then it reads the token again.
enum UsageFetcher {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Claude Code refetches at most once a minute; every 5 minutes keeps the load well below that.
    static let interval: TimeInterval = 300
    /// After a 429, wait longer before asking again.
    static let backoff: TimeInterval = 900

    enum Failure: Error, Equatable {
        case noLogin, loginExpired, rateLimited, http(Int), network(String), badResponse

        var message: String {
            switch self {
            case .noLogin: return "No Claude Code login found on this Mac. Run claude and /login here once."
            case .loginExpired: return "Claude Code's login on this Mac has expired and couldn't be renewed. Run claude here once."
            case .rateLimited: return "Anthropic asked to slow down. Retrying in 15 min."
            case .http(let code): return "Anthropic answered HTTP \(code)."
            case .network(let text): return "Couldn't reach Anthropic: \(text)"
            case .badResponse: return "Anthropic's answer wasn't usage data."
            }
        }
    }

    struct Token {
        let accessToken: String
        /// Epoch milliseconds, as Claude Code stores it.
        let expiresAtMs: Double?
    }

    /// Claude Code keeps its login in the Keychain item "Claude Code-credentials", written with the
    /// security tool, or in ~/.claude/.credentials.json where the Keychain is unavailable. Reading it
    /// through /usr/bin/security, as Claude Code does, avoids a Keychain prompt for this app.
    static func readToken() -> Token? {
        if let data = runSecurity(), let token = parse(data) { return token }
        let file = ClaudeSetup.claudeDir.appendingPathComponent(".credentials.json")
        return (try? Data(contentsOf: file)).flatMap(parse)
    }

    private static func runSecurity() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    private static func parse(_ data: Data) -> Token? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty else { return nil }
        return Token(accessToken: access, expiresAtMs: oauth["expiresAt"] as? Double)
    }

    /// Where Claude Code is installed. Apps started from the Dock don't get the shell's PATH, so the
    /// usual install locations are tried first, then a login shell.
    static func claudeExecutable() -> URL? {
        let home = ClaudeSetup.home.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let out = run(URL(fileURLWithPath: shell), ["-lc", "command -v claude"], timeout: 10),
              let path = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Lets Claude Code renew its own login by running its local /usage command. Returns whether it ran.
    static func renewLogin() -> Bool {
        guard let claude = claudeExecutable() else { return false }
        return run(claude, ["-p", "/usage", "--no-session-persistence"], timeout: 60,
                   directory: FileManager.default.temporaryDirectory) != nil
    }

    /// Runs a program and returns its output, or nil if it failed or ran past the timeout.
    private static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval,
                            directory: URL? = nil) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        // Run as a top-level Claude Code, not one nested inside another session.
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        return process.terminationReason == .exit && process.terminationStatus == 0 ? data : nil
    }

    private static func isExpired(_ token: Token) -> Bool {
        // A minute of margin so the request doesn't race the expiry.
        guard let expires = token.expiresAtMs else { return false }
        return expires / 1000 <= Date().timeIntervalSince1970 + 60
    }

    /// A token that is valid now, renewing Claude Code's login first if it has expired.
    private static func validToken(renewIfExpired: Bool) async -> Result<Token, Failure> {
        // The Keychain read and the renewal run subprocesses; keep them off the main thread.
        await Task.detached {
            guard let token = readToken() else { return .failure(.noLogin) }
            guard isExpired(token) else { return .success(token) }
            guard renewIfExpired, renewLogin(), let renewed = readToken(), !isExpired(renewed) else {
                return .failure(.loginExpired)
            }
            return .success(renewed)
        }.value
    }

    /// One fetch. The answer has the same shape as the /usage cache in ~/.claude.json. A rejected
    /// token, which can happen when it was revoked early, gets one renewal and one retry.
    static func fetch() async -> Result<ClaudeConfig.UsageCache, Failure> {
        switch await validToken(renewIfExpired: true) {
        case .failure(let failure): return .failure(failure)
        case .success(let token):
            let result = await request(token)
            guard case .failure(.loginExpired) = result else { return result }
            let renewed = await Task.detached { renewLogin() ? readToken() : nil }.value
            guard let renewed, renewed.accessToken != token.accessToken, !isExpired(renewed) else { return result }
            return await request(renewed)
        }
    }

    private static func request(_ token: Token) async -> Result<ClaudeConfig.UsageCache, Failure> {
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300: break
            case 401, 403: return .failure(.loginExpired)
            case 429: return .failure(.rateLimited)
            default: return .failure(.http(status))
            }
            guard let utilization = try? JSONDecoder().decode(ClaudeConfig.UsageCache.Utilization.self, from: data),
                  utilization.five_hour != nil || utilization.seven_day != nil || utilization.limits != nil
            else { return .failure(.badResponse) }
            return .success(ClaudeConfig.UsageCache(fetchedAtMs: Date().timeIntervalSince1970 * 1000,
                                                    utilization: utilization))
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
