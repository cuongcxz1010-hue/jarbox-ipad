//
//  ControlLayout.swift
//  J2MEEmulator
//
//  On-screen keyboard model in the style of J2ME Loader (Android):
//  • the keys (3×3 arrow pad with OK and diagonals, 0-9 * #, soft keys L/R,
//    Menu, and the optional C / Call / End);
//  • layout presets and the default geometry for portrait (keys on a panel
//    under the game) and landscape (keys beside / over the game);
//  • per-game control profiles: layout, colours, key shape, size, opacity
//    and where the user moved / resized / hid each key (portrait and
//    landscape separately).
//

import UIKit

// MARK: - Keys

enum VKeyGroup {
    case arrows, numbers, soft, extra, menu
}

struct VKeySpec {
    let id: String
    let name: String          // shown in the layout editor
    let label: String         // drawn on the key
    let codes: [Int32]        // J2ME key codes sent together (diagonals send two)
    let group: VKeyGroup
}

/// Keyboard arrangements (like J2ME Loader's keyboard types).
enum KeyboardPreset: String, CaseIterable {
    case arrowsLeft, arrowsRight, arrowsOnly, numbersOnly

    var title: String {
        switch self {
        case .arrowsLeft:  return "Mũi tên bên trái, số bên phải"
        case .arrowsRight: return "Số bên trái, mũi tên bên phải"
        case .arrowsOnly:  return "Chỉ mũi tên (+ L, R)"
        case .numbersOnly: return "Chỉ phím số (+ L, R)"
        }
    }
}

/// Key colours.
enum KeyTheme: String, CaseIterable {
    case light, dark

    var title: String {
        switch self {
        case .light: return "Sáng (giống J2ME Loader)"
        case .dark:  return "Tối"
        }
    }
}

enum KeyShape: String, CaseIterable {
    case rounded, circle, square

    var title: String {
        switch self {
        case .rounded: return "Bo góc"
        case .circle:  return "Tròn"
        case .square:  return "Vuông"
        }
    }
}

enum ControlCatalog {
    static let all: [VKeySpec] = {
        var specs: [VKeySpec] = [
            VKeySpec(id: "upLeft", name: "Chéo lên trái", label: "↖", codes: [J2MEKey.up, J2MEKey.left], group: .arrows),
            VKeySpec(id: "up", name: "Lên", label: "↑", codes: [J2MEKey.up], group: .arrows),
            VKeySpec(id: "upRight", name: "Chéo lên phải", label: "↗", codes: [J2MEKey.up, J2MEKey.right], group: .arrows),
            VKeySpec(id: "left", name: "Trái", label: "←", codes: [J2MEKey.left], group: .arrows),
            VKeySpec(id: "fire", name: "OK (bắn / chọn)", label: "OK", codes: [J2MEKey.fire], group: .arrows),
            VKeySpec(id: "right", name: "Phải", label: "→", codes: [J2MEKey.right], group: .arrows),
            VKeySpec(id: "downLeft", name: "Chéo xuống trái", label: "↙", codes: [J2MEKey.down, J2MEKey.left], group: .arrows),
            VKeySpec(id: "down", name: "Xuống", label: "↓", codes: [J2MEKey.down], group: .arrows),
            VKeySpec(id: "downRight", name: "Chéo xuống phải", label: "↘", codes: [J2MEKey.down, J2MEKey.right], group: .arrows),
            VKeySpec(id: "softL", name: "Phím mềm trái (L)", label: "L", codes: [J2MEKey.softLeft], group: .soft),
            VKeySpec(id: "softR", name: "Phím mềm phải (R)", label: "R", codes: [J2MEKey.softRight], group: .soft),
            VKeySpec(id: "menu", name: "Menu của JarBox", label: "≡", codes: [], group: .menu),
            VKeySpec(id: "clear", name: "Phím C (xóa / quay lại)", label: "C", codes: [J2MEKey.clear], group: .extra),
            VKeySpec(id: "call", name: "Phím Gọi", label: "Gọi", codes: [J2MEKey.call], group: .extra),
            VKeySpec(id: "end", name: "Phím Tắt", label: "Tắt", codes: [J2MEKey.end], group: .extra),
        ]
        let digits: [(String, Int32)] = [
            ("1", 49), ("2", 50), ("3", 51), ("4", 52), ("5", 53), ("6", 54),
            ("7", 55), ("8", 56), ("9", 57), ("*", 42), ("0", 48), ("#", 35),
        ]
        for (label, code) in digits {
            specs.append(VKeySpec(id: "num\(code)", name: "Phím \(label)", label: label, codes: [code], group: .numbers))
        }
        return specs
    }()

    private static let byId: [String: VKeySpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func spec(_ id: String) -> VKeySpec? { byId[id] }

    static let arrowGrid = ["upLeft", "up", "upRight", "left", "fire", "right", "downLeft", "down", "downRight"]
    static let numberGrid = ["num49", "num50", "num51", "num52", "num53", "num54",
                             "num55", "num56", "num57", "num42", "num48", "num35"]

    /// Shown before the user changes anything.
    static func visibleByDefault(_ id: String, preset: KeyboardPreset) -> Bool {
        guard let spec = spec(id) else { return false }
        switch spec.group {
        case .extra: return false
        case .soft, .menu: return true
        case .arrows: return preset != .numbersOnly
        case .numbers: return preset != .arrowsOnly
        }
    }

    // MARK: Geometry

    struct Metrics {
        let key: CGFloat       // side of a square key
        let gap: CGFloat
        let margin: CGFloat
        var softSize: CGSize { CGSize(width: round(key * 1.35), height: round(key * 0.72)) }
        var menuSize: CGSize { CGSize(width: round(key * 1.0), height: round(key * 0.72)) }
        var arrowPad: CGSize { CGSize(width: key * 3 + gap * 2, height: key * 3 + gap * 2) }
        var numberPad: CGSize { CGSize(width: key * 3 + gap * 2, height: key * 4 + gap * 3) }
    }

    /// Key size: about 1/14 of the long screen side (J2ME Loader uses 1/12),
    /// limited so both pads fit side by side, times the user's size.
    static func metrics(safe: CGRect, portrait: Bool, userScale: CGFloat, isPad: Bool) -> Metrics {
        let long = max(safe.width, safe.height), short = min(safe.width, safe.height)
        let margin: CGFloat = isPad ? 14 : 8
        var key = long / 14
        let fitAcross = (short - 2 * margin - 24) / 6.5          // two 3-wide pads in the short side
        key = min(key, fitAcross)
        key = min(max(key, 44), 96) * userScale
        return Metrics(key: round(key), gap: round(max(4, key * 0.11)), margin: margin)
    }

    /// Smaller keys when they then fit in the empty bars beside a landscape game.
    static func fitBesideGame(_ m: Metrics, safe: CGRect, game: CGRect) -> Metrics {
        let side = min(game.minX - safe.minX, safe.maxX - game.maxX)
        let fitted = floor((side - 2 * m.margin) / (3 + 2 * 0.11))
        guard fitted >= m.key * 0.78, fitted < m.key else { return m }
        return Metrics(key: fitted, gap: round(max(4, fitted * 0.11)), margin: m.margin)
    }

    /// Height of the key panel under the game in portrait.
    static func portraitPanelHeight(_ m: Metrics, preset: KeyboardPreset) -> CGFloat {
        let rows: CGFloat = preset == .arrowsOnly ? 3 : 4
        return m.margin + m.softSize.height + m.gap * 1.5 + rows * m.key + (rows - 1) * m.gap + m.margin
    }

    /// Default frame of every key.
    static func defaultFrames(safe: CGRect, portrait: Bool, preset: KeyboardPreset, metrics m: Metrics) -> [String: CGRect] {
        var f: [String: CGRect] = [:]
        let k = m.key, g = m.gap
        let bottom = safe.maxY - m.margin
        let left = safe.minX + m.margin, right = safe.maxX - m.margin

        // Where the two pads go
        let arrowW = m.arrowPad.width, numW = m.numberPad.width
        var arrowX: CGFloat, numX: CGFloat
        switch preset {
        case .arrowsLeft, .arrowsOnly, .numbersOnly:
            arrowX = left
            numX = right - numW
        case .arrowsRight:
            arrowX = right - arrowW
            numX = left
        }
        if portrait && preset == .arrowsOnly { arrowX = round(safe.midX - arrowW / 2) }
        if portrait && preset == .numbersOnly { numX = round(safe.midX - numW / 2) }

        let numY = bottom - m.numberPad.height
        // Portrait: arrow pad centred on the number pad; landscape: both on the bottom edge
        let arrowY = portrait && preset != .arrowsOnly
            ? round(numY + (m.numberPad.height - m.arrowPad.height) / 2)
            : bottom - m.arrowPad.height

        for (i, id) in arrowGrid.enumerated() {
            f[id] = CGRect(x: arrowX + CGFloat(i % 3) * (k + g), y: arrowY + CGFloat(i / 3) * (k + g), width: k, height: k)
        }
        for (i, id) in numberGrid.enumerated() {
            f[id] = CGRect(x: numX + CGFloat(i % 3) * (k + g), y: numY + CGFloat(i / 3) * (k + g), width: k, height: k)
        }

        // Soft keys: L always on the left, R on the right
        // (portrait: one row on top of the panel; landscape: each above the pad on its side)
        let soft = m.softSize
        let topOfPads = preset == .arrowsOnly ? arrowY : (preset == .numbersOnly ? numY : min(arrowY, numY))
        let leftPadTop = preset == .arrowsRight ? numY : arrowY
        let rightPadTop = preset == .arrowsRight ? arrowY : numY
        let softLY = (portrait ? topOfPads : leftPadTop) - g * 1.5 - soft.height
        let softRY = (portrait ? topOfPads : rightPadTop) - g * 1.5 - soft.height
        let softY = min(softLY, softRY)
        let softL = CGRect(x: left, y: softLY, width: soft.width, height: soft.height)
        let softR = CGRect(x: right - soft.width, y: softRY, width: soft.width, height: soft.height)
        f["softL"] = softL
        f["softR"] = softR

        // Menu: between the soft keys in portrait, top-right corner in landscape
        let menu = m.menuSize
        if portrait {
            f["menu"] = CGRect(x: round(safe.midX - menu.width / 2), y: softY, width: menu.width, height: menu.height)
        } else {
            f["menu"] = CGRect(x: right - menu.width, y: safe.minY + m.margin, width: menu.width, height: menu.height)
        }

        // Optional keys (hidden by default): next to the soft keys
        let small = CGSize(width: round(k * 0.9), height: soft.height)
        f["call"] = CGRect(x: softL.maxX + g, y: softL.minY, width: small.width, height: small.height)
        f["end"] = CGRect(x: softR.minX - g - small.width, y: softR.minY, width: small.width, height: small.height)
        f["clear"] = CGRect(x: softR.minX - 2 * (g + small.width), y: softR.minY, width: small.width, height: small.height)
        return f
    }
}

// MARK: - Profiles

struct KeyPlacement: Codable, Equatable {
    var x: Double            // centre, fraction of the safe area width
    var y: Double            // centre, fraction of the safe area height
    var scale: Double = 1    // size relative to the default
    var opacity: Double = 1  // multiplied with the profile opacity
    var hidden: Bool = false
}

struct ControlProfile: Codable {
    var name: String
    var opacity: Double = 0.45          // keys drawn over the game
    var scale: Double = 1.0
    var landscape: [String: KeyPlacement] = [:]
    var portrait: [String: KeyPlacement] = [:]
    var layout: String?                 // KeyboardPreset raw value
    var theme: String?                  // KeyTheme raw value
    var shape: String?                  // KeyShape raw value

    var preset: KeyboardPreset {
        get { layout.flatMap(KeyboardPreset.init(rawValue:)) ?? .arrowsLeft }
        set { layout = newValue.rawValue }
    }
    var keyTheme: KeyTheme {
        get { theme.flatMap(KeyTheme.init(rawValue:)) ?? .light }
        set { theme = newValue.rawValue }
    }
    var keyShape: KeyShape {
        get { shape.flatMap(KeyShape.init(rawValue:)) ?? .rounded }
        set { shape = newValue.rawValue }
    }
}

/// Control profiles of one game, saved as JSON in UserDefaults.
final class ControlProfileStore {
    private let profilesKey: String
    private let activeKey: String
    private(set) var profiles: [ControlProfile]
    private(set) var activeIndex: Int

    init(settings: GameSettings) {
        // "vk2": the J2ME Loader-style keyboard; older layouts used other key ids
        profilesKey = "vk2Profiles_" + settings.id
        activeKey = "vk2Active_" + settings.id
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: profilesKey),
           let saved = try? JSONDecoder().decode([ControlProfile].self, from: data), !saved.isEmpty {
            profiles = saved
        } else {
            profiles = [ControlProfile(name: "Mặc định")]
        }
        activeIndex = min(max(0, defaults.integer(forKey: activeKey)), profiles.count - 1)
    }

    var active: ControlProfile {
        get { profiles[activeIndex] }
        set { profiles[activeIndex] = newValue; save() }
    }

    func select(_ index: Int) {
        guard profiles.indices.contains(index) else { return }
        activeIndex = index
        save()
    }

    /// New profile copied from the active one.
    func addCopy(named name: String) {
        var copy = active
        copy.name = name
        profiles.append(copy)
        activeIndex = profiles.count - 1
        save()
    }

    func renameActive(_ name: String) {
        guard !name.isEmpty else { return }
        active.name = name
    }

    func removeActive() {
        guard profiles.count > 1 else { return }
        profiles.remove(at: activeIndex)
        activeIndex = max(0, activeIndex - 1)
        save()
    }

    func placement(_ id: String, portrait: Bool) -> KeyPlacement? {
        portrait ? active.portrait[id] : active.landscape[id]
    }

    func setPlacement(_ placement: KeyPlacement?, _ id: String, portrait: Bool) {
        if portrait { active.portrait[id] = placement } else { active.landscape[id] = placement }
    }

    func resetPlacements(portrait: Bool) {
        if portrait { active.portrait = [:] } else { active.landscape = [:] }
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: profilesKey) }
        defaults.set(activeIndex, forKey: activeKey)
    }
}
