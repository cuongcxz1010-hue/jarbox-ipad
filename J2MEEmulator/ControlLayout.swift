//
//  ControlLayout.swift
//  J2MEEmulator
//
//  On-screen control catalogue, default placement and per-game control
//  profiles (position, size, opacity and visibility of every key,
//  separately for portrait and landscape).
//

import UIKit

// MARK: - Catalogue

enum ControlKind {
    case dpad
    case key(code: Int32, title: String, subtitle: String?)
}

struct ControlSpec {
    let id: String
    let name: String          // shown in the layout editor
    let kind: ControlKind
    let baseSize: CGSize      // points at size 1.0 on iPad
}

enum ControlCatalog {
    static let digitSize = CGSize(width: 64, height: 54)
    static let smallSize = CGSize(width: 64, height: 46)
    static let softSize = CGSize(width: 108, height: 48)

    static let all: [ControlSpec] = {
        var specs: [ControlSpec] = [
            ControlSpec(id: "dpad", name: "Phím điều hướng + OK", kind: .dpad, baseSize: CGSize(width: 230, height: 230)),
            ControlSpec(id: "softL", name: "Phím mềm trái",
                        kind: .key(code: J2MEKey.softLeft, title: "Trái", subtitle: "phím mềm"), baseSize: softSize),
            ControlSpec(id: "softR", name: "Phím mềm phải",
                        kind: .key(code: J2MEKey.softRight, title: "Phải", subtitle: "phím mềm"), baseSize: softSize),
            ControlSpec(id: "call", name: "Phím Gọi",
                        kind: .key(code: J2MEKey.call, title: "Gọi", subtitle: "call"), baseSize: smallSize),
            ControlSpec(id: "back", name: "Phím C / Back",
                        kind: .key(code: J2MEKey.clear, title: "C", subtitle: "back"), baseSize: smallSize),
            ControlSpec(id: "end", name: "Phím Tắt",
                        kind: .key(code: J2MEKey.end, title: "Tắt", subtitle: "end"), baseSize: smallSize),
        ]
        let digits: [(String, String?, Int32)] = [
            ("1", nil, 49), ("2", "abc", 50), ("3", "def", 51),
            ("4", "ghi", 52), ("5", "jkl", 53), ("6", "mno", 54),
            ("7", "pqrs", 55), ("8", "tuv", 56), ("9", "wxyz", 57),
            ("*", nil, 42), ("0", "␣", 48), ("#", nil, 35),
        ]
        for (title, sub, code) in digits {
            specs.append(ControlSpec(id: "key\(code)", name: "Phím \(title)",
                                     kind: .key(code: code, title: title, subtitle: sub), baseSize: digitSize))
        }
        return specs
    }()

    static func spec(_ id: String) -> ControlSpec? { all.first { $0.id == id } }

    /// Default frames: D-pad bottom-left, keypad bottom-right, soft keys and
    /// Call / C / End on one row above them.
    static func defaultFrames(in safe: CGRect, unit: CGFloat, margin: CGFloat) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        let bottom = safe.maxY - margin
        let gap = 9 * unit

        let dpad = 230 * unit
        let dpadRect = CGRect(x: safe.minX + margin, y: bottom - dpad, width: dpad, height: dpad)
        frames["dpad"] = dpadRect

        let kw = digitSize.width * unit, kh = digitSize.height * unit
        let padW = kw * 3 + gap * 2, padH = kh * 4 + gap * 3
        let padX = safe.maxX - margin - padW, padY = bottom - padH
        let order: [Int32] = [49, 50, 51, 52, 53, 54, 55, 56, 57, 42, 48, 35]
        for (i, code) in order.enumerated() {
            frames["key\(code)"] = CGRect(x: padX + CGFloat(i % 3) * (kw + gap),
                                          y: padY + CGFloat(i / 3) * (kh + gap), width: kw, height: kh)
        }

        let sw = softSize.width * unit, sh = softSize.height * unit
        let smw = smallSize.width * unit, smh = smallSize.height * unit
        let rowBottom = min(dpadRect.minY, padY) - 12 * unit
        let softY = rowBottom - sh
        let smallY = softY + (sh - smh) / 2
        let softL = CGRect(x: dpadRect.minX, y: softY, width: sw, height: sh)
        frames["softL"] = softL
        frames["call"] = CGRect(x: softL.maxX + gap, y: smallY, width: smw, height: smh)
        let softR = CGRect(x: safe.maxX - margin - sw, y: softY, width: sw, height: sh)
        frames["softR"] = softR
        let end = CGRect(x: softR.minX - gap - smw, y: smallY, width: smw, height: smh)
        frames["end"] = end
        frames["back"] = CGRect(x: end.minX - gap - smw, y: smallY, width: smw, height: smh)
        return frames
    }

    /// Height of the default control area (for keeping the game screen above it in portrait).
    static func defaultClusterHeight(unit: CGFloat) -> CGFloat {
        let padH = digitSize.height * unit * 4 + 9 * unit * 3
        return max(230 * unit, padH) + 12 * unit + softSize.height * unit
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
    var opacity: Double = 0.75
    var scale: Double = 1.0
    var landscape: [String: KeyPlacement] = [:]
    var portrait: [String: KeyPlacement] = [:]
}

/// Control profiles of one game, saved as JSON in UserDefaults.
final class ControlProfileStore {
    private let profilesKey: String
    private let activeKey: String
    private(set) var profiles: [ControlProfile]
    private(set) var activeIndex: Int

    init(settings: GameSettings) {
        profilesKey = "ctlProfiles_" + settings.id
        activeKey = "ctlActive_" + settings.id
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: profilesKey),
           let saved = try? JSONDecoder().decode([ControlProfile].self, from: data), !saved.isEmpty {
            profiles = saved
        } else {
            // First run: start from the older single opacity / size settings
            profiles = [ControlProfile(name: "Mặc định", opacity: settings.keyOpacity, scale: settings.keyScale)]
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
