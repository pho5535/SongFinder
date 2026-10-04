import Foundation

/// 설정 저장 키 (앱과 "이 폰 소리로 찾기" 확장이 같이 써요)
enum Keys {
    static let auddToken = "auddToken"
    static let acrHost = "acrHost"
    static let acrAccess = "acrAccess"
    static let acrSecret = "acrSecret"
    static let geniusToken = "geniusToken"
    static let language = "speechLanguage"
    static let useLyrics = "useLyrics"
    static let history = "songHistory2"
    static let lastBroadcast = "lastBroadcastResult"
}

struct SavedSong: Codable, Identifiable {
    var id = UUID()
    let title: String
    let artist: String
    let artworkURL: String?
    let link: String?
    var date = Date()
    var fromPhoneAudio: Bool? = nil
}

struct AppSettings {
    var auddToken: String
    var acrHost: String
    var acrAccess: String
    var acrSecret: String
    var geniusToken: String
    var language: String
    var useLyrics: Bool

    static func load() -> AppSettings {
        let d = SharedStore.defaults
        func s(_ k: String) -> String { (d.string(forKey: k) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        return AppSettings(auddToken: s(Keys.auddToken), acrHost: s(Keys.acrHost),
                           acrAccess: s(Keys.acrAccess), acrSecret: s(Keys.acrSecret),
                           geniusToken: s(Keys.geniusToken),
                           language: d.string(forKey: Keys.language) ?? "ko-KR",
                           useLyrics: d.object(forKey: Keys.useLyrics) as? Bool ?? true)
    }

    var hasAudD: Bool { !auddToken.isEmpty }
    var hasACR: Bool { !acrHost.isEmpty && !acrAccess.isEmpty && !acrSecret.isEmpty }
    var hasGenius: Bool { !geniusToken.isEmpty && useLyrics }
    var hasAnyEngine: Bool { hasAudD || hasACR || hasGenius }
    var hasFingerprint: Bool { hasAudD || hasACR }
}

/// 앱과 확장이 함께 쓰는 저장소 (App Group)
enum SharedStore {
    static let fallbackGroup = "group.com.heewon.songfinder"

    /// 설치할 때 실제로 받은 App Group 이름 (Sideloadly가 이름을 바꿀 수 있어서 직접 읽어요)
    static let groupID: String = provisionedGroups().first ?? fallbackGroup

    static let defaults: UserDefaults = UserDefaults(suiteName: groupID) ?? .standard

    static var isShared: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil
    }

    private static func provisionedGroups() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              start.lowerBound < end.upperBound else { return [] }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let ent = plist["Entitlements"] as? [String: Any],
              let groups = ent["com.apple.security.application-groups"] as? [String] else { return [] }
        return groups
    }

    /// 예전 버전에서 저장한 키·기록을 공용 저장소로 옮겨요
    static func migrateIfNeeded() {
        guard defaults !== UserDefaults.standard else { return }
        let old = UserDefaults.standard
        for k in [Keys.auddToken, Keys.acrHost, Keys.acrAccess, Keys.acrSecret, Keys.geniusToken,
                  Keys.language, Keys.useLyrics, Keys.history] {
            if defaults.object(forKey: k) == nil, let v = old.object(forKey: k) {
                defaults.set(v, forKey: k)
            }
        }
    }

    static func loadHistory() -> [SavedSong] {
        guard let data = defaults.data(forKey: Keys.history),
              let list = try? JSONDecoder().decode([SavedSong].self, from: data) else { return [] }
        return list
    }

    static func saveHistory(_ list: [SavedSong]) {
        if let data = try? JSONEncoder().encode(Array(list.prefix(200))) {
            defaults.set(data, forKey: Keys.history)
        }
    }

    static func add(_ song: SavedSong) {
        var list = loadHistory()
        list.removeAll { Matcher.normalize($0.title) == Matcher.normalize(song.title) && $0.artist == song.artist }
        list.insert(song, at: 0)
        saveHistory(list)
    }

    static func setLastBroadcast(_ song: SavedSong) {
        if let data = try? JSONEncoder().encode(song) { defaults.set(data, forKey: Keys.lastBroadcast) }
    }

    static func lastBroadcast() -> SavedSong? {
        guard let data = defaults.data(forKey: Keys.lastBroadcast) else { return nil }
        return try? JSONDecoder().decode(SavedSong.self, from: data)
    }

    /// 앱 안에 들어 있는 "방송(화면 기록) 확장"의 번들 ID
    static var broadcastExtensionID: String? {
        guard let dir = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for item in items where item.pathExtension == "appex" {
            if let b = Bundle(url: item),
               let ext = b.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
               ext["NSExtensionPointIdentifier"] as? String == "com.apple.broadcast-services-upload" {
                return b.bundleIdentifier
            }
        }
        return nil
    }
}

/// 소리 데이터 → 업로드용 WAV
enum AudioClip {
    static func wav(_ all: [Float], rate: Double, from start: Double, length: Double) -> Data? {
        let s = max(0, Int(start * rate))
        let e = min(all.count, s + Int(length * rate))
        guard e - s > Int(rate * 3) else { return nil }
        let factor = max(1, Int(rate / 16000))
        var reduced: [Float] = []
        reduced.reserveCapacity((e - s) / factor + 1)
        var i = s
        while i + factor <= e {
            var acc: Float = 0
            for k in 0..<factor { acc += all[i + k] }
            reduced.append(acc / Float(factor))
            i += factor
        }
        var peak: Float = 0
        for v in reduced { peak = max(peak, abs(v)) }
        let gain: Float = peak > 0.0001 ? min(0.9 / peak, 20) : 1
        return WAV.encode(reduced, sampleRate: Int(rate) / factor, gain: gain)
    }
}
