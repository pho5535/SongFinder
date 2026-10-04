import CryptoKit
import Foundation

enum SongFinderError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

/// 결과를 낸 곳
enum Source: String, Codable, Hashable, CaseIterable {
    case audd = "AudD"
    case acr = "ACRCloud"
    case acrCover = "커버 인식"
    case lyrics = "가사"

    /// 녹음 파일과 소리가 똑같은지 비교하는 방식(지문 인식)인지
    var isFingerprint: Bool { self == .audd || self == .acr }
}

/// 인식 서비스 한 곳이 돌려준 결과 하나
struct Hit {
    let title: String
    let artist: String
    let album: String?
    let artworkURL: String?
    let link: String?
    let source: Source
    let weight: Double
}

// MARK: - 공통

struct MultipartForm {
    let boundary = "Boundary-\(UUID().uuidString)"
    private(set) var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func file(_ name: String, filename: String, type: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    mutating func finish() -> Data {
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}

enum HTTP {
    static func send(_ request: URLRequest, service: String) async throws -> Data {
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SongFinderError.message("\(service): 인터넷에 연결할 수 없어요.")
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, service: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SongFinderError.message("\(service): 응답을 읽지 못했어요.")
        }
    }
}

// MARK: - AudD (https://docs.audd.io)

enum AudD {
    static func recognize(wav: Data, token: String) async throws -> Hit? {
        var form = MultipartForm()
        form.field("api_token", token)
        form.field("return", "apple_music,spotify")
        form.file("file", filename: "clip.wav", type: "audio/wav", data: wav)

        var req = URLRequest(url: URL(string: "https://api.audd.io/")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finish()

        let data = try await HTTP.send(req, service: "AudD")
        let resp = try HTTP.decode(Response.self, from: data, service: "AudD")
        if resp.status == "error" {
            throw SongFinderError.message("AudD: \(resp.error?.error_message ?? "오류") — 키를 확인해 주세요.")
        }
        guard let r = resp.result, let title = r.title else { return nil }

        var art = r.spotify?.album?.images?.first?.url
        if art == nil, let a = r.apple_music?.artwork?.url {
            art = a.replacingOccurrences(of: "{w}", with: "400").replacingOccurrences(of: "{h}", with: "400")
        }
        return Hit(title: title, artist: r.artist ?? "알 수 없는 가수", album: r.album,
                   artworkURL: art, link: r.song_link, source: .audd, weight: 1.0)
    }

    struct Response: Decodable {
        let status: String
        let result: SongResult?
        let error: ErrorInfo?
    }
    struct ErrorInfo: Decodable {
        let error_code: Int?
        let error_message: String?
    }
    struct SongResult: Decodable {
        let artist: String?
        let title: String?
        let album: String?
        let song_link: String?
        let apple_music: AppleMusic?
        let spotify: Spotify?
    }
    struct AppleMusic: Decodable {
        let artwork: Artwork?
        struct Artwork: Decodable { let url: String? }
    }
    struct Spotify: Decodable {
        let album: Album?
        struct Album: Decodable { let images: [Image]? }
        struct Image: Decodable { let url: String }
    }
}

// MARK: - ACRCloud (https://docs.acrcloud.com) — 일반 인식 + 커버/허밍 인식

enum ACRCloud {
    static func recognize(wav: Data, host: String, accessKey: String, secret: String) async throws -> [Hit] {
        let cleanHost = host
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "https://\(cleanHost)/v1/identify") else {
            throw SongFinderError.message("ACRCloud: 호스트 주소가 올바르지 않아요.")
        }

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let toSign = "POST\n/v1/identify\n\(accessKey)\naudio\n1\n\(timestamp)"
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(toSign.utf8),
                                                         using: SymmetricKey(data: Data(secret.utf8)))
        let signature = Data(mac).base64EncodedString()

        var form = MultipartForm()
        form.field("access_key", accessKey)
        form.field("data_type", "audio")
        form.field("signature_version", "1")
        form.field("signature", signature)
        form.field("sample_bytes", String(wav.count))
        form.field("timestamp", timestamp)
        form.file("sample", filename: "sample.wav", type: "audio/wav", data: wav)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finish()

        let data = try await HTTP.send(req, service: "ACRCloud")
        let resp = try HTTP.decode(Response.self, from: data, service: "ACRCloud")
        switch resp.status.code {
        case 0: break
        case 1001: return []                       // 결과 없음
        default:
            throw SongFinderError.message("ACRCloud: \(resp.status.msg ?? "오류") — 키와 호스트를 확인해 주세요.")
        }

        var hits: [Hit] = []
        if let t = resp.metadata?.music?.first, let h = t.hit(source: .acr, scale: 1.0) { hits.append(h) }
        if let t = resp.metadata?.cover_songs?.first, let h = t.hit(source: .acrCover, scale: 0.8) { hits.append(h) }
        if let t = resp.metadata?.humming?.first, let h = t.hit(source: .acrCover, scale: 0.6) { hits.append(h) }
        return hits
    }

    struct Response: Decodable {
        let status: Status
        let metadata: Metadata?
    }
    struct Status: Decodable {
        let code: Int
        let msg: String?
    }
    struct Metadata: Decodable {
        let music: [Track]?
        let cover_songs: [Track]?
        let humming: [Track]?
    }
    struct Track: Decodable {
        let title: String?
        let artists: [Artist]?
        let album: Album?
        let score: Double?
        let external_metadata: External?

        struct Artist: Decodable { let name: String? }
        struct Album: Decodable { let name: String? }
        struct External: Decodable {
            let spotify: Spotify?
            struct Spotify: Decodable {
                let track: SpotifyTrack?
                struct SpotifyTrack: Decodable { let id: String? }
            }
        }

        func hit(source: Source, scale: Double) -> Hit? {
            guard let title = title, !title.isEmpty else { return nil }
            // 점수가 0~100 또는 0~1로 올 수 있어요
            var s = score ?? 70
            if s > 1 { s /= 100 }
            let artist = artists?.compactMap { $0.name }.joined(separator: ", ") ?? ""
            var link: String?
            if let id = external_metadata?.spotify?.track?.id { link = "https://open.spotify.com/track/\(id)" }
            return Hit(title: title, artist: artist.isEmpty ? "알 수 없는 가수" : artist,
                       album: album?.name, artworkURL: nil, link: link,
                       source: source, weight: max(0.3, s) * scale)
        }
    }
}

// MARK: - Genius 가사 검색 (https://docs.genius.com)

enum Genius {
    /// 받아쓴 가사로 곡을 찾아요. 커버·라이브라도 가사는 같아서 원곡을 찾을 수 있어요.
    static func search(transcript: String, token: String) async throws -> [Hit] {
        let words = transcript
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard words.count >= 4 else { return [] }

        // 앞부분과 뒷부분을 따로 검색해서, 받아쓰기가 일부 틀려도 버틸 수 있게 해요
        var queries = [words.prefix(10).joined(separator: " ")]
        if words.count >= 14 { queries.append(words.suffix(10).joined(separator: " ")) }

        var hits: [Hit] = []
        for q in queries {
            hits += try await query(q, token: token)
        }
        return hits
    }

    private static func query(_ q: String, token: String) async throws -> [Hit] {
        var comps = URLComponents(string: "https://api.genius.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: q)]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data = try await HTTP.send(req, service: "Genius")
        let resp = try HTTP.decode(Response.self, from: data, service: "Genius")
        if let status = resp.meta?.status, status != 200 {
            throw SongFinderError.message("Genius: \(resp.meta?.message ?? "오류") — 키를 확인해 주세요.")
        }
        let weights = [0.9, 0.4, 0.2]
        let songs = (resp.response?.hits ?? []).filter { $0.type == "song" }.compactMap { $0.result }
        return zip(songs.prefix(3), weights).map { song, w in
            Hit(title: song.title ?? "제목 없음",
                artist: song.primary_artist?.name ?? "알 수 없는 가수",
                album: nil,
                artworkURL: song.song_art_image_thumbnail_url,
                link: song.url,
                source: .lyrics,
                weight: w)
        }
    }

    struct Response: Decodable {
        let meta: Meta?
        let response: Body?
    }
    struct Meta: Decodable {
        let status: Int?
        let message: String?
    }
    struct Body: Decodable { let hits: [HitItem]? }
    struct HitItem: Decodable {
        let type: String?
        let result: Song?
    }
    struct Song: Decodable {
        let title: String?
        let url: String?
        let song_art_image_thumbnail_url: String?
        let primary_artist: Artist?
        struct Artist: Decodable { let name: String? }
    }
}
