import SwiftUI

@main
struct SongFinderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var rec = Recognizer()
    @State private var task: Task<Void, Never>?
    @State private var showSettings = false
    @State private var showHistory = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ListenButton(busy: rec.isBusy, level: rec.level) { toggle() }
                        .padding(.top, 16)
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
            .navigationTitle("노래찾기")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("찾은 곡 기록")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "key.fill") }
                        .accessibilityLabel("설정")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showHistory) { HistoryView(rec: rec) }
            .onAppear {
                if !AppSettings.load().hasAnyEngine { showSettings = true }
            }
        }
    }

    private func toggle() {
        if rec.isBusy {
            task?.cancel()
            rec.cancel()
        } else {
            task = Task { await rec.run() }
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
                    .fill((busy ? Color.red : Color.indigo).opacity(0.15))
                    .frame(width: 210, height: 210)
                    .scaleEffect(1 + CGFloat(level) * 0.25)
                    .animation(.easeOut(duration: 0.1), value: level)
                Circle()
                    .fill(busy ? Color.red : Color.indigo)
                    .frame(width: 160, height: 160)
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                VStack(spacing: 6) {
                    Image(systemName: busy ? "stop.fill" : "waveform")
                        .font(.system(size: 48, weight: .semibold))
                    Text(busy ? "멈추기" : "듣기")
                        .font(.headline)
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
                    Text("15초 동안 듣고, 여러 번 확인해서 가장 맞는 곡을 골라요.")
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
                    Text("대화나 잡음이 적은 곳에서, 노래 소리를 크게 들려주면 더 정확해요.")
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
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
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
                    .font(.title3.weight(.semibold))
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
                    .background(Color.indigo.opacity(0.12), in: Capsule())
                    .foregroundStyle(.indigo)
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
            HStack(spacing: 10) {
                if let url = listenURL(title: candidate.title, artist: candidate.artist, link: candidate.link) {
                    Link(destination: url) {
                        Label("듣기", systemImage: "play.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                }
                Button(action: onSave) {
                    Label(saved ? "저장됨" : "맞아요", systemImage: saved ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .disabled(saved)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
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
            Button(action: onSave) {
                Text(saved ? "저장됨" : "이 곡이에요")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(saved)
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
                Color.indigo.opacity(0.15)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.35))
                    .foregroundStyle(.indigo)
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
    @AppStorage(Keys.auddToken) private var auddToken = ""
    @AppStorage(Keys.acrHost) private var acrHost = ""
    @AppStorage(Keys.acrAccess) private var acrAccess = ""
    @AppStorage(Keys.acrSecret) private var acrSecret = ""
    @AppStorage(Keys.geniusToken) private var geniusToken = ""
    @AppStorage(Keys.language) private var language = "ko-KR"
    @AppStorage(Keys.useLyrics) private var useLyrics = true

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
