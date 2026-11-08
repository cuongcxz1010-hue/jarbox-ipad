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
