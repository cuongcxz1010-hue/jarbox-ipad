//
//  GameViewController.swift
//  J2MEEmulator
//
//  Runs one J2ME MIDlet in the style of J2ME Loader (Android):
//  the game screen scaled to fit, translucent on-screen keys in the bottom
//  corners (D-pad + OK, soft keys, keypad 1-9 * 0 #) and one Menu button
//  holding every option (typing, show/hide keys, rotation, key size and
//  opacity, resolution, exit).
//
//  Landscape                                   Portrait
//  ┌──────────────────────────────────────┐    ┌──────────────────────┐
//  │              ┌──────────┐    [Menu]  │    │   ┌──────────────┐   │
//  │              │          │            │    │   │  game screen │   │
//  │ [Trái]       │  game    │     [Phải] │    │   └──────────────┘   │
//  │  ╭─────╮     │  screen  │   [1][2][3]│    │ [Trái] [Menu] [Phải] │
//  │  │ ◀OK▶│     │          │   [4][5][6]│    │  ╭─────╮   [1][2][3] │
//  │  ╰─────╯     │          │   [7][8][9]│    │  │ ◀OK▶│   [4][5][6] │
//  │              └──────────┘   [*][0][#]│    │  ╰─────╯   [7][8][9] │
//  └──────────────────────────────────────┘    └──────────────────────┘
//

import UIKit

class GameViewController: UIViewController {

    let jarPath: String
    let appName: String
    let appIcon: UIImage
    let canvasWidth: Int
    let canvasHeight: Int
    let render3dScale: Int
    let fpsLimit: Int
    private let settings: GameSettings

    private let emulatorView = EmulatorView()
    private let glowContainer = UIView()
    private let glowContentView = UIView()
    private let glowBlur = NeutralBlurView(radius: 100)
    private lazy var formView = FormView()
    private lazy var listView = J2MEListView()
    private(set) var placeholderIconView: UIImageView?

    // On-screen keys
    private let dpad = DPadView()
    private let keypad = KeypadView()
    private let softLeftKey = VirtualKeyButton(title: "Trái", subtitle: "phím mềm", codes: [J2MEKey.softLeft])
    private let softRightKey = VirtualKeyButton(title: "Phải", subtitle: "phím mềm", codes: [J2MEKey.softRight])
    private let menuButton = UIButton(type: .system)
    private let keyInputView = KeyInputView()
    private var textBoxDelegate: J2METextFieldDelegate?

    private var showingNativeScreen = false          // a Form or List is shown instead of the canvas
    private var canvasCommands: [(label: String, id: Int32)] = []
    private var alertTimeoutWork: DispatchWorkItem?

    // Launch-failure detection / restart
    private var didShowContent = false
    private var userRequestedExit = false
    private var restartRequested = false
    private var logOffset = 0
    private var startedAt = Date()

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    init(jarPath: String, appName: String, appIcon: UIImage,
         canvasWidth: Int = 240, canvasHeight: Int = 320,
         render3dScale: Int = 3, fpsLimit: Int = 0) {
        self.jarPath = jarPath
        self.appName = appName
        self.appIcon = appIcon
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.render3dScale = render3dScale
        self.fpsLimit = fpsLimit
        self.settings = GameSettings(jarPath: jarPath)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A game screen configured from the game's saved settings.
    static func make(jarPath: String, appName: String, appIcon: UIImage) -> GameViewController {
        let s = GameSettings(jarPath: jarPath)
        let res = s.resolution
        return GameViewController(jarPath: jarPath, appName: appName, appIcon: appIcon,
                                  canvasWidth: res.w, canvasHeight: res.h,
                                  render3dScale: s.supersampling3D ? 3 : 1, fpsLimit: s.fpsLimit)
    }

    deinit {
        setGlobalEmulatorView(nil)
        alertTimeoutWork?.cancel()
    }

    // MARK: - Appearance & orientation

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        switch settings.orientation {
        case .landscape: return .landscape
        case .portrait:  return .portrait
        case .auto:      return isPad ? .all : .allButUpsideDown
        }
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        switch settings.orientation {
        case .landscape: return .landscapeRight
        case .portrait:  return .portrait
        case .auto:      return super.preferredInterfaceOrientationForPresentation
        }
    }

    // MARK: - Setup

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        emulatorView.canvasWidth = canvasWidth
        emulatorView.canvasHeight = canvasHeight
        emulatorView.layer.cornerRadius = 4
        emulatorView.clipsToBounds = true

        // Soft glow of the game picture behind the screen
        glowContainer.isUserInteractionEnabled = false
        glowContainer.clipsToBounds = true
        glowContentView.layer.magnificationFilter = .trilinear
        glowContentView.layer.minificationFilter = .trilinear
        glowContentView.alpha = 0.6
        glowContainer.addSubview(glowContentView)
        glowBlur.isUserInteractionEnabled = false

        for v: UIView in [glowContainer, glowBlur, emulatorView, keyInputView,
                          dpad, keypad, softLeftKey, softRightKey, formView, listView, menuButton] {
            view.addSubview(v)
        }
        formView.isHidden = true
        listView.isHidden = true

        setupMenuButton()
        setupTyping()
        applyKeyOpacity()

        // Placeholder icon — visible until the first game frame
        let iconIV = UIImageView(image: appIcon)
        iconIV.contentMode = .center
        iconIV.sizeToFit()
        view.insertSubview(iconIV, aboveSubview: emulatorView)
        placeholderIconView = iconIV

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

        // Mirror game frames to the glow layer
        emulatorView.onFrame = { [weak self] cgImage in
            self?.glowContentView.layer.contents = cgImage
        }

        // Native callbacks
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

    // MARK: - Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutGame()
    }

    private func layoutGame() {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        guard safe.width > 0, safe.height > 0 else { return }
        let portrait = safe.height > safe.width
        let keysShown = settings.keyboardVisible && !showingNativeScreen

        // Key sizes in points: iPad base, smaller on iPhone, times the user's size choice
        let unit = CGFloat(settings.keyScale) * (isPad ? 1.0 : 0.7)
        let dpadSize = 230 * unit
        let keypadW = 210 * unit, keypadH = 236 * unit
        let softW = 108 * unit, softH = 48 * unit
        let rowGap = 12 * unit
        let margin: CGFloat = isPad ? 20 : 10
        let clusterH = max(dpadSize, keypadH) + rowGap + softH

        // Game screen: scaled to fit — full height in landscape, above the keys in portrait
        var area = safe.insetBy(dx: 4, dy: 4)
        if portrait && keysShown {
            area.size.height = max(safe.height * 0.45, safe.height - clusterH - 2 * margin - 8)
        }
        let cw = CGFloat(canvasWidth), ch = CGFloat(canvasHeight)
        let scale = min(area.width / cw, area.height / ch)
        let size = CGSize(width: floor(cw * scale), height: floor(ch * scale))
        let screen = CGRect(x: round(area.midX - size.width / 2), y: round(area.midY - size.height / 2),
                            width: size.width, height: size.height)
        emulatorView.frame = screen
        glowContainer.frame = screen
        glowContentView.frame = glowContainer.bounds
        glowBlur.frame = view.bounds
        placeholderIconView?.center = CGPoint(x: screen.midX, y: screen.midY)
        formView.frame = view.bounds
        listView.frame = view.bounds
        keyInputView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)

        // Keys in the bottom corners, soft keys on one row above them
        let bottom = safe.maxY - margin
        dpad.frame = CGRect(x: safe.minX + margin, y: bottom - dpadSize, width: dpadSize, height: dpadSize)
        keypad.frame = CGRect(x: safe.maxX - margin - keypadW, y: bottom - keypadH, width: keypadW, height: keypadH)
        let softY = min(dpad.frame.minY, keypad.frame.minY) - rowGap - softH
        softLeftKey.frame = CGRect(x: dpad.frame.minX, y: softY, width: softW, height: softH)
        softRightKey.frame = CGRect(x: keypad.frame.maxX - softW, y: softY, width: softW, height: softH)
        for key: UIView in [dpad, keypad, softLeftKey, softRightKey] { key.isHidden = !keysShown }

        // Menu: centred on the soft-key row in portrait, top-right otherwise
        let menuSize = CGSize(width: 110, height: 44)
        if portrait && keysShown {
            menuButton.frame = CGRect(x: round(safe.midX - menuSize.width / 2), y: softY + (softH - menuSize.height) / 2,
                                      width: menuSize.width, height: menuSize.height)
        } else {
            menuButton.frame = CGRect(x: safe.maxX - menuSize.width - 10, y: safe.minY + 10,
                                      width: menuSize.width, height: menuSize.height)
        }
    }

    private func applyKeyOpacity() {
        let alpha = CGFloat(max(0.3, min(1.0, settings.keyOpacity)))
        for key: UIView in [dpad, keypad, softLeftKey, softRightKey] { key.alpha = alpha }
    }

    // MARK: - Menu

    private func setupMenuButton() {
        var config = UIButton.Configuration.filled()
        config.title = "Menu"
        config.image = UIImage(systemName: "line.3.horizontal")
        config.imagePadding = 6
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor(white: 0, alpha: 0.55)
        config.baseForegroundColor = .white
        config.background.strokeColor = UIColor(white: 1, alpha: 0.6)
        config.background.strokeWidth = 1.5
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var attrs = attrs
            attrs.font = .systemFont(ofSize: 16, weight: .semibold)
            return attrs
        }
        menuButton.configuration = config
        menuButton.accessibilityLabel = "Menu"
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.preferredMenuElementOrder = .fixed
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.menuItems() ?? [])
            },
        ])
    }

    private func menuItems() -> [UIMenuElement] {
        var items: [UIMenuElement] = []

        // Typing & keys
        let typing = UIAction(title: keyInputView.isFirstResponder ? "Ẩn bàn phím gõ chữ" : "Gõ chữ (bàn phím iPad)",
                              image: UIImage(systemName: "keyboard")) { [weak self] _ in
            self?.toggleTyping()
        }
        let keysVisible = settings.keyboardVisible
        let toggleKeys = UIAction(title: keysVisible ? "Ẩn phím điều khiển" : "Hiện phím điều khiển",
                                  image: UIImage(systemName: keysVisible ? "eye.slash" : "gamecontroller")) { [weak self] _ in
            guard let self else { return }
            self.settings.keyboardVisible = !keysVisible
            self.view.setNeedsLayout()
        }
        items.append(UIMenu(options: .displayInline, children: [typing, toggleKeys]))

        // Rotation
        let orientation = settings.orientation
        let rotate = UIMenu(title: "Xoay màn hình", image: UIImage(systemName: "rotate.right"), children: [
            (GameOrientation.auto, "Tự động theo iPad"),
            (GameOrientation.landscape, "Luôn nằm ngang"),
            (GameOrientation.portrait, "Luôn dựng dọc"),
        ].map { value, title in
            UIAction(title: title, state: value == orientation ? .on : .off) { [weak self] _ in
                self?.setOrientation(value)
            }
        })

        // Key size
        let scale = settings.keyScale
        let keySize = UIMenu(title: "Cỡ phím", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"), children: [
            (0.8, "Nhỏ"), (1.0, "Vừa"), (1.2, "Lớn"), (1.4, "Rất lớn"),
        ].map { value, title in
            UIAction(title: title, state: abs(value - scale) < 0.01 ? .on : .off) { [weak self] _ in
                self?.settings.keyScale = value
                self?.view.setNeedsLayout()
            }
        })

        // Key opacity
        let opacity = settings.keyOpacity
        let keyOpacity = UIMenu(title: "Độ đậm của phím", image: UIImage(systemName: "circle.lefthalf.filled"), children: [
            (0.35, "Mờ"), (0.55, "Vừa"), (0.75, "Rõ"), (1.0, "Đậm nhất"),
        ].map { value, title in
            UIAction(title: title, state: abs(value - opacity) < 0.01 ? .on : .off) { [weak self] _ in
                self?.settings.keyOpacity = value
                self?.applyKeyOpacity()
            }
        })

        // Resolution (restarts the game)
        let res = settings.resolution
        let resolution = UIMenu(title: "Độ phân giải game",
                                subtitle: "\(res.w)×\(res.h) · đổi sẽ khởi động lại game",
                                image: UIImage(systemName: "aspectratio"),
                                children: GameSettings.resolutionOptions.map { opt in
            UIAction(title: opt.label, state: (opt.w == res.w && opt.h == res.h) ? .on : .off) { [weak self] _ in
                self?.changeResolution(w: opt.w, h: opt.h)
            }
        })
        items.append(UIMenu(options: .displayInline, children: [rotate, keySize, keyOpacity, resolution]))

        // Commands the game attached to its screen (MIDP Canvas commands)
        if !canvasCommands.isEmpty {
            let commands = canvasCommands.map { cmd in
                UIAction(title: cmd.label) { _ in
                    j2me_input_post_key(Int32(J2ME_UI_COMMAND_ACTION), cmd.id)
                }
            }
            items.append(UIMenu(title: "Lệnh của game", options: .displayInline, children: commands))
        }

        items.append(UIAction(title: "Thoát game", image: UIImage(systemName: "xmark.circle"),
                              attributes: .destructive) { [weak self] _ in
            self?.exitGame()
        })
        return items
    }

    private func setOrientation(_ value: GameOrientation) {
        settings.orientation = value
        setNeedsUpdateOfSupportedInterfaceOrientations()
        guard value != .auto, let scene = view.window?.windowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: value == .portrait ? .portrait : .landscape)) { error in
            print("[Swift] Rotation request failed: \(error.localizedDescription)")
        }
    }

    private func changeResolution(w: Int, h: Int) {
        guard w != canvasWidth || h != canvasHeight else { return }
        settings.resolution = (w, h)
        let alert = UIAlertController(title: "Đổi độ phân giải",
                                      message: "Game sẽ khởi động lại với độ phân giải \(w)×\(h).",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Khởi động lại", style: .default) { [weak self] _ in
            self?.restartRequested = true
            self?.exitGame()
        })
        alert.addAction(UIAlertAction(title: "Để lần sau", style: .cancel))
        present(alert, animated: true)
    }

    private func exitGame() {
        userRequestedExit = true
        menuButton.isEnabled = false
        jvm_bridge_request_stop()
    }

    // MARK: - Typing (iOS keyboard → key presses)

    private func setupTyping() {
        keyInputView.onCharacter = { code in
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), code)
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), code)
        }
        keyInputView.onDelete = {
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), -8)
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), -8)
        }
        keyInputView.onReturn = { [weak self] in
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), J2MEKey.fire)
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), J2MEKey.fire)
            self?.keyInputView.resignFirstResponder()
        }
    }

    private func toggleTyping() {
        if keyInputView.isFirstResponder {
            keyInputView.resignFirstResponder()
        } else {
            keyInputView.becomeFirstResponder()
        }
    }

    // MARK: - Hardware keyboard (Magic Keyboard / Bluetooth)

    override var canBecomeFirstResponder: Bool { true }

    private func j2meKeyCode(for press: UIPress) -> Int32? {
        guard let key = press.key else { return nil }
        let typing = keyInputView.isFirstResponder   // text then arrives via insertText
        switch key.keyCode {
        case .keyboardUpArrow:    return J2MEKey.up
        case .keyboardDownArrow:  return J2MEKey.down
        case .keyboardLeftArrow:  return J2MEKey.left
        case .keyboardRightArrow: return J2MEKey.right
        case .keyboardF1:         return J2MEKey.softLeft
        case .keyboardF2:         return J2MEKey.softRight
        case .keyboardReturnOrEnter, .keypadEnter: return typing ? nil : J2MEKey.fire
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

    /// Close the game screen. Restart it when the resolution was changed; if the
    /// game stopped by itself before showing anything, tell the user why.
    private func finishGame(initResult: Int32) {
        let ranFor = Date().timeIntervalSince(startedAt)
        let presenter = presentingViewController

        if restartRequested, let presenter {
            let next = GameViewController.make(jarPath: jarPath, appName: appName, appIcon: appIcon)
            next.modalPresentationStyle = .fullScreen
            print("[Swift] Restarting \(appName) at \(next.canvasWidth)x\(next.canvasHeight)")
            dismiss(animated: false) {
                presenter.present(next, animated: false)
            }
            return
        }

        let failed = !userRequestedExit && (initResult != 0 || (!didShowContent && ranFor < 10))
        let details = failed ? DiagnosticsLog.failureSummary(since: logOffset) : ""
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

    // ============================================================
    // MARK: - View switching (called from the JVM via gameUICallback)
    // ============================================================

    func showCanvasView() {
        showingNativeScreen = false
        emulatorView.isHidden = false
        formView.isHidden = true
        listView.isHidden = true
        var commands: [(label: String, id: Int32)] = []
        for i in 0..<j2me_ui_get_command_count() {
            commands.append((label: String(cString: j2me_ui_get_command_label(i)), id: j2me_ui_get_command_id(i)))
        }
        canvasCommands = commands
        view.setNeedsLayout()
        if !keyInputView.isFirstResponder { becomeFirstResponder() }
    }

    func showFormView() {
        didShowContent = true
        showingNativeScreen = true
        formView.buildFromNativeData()
        formView.isHidden = false
        emulatorView.isHidden = true
        listView.isHidden = true
        view.setNeedsLayout()
    }

    func showListView() {
        didShowContent = true
        showingNativeScreen = true
        listView.buildFromNativeData()
        listView.isHidden = false
        emulatorView.isHidden = true
        formView.isHidden = true
        view.setNeedsLayout()
    }

    /// MIDP TextBox → iOS text-entry dialog with the system keyboard.
    func showTextBox() {
        didShowContent = true
        keyInputView.resignFirstResponder()

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
