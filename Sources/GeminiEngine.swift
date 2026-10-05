import Foundation

// MARK: - Google Gemini (무료 키): 노래를 직접 듣고 가사 받아쓰기 + 원곡 맞히기
// 커버곡·누가 불러도 가사와 멜로디로 원곡을 찾아요.

enum GeminiEngine {
    struct Result {
        var lyrics: String
        var hits: [Hit]
    }

    private static let models = ["gemini-2.5-flash", "gemini-flash-latest", "gemini-2.0-flash"]

    static func analyze(wav: Data, key: String) async throws -> Result {
        let prompt = """
        This audio was recorded through a phone microphone while music was playing (from the phone speaker or nearby). \
        It may be the original recording, a live version, or a cover sung by someone else, and there may be noise or talking.
        1) Transcribe the sung lyrics you can hear, in the original language (Korean lyrics in Korean).
        2) Identify the ORIGINAL song: official title (Korean title for Korean songs) and ORIGINAL artist, never the cover singer.
        Respond only in JSON: {"lyrics":"...","songs":[{"title":"...","artist":"...","confidence":0.0}]} \
        with up to 3 candidates, best first, confidence 0 to 1. If you cannot tell, use an empty songs list.
        """
        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["inline_data": ["mime_type": "audio/wav", "data": wav.base64EncodedString()]],
                    ["text": prompt]
                ]
            ]],
            "generationConfig": [
                "temperature": 0,
                "response_mime_type": "application/json"
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var lastError = "Gemini: 응답을 받지 못했어요."
        for model in models {
            var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 60
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            req.httpBody = bodyData

            let data = try await HTTP.send(req, service: "Gemini")
            if let e = try? JSONDecoder().decode(ErrorResponse.self, from: data), let err = e.error {
                let status = err.status ?? ""
                if status == "NOT_FOUND" { continue }          // 모델 이름이 바뀐 경우 다음 모델로
                if status == "PERMISSION_DENIED" || status == "UNAUTHENTICATED" || (err.message ?? "").contains("API key") {
                    throw SongFinderError.message("Gemini 키가 올바르지 않아요. 설정(열쇠)에서 다시 확인해 주세요.")
                }
                if status == "RESOURCE_EXHAUSTED" {
                    throw SongFinderError.message("Gemini 무료 사용량을 다 썼어요. 잠시 뒤(또는 내일) 다시 해 주세요.")
                }
                lastError = "Gemini: \(err.message ?? "오류")"
                continue
            }
            guard let resp = try? JSONDecoder().decode(Response.self, from: data),
                  let text = resp.candidates?.first?.content?.parts?.compactMap({ $0.text }).joined(),
                  let json = cleanJSON(text).data(using: .utf8),
                  let answer = try? JSONDecoder().decode(Answer.self, from: json) else {
                lastError = "Gemini: 응답을 읽지 못했어요."
                continue
            }

            var hits: [Hit] = []
            for (i, s) in (answer.songs ?? []).prefix(3).enumerated() {
                let conf = min(1, max(0, s.confidence ?? 0.5))
                guard conf >= 0.2, let title = s.title, !title.isEmpty else { continue }
                let artist = s.artist ?? ""
                // 실제로 있는 곡인지 애플 뮤직에서 확인해요 (지어낸 곡은 점수를 낮춰요)
                let check = await ITunesCheck.find(title: title, artist: artist)
                let weight = conf * (check.found ? 1.4 : 0.5) * (i == 0 ? 1.0 : 0.6)
                hits.append(Hit(title: title, artist: artist.isEmpty ? "알 수 없는 가수" : artist,
                                album: nil, artworkURL: check.artwork, link: nil,
                                source: .ai, weight: weight))
            }
            return Result(lyrics: (answer.lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines), hits: hits)
        }
        throw SongFinderError.message(lastError)
    }

    /// ```json ... ``` 같은 감싸기를 벗겨요
    private static func cleanJSON(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        }
        if let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}") { t = String(t[a...b]) }
        return t
    }

    struct ErrorResponse: Decodable {
        let error: Info?
        struct Info: Decodable {
            let message: String?
            let status: String?
        }
    }
    struct Response: Decodable {
        let candidates: [Candidate]?
        struct Candidate: Decodable { let content: Content? }
        struct Content: Decodable { let parts: [Part]? }
        struct Part: Decodable { let text: String? }
    }
    struct Answer: Decodable {
        let lyrics: String?
        let songs: [Song]?
        struct Song: Decodable {
            let title: String?
            let artist: String?
            let confidence: Double?
        }
    }
}
