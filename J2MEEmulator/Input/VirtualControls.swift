//
//  VirtualControls.swift
//  J2MEEmulator
//
//  On-screen phone keyboard that behaves like J2ME Loader's (Android):
//  • one overlay handles every finger itself — several keys at once
//    (walk + attack), and sliding a finger from one key to the next releases
//    the old key and presses the new one (no lifting needed);
//  • holding a key repeats it with J2ME Loader's timing (first repeat after
//    400 ms, then speeding up to every 80 ms);
//  • diagonal keys press two directions together;
//  • keys are opaque where they don't cover the game and translucent where
//    they do;
//  • touches that miss every key go to the game screen (touch games).
//

import UIKit

enum J2MEKey {
    static let up: Int32 = -1
    static let down: Int32 = -2
    static let left: Int32 = -3
    static let right: Int32 = -4
    static let fire: Int32 = -5
    static let softLeft: Int32 = -6
    static let softRight: Int32 = -7
    static let clear: Int32 = -8      // "C" / Back on Nokia phones
    static let call: Int32 = -10      // green Call / Send key
    static let end: Int32 = -11       // red End key
}

/// Light vibration on key press (Menu → Phím điều khiển → Rung khi bấm phím).
var virtualKeyHapticsEnabled = true

private let keyHaptic = UIImpactFeedbackGenerator(style: .light)

// MARK: - Repeat timing

/// KEY_REPEATED while a key is held: 400 ms, then 200, 400, 5 × 128 ms, then every 80 ms
/// (the intervals J2ME Loader uses).
private final class KeyRepeater {
    private static let intervals: [TimeInterval] = [0.4, 0.2, 0.4, 0.128, 0.128, 0.128, 0.128, 0.128]
    private var timer: Timer?
    private var step = 0
    private var fire: (() -> Void)?
    private var customDelay: TimeInterval?
    private var customInterval: TimeInterval = 0.08

    /// `delayMs` nil keeps J2ME Loader's schedule.
    func start(delayMs: Int?, intervalMs: Int?, _ action: @escaping () -> Void) {
        stop()
        fire = action
        step = 0
        customDelay = delayMs.map { TimeInterval($0) / 1000 }
        customInterval = TimeInterval(intervalMs ?? 80) / 1000
        schedule()
    }

    private func nextDelay() -> TimeInterval {
        if let customDelay { return step == 0 ? customDelay : customInterval }
        return step < Self.intervals.count ? Self.intervals[step] : 0.08
    }

    private func schedule() {
        timer = Timer.scheduledTimer(withTimeInterval: nextDelay(), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.fire != nil else { return }
                self.fire?()
                self.step += 1
                self.schedule()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        fire = nil
    }
}

// MARK: - Look

struct KeyStyle {
    let fill: UIColor
    let text: UIColor
    let border: UIColor
    let pressedFill: UIColor
    let pressedText: UIColor

    static func of(_ theme: KeyTheme, fill: UIColor?, text: UIColor?) -> KeyStyle {
        let base = of(theme)
        guard fill != nil || text != nil else { return base }
        let f = fill ?? base.fill, t = text ?? base.text
        return KeyStyle(fill: f, text: t, border: base.border, pressedFill: t, pressedText: f)
    }

    static func of(_ theme: KeyTheme) -> KeyStyle {
        switch theme {
        case .light:   // J2ME Loader defaults: light grey keys, navy labels, navy when pressed
            return KeyStyle(fill: UIColor(red: 0.816, green: 0.816, blue: 0.816, alpha: 1),
                            text: UIColor(red: 0, green: 0, blue: 0.5, alpha: 1),
                            border: UIColor.white,
                            pressedFill: UIColor(red: 0, green: 0, blue: 0.5, alpha: 1),
                            pressedText: UIColor.white)
        case .dark:
            return KeyStyle(fill: UIColor(white: 0.12, alpha: 1),
                            text: UIColor.white,
                            border: UIColor(white: 1, alpha: 0.55),
                            pressedFill: UIColor(white: 0.85, alpha: 1),
                            pressedText: UIColor.black)
        }
    }
}

/// One drawn key (touches are handled by the keyboard view).
final class VKeyView: UIView {
    let spec: VKeySpec
    private let label = UILabel()
    private var style = KeyStyle.of(.light)
    private var shape = KeyShape.rounded
    private(set) var isPressed = false

    init(spec: VKeySpec) {
        self.spec = spec
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.borderWidth = 1
        label.text = spec.label
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = spec.name
        accessibilityTraits = .keyboardKey
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(theme: KeyTheme, shape: KeyShape, fill: UIColor? = nil, text: UIColor? = nil) {
        style = KeyStyle.of(theme, fill: fill, text: text)
        self.shape = shape
        applyColors()
        setNeedsLayout()
    }

    func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        applyColors()
    }

    private func applyColors() {
        backgroundColor = isPressed ? style.pressedFill : style.fill
        label.textColor = isPressed ? style.pressedText : style.text
        layer.borderColor = style.border.cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        switch shape {
        case .rounded: layer.cornerRadius = side * 0.25
        case .circle:  layer.cornerRadius = side / 2
        case .square:  layer.cornerRadius = 3
        }
        let arrows = spec.group == .arrows && spec.id != "fire"
        let isWord = spec.label.count > 1
        label.font = .systemFont(ofSize: side * (arrows ? 0.5 : (isWord ? 0.34 : 0.44)), weight: .bold)
        label.frame = bounds.insetBy(dx: 3, dy: 2)
    }
}

/// The Menu key: a real button so it can open the JarBox menu.
final class VMenuButton: UIButton {
    let face: VKeyView

    init(spec: VKeySpec) {
        face = VKeyView(spec: spec)
        super.init(frame: .zero)
        addSubview(face)
        accessibilityLabel = "Menu"
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { face.setPressed(isHighlighted) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        face.frame = bounds
    }
}

// MARK: - Joystick

/// 8-way joystick: a ring and a thumb. Touches are handled by the keyboard view.
final class VJoystickView: UIView {
    private let ring = CAShapeLayer()
    private let thumb = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(ring)
        layer.addSublayer(thumb)
        applyColors(fill: UIColor(white: 0.8, alpha: 1), text: UIColor(red: 0, green: 0, blue: 0.5, alpha: 1))
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyColors(fill: UIColor, text: UIColor) {
        ring.fillColor = fill.withAlphaComponent(0.55).cgColor
        ring.strokeColor = UIColor.white.cgColor
        ring.lineWidth = 1
        thumb.fillColor = text.cgColor
        thumb.strokeColor = UIColor.white.cgColor
        thumb.lineWidth = 1
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).cgPath
        setThumb(dx: 0, dy: 0)
    }

    /// Offset as a fraction of the radius.
    func setThumb(dx: CGFloat, dy: CGFloat) {
        let radius = bounds.width / 2
        let side = radius * 0.8
        let box = CGRect(x: radius - side / 2 + dx * radius * 0.6, y: radius - side / 2 + dy * radius * 0.6, width: side, height: side)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.path = UIBezierPath(ovalIn: box).cgPath
        CATransaction.commit()
    }
}

// MARK: - Keyboard

final class VirtualKeyboardView: UIView {

    private(set) var keyViews: [String: VKeyView] = [:]
    let menuButton: VMenuButton
    let joystick = VJoystickView()

    /// Joystick centre zone that counts as "no direction", 0…1 of the radius.
    var joystickDeadZone: CGFloat = 0.25
    private var joystickTouch: ObjectIdentifier?
    private var joystickDirection: String?
    private var repeatDelayMs: Int?
    private var repeatIntervalMs: Int?

    /// Keys currently shown (frames are set by the owner on every layout).
    private var visibleIds: Set<String> = []
    private var hitSlop: CGFloat = 4

    private var touchKeys: [ObjectIdentifier: String] = [:]     // finger → key under it
    private var keyTouches: [String: Int] = [:]                  // key → fingers on it
    private var heldCodes: [Int32: Int] = [:]                    // key code → keys holding it
    private var repeaters: [String: KeyRepeater] = [:]

    /// While the layout editor is open the keys only show where they are.
    var isEditing = false {
        didSet { if isEditing { releaseAll() } }
    }

    override init(frame: CGRect) {
        menuButton = VMenuButton(spec: ControlCatalog.spec("menu")!)
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        for spec in ControlCatalog.all where spec.group != .menu {
            let key = VKeyView(spec: spec)
            keyViews[spec.id] = key
            addSubview(key)
        }
        addSubview(joystick)
        addSubview(menuButton)
        keyHaptic.prepare()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// All key views including the Menu key's face, by key id (for the layout editor).
    var allKeyViews: [String: UIView] {
        var all: [String: UIView] = keyViews
        all["menu"] = menuButton
        all["joystick"] = joystick
        return all
    }

    func apply(theme: KeyTheme, shape: KeyShape, fill: UIColor?, text: UIColor?, perKey: [String: UIColor] = [:]) {
        for (id, key) in keyViews { key.apply(theme: theme, shape: shape, fill: perKey[id] ?? fill, text: text) }
        menuButton.face.apply(theme: theme, shape: shape, fill: fill, text: text)
        let style = KeyStyle.of(theme, fill: fill, text: text)
        joystick.applyColors(fill: style.fill, text: style.text)
    }

    func setRepeat(delayMs: Int?, intervalMs: Int?) {
        repeatDelayMs = delayMs
        repeatIntervalMs = intervalMs
    }

    /// Place one key. `alpha` 0 hides it.
    func place(_ id: String, frame: CGRect, alpha: CGFloat, visible: Bool) {
        let target: UIView? = id == "menu" ? menuButton : (id == "joystick" ? joystick : keyViews[id])
        guard let view = target else { return }
        view.frame = frame
        view.alpha = alpha
        view.isHidden = !visible
        if visible { visibleIds.insert(id) } else { visibleIds.remove(id) }
        if id == "joystick" && !visible { endJoystick() }
        if !visible, keyTouches[id] != nil { forceRelease(id) }
    }

    func setHitSlop(_ slop: CGFloat) { hitSlop = slop }

    // MARK: Hit testing

    /// The key under a point: the nearest visible key whose frame (grown by
    /// half a gap, so sliding across the gap between keys never drops out)
    /// contains it.
    private func key(at point: CGPoint) -> String? {
        var best: String?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for id in visibleIds where id != "menu" && id != "joystick" {
            guard let v = keyViews[id] else { continue }
            let f = v.frame.insetBy(dx: -hitSlop, dy: -hitSlop)
            guard f.contains(point) else { continue }
            let d = hypot(point.x - v.frame.midX, point.y - v.frame.midY)
            if d < bestDistance { bestDistance = d; best = id }
        }
        return best
    }

    /// Touches that miss every key fall through to the game screen.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if isEditing { return false }
        if visibleIds.contains("menu"), !menuButton.isHidden, menuButton.frame.contains(point) { return true }
        return key(at: point) != nil || isOnJoystick(point)
    }

    // MARK: Joystick

    private func isOnJoystick(_ point: CGPoint) -> Bool {
        guard visibleIds.contains("joystick"), !joystick.isHidden else { return false }
        let radius = joystick.bounds.width / 2
        return hypot(point.x - joystick.center.x, point.y - joystick.center.y) <= radius * 1.15
    }

    private static let sectors = ["right", "upRight", "up", "upLeft", "left", "downLeft", "down", "downRight"]

    private func updateJoystick(_ point: CGPoint) {
        let radius = max(1, joystick.bounds.width / 2)
        var dx = (point.x - joystick.center.x) / radius
        var dy = (point.y - joystick.center.y) / radius
        let magnitude = hypot(dx, dy)
        if magnitude > 1 { dx /= magnitude; dy /= magnitude }
        joystick.setThumb(dx: dx, dy: dy)

        var next: String?
        if magnitude >= joystickDeadZone {
            let angle = atan2(-dy, dx)
            let sector = Int((angle / (.pi / 4)).rounded())
            next = Self.sectors[((sector % 8) + 8) % 8]
        }
        guard next != joystickDirection else { return }
        if let next { press(next) }
        if let old = joystickDirection { release(old) }
        joystickDirection = next
    }

    private func endJoystick() {
        joystickTouch = nil
        if let old = joystickDirection { release(old) }
        joystickDirection = nil
        joystick.setThumb(dx: 0, dy: 0)
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let point = t.location(in: self)
            if let id = key(at: point) {
                touchKeys[ObjectIdentifier(t)] = id
                press(id)
            } else if joystickTouch == nil, isOnJoystick(point) {
                joystickTouch = ObjectIdentifier(t)
                updateJoystick(point)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let tid = ObjectIdentifier(t)
            if tid == joystickTouch {
                updateJoystick(t.location(in: self))
                continue
            }
            let now = key(at: t.location(in: self))
            let before = touchKeys[tid]
            guard now != before else { continue }
            // Press the new key before releasing the old one, so a direction
            // shared by both (↑ → ↗) stays held without a release in between
            if let now {
                touchKeys[tid] = now
                press(now)
            } else {
                touchKeys[tid] = nil
            }
            if let before { release(before) }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let tid = ObjectIdentifier(t)
            if tid == joystickTouch {
                endJoystick()
            } else if let id = touchKeys.removeValue(forKey: tid) {
                release(id)
            }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    // MARK: Key state

    private func press(_ id: String) {
        guard let spec = ControlCatalog.spec(id) else { return }
        let fingers = (keyTouches[id] ?? 0) + 1
        keyTouches[id] = fingers
        guard fingers == 1 else { return }
        keyViews[id]?.setPressed(true)
        if virtualKeyHapticsEnabled { keyHaptic.impactOccurred(intensity: 0.7) }
        for code in spec.codes {
            let n = (heldCodes[code] ?? 0) + 1
            heldCodes[code] = n
            if n == 1 { j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), code) }
        }
        let repeater = repeaters[id] ?? KeyRepeater()
        repeaters[id] = repeater
        let codes = spec.codes
        repeater.start(delayMs: repeatDelayMs, intervalMs: repeatIntervalMs) {
            for code in codes { j2me_input_post_key(Int32(J2ME_INPUT_KEY_REPEATED), code) }
        }
    }

    private func release(_ id: String) {
        guard let fingers = keyTouches[id] else { return }
        if fingers > 1 { keyTouches[id] = fingers - 1; return }
        forceRelease(id)
    }

    private func forceRelease(_ id: String) {
        keyTouches[id] = nil
        repeaters[id]?.stop()
        keyViews[id]?.setPressed(false)
        guard let spec = ControlCatalog.spec(id) else { return }
        for code in spec.codes {
            let n = (heldCodes[code] ?? 1) - 1
            if n <= 0 {
                heldCodes[code] = nil
                j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), code)
            } else {
                heldCodes[code] = n
            }
        }
    }

    /// Release every held key (screen change, app switch, editor).
    func releaseAll() {
        joystickTouch = nil
        joystickDirection = nil
        joystick.setThumb(dx: 0, dy: 0)
        for id in Array(keyTouches.keys) { forceRelease(id) }
        touchKeys.removeAll()
    }

    /// Light up the on-screen key matching a hardware key press.
    func showHardwareKey(_ code: Int32, pressed: Bool) {
        for (id, view) in keyViews where keyTouches[id] == nil {
            if view.spec.codes == [code] { view.setPressed(pressed) }
        }
    }
}

extension UIColor {
    /// "#RRGGBB"
    convenience init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(r), channel(g), channel(b))
    }
}
