import AppKit

final class ClosureItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

// MARK: - Today's plan, as text

func planText(_ engine: Engine) -> NSAttributedString {
    let out = NSMutableAttributedString()
    guard let plan = engine.plan else { return out }
    let ink = NSColor.labelColor
    func add(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = ink) {
        out.append(NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]))
    }

    add((plan.title.isEmpty ? L.t("🧟 僵尸的一天", "🧟 A Day as a Zombie") : "🧟 " + plan.title) + "\n", size: 16, weight: .bold)
    add(engine.progressBar() + " · " + engine.rankText() + "\n", size: 12, color: .secondaryLabelColor)

    var lastAct: String? = nil
    let currentID = engine.isFinished ? nil : engine.current?.id
    for b in plan.blocks {
        if b.act != lastAct {
            lastAct = b.act
            add("\n")
            if !b.act.isEmpty { add(b.act + "\n", size: 13, weight: .bold) }
        }
        let mark = engine.isDone(b.id) ? "✅" : (b.id == currentID ? "👉" : "▫️")
        let brains = String(repeating: "🧠", count: b.brains)
        let dim = engine.isDone(b.id) ? NSColor.secondaryLabelColor : ink
        add("\(mark)  \(b.start)  \(b.label)  \(brains)\n", weight: b.id == currentID ? .semibold : .regular, color: dim)
    }
    if !plan.buried.isEmpty {
        add("\n" + L.t("🪦 无法完成的部分", "🪦 Won't fit today") + "\n", size: 13, weight: .bold)
        for line in plan.buried { add("- " + line + "\n", color: .secondaryLabelColor) }
    }
    return out
}

final class PlanWindow {
    let window: NSWindow
    private let textView: NSTextView

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .floating
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        window.contentView = scroll
    }

    func show(_ text: NSAttributedString) {
        textView.textStorage?.setAttributedString(text)
        window.title = L.t("今日计划", "Today's plan")
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshIfVisible(_ text: @autoclosure () -> NSAttributedString) {
        if window.isVisible { textView.textStorage?.setAttributedString(text()) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = Engine()
    let brain = Brain()
    var panel: PetPanel!
    var petView: PetView!
    var statusItem: NSStatusItem!
    var supervisor: Supervisor!
    var planWindow: PlanWindow?
    var timer: Timer?
    private var lastPlanKey = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: Paths.dir, withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: Paths.log.path))?[.size] as? Int, size > 300_000 {
            try? FileManager.default.removeItem(at: Paths.log)
        }
        engine.loadAll()
        buildPanel()
        buildStatusItem()

        engine.onChange = { [weak self] in self?.refresh() }
        engine.onPoke = { [weak self] p in self?.poke(p) }
        supervisor = Supervisor(engine: engine)
        supervisor.start()

        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        engine.tick()
        petView.zombie.hop()
        zlog("pet started")

        // Self-test hook: ZOMBIE_DEBUG_CLICK=3 presses the bubble's first button after 3 seconds.
        if let s = ProcessInfo.processInfo.environment["ZOMBIE_DEBUG_CLICK"], let delay = Double(s) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.debugClick() }
        }
    }

    private func debugClick() {
        guard let button = petView.bubble.subviews.compactMap({ $0 as? PillButton }).first else {
            zlog("debug click: no button on screen")
            return
        }
        let p = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) {
                panel.sendEvent(e)
            }
        }
        zlog("debug click: pressed '\(button.title)' (window visible=\(panel.isVisible), opaque=\(panel.isOpaque), frame=\(panel.frame))")
    }

    private func buildPanel() {
        UI.z = CGFloat(engine.config.scale)
        let size = PetView.scaledSize
        panel = PetPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        petView = PetView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = petView
        petView.bubble.onAction = { [weak self] a in self?.handle(a) }
        petView.zombie.onClick = { [weak self] in self?.zombieClicked() }
        petView.zombie.onMenu = { [weak self] e in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.buildMenu(), with: e, for: self.petView.zombie)
        }
        petView.zombie.onDragEnd = { [weak self] in
            guard let self else { return }
            // Saved as the normal-size window's origin, so the zombie keeps its spot at any size.
            self.engine.config.x = Double(self.panel.frame.maxX - PetView.size.width)
            self.engine.config.y = Double(self.panel.frame.origin.y)
            self.engine.config.save()
        }

        var origin: NSPoint
        if let x = engine.config.x, let y = engine.config.y,
           NSScreen.screens.contains(where: { $0.frame.intersects(NSRect(x: x + PetView.size.width - 100, y: y, width: 100, height: 100)) }) {
            origin = NSPoint(x: x + PetView.size.width - size.width, y: y)
        } else {
            let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            origin = NSPoint(x: vf.maxX - size.width - 16, y: vf.minY + 12)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🧟"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        for item in buildMenu().items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let e = engine
        let hasPlan = e.plan != nil

        let head = NSMenuItem(
            title: hasPlan ? e.progressBar() + " · " + e.rankText() : L.t("今天还没有计划", "No plan for today yet"),
            action: nil, keyEquivalent: ""
        )
        head.isEnabled = false
        m.addItem(head)
        m.addItem(ClosureItem(L.t("📋 今日计划", "📋 Today's plan"), enabled: hasPlan) { [weak self] in self?.showPlan() })
        m.addItem(.separator())

        m.addItem(ClosureItem(L.t("👀 让大脑看一眼屏幕", "👀 Have the brain look at my screen")) { [weak self] in self?.look(auto: false) })
        m.addItem(ClosureItem(L.t("分心提醒(只在本机判断)", "Drift reminders (judged on this Mac)"), checked: e.config.watch) { [weak self] in
            guard let self else { return }
            self.engine.config.watch.toggle()
            self.engine.config.save()
        })
        let n = e.config.aiEveryMin
        m.addItem(ClosureItem(
            L.t("AI 监督:每 \(n) 分钟截屏给 Claude 看一眼", "AI watch: send Claude a screenshot every \(n) min"),
            checked: e.config.aiWatch
        ) { [weak self] in self?.toggleAIWatch() })
        m.addItem(.separator())

        if e.isFinished && e.hasLeftovers {
            m.addItem(ClosureItem(L.t("🧟 挖出来继续", "🧟 Dig back in")) { [weak self] in self?.engine.resume() })
        } else {
            m.addItem(ClosureItem(L.t("⚰️ 收工", "⚰️ Wrap up"), enabled: hasPlan && !e.isFinished) { [weak self] in self?.engine.wrapUp() })
        }
        m.addItem(ClosureItem(L.t("小气泡模式", "Compact bubble"), checked: e.config.mini) { [weak self] in self?.toggleMini() })
        m.addItem(ClosureItem(L.t("大号模式(录屏用)", "Large size (for recordings)"), checked: e.config.scale > 1) { [weak self] in self?.toggleLarge() })
        m.addItem(ClosureItem(L.t("提示音", "Sounds"), checked: e.config.sound) { [weak self] in
            guard let self else { return }
            self.engine.config.sound.toggle()
            self.engine.config.save()
        })

        let langItem = NSMenuItem(title: L.t("语言", "Language"), action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        langMenu.autoenablesItems = false
        langMenu.addItem(ClosureItem("中文", checked: L.zh) { [weak self] in self?.setLang("zh") })
        langMenu.addItem(ClosureItem("English", checked: !L.zh) { [weak self] in self?.setLang("en") })
        langItem.submenu = langMenu
        m.addItem(langItem)

        m.addItem(.separator())
        m.addItem(ClosureItem(L.t("退出", "Quit")) { NSApp.terminate(nil) })
        return m
    }

    // MARK: Events

    private func tick() {
        engine.tick()
        guard engine.config.aiWatch, !brain.busy, engine.wantsWatching else { return }
        let every = Double(engine.config.aiEveryMin) * 60
        let blockStart = engine.state.startedAt.map { Date(timeIntervalSince1970: $0) } ?? Date()
        if Date().timeIntervalSince(max(engine.lastAILook, blockStart)) >= every { look(auto: true) }
    }

    private func refresh() {
        let m = engine.bubble()
        petView.layoutPet(model: m, mini: engine.config.mini && !m.attention)
        let parts: [String] = [
            engine.state.signature,
            engine.state.done.joined(separator: ","),
            engine.current?.id ?? "",
            engine.isFinished ? "finished" : "",
        ]
        let key = parts.joined(separator: "|")
        if key != lastPlanKey {
            lastPlanKey = key
            planWindow?.refreshIfVisible(planText(engine))
        }
    }

    private func play(_ name: String) {
        if engine.config.sound { NSSound(named: NSSound.Name(name))?.play() }
    }

    private func poke(_ p: Poke) {
        switch p {
        case .attention:
            petView.zombie.hop()
            play("Glass")
        case .nag:
            petView.zombie.shake()
            play("Purr")
        case .happy(let n):
            petView.zombie.hop()
            petView.floatBrain(n)
            play("Pop")
        case .hello:
            petView.zombie.hop()
        }
    }

    private func handle(_ a: Action) {
        if case .openScreenSettings = a,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        engine.perform(a)
    }

    private func zombieClicked() {
        if engine.asleep {
            engine.wake()
        } else {
            toggleMini()
        }
    }

    private func toggleMini() {
        engine.config.mini.toggle()
        engine.config.save()
        refresh()
    }

    private func toggleLarge() {
        engine.config.scale = engine.config.scale > 1 ? 1 : 2
        engine.config.save()
        panel.orderOut(nil)
        buildPanel()
        refresh()
    }

    private func setLang(_ code: String) {
        engine.config.lang = code
        engine.config.save()
        engine.applyLanguage()
        refresh()
    }

    private func showPlan() {
        if planWindow == nil { planWindow = PlanWindow() }
        planWindow?.show(planText(engine))
    }

    // MARK: The AI look

    private func toggleAIWatch() {
        engine.config.aiWatch.toggle()
        engine.config.save()
        guard engine.config.aiWatch else { return }
        if Brain.cliPath(engine.config) == nil {
            aiFailed(.noCLI, auto: true)
        } else if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            aiFailed(.noScreenAccess, auto: true)
        }
    }

    private func look(auto: Bool) {
        guard !brain.busy else { return }
        guard let (block, mins) = engine.currentWork() else {
            if !auto {
                engine.show(.info(
                    L.t("🧟 现在没有猎物", "🧟 No prey right now"),
                    L.t("正在吃某一块的时候,再叫大脑来看", "Ask the brain while a block is in progress"),
                    []
                ), seconds: 8)
            }
            return
        }
        guard let cli = Brain.cliPath(engine.config) else {
            aiFailed(.noCLI, auto: auto)
            return
        }
        engine.lastAILook = Date()
        if !auto { engine.show(.looking) }
        brain.look(cli: cli, block: block, minutesLeft: mins) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let v):
                self.engine.aiVerdict(onTask: v.onTask, say: v.say, auto: auto)
            case .failure(let f):
                self.aiFailed(f, auto: auto)
            }
        }
    }

    private func aiFailed(_ f: Brain.Failure, auto: Bool) {
        if auto && engine.config.aiWatch {
            engine.config.aiWatch = false   // don't keep retrying something the user has to fix
            engine.config.save()
        }
        switch f {
        case .noCLI:
            engine.show(.info(
                L.t("🧠 找不到 claude 命令行", "🧠 Can't find the claude command"),
                L.t("看屏幕要用 Claude Code 命令行。装好以后再点我", "The screen look needs the Claude Code CLI. Install it, then ask again"),
                []
            ))
        case .notLoggedIn:
            engine.show(.info(
                L.t("🧠 大脑还没登录", "🧠 The brain isn't signed in"),
                L.t("打开终端运行 claude,输入 /login,登录后再点我", "Open Terminal, run claude, type /login, then ask again"),
                []
            ))
        case .noScreenAccess:
            engine.show(.info(
                L.t("👀 需要「屏幕录制」权限", "👀 Screen Recording permission needed"),
                L.t("系统设置 → 隐私与安全性 → 屏幕录制,打开 ZombiePet,然后重开我", "System Settings → Privacy & Security → Screen Recording: turn on ZombiePet, then reopen me"),
                [(L.t("打开设置", "Open Settings"), .openScreenSettings)]
            ))
        case .failed(let why):
            zlog("ai look failed: \(why)")
            engine.show(.info(
                L.t("🧠 大脑短路了", "🧠 The brain shorted out"),
                L.t("这次没看成,等会儿再试", "That look didn't work. Try again in a bit"),
                []
            ), seconds: 12)
        }
    }
}

// MARK: - Snapshot mode (renders every bubble state to one PNG, for checking the look and the logic)

func runSnapshot(outPath: String, start: Date, stubCLI: String?) {
    var t = start
    let engine = Engine()
    engine.now = { t }
    engine.loadAll()

    // At scale 2 with 1 pixel per point the picture should match scale 1 at 2 pixels per point.
    let size = PetView.scaledSize
    let density = 2 / UI.z
    let view = PetView(frame: NSRect(origin: .zero, size: size))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView = view

    var cells: [(String, NSBitmapImageRep)] = []
    func shot(_ name: String, mini: Bool = false, dark: Bool = false) {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let m = engine.bubble()
        view.layoutPet(model: m, mini: mini && !m.attention)
        view.layoutSubtreeIfNeeded()
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * density), pixelsHigh: Int(size.height * density),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        cells.append((name, rep))
        let buttons = m.buttons.map { $0.0 }.joined(separator: " / ")
        print("[\(cells.count) \(name)] \(m.badge) | \(m.title) | \(m.subtitle.replacingOccurrences(of: "\n", with: " ⏎ ")) | [\(buttons)] | pill=\(m.pill)\(m.hidden ? " | HIDDEN" : "")")
    }
    func advance(_ seconds: Double) {
        t = t.addingTimeInterval(seconds)
        engine.tick()
    }

    engine.tick()
    shot("waiting")
    advance(5 * 60)
    shot("working")
    shot("compact", mini: true)
    engine.perform(.ate)
    shot("celebrate")
    advance(4)
    shot("next block")
    advance(16 * 60)
    shot("overtime")
    engine.perform(.more10)
    advance(1)
    shot("10 more min")
    engine.perform(.ate)
    advance(4)
    shot("heavy block", dark: true)
    engine.perform(.stuck)
    shot("stuck")
    engine.perform(.startBite)
    advance(30)
    shot("bite running")
    advance(5 * 60)
    shot("bite done")
    engine.perform(.keepEating)
    for _ in 0..<14 {
        t = t.addingTimeInterval(5)
        engine.reportFront(key: "site:youtube.com")
    }
    shot("drift nag")
    engine.reportFront(key: nil)
    shot("came back")
    engine.aiVerdict(onTask: true, say: L.t("去 Overleaf,把第 2 节第一段写完", "Go to Overleaf and finish the first paragraph of section 2"), auto: false)
    shot("ai hint")
    engine.perform(.ok)
    engine.perform(.ate)
    advance(4)
    shot("treat")
    advance(11 * 60)
    shot("treat over")
    engine.perform(.restDone)
    advance(1)
    shot("after treat")
    engine.perform(.ate)
    advance(4)
    shot("then")
    advance(100 * 60)
    shot("100 min later")
    engine.wrapUp()
    shot("report", dark: true)
    engine.perform(.goodnight)
    shot("asleep")

    // Compose one contact sheet.
    let cols = 4
    let rows = Int(ceil(Double(cells.count) / Double(cols)))
    let labelH: CGFloat = 22
    let cellW = size.width, cellH = size.height + labelH
    let sheetSize = NSSize(width: cellW * CGFloat(cols), height: cellH * CGFloat(rows))
    let sheet = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(sheetSize.width * density), pixelsHigh: Int(sheetSize.height * density),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    sheet.size = sheetSize
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
    for (i, cell) in cells.enumerated() {
        let col = i % cols, row = i / cols
        let origin = NSPoint(x: CGFloat(col) * cellW, y: sheetSize.height - CGFloat(row + 1) * cellH)
        let bg = (col + row) % 2 == 0
            ? NSColor(srgbRed: 0.36, green: 0.52, blue: 0.66, alpha: 1)
            : NSColor(srgbRed: 0.22, green: 0.26, blue: 0.33, alpha: 1)
        bg.setFill()
        NSRect(x: origin.x, y: origin.y, width: cellW, height: cellH).fill()
        cell.1.draw(
            in: NSRect(x: origin.x, y: origin.y, width: size.width, height: size.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil
        )
        ("\(i + 1). \(cell.0)" as NSString).draw(
            at: NSPoint(x: origin.x + 8, y: origin.y + size.height + 3),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
        )
    }
    NSGraphicsContext.restoreGraphicsState()
    if let png = sheet.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: outPath))
        print("sheet: \(outPath)")
    }

    // Parsing of the CLI's answers, and the round trip through a stand-in CLI if one is given.
    func describe(_ r: Result<Brain.Verdict, Brain.Failure>) -> String {
        switch r {
        case .success(let v): return "ok on_task=\(v.onTask) say=\(v.say)"
        case .failure(let f): return "failure \(f)"
        }
    }
    print("parse not-logged-in: " + describe(Brain.parse(#"{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}"#)))
    print("parse fenced: " + describe(Brain.parse(#"{"type":"result","is_error":false,"result":"```json\n{\"on_task\": false, \"say\": \"先切回 Overleaf\"}\n```"}"#)))
    print("parse garbage: " + describe(Brain.parse("zsh: command not found")))
    if let stubCLI {
        let p = Brain.prompt(block: engine.plan!.blocks[2], minutesLeft: 30, shotPath: Paths.shot.path)
        print("stub cli: " + describe(Brain().ask(cli: stubCLI, system: p.system, user: p.user)))
    }
    print("site match: \(Supervisor.matchSite("www.youtube.com", Config.defaultSites) ?? "nil"), \(Supervisor.matchSite("box.com", Config.defaultSites) ?? "nil"), \(Supervisor.matchSite("x.com", Config.defaultSites) ?? "nil")")
}

// MARK: - Entry point

let arguments = CommandLine.arguments
let app = NSApplication.shared

if let i = arguments.firstIndex(of: "--scale"), i + 1 < arguments.count, let z = Double(arguments[i + 1]) {
    UI.z = CGFloat(z)
}

if let i = arguments.firstIndex(of: "--snapshot"), i + 2 < arguments.count {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    let stub = arguments.firstIndex(of: "--stub-cli").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    runSnapshot(outPath: arguments[i + 1], start: f.date(from: arguments[i + 2]) ?? Date(), stubCLI: stub)
    exit(0)
}

if let i = arguments.firstIndex(of: "--film"), i + 2 < arguments.count {
    runFilm(scriptPath: arguments[i + 1], outDir: arguments[i + 2])
    exit(0)
}

if let me = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: me).count > 1 {
    exit(0)   // one zombie is enough
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
