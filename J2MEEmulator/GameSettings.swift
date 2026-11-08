//
//  GameSettings.swift
//  J2MEEmulator
//
//  Per-game settings stored in UserDefaults. Keys are "<prefix><gameId>"
//  and stay compatible with earlier versions (resW_, resH_, fpsLimit_, ss3d_).
//

import Foundation

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

    static let resolutionOptions: [(label: String, w: Int, h: Int)] = [
        // Landscape (for games that adapt to the screen size)
        ("320×240 (ngang)", 320, 240),
        ("400×240 (ngang)", 400, 240),
        ("480×320 (ngang)", 480, 320),
        ("640×360 (ngang)", 640, 360),
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
