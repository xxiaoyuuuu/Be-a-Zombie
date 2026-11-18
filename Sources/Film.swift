import AppKit

// MARK: - Film mode
//
// Renders the pet frame by frame, on a transparent background, while a script drives the clock and
// presses the buttons. It exists so promo footage can be made in any language without recording
// the screen.
//
//   ZOMBIE_HOME=<scratch folder> ZombiePet --scale 2 --film <script> <out dir>
//
// The script has one command per line; # starts a comment. Positions are in the pet window's own
// points, from its bottom-left corner.
//
//   clock 2026-11-17 16:45:30.4    set the clock
//   align 0.25                     let time run until the clock's fraction of a second is this
//   plan <file>                    put this plan in place, as the skill would
//   scene <name>                   frames from here on go to <out dir>/<name>/0001.png, 0002.png ...
//   play <seconds>                 let time run and render it, 30 frames a second
//   wait <seconds>                 let time run without rendering
//   cheer <words>                  what the next celebration says
//   press <n>                      press the bubble's n-th button (0 is the first) without showing it
//   cursor <x> <y> | cursor off    put the cursor somewhere, or hide it
//   point <n> <seconds>            the cursor glides to the n-th button over this long, rendered
//   click <n> <seconds>            the same, and it clicks; the click lands exactly when the time is up

private final class Film {
    let fps = 30.0
    let density: CGFloat = 2          // pixels per point, as on a Retina screen
    let engine = Engine()
    let view: PetView
    let window: NSWindow
    let size: NSSize
    let outDir: URL
    let scriptDir: URL

    var t = Date()
    var lastWholeSecond = -1
    var sceneDir: URL?
    var frame = 0
    var total = 0

    // What the real app animates with Core Animation, which an offscreen render does not capture.
    var hopAt: Date?
    var shakeAt: Date?
    var float: (n: Int, at: Date)?
    var idleMood: Mood?
    var idleAt = Date()

    var cursor: NSPoint?
    var pressed: Int?

    init(outDir: URL, scriptDir: URL) {
        self.outDir = outDir
        self.scriptDir = scriptDir
        size = PetView.scaledSize
        view = PetView(frame: NSRect(origin: .zero, size: size))
        window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        NSApp.appearance = NSAppearance(named: .aqua)

        engine.now = { [unowned self] in self.t }
        engine.onPoke = { [unowned self] p in
            switch p {
            case .attention, .hello:
                self.hopAt = self.t
            case .nag:
                self.shakeAt = self.t
            case .happy(let n):
                self.hopAt = self.t
                self.float = (n, self.t)
            }
        }
        view.bubble.onAction = { [unowned self] a in self.engine.perform(a) }
    }

    // MARK: Time

    private func tickIfNewSecond() {
        let whole = Int(floor(t.timeIntervalSince1970 + 1e-6))
        if whole != lastWholeSecond {
            lastWholeSecond = whole
            engine.tick()
        }
    }

    /// The app ticks once a second; so does the film, on the clock's whole seconds.
    func run(_ seconds: Double, render: Bool) {
        if render {
            for _ in 0..<Int((seconds * fps).rounded()) {
                renderFrame()
                t = t.addingTimeInterval(1 / fps)
                tickIfNewSecond()
            }
        } else {
            let end = t.addingTimeInterval(seconds)
            while end.timeIntervalSince(t) > 1e-6 {
                let fraction = t.timeIntervalSince1970 - floor(t.timeIntervalSince1970 + 1e-6)
                t = t.addingTimeInterval(min(end.timeIntervalSince(t), max(1 - fraction, 1e-3)))
                tickIfNewSecond()
            }
        }
    }

    // MARK: Buttons and cursor

    private var buttons: [PillButton] { view.bubble.subviews.compactMap { $0 as? PillButton } }

    private func layout() {
        let m = engine.bubble()
        view.layoutPet(model: m, mini: false)
        view.layoutSubtreeIfNeeded()
        if m.mood != idleMood {
            idleMood = m.mood
            idleAt = t
        }
    }

    func press(_ n: Int) {
        layout()
        guard n < buttons.count else { fail("press \(n): the bubble has \(buttons.count) buttons") }
        buttons[n].action()
    }

    /// The cursor eases onto the button; with `click`, it rests one frame, holds the button down
    /// for two, and lets go as the time runs out.
    func glide(to n: Int, seconds: Double, click: Bool) {
        layout()
        guard n < buttons.count else { fail("button \(n): the bubble has \(buttons.count) buttons") }
        let b = buttons[n]
        let c = view.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), from: b)
        let target = NSPoint(x: c.x + 5 * UI.z, y: c.y - 3 * UI.z)
        let from = cursor ?? NSPoint(x: target.x - 70 * UI.z, y: target.y - 50 * UI.z)
        let frames = Int((seconds * fps).rounded())
        let moving = max(click ? frames - 3 : frames, 1)
        for i in 0..<frames {
            let u = min(Double(i + 1) / Double(moving), 1)
            let e = 1 - pow(1 - u, 3)
            cursor = NSPoint(x: from.x + (target.x - from.x) * e, y: from.y + (target.y - from.y) * e)
            pressed = click && i >= frames - 2 ? n : nil
            renderFrame()
            t = t.addingTimeInterval(1 / fps)
            tickIfNewSecond()
        }
        pressed = nil
        if click { press(n) }
    }

    // MARK: Drawing

    private func zombieOffset() -> (CGFloat, CGFloat) {
        var dx: CGFloat = 0, dy: CGFloat = 0
        func swing(_ from: CGFloat, _ to: CGFloat, _ duration: Double) -> CGFloat {
            let cycle = (t.timeIntervalSince(idleAt) / duration).truncatingRemainder(dividingBy: 2)
            let u = CGFloat(cycle < 1 ? cycle : 2 - cycle)
            return from + (to - from) * u * u * (3 - 2 * u)
        }
        switch idleMood {
        case .some(.sleep), .none: break
        case .some(.rest), .some(.happy): dx = swing(-3, 3, 0.9)
        case .some(.alert): dy = swing(0, 5, 0.45)
        default: dy = swing(0, 2.5, 1.7)
        }
        func keyframes(_ values: [CGFloat], _ times: [Double], _ u: Double) -> CGFloat {
            for i in 1..<values.count where u <= times[i] {
                let f = CGFloat((u - times[i - 1]) / (times[i] - times[i - 1]))
                return values[i - 1] + (values[i] - values[i - 1]) * f
            }
            return values.last ?? 0
        }
        if let h = hopAt {
            let u = t.timeIntervalSince(h) / 0.6
            if u < 1 { dy = keyframes([0, 16, 0, 9, 0], [0, 0.3, 0.55, 0.78, 1], u) } else { hopAt = nil }
        }
        if let s = shakeAt {
            let u = t.timeIntervalSince(s) / 0.55
            let v: [CGFloat] = [0, -7, 7, -6, 6, -3, 3, 0]
            if u < 1 { dx = keyframes(v, (0..<v.count).map { Double($0) / Double(v.count - 1) }, u) } else { shakeAt = nil }
        }
        return (dx * UI.z, dy * UI.z)
    }

    func renderFrame() {
        guard let sceneDir else { fail("play before any scene") }
        layout()
        if let p = pressed, p < buttons.count { buttons[p].pressed = true }
        let (dx, dy) = zombieOffset()
        view.zombie.frame = view.zombie.frame.offsetBy(dx: dx, dy: dy)

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * density), pixelsHigh: Int(size.height * density),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let f = float {
            let p = CGFloat(t.timeIntervalSince(f.at) / 1.3)
            if p < 1 {
                let s = NSAttributedString(string: "🧠 +\(f.n)", attributes: [
                    .font: NSFont.systemFont(ofSize: 20 * UI.z, weight: .heavy),
                    .foregroundColor: Theme.accent,
                ])
                let r = UI.px(view.floatRect).offsetBy(dx: 0, dy: 44 * UI.z * p)
                let textSize = s.size()
                if let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.saveGState()
                    ctx.setAlpha(1 - p)
                    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                    s.draw(at: NSPoint(x: r.midX - textSize.width / 2, y: r.maxY - textSize.height))
                    ctx.endTransparencyLayer()
                    ctx.restoreGState()
                }
            } else {
                float = nil
            }
        }
        if let c = cursor {
            let arrow = NSCursor.arrow
            let image = arrow.image
            image.draw(
                in: NSRect(x: c.x - arrow.hotSpot.x, y: c.y + arrow.hotSpot.y - image.size.height,
                           width: image.size.width, height: image.size.height),
                from: .zero, operation: .sourceOver, fraction: 1
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        frame += 1
        total += 1
        let url = sceneDir.appendingPathComponent(String(format: "%04d.png", frame))
        guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil else {
            fail("could not write \(url.path)")
        }
    }

    // MARK: Script

    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(("film: " + message + "\n").data(using: .utf8)!)
        exit(1)
    }

    func command(_ line: String) {
        let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let name = words.first else { return }
        let rest = words.dropFirst().joined(separator: " ")
        func number(_ i: Int) -> Double {
            guard i < words.count, let v = Double(words[i]) else { fail("\(line): needs a number") }
            return v
        }
        switch name {
        case "clock":
            guard words.count >= 3 else { fail("\(line): needs a date and a time") }
            let parts = words[2].split(separator: ".", maxSplits: 1).map(String.init)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            guard let d = f.date(from: words[1] + " " + parts[0]) else { fail("\(line): not a date") }
            t = d.addingTimeInterval(parts.count > 1 ? Double("0." + parts[1]) ?? 0 : 0)
            lastWholeSecond = -1
            tickIfNewSecond()
        case "align":
            let now = t.timeIntervalSince1970
            var d = number(1) - (now - floor(now))
            if d < 1e-6 { d += 1 }
            run(d, render: false)
        case "plan":
            let source = URL(fileURLWithPath: rest, relativeTo: scriptDir)
            try? FileManager.default.removeItem(at: Paths.plan)
            do { try FileManager.default.copyItem(at: source, to: Paths.plan) } catch { fail("plan: \(error.localizedDescription)") }
            engine.tick()
        case "scene":
            let dir = outDir.appendingPathComponent(rest, isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { fail("scene: \(error.localizedDescription)") }
            if let s = sceneDir { print("  \(s.lastPathComponent): \(frame) frames") }
            sceneDir = dir
            frame = 0
        case "play": run(number(1), render: true)
        case "wait": run(number(1), render: false)
        case "cheer": engine.nextCheer = rest
        case "press": press(Int(number(1)))
        case "cursor": cursor = rest == "off" ? nil : NSPoint(x: number(1), y: number(2))
        case "point": glide(to: Int(number(1)), seconds: number(2), click: false)
        case "click": glide(to: Int(number(1)), seconds: number(2), click: true)
        default: fail("unknown command: \(line)")
        }
    }
}

func runFilm(scriptPath: String, outDir: String) {
    let scriptURL = URL(fileURLWithPath: scriptPath)
    guard let text = try? String(contentsOf: scriptURL, encoding: .utf8) else {
        FileHandle.standardError.write("film: cannot read \(scriptPath)\n".data(using: .utf8)!)
        exit(1)
    }
    try? FileManager.default.createDirectory(at: Paths.dir, withIntermediateDirectories: true)
    let film = Film(outDir: URL(fileURLWithPath: outDir, isDirectory: true), scriptDir: scriptURL.deletingLastPathComponent())
    film.engine.loadAll()
    for raw in text.components(separatedBy: .newlines) {
        let line = (raw.components(separatedBy: "#").first ?? "").trimmingCharacters(in: .whitespaces)
        if !line.isEmpty { film.command(line) }
    }
    if let s = film.sceneDir { print("  \(s.lastPathComponent): \(film.frame) frames") }
    print("film: \(film.total) frames in \(outDir)")
}
