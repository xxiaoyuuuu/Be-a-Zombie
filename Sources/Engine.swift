import Foundation

enum Action {
    case ate, stuck, more10, startBite, swap, keepEating, shelve, restDone, startNow
    case snooze, allow, ok, goodnight, openScreenSettings
}

enum Mood { case sleep, wait, work, rest, alert, happy }

enum Poke { case attention, nag, happy(Int), hello }

struct BubbleModel {
    var title = ""
    var subtitle = ""
    var buttons: [(String, Action)] = []
    var dismissible = false
    var attention = false   // show the full bubble even in compact mode
    var hidden = false
    var mood: Mood = .sleep
    var badge = ""
    var pill = ""
}

enum Overlay {
    case none
    case celebrate(Int, String)
    case stuck
    case biteDone
    case nag(String?)       // nil = spotted on this Mac; text = what the AI said
    case hint(String)
    case looking
    case info(String, String, [(String, Action)])
}

enum Phase {
    case noPlan, done
    case waiting(Block, Date)
    case working(Block, Date)
    case overtime(Block)
    case resting(Block, Date)
    case restOver(Block)

    var key: String {
        switch self {
        case .noPlan: return "noPlan"
        case .done: return "done"
        case .waiting(let b, _): return "waiting:" + b.id
        case .working(let b, _): return "working:" + b.id
        case .overtime(let b): return "overtime:" + b.id
        case .resting(let b, _): return "resting:" + b.id
        case .restOver(let b): return "restOver:" + b.id
        }
    }
}

/// The zombie's day: which block is current, how long is left, what the bubble says.
final class Engine {
    var now: () -> Date = { Date() }
    var onChange: () -> Void = {}
    var onPoke: (Poke) -> Void = { _ in }

    private(set) var plan: Plan?
    private(set) var state = PetState()
    var config = Config()
    private(set) var overlay: Overlay = .none
    private(set) var biteUntil: Date?
    private(set) var asleep = false
    var lastAILook = Date.distantPast
    var nextCheer: String?      // film mode: what the next celebration says, instead of a random cheer

    private var overlayUntil: Date?
    private var planMTime: Date?
    private var configMTime: Date?
    private var lastPhaseKey = ""
    private var lastPokeAt = Date.distantPast
    private var distractedSince: Date?
    private var distractionKey: String?
    private var nagSnoozeUntil = Date.distantPast
    private var nagCooldownUntil = Date.distantPast
    private var allowed = Set<String>()

    // MARK: Loading and saving

    func loadAll() {
        config = Config.load()
        configMTime = mtime(Paths.config)
        loadState()
        reloadPlanIfChanged(force: true)
        applyLanguage()
    }

    private func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func applyLanguage() {
        let system = (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? "zh" : "en"
        L.zh = (config.lang ?? plan?.lang ?? system).hasPrefix("zh")
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: Paths.state),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        var s = PetState()
        s.date = o["date"] as? String ?? ""
        s.signature = o["signature"] as? String ?? ""
        if let e = o["earned"] as? [String: Any] {
            for (k, v) in e { if let n = v as? Int { s.earned[k] = n } }
        }
        s.done = o["done"] as? [String] ?? []
        s.queue = o["queue"] as? [String] ?? []
        s.startedAt = o["startedAt"] as? Double
        s.extraMin = o["extraMin"] as? Int ?? 0
        s.finished = o["finished"] as? Bool ?? false
        state = s
    }

    func save() {
        var o: [String: Any] = [
            "date": state.date,
            "signature": state.signature,
            "earned": state.earned,
            "done": state.done,
            "queue": state.queue,
            "extraMin": state.extraMin,
            "finished": state.finished,
            "updated": ISO8601DateFormatter().string(from: now()),
            // Readable copies for the skill, which reads this file before replanning.
            "brains_eaten": eatenBrains,
            "brains_total": totalBrains,
            "current": current?.label ?? "",
            "done_names": state.done.compactMap { block($0)?.label },
        ]
        if let s = state.startedAt { o["startedAt"] = s }
        if let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Paths.state, options: .atomic)
        }
    }

    private func reloadPlanIfChanged(force: Bool = false) {
        let m = mtime(Paths.plan)
        if !force && m == planMTime { return }
        let firstLoad = planMTime == nil && force
        planMTime = m

        guard m != nil, let p = Plan.load(from: Paths.plan), p.isFor(now()) else {
            plan = nil
            return
        }
        if state.date != p.date {
            state = PetState()
            state.date = p.date
        }
        plan = p
        if state.signature != p.signature {
            let ids = Set(p.blocks.map { $0.id })
            var doneSet = Set(state.done).intersection(ids)
            for b in p.blocks where b.planDone {
                doneSet.insert(b.id)
                if b.kind == .work && state.earned[b.id] == nil { state.earned[b.id] = b.brains }
            }
            let oldCurrent = state.queue.first
            state.done = p.blocks.map { $0.id }.filter { doneSet.contains($0) }
            state.earned = state.earned.filter { ids.contains($0.key) }
            state.queue = p.blocks.map { $0.id }.filter { !doneSet.contains($0) }
            if state.queue.first != oldCurrent {
                state.startedAt = nil
                state.extraMin = 0
                biteUntil = nil
                allowed = []
            }
            state.signature = p.signature
            state.finished = false
            asleep = false
            overlay = .none
            overlayUntil = nil
            if !firstLoad { poke(.hello) }
            zlog("plan loaded: \(p.blocks.count) blocks, \(state.queue.count) left")
        }
        applyLanguage()
        save()
    }

    // MARK: Lookups

    func block(_ id: String) -> Block? { plan?.blocks.first { $0.id == id } }
    var current: Block? { state.queue.first.flatMap { block($0) } }
    var nextUp: Block? { state.queue.count > 1 ? block(state.queue[1]) : nil }
    var totalBrains: Int { plan?.blocks.filter { $0.kind == .work }.reduce(0) { $0 + $1.brains } ?? 0 }
    var eatenBrains: Int { min(state.earned.values.reduce(0, +), max(totalBrains, 0)) }
    var isFinished: Bool { state.finished }
    var hasLeftovers: Bool { !state.queue.isEmpty }
    func isDone(_ id: String) -> Bool { state.done.contains(id) }

    func rankText() -> String {
        let total = totalBrains
        let r = total > 0 ? Double(eatenBrains) / Double(total) : 0
        if r > 0.9 { return L.t("👑 僵尸王", "👑 Zombie Royalty") }
        if r >= 0.6 { return L.t("😎 精英僵尸", "😎 Elite Zombie") }
        if r >= 0.3 { return L.t("💨 走路带风", "💨 Shambling with Swagger") }
        return L.t("🌱 刚出土", "🌱 Freshly Risen")
    }

    func progressBar() -> String {
        let total = totalBrains, eaten = eatenBrains
        guard total > 0 else { return "" }
        let cells = min(total, 8)
        var filled = eaten
        if total > cells {
            // Scaled bar: never empty once something is eaten, never full until everything is.
            filled = Int((Double(eaten) / Double(total) * Double(cells)).rounded())
            if eaten > 0 { filled = max(filled, 1) }
            if eaten < total { filled = min(filled, cells - 1) }
        }
        return String(repeating: "🧠", count: filled) + String(repeating: "⚪", count: cells - filled) + " \(eaten)/\(total)"
    }

    private func plannedStart(_ b: Block) -> Date? {
        guard let p = plan, let day = dayFormatter.date(from: p.date), let m = minutesOfDay(b.start) else { return nil }
        var d = day.addingTimeInterval(Double(m) * 60)
        if let first = p.blocks.first, let fm = minutesOfDay(first.start), m < fm - 60 {
            d = d.addingTimeInterval(86400)   // the plan runs past midnight
        }
        return d
    }

    /// Only the first block of the day and fixed commitments wait for the clock.
    private func waitsForClock(_ b: Block) -> Date? {
        guard b.kind == .fixed || state.done.isEmpty, let ps = plannedStart(b), now() < ps else { return nil }
        return ps
    }

    func phase() -> Phase {
        guard plan != nil else { return .noPlan }
        guard !state.finished, let cur = current else { return .done }
        let t = now()
        guard let s = state.startedAt else {
            if let at = waitsForClock(cur) { return .waiting(cur, at) }
            let d = t.addingTimeInterval(Double(cur.minutes) * 60)
            return cur.isRest ? .resting(cur, d) : .working(cur, d)
        }
        let deadline = Date(timeIntervalSince1970: s).addingTimeInterval(Double(cur.minutes + state.extraMin) * 60)
        if cur.isRest { return t < deadline ? .resting(cur, deadline) : .restOver(cur) }
        return t < deadline ? .working(cur, deadline) : .overtime(cur)
    }

    /// The work block being eaten right now and the minutes left on it, if any.
    func currentWork() -> (Block, Int)? {
        switch phase() {
        case .working(let b, let d) where b.kind == .work:
            return (b, max(1, Int(ceil(d.timeIntervalSince(now()) / 60))))
        case .overtime(let b) where b.kind == .work:
            return (b, 0)
        default:
            return nil
        }
    }

    var wantsWatching: Bool {
        guard !asleep, now() >= nagSnoozeUntil else { return false }
        return currentWork() != nil
    }

    // MARK: Clock

    func tick() {
        if let m = mtime(Paths.config), m != configMTime {
            configMTime = m
            config = Config.load()
            applyLanguage()
        }
        reloadPlanIfChanged()
        let t = now()
        if let p = plan, !p.isFor(t) { plan = nil }

        if let u = overlayUntil, t >= u {
            overlay = .none
            overlayUntil = nil
        }
        if let b = biteUntil, t >= b {
            biteUntil = nil
            if let cur = current, cur.kind == .work {
                state.earned[cur.id] = max(state.earned[cur.id] ?? 0, 1)
            }
            overlay = .biteDone
            overlayUntil = nil
            save()
            poke(.attention)
        }
        if plan != nil, !state.finished, state.startedAt == nil, let cur = current {
            var celebrating = false
            if case .celebrate = overlay { celebrating = true }
            if !celebrating && waitsForClock(cur) == nil {
                // A fixed commitment keeps its own clock even if the zombie shows up late.
                var begin = t
                if cur.kind == .fixed, let ps = plannedStart(cur), ps <= t { begin = ps }
                state.startedAt = begin.timeIntervalSince1970
                state.extraMin = 0
                save()
            }
        }

        let ph = phase()
        if ph.key != lastPhaseKey {
            lastPhaseKey = ph.key
            switch ph {
            case .overtime, .restOver: poke(.attention)
            default: break
            }
        } else {
            switch ph {
            case .overtime, .restOver:
                if t.timeIntervalSince(lastPokeAt) >= 300 { poke(.attention) }
            default: break
            }
        }
        onChange()
    }

    private func poke(_ p: Poke) {
        lastPokeAt = now()
        onPoke(p)
    }

    // MARK: Buttons

    func perform(_ a: Action) {
        let t = now()
        switch a {
        case .ate:
            finishCurrent(eaten: true)
        case .restDone:
            finishCurrent(eaten: false)
        case .startNow:
            state.startedAt = t.timeIntervalSince1970
            state.extraMin = 0
        case .more10:
            if let s = state.startedAt, let cur = current {
                let elapsed = Int(ceil((t.timeIntervalSince1970 - s) / 60))
                state.extraMin = max(0, elapsed - cur.minutes) + 10
            }
            overlay = .none
        case .stuck:
            overlay = .stuck
            overlayUntil = nil
        case .startBite:
            biteUntil = t.addingTimeInterval(300)
            state.startedAt = t.timeIntervalSince1970
            state.extraMin = 0
            overlay = .none
        case .swap:
            if let i = softerIndex() {
                let id = state.queue.remove(at: i)
                state.queue.insert(id, at: 0)
                resetCurrentTimer()
            }
            overlay = .none
        case .keepEating:
            overlay = .none
        case .shelve:
            if state.queue.count > 1 {
                let id = state.queue.removeFirst()
                state.queue.append(id)
                resetCurrentTimer()
            }
            overlay = .none
        case .snooze:
            nagSnoozeUntil = t.addingTimeInterval(300)
            distractedSince = nil
            overlay = .none
        case .allow:
            if let k = distractionKey { allowed.insert(k) }
            distractedSince = nil
            overlay = .none
        case .ok:
            if case .nag = overlay { nagCooldownUntil = t.addingTimeInterval(120) }
            overlay = .none
        case .goodnight:
            asleep = true
            overlay = .none
        case .openScreenSettings:
            overlay = .none   // the app opens the Settings pane; nothing to change here
        }
        overlayUntilIfNone()
        save()
        onChange()
    }

    private func overlayUntilIfNone() {
        if case .none = overlay { overlayUntil = nil }
    }

    private func resetCurrentTimer() {
        state.startedAt = nil
        state.extraMin = 0
        biteUntil = nil
        allowed = []
        distractedSince = nil
    }

    private func softerIndex() -> Int? {
        guard let cur = current, cur.kind == .work else { return nil }
        let rest = state.queue.enumerated().dropFirst().compactMap { (i, id) -> (Int, Block)? in
            guard let b = block(id), b.kind == .work, b.brains < cur.brains else { return nil }
            return (i, b)
        }
        return (rest.first { $0.1.brains == 1 } ?? rest.first)?.0
    }

    private func finishCurrent(eaten: Bool) {
        guard let cur = current else { return }
        if cur.kind == .work && eaten { state.earned[cur.id] = cur.brains }
        state.done.append(cur.id)
        state.queue.removeFirst()
        resetCurrentTimer()
        if state.queue.isEmpty { state.finished = true }
        if cur.kind == .work && eaten {
            let cheers = L.zh
                ? ["嚼嚼嚼", "真香", "好吃!", "嗝~", "再来一个", "真好吃", "啊呜一口"]
                : ["Nom nom", "Delicious", "Crunchy!", "Burp", "More brains", "So tasty", "Chomp"]
            overlay = .celebrate(cur.brains, nextCheer ?? cheers.randomElement() ?? "")
            nextCheer = nil
            overlayUntil = now().addingTimeInterval(3)
            poke(.happy(cur.brains))
        } else {
            overlay = .none
        }
        zlog("finished \(cur.id) (\(eatenBrains)/\(totalBrains))")
    }

    func wrapUp() {
        state.finished = true
        asleep = false
        overlay = .none
        biteUntil = nil
        save()
        onChange()
    }

    func resume() {
        guard !state.queue.isEmpty else { return }
        state.finished = false
        asleep = false
        resetCurrentTimer()
        save()
        onChange()
    }

    func wake() {
        asleep = false
        onChange()
    }

    func show(_ o: Overlay, seconds: Double? = nil) {
        overlay = o
        overlayUntil = seconds.map { now().addingTimeInterval($0) }
        onChange()
    }

    // MARK: Watching

    /// Called every few seconds with what is in front: a key such as "site:youtube.com" when it
    /// matches the drift list, or nil when it doesn't.
    func reportFront(key: String?) {
        let t = now()
        guard config.watch, wantsWatching, let key, !allowed.contains(key) else {
            distractedSince = nil
            if case .nag(let text) = overlay, text == nil {
                overlay = .none
                nagCooldownUntil = t.addingTimeInterval(120)
                onChange()
            }
            return
        }
        if distractedSince == nil || distractionKey != key {
            distractedSince = t
            distractionKey = key
        }
        guard let since = distractedSince, t.timeIntervalSince(since) >= Double(config.nagAfterSec), t >= nagCooldownUntil else { return }
        if case .nag = overlay { return }
        overlay = .nag(nil)
        overlayUntil = nil
        zlog("drift: \(key)")
        poke(.nag)
        onChange()
    }

    func aiVerdict(onTask: Bool, say: String, auto: Bool) {
        if onTask {
            if case .looking = overlay { overlay = .none }
            if !auto {
                overlay = .hint(say)
                overlayUntil = now().addingTimeInterval(25)
                poke(.hello)
            }
        } else {
            overlay = .nag(say)
            overlayUntil = nil
            poke(.nag)
        }
        onChange()
    }

    // MARK: What the bubble says

    func bubble() -> BubbleModel {
        var m = BubbleModel()
        let t = now()

        switch phase() {
        case .noPlan:
            m.title = L.t("🧟 今天还没有计划", "🧟 No plan for today yet")
            m.subtitle = L.t("在 Claude 里说「僵尸模式」,再把今天要做的事丢过去", "Tell Claude “zombie mode” and dump today's tasks on it")
            m.mood = .sleep
            m.badge = "💤"
            m.pill = "💤"

        case .waiting(let b, let at):
            m.title = L.t("⏳ \(hhmm(at)) 开始", "⏳ Starts at \(hhmm(at))")
            m.subtitle = b.label
            m.buttons = [(L.t("现在就开始", "Start now"), .startNow)]
            m.mood = .wait
            m.badge = "⏳"
            m.pill = "⏳ \(hhmm(at))"

        case .working(let b, let deadline):
            let mins = max(1, Int(ceil(deadline.timeIntervalSince(t) / 60)))
            m.mood = .work
            m.pill = (b.emoji.isEmpty ? "👉" : b.emoji) + " \(mins)′"
            if b.kind == .fixed {
                m.title = b.label
                m.subtitle = L.t("到 \(hhmm(deadline)) · 还剩 \(mins) 分钟", "Until \(hhmm(deadline)) · \(mins) min left")
                m.buttons = [(L.t("结束了", "It's over"), .ate)]
                m.badge = "📌"
            } else if let bu = biteUntil {
                let s = max(0, Int(bu.timeIntervalSince(t)))
                m.title = L.t("🦷 只咬一口 · ", "🦷 Just one bite · ") + String(format: "%d:%02d", s / 60, s % 60)
                m.subtitle = b.label
                m.buttons = [(L.t("吃掉了 🧠", "Ate it 🧠"), .ate)]
                m.badge = "🦷"
                m.pill = "🦷 " + String(format: "%d:%02d", s / 60, s % 60)
            } else {
                m.title = "👉 " + b.label
                m.subtitle = L.t("还剩 \(mins) 分钟", "\(mins) min left") + " · " + String(repeating: "🧠", count: b.brains)
                m.buttons = [(L.t("吃掉了 🧠", "Ate it 🧠"), .ate), (L.t("卡住了", "Stuck"), .stuck)]
            }

        case .overtime(let b):
            m.mood = .alert
            m.badge = "⏰"
            m.pill = "⏰"
            m.attention = true
            m.subtitle = b.label
            if b.kind == .fixed {
                m.title = L.t("📌 结束了吗?", "📌 Is it over?")
                m.buttons = [(L.t("结束了", "It's over"), .ate), (L.t("再 10 分钟", "10 more min"), .more10)]
            } else {
                m.title = L.t("⏰ 时间到,吃掉了吗?", "⏰ Time's up. Eaten?")
                m.buttons = [(L.t("吃掉了 🧠", "Ate it 🧠"), .ate), (L.t("再 10 分钟", "10 more min"), .more10)]
            }

        case .resting(let b, let deadline):
            let mins = max(1, Int(ceil(deadline.timeIntervalSince(t) / 60)))
            m.title = b.label
            m.subtitle = L.t("休息中 · 还剩 \(mins) 分钟", "Break · \(mins) min left")
            m.buttons = [(L.t("休息完了", "Done resting"), .restDone)]
            m.mood = .rest
            m.badge = b.emoji.isEmpty ? "🎁" : b.emoji
            m.pill = (b.emoji.isEmpty ? "🎁" : b.emoji) + " \(mins)′"

        case .restOver:
            m.title = L.t("🔔 休息结束", "🔔 Break's over")
            if let n = nextUp {
                m.subtitle = L.t("👉 下一口:", "👉 Next bite: ") + n.label
                m.buttons = [(L.t("开吃", "Let's eat"), .restDone)]
            } else {
                m.subtitle = L.t("今天的猎物都吃完了", "Every bit of today's prey is eaten")
                m.buttons = [(L.t("收工", "Wrap up"), .restDone)]
            }
            m.mood = .alert
            m.badge = "🔔"
            m.pill = "🔔"
            m.attention = true

        case .done:
            if asleep {
                m.hidden = true
                m.mood = .sleep
                m.badge = "💤"
            } else {
                m.title = L.t("🪦 僵尸日报", "🪦 Zombie report")
                let hour = Calendar.current.component(.hour, from: t)
                let evening = hour >= 17 || hour < 5
                var lines = [
                    "🧠 \(eatenBrains)/\(totalBrains) → \(rankText())",
                    evening
                        ? L.t("🌙 收工,今晚剩下的时间都是你的", "🌙 Done. The rest of tonight is yours")
                        : L.t("🌤 收工,今天剩下的时间都是你的", "🌤 Done. The rest of today is yours"),
                ]
                if let left = state.queue.compactMap({ block($0) }).first(where: { $0.kind == .work }) {
                    lines.append(L.t("📅 明天先挖:", "📅 Dig up first tomorrow: ") + left.label)
                }
                m.subtitle = lines.joined(separator: "\n")
                m.buttons = [(L.t("晚安 💤", "Good night 💤"), .goodnight)]
                m.mood = .sleep
                m.badge = "🌙"
                m.pill = "🌙"
                m.attention = true
            }
        }

        switch overlay {
        case .none:
            break
        case .celebrate(let n, let cheer):
            m.title = "🧠 +\(n)!" + (L.zh ? "" : " ") + cheer
            m.subtitle = progressBar() + "\n" + rankText()
            m.buttons = []
            m.mood = .happy
            m.badge = "🧠"
            m.attention = true
            m.hidden = false
        case .stuck:
            m.title = L.t("🦷 只咬一口", "🦷 Just one bite")
            m.subtitle = L.t("定 5 分钟,只做开头。响了就停,照样算 🧠", "Five minutes on the very start. Stop when it rings; it still earns a 🧠")
            m.buttons = [(L.t("开始 5 分钟", "Start 5 min"), .startBite)]
            if softerIndex() != nil { m.buttons.append((L.t("换个软的", "Swap"), .swap)) }
            m.dismissible = true
            m.badge = "🦷"
            m.attention = true
        case .biteDone:
            m.title = L.t("⏰ 5 分钟到,算你咬了一口 🧠", "⏰ 5 min up. One 🧠 earned")
            m.subtitle = current?.label ?? ""
            m.buttons = [(L.t("接着吃", "Keep eating"), .keepEating)]
            if state.queue.count > 1 { m.buttons.append((L.t("先放着", "Shelve it"), .shelve)) }
            m.mood = .alert
            m.badge = "🦷"
            m.attention = true
        case .nag(let text):
            m.title = L.t("🧟 这个不是猎物哦", "🧟 That isn't prey")
            if let text {
                m.subtitle = text
                m.buttons = [(L.t("知道了", "Got it"), .ok), (L.t("歇 5 分钟", "Rest 5 min"), .snooze)]
            } else {
                m.subtitle = L.t("👉 回来:", "👉 Come back: ") + (current?.label ?? "")
                m.buttons = [(L.t("歇 5 分钟", "Rest 5 min"), .snooze), (L.t("这算猎物", "It's prey"), .allow)]
            }
            m.mood = .alert
            m.badge = "❗"
            m.attention = true
        case .hint(let text):
            m.title = L.t("🧠 大脑看了一眼", "🧠 The brain took a look")
            m.subtitle = text
            m.buttons = [(L.t("知道了", "Got it"), .ok)]
            m.badge = "👀"
            m.attention = true
        case .looking:
            m.title = L.t("👀 大脑正在看屏幕…", "👀 The brain is looking…")
            m.subtitle = ""
            m.buttons = []
            m.badge = "👀"
            m.attention = true
        case .info(let title, let sub, let buttons):
            m.title = title
            m.subtitle = sub
            m.buttons = buttons
            m.dismissible = true
            m.attention = true
            m.hidden = false
        }
        return m
    }
}
