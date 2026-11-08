//
//  GameSettingsView.swift
//  J2MEEmulator
//
//  SwiftUI settings screen for one game (opened from the game list or from
//  the in-game Menu). Every change is saved immediately; `onChange` lets an
//  open game apply it live.
//

import SwiftUI

struct GameSettingsView: View {
    let gameName: String
    let settings: GameSettings
    let profiles: ControlProfileStore
    var inGame = false
    var onChange: () -> Void = {}
    var onEditLayout: (() -> Void)? = nil
    var onClose: () -> Void = {}

    @State private var orientation: GameOrientation
    @State private var scaleMode: ScaleMode
    @State private var preset: KeyboardPreset
    @State private var keyTheme: KeyTheme
    @State private var keyShape: KeyShape
    @State private var smooth: Bool
    @State private var resolution: String
    @State private var profileIndex: Int
    @State private var opacity: Double
    @State private var keyScale: Double
    @State private var haptics: Bool
    @State private var keepScreenOn: Bool
    @State private var autoKey: Int32
    @State private var autoInterval: Int
    @State private var backgroundAudio: Bool
    @State private var idleFps: Int
    @State private var fps: Int
    @State private var smooth3D: Bool

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
        _orientation = State(initialValue: settings.orientation)
        _scaleMode = State(initialValue: settings.scaleMode)
        _preset = State(initialValue: profiles.active.preset)
        _keyTheme = State(initialValue: profiles.active.keyTheme)
        _keyShape = State(initialValue: profiles.active.keyShape)
        _smooth = State(initialValue: settings.smoothPicture)
        _resolution = State(initialValue: "\(res.w)x\(res.h)")
        _profileIndex = State(initialValue: profiles.activeIndex)
        _opacity = State(initialValue: profiles.active.opacity)
        _keyScale = State(initialValue: profiles.active.scale)
        _haptics = State(initialValue: settings.keyHaptics)
        _keepScreenOn = State(initialValue: settings.keepScreenOn)
        _autoKey = State(initialValue: settings.autoPressCode)
        _autoInterval = State(initialValue: settings.autoPressInterval)
        _backgroundAudio = State(initialValue: SessionKeeper.backgroundAudioEnabled)
        _idleFps = State(initialValue: settings.idleFps)
        _fps = State(initialValue: settings.fpsLimit)
        _smooth3D = State(initialValue: settings.supersampling3D)
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

    var body: some View {
        NavigationStack {
            Form {
                displaySection
                controlsSection
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
        }
    }

    // MARK: - Sections

    private var displaySection: some View {
        Section {
            Picker("Xoay màn hình", selection: saving($orientation) { settings.orientation = $0 }) {
                Text("Tự động theo máy").tag(GameOrientation.auto)
                Text("Luôn nằm ngang").tag(GameOrientation.landscape)
                Text("Luôn dựng dọc").tag(GameOrientation.portrait)
            }
            Picker("Kiểu hiển thị", selection: saving($scaleMode) { settings.scaleMode = $0 }) {
                ForEach(ScaleMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Toggle("Làm mịn hình", isOn: saving($smooth) { settings.smoothPicture = $0 })
            Picker("Độ phân giải game", selection: saving($resolution) { value in
                let parts = value.split(separator: "x").compactMap { Int($0) }
                if parts.count == 2 { settings.resolution = (parts[0], parts[1]) }
            }) {
                ForEach(GameSettings.resolutionOptions.indices, id: \.self) { i in
                    let opt = GameSettings.resolutionOptions[i]
                    Text(opt.label).tag("\(opt.w)x\(opt.h)")
                }
            }
        } header: {
            Text("Hiển thị")
        } footer: {
            Text(inGame ? "Đổi độ phân giải sẽ khởi động lại game khi bạn bấm Xong."
                        : "Game tự chọn bố cục theo độ phân giải; nếu hình bị lệch, quay về 240×320.")
        }
    }

    private var controlsSection: some View {
        Section {
            Picker("Hồ sơ phím", selection: saving($profileIndex) { index in
                profiles.select(index)
                opacity = profiles.active.opacity
                keyScale = profiles.active.scale
                preset = profiles.active.preset
                keyTheme = profiles.active.keyTheme
                keyShape = profiles.active.keyShape
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
            Picker("Màu phím", selection: saving($keyTheme) { profiles.active.keyTheme = $0 }) {
                ForEach(KeyTheme.allCases, id: \.self) { value in
                    Text(value.title).tag(value)
                }
            }
            Picker("Hình phím", selection: saving($keyShape) { profiles.active.keyShape = $0 }) {
                ForEach(KeyShape.allCases, id: \.self) { value in
                    Text(value.title).tag(value)
                }
            }
            VStack(alignment: .leading) {
                Text("Độ đậm phím đè lên game: \(Int(opacity * 100))%")
                Slider(value: saving($opacity) { profiles.active.opacity = $0 }, in: 0.15...1.0)
            }
            VStack(alignment: .leading) {
                Text("Cỡ phím: \(Int(keyScale * 100))%")
                Slider(value: saving($keyScale) { profiles.active.scale = $0 }, in: 0.7...1.4)
            }
            Toggle("Rung khi bấm phím", isOn: saving($haptics) { settings.keyHaptics = $0 })
            if let onEditLayout {
                Button {
                    onEditLayout()
                } label: {
                    Label("Kéo thả, đổi cỡ từng phím…", systemImage: "hand.draw")
                }
            }
        } header: {
            Text("Điều khiển")
        } footer: {
            Text("Bàn phím giống J2ME Loader: trượt ngón giữa các phím để đổi hướng, bấm nhiều phím cùng lúc, giữ để bấm liên tục. Phím chỉ mờ khi đè lên hình game. Mỗi hồ sơ lưu kiểu bàn phím, màu, cỡ và vị trí từng phím (riêng màn ngang và dọc). Tạo hồ sơ mới trong menu ≡ khi đang chơi.")
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
            Toggle("Giữ chạy nền (thử nghiệm)", isOn: saving($backgroundAudio) {
                SessionKeeper.shared.setBackgroundAudio($0)
            })
        } header: {
            Text("Treo game & chạy nền")
        } footer: {
            Text("""
            Cách treo ổn định nhất: trong game bấm Menu → Treo game → Treo máy ổn định (giữ máy luôn mở, màn tối, khóa chạm, giảm FPS; tự giảm thêm khi máy nóng). Bật thêm "Truy cập được hướng dẫn" của iOS để iPad không thoát khỏi game. Bật/tắt tự bấm trong Menu khi đang chơi.
            Giới hạn của iOS: khi bạn thoát ra ngoài hoặc khóa máy, iOS chỉ cho app chạy thêm khoảng 30 giây rồi tạm dừng (game mất kết nối). "Giữ chạy nền (thử nghiệm)" dùng chế độ âm thanh nền để app tiếp tục chạy — có tác dụng với bản cài qua Sideloadly nhưng không được App Store cho phép, tốn pin hơn, và iOS vẫn có thể đóng app khi thiếu bộ nhớ hoặc có cuộc gọi.
            """)
        }
    }

    private var advancedSection: some View {
        Section {
            Picker("Giới hạn FPS", selection: saving($fps) { settings.fpsLimit = $0 }) {
                ForEach(GameSettings.fpsOptions.indices, id: \.self) { i in
                    let opt = GameSettings.fpsOptions[i]
                    Text(opt.label).tag(opt.value)
                }
            }
            Toggle("Làm mịn đồ họa 3D", isOn: saving($smooth3D) { settings.supersampling3D = $0 })
        } header: {
            Text("Nâng cao")
        } footer: {
            Text("FPS thấp (15–20) giúp đỡ nóng máy và tiết kiệm pin khi treo lâu. Hai mục này áp dụng ở lần mở game tiếp theo.")
        }
    }
}
