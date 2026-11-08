//
//  GameViewController.swift
//  J2MEEmulator
//
//  Runs one J2ME MIDlet in the style of J2ME Loader (Android):
//  • the game picture scaled to fit (or stretched) — UIKit for speed;
//  • every phone key on screen (D-pad + OK, soft keys, Call, C/Back, End,
//    0-9 * #), each one movable / resizable / fadeable / hideable and saved
//    in per-game control profiles (portrait and landscape separately);
//  • one Menu button for everything: typing, keys, display, idle tools
//    (idle mode, auto-press, keep screen on, background), screenshot,
//    settings (SwiftUI) and help.
//

import SwiftUI
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
    private let profiles: ControlProfileStore

    private let emulatorView = EmulatorView()
    private let glowContainer = UIView()
    private let glowContentView = UIView()
    private let glowBlur = NeutralBlurView(radius: 100)
    private lazy var formView = FormView()
    private lazy var listView = J2MEListView()
    private(set) var placeholderIconView: UIImageView?

    // On-screen controls, keyed by ControlSpec.id
    private var controlViews: [String: UIView] = [:]
    private let menuButton = UIButton(type: .system)
    private let autoPressBadge = UIButton(type: .system)
    private let keyInputView = KeyInputView()
    private var textBoxDelegate: J2METextFieldDelegate?
    private var editor: KeyLayoutEditorView?

    private var showingNativeScreen = false          // a Form or List is shown instead of the canvas
    private var systemKeyboardVisible = false        // iOS keyboard on screen → hide the phone keys
    private var canvasCommands: [(label: String, id: Int32)] = []
    private var alertTimeoutWork: DispatchWorkItem?

    // Idle tools
    private var idleOverlay: IdleOverlayView?
    private var savedBrightness: CGFloat?
    private var idleStartedAt = Date()
    private var idleStatusTimer: Timer?
    private var thermalObserver: NSObjectProtocol?
    private var autoPressTimer: Timer?

    // Launch-failure detection / restart
    private var didShowContent = false
    private var userRequestedExit = false
    private var restartRequested = false
    private var logOffset = 0
    private var startedAt = Date()

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var isPortraitNow: Bool {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        return safe.height > safe.width
    }

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
        let gameSettings = GameSettings(jarPath: jarPath)
        self.settings = gameSettings
        self.profiles = ControlProfileStore(settings: gameSettings)
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
        autoPressTimer?.invalidate()
        idleStatusTimer?.invalidate()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
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

        for v: UIView in [glowContainer, glowBlur, emulatorView, keyInputView] { view.addSubview(v) }

        // Phone keys
        for spec in ControlCatalog.all {
            let control: UIView
            switch spec.kind {
            case .dpad:
                control = DPadView()
            case let .key(code, title, subtitle):
                control = VirtualKeyButton(title: title, subtitle: subtitle, codes: [code])
            }
            controlViews[spec.id] = control
            view.addSubview(control)
        }

        for v: UIView in [formView, listView, autoPressBadge, menuButton] { view.addSubview(v) }
        formView.isHidden = true
        listView.isHidden = true

        setupMenuButton()
        setupAutoPressBadge()
        setupTyping()
        applySettings()

        // Placeholder icon — visible until the first game frame
        let iconIV = UIImageView(image: appIcon)
        iconIV.contentMode = .center
        iconIV.sizeToFit()
        view.insertSubview(iconIV, aboveSubview: emulatorView)
        placeholderIconView = iconIV

        emulatorView.onFirstFrame = { [weak self] in
            self?.didShowContent = true
            self?.showHelpOnFirstRun()
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
            self?.idleOverlay?.setPreview(cgImage)
        }

        // System events
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
        nc.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        // Device getting hot -> lower the frame rate (posted on any thread; handled on main)
        thermalObserver = nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyFpsOverride() }
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

    /// Apply the saved display / control settings to the running screen.
    private func applySettings() {
        emulatorView.stretchToFill = settings.stretchToFill
        emulatorView.smoothScaling = settings.smoothPicture
        virtualKeyHapticsEnabled = settings.keyHaptics
        if SessionKeeper.shared.gameRunning {
            UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        }
        setNeedsUpdateOfSupportedInterfaceOrientations()
        view.setNeedsLayout()
    }

    // MARK: - Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutGame()
    }

    private var keyUnit: CGFloat { CGFloat(profiles.active.scale) * (isPad ? 1.0 : 0.7) }
    private var keyMargin: CGFloat { isPad ? 20 : 10 }

    private func defaultControlFrames() -> [String: CGRect] {
        ControlCatalog.defaultFrames(in: view.safeAreaLayoutGuide.layoutFrame, unit: keyUnit, margin: keyMargin)
    }

    private func layoutGame() {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        guard safe.width > 0, safe.height > 0 else { return }
        let portrait = safe.height > safe.width
        let editing = editor != nil
        let keysShown = (settings.keyboardVisible || editing) && !showingNativeScreen && !systemKeyboardVisible
        let unit = keyUnit
        let margin = keyMargin

        // Game screen — full height in landscape, above the keys in portrait
        var area = safe.insetBy(dx: 4, dy: 4)
        if portrait && keysShown {
            area.size.height = max(safe.height * 0.45,
                                   safe.height - ControlCatalog.defaultClusterHeight(unit: unit) - 2 * margin - 8)
        }
        let screen: CGRect
        if settings.stretchToFill {
            screen = area.integral
        } else {
            let cw = CGFloat(canvasWidth), ch = CGFloat(canvasHeight)
            let scale = min(area.width / cw, area.height / ch)
            let size = CGSize(width: floor(cw * scale), height: floor(ch * scale))
            screen = CGRect(x: round(area.midX - size.width / 2), y: round(area.midY - size.height / 2),
                            width: size.width, height: size.height)
        }
        emulatorView.frame = screen
        glowContainer.frame = screen
        glowContentView.frame = glowContainer.bounds
        glowBlur.frame = view.bounds
        placeholderIconView?.center = CGPoint(x: screen.midX, y: screen.midY)
        formView.frame = view.bounds
        listView.frame = view.bounds
        keyInputView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)

        // Phone keys: default frame, or where the user put them in this profile
        let defaults = ControlCatalog.defaultFrames(in: safe, unit: unit, margin: margin)
        let profileOpacity = profiles.active.opacity
        for spec in ControlCatalog.all {
            guard let control = controlViews[spec.id], let base = defaults[spec.id] else { continue }
            let placement = profiles.placement(spec.id, portrait: portrait)
            control.frame = frame(for: base, placement: placement, safe: safe)
            let hidden = placement?.hidden ?? false
            control.isHidden = !keysShown || (hidden && !editing)
            let alpha = max(0.15, min(1.0, profileOpacity * (placement?.opacity ?? 1)))
            control.alpha = CGFloat(alpha) * (hidden && editing ? 0.35 : 1)
        }

        // Menu: centred on the soft-key row in portrait, top-right otherwise
        let menuSize = CGSize(width: 110, height: 44)
        if portrait && keysShown, let softRow = defaults["softL"] {
            menuButton.frame = CGRect(x: round(safe.midX - menuSize.width / 2), y: softRow.midY - menuSize.height / 2,
                                      width: menuSize.width, height: menuSize.height)
        } else {
            menuButton.frame = CGRect(x: safe.maxX - menuSize.width - 10, y: safe.minY + 10,
                                      width: menuSize.width, height: menuSize.height)
        }
        menuButton.isHidden = editing

        let badgeSize = autoPressBadge.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        autoPressBadge.frame = CGRect(x: safe.minX + 10, y: safe.minY + 10,
                                      width: min(badgeSize.width, safe.width - menuSize.width - 40), height: 40)

        if let editor {
            editor.frame = view.bounds
            editor.refreshOutlines()
        }
        idleOverlay?.frame = view.bounds
    }

    private func frame(for base: CGRect, placement: KeyPlacement?, safe: CGRect) -> CGRect {
        guard let p = placement else { return base }
        let size = CGSize(width: base.width * CGFloat(p.scale), height: base.height * CGFloat(p.scale))
        var c = CGPoint(x: safe.minX + CGFloat(p.x) * safe.width, y: safe.minY + CGFloat(p.y) * safe.height)
        c.x = min(max(c.x, size.width / 2), view.bounds.width - size.width / 2)
        c.y = min(max(c.y, size.height / 2), view.bounds.height - size.height / 2)
        return CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
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
        items.append(UIMenu(options: .displayInline, children: [controlsMenu(), displayMenu(), idleMenu()]))

        let screenshot = UIAction(title: "Chụp màn hình game", image: UIImage(systemName: "camera")) { [weak self] _ in
            self?.shareScreenshot()
        }
        let openSettings = UIAction(title: "Cài đặt game…", image: UIImage(systemName: "gearshape")) { [weak self] _ in
            self?.openSettings()
        }
        let help = UIAction(title: "Hướng dẫn", image: UIImage(systemName: "questionmark.circle")) { [weak self] _ in
            self?.showHelp()
        }
        items.append(UIMenu(options: .displayInline, children: [screenshot, openSettings, help]))

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

    private func controlsMenu() -> UIMenu {
        let edit = UIAction(title: "Kéo thả, đổi cỡ từng phím…", image: UIImage(systemName: "hand.draw")) { [weak self] _ in
            self?.startLayoutEditor()
        }

        var profileItems: [UIMenuElement] = profiles.profiles.indices.map { i in
            UIAction(title: profiles.profiles[i].name, state: i == profiles.activeIndex ? .on : .off) { [weak self] _ in
                self?.profiles.select(i)
                self?.view.setNeedsLayout()
            }
        }
        profileItems.append(UIAction(title: "Tạo hồ sơ mới…", image: UIImage(systemName: "plus")) { [weak self] _ in
            self?.promptProfileName(title: "Hồ sơ phím mới", initial: "Hồ sơ \((self?.profiles.profiles.count ?? 0) + 1)") { name in
                self?.profiles.addCopy(named: name)
                self?.view.setNeedsLayout()
            }
        })
        profileItems.append(UIAction(title: "Đổi tên hồ sơ…", image: UIImage(systemName: "pencil")) { [weak self] _ in
            guard let self else { return }
            self.promptProfileName(title: "Đổi tên hồ sơ", initial: self.profiles.active.name) { name in
                self.profiles.renameActive(name)
            }
        })
        if profiles.profiles.count > 1 {
            profileItems.append(UIAction(title: "Xóa hồ sơ \"\(profiles.active.name)\"", image: UIImage(systemName: "trash"),
                                         attributes: .destructive) { [weak self] _ in
                self?.profiles.removeActive()
                self?.view.setNeedsLayout()
            })
        }
        let profileMenu = UIMenu(title: "Hồ sơ phím", subtitle: profiles.active.name,
                                 image: UIImage(systemName: "person.crop.rectangle.stack"), children: profileItems)

        let scale = profiles.active.scale
        let keySize = UIMenu(title: "Cỡ phím", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"), children: [
            (0.8, "Nhỏ"), (1.0, "Vừa"), (1.2, "Lớn"), (1.4, "Rất lớn"),
        ].map { value, title in
            UIAction(title: title, state: abs(value - scale) < 0.01 ? .on : .off) { [weak self] _ in
                self?.profiles.active.scale = value
                self?.view.setNeedsLayout()
            }
        })

        let opacity = profiles.active.opacity
        let keyOpacity = UIMenu(title: "Độ đậm của phím", image: UIImage(systemName: "circle.lefthalf.filled"), children: [
            (0.35, "Mờ"), (0.55, "Vừa"), (0.75, "Rõ"), (1.0, "Đậm nhất"),
        ].map { value, title in
            UIAction(title: title, state: abs(value - opacity) < 0.01 ? .on : .off) { [weak self] _ in
                self?.profiles.active.opacity = value
                self?.view.setNeedsLayout()
            }
        })

        let haptics = UIAction(title: "Rung khi bấm phím", image: UIImage(systemName: "iphone.radiowaves.left.and.right"),
                               state: settings.keyHaptics ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.settings.keyHaptics = !self.settings.keyHaptics
            self.applySettings()
        }

        return UIMenu(title: "Phím điều khiển", image: UIImage(systemName: "gamecontroller"),
                      children: [edit, profileMenu, keySize, keyOpacity, haptics])
    }

    private func displayMenu() -> UIMenu {
        let orientation = settings.orientation
        let rotate = UIMenu(title: "Xoay màn hình", image: UIImage(systemName: "rotate.right"), children: [
            (GameOrientation.auto, "Tự động theo máy"),
            (GameOrientation.landscape, "Luôn nằm ngang"),
            (GameOrientation.portrait, "Luôn dựng dọc"),
        ].map { value, title in
            UIAction(title: title, state: value == orientation ? .on : .off) { [weak self] _ in
                self?.setOrientation(value)
            }
        })

        let stretch = settings.stretchToFill
        let scaling = UIMenu(title: "Kiểu hiển thị", image: UIImage(systemName: "rectangle.expand.vertical"), children: [
            UIAction(title: "Vừa khít (giữ tỉ lệ)", state: stretch ? .off : .on) { [weak self] _ in
                self?.settings.stretchToFill = false
                self?.applySettings()
            },
            UIAction(title: "Kéo giãn đầy màn hình", state: stretch ? .on : .off) { [weak self] _ in
                self?.settings.stretchToFill = true
                self?.applySettings()
            },
        ])

        let smooth = UIAction(title: "Làm mịn hình", image: UIImage(systemName: "wand.and.stars"),
                              state: settings.smoothPicture ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.settings.smoothPicture = !self.settings.smoothPicture
            self.applySettings()
        }

        let res = settings.resolution
        let resolution = UIMenu(title: "Độ phân giải game",
                                subtitle: "\(res.w)×\(res.h) · đổi sẽ khởi động lại game",
                                image: UIImage(systemName: "aspectratio"),
                                children: GameSettings.resolutionOptions.map { opt in
            UIAction(title: opt.label, state: (opt.w == res.w && opt.h == res.h) ? .on : .off) { [weak self] _ in
                self?.changeResolution(w: opt.w, h: opt.h)
            }
        })

        return UIMenu(title: "Hiển thị", image: UIImage(systemName: "display"),
                      children: [rotate, scaling, smooth, resolution])
    }

    private func idleMenu() -> UIMenu {
        let idle = UIAction(title: "Treo máy ổn định (khuyên dùng)",
                            subtitle: "Màn tối, khóa chạm, giảm FPS, giữ máy luôn mở",
                            image: UIImage(systemName: "moon.zzz.fill")) { [weak self] _ in
            self?.startStableIdle()
        }
        let guide = UIAction(title: "Hướng dẫn treo chắc chắn", subtitle: "Bật Truy cập được hướng dẫn",
                             image: UIImage(systemName: "lock.iphone")) { [weak self] _ in
            self?.showGuidedAccessGuide()
        }
        let currentIdleFps = settings.idleFps
        let idleFpsMenu = UIMenu(title: "FPS khi treo", image: UIImage(systemName: "speedometer"),
                                 children: GameSettings.idleFpsOptions.map { opt in
            UIAction(title: opt.label, state: opt.value == currentIdleFps ? .on : .off) { [weak self] _ in
                self?.settings.idleFps = opt.value
                self?.applyFpsOverride()
            }
        })

        let running = autoPressTimer != nil
        let autoToggle = UIAction(title: running ? "Dừng tự động bấm" : "Bắt đầu tự động bấm",
                                  subtitle: autoPressDescription(),
                                  image: UIImage(systemName: running ? "stop.circle" : "play.circle")) { [weak self] _ in
            self?.toggleAutoPress()
        }
        let currentKey = settings.autoPressCode
        let keyMenu = UIMenu(title: "Phím tự bấm", image: UIImage(systemName: "hand.tap"),
                             children: GameSettings.autoPressKeys.map { key in
            UIAction(title: key.label, state: key.code == currentKey ? .on : .off) { [weak self] _ in
                self?.settings.autoPressCode = key.code
                self?.restartAutoPressIfRunning()
            }
        })
        let currentInterval = settings.autoPressInterval
        let intervalMenu = UIMenu(title: "Chu kỳ tự bấm", image: UIImage(systemName: "timer"),
                                  children: GameSettings.autoPressIntervals.map { s in
            UIAction(title: s < 60 ? "\(s) giây" : "\(s / 60) phút", state: s == currentInterval ? .on : .off) { [weak self] _ in
                self?.settings.autoPressInterval = s
                self?.restartAutoPressIfRunning()
            }
        })

        let keepOn = UIAction(title: "Giữ màn hình luôn sáng", image: UIImage(systemName: "sun.max"),
                              state: settings.keepScreenOn ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.settings.keepScreenOn = !self.settings.keepScreenOn
            self.applySettings()
        }
        let background = UIAction(title: "Giữ chạy nền (thử nghiệm)",
                                  subtitle: "Không đảm bảo — iOS có thể vẫn dừng app",
                                  image: UIImage(systemName: "moon.circle"),
                                  state: SessionKeeper.backgroundAudioEnabled ? .on : .off) { [weak self] _ in
            let enable = !SessionKeeper.backgroundAudioEnabled
            SessionKeeper.shared.setBackgroundAudio(enable)
            if enable { self?.explainBackgroundLimits() }
        }

        return UIMenu(title: "Treo game", image: UIImage(systemName: "hourglass"),
                      children: [idle, guide, idleFpsMenu, autoToggle, keyMenu, intervalMenu, keepOn, background])
    }

    private func promptProfileName(title: String, initial: String, completion: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = initial; $0.clearButtonMode = .whileEditing }
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Lưu", style: .default) { [weak alert] _ in
            let name = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { completion(name) }
        })
        present(alert, animated: true)
    }

    private func setOrientation(_ value: GameOrientation) {
        settings.orientation = value
        requestOrientationUpdate()
    }

    private func requestOrientationUpdate() {
        setNeedsUpdateOfSupportedInterfaceOrientations()
        let value = settings.orientation
        guard value != .auto, let scene = view.window?.windowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: value == .portrait ? .portrait : .landscape)) { error in
            print("[Swift] Rotation request failed: \(error.localizedDescription)")
        }
    }

    private func changeResolution(w: Int, h: Int) {
        settings.resolution = (w, h)
        askRestartForResolution()
    }

    private func askRestartForResolution() {
        let res = settings.resolution
        guard res.w != canvasWidth || res.h != canvasHeight else { return }
        let alert = UIAlertController(title: "Đổi độ phân giải",
                                      message: "Game sẽ khởi động lại với độ phân giải \(res.w)×\(res.h).",
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

    // MARK: - Settings screen (SwiftUI)

    private func openSettings() {
        let settingsView = GameSettingsView(
            gameName: appName, settings: settings, profiles: profiles, inGame: true,
            onChange: { [weak self] in self?.applySettings() },
            onEditLayout: { [weak self] in
                self?.dismiss(animated: true) { self?.startLayoutEditor() }
            },
            onClose: { [weak self] in
                self?.dismiss(animated: true) { self?.settingsClosed() }
            })
        let host = UIHostingController(rootView: settingsView)
        host.modalPresentationStyle = .formSheet
        present(host, animated: true)
    }

    private func settingsClosed() {
        applySettings()
        requestOrientationUpdate()
        askRestartForResolution()
    }

    // MARK: - Layout editor

    private func startLayoutEditor() {
        guard editor == nil else { return }
        keyInputView.resignFirstResponder()
        let ed = KeyLayoutEditorView(frame: view.bounds)
        ed.placementFor = { [weak self] id in self?.currentPlacement(id) }
        ed.onMove = { [weak self] id, center, finished in self?.editorMove(id, center: center, finished: finished) }
        ed.onScale = { [weak self] id, scale, finished in self?.editorScale(id, scale: scale, finished: finished) }
        ed.onOpacity = { [weak self] id, value in self?.editorOpacity(id, value) }
        ed.onToggleHidden = { [weak self] id in self?.editorToggleHidden(id) }
        ed.onReset = { [weak self] in
            guard let self else { return }
            self.profiles.resetPlacements(portrait: self.isPortraitNow)
            self.view.setNeedsLayout()
        }
        ed.onDone = { [weak self] in self?.stopLayoutEditor() }
        view.addSubview(ed)
        editor = ed
        view.setNeedsLayout()
        view.layoutIfNeeded()
        ed.items = ControlCatalog.all.compactMap { spec -> KeyLayoutEditorView.Item? in
            guard let control = controlViews[spec.id] else { return nil }
            return KeyLayoutEditorView.Item(id: spec.id, name: spec.name, view: control)
        }
    }

    private func stopLayoutEditor() {
        editor?.removeFromSuperview()
        editor = nil
        view.setNeedsLayout()
    }

    /// Saved placement, or one describing where the key is now.
    private func currentPlacement(_ id: String) -> KeyPlacement {
        if let p = profiles.placement(id, portrait: isPortraitNow) { return p }
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let c = controlViews[id]?.center ?? CGPoint(x: safe.midX, y: safe.midY)
        return KeyPlacement(x: Double((c.x - safe.minX) / safe.width), y: Double((c.y - safe.minY) / safe.height))
    }

    private func editorMove(_ id: String, center: CGPoint, finished: Bool) {
        guard let control = controlViews[id] else { return }
        let w = control.bounds.width, h = control.bounds.height
        let c = CGPoint(x: min(max(center.x, w / 2), view.bounds.width - w / 2),
                        y: min(max(center.y, h / 2), view.bounds.height - h / 2))
        control.center = c
        guard finished else { return }
        let safe = view.safeAreaLayoutGuide.layoutFrame
        var p = currentPlacement(id)
        p.x = Double((c.x - safe.minX) / safe.width)
        p.y = Double((c.y - safe.minY) / safe.height)
        profiles.setPlacement(p, id, portrait: isPortraitNow)
    }

    private func editorScale(_ id: String, scale: Double, finished: Bool) {
        guard let control = controlViews[id], let base = defaultControlFrames()[id] else { return }
        let c = control.center
        let size = CGSize(width: base.width * CGFloat(scale), height: base.height * CGFloat(scale))
        control.frame = CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
        guard finished else { return }
        var p = currentPlacement(id)
        p.scale = scale
        profiles.setPlacement(p, id, portrait: isPortraitNow)
        view.setNeedsLayout()
    }

    private func editorOpacity(_ id: String, _ value: Double) {
        var p = currentPlacement(id)
        p.opacity = value
        profiles.setPlacement(p, id, portrait: isPortraitNow)
        view.setNeedsLayout()
    }

    private func editorToggleHidden(_ id: String) {
        var p = currentPlacement(id)
        p.hidden.toggle()
        profiles.setPlacement(p, id, portrait: isPortraitNow)
        view.setNeedsLayout()
    }

    // MARK: - Stable idle mode (the most reliable way iOS allows)

    /// Keeps the game in the foreground with auto-lock off, the display dimmed,
    /// touches blocked and a low frame rate; shows status and a live preview.
    private func enterIdleMode() {
        guard idleOverlay == nil else { return }
        keyInputView.resignFirstResponder()
        let overlay = IdleOverlayView(frame: view.bounds)
        overlay.onExit = { [weak self] in self?.exitIdleMode() }
        if let image = emulatorView.currentImage { overlay.setPreview(image) }
        view.addSubview(overlay)
        idleOverlay = overlay
        idleStartedAt = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        dimScreen(true)
        applyFpsOverride()
        updateIdleStatus()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIdleStatus() }
        }
        timer.tolerance = 0.3
        idleStatusTimer = timer
        print("[Swift] Stable idle mode ON (fps cap \(currentFpsCap()))")
    }

    @objc private func exitIdleMode() {
        guard let overlay = idleOverlay else { return }
        overlay.removeFromSuperview()
        idleOverlay = nil
        idleStatusTimer?.invalidate()
        idleStatusTimer = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
        dimScreen(false)
        applyFpsOverride()
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn && SessionKeeper.shared.gameRunning
        print("[Swift] Stable idle mode OFF after \(Int(Date().timeIntervalSince(idleStartedAt))) s")
    }

    private func updateIdleStatus() {
        guard let overlay = idleOverlay else { return }
        let device = UIDevice.current
        overlay.update(IdleOverlayView.Status(
            elapsed: Date().timeIntervalSince(idleStartedAt),
            batteryLevel: device.batteryLevel,
            batteryState: device.batteryState,
            fps: currentFpsCap(),
            thermal: ProcessInfo.processInfo.thermalState,
            autoPress: autoPressTimer != nil ? autoPressDescription() : nil,
            guidedAccess: UIAccessibility.isGuidedAccessEnabled))
    }

    /// Frame-rate cap now (0 = unlimited): idle mode and device temperature
    /// lower it; never above the game's own setting.
    private func currentFpsCap() -> Int {
        var cap: Int?
        if idleOverlay != nil && settings.idleFps > 0 { cap = settings.idleFps }
        switch ProcessInfo.processInfo.thermalState {
        case .serious:  cap = min(cap ?? 15, 15)
        case .critical: cap = min(cap ?? 8, 8)
        default: break
        }
        if let c = cap, fpsLimit > 0 { cap = min(c, fpsLimit) }
        return cap ?? fpsLimit
    }

    private func applyFpsOverride() {
        let cap = currentFpsCap()
        j2me_set_fps_override(Int32(cap == fpsLimit ? -1 : cap))
    }

    /// Menu → Treo máy ổn định: first time without Guided Access, offer the guide.
    private func startStableIdle() {
        let tipKey = "guidedAccessTipShown"
        if UIAccessibility.isGuidedAccessEnabled || UserDefaults.standard.bool(forKey: tipKey) {
            enterIdleMode()
            return
        }
        UserDefaults.standard.set(true, forKey: tipKey)
        showGuidedAccessGuide()
    }

    private func showGuidedAccessGuide() {
        let status = UIAccessibility.isGuidedAccessEnabled ? "đang bật ✓" : "chưa bật"
        let alert = UIAlertController(title: "Treo chắc chắn hơn", message: """
            "Truy cập được hướng dẫn" của iOS giữ iPad luôn ở trong game: không thoát nhầm ra ngoài, không bị khóa màn hình.

            Cài một lần:
            1. Cài đặt → Trợ năng → Truy cập được hướng dẫn → Bật.
            2. Cài đặt mật mã → đặt mật mã.
            3. Tự động khóa màn hình → Không bao giờ.

            Mỗi lần treo:
            4. Trong game: Menu → Treo game → Treo máy ổn định.
            5. Bấm nhanh 3 lần nút nguồn (máy có nút Home: bấm 3 lần nút Home) → Bắt đầu.
            Thoát: bấm 3 lần nút đó → nhập mật mã → Kết thúc.

            Nên: cắm sạc, bật Không làm phiền, để máy chỗ thoáng mát.
            Trạng thái hiện tại: \(status).
            """, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Đóng", style: .cancel))
        alert.addAction(UIAlertAction(title: "Treo ngay", style: .default) { [weak self] _ in
            self?.enterIdleMode()
        })
        present(alert, animated: true)
    }

    private func dimScreen(_ dim: Bool) {
        guard let screen = view.window?.windowScene?.screen else { return }
        if dim {
            if savedBrightness == nil { savedBrightness = screen.brightness }
            screen.brightness = 0.01
        } else if let saved = savedBrightness {
            screen.brightness = saved
            savedBrightness = nil
        }
    }

    private func setupAutoPressBadge() {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor.systemOrange.withAlphaComponent(0.85)
        config.baseForegroundColor = .white
        config.image = UIImage(systemName: "timer")
        config.imagePadding = 6
        config.titleLineBreakMode = .byTruncatingTail
        autoPressBadge.configuration = config
        autoPressBadge.addTarget(self, action: #selector(stopAutoPressTapped), for: .touchUpInside)
        autoPressBadge.isHidden = true
    }

    private func autoPressDescription() -> String {
        let code = settings.autoPressCode
        let key = GameSettings.autoPressKeys.first { $0.code == code }?.label ?? "Phím \(code)"
        let s = settings.autoPressInterval
        return "\(key) · mỗi \(s < 60 ? "\(s) giây" : "\(s / 60) phút")"
    }

    private func toggleAutoPress() {
        if autoPressTimer == nil { startAutoPress() } else { stopAutoPress() }
    }

    private func startAutoPress() {
        stopAutoPress()
        let code = settings.autoPressCode
        let interval = TimeInterval(max(1, settings.autoPressInterval))
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), code)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), code)
            }
        }
        timer.tolerance = 0.1
        autoPressTimer = timer
        autoPressBadge.configuration?.title = "Tự bấm: \(autoPressDescription()) · chạm để dừng"
        autoPressBadge.isHidden = false
        view.setNeedsLayout()
        print("[Swift] Auto-press started: \(autoPressDescription())")
    }

    private func stopAutoPress() {
        autoPressTimer?.invalidate()
        autoPressTimer = nil
        autoPressBadge.isHidden = true
    }

    @objc private func stopAutoPressTapped() {
        stopAutoPress()
    }

    private func restartAutoPressIfRunning() {
        if autoPressTimer != nil { startAutoPress() }
    }

    private func explainBackgroundLimits() {
        let alert = UIAlertController(
            title: "Giữ chạy nền (thử nghiệm)",
            message: """
            Khi bạn thoát ra màn hình chính hoặc khóa máy, app sẽ cố chạy tiếp bằng chế độ âm thanh nền.

            Đây không phải tính năng chắc chắn: iOS vẫn có thể dừng app khi thiếu bộ nhớ, khi có cuộc gọi hoặc sau thời gian dài; tốn pin hơn; App Store không cho phép cách này (bản cài qua Sideloadly thì dùng được).

            Cách treo ổn định nhất: để game mở, bật "Giữ màn hình luôn sáng" và dùng "Treo máy ổn định" (Menu → Treo game).
            """,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Đã hiểu", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Screenshot & help

    private func shareScreenshot() {
        guard let cg = emulatorView.currentImage else { return }
        let factor = max(1, Int(960 / CGFloat(max(cg.width, cg.height))))
        let size = CGSize(width: cg.width * factor, height: cg.height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.interpolationQuality = .none
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
        }
        let share = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        share.popoverPresentationController?.sourceItem = menuButton
        present(share, animated: true)
    }

    private static let helpText = """
    • Vòng tròn bên trái (D-pad): di chuyển, chọn mục, đổi tab. Nút OK ở giữa = chọn / đồng ý. Chạm vào khe giữa 2 mũi tên để đi chéo.
    • "Trái" / "Phải" (phím mềm): bấm theo chữ game hiện ở góc dưới màn hình game (Menu, OK, Quay lại…).
    • Phím số 0–9, *, # như điện thoại; C = xóa/quay lại; Gọi; Tắt.
    • Có thể chạm thẳng vào màn hình game.
    • Ô tài khoản / mật khẩu / chat: chạm vào ô, bàn phím iPad tự hiện.
    • Menu: gõ chữ, ẩn/hiện phím, kéo thả và đổi cỡ từng phím, hồ sơ phím, xoay màn hình, cài đặt.
    • Treo lâu: Menu → Treo game → Treo máy ổn định (màn tối, khóa chạm, giảm FPS).
    """

    private func showHelp() {
        let alert = UIAlertController(title: "Cách điều khiển", message: Self.helpText, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Đã hiểu", style: .default))
        present(alert, animated: true)
    }

    private func showHelpOnFirstRun() {
        let key = "shownControlsHelp_v3"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.presentedViewController == nil else { return }
            self.showHelp()
        }
    }

    // MARK: - Typing (iOS keyboard → key presses)

    private func setupTyping() {
        keyInputView.onCharacter = { code in
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), code)
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), code)
        }
        keyInputView.onDelete = {
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), J2MEKey.clear)
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), J2MEKey.clear)
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

    @objc private func keyboardWillShow() {
        systemKeyboardVisible = true
        view.setNeedsLayout()
    }

    @objc private func keyboardWillHide() {
        systemKeyboardVisible = false
        view.setNeedsLayout()
    }

    @objc private func appWillResignActive() {
        if idleOverlay != nil { dimScreen(false) }   // never leave the device dimmed
    }

    @objc private func appDidBecomeActive() {
        if idleOverlay != nil { dimScreen(true) }
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
        case .keyboardF3:         return J2MEKey.call
        case .keyboardF4:         return J2MEKey.end
        case .keyboardEscape:     return J2MEKey.clear
        case .keyboardReturnOrEnter, .keypadEnter: return typing ? nil : J2MEKey.fire
        case .keyboardDeleteOrBackspace:           return typing ? nil : J2MEKey.clear
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
        SessionKeeper.shared.gameStarted()
        applyFpsOverride()
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
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
        stopAutoPress()
        exitIdleMode()
        SessionKeeper.shared.gameStopped()
        UIApplication.shared.isIdleTimerDisabled = false

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
