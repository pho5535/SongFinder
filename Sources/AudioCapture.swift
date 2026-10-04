import AVFoundation
import Speech

/// 마이크로 녹음하면서(소리 데이터 보관) 동시에 애플 음성 인식으로 가사를 받아 적어요.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var transcriptText = ""
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private(set) var sampleRate: Double = 44100

    /// 소리 크기(0~1), 오디오 스레드에서 호출돼요
    var onLevel: ((Float) -> Void)?
    /// 받아쓴 가사(지금까지 전체), 임의 스레드에서 호출돼요
    var onTranscript: ((String) -> Void)?

    static func requestPermissions() async -> (mic: Bool, speech: Bool) {
        let mic = await AVAudioApplication.requestRecordPermission()
        let speech = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        return (mic, speech)
    }

    func start(language: String, useSpeech: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        // measurement 모드: 음성용 잡음 제거를 끄고 음악 소리를 최대한 그대로 받아요
        // mixWithOthers: 다른 앱에서 나오는 음악이 멈추지 않게 해요
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)

        lock.lock()
        samples = []
        samples.reserveCapacity(48000 * 20)
        transcriptText = ""
        lock.unlock()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SongFinderError.message("마이크를 찾지 못했어요.")
        }
        sampleRate = format.sampleRate

        if useSpeech,
           let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
           recognizer.isAvailable {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            speechRequest = request
            speechTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
                guard let self = self, let result = result else { return }
                let text = result.bestTranscription.formattedString
                self.lock.lock()
                self.transcriptText = text
                self.lock.unlock()
                self.onTranscript?(text)
            }
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.speechRequest?.append(buffer)
            guard let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            let ptr = UnsafeBufferPointer(start: channel, count: count)
            var sum: Float = 0
            for v in ptr { sum += v * v }
            self.lock.lock()
            self.samples.append(contentsOf: ptr)
            self.lock.unlock()
            let rms = sqrt(sum / Float(max(count, 1)))
            let db = 20 * log10(max(rms, 0.0000001))
            self.onLevel?(max(0, min(1, (db + 50) / 50)))
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    /// 녹음을 멈추고, 지금까지 받아쓴 가사를 돌려줘요.
    @discardableResult
    func stop() -> String {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        speechRequest?.endAudio()
        speechTask?.finish()
        speechRequest = nil
        speechTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        lock.lock()
        defer { lock.unlock() }
        return transcriptText
    }

    var recordedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / sampleRate
    }

    /// 녹음의 한 구간을 WAV 파일 데이터로 만들어요.
    /// 업로드 크기를 줄이려고 약 16kHz로 줄이고, 소리가 작으면 키워요.
    func wavSegment(from start: Double, length: Double) -> Data? {
        lock.lock()
        let all = samples
        lock.unlock()

        let s = max(0, Int(start * sampleRate))
        let e = min(all.count, s + Int(length * sampleRate))
        guard e - s > Int(sampleRate * 3) else { return nil }

        // 간단한 다운샘플링(평균) — 저역 통과 효과도 있어요
        let factor = max(1, Int(sampleRate / 16000))
        var reduced: [Float] = []
        reduced.reserveCapacity((e - s) / factor + 1)
        var i = s
        while i + factor <= e {
            var acc: Float = 0
            for k in 0..<factor { acc += all[i + k] }
            reduced.append(acc / Float(factor))
            i += factor
        }
        let outRate = Int(sampleRate) / factor

        var peak: Float = 0
        for v in reduced { peak = max(peak, abs(v)) }
        let gain: Float = peak > 0.0001 ? min(0.9 / peak, 20) : 1
        return WAV.encode(reduced, sampleRate: outRate, gain: gain)
    }
}

enum WAV {
    static func encode(_ samples: [Float], sampleRate: Int, gain: Float) -> Data {
        var d = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataSize = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                              // PCM
        u16(1)                              // 모노
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))         // 바이트/초
        u16(2)                              // 블록 크기
        u16(16)                             // 16비트
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        for s in samples {
            let v = Int16(max(-1, min(1, s * gain)) * 32767)
            u16(UInt16(bitPattern: v))
        }
        return d
    }
}
