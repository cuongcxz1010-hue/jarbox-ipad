//
//  GameSettingsView.swift
//  J2MEEmulator
//
//  Settings of one game (SwiftUI), opened from the library or the in-game
//  menu. Every change is saved immediately; `onChange` lets a running game
//  apply it live. Settings the JVM reads at startup are marked as such.
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct GameSettingsView: View {
    let gameName: String
    let settings: GameSettings
    let profiles: ControlProfileStore
    var inGame = false
    var onChange: () -> Void = {}
    var onEditLayout: (() -> Void)? = nil
    var onClose: () -> Void = {}

    // Display
    @State private var orientation: GameOrientation
    @State private var scaleMode: ScaleMode
    @State private var smooth: Bool
    @State private var resolution: String
    @State private var customW: String
    @State private var customH: String
    @State private var fps: Int
    // Sound
    @State private var sound: Bool
    // Controls
    @State private var profileIndex: Int
    @State private var preset: KeyboardPreset
    @State private var keyTheme: KeyTheme
    @State private var keyShape: KeyShape
    @State private var opacity: Double
    @State private var keyScale: Double
    @State private var spacing: Double
    @State private var useJoystick: Bool
    @State private var deadZone: Double
    @State private var repeatDefault: Bool
    @State private var repeatDelay: Double
    @State private var repeatInterval: Double
    @State private var haptics: Bool
    @State private var keyLayout: KeyLayout
    @State private var fillColor: Color
    @State private var textColor: Color
    @State private var customColors: Bool
    // Text
    @State private var fontAuto: Bool
    @State private var fontSmall: Double
    @State private var fontMedium: Double
    @State private var fontLarge: Double
    // Idle
    @State private var keepScreenOn: Bool
    @State private var autoKey: Int32
    @State private var autoInterval: Int
    @State private var idleFps: Int
    // Advanced
    @State private var heapMB: Int
    @State private var smooth3D: Bool
    @State private var callPause: Bool
    @State private var connectTimeout: Int
    // Sheets
    @State private var showImporter = false
    @State private var exportURL: URL?
    @State private var showExporter = false
    @State private var message: String?

    init(gameName: String, settings: GameSettings, profiles: ControlProfileStore, inGame: Bool = false,
         onChange: @escaping () -> Void = {}, onEditLayout: (() -> Void)? = nil,
         onClose: @escaping () -> Void = {}) {
        self.gameName = gameName
        self.settings = settings
        self.profiles = profiles
        self.inGame = inGame
        self.onChange = onChange
        self.onEditLayout = onEditLayout
        self.onClose = onClose
        let res = settings.resolution
        let active = profiles.active
        let isPreset = GameSettings.resolutionOptions.contains { $0.w == res.w && $0.h == res.h }
        _orientation = State(initialValue: settings.orientation)
        _scaleMode = State(initialValue: settings.scaleMode)
        _smooth = State(initialValue: settings.smoothPicture)
        _resolution = State(initialValue: isPreset ? "\(res.w)x\(res.h)" : "custom")
        _customW = State(initialValue: String(res.w))
        _customH = State(initialValue: String(res.h))
        _fps = State(initialValue: settings.fpsLimit)
        _sound = State(initialValue: settings.soundEnabled)
        _profileIndex = State(initialValue: profiles.activeIndex)
        _preset = State(initialValue: active.preset)
        _keyTheme = State(initialValue: active.keyTheme)
        _keyShape = State(initialValue: active.keyShape)
        _opacity = State(initialValue: active.opacity)
        _keyScale = State(initialValue: active.scale)
        _spacing = State(initialValue: active.keySpacing)
        _useJoystick = State(initialValue: active.useJoystick)
        _deadZone = State(initialValue: active.deadZone)
        _repeatDefault = State(initialValue: active.repeatDelayMs == nil)
        _repeatDelay = State(initialValue: Double(active.repeatDelayMs ?? 400))
        _repeatInterval = State(initialValue: Double(active.repeatIntervalMs ?? 80))
        _haptics = State(initialValue: settings.keyHaptics)
        _keyLayout = State(initialValue: settings.keyLayout)
        _customColors = State(initialValue: active.fillColorHex != nil)
        _fillColor = State(initialValue: Color(UIColor(hex: active.fillColorHex) ?? .lightGray))
        _textColor = State(initialValue: Color(UIColor(hex: active.textColorHex) ?? .black))
        let fonts = settings.fontSizes
        _fontAuto = State(initialValue: fonts.small == 0)
        _fontSmall = State(initialValue: Double(fonts.small > 0 ? fonts.small : 18))
        _fontMedium = State(initialValue: Double(fonts.medium > 0 ? fonts.medium : 22))
        _fontLarge = State(initialValue: Double(fonts.large > 0 ? fonts.large : 26))
        _keepScreenOn = State(initialValue: settings.keepScreenOn)
        _autoKey = State(initialValue: settings.autoPressCode)
        _autoInterval = State(initialValue: settings.autoPressInterval)
        _idleFps = State(initialValue: settings.idleFps)
        _heapMB = State(initialValue: settings.heapMB)
        _smooth3D = State(initialValue: settings.supersampling3D)
        _callPause = State(initialValue: settings.callPauseApp)
        _connectTimeout = State(initialValue: settings.connectTimeoutSeconds)
    }

    /// Binding that also saves the value and notifies the game.
    private func saving<T>(_ value: Binding<T>, _ apply: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: { value.wrappedValue },
                set: { newValue in
                    value.wrappedValue = newValue
                    apply(newValue)
                    onChange()
                })
    }

    private func saveCustomResolution() {
        guard let w = Int(customW), let h = Int(customH), (16...2048).contains(w), (16...2048).contains(h) else { return }
        settings.resolution = (w, h)
        onChange()
    }

    private func syncProfileState() {
        let active = profiles.active
        opacity = active.opacity
        keyScale = active.scale
        preset = active.preset
        keyTheme = active.keyTheme
        keyShape = active.keyShape
        spacing = active.keySpacing
        useJoystick = active.useJoystick
        deadZone = active.deadZone
        repeatDefault = active.repeatDelayMs == nil
    }

    private func saveFonts() {
        settings.fontSizes = fontAuto ? (0, 0, 0) : (Int(fontSmall), Int(fontMedium), Int(fontLarge))
    }

    private func applyColors() {
        var p = profiles.active
        p.fillColorHex = customColors ? UIColor(fillColor).hexString : nil
        p.textColorHex = customColors ? UIColor(textColor).hexString : nil
        profiles.active = p
        onChange()
    }

    private func applyRepeat() {
        var p = profiles.active
        p.repeatDelayMs = repeatDefault ? nil : Int(repeatDelay)
        p.repeatIntervalMs = repeatDefault ? nil : Int(repeatInterval)
        profiles.active = p
        onChange()
    }

    var body: some View {
        NavigationStack {
            Form {
                displaySection
                soundSection
                controlsSection
                keyboardFineSection
                textSection
                idleSection
                advancedSection
            }
            .navigationTitle(gameName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { onClose() }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .data]) { result in
                importProfile(result)
            }
            .sheet(isPresented: $showExporter) {
                if let exportURL { ShareSheet(url: exportURL) }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { }
            }
        }
    }

    // MARK: - Sections

    private var displaySection: some View {
        Section {
            Picker("Độ phân giải", selection: saving($resolution) { value in
                let parts = value.split(separator: "x").compactMap { Int($0) }
                if parts.count == 2 {
                    settings.resolution = (parts[0], parts[1])
                    customW = String(parts[0])
                    customH = String(parts[1])
                }
            }) {
                ForEach(GameSettings.resolutionOptions.indices, id: \.self) { i in
                    let opt = GameSettings.resolutionOptions[i]
                    Text(opt.label).tag("\(opt.w)x\(opt.h)")
                }
                Text("Tùy chỉnh…").tag("custom")
            }
            if resolution == "custom" {
                HStack {
                    TextField("Rộng", text: $customW).keyboardType(.numberPad)
                    Text("×")
                    TextField("Cao", text: $customH).keyboardType(.numberPad)
                    Button("Áp dụng") { saveCustomResolution() }
                }
            }
            Picker("Tỷ lệ hiển thị", selection: saving($scaleMode) { settings.scaleMode = $0 }) {
                ForEach(ScaleMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Toggle("Lọc mịn hình (tắt = điểm ảnh sắc nét)", isOn: saving($smooth) { settings.smoothPicture = $0 })
            Picker("Xoay màn hình", selection: saving($orientation) { settings.orientation = $0 }) {
                Text("Tự động theo máy").tag(GameOrientation.auto)
                Text("Luôn nằm ngang").tag(GameOrientation.landscape)
                Text("Luôn dựng dọc").tag(GameOrientation.portrait)
            }
            Picker("Giới hạn FPS", selection: saving($fps) { settings.fpsLimit = $0 }) {
                ForEach(GameSettings.fpsOptions.indices, id: \.self) { i in
                    let opt = GameSettings.fpsOptions[i]
                    Text(opt.label).tag(opt.value)
                }
            }
        } header: {
            Text("Hiển thị")
        } footer: {
            Text(inGame ? "Đổi độ phân giải hoặc FPS sẽ áp dụng khi mở lại game." : "Game tự bố trí theo độ phân giải. Nếu hình bị lệch, quay về 240×320.")
        }
    }

    private var soundSection: some View {
        Section("Âm thanh") {
            Toggle("Bật âm thanh game", isOn: saving($sound) { settings.soundEnabled = $0 })
        }
    }

    private var controlsSection: some View {
        Section {
            Picker("Hồ sơ phím", selection: saving($profileIndex) { index in
                profiles.select(index)
                syncProfileState()
            }) {
                ForEach(profiles.profiles.indices, id: \.self) { i in
                    Text(profiles.profiles[i].name).tag(i)
                }
            }
            Picker("Kiểu bàn phím", selection: saving($preset) { profiles.active.preset = $0 }) {
                ForEach(KeyboardPreset.allCases, id: \.self) { value in
                    Text(value.title).tag(value)
                }
            }
            Toggle("Dùng cần điều khiển 8 hướng thay mũi tên", isOn: saving($useJoystick) { profiles.active.useJoystick = $0 })
            if useJoystick {
                VStack(alignment: .leading) {
                    Text("Độ nhạy cần điều khiển: \(Int((1 - deadZone) * 100))%")
                    Slider(value: saving($deadZone) { profiles.active.deadZone = $0 }, in: 0.1...0.6)
                }
            }
            Picker("Bộ mã phím theo hãng", selection: saving($keyLayout) { settings.keyLayout = $0 }) {
                ForEach(KeyLayout.allCases, id: \.self) { value in
                    Text(value.title).tag(value)
                }
            }
            Toggle("Rung khi bấm phím", isOn: saving($haptics) { settings.keyHaptics = $0 })
            if let onEditLayout {
                Button {
                    onEditLayout()
                } label: {
                    Label("Kéo thả, đổi cỡ, ẩn từng phím…", systemImage: "hand.draw")
                }
            }
        } header: {
            Text("Điều khiển")
        } footer: {
            Text("Trượt ngón giữa các phím để đổi hướng, bấm nhiều phím cùng lúc, giữ để bấm liên tục. Mỗi hồ sơ lưu kiểu bàn phím, màu, cỡ, vị trí từng phím (riêng ngang và dọc). Bộ mã phím áp dụng ở lần mở game tiếp theo.")
        }
    }

    private var keyboardFineSection: some View {
        Section {
            Picker("Màu phím", selection: saving($keyTheme) { profiles.active.keyTheme = $0 }) {
                ForEach(KeyTheme.allCases, id: \.self) { value in
                    Text(value.title).tag(value)
                }
            }
            Toggle("Tự chọn màu", isOn: Binding(get: { customColors }, set: { customColors = $0; applyColors() }))
            if customColors {
                ColorPicker("Màu nền phím", selection: Binding(get: { fillColor }, set: { fillColor = $0; applyColors() }), supportsOpacity: false)
                ColorPicker("Màu chữ phím", selection: Binding(get: { textColor }, set: { textColor = $0; applyColors() }), supportsOpacity: false)
            }
            Picker("Hình phím", selection: saving($keyShape) { profiles.active.keyShape = $0 }) {
                ForEach(KeyShape.allCases, id: \.self) { value in
                    Text(value.title).tag(value)
                }
            }
            sliderRow("Cỡ phím", value: $keyScale, range: 0.7...1.4, suffix: "%", factor: 100) { profiles.active.scale = $0 }
            sliderRow("Độ đậm phím đè lên game", value: $opacity, range: 0.15...1.0, suffix: "%", factor: 100) { profiles.active.opacity = $0 }
            sliderRow("Khoảng cách giữa các phím", value: $spacing, range: 0.5...2.5, suffix: "%", factor: 100) { profiles.active.keySpacing = $0 }
            Toggle("Giữ phím theo mặc định J2ME Loader", isOn: Binding(get: { repeatDefault }, set: { repeatDefault = $0; applyRepeat() }))
            if !repeatDefault {
                VStack(alignment: .leading) {
                    Text("Độ trễ trước khi lặp: \(Int(repeatDelay)) ms")
                    Slider(value: Binding(get: { repeatDelay }, set: { repeatDelay = $0; applyRepeat() }), in: 100...1000, step: 20)
                }
                VStack(alignment: .leading) {
                    Text("Khoảng lặp: \(Int(repeatInterval)) ms")
                    Slider(value: Binding(get: { repeatInterval }, set: { repeatInterval = $0; applyRepeat() }), in: 30...400, step: 10)
                }
            }
            Button {
                exportProfiles()
            } label: {
                Label("Xuất cấu hình phím…", systemImage: "square.and.arrow.up")
            }
            Button {
                showImporter = true
            } label: {
                Label("Nhập cấu hình phím…", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Bàn phím chi tiết")
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String,
                           factor: Double, apply: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(Int(value.wrappedValue * factor))\(suffix)")
            Slider(value: saving(value, apply), in: range)
        }
    }

    private var textSection: some View {
        Section {
            Toggle("Cỡ chữ tự động theo độ phân giải", isOn: Binding(get: { fontAuto }, set: { fontAuto = $0; saveFonts() }))
            if !fontAuto {
                fontRow("Nhỏ", value: $fontSmall)
                fontRow("Vừa", value: $fontMedium)
                fontRow("Lớn", value: $fontLarge)
            }
        } header: {
            Text("Chữ trong game")
        } footer: {
            Text("Áp dụng cho game dùng phông của máy, không áp dụng cho game có phông riêng. Có hiệu lực khi mở lại game.")
        }
    }

    private func fontRow(_ title: String, value: Binding<Double>) -> some View {
        Stepper(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; saveFonts() }), in: 8...40) {
            Text("\(title): \(Int(value.wrappedValue)) px")
        }
    }

    private var idleSection: some View {
        Section {
            Toggle("Giữ màn hình luôn sáng", isOn: saving($keepScreenOn) { settings.keepScreenOn = $0 })
            Picker("FPS khi treo", selection: saving($idleFps) { settings.idleFps = $0 }) {
                ForEach(GameSettings.idleFpsOptions.indices, id: \.self) { i in
                    let opt = GameSettings.idleFpsOptions[i]
                    Text(opt.label).tag(opt.value)
                }
            }
            Picker("Tự động bấm phím", selection: saving($autoKey) { settings.autoPressCode = $0 }) {
                ForEach(GameSettings.autoPressKeys.indices, id: \.self) { i in
                    let key = GameSettings.autoPressKeys[i]
                    Text(key.label).tag(key.code)
                }
            }
            Picker("Chu kỳ tự bấm", selection: saving($autoInterval) { settings.autoPressInterval = $0 }) {
                ForEach(GameSettings.autoPressIntervals, id: \.self) { s in
                    Text(s < 60 ? "\(s) giây" : "\(s / 60) phút").tag(s)
                }
            }
        } header: {
            Text("Treo game")
        } footer: {
            Text("""
            Khi game đang mở: chạy bình thường, có thể bật "Treo máy ổn định" trong Menu ≡ (màn tối, giảm FPS).
            Khi chuyển ứng dụng hoặc khóa màn hình: iOS chỉ cho chạy thêm khoảng 30 giây rồi tạm dừng ứng dụng; máy chủ sẽ ngắt kết nối sau đó.
            JarBox không dùng âm thanh giả hay GPS giả để lách giới hạn này. Khi quay lại, game tự kết nối lại nếu game có hỗ trợ. Nếu iOS đã đóng app, game mở lại từ dữ liệu đã lưu.
            """)
        }
    }

    private var advancedSection: some View {
        Section {
            Picker("Bộ nhớ JVM tối đa", selection: saving($heapMB) { settings.heapMB = $0 }) {
                ForEach([64, 96, 128, 192, 256, 384], id: \.self) { mb in
                    Text("\(mb) MB").tag(mb)
                }
            }
            Picker("Thời gian chờ kết nối", selection: saving($connectTimeout) { settings.connectTimeoutSeconds = $0 }) {
                ForEach([10, 20, 30, 60], id: \.self) { s in
                    Text("\(s) giây").tag(s)
                }
            }
            Toggle("Gọi pauseApp khi rời ứng dụng", isOn: saving($callPause) { settings.callPauseApp = $0 })
            Toggle("Làm mịn đồ họa 3D", isOn: saving($smooth3D) { settings.supersampling3D = $0 })
        } header: {
            Text("Tương thích")
        } footer: {
            Text("""
            pauseApp: tắt theo mặc định vì một số game khởi động lại khi được gọi startApp; phần lớn điện thoại thật chỉ báo hideNotify. Các mục này có hiệu lực khi mở lại game.
            """)
        }
    }

    // MARK: - Import / export

    private func exportProfiles() {
        guard let data = profiles.exportJSON() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(settings.id)-phim.json")
        do {
            try data.write(to: url, options: .atomic)
            exportURL = url
            showExporter = true
        } catch {
            message = "Không tạo được file: \(error.localizedDescription)"
        }
    }

    private func importProfile(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            message = error.localizedDescription
        case .success(let url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), profiles.importJSON(data) else {
                message = "File không phải cấu hình phím của JarBox."
                return
            }
            profileIndex = profiles.activeIndex
            syncProfileState()
            onChange()
            message = "Đã nhập \(profiles.profiles.count) hồ sơ phím."
        }
    }
}

/// System share sheet for a file.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
