//
//  KeyLayoutEditor.swift
//  J2MEEmulator
//
//  Full-screen overlay for arranging the on-screen keys: drag to move,
//  pinch to resize, tap a key to adjust its size / opacity or hide it.
//  The game view controller owns the key views and stores the result.
//

import UIKit

final class KeyLayoutEditorView: UIView, UIGestureRecognizerDelegate {

    struct Item {
        let id: String
        let name: String
        let view: UIView
    }

    // Supplied by the owner
    var items: [Item] = [] { didSet { refreshOutlines() } }
    var placementFor: ((String) -> KeyPlacement?)?
    var onMove: ((String, CGPoint, Bool) -> Void)?     // id, new centre, finished
    var onScale: ((String, Double, Bool) -> Void)?     // id, new scale, finished
    var onOpacity: ((String, Double) -> Void)?
    var onToggleHidden: ((String) -> Void)?
    var onReset: (() -> Void)?
    var onDone: (() -> Void)?

    private let toolbar = UIStackView()
    private let hintLabel = UILabel()
    private let inspector = UIView()
    private let inspectorTitle = UILabel()
    private let sizeSlider = UISlider()
    private let opacitySlider = UISlider()
    private let hideButton = UIButton(type: .system)
    private let selectionLayer = CAShapeLayer()
    private var outlineLayers: [CAShapeLayer] = []

    private var selectedId: String?
    private var dragStartCenter: CGPoint = .zero
    private var pinchStartScale: Double = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0, alpha: 0.25)

        // Toolbar: Done / Reset
        let done = makeToolbarButton("Xong", filled: true) { [weak self] in self?.onDone?() }
        let reset = makeToolbarButton("Đặt lại mặc định", filled: false) { [weak self] in
            self?.select(nil)
            self?.onReset?()
        }
        toolbar.axis = .horizontal
        toolbar.spacing = 10
        toolbar.addArrangedSubview(reset)
        toolbar.addArrangedSubview(done)
        addSubview(toolbar)

        hintLabel.text = "Kéo phím để di chuyển · Chụm 2 ngón để đổi cỡ · Chạm 1 phím để chỉnh chi tiết"
        hintLabel.textColor = .white
        hintLabel.font = .systemFont(ofSize: 14, weight: .medium)
        hintLabel.numberOfLines = 0
        hintLabel.textAlignment = .center
        hintLabel.backgroundColor = UIColor(white: 0, alpha: 0.6)
        hintLabel.layer.cornerRadius = 10
        hintLabel.clipsToBounds = true
        addSubview(hintLabel)

        setupInspector()

        selectionLayer.strokeColor = UIColor.systemYellow.cgColor
        selectionLayer.fillColor = UIColor.clear.cgColor
        selectionLayer.lineWidth = 3
        layer.addSublayer(selectionLayer)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        for g in [pan, pinch, tap] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeToolbarButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> UIButton {
        var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        config.title = title
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18)
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        return button
    }

    private func setupInspector() {
        inspector.backgroundColor = UIColor(white: 0.08, alpha: 0.92)
        inspector.layer.cornerRadius = 16
        inspector.layer.borderColor = UIColor(white: 1, alpha: 0.2).cgColor
        inspector.layer.borderWidth = 1
        inspector.isHidden = true
        addSubview(inspector)

        inspectorTitle.textColor = .white
        inspectorTitle.font = .systemFont(ofSize: 16, weight: .semibold)

        let sizeLabel = UILabel()
        sizeLabel.text = "Cỡ"
        let opacityLabel = UILabel()
        opacityLabel.text = "Độ đậm"
        for l in [sizeLabel, opacityLabel] {
            l.textColor = UIColor(white: 1, alpha: 0.8)
            l.font = .systemFont(ofSize: 14)
            l.setContentHuggingPriority(.required, for: .horizontal)
        }
        sizeSlider.minimumValue = 0.5
        sizeSlider.maximumValue = 2.5
        sizeSlider.addTarget(self, action: #selector(sizeChanged(_:)), for: .valueChanged)
        sizeSlider.addTarget(self, action: #selector(sizeFinished(_:)), for: [.touchUpInside, .touchUpOutside])
        opacitySlider.minimumValue = 0.2
        opacitySlider.maximumValue = 1.0
        opacitySlider.addTarget(self, action: #selector(opacityChanged(_:)), for: .valueChanged)

        var hideConfig = UIButton.Configuration.tinted()
        hideConfig.cornerStyle = .medium
        hideButton.configuration = hideConfig
        hideButton.addTarget(self, action: #selector(hideTapped), for: .touchUpInside)

        let sizeRow = UIStackView(arrangedSubviews: [sizeLabel, sizeSlider])
        let opacityRow = UIStackView(arrangedSubviews: [opacityLabel, opacitySlider])
        for row in [sizeRow, opacityRow] { row.spacing = 10; row.alignment = .center }
        let stack = UIStackView(arrangedSubviews: [inspectorTitle, sizeRow, opacityRow, hideButton])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: inspector.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: inspector.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: inspector.bottomAnchor, constant: -14),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let safe = safeAreaLayoutGuide.layoutFrame
        let tbSize = toolbar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        toolbar.frame = CGRect(x: safe.midX - tbSize.width / 2, y: safe.minY + 10, width: tbSize.width, height: tbSize.height)
        let hintW = min(safe.width - 40, 560)
        let hintH = hintLabel.sizeThatFits(CGSize(width: hintW - 20, height: 200)).height + 14
        hintLabel.frame = CGRect(x: safe.midX - hintW / 2, y: toolbar.frame.maxY + 8, width: hintW, height: hintH)
        let inspW = min(safe.width - 40, 340)
        let inspH = inspector.systemLayoutSizeFitting(CGSize(width: inspW, height: 0),
                                                      withHorizontalFittingPriority: .required,
                                                      verticalFittingPriority: .fittingSizeLevel).height
        inspector.frame = CGRect(x: safe.midX - inspW / 2, y: hintLabel.frame.maxY + 10, width: inspW, height: inspH)
        refreshOutlines()
    }

    // MARK: - Outlines

    func refreshOutlines() {
        outlineLayers.forEach { $0.removeFromSuperlayer() }
        outlineLayers = items.map { item in
            let l = CAShapeLayer()
            l.path = UIBezierPath(roundedRect: item.view.frame.insetBy(dx: -3, dy: -3), cornerRadius: 10).cgPath
            l.strokeColor = UIColor(white: 1, alpha: 0.8).cgColor
            l.fillColor = UIColor.clear.cgColor
            l.lineDashPattern = [6, 4]
            l.lineWidth = 1.5
            layer.insertSublayer(l, below: selectionLayer)
            return l
        }
        if let id = selectedId, let item = items.first(where: { $0.id == id }) {
            selectionLayer.path = UIBezierPath(roundedRect: item.view.frame.insetBy(dx: -5, dy: -5), cornerRadius: 12).cgPath
        } else {
            selectionLayer.path = nil
        }
    }

    // MARK: - Selection / inspector

    private func item(at point: CGPoint) -> Item? {
        items.last { $0.view.frame.insetBy(dx: -8, dy: -8).contains(point) }
    }

    private func select(_ id: String?) {
        selectedId = id
        guard let id, let item = items.first(where: { $0.id == id }) else {
            inspector.isHidden = true
            refreshOutlines()
            return
        }
        let p = placementFor?(id)
        inspectorTitle.text = item.name
        sizeSlider.value = Float(p?.scale ?? 1)
        opacitySlider.value = Float(p?.opacity ?? 1)
        updateHideButton(hidden: p?.hidden ?? false)
        inspector.isHidden = false
        bringSubviewToFront(inspector)
        setNeedsLayout()
        refreshOutlines()
    }

    private func updateHideButton(hidden: Bool) {
        var config = hideButton.configuration ?? UIButton.Configuration.tinted()
        config.title = hidden ? "Hiện lại phím này" : "Ẩn phím này"
        config.image = UIImage(systemName: hidden ? "eye" : "eye.slash")
        config.imagePadding = 6
        config.baseForegroundColor = hidden ? .systemGreen : .systemRed
        hideButton.configuration = config
    }

    @objc private func sizeChanged(_ s: UISlider) {
        guard let id = selectedId else { return }
        onScale?(id, Double(s.value), false)
        refreshOutlines()
    }

    @objc private func sizeFinished(_ s: UISlider) {
        guard let id = selectedId else { return }
        onScale?(id, Double(s.value), true)
        refreshOutlines()
    }

    @objc private func opacityChanged(_ s: UISlider) {
        guard let id = selectedId else { return }
        onOpacity?(id, Double(s.value))
    }

    @objc private func hideTapped() {
        guard let id = selectedId else { return }
        onToggleHidden?(id)
        updateHideButton(hidden: placementFor?(id)?.hidden ?? false)
    }

    // MARK: - Gestures

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Let the toolbar, hint and inspector controls work normally
        guard let v = touch.view else { return true }
        return !(v.isDescendant(of: toolbar) || v.isDescendant(of: inspector))
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
            || (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        select(item(at: g.location(in: self))?.id)
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            guard let hit = item(at: g.location(in: self)) else { return }
            if selectedId != hit.id { select(hit.id) }
            dragStartCenter = hit.view.center
        case .changed, .ended:
            guard let id = selectedId else { return }
            let t = g.translation(in: self)
            let c = CGPoint(x: dragStartCenter.x + t.x, y: dragStartCenter.y + t.y)
            onMove?(id, c, g.state == .ended)
            refreshOutlines()
        default:
            break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            guard let hit = item(at: g.location(in: self)) else { return }
            if selectedId != hit.id { select(hit.id) }
            pinchStartScale = placementFor?(hit.id)?.scale ?? 1
        case .changed, .ended:
            guard let id = selectedId else { return }
            let s = min(2.5, max(0.5, pinchStartScale * Double(g.scale)))
            sizeSlider.value = Float(s)
            onScale?(id, s, g.state == .ended)
            refreshOutlines()
        default:
            break
        }
    }
}
