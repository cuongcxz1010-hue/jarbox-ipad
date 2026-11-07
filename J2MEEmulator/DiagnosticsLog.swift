//
//  DiagnosticsLog.swift
//  J2MEEmulator
//
//  Writes everything printed by Swift, the C bridge / miniJVM and Java
//  (System.out / System.err) to Documents/logs/jarbox-log.txt so problems on a
//  sideloaded device can be diagnosed without Xcode. The folder is visible in
//  the Files app under "On My iPad › JarBox › logs". The previous session is
//  kept as jarbox-log-previous.txt (useful after a crash).
//

import Foundation

nonisolated enum DiagnosticsLog {

    static var logsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("logs", isDirectory: true)
    }
    static var currentURL: URL { logsDirectory.appendingPathComponent("jarbox-log.txt") }
    static var previousURL: URL { logsDirectory.appendingPathComponent("jarbox-log-previous.txt") }
    private static var runningMarkerURL: URL { logsDirectory.appendingPathComponent(".running-game") }

    /// Redirect stdout/stderr to the log file. Call once, as early as possible.
    static func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: currentURL.path) {
            try? fm.removeItem(at: previousURL)
            try? fm.moveItem(at: currentURL, to: previousURL)
        }
        let path = currentURL.path
        _ = freopen(path, "a", stdout)
        _ = freopen(path, "a", stderr)
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)

        var u = utsname()
        uname(&u)
        let machine = withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        print("=== JarBox \(version) (\(build)) | \(machine) | \(ProcessInfo.processInfo.operatingSystemVersionString) | \(Date()) ===")
    }

    /// Current size of the log; pass it to `failureSummary(since:)` later.
    static func mark() -> Int {
        fflush(stdout)
        let attrs = try? FileManager.default.attributesOfItem(atPath: currentURL.path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Log text written after `offset`.
    static func text(since offset: Int) -> String {
        fflush(stdout)
        guard let data = try? Data(contentsOf: currentURL), data.count > offset else { return "" }
        return String(decoding: data.subdata(in: offset..<data.count), as: UTF8.self)
    }

    /// The lines most useful for a "game failed to start" message.
    static func failureSummary(since offset: Int, maxLines: Int = 14) -> String {
        let lines = text(since: offset).split(separator: "\n").map(String.init)
        let keys = ["ERROR", "Error", "error", "Exception", "Caused by", "[MIDletRunner]", "[JVM Bridge]"]
        var picked = lines.filter { line in keys.contains { line.contains($0) } }
        if picked.isEmpty { picked = lines }
        return picked.suffix(maxLines).joined(separator: "\n")
    }

    // MARK: - Crash detection (marker file exists while a game is running)

    static func markGameRunning(_ name: String) {
        try? name.write(to: runningMarkerURL, atomically: true, encoding: .utf8)
    }

    static func markGameStopped() {
        try? FileManager.default.removeItem(at: runningMarkerURL)
    }

    /// Name of the game that was running when the app last ended unexpectedly.
    /// Consumes the marker.
    static func takeCrashedGameName() -> String? {
        guard let name = try? String(contentsOf: runningMarkerURL, encoding: .utf8) else { return nil }
        markGameStopped()
        return name
    }

    static var shareableURLs: [URL] {
        fflush(stdout)
        return [currentURL, previousURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
