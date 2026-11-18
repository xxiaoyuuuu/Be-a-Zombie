import Foundation

// MARK: - Paths

enum Paths {
    static let dir: URL = {
        if let h = ProcessInfo.processInfo.environment["ZOMBIE_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zombie", isDirectory: true)
    }()
    static let plan = dir.appendingPathComponent("plan.json")
    static let state = dir.appendingPathComponent("state.json")
    static let config = dir.appendingPathComponent("config.json")
    static let log = dir.appendingPathComponent("pet.log")
    static let shot = dir.appendingPathComponent("shot.jpg")
}

func zlog(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: Paths.log) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        try? data.write(to: Paths.log)
    }
}

// MARK: - Language

enum L {
    static var zh = true
    static func t(_ z: String, _ e: String) -> String { zh ? z : e }
}

// MARK: - Time helpers

let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private let clockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm"
    return f
}()

func hhmm(_ d: Date) -> String { clockFormatter.string(from: d) }

func minutesOfDay(_ s: String) -> Int? {
    let p = s.split(separator: ":")
    guard p.count >= 2, let h = Int(p[0]), let m = Int(p[1].prefix(2)) else { return nil }
    return h * 60 + m
}

func fnv1a(_ data: Data) -> String {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in data {
        h ^= UInt64(b)
        h = h &* 0x0000_0100_0000_01b3
    }
    return String(h, radix: 16)
}

// MARK: - Plan (written by the be-a-zombie skill)

struct Block {
    enum Kind: String { case work, treat, rest = "break", meal, fixed }

    var id: String
    var start: String
    var minutes: Int
    var kind: Kind
    var emoji: String
    var name: String
    var brains: Int
    var act: String
    var planDone: Bool

    var isRest: Bool { kind == .treat || kind == .rest || kind == .meal }
    var label: String {
        if emoji.isEmpty || name.hasPrefix(emoji) { return name }
        return emoji + " " + name
    }
}

struct Plan {
    var date: String
    var lang: String?
    var title: String
    var finish: String
    var blocks: [Block]
    var buried: [String]
    var signature: String

    func isFor(_ now: Date) -> Bool {
        if date == dayFormatter.string(from: now) { return true }
        let yesterday = dayFormatter.string(from: now.addingTimeInterval(-86400))
        return date == yesterday && Calendar.current.component(.hour, from: now) < 5
    }

    static func load(from url: URL) -> Plan? {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = obj["blocks"] as? [[String: Any]], !raw.isEmpty
        else { return nil }

        var blocks: [Block] = []
        var seen = Set<String>()
        for (i, b) in raw.enumerated() {
            var id = (b["id"] as? String) ?? "b\(i + 1)"
            if id.isEmpty || seen.contains(id) { id = "b\(i + 1)_\(i)" }
            seen.insert(id)

            let emoji = (b["emoji"] as? String) ?? ""
            let name = (b["name"] as? String) ?? "?"
            let kind: Block.Kind = {
                if let k = b["kind"] as? String, let kk = Block.Kind(rawValue: k.lowercased()) { return kk }
                let probe = emoji + name
                if probe.hasPrefix("🎁") { return .treat }
                if probe.hasPrefix("☕") { return .rest }
                if probe.hasPrefix("🍚") { return .meal }
                if probe.hasPrefix("📌") { return .fixed }
                return .work
            }()

            var brains = kind == .work ? 1 : 0
            if let n = b["brains"] as? Int {
                brains = n
            } else if let n = b["brains"] as? Double {
                brains = Int(n)
            } else if let s = b["brains"] as? String {
                let icons = s.components(separatedBy: "🧠").count - 1
                brains = icons > 0 ? icons : (Int(s) ?? brains)
            }
            brains = kind == .work ? min(max(brains, 1), 3) : 0

            var minutes = 0
            if let n = b["minutes"] as? Int { minutes = n } else if let n = b["minutes"] as? Double { minutes = Int(n) }

            blocks.append(Block(
                id: id,
                start: (b["start"] as? String) ?? "",
                minutes: minutes,
                kind: kind,
                emoji: emoji,
                name: name,
                brains: brains,
                act: (b["act"] as? String) ?? "",
                planDone: (b["done"] as? Bool) ?? false
            ))
        }

        // A block without a length runs until the next block starts.
        for i in blocks.indices where blocks[i].minutes <= 0 {
            var m = 25
            if i + 1 < blocks.count,
               let a = minutesOfDay(blocks[i].start), let n = minutesOfDay(blocks[i + 1].start) {
                let d = (n - a + 1440) % 1440
                if d > 0 && d <= 240 { m = d }
            }
            blocks[i].minutes = m
        }

        return Plan(
            date: (obj["date"] as? String) ?? dayFormatter.string(from: Date()),
            lang: obj["lang"] as? String,
            title: (obj["title"] as? String) ?? "",
            finish: (obj["finish"] as? String) ?? "",
            blocks: blocks,
            buried: (obj["buried"] as? [String]) ?? [],
            signature: fnv1a(data)
        )
    }
}

// MARK: - Progress (owned by the pet)

struct PetState {
    var date = ""
    var signature = ""
    var earned: [String: Int] = [:]   // block id -> brains earned so far
    var done: [String] = []           // block ids that are finished
    var queue: [String] = []          // remaining block ids, in eating order
    var startedAt: Double? = nil      // when queue.first started (epoch seconds)
    var extraMin = 0
    var finished = false
}

// MARK: - Config (the user may edit ~/.zombie/config.json)

struct Config {
    var lang: String? = nil
    var watch = true          // drift reminders, judged on this Mac only
    var aiWatch = false       // periodic screenshot to Claude
    var aiEveryMin = 5
    var nagAfterSec = 60
    var sound = true
    var mini = false
    var scale = 1.0           // 2 = large mode, for screen recordings
    var x: Double? = nil
    var y: Double? = nil
    var claudePath: String? = nil
    var sites = Config.defaultSites
    var apps = Config.defaultApps

    static let defaultSites = [
        "youtube.com", "bilibili.com", "netflix.com", "twitch.tv", "tiktok.com", "douyin.com",
        "twitter.com", "x.com", "weibo.com", "xiaohongshu.com", "instagram.com", "facebook.com",
        "reddit.com", "zhihu.com", "douban.com", "iqiyi.com", "v.qq.com", "youku.com",
        "taobao.com", "jd.com", "steampowered.com",
    ]
    static let defaultApps = [
        "Steam", "哔哩哔哩", "bilibili", "抖音", "小红书", "微博", "Netflix", "com.apple.TV",
        "爱奇艺", "腾讯视频", "优酷", "Epic Games",
    ]

    static func load() -> Config {
        var c = Config()
        guard let data = try? Data(contentsOf: Paths.config),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return c }
        c.lang = o["lang"] as? String
        c.watch = o["watch"] as? Bool ?? c.watch
        c.aiWatch = o["aiWatch"] as? Bool ?? c.aiWatch
        c.aiEveryMin = max(1, o["aiEveryMin"] as? Int ?? c.aiEveryMin)
        c.nagAfterSec = max(10, o["nagAfterSec"] as? Int ?? c.nagAfterSec)
        c.sound = o["sound"] as? Bool ?? c.sound
        c.mini = o["mini"] as? Bool ?? c.mini
        c.scale = min(max(o["scale"] as? Double ?? c.scale, 1), 3)
        c.x = o["x"] as? Double
        c.y = o["y"] as? Double
        c.claudePath = o["claudePath"] as? String
        c.sites = o["sites"] as? [String] ?? c.sites
        c.apps = o["apps"] as? [String] ?? c.apps
        return c
    }

    func save() {
        var o: [String: Any] = [
            "watch": watch, "aiWatch": aiWatch, "aiEveryMin": aiEveryMin, "nagAfterSec": nagAfterSec,
            "sound": sound, "mini": mini, "scale": scale, "sites": sites, "apps": apps,
        ]
        if let lang { o["lang"] = lang }
        if let x { o["x"] = x }
        if let y { o["y"] = y }
        if let claudePath { o["claudePath"] = claudePath }
        if let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Paths.config, options: .atomic)
        }
    }
}
