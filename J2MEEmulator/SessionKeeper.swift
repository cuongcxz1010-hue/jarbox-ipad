//
//  SessionKeeper.swift
//  J2MEEmulator
//
//  Follows the game session through the iOS app life cycle using only what
//  iOS allows. See docs/BACKGROUND.md.
//
//  • App in the foreground: the game runs normally.
//  • App switch or lock: iOS grants a short background task (usually around
//    30 seconds), then suspends the process; Java threads stop and the
//    server closes the socket after its own timeout.
//  • When the app comes back within that window nothing was lost. After a
//    long suspension the game sees the broken connection and runs its own
//    reconnect code.
//  • If iOS ended the app, the game is offered again on the next launch and
//    starts from its saved data (RMS).
//

import Network
import UIKit

final class SessionKeeper {
    static let shared = SessionKeeper()

    private static let resumeKey = "resumeGamePath"

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private(set) var gameRunning = false
    private(set) var networkAvailable = true
    private let pathMonitor = NWPathMonitor()

    /// Called on the main thread when the connection to the network changes.
    var onNetworkChange: ((Bool) -> Void)?

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self, self.networkAvailable != up else { return }
                self.networkAvailable = up
                print("[Session] Network \(up ? "available" : "lost")")
                self.onNetworkChange?(up)
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    // MARK: - Game lifecycle

    func gameStarted() {
        gameRunning = true
    }

    func gameStopped() {
        gameRunning = false
        endBackgroundTask()
        Self.clearResume()
    }

    // MARK: - App lifecycle (called by SceneDelegate)

    func appDidEnterBackground(gameJarPath: String?) {
        guard gameRunning, let path = gameJarPath else { return }
        // File name only: the app's container path can change after reinstalling
        UserDefaults.standard.set(URL(fileURLWithPath: path).lastPathComponent, forKey: Self.resumeKey)
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "J2MEGameSession") { [weak self] in
            self?.endBackgroundTask()
        }
        let remaining = UIApplication.shared.backgroundTimeRemaining
        print("[Session] Background: \(remaining > 1e6 ? "time not limited yet" : String(format: "%.0f s granted", remaining))")
    }

    func appWillEnterForeground() {
        endBackgroundTask()
        Self.clearResume()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Resume after the system ended the app

    /// File name of the game that was running when the app went to the
    /// background and never came back (consumed).
    static func takeResumeJarName() -> String? {
        let name = UserDefaults.standard.string(forKey: resumeKey)
        clearResume()
        return name
    }

    static func clearResume() {
        UserDefaults.standard.removeObject(forKey: resumeKey)
    }
}
