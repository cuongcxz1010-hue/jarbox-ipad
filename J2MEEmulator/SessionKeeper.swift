//
//  SessionKeeper.swift
//  J2MEEmulator
//
//  Keeps a game session alive as far as iOS allows, and remembers which
//  game to offer again if the system ended the app.
//
//  What iOS allows (and what this does):
//  • Foreground: the game runs normally; "keep screen on" disables auto-lock.
//  • Short app switch: a background task — iOS grants roughly 30 seconds,
//    then suspends the app (sockets are dropped). App Store-safe API.
//  • Longer background / locked screen (EXPERIMENTAL, off by default):
//    background audio mode with a silent loop keeps the process running.
//    Works on sideloaded builds; it is NOT allowed on the App Store
//    (guideline 2.5.4), costs battery, and iOS may still end the app
//    (low memory, very long sessions, audio interruptions such as calls).
//  • A true memory snapshot of the Java VM is not possible; after the app was
//    ended the game is started again and uses its own saved data (RMS).
//

import AVFoundation
import UIKit

final class SessionKeeper {
    static let shared = SessionKeeper()

    private static let backgroundAudioKey = "bgKeepAlive"
    private static let resumeKey = "resumeGamePath"

    /// User setting: try to keep games running in the background / locked screen.
    static var backgroundAudioEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: backgroundAudioKey) }
        set { UserDefaults.standard.set(newValue, forKey: backgroundAudioKey) }
    }

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var silentPlayer: AVAudioPlayer?
    private(set) var gameRunning = false

    // MARK: - Game lifecycle

    func gameStarted() {
        gameRunning = true
        if Self.backgroundAudioEnabled { startSilentAudio() }
    }

    func gameStopped() {
        gameRunning = false
        stopSilentAudio()
        endBackgroundTask()
        Self.clearResume()
    }

    func setBackgroundAudio(_ enabled: Bool) {
        Self.backgroundAudioEnabled = enabled
        if enabled && gameRunning {
            startSilentAudio()
        } else if !enabled {
            stopSilentAudio()
        }
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
        print("[Session] Background: extra time \(remaining > 1e6 ? "unlimited" : String(format: "%.0f s", remaining)), " +
              "background audio \(silentPlayer?.isPlaying == true ? "ON" : "off")")
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

    // MARK: - Background audio keep-alive (experimental)

    private func startSilentAudio() {
        guard silentPlayer == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silentWAV())
            player.numberOfLoops = -1
            player.volume = 0
            player.play()
            silentPlayer = player
            print("[Session] Background audio keep-alive ON")
        } catch {
            print("[Session] Background audio keep-alive failed: \(error)")
        }
    }

    private func stopSilentAudio() {
        guard let player = silentPlayer else { return }
        player.stop()
        silentPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        print("[Session] Background audio keep-alive OFF")
    }

    /// One second of 8 kHz mono 16-bit silence as a WAV file.
    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 8000
        let dataSize: UInt32 = sampleRate * 2
        var d = Data()
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); append32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); append32(16)
        append16(1); append16(1)                       // PCM, mono
        append32(sampleRate); append32(sampleRate * 2) // sample rate, byte rate
        append16(2); append16(16)                      // block align, bits per sample
        d.append(contentsOf: Array("data".utf8)); append32(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }
}
