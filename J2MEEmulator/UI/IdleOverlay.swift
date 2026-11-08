//
//  IdleOverlay.swift
//  J2MEEmulator
//
//  Screen shown in "stable idle" mode: the game keeps running in the
//  foreground while the display is dimmed and touches are blocked.
//  Shows a small live preview of the game (to see it is still connected)
//  and status: time idled, battery, frame rate, temperature, auto-press,
//  Guided Access. Content drifts every minute (no burn-in on OLED iPads).
//

import UIKit

final class IdleOverlayView: UIView {

    struct Status {
        var elapsed: TimeInterval
        var batteryLevel: Float        // 0…1, or < 0 when unknown
        var batteryState: UIDevice.BatteryState
        var fps: Int                   // 0 = unlimited
        var thermal: ProcessInfo.ThermalState
        var autoPress: String?         // nil = off
        var guidedAccess: Bool
    }

    var onExit: (() -> Void)?

    private let content = UIView()
    private let preview = UIView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private var drift = CGPoint.zero
    private var lastDrift = Date()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        preview.layer.magnificationFilter = .nearest
        preview.layer.contentsGravity = .resizeAspect
        preview.alpha = 0.55
        preview.layer.cornerRadius = 8
        preview.clipsToBounds = true
        preview.layer.borderColor = UIColor(white: 1, alpha: 0.15).cgColor
        preview.layer.borderWidth = 1

        titleLabel.text = "ĐANG TREO GAME"
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = UIColor(white: 1, alpha: 0.7)
        titleLabel.textAlignment = .center

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        statusLabel.textColor = UIColor(white: 1, alpha: 0.6)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center

        hintLabel.text = "Chạm 2 lần để quay lại game"
        hintLabel.font = .systemFont(ofSize: 14, weight: .medium)
        hintLabel.textColor = UIColor(white: 1, alpha: 0.45)
        hintLabel.textAlignment = .center

        for v in [preview, titleLabel, statusLabel, hintLabel] { content.addSubview(v) }
        addSubview(content)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(exitTapped))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        accessibilityLabel = "Đang treo game. Chạm 2 lần để quay lại."
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func exitTapped() { onExit?() }

    /// Latest game frame (called for every frame the game draws).
    func setPreview(_ image: CGImage) {
        preview.layer.contents = image
    }

    func update(_ s: Status) {
        let h = Int(s.elapsed) / 3600, m = Int(s.elapsed) / 60 % 60, sec = Int(s.elapsed) % 60
        var lines = [String(format: "Đã treo: %02d:%02d:%02d", h, m, sec)]

        if s.batteryLevel >= 0 {
            let state: String
            switch s.batteryState {
            case .charging: state = "đang sạc"
            case .full: state = "đã đầy"
            case .unplugged: state = "không cắm sạc"
            default: state = ""
            }
            lines.append("Pin: \(Int((s.batteryLevel * 100).rounded()))%" + (state.isEmpty ? "" : " · \(state)"))
        }

        lines.append("Hình: " + (s.fps > 0 ? "\(s.fps) FPS (tiết kiệm pin)" : "không giới hạn"))

        let thermal: String
        switch s.thermal {
        case .nominal: thermal = "bình thường"
        case .fair: thermal = "hơi ấm"
        case .serious: thermal = "nóng — đã giảm FPS"
        case .critical: thermal = "rất nóng — nên rút sạc / để chỗ mát"
        @unknown default: thermal = "không rõ"
        }
        lines.append("Nhiệt độ máy: \(thermal)")
        lines.append("Tự động bấm: " + (s.autoPress ?? "tắt"))
        lines.append("Truy cập được hướng dẫn: " + (s.guidedAccess ? "đang bật ✓" : "chưa bật"))
        statusLabel.text = lines.joined(separator: "\n")

        // Move the content a little every minute (avoids burn-in on OLED screens)
        if Date().timeIntervalSince(lastDrift) > 60 {
            lastDrift = Date()
            drift = CGPoint(x: CGFloat.random(in: -24...24), y: CGFloat.random(in: -24...24))
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let safe = safeAreaLayoutGuide.layoutFrame
        let width = min(safe.width - 40, 520)
        let previewH = min(safe.height * 0.35, 280)
        let statusH = statusLabel.sizeThatFits(CGSize(width: width, height: 400)).height
        let total = previewH + 16 + 28 + 10 + statusH + 16 + 20
        content.frame = CGRect(x: safe.midX - width / 2 + drift.x, y: safe.midY - total / 2 + drift.y,
                               width: width, height: total)
        preview.frame = CGRect(x: 0, y: 0, width: width, height: previewH)
        titleLabel.frame = CGRect(x: 0, y: previewH + 16, width: width, height: 28)
        statusLabel.frame = CGRect(x: 0, y: titleLabel.frame.maxY + 10, width: width, height: statusH)
        hintLabel.frame = CGRect(x: 0, y: statusLabel.frame.maxY + 16, width: width, height: 20)
    }
}
