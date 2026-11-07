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
    case ngage      // Landscape: D-pad left, screen center, numpad right
    // Future: .classic   — Portrait: screen top, keyboard bottom
    // Future: .fullscreen — Landscape: screen fills, overlay controls
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

    override var prefersStatusBarHidden: Bool { true }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        switch layoutMode {
        case .ngage: return .landscape
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
        startGame()
    }

    // ============================================================
    // MARK: - N-Gage layout
    // ============================================================
    //
    //  ┌──────────────────────────────────────────────────────┐
    //  │ [X]                                                   │
    //  │  ┌─────────┐  ┌──────────────┐  ┌───────────────┐  │
    //  │  │         │  │              │  │ [LSK]   [RSK] │  │
    //  │  │  ╭───╮  │  │  J2ME Canvas │  │ [1] [2] [3]  │  │
    //  │  │  │ ○ │  │  │   240×320    │  │ [4] [5] [6]  │  │
    //  │  │  ╰───╯  │  │              │  │ [7] [8] [9]  │  │
    //  │  │joystick │  │              │  │ [*] [0] [#]  │  │
    //  │  └─────────┘  └──────────────┘  └───────────────┘  │
    //  └──────────────────────────────────────────────────────┘

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

        // glowContentView fills glowContainer
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

        for v: UIView in [glowContainer, glowBlur, joystick, emulatorView, numpad, lskButton, rskButton, formView, listView, backButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        formView.isHidden = true
        listView.isHidden = true

        // Soft keys — flanking the game screen at bottom
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

        // Back button
        backButton.setTitle("  \u{2715}  ", for: .normal)
        backButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .medium)
        backButton.backgroundColor = UIColor(white: 0.15, alpha: 0.85)
        backButton.setTitleColor(.white, for: .normal)
        backButton.layer.cornerRadius = 10
        backButton.layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
        backButton.layer.borderWidth = 1
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)

        let canvasRatio: CGFloat = CGFloat(emulatorView.canvasWidth) / CGFloat(emulatorView.canvasHeight)
        let pad: CGFloat = 8

        // iPad: the screen is close to 4:3, so a full-height game screen leaves
        // side panels narrower than the joystick/numpad (sized from view height).
        // Cap the game screen width and keep the controls inside their panels.
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let controlGap: CGFloat = 12

        let emulatorTop: NSLayoutConstraint
        let emulatorBottom: NSLayoutConstraint
        if isPad {
            emulatorTop = emulatorView.topAnchor.constraint(
                greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: pad)
            emulatorBottom = emulatorView.bottomAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -pad)
        } else {
            emulatorTop = emulatorView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: pad)
            emulatorBottom = emulatorView.bottomAnchor.constraint(
                equalTo: view.bottomAnchor, constant: -pad)
        }

        let joystickSize = joystick.widthAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.42)
        if isPad { joystickSize.priority = .defaultHigh }

        // Layout guides for centering controls in the side panels
        let leftArea = UILayoutGuide()
        let rightArea = UILayoutGuide()
        view.addLayoutGuide(leftArea)
        view.addLayoutGuide(rightArea)

        if isPad {
            let fillHeight = emulatorView.heightAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.heightAnchor, constant: -2 * pad)
            fillHeight.priority = .defaultHigh
            NSLayoutConstraint.activate([
                emulatorView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
                emulatorView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.5),
                fillHeight,
                joystick.widthAnchor.constraint(lessThanOrEqualTo: leftArea.widthAnchor,
                                                constant: -2 * controlGap),
                numpad.widthAnchor.constraint(lessThanOrEqualTo: rightArea.widthAnchor,
                                              constant: -2 * controlGap),
            ])
        }

        NSLayoutConstraint.activate([
            leftArea.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            leftArea.trailingAnchor.constraint(equalTo: emulatorView.leadingAnchor),

            rightArea.leadingAnchor.constraint(equalTo: emulatorView.trailingAnchor),
            rightArea.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            // Glow content: slightly larger than emulator, sits behind it
            glowContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            glowContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            glowContainer.widthAnchor.constraint(equalTo: emulatorView.widthAnchor),
            glowContainer.heightAnchor.constraint(equalTo: emulatorView.heightAnchor),

            // Blur: full screen (no hard edge at glow boundary)
            glowBlur.topAnchor.constraint(equalTo: view.topAnchor),
            glowBlur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            glowBlur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            glowBlur.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Emulator: centered, aspect ratio, full height with padding
            emulatorView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emulatorTop,
            emulatorBottom,
            emulatorView.widthAnchor.constraint(equalTo: emulatorView.heightAnchor, multiplier: canvasRatio),

            // Joystick: centered horizontally between safe area left and emulator left
            joystick.centerXAnchor.constraint(equalTo: leftArea.centerXAnchor),
            joystick.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 80),
            joystickSize,
            joystick.heightAnchor.constraint(equalTo: joystick.widthAnchor),

            // Numpad: centered in right panel, same width as joystick, top 48pt
            numpad.centerXAnchor.constraint(equalTo: rightArea.centerXAnchor),
            numpad.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 80),
            numpad.widthAnchor.constraint(equalTo: joystick.widthAnchor),
            numpad.heightAnchor.constraint(equalTo: numpad.widthAnchor, multiplier: 1.33),

            // Soft keys: flanking game screen at bottom
            lskButton.trailingAnchor.constraint(equalTo: emulatorView.leadingAnchor, constant: -6),
            lskButton.bottomAnchor.constraint(equalTo: emulatorView.bottomAnchor),
            lskButton.widthAnchor.constraint(equalToConstant: 68),
            lskButton.heightAnchor.constraint(equalToConstant: 40),

            rskButton.leadingAnchor.constraint(equalTo: emulatorView.trailingAnchor, constant: 6),
            rskButton.bottomAnchor.constraint(equalTo: emulatorView.bottomAnchor),
            rskButton.widthAnchor.constraint(equalToConstant: 68),
            rskButton.heightAnchor.constraint(equalToConstant: 40),

            // Form / List: full screen (overlays everything when visible)
            formView.topAnchor.constraint(equalTo: view.topAnchor),
            formView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            formView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            formView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            listView.topAnchor.constraint(equalTo: view.topAnchor),
            listView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Back button: top-left
            backButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            backButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 4),
        ])

        // Game screen rounded corners + border
        emulatorView.layer.cornerRadius = 8
        emulatorView.clipsToBounds = true
        emulatorView.layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
        emulatorView.layer.borderWidth = 1

        view.bringSubviewToFront(formView)
        view.bringSubviewToFront(listView)
        view.bringSubviewToFront(backButton)
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
        default: break
        }
    }
}
