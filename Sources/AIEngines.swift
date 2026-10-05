import Foundation

// MARK: - OpenAI: 노래 가사 정밀 받아쓰기 + 가사로 원곡 맞히기
// 커버곡·라이브처럼 음원과 소리가 달라도, 가사는 같아서 원곡을 찾을 수 있어요.

enum OpenAIEngine {
    /// 녹음 전체에서 가사를 받아 적어요 (애플 음성 인식보다 노래에 훨씬 강해요)
    static func transcribe(wav: Data, key: String, language: String) async throws -> String {
        let lang = String(language.prefix(2))
        let prompt = lang == "ko" ? "노래 가사입니다. 들리는 가사를 그대로 받아 적어 주세요." : "Song lyrics."
        for model in ["gpt-4o-transcribe", "whisper-1"] {
            var form = MultipartForm()
            form.field("model", model)
            form.field("language", lang)
            form.field("prompt", prompt)
            form.field("response_format", "json")
            form.file("file", filename: "song.wav", type: "audio/wav", data: wav)

            var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 45
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
            req.httpBody = form.finish()

            let data = try await HTTP.send(req, service: "OpenAI")
            if let r = try? JSONDecoder().decode(TranscriptResponse.self, from: data), let text = r.text {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let e = try? JSONDecoder().decode(ErrorResponse.self, from: data), let err = e.error {
                if let friendly = friendlyError(err) { throw SongFinderError.message(friendly) }
                if model == "whisper-1" { throw SongFinderError.message("OpenAI: \(err.message ?? "오류")") }
            }
        }
        return ""
    }

    /// 받아 적은 가사로 원곡 제목·가수를 맞혀요
    static func identify(lyrics: String, key: String) async throws -> [Hit] {
        let system = """
        You are a music expert who identifies songs (especially K-pop, Korean ballads, Korean indie, J-pop and global pop) from lyrics. \
        The lyrics come from speech recognition of someone singing, possibly an amateur cover, so expect misheard words and errors. \
        Answer with the ORIGINAL song and ORIGINAL artist, never the cover singer. Use the official title (Korean title for Korean songs). \
        Respond only in JSON like {"songs":[{"title":"...","artist":"...","confidence":0.0}]} with up to 3 candidates, best first. \
        confidence is 0 to 1. If you cannot tell, return {"songs":[]}.
        """
        let body: [String: Any] = [
            "model": "gpt-4o",
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": "Transcribed lyrics:\n" + String(lyrics.prefix(1200))]
            ]
        ]
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await HTTP.send(req, service: "OpenAI")
        if let e = try? JSONDecoder().decode(ErrorResponse.self, from: data), let err = e.error {
            throw SongFinderError.message(friendlyError(err) ?? "OpenAI: \(err.message ?? "오류")")
        }
        guard let chat = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = chat.choices.first?.message.content,
              let json = content.data(using: .utf8),
              let answer = try? JSONDecoder().decode(SongAnswer.self, from: json) else { return [] }

        var hits: [Hit] = []
        for (i, s) in answer.songs.prefix(3).enumerated() {
            let conf = min(1, max(0, s.confidence ?? 0.5))
            guard conf >= 0.2, !s.title.isEmpty else { continue }
            // 실제로 있는 곡인지 애플 뮤직에서 확인해요 (AI가 지어낸 곡은 점수를 낮춰요)
            let check = await ITunesCheck.find(title: s.title, artist: s.artist)
            let weight = conf * (check.found ? 1.3 : 0.5) * (i == 0 ? 1.0 : 0.6)
            hits.append(Hit(title: s.title, artist: s.artist.isEmpty ? "알 수 없는 가수" : s.artist,
                            album: nil, artworkURL: check.artwork, link: nil,
                            source: .ai, weight: weight))
        }
        return hits
    }

    private static func friendlyError(_ err: ErrorResponse.Info) -> String? {
        switch err.code ?? err.type ?? "" {
        case "invalid_api_key": return "OpenAI 키가 올바르지 않아요. 설정(열쇠)에서 다시 확인해 주세요."
        case "insufficient_quota": return "OpenAI 잔액이 없어요. platform.openai.com 에서 크레딧을 충전해 주세요."
        default: return nil
        }
    }

    struct TranscriptResponse: Decodable { let text: String? }
    struct ErrorResponse: Decodable {
        let error: Info?
        struct Info: Decodable {
            let message: String?
            let type: String?
            let code: String?
        }
    }
    struct ChatResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let content: String? }
    }
    struct SongAnswer: Decodable {
        let songs: [Song]
        struct Song: Decodable {
            let title: String
            let artist: String
            let confidence: Double?
        }
    }
}

// MARK: - AudD 가사 검색 (AudD 키로 무료)

enum AudDLyrics {
    static func search(_ lyrics: String, token: String) async throws -> [Hit] {
        let words = lyrics.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 4 else { return [] }
        var queries = [words.prefix(12).joined(separator: " ")]
        if words.count >= 20 { queries.append(words.suffix(12).joined(separator: " ")) }

        var hits: [Hit] = []
        for q in queries {
            var form = MultipartForm()
            form.field("api_token", token)
            form.field("q", q)
            var req = URLRequest(url: URL(string: "https://api.audd.io/findLyrics/")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
            req.httpBody = form.finish()
            let data = try await HTTP.send(req, service: "AudD 가사")
            guard let r = try? JSONDecoder().decode(Response.self, from: data), r.status == "success" else { continue }
            let weights = [0.7, 0.3, 0.15]
            for (item, w) in zip((r.result ?? []).prefix(3), weights) {
                guard let t = item.title, !t.isEmpty else { continue }
                hits.append(Hit(title: t, artist: item.artist ?? "알 수 없는 가수", album: nil,
                                artworkURL: nil, link: nil, source: .lyrics, weight: w))
            }
        }
        return hits
    }

    struct Response: Decodable {
        let status: String
        let result: [Item]?
    }
    struct Item: Decodable {
        let title: String?
        let artist: String?
    }
}

// MARK: - 애플 뮤직에 실제로 있는 곡인지 확인

enum ITunesCheck {
    static func find(title: String, artist: String) async -> (found: Bool, artwork: String?) {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "8"),
            URLQueryItem(name: "country", value: "KR")
        ]
        guard let url = comps.url,
              let res = try? await URLSession.shared.data(from: url),
              let r = try? JSONDecoder().decode(Response.self, from: res.0) else { return (false, nil) }
        let want = Matcher.aliases(for: title)
        for t in r.results {
            let have = Matcher.aliases(for: t.trackName ?? "")
            if !have.isDisjoint(with: want) {
                return (true, t.artworkUrl100?.replacingOccurrences(of: "100x100", with: "400x400"))
            }
        }
        return (false, nil)
    }

    struct Response: Decodable { let results: [Track] }
    struct Track: Decodable {
        let trackName: String?
        let artworkUrl100: String?
    }
}
