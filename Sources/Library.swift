import AVFoundation
import SwiftUI

// MARK: - 즐겨찾기 저장소

enum FavoritesStore {
    static let key = "favoriteSongs"

    static func load() -> [SavedSong] {
        guard let data = SharedStore.defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([SavedSong].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [SavedSong]) {
        if let data = try? JSONEncoder().encode(list) {
            SharedStore.defaults.set(data, forKey: key)
        }
    }

    static func same(_ a: SavedSong, _ title: String, _ artist: String) -> Bool {
        Matcher.normalize(a.title) == Matcher.normalize(title) && Matcher.normalize(a.artist) == Matcher.normalize(artist)
    }
}

@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published var favorites: [SavedSong] = FavoritesStore.load()
    @Published var recent: [SavedSong] = SharedStore.loadHistory()

    func reload() {
        favorites = FavoritesStore.load()
        recent = SharedStore.loadHistory()
    }

    func isFavorite(_ title: String, _ artist: String) -> Bool {
        favorites.contains { FavoritesStore.same($0, title, artist) }
    }

    func toggleFavorite(title: String, artist: String, artworkURL: String?, link: String?) {
        if isFavorite(title, artist) {
            favorites.removeAll { FavoritesStore.same($0, title, artist) }
        } else {
            favorites.insert(SavedSong(title: title, artist: artist, artworkURL: artworkURL, link: link), at: 0)
        }
        FavoritesStore.save(favorites)
    }

    func addRecent(title: String, artist: String, artworkURL: String?, link: String?) {
        SharedStore.add(SavedSong(title: title, artist: artist, artworkURL: artworkURL, link: link))
        recent = SharedStore.loadHistory()
    }

    func deleteRecent(at offsets: IndexSet) {
        recent.remove(atOffsets: offsets)
        SharedStore.saveHistory(recent)
    }

    func deleteFavorite(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        FavoritesStore.save(favorites)
    }

    func clearRecent() {
        recent = []
        SharedStore.saveHistory([])
    }
}

// MARK: - 미리 듣기 (애플 뮤직 공식 30초 미리듣기)

@MainActor
final class PreviewPlayer: ObservableObject {
    static let shared = PreviewPlayer()

    @Published var playingKey: String?
    @Published var loadingKey: String?
    @Published var progress: Double = 0
    @Published var message: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    static func key(_ title: String, _ artist: String) -> String { "\(artist)|\(title)" }

    func toggle(title: String, artist: String) {
        let k = Self.key(title, artist)
        if playingKey == k { stop(); return }
        stop()
        loadingKey = k
        message = nil
        Task {
            do {
                guard let url = try await Self.findPreview(title: title, artist: artist) else {
                    loadingKey = nil
                    message = "이 곡은 미리듣기가 없어요. \"전곡 듣기\"를 눌러 주세요."
                    return
                }
                guard loadingKey == k else { return }
                play(url: url, key: k)
            } catch {
                loadingKey = nil
                message = "미리듣기를 불러오지 못했어요. 인터넷 연결을 확인해 주세요."
            }
        }
    }

    private func play(url: URL, key: String) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p
        loadingKey = nil
        playingKey = key
        progress = 0
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self = self else { return }
            Task { @MainActor in
                let total = p.currentItem?.duration.seconds ?? 30
                self.progress = total.isFinite && total > 0 ? min(1, t.seconds / total) : 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in self.stop() }
        }
        p.play()
    }

    func stop() {
        player?.pause()
        if let o = timeObserver { player?.removeTimeObserver(o) }
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        timeObserver = nil
        endObserver = nil
        player = nil
        playingKey = nil
        loadingKey = nil
        progress = 0
    }

    /// iTunes 검색 API (키 필요 없음)
    static func findPreview(title: String, artist: String) async throws -> URL? {
        let cleanTitle = title.components(separatedBy: CharacterSet(charactersIn: "([")).first ?? title
        for country in ["KR", "US"] {
            var comps = URLComponents(string: "https://itunes.apple.com/search")!
            comps.queryItems = [
                URLQueryItem(name: "term", value: "\(artist) \(cleanTitle)"),
                URLQueryItem(name: "entity", value: "song"),
                URLQueryItem(name: "limit", value: "5"),
                URLQueryItem(name: "country", value: country)
            ]
            let (data, _) = try await URLSession.shared.data(from: comps.url!)
            let resp = try JSONDecoder().decode(ITunesResponse.self, from: data)
            let want = Matcher.normalize(cleanTitle)
            let best = resp.results.first { Matcher.normalize($0.trackName ?? "").contains(want) || want.contains(Matcher.normalize($0.trackName ?? "")) }
                ?? resp.results.first
            if let s = best?.previewUrl, let url = URL(string: s) { return url }
        }
        return nil
    }

    struct ITunesResponse: Decodable { let results: [Track] }
    struct Track: Decodable {
        let trackName: String?
        let artistName: String?
        let previewUrl: String?
    }
}

// MARK: - 가사로 곡 검색 (Genius)

enum LyricsSearch {
    static func search(_ text: String, token: String) async throws -> [Hit] {
        var comps = URLComponents(string: "https://api.genius.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: text)]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await HTTP.send(req, service: "Genius")
        let resp = try HTTP.decode(Genius.Response.self, from: data, service: "Genius")
        if let status = resp.meta?.status, status != 200 {
            throw SongFinderError.message("Genius: \(resp.meta?.message ?? "오류") — 키를 확인해 주세요.")
        }
        let songs = (resp.response?.hits ?? []).filter { $0.type == "song" }.compactMap { $0.result }
        return songs.prefix(10).map { s in
            Hit(title: s.title ?? "제목 없음", artist: s.primary_artist?.name ?? "알 수 없는 가수",
                album: nil, artworkURL: s.song_art_image_thumbnail_url, link: s.url,
                source: .lyrics, weight: 1)
        }
    }
}

// MARK: - 공용 작은 화면 요소

struct PreviewButton: View {
    let title: String
    let artist: String
    @ObservedObject private var player = PreviewPlayer.shared

    var body: some View {
        let k = PreviewPlayer.key(title, artist)
        Button {
            player.toggle(title: title, artist: artist)
        } label: {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.12)).frame(width: 36, height: 36)
                if player.loadingKey == k {
                    ProgressView().scaleEffect(0.7)
                } else if player.playingKey == k {
                    Circle()
                        .trim(from: 0, to: player.progress)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 34, height: 34)
                    Image(systemName: "pause.fill").font(.footnote).foregroundStyle(Theme.accent)
                } else {
                    Image(systemName: "play.fill").font(.footnote).foregroundStyle(Theme.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.playingKey == k ? "미리듣기 멈추기" : "30초 미리듣기")
    }
}

struct FavoriteButton: View {
    let title: String
    let artist: String
    let artworkURL: String?
    let link: String?
    @ObservedObject private var library = Library.shared

    var body: some View {
        let on = library.isFavorite(title, artist)
        Button {
            library.toggleFavorite(title: title, artist: artist, artworkURL: artworkURL, link: link)
        } label: {
            Image(systemName: on ? "star.fill" : "star")
                .font(.body)
                .foregroundStyle(on ? Color.yellow : Color.secondary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "즐겨찾기 해제" : "즐겨찾기")
    }
}

struct SongRow: View {
    let title: String
    let artist: String
    let artworkURL: String?
    let link: String?

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: artworkURL, size: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            PreviewButton(title: title, artist: artist)
            FavoriteButton(title: title, artist: artist, artworkURL: artworkURL, link: link)
            ListenMenu(title: title, artist: artist) {
                Image(systemName: "arrow.up.right.circle").font(.title3).foregroundStyle(Theme.accent)
            }
            .accessibilityLabel("전곡 듣기")
        }
        .padding(.vertical, 4)
    }
}
