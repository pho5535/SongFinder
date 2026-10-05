import Foundation
import SwiftUI

@MainActor
final class Recognizer: ObservableObject {
    enum Mode: Equatable {
        case song      // 노래 듣기 (40초)
        case humming   // 허밍 (15초, ACRCloud)
    }

    enum Stage: Equatable {
        case idle
        case listening(Int)
        case analyzing(String)
        case done
        case failed(String)
    }

    @Published var stage: Stage = .idle
    @Published var level: Float = 0
    @Published var transcript = ""
    @Published var candidates: [Candidate] = []
    @Published var confidence: Confidence?
    @Published var notes: [String] = []
    @Published var warnings: [String] = []
    @Published var history: [SavedSong] = []

    @Published var seconds = 40
    @Published var mode: Mode = .song
    private let capture = AudioCapture()

    var isBusy: Bool {
        switch stage {
        case .listening, .analyzing: return true
        default: return false
        }
    }

    init() {
        SharedStore.migrateIfNeeded()
        loadHistory()
    }

    func run(mode: Mode = .song) async {
        guard !isBusy else { return }
        self.mode = mode
        seconds = mode == .humming ? 15 : 40
        var settings = AppSettings.load()
        if mode == .humming {
            guard settings.hasACR else {
                stage = .failed("허밍으로 찾기는 ACRCloud 키가 필요해요. 설정(열쇠)에서 ACRCloud 키를 넣어 주세요.")
                return
            }
            settings.auddToken = ""      // 허밍은 ACRCloud만 사용
            settings.geniusToken = ""
        }
        candidates = []
        confidence = nil
        notes = []
        warnings = []
        transcript = ""

        guard settings.hasAnyEngine else {
            stage = .failed("설정(열쇠 아이콘)에서 인식 서비스 키를 하나 이상 넣어 주세요.")
            return
        }
        let perms = await AudioCapture.requestPermissions()
        guard perms.mic else {
            stage = .failed("마이크 권한이 꺼져 있어요. 설정 앱 > Melook에서 마이크를 켜 주세요.")
            return
        }
        let useSpeech = perms.speech && settings.hasGenius
        if settings.hasGenius && !perms.speech {
            warnings.append("음성 인식 권한이 꺼져 있어서 가사 확인은 건너뛰어요.")
        }

        capture.onLevel = { [weak self] value in
            guard let self = self else { return }
            Task { @MainActor in self.level = value }
        }
        capture.onTranscript = { [weak self] text in
            guard let self = self else { return }
            Task { @MainActor in self.transcript = text }
        }

        do {
            try capture.start(language: settings.language, useSpeech: useSpeech)
            for left in stride(from: seconds, to: 0, by: -1) {
                stage = .listening(left)
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let text = capture.stop()
            level = 0
            stage = .analyzing("들은 소리를 정리하는 중…")
            try await Task.sleep(nanoseconds: 700_000_000)   // 마지막 받아쓰기 결과 기다리기
            let lyrics = transcript.count >= text.count ? transcript : text
            transcript = lyrics

            // 들은 소리 중 구간을 골라요. 가운데 구간부터 먼저 보내요.
            let ranges: [(Double, Double)] = mode == .humming
                ? [(2.0, 12.0)]
                : [(16.0, 10.0), (3.0, 10.0), (29.0, 10.0)]
            let segments = ranges.compactMap {
                capture.wavSegment(from: $0.0, length: $0.1)
            }
            guard !segments.isEmpty else {
                stage = .failed("소리가 충분히 녹음되지 않았어요. 다시 시도해 주세요.")
                return
            }

            var hits: [Hit] = []
            stage = .analyzing("1차 인식 중… (\(engineNames(settings)))")
            hits += await identify(segments[0], lyrics: lyrics, settings: settings)
            var cands = Matcher.merge(hits)

            // 확실하지 않으면 나머지 구간도 보내서 투표해요
            if Matcher.confidence(cands) != .sure && segments.count > 1 && (settings.hasAudD || settings.hasACR) {
                for (n, seg) in segments.dropFirst().enumerated() {
                    try Task.checkCancellation()
                    stage = .analyzing("다시 확인하는 중… (\(n + 2)/\(segments.count)구간)")
                    hits += await identify(seg, lyrics: nil, settings: settings)
                }
                cands = Matcher.merge(hits)
            }

            candidates = Array(cands.prefix(5))
            confidence = Matcher.confidence(cands)
            notes = mode == .humming && !cands.isEmpty
                ? ["허밍으로 찾은 결과예요. 후보 중에서 맞는 곡을 골라 보세요."]
                : Matcher.notes(for: cands)
            if let top = cands.first {
                Library.shared.addRecent(title: top.title, artist: top.artist, artworkURL: top.artworkURL, link: top.link)
                history = SharedStore.loadHistory()
            }
            stage = .done
        } catch is CancellationError {
            capture.stop()
            level = 0
            stage = .idle
        } catch {
            capture.stop()
            level = 0
            stage = .failed(error.localizedDescription)
        }
    }

    /// "이 폰 소리로 찾기"로 방금 들은 소리를 가사·커버까지 써서 다시 확인해요
    func analyzePhoneCapture() async {
        guard !isBusy else { return }
        mode = .song
        let settings = AppSettings.load()
        candidates = []
        confidence = nil
        notes = []
        warnings = []
        transcript = ""
        guard settings.hasAnyEngine else {
            stage = .failed("설정(열쇠 아이콘)에서 인식 서비스 키를 하나 이상 넣어 주세요.")
            return
        }
        guard let cap = SharedStore.loadCapture(), let url = SharedStore.captureURL else {
            stage = .failed("최근 30분 안에 '이 폰 소리로 찾기'로 들은 소리가 없어요. 먼저 이 폰 소리로 찾기를 해 주세요.")
            return
        }

        var lyrics = ""
        if settings.hasGenius {
            stage = .analyzing("폰 소리에서 가사를 받아 적는 중…")
            if await AudioCapture.requestSpeechPermission() {
                lyrics = await AudioCapture.transcribeFile(url, language: settings.language)
            } else {
                warnings.append("음성 인식 권한이 꺼져 있어서 가사 확인은 건너뛰어요.")
            }
        } else {
            warnings.append("Genius 키를 넣으면 커버곡도 가사로 원곡을 찾을 수 있어요.")
        }
        transcript = lyrics

        let starts = AudioClip.bestStarts(cap.samples, rate: cap.rate, length: 12, count: 3)
        let segments = starts.compactMap { AudioClip.wav(cap.samples, rate: cap.rate, from: $0, length: 12) }
        guard !segments.isEmpty else {
            stage = .failed("저장된 소리가 너무 짧아요. 이 폰 소리로 찾기를 다시 해 주세요.")
            return
        }

        var hits: [Hit] = []
        for (n, seg) in segments.enumerated() {
            if Task.isCancelled { stage = .idle; return }
            stage = .analyzing("원곡·커버 확인 중… (\(n + 1)/\(segments.count)구간)")
            hits += await identify(seg, lyrics: n == 0 ? lyrics : nil, settings: settings)
        }

        let cands = Matcher.merge(hits)
        candidates = Array(cands.prefix(5))
        confidence = Matcher.confidence(cands)
        notes = Matcher.notes(for: cands)
        if let top = cands.first {
            Library.shared.addRecent(title: top.title, artist: top.artist, artworkURL: top.artworkURL, link: top.link)
            history = SharedStore.loadHistory()
        }
        stage = .done
    }

    func cancel() {
        capture.stop()
        level = 0
        stage = .idle
    }

    private func engineNames(_ s: AppSettings) -> String {
        var names: [String] = []
        if s.hasAudD { names.append("AudD") }
        if s.hasACR { names.append("ACRCloud") }
        if s.hasGenius { names.append("가사") }
        return names.joined(separator: " · ")
    }

    /// 한 구간을 켜져 있는 모든 서비스에 동시에 보내요
    private func identify(_ wav: Data, lyrics: String?, settings: AppSettings) async -> [Hit] {
        await withTaskGroup(of: (hits: [Hit], warning: String?).self) { group in
            if settings.hasAudD {
                group.addTask {
                    do {
                        let h = try await AudD.recognize(wav: wav, token: settings.auddToken)
                        return (h.map { [$0] } ?? [], nil)
                    } catch { return ([], error.localizedDescription) }
                }
            }
            if settings.hasACR {
                group.addTask {
                    do {
                        let h = try await ACRCloud.recognize(wav: wav, host: settings.acrHost,
                                                             accessKey: settings.acrAccess, secret: settings.acrSecret)
                        return (h, nil)
                    } catch { return ([], error.localizedDescription) }
                }
            }
            if settings.hasGenius, let lyrics = lyrics, !lyrics.isEmpty {
                group.addTask {
                    do {
                        let h = try await Genius.search(transcript: lyrics, token: settings.geniusToken)
                        return (h, nil)
                    } catch { return ([], error.localizedDescription) }
                }
            }
            var all: [Hit] = []
            for await r in group {
                all += r.hits
                if let w = r.warning, !self.warnings.contains(w) { self.warnings.append(w) }
            }
            return all
        }
    }

    // MARK: - 기록

    func save(_ c: Candidate) {
        history.removeAll { Matcher.normalize($0.title) == Matcher.normalize(c.title) && $0.artist == c.artist }
        history.insert(SavedSong(title: c.title, artist: c.artist, artworkURL: c.artworkURL, link: c.link), at: 0)
        saveHistory()
    }

    func isSaved(_ c: Candidate) -> Bool {
        history.contains { Matcher.normalize($0.title) == Matcher.normalize(c.title) && $0.artist == c.artist }
    }

    func deleteHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        saveHistory()
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    func reloadHistory() {
        history = SharedStore.loadHistory()
    }

    private func loadHistory() {
        history = SharedStore.loadHistory()
    }

    private func saveHistory() {
        SharedStore.saveHistory(history)
    }
}
