//
//  GameSettings.swift
//  J2MEEmulator
//
//  Per-game settings stored in UserDefaults. Keys are "<prefix><gameId>"
//  and stay compatible with earlier versions (resW_, resH_, fpsLimit_, ss3d_).
//

import Foundation

/// How the game picture fills its area.
enum ScaleMode: String, CaseIterable {
    case fit        // as large as possible, proportions kept
    case integer    // whole multiples only (2×, 3×…): sharpest pixels
    case stretch    // fill the area

    var title: String {
        switch self {
        case .fit:     return "Vừa khít (giữ tỉ lệ)"
        case .integer: return "Phóng số nguyên (nét nhất)"
        case .stretch: return "Kéo giãn đầy màn hình"
        }
    }
}

/// Screen orientation for a game: follow the device, or stay landscape / portrait.
enum GameOrientation: String {
    case auto, landscape, portrait

    static func saved(forJar path: String) -> GameOrientation { GameSettings(jarPath: path).orientation }
    static func save(_ value: GameOrientation, forJar path: String) { GameSettings(jarPath: path).orientation = value }
}

/// Phone families with different key codes (see KeyMapper.java).
enum KeyLayout: Int, CaseIterable {
    case nokia = 0, siemens = 1, motorola = 2, samsung = 3, sonyEricsson = 4, nokiaE62 = 5

    var title: String {
        switch self {
        case .nokia:        return "Nokia (mặc định)"
        case .samsung:      return "Samsung"
        case .sonyEricsson: return "Sony Ericsson"
        case .motorola:     return "Motorola"
        case .siemens:      return "Siemens"
        case .nokiaE62:     return "Nokia E62 (QWERTY)"
        }
    }
}

struct GameSettings {
    let id: String

    init(jarPath: String) {
        let name = URL(fileURLWithPath: jarPath).deletingPathExtension().lastPathComponent
        id = name.replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
    }

    private var defaults: UserDefaults { .standard }
    private func int(_ prefix: String, _ fallback: Int) -> Int {
        defaults.object(forKey: prefix + id) as? Int ?? fallback
    }
    private func double(_ prefix: String, _ fallback: Double) -> Double {
        defaults.object(forKey: prefix + id) as? Double ?? fallback
    }
    private func bool(_ prefix: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: prefix + id) as? Bool ?? fallback
    }
    private func store(_ value: Any, _ prefix: String) {
        defaults.set(value, forKey: prefix + id)
    }

    /// J2ME canvas size the game is started with (default 240×320).
    var resolution: (w: Int, h: Int) {
        get { (int("resW_", 240), int("resH_", 320)) }
        nonmutating set { store(newValue.w, "resW_"); store(newValue.h, "resH_") }
    }

    var fpsLimit: Int {
        get { int("fpsLimit_", 60) }
        nonmutating set { store(newValue, "fpsLimit_") }
    }

    var supersampling3D: Bool {
        get { bool("ss3d_", true) }
        nonmutating set { store(newValue, "ss3d_") }
    }

    var orientation: GameOrientation {
        get { GameOrientation(rawValue: defaults.string(forKey: "orient_" + id) ?? "") ?? .auto }
        nonmutating set { store(newValue.rawValue, "orient_") }
    }

    /// On-screen keys (D-pad, keypad, soft keys) shown over / under the game.
    var keyboardVisible: Bool {
        get { bool("kbdVisible_", true) }
        nonmutating set { store(newValue, "kbdVisible_") }
    }

    /// Opacity of the on-screen keys (0.3 … 1.0).
    var keyOpacity: Double {
        get { double("kbdOpacity_", 0.75) }
        nonmutating set { store(newValue, "kbdOpacity_") }
    }

    /// Size multiplier of the on-screen keys.
    var keyScale: Double {
        get { double("kbdScale_", 1.0) }
        nonmutating set { store(newValue, "kbdScale_") }
    }

    /// Stretch the game picture to fill the screen instead of keeping its proportions.
    var stretchToFill: Bool {
        get { scaleMode == .stretch }
        nonmutating set { scaleMode = newValue ? .stretch : .fit }
    }

    var scaleMode: ScaleMode {
        get {
            if let raw = defaults.string(forKey: "scaleMode_" + id), let mode = ScaleMode(rawValue: raw) { return mode }
            return bool("scaleFill_", false) ? .stretch : .fit
        }
        nonmutating set { store(newValue.rawValue, "scaleMode_") }
    }

    /// Smooth (bilinear) scaling instead of sharp pixels.
    var smoothPicture: Bool {
        get { bool("smooth_", false) }
        nonmutating set { store(newValue, "smooth_") }
    }

    /// Light vibration when an on-screen key is pressed.
    var keyHaptics: Bool {
        get { bool("haptic_", true) }
        nonmutating set { store(newValue, "haptic_") }
    }

    /// Disable auto-lock while this game is open (for long sessions).
    var keepScreenOn: Bool {
        get { bool("keepOn_", true) }
        nonmutating set { store(newValue, "keepOn_") }
    }

    /// Phone family whose key codes the game expects.
    var keyLayout: KeyLayout {
        get { KeyLayout(rawValue: int("keyLayout_", 0)) ?? .nokia }
        nonmutating set { store(newValue.rawValue, "keyLayout_") }
    }

    /// Text sizes in pixels for Font.SIZE_SMALL / MEDIUM / LARGE (0 = chosen from the resolution).
    var fontSizes: (small: Int, medium: Int, large: Int) {
        get { (int("fontS_", 0), int("fontM_", 0), int("fontL_", 0)) }
        nonmutating set { store(newValue.small, "fontS_"); store(newValue.medium, "fontM_"); store(newValue.large, "fontL_") }
    }

    /// Heap limit of the Java VM in megabytes.
    var heapMB: Int {
        get { int("heapMB_", 192) }
        nonmutating set { store(newValue, "heapMB_") }
    }

    /// Call pauseApp()/startApp() when the app leaves and returns to the foreground.
    /// Off by default: most phones only sent hideNotify, and some games restart on startApp.
    var callPauseApp: Bool {
        get { bool("callPause_", false) }
        nonmutating set { store(newValue, "callPause_") }
    }

    /// Tell the game the screen is a touch screen. Off: it may offer its key-only interface.
    var touchInput: Bool {
        get { bool("touch_", true) }
        nonmutating set { store(newValue, "touch_") }
    }

    /// Sound on or off for this game.
    var soundEnabled: Bool {
        get { bool("sound_", true) }
        nonmutating set { store(newValue, "sound_") }
    }

    /// Seconds a connection attempt may take before it fails.
    var connectTimeoutSeconds: Int {
        get { int("connectSec_", 30) }
        nonmutating set { store(newValue, "connectSec_") }
    }

    /// Total time this game has been played, in seconds.
    var playTimeSeconds: Double {
        get { double("playTime_", 0) }
    }

    func addPlayTime(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        store(playTimeSeconds + seconds, "playTime_")
    }

    /// Pass the per-game engine settings to the Java VM. Call before jvm_bridge_init.
    func applyToJVM() {
        jvm_bridge_set_property("j2me.keyboard.layout", String(keyLayout.rawValue))
        jvm_bridge_set_property("j2me.call.pauseapp", callPauseApp ? "1" : "0")
        jvm_bridge_set_property("j2me.sound.enabled", soundEnabled ? "1" : "0")
        jvm_bridge_set_property("j2me.touch.enabled", touchInput ? "1" : "0")
        jvm_bridge_set_property("j2me.net.connect.timeout", String(connectTimeoutSeconds * 1000))
        let res = resolution
        let sizes = resolvedFontSizes(longSide: max(res.w, res.h))
        jvm_bridge_set_font_sizes(Int32(sizes.small), Int32(sizes.medium), Int32(sizes.large))
        jvm_bridge_set_heap_limit(Int32(heapMB))
    }

    /// J2ME Loader's table: font sizes by the longer screen side, unless the user set them.
    private func resolvedFontSizes(longSide: Int) -> (small: Int, medium: Int, large: Int) {
        let user = fontSizes
        if user.small > 0 && user.medium > 0 && user.large > 0 { return user }
        if longSide <= 128 { return (9, 13, 15) }
        if longSide <= 176 { return (13, 15, 20) }
        if longSide <= 220 { return (15, 18, 22) }
        return (18, 22, 26)
    }

    /// Auto-press: key code and interval in seconds.
    var autoPressCode: Int32 {
        get { Int32(int("autoKey_", Int(J2MEKey.fire))) }
        nonmutating set { store(Int(newValue), "autoKey_") }
    }

    var autoPressInterval: Int {
        get { int("autoEvery_", 10) }
        nonmutating set { store(newValue, "autoEvery_") }
    }

    static let autoPressKeys: [(label: String, code: Int32)] = [
        ("OK (giữa D-pad)", J2MEKey.fire), ("Phím mềm trái", J2MEKey.softLeft), ("Phím mềm phải", J2MEKey.softRight),
        ("Phím 5", 53), ("Phím 0", 48), ("Phím 1", 49), ("Phím 3", 51), ("Phím 7", 55), ("Phím 9", 57),
        ("Phím *", 42), ("Phím #", 35), ("Lên", J2MEKey.up), ("Xuống", J2MEKey.down),
        ("Trái (D-pad)", J2MEKey.left), ("Phải (D-pad)", J2MEKey.right),
    ]

    static let autoPressIntervals: [Int] = [1, 2, 5, 10, 30, 60, 120, 300]

    /// Frame rate while in stable idle mode (0 = keep the normal rate).
    var idleFps: Int {
        get { int("idleFps_", 10) }
        nonmutating set { store(newValue, "idleFps_") }
    }

    static let idleFpsOptions: [(label: String, value: Int)] = [
        ("5 FPS (mát máy nhất)", 5),
        ("10 FPS (khuyên dùng)", 10),
        ("15 FPS", 15),
        ("20 FPS", 20),
        ("Không giảm", 0),
    ]

    /// Where the user dragged an on-screen key group, as a fraction of the
    /// safe area (0…1), separately for portrait and landscape. nil = default.
    func keyPosition(_ name: String, portrait: Bool) -> CGPoint? {
        guard let s = defaults.string(forKey: keyPositionKey(name, portrait)) else { return nil }
        let parts = s.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGPoint(x: parts[0], y: parts[1])
    }

    func setKeyPosition(_ point: CGPoint?, _ name: String, portrait: Bool) {
        let key = keyPositionKey(name, portrait)
        if let p = point {
            defaults.set(String(format: "%.4f,%.4f", Double(p.x), Double(p.y)), forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func keyPositionKey(_ name: String, _ portrait: Bool) -> String {
        "kbdPos_\(portrait ? "p" : "l")_\(name)_" + id
    }

    static let resolutionOptions: [(label: String, w: Int, h: Int)] = [
        // Landscape (for games that adapt to the screen size)
        ("320×240 (ngang)", 320, 240),
        ("400×240 (ngang)", 400, 240),
        ("480×320 (ngang)", 480, 320),
        ("480×360 (ngang, vừa iPad)", 480, 360),
        ("640×360 (ngang)", 640, 360),
        ("640×480 (ngang, vừa iPad)", 640, 480),
        ("800×480 (ngang)", 800, 480),
        // Classic phone sizes (portrait / square)
        ("101×80", 101, 80),
        ("128×128", 128, 128),
        ("128×160", 128, 160),
        ("132×176", 132, 176),
        ("160×128", 160, 128),
        ("176×208", 176, 208),
        ("176×220", 176, 220),
        ("208×208", 208, 208),
        ("220×220", 220, 220),
        ("240×266", 240, 266),
        ("240×320 (mặc định)", 240, 320),
        ("240×400", 240, 400),
        ("320×480", 320, 480),
        ("352×416", 352, 416),
        ("360×640", 360, 640),
        ("480×800", 480, 800),
    ]

    static let fpsOptions: [(label: String, value: Int)] = [
        ("Không giới hạn", 0),
        ("15 FPS", 15),
        ("20 FPS", 20),
        ("30 FPS", 30),
        ("60 FPS", 60),
    ]
}
