import Foundation

/// Opt-in: asks Anthropic for the account's usage directly, with the login Claude Code keeps on this Mac.
/// Usage belongs to the account, so this stays current while Claude Code runs on another host, where
/// neither the status line nor the /usage cache on this Mac is updated.
///
/// It only reads Claude Code's access token and never renews it: renewing could replace the login
/// Claude Code holds and sign it out. Once the token expires, fetching pauses until Claude Code on this
/// Mac renews it, which it does whenever it runs.
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
            case .loginExpired: return "Claude Code's login on this Mac has expired. Run claude here once to renew it."
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

    /// One fetch. The answer has the same shape as the /usage cache in ~/.claude.json.
    static func fetch() async -> Result<ClaudeConfig.UsageCache, Failure> {
        // The Keychain read runs a short subprocess; keep it off the main thread.
        let token = await Task.detached { readToken() }.value
        guard let token else { return .failure(.noLogin) }
        if let expires = token.expiresAtMs, expires / 1000 <= Date().timeIntervalSince1970 {
            return .failure(.loginExpired)
        }
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
