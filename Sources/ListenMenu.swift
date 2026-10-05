import SwiftUI

// MARK: - 전곡 듣기: 여러 음악 앱·검색 사이트 중에서 골라 열기

enum MusicService: String, CaseIterable, Identifiable {
    case youtube, melon, genie, vibe, naver, google, chrome, apple

    var id: String { rawValue }

    var name: String {
        switch self {
        case .youtube: return "유튜브"
        case .melon: return "멜론"
        case .genie: return "지니뮤직"
        case .vibe: return "네이버 바이브"
        case .naver: return "네이버 검색"
        case .google: return "구글 검색"
        case .chrome: return "크롬으로 열기"
        case .apple: return "애플 뮤직"
        }
    }

    var icon: String {
        switch self {
        case .youtube: return "play.rectangle.fill"
        case .melon: return "music.note"
        case .genie: return "music.quarternote.3"
        case .vibe: return "waveform"
        case .naver: return "n.square.fill"
        case .google: return "magnifyingglass"
        case .chrome: return "globe"
        case .apple: return "applelogo"
        }
    }

    func url(title: String, artist: String) -> URL? {
        let query = "\(artist) \(title)"
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let s: String
        switch self {
        case .youtube: s = "https://www.youtube.com/results?search_query=\(q)"
        case .melon: s = "https://www.melon.com/search/total/index.htm?q=\(q)"
        case .genie: s = "https://www.genie.co.kr/search/searchMain?query=\(q)"
        case .vibe: s = "https://vibe.naver.com/search?query=\(q)"
        case .naver: s = "https://search.naver.com/search.naver?query=\(q)"
        case .google: s = "https://www.google.com/search?q=\(q)"
        case .chrome: s = "googlechromes://www.google.com/search?q=\(q)"
        case .apple: s = "https://music.apple.com/kr/search?term=\(q)"
        }
        return URL(string: s)
    }
}

struct ListenMenu<L: View>: View {
    let title: String
    let artist: String
    @ViewBuilder let label: () -> L
    @Environment(\.openURL) private var openURL

    var body: some View {
        Menu {
            Section("어디서 들을까요?") {
                ForEach(MusicService.allCases) { service in
                    Button {
                        open(service)
                    } label: {
                        Label(service.name, systemImage: service.icon)
                    }
                }
            }
        } label: {
            label()
        }
    }

    private func open(_ service: MusicService) {
        guard let url = service.url(title: title, artist: artist) else { return }
        openURL(url) { accepted in
            // 앱이 없어서 못 열면(예: 크롬 미설치) 구글 검색으로 열어요
            if !accepted, let fallback = MusicService.google.url(title: title, artist: artist) {
                openURL(fallback)
            }
        }
    }
}
