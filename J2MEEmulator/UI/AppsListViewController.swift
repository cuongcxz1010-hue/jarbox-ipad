//
//  AppsListViewController.swift
//  J2MEEmulator
//
//  Home screen: hosts the SwiftUI game library (LibraryView) and does the
//  UIKit work behind it — importing .jar / .jad files, scanning the library,
//  launching games, settings sheets, crash / resume prompts and logs.
//

import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

class AppsListViewController: UIViewController, UIDocumentPickerDelegate {

    private let model = LibraryModel()
    private var hosting: UIHostingController<LibraryView>?

    /// Directory where imported JARs are stored
    private static var gamesDirectory: String {
        documentsDirectory + "/games"
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let actions = LibraryActions(
            play: { [weak self] game in self?.launch(game) },
            settings: { [weak self] game in self?.openSettings(for: game) },
            rename: { [weak self] game in self?.rename(game) },
            clearData: { [weak self] game in self?.confirmClearGameData(for: game) },
            delete: { [weak self] game in self?.confirmDelete(game) },
            backup: { [weak self] game in self?.backup(game) },
            restoreSnapshot: { [weak self] game in self?.restoreSnapshot(game) },
            add: { [weak self] in self?.addAppTapped() },
            logs: { [weak self] in
                guard let self else { return }
                Self.shareLogs(from: self, barButtonItem: nil)
            },
            help: { [weak self] in self?.showLibraryHelp() })

        let host = UIHostingController(rootView: LibraryView(model: model, actions: actions))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        hosting = host

        // Ensure games directory exists
        try? FileManager.default.createDirectory(atPath: Self.gamesDirectory,
                                                  withIntermediateDirectories: true)
        scanApps()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The SwiftUI library has its own navigation bar
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    private var checkedLastCrash = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        scanApps()   // refresh "last played" after a game

        // A game was running when the app last ended → it most likely crashed.
        if !checkedLastCrash {
            checkedLastCrash = true
            if let name = DiagnosticsLog.takeCrashedGameName() {
                let alert = UIAlertController(
                    title: "Game bị thoát đột ngột",
                    message: "Lần trước \"\(name)\" bị đóng bất ngờ (có thể do lỗi giả lập).\n\nChia sẻ nhật ký để báo lỗi?",
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Chia sẻ nhật ký", style: .default) { [weak self] _ in
                    guard let self else { return }
                    Self.shareLogs(from: self, barButtonItem: nil)
                })
                alert.addAction(UIAlertAction(title: "Bỏ qua", style: .cancel))
                present(alert, animated: true)
            } else {
                // iOS ended the app while a game was in the background → offer to reopen it
                pendingResumeName = SessionKeeper.takeResumeJarName()
                offerResumeIfReady()
            }
        }
    }

    private var pendingResumeName: String?
    private var autoStarted = false

    /// Called once the game list is known (the scan runs in the background).
    private func offerResumeIfReady() {
        guard let name = pendingResumeName, presentedViewController == nil,
              let game = model.games.first(where: { $0.fileName == name }) else { return }
        pendingResumeName = nil
        let alert = UIAlertController(
            title: "Tiếp tục chơi?",
            message: "iOS đã đóng KUONTPL khi \"\(game.name)\" đang chạy nền.\n\nMở lại game? Game sẽ khởi động lại và dùng dữ liệu game đã tự lưu.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Không", style: .cancel))
        alert.addAction(UIAlertAction(title: "Mở lại", style: .default) { [weak self] _ in
            self?.launch(game)
        })
        present(alert, animated: true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func appDidBecomeActive() {
        scanApps()
    }

    private func showLibraryHelp() {
        let alert = UIAlertController(title: "Hướng dẫn", message: """
            Thêm game:
            • Bấm + rồi chọn file .jar (chọn cùng lúc file .jad nếu game có).
            • Hoặc trong ứng dụng Tệp / Zalo / Safari: mở file .jar → Chia sẻ → KUONTPL.
            • Hoặc chép file .jar vào Tệp → Trên iPad → KUONTPL.

            Chơi:
            • Chạm vào game để chơi. Bấm ⋯ để chỉnh độ phân giải, xoay màn hình, kiểu phím, treo game.
            • Trong game, phím ≡ mở menu của KUONTPL (gõ chữ, kéo thả phím, chụp màn hình, thoát…).

            Game chạy sai hình: thử độ phân giải 240×320, hoặc độ phân giải ngang (320×240, 640×360) với game hỗ trợ màn ngang.
            """, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Đã hiểu", style: .default))
        present(alert, animated: true)
    }

    // ============================================================
    // MARK: - Import JAR from Files
    // ============================================================

    private func addAppTapped() {
        // Accept .jar plus anything else (downloads are sometimes renamed to .zip
        // or lose their extension); the content is checked on import.
        var types: [UTType] = [.zip, .data]
        if let jarType = UTType(filenameExtension: "jar") { types.insert(jarType, at: 0) }
        // asCopy: the system hands us a local copy (also downloads iCloud files)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        importFiles(urls)
    }

    /// Import .jar files picked in the app or opened from Files / another app.
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        loadViewIfNeeded()
        let dir = Self.gamesDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            let backups = urls.filter { GameStorage.isBackupFile($0) }
            let others = urls.filter { !GameStorage.isBackupFile($0) }
            var result = Self.importJARs(from: others, into: dir)
            for url in backups {
                let accessing = url.startAccessingSecurityScopedResource()
                if let name = GameStorage.importBackup(from: url, gamesDirectory: dir) {
                    result.imported.append(name + " (khôi phục từ bản sao lưu)")
                } else {
                    result.rejected.append(url.lastPathComponent + ": không phải bản sao lưu của KUONTPL")
                }
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            let finished = result
            DispatchQueue.main.async { [weak self] in
                self?.handleImported(finished)
            }
        }
    }

    nonisolated struct ImportResult: Sendable {
        var imported: [String] = []
        var rejected: [String] = []
    }

    nonisolated static func importJARs(from urls: [URL], into gamesDir: String) -> ImportResult {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: gamesDir, withIntermediateDirectories: true)
        var result = ImportResult()
        var importedJars: [String: String] = [:]          // picked file name (lowercased) → saved name
        var jads: [(name: String, data: Data)] = []

        for url in urls {
            let original = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            let (fileData, readError) = readPickedFile(url)
            guard let data = fileData, !data.isEmpty else {
                let why = readError ?? "file rỗng hoặc không có quyền đọc"
                result.rejected.append("\(original): không đọc được file (\(why))")
                print("[Import] FAILED to read \(original): \(why)")
                continue
            }

            // JAD descriptors are paired with their JAR after all JARs are saved
            if ext == "jad" {
                jads.append((original, data))
                continue
            }

            // A .jar is a ZIP archive: it must start with "PK"
            guard data.count >= 4, data[data.startIndex] == 0x50, data[data.startIndex + 1] == 0x4B else {
                result.rejected.append("\(original): không phải file .jar (sai định dạng)")
                print("[Import] REJECTED \(original): not a ZIP/JAR (\(data.count) bytes)")
                continue
            }

            var base = (ext == "jar" || ext == "zip") ? url.deletingPathExtension().lastPathComponent : original
            if base.lowercased().hasSuffix(".jar") { base = String(base.dropLast(4)) } // "game.jar.zip"
            if base.isEmpty { base = "game" }
            let destName = base + ".jar"
            let dest = URL(fileURLWithPath: gamesDir).appendingPathComponent(destName)
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try data.write(to: dest, options: .atomic)
                result.imported.append(destName)
                importedJars[original.lowercased()] = destName
                importedJars[destName.lowercased()] = destName
                print("[Import] \(original) -> games/\(destName) (\(data.count) bytes)")
            } catch {
                result.rejected.append("\(original): \(error.localizedDescription)")
                print("[Import] FAILED to save \(original): \(error)")
            }
        }

        for jad in jads {
            let text = String(decoding: jad.data, as: UTF8.self)
            var jarName: String?
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "midlet-jar-url" else { continue }
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                jarName = value.split(separator: "/").last.map(String.init) ?? value
            }
            // The JAR named in the JAD, the only JAR picked with it, or one already in the library
            var target: String?
            if let name = jarName?.lowercased(), let saved = importedJars[name] {
                target = saved
            } else if Set(importedJars.values).count == 1 {
                target = importedJars.values.first
            } else if let name = jarName, fm.fileExists(atPath: gamesDir + "/" + name) {
                target = name
            }
            guard let jar = target else {
                result.rejected.append("\(jad.name): cần chọn kèm file .jar của game (\(jarName ?? "không rõ tên"))")
                continue
            }
            let jadDest = URL(fileURLWithPath: gamesDir)
                .appendingPathComponent(String(jar.dropLast(4)) + ".jad")
            do {
                try jad.data.write(to: jadDest, options: .atomic)
                result.imported.append("\(jad.name) (mô tả cho \(jar))")
                print("[Import] \(jad.name) -> games/\(jadDest.lastPathComponent)")
            } catch {
                result.rejected.append("\(jad.name): \(error.localizedDescription)")
            }
        }
        return result
    }

    /// Read a picked / opened file through a file coordinator so iCloud and
    /// other providers deliver it first.
    nonisolated private static func readPickedFile(_ url: URL) -> (Data?, String?) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var data: Data?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        return (data, coordError?.localizedDescription)
    }

    private func handleImported(_ result: ImportResult) {
        scanApps()
        if AutoTest.showSettings { return }
        var message = ""
        if !result.imported.isEmpty {
            message += "Đã thêm \(result.imported.count) game:\n" + result.imported.joined(separator: "\n")
        }
        if !result.rejected.isEmpty {
            if !message.isEmpty { message += "\n\n" }
            message += "Không thêm được:\n" + result.rejected.joined(separator: "\n")
        }
        guard !message.isEmpty else { return }
        let alert = UIAlertController(title: result.rejected.isEmpty ? "Đã thêm game" : "Kết quả thêm game",
                                      message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        topPresenter().present(alert, animated: true)
    }

    private func topPresenter() -> UIViewController {
        var top: UIViewController = navigationController ?? self
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    // ============================================================
    // MARK: - Error reporting / diagnostics log
    // ============================================================

    static func presentLaunchFailure(gameName: String, details: String, from presenter: UIViewController) {
        var message = "\"\(gameName)\" dừng lại ngay khi khởi động."
        message += "\n\nCó thể thử: ở danh sách game bấm ⋯ → Cài đặt game… → Độ phân giải game → chọn độ phân giải khác (thường là 240×320)."
        if !details.isEmpty { message += "\n\nNhật ký lỗi:\n" + details }
        let alert = UIAlertController(title: "Không chạy được game", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Chia sẻ nhật ký", style: .default) { _ in
            shareLogs(from: presenter, barButtonItem: nil)
        })
        alert.addAction(UIAlertAction(title: "Đóng", style: .cancel))
        presenter.present(alert, animated: true)
    }

    static func shareLogs(from vc: UIViewController, barButtonItem: UIBarButtonItem?) {
        let urls = DiagnosticsLog.shareableURLs
        guard !urls.isEmpty else { return }
        let share = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let pop = share.popoverPresentationController {   // required on iPad
            if let barButtonItem {
                pop.sourceItem = barButtonItem
            } else {
                pop.sourceView = vc.view
                pop.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
        }
        vc.present(share, animated: true)
    }

    // ============================================================
    // MARK: - Library scanning (Documents/games/)
    // ============================================================

    private static func customNameKey(_ path: String) -> String { "customName_" + GameSettings(jarPath: path).id }
    private static func lastPlayedKey(_ path: String) -> String { "lastPlayed_" + GameSettings(jarPath: path).id }

    private func scanApps() {
        let gamesDir = Self.gamesDirectory
        let docsDir = Self.documentsDirectory
        let defaults = UserDefaults.standard
        // Read on the main thread, used on the scan thread
        var customNames: [String: String] = [:]
        var lastPlayed: [String: Double] = [:]
        var resolutions: [String: String] = [:]
        var playTimes: [String: Double] = [:]
        if let files = try? FileManager.default.contentsOfDirectory(atPath: gamesDir) {
            for file in files where file.lowercased().hasSuffix(".jar") {
                let path = gamesDir + "/" + file
                if let n = defaults.string(forKey: Self.customNameKey(path)), !n.isEmpty { customNames[path] = n }
                let t = defaults.double(forKey: Self.lastPlayedKey(path))
                if t > 0 { lastPlayed[path] = t }
                let settings = GameSettings(jarPath: path)
                resolutions[path] = "\(settings.resolution.w)×\(settings.resolution.h)"
                playTimes[path] = settings.playTimeSeconds
            }
        }

        let names = customNames, played = lastPlayed, sizes = resolutions, times = playTimes
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default

            // .jar files copied straight into "On My iPad › KUONTPL" → move into games/
            if let rootFiles = try? fm.contentsOfDirectory(atPath: docsDir) {
                for file in rootFiles where file.lowercased().hasSuffix(".jar") {
                    let dst = gamesDir + "/" + String(file.dropLast(4)) + ".jar"
                    try? fm.removeItem(atPath: dst)
                    try? fm.moveItem(atPath: docsDir + "/" + file, toPath: dst)
                    print("[Swift] Moved \(file) from Documents into games/")
                }
            }

            var entries: [GameEntry] = []
            let files = (try? fm.contentsOfDirectory(atPath: gamesDir)) ?? []
            for (index, file) in files.sorted().enumerated() where file.lowercased().hasSuffix(".jar") {
                let path = gamesDir + "/" + file
                let meta = JARMetadata.read(from: path)
                let name = names[path] ?? meta?.midletName ?? String(file.dropLast(4))
                let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
                let jad = gamesDir + "/" + String(file.dropLast(4)) + ".jad"
                entries.append(GameEntry(
                    id: path, name: name, fileName: file,
                    vendor: meta?.vendor, version: meta?.version, sizeBytes: size,
                    icon: Self.gameIcon(meta?.readIcon(from: path), name: name, index: index),
                    lastPlayed: played[path].map { Date(timeIntervalSince1970: $0) },
                    hasJad: fm.fileExists(atPath: jad),
                    resolution: sizes[path] ?? "240×320",
                    playTime: times[path] ?? 0,
                    problem: Self.problem(with: meta, jarPath: path)))
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.model.games != entries { self.model.games = entries }
                self.model.scanned = true
                self.offerResumeIfReady()
                if AutoTest.showSettings, !self.autoStarted, let game = entries.first {
                    self.autoStarted = true
                    self.openSettings(for: game)
                }
                if let name = AutoTest.autorunJarName, !self.autoStarted,
                   let game = entries.first(where: { $0.fileName == name }) {
                    self.autoStarted = true
                    self.launch(game)
                }
                print("[Swift] Found \(entries.count) MIDlet JARs in \(gamesDir)")
            }
        }
    }

    // ============================================================
    // MARK: - Icons
    // ============================================================

    /// Why a JAR cannot start, checked from its manifest and contents.
    private static func problem(with meta: JARMetadata?, jarPath: String) -> String? {
        guard let meta else { return "Thiếu MANIFEST.MF hoặc file hỏng" }
        guard let className = meta.className, !className.isEmpty else { return "Không có MIDlet-Class trong manifest" }
        let entry = className.replacingOccurrences(of: ".", with: "/") + ".class"
        return ZIPReader.extractEntry(zipPath: jarPath, entryName: entry) == nil ? "Không tìm thấy lớp \(className)" : nil
    }

    private static let iconSide: CGFloat = 60

    private static let placeholderGradients: [(UIColor, UIColor)] = [
        (UIColor(red: 0.20, green: 0.40, blue: 0.90, alpha: 1), UIColor(red: 0.35, green: 0.60, blue: 1.00, alpha: 1)),
        (UIColor(red: 0.00, green: 0.68, blue: 0.63, alpha: 1), UIColor(red: 0.20, green: 0.85, blue: 0.60, alpha: 1)),
        (UIColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 1), UIColor(red: 1.00, green: 0.75, blue: 0.28, alpha: 1)),
        (UIColor(red: 0.88, green: 0.22, blue: 0.28, alpha: 1), UIColor(red: 1.00, green: 0.42, blue: 0.48, alpha: 1)),
        (UIColor(red: 0.58, green: 0.28, blue: 0.85, alpha: 1), UIColor(red: 0.72, green: 0.48, blue: 1.00, alpha: 1)),
        (UIColor(red: 0.15, green: 0.65, blue: 0.42, alpha: 1), UIColor(red: 0.28, green: 0.82, blue: 0.55, alpha: 1)),
    ]

    /// The game's own icon scaled up with sharp pixels, or a coloured tile
    /// with the first letter of its name.
    private static func gameIcon(_ jarIcon: UIImage?, name: String, index: Int) -> UIImage {
        let side = iconSide
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            let cg = ctx.cgContext
            if let img = jarIcon, img.size.width > 0 {
                UIColor(white: 0.16, alpha: 1).setFill()
                cg.fill(rect)
                // Whole-number upscale of small pixel-art icons, centred
                let maxSide = max(img.size.width, img.size.height)
                let factor = maxSide <= side ? max(1, floor(side * 0.82 / maxSide)) : side * 0.82 / maxSide
                let w = img.size.width * factor, h = img.size.height * factor
                cg.interpolationQuality = .none
                img.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
            } else {
                let pair = placeholderGradients[index % placeholderGradients.count]
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                             colors: [pair.0.cgColor, pair.1.cgColor] as CFArray,
                                             locations: [0, 1]) {
                    cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
                }
                let letter = String(name.prefix(1)).uppercased()
                let attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: UIColor.white.withAlphaComponent(0.95),
                    .font: UIFont.systemFont(ofSize: side * 0.45, weight: .bold),
                ]
                let s = (letter as NSString).size(withAttributes: attrs)
                (letter as NSString).draw(at: CGPoint(x: (side - s.width) / 2, y: (side - s.height) / 2),
                                          withAttributes: attrs)
            }
        }
    }

    // ============================================================
    // MARK: - Per-game actions
    // ============================================================

    private static var documentsDirectory: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.path
    }

    private func rename(_ game: GameEntry) {
        let alert = UIAlertController(title: "Đổi tên game", message: "Để trống để dùng tên gốc của game.",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.text = game.name
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Lưu", style: .default) { [weak self, weak alert] _ in
            let name = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            let key = Self.customNameKey(game.path)
            if name.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
            else { UserDefaults.standard.set(name, forKey: key) }
            self?.scanApps()
        })
        present(alert, animated: true)
    }

    private func confirmClearGameData(for game: GameEntry) {
        let alert = UIAlertController(title: "Xóa dữ liệu lưu game",
                                       message: "Xóa toàn bộ dữ liệu lưu (tài khoản đã nhớ, màn chơi…) của \"\(game.name)\"?",
                                       preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Xóa", style: .destructive) { _ in
            let gid = GameSettings(jarPath: game.path).id
            try? FileManager.default.removeItem(atPath: Self.documentsDirectory + "/Games Data/" + gid)
        })
        present(alert, animated: true)
    }

    private func confirmDelete(_ game: GameEntry) {
        let alert = UIAlertController(title: "Xóa game",
                                       message: "Xóa \"\(game.name)\" và toàn bộ dữ liệu lưu của game?",
                                       preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Xóa", style: .destructive) { [weak self] _ in
            guard let self else { return }
            let fm = FileManager.default
            let gid = GameSettings(jarPath: game.path).id
            try? fm.removeItem(atPath: Self.documentsDirectory + "/Games Data/" + gid)
            try? fm.removeItem(atPath: game.path)
            try? fm.removeItem(atPath: String(game.path.dropLast(4)) + ".jad")
            self.model.games.removeAll { $0.id == game.id }
        })
        present(alert, animated: true)
    }

    /// Full settings screen (SwiftUI) for one game.
    private func openSettings(for game: GameEntry) {
        let settings = GameSettings(jarPath: game.path)
        weak var host: UIViewController?
        let settingsView = GameSettingsView(gameName: game.name, settings: settings,
                                            profiles: ControlProfileStore(settings: settings),
                                            onClose: { host?.dismiss(animated: true) })
        let controller = UIHostingController(rootView: settingsView)
        controller.modalPresentationStyle = .formSheet
        host = controller
        present(controller, animated: true)
    }

    private func backup(_ game: GameEntry) {
        let storage = GameStorage(settings: GameSettings(jarPath: game.path))
        DispatchQueue.global(qos: .userInitiated).async {
            let url = storage.exportBackup(jarPath: game.path)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let url else {
                    self.showMessage("Không tạo được bản sao lưu.")
                    return
                }
                let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let pop = share.popoverPresentationController {
                    pop.sourceView = self.view
                    pop.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
                    pop.permittedArrowDirections = []
                }
                self.present(share, animated: true)
            }
        }
    }

    private func restoreSnapshot(_ game: GameEntry) {
        let storage = GameStorage(settings: GameSettings(jarPath: game.path))
        guard storage.hasSnapshot else {
            showMessage("Chưa có bản lưu. Trong game, mở Menu ≡ → Lưu dữ liệu game để tạo.")
            return
        }
        let alert = UIAlertController(title: "Khôi phục dữ liệu", message: "Thay dữ liệu hiện tại của \"\(game.name)\" bằng bản đã lưu?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Khôi phục", style: .destructive) { [weak self] _ in
            self?.showMessage(storage.restoreSnapshot() ? "Đã khôi phục dữ liệu game." : "Không khôi phục được.")
        })
        present(alert, animated: true)
    }

    private func showMessage(_ text: String) {
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        topPresenter().present(alert, animated: true)
    }

    private func launch(_ game: GameEntry) {
        guard presentedViewController == nil else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastPlayedKey(game.path))
        let gameVC = GameViewController.make(jarPath: game.path, appName: game.name, appIcon: game.icon)
        gameVC.modalPresentationStyle = .fullScreen
        gameVC.modalTransitionStyle = .crossDissolve
        present(gameVC, animated: true)
    }
}
