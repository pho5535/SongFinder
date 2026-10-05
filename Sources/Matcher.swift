import Foundation

/// 여러 결과를 같은 곡끼리 묶은 후보
struct Candidate: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var artist: String
    var album: String?
    var artworkURL: String?
    var link: String?
    var score: Double
    var sources: [Source: Int]
    var aliases: Set<String>
    /// 지금 표시 중인 제목/가수를 낸 곳 (지문 인식 이름을 우선 표시)
    var displaySource: Source

    var fingerprintHits: Int { sources.filter { $0.key.isFingerprint }.map { $0.value }.reduce(0, +) }
    var foundByLyricsOrCover: Bool { sources[.lyrics] != nil || sources[.acrCover] != nil || sources[.ai] != nil }

    static func == (a: Candidate, b: Candidate) -> Bool { a.id == b.id }
}

enum Confidence {
    case sure, likely, guess

    var label: String {
        switch self {
        case .sure: return "확실해요"
        case .likely: return "아마도"
        case .guess: return "후보"
        }
    }
}

enum Matcher {
    /// 비교용으로 소문자·기호/공백 제거 (한글·영문·숫자만 남김)
    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// 괄호 속 버전 표시는 무시할 단어
    private static let versionWords: Set<String> = [
        "live", "remaster", "remastered", "feat", "ft", "ver", "version", "remix", "sped", "slowed",
        "acoustic", "inst", "instrumental", "mr", "cover", "edit", "mix", "radio", "explicit", "from", "prod"
    ]

    private static func isVersionTag(_ part: String) -> Bool {
        let tokens = part.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return tokens.contains { versionWords.contains($0) || $0.contains("버전") || $0.contains("라이브") || $0.contains("커버") }
    }

    /// 제목의 여러 이름 — 예: "Through the Night (밤편지)" → {throughthenight, 밤편지}
    static func aliases(for title: String) -> Set<String> {
        var result = Set<String>()
        var main = title
        var inner: [String] = []

        let pattern = "\\(([^)]*)\\)|\\[([^\\]]*)\\]"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = title as NSString
            for m in regex.matches(in: title, range: NSRange(location: 0, length: ns.length)) {
                for g in 1...2 {
                    let r = m.range(at: g)
                    if r.location != NSNotFound { inner.append(ns.substring(with: r)) }
                }
            }
            main = regex.stringByReplacingMatches(in: title, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        }
        if let dash = main.range(of: " - ") { main = String(main[..<dash.lowerBound]) }

        let m = normalize(main)
        if !m.isEmpty { result.insert(m) }
        for part in inner {
            if isVersionTag(part) { continue }
            let n = normalize(part)
            if n.count >= 2 { result.insert(n) }
        }
        if result.isEmpty { result.insert(normalize(title)) }
        return result
    }

    private static func hasHangul(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
    }

    /// 같은 가수로 볼 수 있는지 (한글/영문 표기가 다르면 같다고 봐요)
    static func artistsCompatible(_ a: String, _ b: String) -> Bool {
        let na = normalize(a), nb = normalize(b)
        if na.isEmpty || nb.isEmpty { return true }
        if na.contains(nb) || nb.contains(na) { return true }
        if hasHangul(na) != hasHangul(nb) { return true }
        return false
    }

    private static func priority(_ s: Source) -> Int {
        switch s {
        case .shazam: return 4
        case .audd: return 3
        case .acr: return 2
        case .lyrics: return 1
        case .ai: return 1
        case .acrCover: return 0
        }
    }

    static func merge(_ hits: [Hit]) -> [Candidate] {
        var cands: [Candidate] = []
        for h in hits {
            let a = aliases(for: h.title)
            if let i = cands.firstIndex(where: { !$0.aliases.isDisjoint(with: a) && artistsCompatible($0.artist, h.artist) }) {
                cands[i].score += h.weight
                cands[i].sources[h.source, default: 0] += 1
                cands[i].aliases.formUnion(a)
                if cands[i].artworkURL == nil { cands[i].artworkURL = h.artworkURL }
                if cands[i].link == nil { cands[i].link = h.link }
                if cands[i].album == nil { cands[i].album = h.album }
                if priority(h.source) > priority(cands[i].displaySource) {
                    cands[i].title = h.title
                    cands[i].artist = h.artist
                    cands[i].displaySource = h.source
                    if let link = h.link { cands[i].link = link }
                }
            } else {
                cands.append(Candidate(title: h.title, artist: h.artist, album: h.album,
                                       artworkURL: h.artworkURL, link: h.link, score: h.weight,
                                       sources: [h.source: 1], aliases: a, displaySource: h.source))
            }
        }
        return cands.sorted { $0.score > $1.score }
    }

    static func confidence(_ cands: [Candidate]) -> Confidence? {
        guard let top = cands.first else { return nil }
        let second = cands.count > 1 ? cands[1].score : 0
        let lead = top.score - second
        let kinds = top.sources.keys.count
        if (top.score >= 2.0 && lead >= 1.0) || (kinds >= 2 && top.score >= 1.5 && lead >= 0.6) {
            return .sure
        }
        if top.score >= 0.9 && lead >= 0.4 { return .likely }
        return .guess
    }

    /// 결과 해설 문구
    static func notes(for cands: [Candidate]) -> [String] {
        guard let top = cands.first else { return [] }
        var notes: [String] = []
        if top.fingerprintHits == 0 && top.foundByLyricsOrCover {
            notes.append("녹음과 똑같은 음원은 없었어요. 커버나 라이브 버전일 수 있어요. 가사와 멜로디로 찾은 원곡이에요.")
        }
        let topAliases = top.aliases
        if let other = cands.dropFirst().first(where: { !$0.aliases.isDisjoint(with: topAliases) }) {
            notes.append("같은 노래를 \(other.artist)이(가) 부른 버전도 후보에 있어요.")
        }
        let lower = top.title.lowercased()
        if lower.contains("live") || top.title.contains("라이브") {
            notes.append("라이브 음원으로 찾았어요.")
        }
        return notes
    }
}
