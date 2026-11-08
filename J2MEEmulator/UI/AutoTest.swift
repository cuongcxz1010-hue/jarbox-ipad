//
//  AutoTest.swift
//  J2MEEmulator
//
//  Unattended runs in the iOS Simulator, used by the CI workflow (see
//  tools/ci/simulator_test.sh). Active only when these environment variables
//  are set by `simctl launch`:
//    JARBOX_AUTORUN      file name of a game in Documents/games to start
//    JARBOX_ORIENTATION  "landscape" or "portrait"
//    JARBOX_SCRIPT       "<ms> key <code>; <ms> tap <x> <y>; <ms> rotate <landscape|portrait>"
//

import UIKit

enum AutoTest {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    static var autorunJarName: String? { env["JARBOX_AUTORUN"] }
    static var forcedOrientation: GameOrientation? { env["JARBOX_ORIENTATION"].flatMap(GameOrientation.init(rawValue:)) }

    /// Run the timed script against a game screen.
    static func runScript(on game: GameViewController) {
        guard let script = env["JARBOX_SCRIPT"] else { return }
        for step in script.split(separator: ";") {
            let parts = step.split(separator: " ").map(String.init)
            guard parts.count >= 2, let ms = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000) { [weak game] in
                guard let game else { return }
                switch parts[1] {
                case "key":
                    guard parts.count >= 3, let code = Int32(parts[2]) else { return }
                    j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), code)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), code)
                    }
                case "tap":
                    guard parts.count >= 4, let x = Int32(parts[2]), let y = Int32(parts[3]) else { return }
                    j2me_input_post_touch(Int32(J2ME_INPUT_POINTER_PRESSED), x, y)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        j2me_input_post_touch(Int32(J2ME_INPUT_POINTER_RELEASED), x, y)
                    }
                case "rotate":
                    guard parts.count >= 3, let target = GameOrientation(rawValue: parts[2]) else { return }
                    game.autoTestRotate(target)
                default:
                    break
                }
            }
        }
    }
}
