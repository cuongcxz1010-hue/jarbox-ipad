//
//  GameStorage.swift
//  J2MEEmulator
//
//  Where one game keeps its data, and backups of it. RMS records are written
//  to disk as the game saves them, so they survive closing the app and
//  restarting the device.
//

import Foundation

struct GameStorage {
    let settings: GameSettings

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var dataDirectory: URL {
        Self.documents.appendingPathComponent("Games Data", isDirectory: true).appendingPathComponent(settings.id, isDirectory: true)
    }

    var rmsDirectory: URL { dataDirectory.appendingPathComponent("rms", isDirectory: true) }

    private var snapshotDirectory: URL {
        Self.documents.appendingPathComponent("Snapshots", isDirectory: true).appendingPathComponent(settings.id, isDirectory: true)
    }

    var latestSnapshot: URL { snapshotDirectory.appendingPathComponent("rms-latest.zip") }

    var hasSnapshot: Bool { FileManager.default.fileExists(atPath: latestSnapshot.path) }

    /// Copy the saved data aside. Returns false when there is nothing to copy.
    func createSnapshot() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rmsDirectory.path) else { return false }
        try? fm.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        return jarbox_zip_directory(rmsDirectory.path, latestSnapshot.path) != 0
    }

    /// Put the saved data back as it was when the snapshot was taken.
    func restoreSnapshot() -> Bool {
        let fm = FileManager.default
        guard hasSnapshot else { return false }
        try? fm.removeItem(at: rmsDirectory)
        try? fm.createDirectory(at: rmsDirectory, withIntermediateDirectories: true)
        return jarbox_unzip(latestSnapshot.path, rmsDirectory.path) != 0
    }

    /// A ZIP of the JAR, its JAD and all saved data, for moving a game elsewhere.
    func exportBackup(jarPath: String) -> URL? {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("backup-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        do {
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            let jar = URL(fileURLWithPath: jarPath)
            try fm.copyItem(at: jar, to: stage.appendingPathComponent(jar.lastPathComponent))
            let jad = jar.deletingPathExtension().appendingPathExtension("jad")
            if fm.fileExists(atPath: jad.path) { try fm.copyItem(at: jad, to: stage.appendingPathComponent(jad.lastPathComponent)) }
            if fm.fileExists(atPath: dataDirectory.path) { try fm.copyItem(at: dataDirectory, to: stage.appendingPathComponent("data")) }
            try Data("JarBox backup 1\n".utf8).write(to: stage.appendingPathComponent(Self.marker))
            let out = fm.temporaryDirectory.appendingPathComponent(jar.deletingPathExtension().lastPathComponent + ".kuontpl.zip")
            return jarbox_zip_directory(stage.path, out.path) != 0 ? out : nil
        } catch {
            print("[Storage] Backup failed: \(error)")
            return nil
        }
    }

    static let marker = "JARBOX-BACKUP.txt"

    /// Backup files: ".kuontpl.zip", and ".jarbox.zip" from versions before the rename.
    nonisolated static func isBackupFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".kuontpl.zip") || name.hasSuffix(".jarbox.zip")
    }

    /// Restore a backup file. Returns the file name of the restored JAR.
    static func importBackup(from zip: URL, gamesDirectory: String) -> String? {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("restore-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        guard jarbox_unzip(zip.path, stage.path) != 0, fm.fileExists(atPath: stage.appendingPathComponent(marker).path),
              let files = try? fm.contentsOfDirectory(atPath: stage.path),
              let jarName = files.first(where: { $0.lowercased().hasSuffix(".jar") }) else { return nil }
        do {
            try fm.createDirectory(atPath: gamesDirectory, withIntermediateDirectories: true)
            for name in files where name.lowercased().hasSuffix(".jar") || name.lowercased().hasSuffix(".jad") {
                let target = URL(fileURLWithPath: gamesDirectory).appendingPathComponent(name)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: stage.appendingPathComponent(name), to: target)
            }
            let settings = GameSettings(jarPath: gamesDirectory + "/" + jarName)
            let storage = GameStorage(settings: settings)
            let data = stage.appendingPathComponent("data")
            if fm.fileExists(atPath: data.path) {
                try? fm.removeItem(at: storage.dataDirectory)
                try fm.createDirectory(at: storage.dataDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: data, to: storage.dataDirectory)
            }
            return jarName
        } catch {
            print("[Storage] Restore failed: \(error)")
            return nil
        }
    }
}
