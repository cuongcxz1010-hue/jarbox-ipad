//
//  LibraryView.swift
//  J2MEEmulator
//
//  Game library (SwiftUI), in the spirit of J2ME Loader's app list:
//  icon, name, vendor, version and size of every game; tap to play;
//  ⋯ (or long-press / swipe) for settings, rename, clear data, delete;
//  + to add .jar / .jad files; search and sort.
//

import SwiftUI
import UIKit

struct GameEntry: Identifiable, Equatable {
    let id: String              // path of the .jar
    let name: String
    let fileName: String
    let vendor: String?
    let version: String?
    let sizeBytes: Int64
    let icon: UIImage
    let lastPlayed: Date?
    let hasJad: Bool

    var path: String { id }

    static func == (a: GameEntry, b: GameEntry) -> Bool {
        a.id == b.id && a.name == b.name && a.lastPlayed == b.lastPlayed
            && a.sizeBytes == b.sizeBytes && a.vendor == b.vendor && a.version == b.version
    }
}

enum LibrarySort: String, CaseIterable {
    case recent, name

    var title: String {
        switch self {
        case .recent: return "Chơi gần đây"
        case .name:   return "Tên A–Z"
        }
    }
}

final class LibraryModel: ObservableObject {
    @Published var games: [GameEntry] = []
    @Published var scanned = false
    @Published var sort: LibrarySort {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "librarySort") }
    }

    init() {
        sort = LibrarySort(rawValue: UserDefaults.standard.string(forKey: "librarySort") ?? "") ?? .recent
    }

    func sortedGames(matching query: String) -> [GameEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? games : games.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.fileName.localizedCaseInsensitiveContains(q)
                || ($0.vendor ?? "").localizedCaseInsensitiveContains(q)
        }
        switch sort {
        case .name:
            return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recent:
            return list.sorted {
                switch ($0.lastPlayed, $1.lastPlayed) {
                case let (a?, b?): return a > b
                case (_?, nil): return true
                case (nil, _?): return false
                default: return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
        }
    }
}

struct LibraryActions {
    var play: (GameEntry) -> Void
    var settings: (GameEntry) -> Void
    var rename: (GameEntry) -> Void
    var clearData: (GameEntry) -> Void
    var delete: (GameEntry) -> Void
    var add: () -> Void
    var logs: () -> Void
    var help: () -> Void
}

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    let actions: LibraryActions
    @State private var query = ""

    private var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "?"
        let b = info["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.scanned && model.games.isEmpty {
                    emptyState
                } else {
                    gameList
                }
            }
            .navigationTitle("JarBox")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sắp xếp", selection: $model.sort) {
                            ForEach(LibrarySort.allCases, id: \.self) { s in
                                Text(s.title).tag(s)
                            }
                        }
                        Divider()
                        Button { actions.help() } label: {
                            Label("Hướng dẫn", systemImage: "questionmark.circle")
                        }
                        Button { actions.logs() } label: {
                            Label("Gửi nhật ký lỗi", systemImage: "doc.text.magnifyingglass")
                        }
                        Divider()
                        Text("JarBox \(appVersion)")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Tùy chọn")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { actions.add() } label: {
                        Label("Thêm game", systemImage: "plus")
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Chưa có game", systemImage: "gamecontroller")
        } description: {
            Text("Thêm file game .jar (có thể kèm file .jad) từ ứng dụng Tệp, iCloud, Zalo hoặc Safari.")
        } actions: {
            Button {
                actions.add()
            } label: {
                Label("Thêm game", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var gameList: some View {
        let games = model.sortedGames(matching: query)
        return List {
            Section {
                ForEach(games) { game in
                    row(game)
                        .contextMenu { menuItems(game) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { actions.delete(game) } label: {
                                Label("Xóa", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button { actions.settings(game) } label: {
                                Label("Cài đặt", systemImage: "gearshape")
                            }
                            .tint(.blue)
                        }
                }
            } footer: {
                if !games.isEmpty {
                    Text("Chạm vào game để chơi. Bấm ⋯ để chỉnh độ phân giải, xoay màn hình, phím… Thêm game: nút + ở góc trên, hoặc mở file .jar từ ứng dụng khác → Chia sẻ → JarBox.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Tìm game")
        .overlay {
            if model.scanned && games.isEmpty && !query.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func subtitle(_ game: GameEntry) -> String {
        var parts: [String] = []
        if let vendor = game.vendor, !vendor.isEmpty { parts.append(vendor) }
        if let version = game.version, !version.isEmpty { parts.append("v" + version) }
        parts.append(ByteCountFormatter.string(fromByteCount: game.sizeBytes, countStyle: .file))
        return parts.joined(separator: " · ")
    }

    private func row(_ game: GameEntry) -> some View {
        HStack(spacing: 12) {
            Button {
                actions.play(game)
            } label: {
                HStack(spacing: 14) {
                    Image(uiImage: game.icon)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(game.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(subtitle(game))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let played = game.lastPlayed {
                            Text("Chơi lần cuối " + played.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.tint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Chơi \(game.name)")

            Menu {
                menuItems(game)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 24))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Tùy chọn của \(game.name)")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func menuItems(_ game: GameEntry) -> some View {
        Button { actions.play(game) } label: {
            Label("Chơi", systemImage: "play.fill")
        }
        Button { actions.settings(game) } label: {
            Label("Cài đặt game…", systemImage: "gearshape")
        }
        Button { actions.rename(game) } label: {
            Label("Đổi tên", systemImage: "pencil")
        }
        Divider()
        Button { actions.clearData(game) } label: {
            Label("Xóa dữ liệu lưu", systemImage: "eraser")
        }
        Button(role: .destructive) { actions.delete(game) } label: {
            Label("Xóa game", systemImage: "trash")
        }
    }
}
