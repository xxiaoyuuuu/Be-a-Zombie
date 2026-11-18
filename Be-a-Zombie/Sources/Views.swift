import AppKit

enum Theme {
    static var dark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    static var bubble: NSColor {
        dark ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 0.98)
             : NSColor(srgbRed: 1.0, green: 0.995, blue: 0.97, alpha: 0.98)
    }
    static var border: NSColor { dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.10) }
    static var title: NSColor { dark ? NSColor(white: 0.97, alpha: 1) : NSColor(white: 0.11, alpha: 1) }
    static var sub: NSColor { dark ? NSColor(white: 0.76, alpha: 1) : NSColor(white: 0.36, alpha: 1) }
    static var secondary: NSColor { dark ? NSColor(white: 1, alpha: 0.15) : NSColor(white: 0, alpha: 0.07) }
    static let accent = NSColor(srgbRed: 0.27, green: 0.62, blue: 0.34, alpha: 1)
}

/// Large mode: the whole pet is drawn `z` times bigger. Layout stays in unscaled points;
/// subview frames are multiplied by `z`, and each view scales its own drawing.
enum UI {
    static var z: CGFloat = 1

    static func px(_ r: NSRect) -> NSRect {
        NSRect(x: r.minX * z, y: r.minY * z, width: r.width * z, height: r.height * z)
    }

    /// Call first in draw(_:). Returns the view's bounds in unscaled points; drawing after this uses them.
    static func enter(_ view: NSView) -> NSRect {
        let t = NSAffineTransform()
        t.scale(by: z)
        t.concat()
        return NSRect(x: 0, y: 0, width: view.bounds.width / z, height: view.bounds.height / z)
    }
}

// MARK: - Buttons

final class PillButton: NSView {
    static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static func width(for title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font]).width) + 24
    }

    let title: String
    let primary: Bool
    var action: () -> Void = {}
    var pressed = false { didSet { needsDisplay = true } }

    init(title: String, primary: Bool) {
        self.title = title
        self.primary = primary
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = UI.enter(self)
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        if primary {
            (pressed ? Theme.accent.blended(withFraction: 0.25, of: .black) ?? Theme.accent : Theme.accent).setFill()
        } else {
            (pressed ? Theme.secondary.withAlphaComponent(0.3) : Theme.secondary).setFill()
        }
        path.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: primary ? NSColor.white : Theme.title,
        ]
        let s = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(
            at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2),
            withAttributes: attrs
        )
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside {
            let a = action
            DispatchQueue.main.async { a() }
        }
    }
}

final class CloseDot: NSView {
    var action: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = UI.enter(self)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Theme.sub,
        ]
        let s = ("✕" as NSString).size(withAttributes: attrs)
        ("✕" as NSString).draw(
            at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2),
            withAttributes: attrs
        )
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            let a = action
            DispatchQueue.main.async { a() }
        }
    }
}

// MARK: - Speech bubble

final class BubbleView: NSView {
    static let shadowPad: CGFloat = 14
    static let tailH: CGFloat = 9

    var onAction: (Action) -> Void = { _ in }

    private let pad: CGFloat = 12
    private let maxTextW: CGFloat = 232
    private var model = BubbleModel()
    private var mini = false
    private var pills: [PillButton] = []
    private var closeDot: CloseDot?
    private var buttonKey = ""
    private var titleAttr = NSAttributedString()
    private var subAttr = NSAttributedString()
    private var titleRect = NSRect.zero
    private var subRect = NSRect.zero
    private var bubbleRect = NSRect.zero

    private func measure(_ a: NSAttributedString, _ w: CGFloat) -> NSSize {
        let r = a.boundingRect(
            with: NSSize(width: w, height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return NSSize(width: ceil(r.width), height: ceil(r.height))
    }

    private func clearButtons() {
        pills.forEach { $0.removeFromSuperview() }
        pills = []
        closeDot?.removeFromSuperview()
        closeDot = nil
        buttonKey = ""
    }

    /// Lays the bubble out for this content and returns the size the view needs.
    func apply(_ m: BubbleModel, mini: Bool) -> NSSize {
        model = m
        self.mini = mini
        needsDisplay = true
        let sp = Self.shadowPad

        if m.hidden || (mini && m.pill.isEmpty) {
            clearButtons()
            bubbleRect = .zero
            return .zero
        }

        if mini {
            clearButtons()
            titleAttr = NSAttributedString(string: m.pill, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: Theme.title,
            ])
            subAttr = NSAttributedString()
            subRect = .zero
            let s = titleAttr.size()
            let bw = ceil(s.width) + 20
            let bh: CGFloat = 24
            bubbleRect = NSRect(x: sp, y: sp, width: bw, height: bh)
            titleRect = NSRect(x: sp + 10, y: sp + (bh - ceil(s.height)) / 2, width: ceil(s.width) + 1, height: ceil(s.height))
            return NSSize(width: bw + 2 * sp, height: bh + 2 * sp)
        }

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = 1.5
        titleAttr = NSAttributedString(string: m.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .bold),
            .foregroundColor: Theme.title,
            .paragraphStyle: para,
        ])
        subAttr = NSAttributedString(string: m.subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: Theme.sub,
            .paragraphStyle: para,
        ])

        let closeW: CGFloat = m.dismissible ? 18 : 0
        let tSize = measure(titleAttr, maxTextW - closeW)
        let sSize = m.subtitle.isEmpty ? NSSize.zero : measure(subAttr, maxTextW)
        let widths = m.buttons.map { PillButton.width(for: $0.0) }
        let buttonsW = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * 8
        let innerW = max(max(tSize.width + closeW, sSize.width), max(buttonsW, 120))
        let bw = innerW + 2 * pad
        var bh = pad + tSize.height + pad
        if !m.subtitle.isEmpty { bh += 4 + sSize.height }
        if !m.buttons.isEmpty { bh += 10 + 26 }

        bubbleRect = NSRect(x: sp, y: sp, width: bw, height: bh)
        var y = bubbleRect.maxY - pad - tSize.height
        titleRect = NSRect(x: sp + pad, y: y, width: innerW - closeW, height: tSize.height)
        if m.subtitle.isEmpty {
            subRect = .zero
        } else {
            y -= 4 + sSize.height
            subRect = NSRect(x: sp + pad, y: y, width: innerW, height: sSize.height)
        }

        let key = m.buttons.map { $0.0 }.joined(separator: "|") + (m.dismissible ? "|x" : "")
        if key != buttonKey {
            clearButtons()
            buttonKey = key
            for (i, b) in m.buttons.enumerated() {
                let p = PillButton(title: b.0, primary: i == 0)
                addSubview(p)
                pills.append(p)
            }
            if m.dismissible {
                let c = CloseDot()
                addSubview(c)
                closeDot = c
            }
        }
        var x = sp + pad
        for (i, p) in pills.enumerated() {
            let a = m.buttons[i].1
            p.action = { [weak self] in self?.onAction(a) }
            p.frame = UI.px(NSRect(x: x, y: sp + pad, width: widths[i], height: 26))
            p.needsDisplay = true
            x += widths[i] + 8
        }
        closeDot?.action = { [weak self] in self?.onAction(.ok) }
        closeDot?.frame = UI.px(NSRect(x: bubbleRect.maxX - 24, y: bubbleRect.maxY - 25, width: 18, height: 18))
        closeDot?.needsDisplay = true

        return NSSize(width: bw + 2 * sp, height: bh + 2 * sp)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bubbleRect.width > 0 else { return }
        _ = UI.enter(self)
        let r = bubbleRect
        let radius: CGFloat = mini ? r.height / 2 : 13
        let body = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        let tail = NSBezierPath()
        if !mini {
            let tx = r.maxX - 44
            tail.move(to: NSPoint(x: tx - 8, y: r.minY + 1))
            tail.line(to: NSPoint(x: tx + 2, y: r.minY - Self.tailH))
            tail.line(to: NSPoint(x: tx + 9, y: r.minY + 1))
        }

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor(white: 0, alpha: 0.26)
        shadow.set()
        Theme.bubble.setFill()
        let whole = NSBezierPath()
        whole.append(body)
        if !mini {
            let closed = tail.copy() as! NSBezierPath
            closed.close()
            whole.append(closed)
        }
        whole.fill()
        NSGraphicsContext.restoreGraphicsState()

        Theme.border.setStroke()
        body.lineWidth = 1
        body.stroke()
        if !mini {
            let closed = tail.copy() as! NSBezierPath
            closed.close()
            Theme.bubble.withAlphaComponent(1).setFill()
            closed.fill()
            Theme.border.setStroke()
            tail.lineWidth = 1
            tail.stroke()
        }

        titleAttr.draw(with: titleRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        if subRect.width > 0 {
            subAttr.draw(with: subRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }
}

// MARK: - The zombie

final class ZombieView: NSView {
    var badge = "" {
        didSet { if badge != oldValue { needsDisplay = true } }
    }
    var onClick: () -> Void = {}
    var onMenu: (NSEvent) -> Void = { _ in }
    var onDragEnd: () -> Void = {}

    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var dragged = false
    private var idle: Mood?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = UI.enter(self)
        // A nearly invisible disc so the whole zombie is easy to click and drag.
        NSColor(white: 0.5, alpha: 0.02).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 6, dy: 6)).fill()

        NSColor(white: 0, alpha: 0.22).setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - 25, y: 3, width: 50, height: 9)).fill()

        let z = NSAttributedString(string: "🧟", attributes: [.font: NSFont.systemFont(ofSize: 58)])
        let s = z.size()
        z.draw(at: NSPoint(x: bounds.midX - s.width / 2, y: 6))

        if !badge.isEmpty {
            let b = NSAttributedString(string: badge, attributes: [.font: NSFont.systemFont(ofSize: 20)])
            b.draw(at: NSPoint(x: 0, y: bounds.height - 30))
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        let dx = p.x - dragStartMouse.x, dy = p.y - dragStartMouse.y
        if !dragged && abs(dx) + abs(dy) < 4 { return }
        dragged = true
        window?.setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { onDragEnd() } else { onClick() }
    }

    override func rightMouseDown(with event: NSEvent) { onMenu(event) }

    // MARK: Motion

    func setIdle(_ mood: Mood) {
        guard idle != mood, let layer else { return }
        idle = mood
        layer.removeAnimation(forKey: "idle")
        let a: CABasicAnimation
        switch mood {
        case .sleep:
            return
        case .rest, .happy:
            a = CABasicAnimation(keyPath: "transform.translation.x")
            a.fromValue = -3 * UI.z
            a.toValue = 3 * UI.z
            a.duration = 0.9
        case .alert:
            a = CABasicAnimation(keyPath: "transform.translation.y")
            a.fromValue = 0
            a.toValue = 5 * UI.z
            a.duration = 0.45
        default:
            a = CABasicAnimation(keyPath: "transform.translation.y")
            a.fromValue = 0
            a.toValue = 2.5 * UI.z
            a.duration = 1.7
        }
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "idle")
    }

    func hop() {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.y")
        a.values = [0, 16, 0, 9, 0].map { $0 * UI.z }
        a.keyTimes = [0, 0.3, 0.55, 0.78, 1]
        a.duration = 0.6
        layer?.add(a, forKey: "hop")
    }

    func shake() {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, -7, 7, -6, 6, -3, 3, 0].map { $0 * UI.z }
        a.duration = 0.55
        layer?.add(a, forKey: "shake")
    }
}

// MARK: - Root view

final class PetView: NSView {
    static let size = NSSize(width: 310, height: 300)   // unscaled points
    static var scaledSize: NSSize { NSSize(width: size.width * UI.z, height: size.height * UI.z) }
    static let zombieSide: CGFloat = 88
    private var zombieRect: NSRect {
        NSRect(x: Self.size.width - Self.zombieSide - 10, y: 0, width: Self.zombieSide, height: Self.zombieSide)
    }

    /// Where the little "🧠 +2" starts, in unscaled points. It rises 44 points and fades over 1.3 s.
    var floatRect: NSRect { NSRect(x: zombieRect.minX - 74, y: 18, width: 84, height: 28) }

    let bubble = BubbleView()
    let zombie = ZombieView(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(bubble)
        addSubview(zombie)
        zombie.frame = UI.px(zombieRect)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func layoutPet(model: BubbleModel, mini: Bool) {
        zombie.frame = UI.px(zombieRect)
        zombie.badge = model.badge
        zombie.setIdle(model.mood)

        let size = bubble.apply(model, mini: mini)
        bubble.isHidden = size == .zero
        guard size != .zero else { return }
        if mini {
            let x = min(zombieRect.midX - size.width / 2, Self.size.width - size.width)
            bubble.frame = UI.px(NSRect(x: x, y: 60, width: size.width, height: size.height))
        } else {
            bubble.frame = UI.px(NSRect(x: Self.size.width - size.width, y: 72, width: size.width, height: size.height))
        }
    }

    /// A little "🧠 +2" that floats up beside the zombie.
    func floatBrain(_ n: Int) {
        guard let root = layer else { return }
        let t = CATextLayer()
        t.string = NSAttributedString(string: "🧠 +\(n)", attributes: [
            .font: NSFont.systemFont(ofSize: 20 * UI.z, weight: .heavy),
            .foregroundColor: Theme.accent,
        ])
        t.contentsScale = window?.backingScaleFactor ?? 2
        t.alignmentMode = .center
        t.frame = UI.px(floatRect)
        root.addSublayer(t)

        let move = CABasicAnimation(keyPath: "position.y")
        move.byValue = 44 * UI.z
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [move, fade]
        g.duration = 1.3
        g.isRemovedOnCompletion = false
        g.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { t.removeFromSuperlayer() }
        t.add(g, forKey: "float")
        CATransaction.commit()
    }
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
