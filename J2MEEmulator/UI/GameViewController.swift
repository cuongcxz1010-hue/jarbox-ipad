//
//  GameViewController.swift
//  J2MEEmulator
//
//  Runs a single J2ME MIDlet. Presented modally with zoom transition.
//  Layout mode determines the arrangement of screen and controls.
//

import UIKit

// MARK: - Layout mode (extensible for future layouts)

enum GameLayoutMode {
    case ngage      // Landscape: D-pad left, screen center, numpad right;
                    // Portrait: screen top, controls bottom (see Layout)
}

/// Per-game screen orientation: follow the device, or stay landscape / portrait.
enum GameOrientation: String {
    case auto, landscape, portrait

    private static func key(forJar path: String) -> String {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return "orient_" + name.replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
    }

    static func saved(forJar path: String) -> GameOrientation {
        GameOrientation(rawValue: UserDefaults.standard.string(forKey: key(forJar: path)) ?? "") ?? .auto
    }

    static func save(_ value: GameOrientation, forJar path: String) {
        UserDefaults.standard.set(value.rawValue, forKey: key(forJar: path))
    }
}

// MARK: - GameViewController

class GameViewController: UIViewController {

    let jarPath: String
    let appName: String
    let appIcon: UIImage
    let canvasWidth: Int
    let canvasHeight: Int
    let render3dScale: Int
    let fpsLimit: Int
    let layoutMode: GameLayoutMode

    private let emulatorView = EmulatorView()
    private let glowContainer = UIView()
    private let glowContentView = UIView()
    private lazy var formView = FormView()
    private lazy var listView = J2MEListView()
    private let backButton = UIButton(type: .system)
    private let lskButton = UIButton(type: .system)
    private let rskButton = UIButton(type: .system)
    private let softKeyHaptic = UIImpactFeedbackGenerator(style: .light)
    private(set) var placeholderIconView: UIImageView?

    // Controls — created based on layoutMode
    private var joystickView: JoystickView?
    private var numpadView: NumpadView?

    init(jarPath: String, appName: String, appIcon: UIImage,
         canvasWidth: Int = 240, canvasHeight: Int = 320,
         render3dScale: Int = 3, fpsLimit: Int = 0,
         layoutMode: GameLayoutMode = .ngage) {
        self.jarPath = jarPath
        self.appName = appName
        self.appIcon = appIcon
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.render3dScale = render3dScale
        self.fpsLimit = fpsLimit
        self.layoutMode = layoutMode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        setGlobalEmulatorView(nil)
        alertTimeoutWork?.cancel()
    }

    private var alertTimeoutWork: DispatchWorkItem?

    // Launch-failure detection
    private var didShowContent = false
    private var userRequestedExit = false
    private var logOffset = 0
    private var startedAt = Date()

    private lazy var orientationPref: GameOrientation = GameOrientation.saved(forJar: jarPath)

    override var prefersStatusBarHidden: Bool { true }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        switch orientationPref {
        case .landscape: return .landscape
        case .portrait:  return .portrait
        case .auto:      return UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
        }
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        switch orientationPref {
        case .landscape: return .landscapeRight
        case .portrait:  return .portrait
        case .auto:      return super.preferredInterfaceOrientationForPresentation
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        emulatorView.canvasWidth = canvasWidth
        emulatorView.canvasHeight = canvasHeight

        switch layoutMode {
        case .ngage: setupNGageLayout()
        }

        // Placeholder icon — visible until first game frame
        let iconIV = UIImageView(image: appIcon)
        iconIV.contentMode = .center
        iconIV.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(iconIV)
        NSLayoutConstraint.activate([
            iconIV.centerXAnchor.constraint(equalTo: emulatorView.centerXAnchor),
            iconIV.centerYAnchor.constraint(equalTo: emulatorView.centerYAnchor),
        ])
        placeholderIconView = iconIV
        view.bringSubviewToFront(backButton)

        // Fade out placeholder on first rendered frame
        emulatorView.onFirstFrame = { [weak self] in
            self?.didShowContent = true
            guard let icon = self?.placeholderIconView else { return }
            UIView.animate(withDuration: 0.2) {
                icon.alpha = 0
            } completion: { _ in
                icon.removeFromSuperview()
                self?.placeholderIconView = nil
            }
        }

        // Mirror game frames to glow layer
        emulatorView.onFrame = { [weak self] cgImage in
            self?.glowContentView.layer.contents = cgImage
        }

        // Register native callbacks
        setGlobalEmulatorView(emulatorView)
        j2me_render_set_flush_callback(flushCallback)
        j2me_ui_set_callback(gameUICallback)
        activeGameViewController = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()   // hardware keyboard → game keys
        startGame()
    }

    // ============================================================
    // MARK: - Layout
    // ============================================================
    //
    //  Landscape (device held sideways)         Portrait (device upright)
    //  ┌────────────────────────────────────┐   ┌───────────────────┐
    //  │ [X]                       [⟳] [⌨]  │   │ [X]       [⟳] [⌨] │
    //  │          ┌────────────┐            │   │ ┌───────────────┐ │
    //  │  ╭───╮   │            │  [1][2][3] │   │ │  J2ME screen  │ │
    //  │  │ ○ │   │ J2ME screen│  [4][5][6] │   │ └───────────────┘ │
    //  │  ╰───╯   │            │  [7][8][9] │   │ [L]           [R] │
    //  │          │            │  [*][0][#] │   │  ╭───╮  [1][2][3] │
    //  │       [L]└────────────┘[R]         │   │  │ ○ │  [4][5][6] │
    //  └────────────────────────────────────┘   │  ╰───╯  [7][8][9] │
    //                                           │         [*][0][#] │
    //  The layout follows the device; ⟳ locks   └───────────────────┘
    //  the other orientation (saved per game).

    private let rotateButton = UIButton(type: .system)
    private let keyboardButton = UIButton(type: .system)
    private let keyInputView = KeyInputView()
    private var textBoxDelegate: J2METextFieldDelegate?

    private let leftArea = UILayoutGuide()
    private let rightArea = UILayoutGuide()
    private let controlsArea = UILayoutGuide()
    private var modeConstraints: [NSLayoutConstraint] = []
    private var isPortraitLayout: Bool?

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func setupNGageLayout() {
        let joystick = JoystickView()
        let numpad = NumpadView()
        self.joystickView = joystick
        self.numpadView = numpad

        // Glow: container with game content mirror + NeutralBlurView on top
        glowContainer.isUserInteractionEnabled = false
        glowContainer.clipsToBounds = true

        glowContentView.layer.magnificationFilter = .trilinear
        glowContentView.layer.minificationFilter = .trilinear
        glowContentView.alpha = 0.6
        glowContainer.addSubview(glowContentView)

        glowContentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glowContentView.topAnchor.constraint(equalTo: glowContainer.topAnchor),
            glowContentView.leadingAnchor.constraint(equalTo: glowContainer.leadingAnchor),
            glowContentView.trailingAnchor.constraint(equalTo: glowContainer.trailingAnchor),
            glowContentView.bottomAnchor.constraint(equalTo: glowContainer.bottomAnchor),
        ])

        // Full-screen blur over the glow (no hard edge)
        let glowBlur = NeutralBlurView(radius: 100)
        glowBlur.isUserInteractionEnabled = false

        for v: UIView in [glowContainer, glowBlur, joystick, emulatorView, numpad, lskButton, rskButton,
                          formView, listView, keyInputView, backButton, rotateButton, keyboardButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        formView.isHidden = true
        listView.isHidden = true

        // Soft keys
        for (btn, title) in [(lskButton, "L"), (rskButton, "R")] {
            btn.setTitle(title, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
            btn.setTitleColor(.white, for: .normal)
            btn.backgroundColor = UIColor(white: 0.12, alpha: 1)
            btn.layer.cornerRadius = 10
            btn.layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
            btn.layer.borderWidth = 1
            btn.addTarget(self, action: #selector(softKeyDown(_:)), for: .touchDown)
            btn.addTarget(self, action: #selector(softKeyUp(_:)),
                          for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }
        lskButton.tag = -6
        rskButton.tag = -7

        // Top buttons: close, rotate, keyboard
        styleTopButton(backButton, symbol: "xmark", label: "Thoát game")
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        styleTopButton(rotateButton, symbol: "rotate.right", label: "Xoay màn hình")
        rotateButton.addTarget(self, action: #selector(rotateTapped), for: .touchUpInside)
        styleTopButton(keyboardButton, symbol: "keyboard", label: "Bàn phím")
        keyboardButton.addTarget(self, action: #selector(keyboardTapped), for: .touchUpInside)

        // iOS keyboard → J2ME key presses (character code, -8 delete, -5 fire)
        keyInputView.onCharacter = { code in
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), code)
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), code)
        }
        keyInputView.onDelete = {
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), -8)
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), -8)
        }
        keyInputView.onReturn = { [weak self] in
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), -5)
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), -5)
            self?.keyInputView.resignFirstResponder()
            self?.updateKeyboardButton()
        }

        // Game screen rounded corners + border
        emulatorView.layer.cornerRadius = 8
        emulatorView.clipsToBounds = true
        emulatorView.layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
        emulatorView.layer.borderWidth = 1

        view.addLayoutGuide(leftArea)
        view.addLayoutGuide(rightArea)
        view.addLayoutGuide(controlsArea)

        let canvasRatio = CGFloat(emulatorView.canvasWidth) / CGFloat(emulatorView.canvasHeight)
        let safe = view.safeAreaLayoutGuide

        // Constraints shared by both orientations
        NSLayoutConstraint.activate([
            glowContainer.centerXAnchor.constraint(equalTo: emulatorView.centerXAnchor),
            glowContainer.centerYAnchor.constraint(equalTo: emulatorView.centerYAnchor),
            glowContainer.widthAnchor.constraint(equalTo: emulatorView.widthAnchor),
            glowContainer.heightAnchor.constraint(equalTo: emulatorView.heightAnchor),

            glowBlur.topAnchor.constraint(equalTo: view.topAnchor),
            glowBlur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            glowBlur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            glowBlur.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emulatorView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emulatorView.widthAnchor.constraint(equalTo: emulatorView.heightAnchor, multiplier: canvasRatio),

            joystick.heightAnchor.constraint(equalTo: joystick.widthAnchor),
            numpad.widthAnchor.constraint(equalTo: joystick.widthAnchor),
            numpad.heightAnchor.constraint(equalTo: numpad.widthAnchor, multiplier: 1.33),

            lskButton.widthAnchor.constraint(equalToConstant: 68),
            lskButton.heightAnchor.constraint(equalToConstant: 40),
            rskButton.widthAnchor.constraint(equalToConstant: 68),
            rskButton.heightAnchor.constraint(equalToConstant: 40),

            formView.topAnchor.constraint(equalTo: view.topAnchor),
            formView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            formView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            formView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            listView.topAnchor.constraint(equalTo: view.topAnchor),
            listView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            backButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 6),
            backButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 6),
            keyboardButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 6),
            keyboardButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -6),
            rotateButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 6),
            rotateButton.trailingAnchor.constraint(equalTo: keyboardButton.leadingAnchor, constant: -8),

            keyInputView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyInputView.topAnchor.constraint(equalTo: view.topAnchor),
            keyInputView.widthAnchor.constraint(equalToConstant: 1),
            keyInputView.heightAnchor.constraint(equalToConstant: 1),
        ])

        view.bringSubviewToFront(formView)
        view.bringSubviewToFront(listView)
        for b in [backButton, rotateButton, keyboardButton] { view.bringSubviewToFront(b) }

        applyLayout(portrait: view.bounds.height > view.bounds.width)
    }

    private func styleTopButton(_ button: UIButton, symbol: String, label: String) {
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        button.setTitle(nil, for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor(white: 0.15, alpha: 0.85)
        button.layer.cornerRadius = 10
        button.layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
        button.layer.borderWidth = 1
        button.accessibilityLabel = label
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 46),
            button.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        guard joystickView != nil, view.bounds.width > 0 else { return }
        let portrait = view.bounds.height > view.bounds.width
        if portrait != isPortraitLayout { applyLayout(portrait: portrait) }
    }

    private func applyLayout(portrait: Bool) {
        isPortraitLayout = portrait
        NSLayoutConstraint.deactivate(modeConstraints)
        modeConstraints = portrait ? portraitConstraints() : landscapeConstraints()
        NSLayoutConstraint.activate(modeConstraints)
    }

    /// Screen in the middle, joystick left, numpad right — all vertically centred.
    private func landscapeConstraints() -> [NSLayoutConstraint] {
        guard let joystick = joystickView, let numpad = numpadView else { return [] }
        let pad: CGFloat = 8
        let gap: CGFloat = 14
        let safe = view.safeAreaLayoutGuide

        // As tall as possible, but at most about half the width so the side panels fit the controls
        let fillHeight = emulatorView.heightAnchor.constraint(equalTo: safe.heightAnchor, constant: -2 * pad)
        fillHeight.priority = .defaultHigh
        let controlSize = joystick.widthAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.42)
        controlSize.priority = .defaultHigh

        return [
            emulatorView.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
            emulatorView.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: pad),
            emulatorView.bottomAnchor.constraint(lessThanOrEqualTo: safe.bottomAnchor, constant: -pad),
            emulatorView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: isPad ? 0.52 : 0.6),
            fillHeight,

            leftArea.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            leftArea.trailingAnchor.constraint(equalTo: emulatorView.leadingAnchor),
            leftArea.topAnchor.constraint(equalTo: safe.topAnchor),
            leftArea.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            rightArea.leadingAnchor.constraint(equalTo: emulatorView.trailingAnchor),
            rightArea.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            rightArea.topAnchor.constraint(equalTo: safe.topAnchor),
            rightArea.bottomAnchor.constraint(equalTo: safe.bottomAnchor),

            joystick.centerXAnchor.constraint(equalTo: leftArea.centerXAnchor),
            joystick.centerYAnchor.constraint(equalTo: leftArea.centerYAnchor),
            numpad.centerXAnchor.constraint(equalTo: rightArea.centerXAnchor),
            numpad.centerYAnchor.constraint(equalTo: rightArea.centerYAnchor),
            controlSize,
            joystick.widthAnchor.constraint(lessThanOrEqualTo: leftArea.widthAnchor, constant: -2 * gap),
            numpad.widthAnchor.constraint(lessThanOrEqualTo: rightArea.widthAnchor, constant: -2 * gap),
            // leave room above/below the numpad for the top buttons and the soft keys
            numpad.heightAnchor.constraint(lessThanOrEqualTo: safe.heightAnchor, constant: -120),

            lskButton.trailingAnchor.constraint(equalTo: emulatorView.leadingAnchor, constant: -6),
            lskButton.bottomAnchor.constraint(equalTo: emulatorView.bottomAnchor),
            rskButton.leadingAnchor.constraint(equalTo: emulatorView.trailingAnchor, constant: 6),
            rskButton.bottomAnchor.constraint(equalTo: emulatorView.bottomAnchor),
        ]
    }

    /// Screen on top, soft keys under it, joystick + numpad at the bottom.
    private func portraitConstraints() -> [NSLayoutConstraint] {
        guard let joystick = joystickView, let numpad = numpadView else { return [] }
        let pad: CGFloat = 8
        let gap: CGFloat = 18
        let topBar: CGFloat = 54
        let safe = view.safeAreaLayoutGuide

        // As wide as possible, but keep at least ~40% of the height for the controls
        let fillWidth = emulatorView.widthAnchor.constraint(equalTo: safe.widthAnchor, constant: -2 * pad)
        fillWidth.priority = .defaultHigh
        let controlSize = joystick.widthAnchor.constraint(equalTo: controlsArea.widthAnchor, multiplier: 0.42)
        controlSize.priority = .defaultHigh

        return [
            emulatorView.topAnchor.constraint(equalTo: safe.topAnchor, constant: topBar),
            emulatorView.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, constant: -2 * pad),
            emulatorView.heightAnchor.constraint(lessThanOrEqualTo: safe.heightAnchor, multiplier: 0.58),
            fillWidth,

            lskButton.topAnchor.constraint(equalTo: emulatorView.bottomAnchor, constant: 8),
            lskButton.leadingAnchor.constraint(equalTo: emulatorView.leadingAnchor),
            rskButton.topAnchor.constraint(equalTo: emulatorView.bottomAnchor, constant: 8),
            rskButton.trailingAnchor.constraint(equalTo: emulatorView.trailingAnchor),

            controlsArea.topAnchor.constraint(equalTo: lskButton.bottomAnchor, constant: 8),
            controlsArea.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -pad),
            controlsArea.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: gap),
            controlsArea.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -gap),

            joystick.leadingAnchor.constraint(equalTo: controlsArea.leadingAnchor),
            joystick.centerYAnchor.constraint(equalTo: controlsArea.centerYAnchor),
            numpad.trailingAnchor.constraint(equalTo: controlsArea.trailingAnchor),
            numpad.centerYAnchor.constraint(equalTo: controlsArea.centerYAnchor),
            controlSize,
            joystick.widthAnchor.constraint(lessThanOrEqualTo: controlsArea.widthAnchor, multiplier: 0.46),
            numpad.heightAnchor.constraint(lessThanOrEqualTo: controlsArea.heightAnchor),
        ]
    }

    // MARK: - Rotate / keyboard buttons

    @objc private func rotateTapped() {
        let toPortrait = !(isPortraitLayout ?? false)
        orientationPref = toPortrait ? .portrait : .landscape
        GameOrientation.save(orientationPref, forJar: jarPath)
        setNeedsUpdateOfSupportedInterfaceOrientations()
        view.window?.windowScene?.requestGeometryUpdate(
            .iOS(interfaceOrientations: toPortrait ? .portrait : .landscape)) { error in
            print("[Swift] Rotation request failed: \(error.localizedDescription)")
        }
    }

    @objc private func keyboardTapped() {
        if keyInputView.isFirstResponder {
            keyInputView.resignFirstResponder()
        } else {
            keyInputView.becomeFirstResponder()
        }
        updateKeyboardButton()
    }

    private func updateKeyboardButton() {
        keyboardButton.backgroundColor = keyInputView.isFirstResponder
            ? UIColor.systemBlue.withAlphaComponent(0.85)
            : UIColor(white: 0.15, alpha: 0.85)
    }

    // MARK: - Hardware keyboard (iPad Magic Keyboard / Bluetooth)

    override var canBecomeFirstResponder: Bool { true }

    private func j2meKeyCode(for press: UIPress) -> Int32? {
        guard let key = press.key else { return nil }
        let typing = keyInputView.isFirstResponder   // text then arrives via insertText
        switch key.keyCode {
        case .keyboardUpArrow:    return -1
        case .keyboardDownArrow:  return -2
        case .keyboardLeftArrow:  return -3
        case .keyboardRightArrow: return -4
        case .keyboardF1:         return -6
        case .keyboardF2:         return -7
        case .keyboardReturnOrEnter, .keypadEnter: return typing ? nil : -5
        case .keyboardDeleteOrBackspace:           return typing ? nil : -8
        default:
            guard !typing, key.modifierFlags.isDisjoint(with: [.command, .control]) else { return nil }
            let scalars = key.characters.unicodeScalars
            guard scalars.count == 1, let s = scalars.first, s.value >= 32, s.value < 0xF700 else { return nil }
            return Int32(bitPattern: s.value)
        }
    }

    private func postPresses(_ presses: Set<UIPress>, type: Int32) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let code = j2meKeyCode(for: press) {
                j2me_input_post_key(type, code)
            } else {
                unhandled.insert(press)
            }
        }
        return unhandled
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = postPresses(presses, type: Int32(J2ME_INPUT_KEY_PRESSED))
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = postPresses(presses, type: Int32(J2ME_INPUT_KEY_RELEASED))
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = postPresses(presses, type: Int32(J2ME_INPUT_KEY_RELEASED))
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    // MARK: - Soft keys

    @objc private func softKeyDown(_ sender: UIButton) {
        softKeyHaptic.impactOccurred(intensity: 0.6)
        j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), Int32(sender.tag))
        sender.backgroundColor = UIColor(white: 0.30, alpha: 1)
    }

    @objc private func softKeyUp(_ sender: UIButton) {
        j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), Int32(sender.tag))
        sender.backgroundColor = UIColor(white: 0.12, alpha: 1)
    }

    // ============================================================
    // MARK: - Game lifecycle
    // ============================================================

    private func startGame() {
        logOffset = DiagnosticsLog.mark()
        startedAt = Date()
        DiagnosticsLog.markGameRunning(appName)
        print("[Swift] Starting \(appName) (\(URL(fileURLWithPath: jarPath).lastPathComponent)), canvas \(canvasWidth)x\(canvasHeight)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let initResult = self?.runMIDlet() ?? 0
            DispatchQueue.main.async {
                DiagnosticsLog.markGameStopped()
                self?.finishGame(initResult: initResult)
            }
        }
    }

    /// Close the game screen; if the game stopped by itself before showing
    /// anything, tell the user why instead of silently returning to the list.
    private func finishGame(initResult: Int32) {
        let ranFor = Date().timeIntervalSince(startedAt)
        let failed = !userRequestedExit && (initResult != 0 || (!didShowContent && ranFor < 10))
        let details = failed ? DiagnosticsLog.failureSummary(since: logOffset) : ""
        let presenter = presentingViewController
        let name = appName
        print("[Swift] Game ended after \(Int(ranFor))s, init=\(initResult), shown=\(didShowContent), failed=\(failed)")
        dismiss(animated: true) {
            guard failed, let presenter else { return }
            AppsListViewController.presentLaunchFailure(gameName: name, details: details, from: presenter)
        }
    }

    /// Returns 0 when the JVM started (the MIDlet then ran until it exited).
    private func runMIDlet() -> Int32 {
        guard let resRoot = Bundle.main.resourcePath else { return -100 }
        let docs = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()

        // Per-game save directory: Documents/Games Data/{jarFilename}/
        let jarFileName = URL(fileURLWithPath: jarPath).deletingPathExtension().lastPathComponent
        let gameId = jarFileName.replacingOccurrences(of: "[^a-zA-Z0-9._-]",
                                                       with: "_", options: .regularExpression)
        let saveRoot = docs + "/Games Data/" + gameId
        try? FileManager.default.createDirectory(atPath: saveRoot, withIntermediateDirectories: true)

        let initResult = jvm_bridge_init(resRoot, saveRoot, jarPath,
                                         Int32(canvasWidth),
                                         Int32(canvasHeight),
                                         Int32(render3dScale),
                                         Int32(fpsLimit))
        guard initResult == 0 else {
            print("[Swift] ERROR: JVM init failed with code \(initResult)")
            return initResult
        }

        let runResult = jvm_bridge_run_midlet(jarPath)
        print("[Swift] MIDlet run result: \(runResult)")
        jvm_bridge_destroy()
        return 0
    }

    @objc private func backTapped() {
        userRequestedExit = true
        backButton.isEnabled = false
        jvm_bridge_request_stop()
    }

    // ============================================================
    // MARK: - View switching
    // ============================================================

    func showCanvasView() {
        emulatorView.isHidden = false
        joystickView?.isHidden = false
        numpadView?.isHidden = false
        formView.isHidden = true
        listView.isHidden = true
        numpadView?.updateCommands()
        if !keyInputView.isFirstResponder { becomeFirstResponder() }
    }

    /// MIDP TextBox → iOS text-entry dialog with the system keyboard.
    func showTextBox() {
        didShowContent = true
        keyInputView.resignFirstResponder()
        updateKeyboardButton()

        let title = String(cString: j2me_ui_get_form_title())
        let hasField = j2me_ui_get_form_item_count() > 0
        let text = hasField ? String(cString: j2me_ui_get_form_item_text(0)) : ""
        let maxSize = hasField ? Int(j2me_ui_get_form_item_param1(0)) : 0
        let constraints = hasField ? Int(j2me_ui_get_form_item_param2(0)) : 0

        var commands: [(label: String, id: Int32, type: Int32)] = []
        let cmdCount = j2me_ui_get_command_count()
        for i in 0..<cmdCount {
            commands.append((String(cString: j2me_ui_get_command_label(Int32(i))),
                             j2me_ui_get_command_id(Int32(i)),
                             j2me_ui_get_command_type(Int32(i))))
        }
        if commands.isEmpty { commands = [("OK", -1, 4)] }

        let alert = UIAlertController(title: title.isEmpty ? "Nhập" : title, message: nil, preferredStyle: .alert)
        let delegate = J2METextFieldDelegate(maxLength: maxSize)
        textBoxDelegate = delegate
        alert.addTextField { field in
            field.text = text
            field.applyJ2MEConstraints(constraints)
            field.delegate = delegate
        }

        // Store the typed text, then fire the command (Java reads the text first)
        let submit: (Int32) -> Void = { [weak alert] cmdId in
            j2me_ui_set_text_result(0, alert?.textFields?.first?.text ?? "")
            j2me_input_post_key(Int32(J2ME_UI_COMMAND_ACTION), cmdId)
        }

        var usedCancel = false
        var preferred: UIAlertAction?
        var preferredId: Int32?
        for cmd in commands {
            // Command types: 2 = BACK, 3 = CANCEL, 4 = OK (only one cancel-style button allowed)
            let isCancel = (cmd.type == 2 || cmd.type == 3) && !usedCancel
            if isCancel { usedCancel = true }
            let action = UIAlertAction(title: cmd.label, style: isCancel ? .cancel : .default) { _ in
                submit(cmd.id)
            }
            alert.addAction(action)
            if !isCancel && (preferred == nil || cmd.type == 4) {
                preferred = action
                preferredId = cmd.id
            }
        }
        alert.preferredAction = preferred
        if let okId = preferredId {
            delegate.onReturn = { [weak alert] in
                submit(okId)
                alert?.dismiss(animated: true)
            }
        }
        present(alert, animated: true)
    }

    func showFormView() {
        didShowContent = true
        formView.buildFromNativeData()
        formView.isHidden = false
        emulatorView.isHidden = true
        joystickView?.isHidden = true
        numpadView?.isHidden = true
        listView.isHidden = true
    }

    func showListView() {
        didShowContent = true
        listView.buildFromNativeData()
        listView.isHidden = false
        emulatorView.isHidden = true
        joystickView?.isHidden = true
        numpadView?.isHidden = true
        formView.isHidden = true
    }

    func showAlert() {
        didShowContent = true
        let title = String(cString: j2me_ui_get_form_title())
        let text = String(cString: j2me_ui_get_alert_text())

        let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)

        alertTimeoutWork?.cancel()
        alertTimeoutWork = nil

        let cmdCount = j2me_ui_get_command_count()
        if cmdCount == 0 {
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.alertTimeoutWork?.cancel()
                j2me_input_post_key(Int32(J2ME_UI_ALERT_DISMISSED), 0)
            })
        } else {
            for i in 0..<cmdCount {
                let label = String(cString: j2me_ui_get_command_label(Int32(i)))
                let cmdId = j2me_ui_get_command_id(Int32(i))
                alert.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                    self?.alertTimeoutWork?.cancel()
                    j2me_input_post_key(Int32(J2ME_UI_COMMAND_ACTION), cmdId)
                })
            }
        }

        present(alert, animated: true)

        let timeout = j2me_ui_get_alert_timeout()
        if timeout > 0 {
            let work = DispatchWorkItem { [weak alert] in
                alert?.dismiss(animated: true) {
                    j2me_input_post_key(Int32(J2ME_UI_ALERT_DISMISSED), 0)
                }
            }
            alertTimeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(timeout) / 1000.0, execute: work)
        }
    }
}

// MARK: - Game UI callback (global)

private(set) weak var activeGameViewController: GameViewController?

let gameUICallback: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = { action, data in
    DispatchQueue.main.async {
        guard let vc = activeGameViewController else { return }
        switch action {
        case Int32(J2ME_UI_ACTION_SHOW_CANVAS):  vc.showCanvasView()
        case Int32(J2ME_UI_ACTION_SHOW_FORM):    vc.showFormView()
        case Int32(J2ME_UI_ACTION_SHOW_LIST):    vc.showListView()
        case Int32(J2ME_UI_ACTION_SHOW_ALERT):   vc.showAlert()
        case Int32(J2ME_UI_ACTION_SHOW_TEXTBOX): vc.showTextBox()
        default: break
        }
    }
}
