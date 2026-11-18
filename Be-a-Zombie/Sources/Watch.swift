import AppKit

// MARK: - Running helper programs

struct ProcessResult {
    var status: Int32
    var out: String
    var err: String
}

/// Runs a program and waits for it. Call from a background queue.
func runProcess(_ path: String, _ args: [String], cwd: URL? = nil, timeout: TimeInterval = 30) -> ProcessResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
    p.environment = env
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    p.standardInput = FileHandle.nullDevice

    do { try p.run() } catch {
        return ProcessResult(status: -1, out: "", err: "\(error.localizedDescription)")
    }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

    var errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    p.waitUntilExit()
    killer.cancel()
    return ProcessResult(
        status: p.terminationStatus,
        out: String(data: outData, encoding: .utf8) ?? "",
        err: String(data: errData, encoding: .utf8) ?? ""
    )
}

// MARK: - Drift reminders (judged on this Mac; nothing is sent anywhere)

final class Supervisor {
    private let engine: Engine
    private var timer: Timer?
    private var busy = false
    private var refused = Set<String>()

    private static let chromeLike: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    init(engine: Engine) { self.engine = engine }

    func start() {
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static func matchSite(_ host: String, _ sites: [String]) -> String? {
        let h = host.lowercased()
        return sites.first { s in
            let d = s.lowercased()
            return h == d || h.hasSuffix("." + d)
        }
    }

    static func matchApp(name: String, bundleID: String, _ apps: [String]) -> String? {
        let n = name.lowercased(), b = bundleID.lowercased()
        return apps.first { a in
            let k = a.lowercased()
            return !k.isEmpty && (n.contains(k) || b.contains(k))
        }
    }

    private func tabScript(_ bundleID: String) -> [String]? {
        let tab: String
        if bundleID == "com.apple.Safari" {
            tab = "current tab"
        } else if Self.chromeLike.contains(bundleID) {
            tab = "active tab"
        } else {
            return nil
        }
        return [
            "-e", "tell application id \"\(bundleID)\"",
            "-e", "if (count of windows) > 0 then return URL of \(tab) of front window",
            "-e", "end tell",
        ]
    }

    private func sample() {
        guard engine.config.watch, engine.wantsWatching,
              let app = NSWorkspace.shared.frontmostApplication
        else {
            engine.reportFront(key: nil)
            return
        }
        let name = app.localizedName ?? ""
        let bid = app.bundleIdentifier ?? ""
        if bid == Bundle.main.bundleIdentifier { return }

        if let hit = Self.matchApp(name: name, bundleID: bid, engine.config.apps) {
            engine.reportFront(key: "app:" + hit)
            return
        }
        guard let script = tabScript(bid), !refused.contains(bid) else {
            engine.reportFront(key: nil)
            return
        }
        if busy { return }
        busy = true
        let sites = engine.config.sites
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // The address is only compared with the drift list here. It is never stored or logged.
            let r = runProcess("/usr/bin/osascript", script, timeout: 150)
            let host = URL(string: r.out.trimmingCharacters(in: .whitespacesAndNewlines))?.host
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if r.status != 0 {
                    if r.err.contains("-1743") || r.err.contains("-10004") {
                        self.refused.insert(bid)
                        zlog("browser check not allowed for \(bid); watching app names only")
                    }
                    self.engine.reportFront(key: nil)
                    return
                }
                if let host, let site = Self.matchSite(host, sites) {
                    self.engine.reportFront(key: "site:" + site)
                } else {
                    self.engine.reportFront(key: nil)
                }
            }
        }
    }
}

// MARK: - The AI look (a screenshot goes to Claude through the user's own Claude Code login)

final class Brain {
    enum Failure: Error {
        case noCLI
        case notLoggedIn
        case noScreenAccess
        case failed(String)
    }

    struct Verdict {
        var onTask: Bool
        var say: String
    }

    private(set) var busy = false

    static func cliPath(_ config: Config) -> String? {
        var candidates: [String] = []
        if let p = config.claudePath, !p.isEmpty { candidates.append((p as NSString).expandingTildeInPath) }
        let home = NSHomeDirectory()
        candidates += [
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            home + "/.local/bin/claude", home + "/.claude/local/claude", home + "/.npm-global/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Turns the CLI's `--output-format json` output into a verdict.
    static func parse(_ output: String) -> Result<Verdict, Failure> {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
              let data = String(output[start...end]).data(using: .utf8),
              let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return .failure(.failed(String(output.prefix(120))))
        }
        let text = (top["result"] as? String) ?? ""
        if (top["is_error"] as? Bool) == true {
            if text.contains("/login") || text.lowercased().contains("not logged in") { return .failure(.notLoggedIn) }
            return .failure(.failed(String(text.prefix(120))))
        }
        if let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"),
           let inner = String(text[s...e]).data(using: .utf8),
           let v = (try? JSONSerialization.jsonObject(with: inner)) as? [String: Any],
           let say = v["say"] as? String {
            return .success(Verdict(onTask: (v["on_task"] as? Bool) ?? true, say: say))
        }
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? .failure(.failed("empty answer")) : .success(Verdict(onTask: true, say: String(plain.prefix(80))))
    }

    static func prompt(block: Block, minutesLeft: Int, shotPath: String) -> (system: String, user: String) {
        let system = """
        You are the brain of a small desktop zombie pet that walks its human through today's plan. \
        You look at one screenshot and say what to do next. Warm, a little silly, never scolding. \
        Output only the JSON object you are asked for.
        """
        let language = L.zh ? "Simplified Chinese, at most 28 characters" : "English, at most 16 words"
        let user = """
        Read the image file \(shotPath). It is a screenshot of my screen right now.

        The block I am supposed to be doing: \(block.label) (\(minutesLeft) min left).

        Decide whether what is on screen is work on this block. Then tell me the single next concrete \
        action to take, as specific as the screenshot allows: which window to go to, which part to \
        write or read next.

        Reply with only this JSON and nothing else: {"on_task": true or false, "say": "one sentence in \(language)"}
        """
        return (system, user)
    }

    func ask(cli: String, system: String, user: String) -> Result<Verdict, Failure> {
        let args = [
            "-p", user,
            "--safe-mode",
            "--model", "haiku",
            "--tools", "Read",
            "--allowedTools", "Read",
            "--no-session-persistence",
            "--system-prompt", system,
            "--output-format", "json",
        ]
        let r = runProcess(cli, args, cwd: Paths.dir, timeout: 120)
        if r.out.isEmpty { return .failure(.failed(String(r.err.prefix(120)))) }
        return Self.parse(r.out)
    }

    /// Takes one screenshot, asks Claude about it, deletes the screenshot. Completion runs on the main queue.
    func look(cli: String, block: Block, minutesLeft: Int, completion: @escaping (Result<Verdict, Failure>) -> Void) {
        guard !busy else { return }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            completion(.failure(.noScreenAccess))
            return
        }
        busy = true
        let shot = Paths.shot.path
        let p = Self.prompt(block: block, minutesLeft: minutesLeft, shotPath: shot)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { try? FileManager.default.removeItem(atPath: shot) }
            var result: Result<Verdict, Failure>
            let cap = runProcess("/usr/sbin/screencapture", ["-x", "-m", "-t", "jpg", shot], timeout: 20)
            if cap.status != 0 || !FileManager.default.fileExists(atPath: shot) {
                result = .failure(.noScreenAccess)
            } else {
                _ = runProcess("/usr/bin/sips", ["-Z", "1400", shot], timeout: 20)
                result = self?.ask(cli: cli, system: p.system, user: p.user) ?? .failure(.failed("gone"))
            }
            DispatchQueue.main.async {
                self?.busy = false
                completion(result)
            }
        }
    }
}
