import ReplayKit
import SwiftUI
import UserNotifications

@main
struct SongFinderApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.light)
                .tint(Theme.accent)
        }
    }
}

// MARK: - 디자인 (아이콘과 같은 파스텔 유리 느낌)

enum Theme {
    static let accent = Color(red: 0.36, green: 0.55, blue: 0.96)
    static let accentLight = Color(red: 0.56, green: 0.77, blue: 1.0)
    static let lavender = Color(red: 0.70, green: 0.66, blue: 0.98)
    static let ink = Color(red: 0.16, green: 0.20, blue: 0.36)
    static let mint = Color(red: 0.36, green: 0.78, blue: 0.86)

    static var buttonGradient: LinearGradient {
        LinearGradient(colors: [accentLight, accent, lavender], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct DreamyBackground: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.white
            WaveShape(phase: 0, amp: 16)
                .fill(Theme.accentLight.opacity(0.16))
                .frame(height: 190)
            WaveShape(phase: .pi, amp: 20)
                .fill(Theme.accent.opacity(0.10))
                .frame(height: 140)
        }
        .ignoresSafeArea()
    }
}

struct WaveShape: Shape {
    var phase: Double
    var amp: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.height))
        let steps = 60
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let x = rect.width * CGFloat(t)
            let y = CGFloat(amp + sin(t * 2 * .pi + phase) * amp)
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: rect.width, y: rect.height))
        p.closeSubpath()
        return p
    }
}

struct Glass: ViewModifier {
    var radius: CGFloat = 22
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.3)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: Theme.accent.opacity(0.12), radius: 16, y: 8)
    }
}

extension View {
    func glass(_ radius: CGFloat = 22) -> some View { modifier(Glass(radius: radius)) }
}

struct RootView: View {
    var body: some View {
        TabView {
            ContentView()
                .tabItem { Label("찾기", systemImage: "waveform") }
            LyricsSearchView()
                .tabItem { Label("가사검색", systemImage: "text.magnifyingglass") }
            LibraryView()
                .tabItem { Label("기록", systemImage: "clock.arrow.circlepath") }
            TipsView()
                .tabItem { Label("팁", systemImage: "lightbulb") }
        }
    }
}

struct ContentView: View {
    @StateObject private var rec = Recognizer()
    @State private var task: Task<Void, Never>?
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var lastPhone: SavedSong?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ListenButton(busy: rec.isBusy, level: rec.level) { toggle() }
                        .padding(.top, 16)
                    PhoneAudioButton()
                        .disabled(rec.isBusy)
                    HummingButton(active: rec.isBusy && rec.mode == .humming) {
                        if rec.isBusy {
                            task?.cancel()
                            rec.cancel()
                        } else {
                            task = Task { await rec.run(mode: .humming) }
                        }
                    }
                    .disabled(rec.isBusy && rec.mode != .humming)
                    if let song = lastPhone, rec.stage != .done {
                        PhoneResultCard(song: song) { lastPhone = nil }
                    }
                    StageView(rec: rec)
                    if !rec.transcript.isEmpty {
                        TranscriptBox(text: rec.transcript)
                    }
                    if rec.stage == .done {
                        ResultsView(rec: rec)
                    }
                    if !rec.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(rec.warnings, id: \.self) { w in
                                Label(w, systemImage: "exclamationmark.triangle")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(DreamyBackground())
            .navigationTitle("Melook")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "key.fill") }
                        .accessibilityLabel("설정")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView().preferredColorScheme(.light) }
            .sheet(isPresented: $showHistory) { HistoryView(rec: rec).preferredColorScheme(.light) }
            .onAppear {
                SharedStore.migrateIfNeeded()
                if !AppSettings.load().hasAnyEngine { showSettings = true }
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                refreshPhoneResult()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    rec.reloadHistory()
                    refreshPhoneResult()
                }
            }
        }
    }

    private func refreshPhoneResult() {
        if let s = SharedStore.lastBroadcast(), Date().timeIntervalSince(s.date) < 600 {
            lastPhone = s
        }
    }

    private func toggle() {
        if rec.isBusy {
            task?.cancel()
            rec.cancel()
        } else {
            task = Task { await rec.run(mode: .song) }
        }
    }
}

// MARK: - 듣기 버튼

struct ListenButton: View {
    let busy: Bool
    let level: Float
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill((busy ? Color.pink : Theme.accentLight).opacity(0.10))
                    .frame(width: 290, height: 290)
                    .scaleEffect(1 + CGFloat(level) * 0.15)
                    .animation(.easeOut(duration: 0.1), value: level)
                Circle()
                    .fill((busy ? Color.pink : Theme.accentLight).opacity(0.18))
                    .frame(width: 240, height: 240)
                Circle()
                    .fill(busy ? LinearGradient(colors: [Color(red: 1, green: 0.66, blue: 0.75), Color(red: 0.94, green: 0.46, blue: 0.6)],
                                                startPoint: .top, endPoint: .bottom)
                               : LinearGradient(colors: [Color(red: 0.56, green: 0.73, blue: 1.0), Color(red: 0.40, green: 0.58, blue: 0.98)],
                                                startPoint: .top, endPoint: .bottom))
                    .frame(width: 196, height: 196)
                    .shadow(color: (busy ? Color.pink : Theme.accent).opacity(0.30), radius: 20, y: 10)
                VStack(spacing: 8) {
                    Image(systemName: busy ? "stop.fill" : "waveform")
                        .font(.system(size: 52, weight: .semibold))
                    Text(busy ? "멈추기" : "듣기")
                        .font(.title3.weight(.semibold))
                }
                .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(busy ? "멈추기" : "노래 듣기 시작")
    }
}

// MARK: - 진행 상태

struct StageView: View {
    @ObservedObject var rec: Recognizer

    var body: some View {
        Group {
            switch rec.stage {
            case .idle:
                VStack(spacing: 6) {
                    Text("버튼을 누르고 노래를 들려주세요")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Text("40초 동안 듣고, 여러 번 확인해서 가장 맞는 곡을 골라요.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .listening(let left):
                VStack(spacing: 8) {
                    Text("듣고 있어요… \(left)초")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    ProgressView(value: Double(rec.seconds - left + 1), total: Double(rec.seconds))
                        .tint(.red)
                        .frame(maxWidth: 240)
                    Text(rec.mode == .humming ? "\"음~\" 소리로 멜로디를 또렷하게 흥얼거려 주세요."
                                              : "대화나 잡음이 적은 곳에서, 노래 소리를 크게 들려주면 더 정확해요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .analyzing(let message):
                VStack(spacing: 10) {
                    ProgressView()
                    Text(message)
                        .font(.headline)
                }
            case .done:
                EmptyView()
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

struct TranscriptBox: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("들린 가사", systemImage: "text.quote")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .glass(16)
    }
}

// MARK: - 결과

struct ResultsView: View {
    @ObservedObject var rec: Recognizer

    var body: some View {
        if let top = rec.candidates.first {
            VStack(spacing: 18) {
                SongCard(candidate: top, confidence: rec.confidence ?? .guess,
                         saved: rec.isSaved(top)) { rec.save(top) }

                ForEach(rec.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if rec.candidates.count > 1 {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("다른 후보")
                            .font(.headline)
                        ForEach(rec.candidates.dropFirst()) { c in
                            CandidateRow(candidate: c, saved: rec.isSaved(c)) { rec.save(c) }
                            Divider()
                        }
                    }
                }
            }
        } else {
            VStack(spacing: 6) {
                Text("곡을 찾지 못했어요")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.ink)
                Text("노래 소리를 키우고, 후렴처럼 보컬이 잘 들리는 부분에서 다시 해 보세요.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

struct ConfidenceBadge: View {
    let confidence: Confidence

    private var color: Color {
        switch confidence {
        case .sure: return .green
        case .likely: return .orange
        case .guess: return .gray
        }
    }

    var body: some View {
        Text(confidence.label)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct SourceChips: View {
    let sources: [Source: Int]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Source.allCases.filter { sources[$0] != nil }, id: \.self) { s in
                let n = sources[s] ?? 0
                Text(n > 1 ? "\(s.rawValue) ×\(n)" : s.rawValue)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                    .foregroundStyle(Theme.accent)
            }
        }
    }
}

func listenURL(title: String, artist: String, link: String?) -> URL? {
    if let link = link, let url = URL(string: link) { return url }
    var comps = URLComponents(string: "https://www.youtube.com/results")!
    comps.queryItems = [URLQueryItem(name: "search_query", value: "\(artist) \(title)")]
    return comps.url
}

struct SongCard: View {
    let candidate: Candidate
    let confidence: Confidence
    let saved: Bool
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ConfidenceBadge(confidence: confidence)
            Artwork(url: candidate.artworkURL, size: 170)
            VStack(spacing: 4) {
                Text(candidate.title)
                    .font(.title2.weight(.bold))
                Text(candidate.artist)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if let album = candidate.album, !album.isEmpty {
                    Text(album)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            SourceChips(sources: candidate.sources)
            HStack(spacing: 14) {
                PreviewButton(title: candidate.title, artist: candidate.artist)
                FavoriteButton(title: candidate.title, artist: candidate.artist,
                               artworkURL: candidate.artworkURL, link: candidate.link)
                if let url = listenURL(title: candidate.title, artist: candidate.artist, link: nil) {
                    Link(destination: url) {
                        Label("전곡 듣기", systemImage: "play.rectangle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                }
            }
            Text("▶︎ 30초 미리듣기 · ☆ 즐겨찾기")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .glass(26)
    }
}

struct CandidateRow: View {
    let candidate: Candidate
    let saved: Bool
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: candidate.artworkURL, size: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.title).font(.body.weight(.medium)).lineLimit(1)
                Text(candidate.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                SourceChips(sources: candidate.sources)
            }
            Spacer(minLength: 6)
            PreviewButton(title: candidate.title, artist: candidate.artist)
            FavoriteButton(title: candidate.title, artist: candidate.artist,
                           artworkURL: candidate.artworkURL, link: candidate.link)
        }
    }
}

struct Artwork: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url.flatMap { URL(string: $0) }) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Theme.accent.opacity(0.15)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.35))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12))
    }
}

// MARK: - 기록

struct HistoryView: View {
    @ObservedObject var rec: Recognizer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if rec.history.isEmpty {
                    ContentUnavailableView("아직 찾은 곡이 없어요", systemImage: "music.note.list",
                                           description: Text("곡을 찾고 \"맞아요\"를 누르면 여기에 모여요."))
                } else {
                    List {
                        ForEach(rec.history) { song in
                            HStack(spacing: 12) {
                                Artwork(url: song.artworkURL, size: 46)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title).font(.body.weight(.medium)).lineLimit(1)
                                    Text(song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if let url = listenURL(title: song.title, artist: song.artist, link: song.link) {
                                    Link(destination: url) { Image(systemName: "play.circle") }
                                }
                            }
                        }
                        .onDelete { rec.deleteHistory(at: $0) }
                    }
                }
            }
            .navigationTitle("찾은 곡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } }
                if !rec.history.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("모두 지우기", role: .destructive) { rec.clearHistory() }
                    }
                }
            }
        }
    }
}

// MARK: - 설정

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Keys.auddToken, store: SharedStore.defaults) private var auddToken = ""
    @AppStorage(Keys.acrHost, store: SharedStore.defaults) private var acrHost = ""
    @AppStorage(Keys.acrAccess, store: SharedStore.defaults) private var acrAccess = ""
    @AppStorage(Keys.acrSecret, store: SharedStore.defaults) private var acrSecret = ""
    @AppStorage(Keys.geniusToken, store: SharedStore.defaults) private var geniusToken = ""
    @AppStorage(Keys.language, store: SharedStore.defaults) private var language = "ko-KR"
    @AppStorage(Keys.useLyrics, store: SharedStore.defaults) private var useLyrics = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("서비스를 많이 켤수록 더 정확해요. 하나만 넣어도 쓸 수 있어요. 키는 이 아이폰에만 저장돼요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    KeyField(title: "API 키", text: $auddToken)
                    Text("\"이 폰 소리로 찾기\"에는 AudD 또는 ACRCloud 키가 꼭 필요해요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("dashboard.audd.io 에서 키 받기", destination: URL(string: "https://dashboard.audd.io/")!)
                } header: {
                    Text("AudD · 일반 음원 인식")
                }

                Section {
                    KeyField(title: "Host (예: identify-ap-southeast-1.acrcloud.com)", text: $acrHost)
                    KeyField(title: "Access Key", text: $acrAccess)
                    KeyField(title: "Access Secret", text: $acrSecret)
                    Link("console.acrcloud.com 에서 키 받기", destination: URL(string: "https://console.acrcloud.com/")!)
                } header: {
                    Text("ACRCloud · 음원 + 커버/라이브 인식")
                } footer: {
                    Text("프로젝트를 만들 때 커버 곡(Cover Songs) 인식을 켜면 커버·라이브를 더 잘 찾아요.")
                }

                Section {
                    Toggle("가사로 한 번 더 확인", isOn: $useLyrics)
                    Picker("노래 언어", selection: $language) {
                        Text("한국어").tag("ko-KR")
                        Text("영어").tag("en-US")
                        Text("일본어").tag("ja-JP")
                        Text("중국어").tag("zh-CN")
                    }
                    KeyField(title: "Client Access Token", text: $geniusToken)
                    Link("genius.com/api-clients 에서 키 받기", destination: URL(string: "https://genius.com/api-clients")!)
                } header: {
                    Text("Genius · 가사 검색")
                } footer: {
                    Text("들린 가사를 받아 적어서 검색해요. 커버나 라이브라도 원곡을 찾을 수 있어요.")
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
        }
    }
}

struct KeyField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        TextField(title, text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.callout, design: .monospaced))
    }
}

// MARK: - 이 폰 소리로 찾기 (화면 방송 확장)

struct PhoneAudioButton: View {
    @StateObject private var picker = BroadcastPickerHolder()
    @State private var showHelp = false

    var body: some View {
        VStack(spacing: 8) {
            Button {
                picker.tap()
            } label: {
                Label("이 폰 소리로 찾기", systemImage: "iphone.radiowaves.left.and.right")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .glass(30)
            }
            .buttonStyle(.plain)
            .background(BroadcastPickerView(holder: picker).frame(width: 1, height: 1).opacity(0.01))

            Button("어떻게 쓰나요?") { showHelp.toggle() }
                .font(.footnote)
            if showHelp {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. 유튜브·음악 앱에서 노래를 틀어 두세요.")
                    Text("2. 이 버튼을 누르고 \"방송 시작\"을 누르세요.")
                    Text("3. 노래 앱으로 돌아가면 40초 뒤 알림으로 제목과 가수가 떠요.")
                    Text("4. 화면 위 빨간 표시를 누르면 언제든 멈출 수 있어요.")
                    Text("이어폰을 끼고 있어도 돼요. 녹음을 막아 둔 앱(넷플릭스 등)의 소리는 들을 수 없어요.")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .glass(14)
            }
        }
    }
}

final class BroadcastPickerHolder: ObservableObject {
    weak var view: RPSystemBroadcastPickerView?

    func tap() {
        guard let view = view else { return }
        for case let button as UIButton in view.subviews {
            button.sendActions(for: .touchUpInside)
            return
        }
    }
}

struct BroadcastPickerView: UIViewRepresentable {
    let holder: BroadcastPickerHolder

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        v.preferredExtension = SharedStore.broadcastExtensionID
        v.showsMicrophoneButton = false
        holder.view = v
        return v
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        holder.view = uiView
    }
}

struct PhoneResultCard: View {
    let song: SavedSong
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: song.artworkURL, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("방금 이 폰 소리로 찾은 곡")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.mint)
                Text(song.title).font(.headline).lineLimit(1)
                Text(song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let url = listenURL(title: song.title, artist: song.artist, link: song.link) {
                Link(destination: url) { Image(systemName: "play.circle.fill").font(.title2) }
            }
            Button(action: onClose) { Image(systemName: "xmark").font(.footnote) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .glass(18)
    }
}

// MARK: - 허밍으로 찾기

struct HummingButton: View {
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(active ? "허밍 듣는 중… (누르면 멈춤)" : "허밍으로 찾기", systemImage: active ? "stop.circle" : "music.mic")
                .font(.headline)
                .foregroundStyle(active ? Color.pink : Theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .glass(30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(active ? "허밍 멈추기" : "허밍으로 노래 찾기")
    }
}
