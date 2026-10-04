import SwiftUI

// MARK: - 가사검색 탭

struct LyricsSearchView: View {
    @State private var query = ""
    @State private var results: [Hit] = []
    @State private var searching = false
    @State private var message: String?
    @State private var showSettings = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    HStack(spacing: 10) {
                        Image(systemName: "text.magnifyingglass").foregroundStyle(Theme.accent)
                        TextField("기억나는 가사를 입력하세요", text: $query)
                            .focused($focused)
                            .submitLabel(.search)
                            .onSubmit { search() }
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        }
                    }
                    .padding(14)
                    .glass(18)

                    Button(action: search) {
                        Text(searching ? "찾는 중…" : "가사로 찾기")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.buttonGradient, in: Capsule())
                    }
                    .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)

                    if let m = message {
                        Text(m).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }

                    if !results.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.offset) { i, h in
                                SongRow(title: h.title, artist: h.artist, artworkURL: h.artworkURL, link: h.link)
                                    .padding(.horizontal, 14)
                                if i < results.count - 1 { Divider().padding(.leading, 76) }
                            }
                        }
                        .padding(.vertical, 6)
                        .glass(20)
                    } else if message == nil {
                        VStack(spacing: 6) {
                            Image(systemName: "quote.bubble").font(.largeTitle).foregroundStyle(Theme.accentLight)
                            Text("한두 줄만 정확히 적어도 잘 찾아요").font(.subheadline).foregroundStyle(.secondary)
                            Text("예: 이 밤 그날의 반딧불을 당신의 창 가까이 보낼게요")
                                .font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                        }
                        .padding(.top, 30)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(DreamyBackground())
            .navigationTitle("가사검색")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "key.fill") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView().preferredColorScheme(.light) }
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let settings = AppSettings.load()
        guard !settings.geniusToken.isEmpty else {
            message = "설정(열쇠)에서 Genius 키를 넣어 주세요."
            return
        }
        focused = false
        searching = true
        message = nil
        Task {
            do {
                let hits = try await LyricsSearch.search(q, token: settings.geniusToken)
                results = hits
                if hits.isEmpty { message = "이 가사로는 찾지 못했어요. 다른 부분을 적어 보세요." }
                if let top = hits.first {
                    Library.shared.addRecent(title: top.title, artist: top.artist, artworkURL: top.artworkURL, link: top.link)
                }
            } catch {
                results = []
                message = error.localizedDescription
            }
            searching = false
        }
    }
}

// MARK: - 기록 탭 (최근 검색 · 즐겨찾기)

struct LibraryView: View {
    @ObservedObject private var library = Library.shared
    @ObservedObject private var player = PreviewPlayer.shared
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("", selection: $tab) {
                    Text("최근 검색").tag(0)
                    Text("즐겨찾기 ⭐").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)

                let items = tab == 0 ? library.recent : library.favorites
                if items.isEmpty {
                    Spacer()
                    ContentUnavailableView(tab == 0 ? "아직 검색 기록이 없어요" : "즐겨찾기한 곡이 없어요",
                                           systemImage: tab == 0 ? "clock" : "star",
                                           description: Text(tab == 0 ? "곡을 찾으면 여기에 자동으로 쌓여요."
                                                                      : "곡 옆의 별(☆)을 누르면 여기에 모여요."))
                    Spacer()
                } else {
                    List {
                        ForEach(items) { s in
                            SongRow(title: s.title, artist: s.artist, artworkURL: s.artworkURL, link: s.link)
                                .listRowBackground(Color.white.opacity(0.6))
                        }
                        .onDelete { tab == 0 ? library.deleteRecent(at: $0) : library.deleteFavorite(at: $0) }
                    }
                    .scrollContentBackground(.hidden)
                }
                if let m = player.message {
                    Text(m).font(.footnote).foregroundStyle(.secondary).padding(.bottom, 6)
                }
            }
            .background(DreamyBackground())
            .navigationTitle("기록")
            .toolbar {
                if tab == 0 && !library.recent.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("모두 지우기", role: .destructive) { library.clearRecent() }
                    }
                }
            }
            .onAppear { library.reload() }
        }
    }
}

// MARK: - 정확도 팁 탭

struct TipsView: View {
    private struct Tip: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let body: String
    }

    private let tips: [Tip] = [
        Tip(icon: "iphone.radiowaves.left.and.right", title: "이 폰에서 나는 노래는 \"이 폰 소리로 찾기\"",
            body: "같은 폰에서 틀면서 마이크로 들으면 소리가 줄어들어요. 방송 기능으로 내부 소리를 직접 받으면 가장 정확해요."),
        Tip(icon: "music.mic", title: "보컬이 나오는 부분에서",
            body: "전주·간주보다 노래(특히 후렴)가 나올 때 시작하세요."),
        Tip(icon: "speaker.wave.3", title: "소리는 크게, 대화는 조용히",
            body: "다른 기기에서 틀 때는 아이폰 마이크(아래쪽)를 스피커 쪽으로 가까이 대 주세요."),
        Tip(icon: "key", title: "키를 두 개 이상 넣기",
            body: "AudD + Genius, 여기에 ACRCloud까지 넣으면 여러 곳 결과를 비교해서 훨씬 정확해져요."),
        Tip(icon: "person.2.wave.2", title: "커버·라이브는 가사로 확인",
            body: "다른 사람이 부른 버전은 소리 모양이 달라요. Genius 키를 넣어 두면 가사로 원곡을 찾아요."),
        Tip(icon: "waveform.path", title: "허밍은 멜로디를 또렷하게",
            body: "\"음~\" 소리로 박자에 맞춰 10초 이상 흥얼거리세요. 허밍은 ACRCloud 키가 있어야 해요."),
        Tip(icon: "text.quote", title: "가사가 기억나면 가사검색",
            body: "정확한 한두 줄이면 충분해요. 틀린 글자가 적을수록 잘 찾아요."),
        Tip(icon: "globe.asia.australia", title: "노래 언어 맞추기",
            body: "설정에서 노래 언어(한국어/영어/일본어…)를 맞추면 가사 받아쓰기가 정확해져요.")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(tips) { t in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: t.icon)
                                .font(.title3)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 40, height: 40)
                                .background(Theme.accent.opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(t.title).font(.headline).foregroundStyle(Theme.ink)
                                Text(t.body).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .glass(18)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(DreamyBackground())
            .navigationTitle("정확도 팁")
        }
    }
}
