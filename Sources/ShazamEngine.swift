import AVFoundation
import ShazamKit

/// 샤잠(애플) 음원 인식 — 키 없이 무료로 써요
enum ShazamEngine {
    static func recognize(samples: [Float], rate: Double, from start: Double, length: Double) async throws -> Hit? {
        let s = max(0, Int(start * rate))
        let e = min(samples.count, s + Int(length * rate))
        guard e - s > Int(rate * 3),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(e - s)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(e - s)
        var peak: Float = 0
        for i in s..<e { peak = max(peak, abs(samples[i])) }
        let gain: Float = peak > 0.0001 ? min(0.9 / peak, 20) : 1
        for i in 0..<(e - s) { channel[i] = samples[s + i] * gain }

        let generator = SHSignatureGenerator()
        try generator.append(buffer, at: nil)
        let signature = generator.signature()
        let result = await SHSession().result(from: signature)
        switch result {
        case .match(let match):
            guard let item = match.mediaItems.first, let title = item.title else { return nil }
            return Hit(title: title, artist: item.artist ?? "알 수 없는 가수", album: nil,
                       artworkURL: item.artworkURL?.absoluteString,
                       link: item.appleMusicURL?.absoluteString ?? item.webURL?.absoluteString,
                       source: .shazam, weight: 1.6)
        case .noMatch:
            return nil
        case .error(let error, _):
            throw error
        @unknown default:
            return nil
        }
    }
}
