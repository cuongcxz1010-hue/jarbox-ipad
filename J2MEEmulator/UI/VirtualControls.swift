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

    func start(_ action: @escaping () -> Void) {
        stop()
        fire = action
        step = 0
        schedule()
    }

    private func schedule() {
        let delay = step < Self.intervals.count ? Self.intervals[step] : 0.08
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
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

    func apply(theme: KeyTheme, shape: KeyShape) {
        style = KeyStyle.of(theme)
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

// MARK: - Keyboard

final class VirtualKeyboardView: UIView {

    private(set) var keyViews: [String: VKeyView] = [:]
    let menuButton: VMenuButton

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
        addSubview(menuButton)
        keyHaptic.prepare()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// All key views including the Menu key's face, by key id (for the layout editor).
    var allKeyViews: [String: UIView] {
        var all: [String: UIView] = keyViews
        all["menu"] = menuButton
        return all
    }

    func apply(theme: KeyTheme, shape: KeyShape) {
        for key in keyViews.values { key.apply(theme: theme, shape: shape) }
        menuButton.face.apply(theme: theme, shape: shape)
    }

    /// Place one key. `alpha` 0 hides it.
    func place(_ id: String, frame: CGRect, alpha: CGFloat, visible: Bool) {
        let target: UIView? = id == "menu" ? menuButton : keyViews[id]
        guard let view = target else { return }
        view.frame = frame
        view.alpha = alpha
        view.isHidden = !visible
        if visible { visibleIds.insert(id) } else { visibleIds.remove(id) }
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
        for id in visibleIds where id != "menu" {
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
        return key(at: point) != nil
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if let id = key(at: t.location(in: self)) {
                touchKeys[ObjectIdentifier(t)] = id
                press(id)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let tid = ObjectIdentifier(t)
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
            if let id = touchKeys.removeValue(forKey: ObjectIdentifier(t)) { release(id) }
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
        repeater.start {
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
