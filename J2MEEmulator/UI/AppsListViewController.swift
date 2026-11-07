//
//  AppsListViewController.swift
//  J2MEEmulator
//
//  Springboard-style home screen with app grid.
//

import UIKit
import UniformTypeIdentifiers

class AppsListViewController: UIViewController,
                      UICollectionViewDataSource,
                      UICollectionViewDelegate,
                      UIDocumentPickerDelegate {

    private var springboardCollectionView: UICollectionView!
    private let emptyStateLabel = UILabel()
    private var lastLayoutWidth: CGFloat = 0

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
        view.backgroundColor = .black

        // Animated blob background
        let bg = AnimatedBackgroundView()
        bg.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bg)
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: view.topAnchor),
            bg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bg.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // "+" button — import JAR from Files
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .add, primaryAction: UIAction { [weak self] _ in
                self?.addAppTapped()
            })

        // "Nhật ký" — share the diagnostics log (Documents/logs)
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Nhật ký", primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                Self.shareLogs(from: self, barButtonItem: self.navigationItem.leftBarButtonItem)
            })

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 10

        springboardCollectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        springboardCollectionView.dataSource = self
        springboardCollectionView.delegate = self
        springboardCollectionView.backgroundColor = .clear
        springboardCollectionView.alwaysBounceVertical = true
        springboardCollectionView.showsVerticalScrollIndicator = false
        springboardCollectionView.register(SpringboardCell.self,
                                           forCellWithReuseIdentifier: SpringboardCell.reuseID)
        springboardCollectionView.contentInsetAdjustmentBehavior = .always
        springboardCollectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(springboardCollectionView)

        NSLayoutConstraint.activate([
            springboardCollectionView.topAnchor.constraint(equalTo: view.topAnchor),
            springboardCollectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            springboardCollectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            springboardCollectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Empty state
        emptyStateLabel.text = "Chưa có game\nBấm + để thêm file .jar"
        emptyStateLabel.textColor = .secondaryLabel
        emptyStateLabel.font = .systemFont(ofSize: 17)
        emptyStateLabel.textAlignment = .center
        emptyStateLabel.numberOfLines = 0
        emptyStateLabel.isHidden = true
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyStateLabel)
        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
        ])

        // Ensure games directory exists
        try? FileManager.default.createDirectory(atPath: Self.gamesDirectory,
                                                  withIntermediateDirectories: true)
        scanApps()
    }

    private var checkedLastCrash = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)

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
                    Self.shareLogs(from: self, barButtonItem: self.navigationItem.leftBarButtonItem)
                })
                alert.addAction(UIAlertAction(title: "Bỏ qua", style: .cancel))
                present(alert, animated: true)
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func appDidBecomeActive() {
        scanApps()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = springboardCollectionView.bounds.width
        guard width > 0, width != lastLayoutWidth else { return }
        lastLayoutWidth = width

        let columns: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 6 : 4
        let iconSize = SpringboardCell.iconSize
        let cellWidth = (width + iconSize) / (columns + 1)
        let horizontalInset = (cellWidth - iconSize) / 2

        guard let layout = springboardCollectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return }
        layout.itemSize = CGSize(width: cellWidth, height: 96)
        layout.sectionInset = UIEdgeInsets(top: 20, left: horizontalInset,
                                            bottom: 20, right: horizontalInset)
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
            let result = Self.importJARs(from: urls, into: dir)
            DispatchQueue.main.async { [weak self] in
                self?.handleImported(result)
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

        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let original = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            if ext == "jad" {
                result.rejected.append("\(original): file .jad chỉ là file mô tả, cần chọn file .jar")
                continue
            }

            // Read through a file coordinator so iCloud / other providers deliver the file
            var data: Data?
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
                data = try? Data(contentsOf: readURL)
            }
            guard let data, !data.isEmpty else {
                let why = coordError?.localizedDescription ?? "file rỗng hoặc không có quyền đọc"
                result.rejected.append("\(original): không đọc được file (\(why))")
                print("[Import] FAILED to read \(original): \(why)")
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
                print("[Import] \(original) -> games/\(destName) (\(data.count) bytes)")
            } catch {
                result.rejected.append("\(original): \(error.localizedDescription)")
                print("[Import] FAILED to save \(original): \(error)")
            }
        }
        return result
    }

    private func handleImported(_ result: ImportResult) {
        scanApps()
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
        message += "\n\nCó thể thử: bấm giữ icon game → Screen Resolution → chọn độ phân giải khác."
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
    // MARK: - App scanning (Documents/games/)
    // ============================================================

    struct AppInfo {
        let name: String
        let path: String
        let fileName: String
        let version: String?
        let vendor: String?
        let icon: UIImage
    }
    private var apps: [AppInfo] = []

    private func scanApps() {
        let gamesDir = Self.gamesDirectory
        let docsDir = Self.documentsDirectory

        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var jarPaths: [(name: String, path: String)] = []

            // .jar files copied straight into "On My iPad › JarBox" → move into games/
            if let rootFiles = try? fm.contentsOfDirectory(atPath: docsDir) {
                for file in rootFiles where file.lowercased().hasSuffix(".jar") {
                    let dst = gamesDir + "/" + String(file.dropLast(4)) + ".jar"
                    try? fm.removeItem(atPath: dst)
                    try? fm.moveItem(atPath: docsDir + "/" + file, toPath: dst)
                    print("[Swift] Moved \(file) from Documents into games/")
                }
            }

            if let files = try? fm.contentsOfDirectory(atPath: gamesDir) {
                for file in files where file.lowercased().hasSuffix(".jar") {
                    jarPaths.append((name: String(file.dropLast(4)), path: gamesDir + "/" + file))
                }
            }

            var unsorted = jarPaths.map { jar -> (String, String, String, String?, String?, UIImage?) in
                let meta = JARMetadata.read(from: jar.path)
                let jarIcon = meta?.readIcon(from: jar.path)
                let fileName = URL(fileURLWithPath: jar.path).lastPathComponent
                let appName = meta?.midletName ?? jar.name
                return (appName, jar.path, fileName, meta?.version, meta?.vendor, jarIcon)
            }
            unsorted.sort { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }

            let scannedApps = unsorted.enumerated().map { (index, t) in
                AppInfo(name: t.0, path: t.1, fileName: t.2,
                        version: t.3, vendor: t.4,
                        icon: Self.springboardIcon(t.5, name: t.0, index: index))
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.apps = scannedApps
                self.springboardCollectionView.reloadData()
                self.emptyStateLabel.isHidden = !scannedApps.isEmpty
                print("[Swift] Found \(scannedApps.count) MIDlet JARs in \(gamesDir)")
            }
        }
    }

    // ============================================================
    // MARK: - Icon generation
    // ============================================================

    private static let iconSize: CGFloat = SpringboardCell.iconSize

    private static let placeholderGradients: [(UIColor, UIColor)] = [
        (UIColor(red: 0.20, green: 0.40, blue: 0.90, alpha: 1),
         UIColor(red: 0.35, green: 0.60, blue: 1.00, alpha: 1)),
        (UIColor(red: 0.00, green: 0.68, blue: 0.63, alpha: 1),
         UIColor(red: 0.20, green: 0.85, blue: 0.60, alpha: 1)),
        (UIColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 1),
         UIColor(red: 1.00, green: 0.75, blue: 0.28, alpha: 1)),
        (UIColor(red: 0.88, green: 0.22, blue: 0.28, alpha: 1),
         UIColor(red: 1.00, green: 0.42, blue: 0.48, alpha: 1)),
        (UIColor(red: 0.58, green: 0.28, blue: 0.85, alpha: 1),
         UIColor(red: 0.72, green: 0.48, blue: 1.00, alpha: 1)),
        (UIColor(red: 0.22, green: 0.30, blue: 0.80, alpha: 1),
         UIColor(red: 0.38, green: 0.48, blue: 0.95, alpha: 1)),
        (UIColor(red: 0.90, green: 0.28, blue: 0.52, alpha: 1),
         UIColor(red: 1.00, green: 0.48, blue: 0.68, alpha: 1)),
        (UIColor(red: 0.15, green: 0.65, blue: 0.42, alpha: 1),
         UIColor(red: 0.28, green: 0.82, blue: 0.55, alpha: 1)),
    ]

    private static func springboardIcon(_ jarIcon: UIImage?, name: String, index: Int) -> UIImage {
        let size = CGSize(width: iconSize, height: iconSize)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)

            UIBezierPath(roundedRect: rect, cornerRadius: SpringboardCell.iconCornerRadius).addClip()

            if let img = jarIcon {
                UIColor(white: 0.22, alpha: 1).setFill()
                UIBezierPath(rect: rect).fill()
                img.draw(in: rect)
            } else {
                let pair = placeholderGradients[index % placeholderGradients.count]
                let cgCtx = ctx.cgContext
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                if let gradient = CGGradient(colorsSpace: colorSpace,
                                              colors: [pair.0.cgColor, pair.1.cgColor] as CFArray,
                                              locations: [0, 1]) {
                    cgCtx.drawLinearGradient(gradient, start: .zero,
                                             end: CGPoint(x: iconSize, y: iconSize), options: [])
                }
                let letter = String(name.prefix(1)).uppercased()
                let attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: UIColor.white.withAlphaComponent(0.9),
                    .font: UIFont.systemFont(ofSize: iconSize * 0.42, weight: .semibold)
                ]
                let strSize = (letter as NSString).size(withAttributes: attrs)
                (letter as NSString).draw(
                    at: CGPoint(x: (iconSize - strSize.width) / 2,
                                y: (iconSize - strSize.height) / 2),
                    withAttributes: attrs)
            }

            let borderPath = UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                           cornerRadius: SpringboardCell.iconCornerRadius - 0.5)
            UIColor(white: 1.0, alpha: 0.12).setStroke()
            borderPath.lineWidth = 1
            borderPath.stroke()
        }
    }

    // ============================================================
    // MARK: - UICollectionView
    // ============================================================

    func collectionView(_ collectionView: UICollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        apps.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: SpringboardCell.reuseID, for: indexPath) as! SpringboardCell
        let app = apps[indexPath.item]
        cell.configure(name: app.name, icon: app.icon)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first else { return nil }
        let app = apps[indexPath.item]
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            let ssEnabled = Self.is3DSupersampling(for: app)
            let toggle3D = UIAction(title: ssEnabled ? "Disable 3D Enhancement" : "Enable 3D Enhancement",
                                    subtitle: ssEnabled ? "Lower quality, but closer to original" : "Smoother 3D, but not original-accurate",
                                    image: UIImage(systemName: "cube"),
                                    state: ssEnabled ? .on : .off) { _ in
                Self.set3DSupersampling(!ssEnabled, for: app)
            }
            let clearData = UIAction(title: "Clear Game Data",
                                     image: UIImage(systemName: "eraser")) { _ in
                self?.confirmClearGameData(for: app)
            }
            let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"),
                                  attributes: .destructive) { _ in
                self?.confirmDeleteApp(at: indexPath)
            }
            let currentRes = Self.resolution(for: app)
            let resActions = Self.resolutionOptions.map { opt in
                UIAction(title: opt.label,
                         state: (opt.w == currentRes.w && opt.h == currentRes.h) ? .on : .off) { _ in
                    Self.setResolution(w: opt.w, h: opt.h, for: app)
                }
            }
            let resMenu = UIMenu(title: "Screen Resolution",
                                  image: UIImage(systemName: "aspectratio"),
                                  children: resActions)

            let currentFps = Self.fpsLimit(for: app)
            let fpsActions = Self.fpsLimitOptions.map { opt in
                UIAction(title: opt.label,
                         state: opt.value == currentFps ? .on : .off) { _ in
                    Self.setFpsLimit(opt.value, for: app)
                }
            }
            let fpsMenu = UIMenu(title: "FPS Limit",
                                  subtitle: "High FPS may break some games",
                                  image: UIImage(systemName: "gauge.with.needle"),
                                  children: fpsActions)

            let currentOrientation = GameOrientation.saved(forJar: app.path)
            let orientationActions: [UIAction] = [
                (GameOrientation.auto, "Tự xoay theo iPad"),
                (GameOrientation.landscape, "Luôn nằm ngang"),
                (GameOrientation.portrait, "Luôn dựng dọc"),
            ].map { value, title in
                UIAction(title: title, state: value == currentOrientation ? .on : .off) { _ in
                    GameOrientation.save(value, forJar: app.path)
                }
            }
            let orientationMenu = UIMenu(title: "Hướng màn hình",
                                         image: UIImage(systemName: "rotate.right"),
                                         children: orientationActions)

            let settings = UIMenu(options: .displayInline,
                                  children: [toggle3D, resMenu, orientationMenu, fpsMenu])
            let actions = UIMenu(options: .displayInline, children: [clearData, delete])
            return UIMenu(children: [settings, actions])
        })
    }

    // MARK: - Per-game settings

    private static func gameId(for app: AppInfo) -> String {
        let jarName = URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent
        return jarName.replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
    }

    static func is3DSupersampling(for app: AppInfo) -> Bool {
        UserDefaults.standard.object(forKey: "ss3d_\(gameId(for: app))") as? Bool ?? true
    }

    static func set3DSupersampling(_ enabled: Bool, for app: AppInfo) {
        UserDefaults.standard.set(enabled, forKey: "ss3d_\(gameId(for: app))")
    }

    private static let resolutionOptions: [(label: String, w: Int, h: Int)] = [
        // Landscape (good on a sideways iPad, for games that adapt to the screen size)
        ("320×240 (ngang)", 320, 240),
        ("400×240 (ngang)", 400, 240),
        ("480×320 (ngang)", 480, 320),
        ("640×360 (ngang)", 640, 360),
        ("800×480 (ngang)", 800, 480),
        // Common J2ME resolutions (portrait / square)
        ("101×80",   101,  80),
        ("128×128",  128, 128),
        ("128×160",  128, 160),
        ("132×176",  132, 176),
        ("160×128",  160, 128),
        ("176×208",  176, 208),
        ("176×220",  176, 220),
        ("208×208",  208, 208),
        ("220×220",  220, 220),
        ("240×266",  240, 266),
        ("240×320",  240, 320),
        ("240×400",  240, 400),
        ("320×480",  320, 480),
        ("352×416",  352, 416),
        ("360×640",  360, 640),
        ("480×800",  480, 800),
    ]

    static func resolution(for app: AppInfo) -> (w: Int, h: Int) {
        let gid = gameId(for: app)
        let w = UserDefaults.standard.object(forKey: "resW_\(gid)") as? Int ?? 240
        let h = UserDefaults.standard.object(forKey: "resH_\(gid)") as? Int ?? 320
        return (w, h)
    }

    private static func setResolution(w: Int, h: Int, for app: AppInfo) {
        let gid = gameId(for: app)
        UserDefaults.standard.set(w, forKey: "resW_\(gid)")
        UserDefaults.standard.set(h, forKey: "resH_\(gid)")
    }

    private static let fpsLimitOptions: [(label: String, value: Int)] = [
        ("Unlimited", 0),
        ("15 FPS",   15),
        ("20 FPS",   20),
        ("30 FPS",   30),
        ("60 FPS",   60),
    ]

    static func fpsLimit(for app: AppInfo) -> Int {
        UserDefaults.standard.object(forKey: "fpsLimit_\(gameId(for: app))") as? Int ?? 60
    }

    private static func setFpsLimit(_ fps: Int, for app: AppInfo) {
        UserDefaults.standard.set(fps, forKey: "fpsLimit_\(gameId(for: app))")
    }

    private static var documentsDirectory: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.path
    }

    private func confirmClearGameData(for app: AppInfo) {
        let alert = UIAlertController(title: "Clear Game Data",
                                       message: "Delete all save data for \(app.name)?",
                                       preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            let gid = Self.gameId(for: app)
            try? FileManager.default.removeItem(atPath: Self.documentsDirectory + "/Games Data/" + gid)
        })
        present(alert, animated: true)
    }

    private func confirmDeleteApp(at indexPath: IndexPath) {
        let app = apps[indexPath.item]
        let alert = UIAlertController(title: "Delete Game",
                                       message: "Delete \(app.name) and all its save data?",
                                       preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            let gid = Self.gameId(for: app)
            try? FileManager.default.removeItem(atPath: Self.documentsDirectory + "/Games Data/" + gid)
            try? FileManager.default.removeItem(atPath: app.path)
            self.springboardCollectionView.performBatchUpdates {
                self.apps.remove(at: indexPath.item)
                self.springboardCollectionView.deleteItems(at: [indexPath])
            }
            self.emptyStateLabel.isHidden = !self.apps.isEmpty
        })
        present(alert, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView,
                        didSelectItemAt indexPath: IndexPath) {
        let app = apps[indexPath.item]

        let render3dScale = Self.is3DSupersampling(for: app) ? 3 : 1
        let res = Self.resolution(for: app)
        let fps = Self.fpsLimit(for: app)
        let gameVC = GameViewController(jarPath: app.path, appName: app.name, appIcon: app.icon,
                                         canvasWidth: res.w, canvasHeight: res.h,
                                         render3dScale: render3dScale, fpsLimit: fps)
        gameVC.modalPresentationStyle = .fullScreen

        let itemIndex = indexPath.item
        let options = UIViewController.Transition.ZoomOptions()
        options.interactiveDismissShouldBegin = { _ in false }
        // Zoom lands on the placeholder icon centered in the game screen
        options.alignmentRectProvider = { context in
            guard let gvc = context.zoomedViewController as? GameViewController,
                  let placeholder = gvc.placeholderIconView else {
                return .null
            }
            return placeholder.frame
        }

        gameVC.preferredTransition = .zoom(options: options) {
            [weak self] _ in
            guard let self,
                  let cell = self.springboardCollectionView.cellForItem(
                      at: IndexPath(item: itemIndex, section: 0)) as? SpringboardCell else {
                return nil
            }
            return cell.iconView
        }

        present(gameVC, animated: true)
    }
}
