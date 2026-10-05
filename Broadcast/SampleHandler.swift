import CoreMedia
import ReplayKit
import UserNotifications

/// "이 폰 소리로 찾기" — 아이폰에서 재생 중인 소리(다른 앱 소리)를 받아 곡을 찾아요.
final class SampleHandler: RPBroadcastSampleHandler {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 44100
    private var done = false
    private let targetSeconds = 40.0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        lock.lock()
        samples = []
        samples.reserveCapacity(48000 * 42)
        done = false
        lock.unlock()
        notify(title: "Melook", body: "이 폰에서 나오는 소리를 듣고 있어요… (약 40초)")
        DispatchQueue.global().asyncAfter(deadline: .now() + 70) { [weak self] in
            self?.timeoutCheck()
        }
    }

    override func broadcastFinished() {}

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .audioApp else { return }
        lock.lock()
        let isDone = done
        lock.unlock()
        if isDone { return }

        append(sampleBuffer)

        lock.lock()
        var shouldRecognize = false
        if !done && Double(samples.count) / sampleRate >= targetSeconds {
            done = true
            shouldRecognize = true
        }
        lock.unlock()
        if shouldRecognize {
            Task { await self.recognize() }
        }
    }

    private func timeoutCheck() {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        let seconds = Double(samples.count) / sampleRate
        lock.unlock()
        if seconds >= 4 {
            Task { await self.recognize() }
        } else {
            finish("노래 소리가 들리지 않았어요. 노래를 재생한 상태에서 다시 해 보세요. (일부 앱은 소리 녹음을 막아 둬요)")
        }
    }

    // MARK: - 소리 데이터 꺼내기

    private func append(_ sb: CMSampleBuffer) {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt),
              let block = CMSampleBufferGetDataBuffer(sb) else { return }
        let asbd = asbdPtr.pointee
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { buf -> OSStatus in
            guard let base = buf.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == kCMBlockBufferNoErr else { return }

        let frames = CMSampleBufferGetNumSamples(sb)
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isBigEndian = flags & kAudioFormatFlagIsBigEndian != 0
        let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let bits = Int(asbd.mBitsPerChannel)
        guard bits == 16 || bits == 32 else { return }
        let bytes = bits / 8
        let useChannels = min(channels, 2)          // 왼쪽·오른쪽을 합쳐서(모노) 더 또렷하게 받아요

        var out: [Float] = []
        out.reserveCapacity(frames)
        data.withUnsafeBytes { raw in
            func sample(_ idx: Int) -> Float? {
                let off = idx * bytes
                guard off + bytes <= raw.count else { return nil }
                if bits == 16 {
                    var u = raw.loadUnaligned(fromByteOffset: off, as: UInt16.self)
                    if isBigEndian { u = UInt16(bigEndian: u) }
                    return Float(Int16(bitPattern: u)) / 32768
                }
                var u = raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)
                if isBigEndian { u = UInt32(bigEndian: u) }
                return isFloat ? Float(bitPattern: u) : Float(Int32(bitPattern: u)) / 2147483648
            }
            for i in 0..<frames {
                var acc: Float = 0
                var n = 0
                for c in 0..<useChannels {
                    let idx = nonInterleaved ? c * frames + i : i * channels + c
                    if let v = sample(idx) { acc += v; n += 1 }
                }
                guard n > 0 else { break }
                out.append(acc / Float(n))
            }
        }

        lock.lock()
        if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
        samples.append(contentsOf: out)
        lock.unlock()
    }

    // MARK: - 곡 찾기

    private func recognize() async {
        lock.lock()
        let all = samples
        let rate = sampleRate
        lock.unlock()

        let settings = AppSettings.load()
        guard settings.hasFingerprint else {
            if !SharedStore.isShared {
                finish("앱 설정을 읽지 못했어요. 앱을 한 번 열어 키를 다시 저장한 뒤 시도해 주세요.")
            } else {
                finish("Melook 앱 설정(열쇠)에서 AudD 키를 넣어 주세요. 이 폰 소리로 찾기는 AudD 또는 ACRCloud 키가 필요해요.")
            }
            return
        }

        var peak: Float = 0
        for v in all { peak = max(peak, abs(v)) }
        guard all.count > Int(rate * 3), peak > 0.001 else {
            finish("소리가 녹음되지 않았어요. 노래를 재생한 상태에서 다시 해 보세요. (넷플릭스·애플뮤직처럼 녹음을 막아 둔 앱은 들을 수 없어요)")
            return
        }

        // 앱에서 "가사·커버로 다시 확인"할 수 있게 들은 소리를 저장해 둬요
        SharedStore.saveCapture(all, rate: rate)

        // 노래가 또렷하게 나오는 12초 구간 3개를 골라서 차례로 확인해요
        let starts = AudioClip.bestStarts(all, rate: rate, length: 12, count: 3)
        let segments = starts.compactMap { AudioClip.wav(all, rate: rate, from: $0, length: 12) }

        var hits: [Hit] = []
        var errors: [String] = []
        for seg in segments {
            let r = await identify(seg, settings: settings)
            hits += r.hits
            errors += r.errors
            if Matcher.confidence(Matcher.merge(hits)) == .sure { break }
        }

        let cands = Matcher.merge(hits)
        let hint = "Melook 앱을 열고 '가사·커버로 다시 확인'을 누르면 커버곡도 찾아볼 수 있어요."
        guard let top = cands.first else {
            notify(title: "곡을 바로 찾지 못했어요", body: hint)
            finish((errors.first.map { $0 + " " } ?? "") + hint)
            return
        }

        let song = SavedSong(title: top.title, artist: top.artist, artworkURL: top.artworkURL,
                             link: top.link, fromPhoneAudio: true)
        SharedStore.add(song)
        SharedStore.setLastBroadcast(song)

        let conf = Matcher.confidence(cands)
        let label = conf?.label ?? ""
        let extra = conf == .sure ? "" : "\n" + hint
        notify(title: "🎵 \(top.title)", body: "\(top.artist) · \(label)" + extra)
        finish("찾았어요: \(top.title) - \(top.artist)")
    }

    private func identify(_ wav: Data, settings: AppSettings) async -> (hits: [Hit], errors: [String]) {
        var hits: [Hit] = []
        var errors: [String] = []
        if settings.hasAudD {
            do {
                let found = try await AudD.recognize(wav: wav, token: settings.auddToken)
                if let h = found { hits.append(h) }
            } catch { errors.append(error.localizedDescription) }
        }
        if settings.hasACR {
            do {
                hits += try await ACRCloud.recognize(wav: wav, host: settings.acrHost,
                                                     accessKey: settings.acrAccess, secret: settings.acrSecret)
            } catch { errors.append(error.localizedDescription) }
        }
        return (hits, errors)
    }

    // MARK: - 알림 · 종료

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func finish(_ message: String) {
        let err = NSError(domain: "SongFinder", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        finishBroadcastWithError(err)
    }
}
