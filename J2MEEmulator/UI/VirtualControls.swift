//
//  VirtualControls.swift
//  J2MEEmulator
//
//  On-screen phone keys in the style of J2ME Loader (Android):
//  translucent round keys, a D-pad that sends the standard arrow / fire
//  codes (-1 up, -2 down, -3 left, -4 right, -5 fire) and a 3×4 keypad.
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

/// Light vibration on key press (Menu → Rung khi bấm phím).
var virtualKeyHapticsEnabled = true

/// Held keys repeat like a phone keypad (KEY_REPEATED after 0.4 s, every 80 ms).
private final class KeyRepeater {
    private var timer: Timer?

    func start(_ codes: @escaping @MainActor () -> [Int32]) {
        stop()
        // Timers are scheduled on the main run loop, so their blocks run on the main actor
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        for code in codes() { j2me_input_post_key(Int32(J2ME_INPUT_KEY_REPEATED), code) }
                    }
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

private let keyHaptic = UIImpactFeedbackGenerator(style: .light)

private enum KeyStyle {
    static let fill = UIColor(white: 0.0, alpha: 0.42)
    static let fillPressed = UIColor(white: 1.0, alpha: 0.42)
    static let border = UIColor(white: 1.0, alpha: 0.6)
    static let text = UIColor.white
}

// MARK: - Single key

final class VirtualKeyButton: UIControl {
    let codes: [Int32]
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let repeater = KeyRepeater()
    private let round: Bool

    init(title: String, subtitle: String? = nil, codes: [Int32], round: Bool = false) {
        self.codes = codes
        self.round = round
        super.init(frame: .zero)
        backgroundColor = KeyStyle.fill
        layer.borderColor = KeyStyle.border.cgColor
        layer.borderWidth = 1.5
        isExclusiveTouch = false

        titleLabel.text = title
        titleLabel.textColor = KeyStyle.text
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.5
        titleLabel.isUserInteractionEnabled = false
        addSubview(titleLabel)

        subtitleLabel.text = subtitle
        subtitleLabel.textColor = KeyStyle.text.withAlphaComponent(0.75)
        subtitleLabel.textAlignment = .center
        subtitleLabel.isUserInteractionEnabled = false
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty
        addSubview(subtitleLabel)

        accessibilityLabel = subtitle.map { "\(title) \($0)" } ?? title
        accessibilityTraits = .keyboardKey
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        layer.cornerRadius = round ? min(bounds.width, h) / 2 : min(14, h * 0.28)
        if subtitleLabel.isHidden {
            titleLabel.font = .systemFont(ofSize: h * 0.42, weight: .bold)
            titleLabel.frame = bounds.insetBy(dx: 4, dy: 2)
        } else {
            titleLabel.font = .systemFont(ofSize: h * 0.40, weight: .bold)
            subtitleLabel.font = .systemFont(ofSize: max(8, h * 0.18), weight: .medium)
            titleLabel.frame = CGRect(x: 4, y: h * 0.08, width: bounds.width - 8, height: h * 0.55)
            subtitleLabel.frame = CGRect(x: 2, y: h * 0.62, width: bounds.width - 4, height: h * 0.3)
        }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if virtualKeyHapticsEnabled { keyHaptic.impactOccurred(intensity: 0.6) }
        for code in codes { j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), code) }
        backgroundColor = KeyStyle.fillPressed
        let held = codes
        repeater.start { held }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        release()
    }

    override func cancelTracking(with event: UIEvent?) {
        release()
    }

    private func release() {
        repeater.stop()
        for code in codes { j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), code) }
        backgroundColor = KeyStyle.fill
    }
}

// MARK: - D-pad

/// Round D-pad: centre = OK/fire, four arrows; touching between two arrows
/// presses both (diagonal). Sliding the finger changes direction.
final class DPadView: UIView {
    private let baseLayer = CAShapeLayer()
    private let highlightLayers = (0..<4).map { _ in CAShapeLayer() }   // up, right, down, left
    private let centerLayer = CAShapeLayer()
    private let okLabel = UILabel()
    private let arrows = (0..<4).map { _ in UIImageView() }
    private var activeCodes: [Int32] = []
    private weak var trackingTouch: UITouch?
    private let repeater = KeyRepeater()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        baseLayer.fillColor = KeyStyle.fill.cgColor
        baseLayer.strokeColor = KeyStyle.border.cgColor
        baseLayer.lineWidth = 1.5
        layer.addSublayer(baseLayer)
        for h in highlightLayers {
            h.fillColor = KeyStyle.fillPressed.cgColor
            h.isHidden = true
            layer.addSublayer(h)
        }
        centerLayer.fillColor = KeyStyle.fill.cgColor
        centerLayer.strokeColor = KeyStyle.border.cgColor
        centerLayer.lineWidth = 1.5
        layer.addSublayer(centerLayer)

        okLabel.text = "OK"
        okLabel.textColor = KeyStyle.text
        okLabel.textAlignment = .center
        addSubview(okLabel)

        let names = ["arrowtriangle.up.fill", "arrowtriangle.right.fill",
                     "arrowtriangle.down.fill", "arrowtriangle.left.fill"]
        for (arrow, name) in zip(arrows, names) {
            arrow.image = UIImage(systemName: name)
            arrow.tintColor = KeyStyle.text
            arrow.contentMode = .scaleAspectFit
            addSubview(arrow)
        }
        accessibilityLabel = "Phím điều hướng"
    }

    required init?(coder: NSCoder) { fatalError() }

    private var radius: CGFloat { min(bounds.width, bounds.height) / 2 }
    private var centerRadius: CGFloat { radius * 0.33 }

    override func layoutSubviews() {
        super.layoutSubviews()
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let r = radius
        baseLayer.path = UIBezierPath(arcCenter: c, radius: r - 1, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
        centerLayer.path = UIBezierPath(arcCenter: c, radius: centerRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath

        // Highlight wedges: up (-90°), right (0°), down (90°), left (180°), each 90° wide
        for (i, h) in highlightLayers.enumerated() {
            let mid = CGFloat(i) * .pi / 2 - .pi / 2
            let path = UIBezierPath()
            path.addArc(withCenter: c, radius: r - 1, startAngle: mid - .pi / 4, endAngle: mid + .pi / 4, clockwise: true)
            path.addArc(withCenter: c, radius: centerRadius, startAngle: mid + .pi / 4, endAngle: mid - .pi / 4, clockwise: false)
            path.close()
            h.path = path.cgPath
        }

        okLabel.font = .systemFont(ofSize: centerRadius * 0.6, weight: .bold)
        okLabel.frame = CGRect(x: c.x - centerRadius, y: c.y - centerRadius, width: centerRadius * 2, height: centerRadius * 2)

        let a = r * 0.26
        let d = (r + centerRadius) / 2
        let offsets = [CGPoint(x: 0, y: -d), CGPoint(x: d, y: 0), CGPoint(x: 0, y: d), CGPoint(x: -d, y: 0)]
        for (arrow, o) in zip(arrows, offsets) {
            arrow.frame = CGRect(x: c.x + o.x - a / 2, y: c.y + o.y - a / 2, width: a, height: a)
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hypot(point.x - bounds.midX, point.y - bounds.midY) <= radius * 1.08
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackingTouch == nil, let t = touches.first else { return }
        trackingTouch = t
        update(t.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = trackingTouch, touches.contains(t) else { return }
        update(t.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = trackingTouch, touches.contains(t) else { return }
        trackingTouch = nil
        setActive([])
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func update(_ p: CGPoint) {
        let dx = p.x - bounds.midX
        let dy = p.y - bounds.midY
        if hypot(dx, dy) < centerRadius {
            setActive([J2MEKey.fire])
            return
        }
        // Angle in degrees, 0 = right, 90 = down (screen coordinates)
        var deg = atan2(dy, dx) * 180 / .pi
        if deg < 0 { deg += 360 }
        // Cardinal directions get 60° each, diagonals the 30° between them
        let cardinals: [(center: CGFloat, code: Int32)] = [
            (0, J2MEKey.right), (90, J2MEKey.down), (180, J2MEKey.left), (270, J2MEKey.up), (360, J2MEKey.right),
        ]
        if let hit = cardinals.first(where: { abs(deg - $0.center) <= 30 }) {
            setActive([hit.code])
            return
        }
        switch deg {
        case 30..<60:   setActive([J2MEKey.down, J2MEKey.right])
        case 120..<150: setActive([J2MEKey.down, J2MEKey.left])
        case 210..<240: setActive([J2MEKey.up, J2MEKey.left])
        default:        setActive([J2MEKey.up, J2MEKey.right])
        }
    }

    private func setActive(_ codes: [Int32]) {
        guard codes != activeCodes else { return }
        for code in activeCodes where !codes.contains(code) {
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), code)
        }
        let newlyPressed = codes.filter { !activeCodes.contains($0) }
        for code in newlyPressed {
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), code)
        }
        if !newlyPressed.isEmpty && virtualKeyHapticsEnabled { keyHaptic.impactOccurred(intensity: 0.5) }
        activeCodes = codes

        highlightLayers[0].isHidden = !codes.contains(J2MEKey.up)
        highlightLayers[1].isHidden = !codes.contains(J2MEKey.right)
        highlightLayers[2].isHidden = !codes.contains(J2MEKey.down)
        highlightLayers[3].isHidden = !codes.contains(J2MEKey.left)
        centerLayer.fillColor = (codes.contains(J2MEKey.fire) ? KeyStyle.fillPressed : KeyStyle.fill).cgColor

        if codes.isEmpty {
            repeater.stop()
        } else {
            repeater.start { [weak self] in self?.activeCodes ?? [] }
        }
    }
}

// MARK: - Keypad 1-9 * 0 #

final class KeypadView: UIView {
    private var keys: [VirtualKeyButton] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        let layout: [(String, String?, Int32)] = [
            ("1", nil, 49), ("2", "abc", 50), ("3", "def", 51),
            ("4", "ghi", 52), ("5", "jkl", 53), ("6", "mno", 54),
            ("7", "pqrs", 55), ("8", "tuv", 56), ("9", "wxyz", 57),
            ("*", nil, 42), ("0", "␣", 48), ("#", nil, 35),
        ]
        for (title, sub, code) in layout {
            let key = VirtualKeyButton(title: title, subtitle: sub, codes: [code])
            keys.append(key)
            addSubview(key)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gap = bounds.width * 0.045
        let w = (bounds.width - gap * 2) / 3
        let h = (bounds.height - gap * 3) / 4
        for (i, key) in keys.enumerated() {
            key.frame = CGRect(x: CGFloat(i % 3) * (w + gap), y: CGFloat(i / 3) * (h + gap), width: w, height: h)
        }
    }

    // Gaps between keys pass touches through to the game screen
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        keys.contains { $0.frame.contains(point) }
    }
}
