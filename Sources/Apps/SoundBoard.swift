import AVFoundation
import UIKit

/// Stream sound effects, synthesised at launch like KeepAlive's silence so
/// there are no binary assets. Plays through the same .mixWithOthers session,
/// so Spotify keeps playing underneath.
enum SoundBoard {
    struct Sound: Identifiable {
        let id: String
        let symbol: String
        let wav: Data
    }

    static let sounds: [Sound] = [
        Sound(id: "Ding", symbol: "bell.fill", wav: wav(bell())),
        Sound(id: "Clap", symbol: "hands.clap.fill", wav: wav(claps(count: 1, seconds: 0.4))),
        Sound(id: "Applause", symbol: "hands.sparkles.fill", wav: wav(claps(count: 90, seconds: 3.5))),
    ]

    private static var players: [AVAudioPlayer] = []
    private static let rate = 44_100

    static func play(_ sound: Sound) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        players.removeAll { !$0.isPlaying }
        guard let player = try? AVAudioPlayer(data: sound.wav) else { return }
        player.play()
        players.append(player)   // retained until finished, so taps can overlap
    }

    // MARK: Synthesis

    /// Struck bell: inharmonic partials with exponential decay.
    private static func bell() -> [Float] {
        let partials: [(ratio: Float, amp: Float, decay: Float)] =
            [(1, 1, 2.2), (2.76, 0.5, 3.5), (5.4, 0.25, 6), (8.93, 0.12, 9)]
        let n = Int(Float(rate) * 2.2)
        return (0..<n).map { i in
            let t = Float(i) / Float(rate)
            return partials.reduce(0) { sum, p in
                sum + p.amp * exp(-p.decay * t) * sin(2 * .pi * 1320 * p.ratio * t)
            } * 0.45
        }
    }

    /// Each clap is a ~25 ms burst of high-passed noise; many random claps
    /// with a swell-and-fade envelope read as applause.
    private static func claps(count: Int, seconds: Float) -> [Float] {
        var out = [Float](repeating: 0, count: Int(Float(rate) * seconds))
        let clapLen = rate / 40
        for _ in 0..<count {
            let start = count == 1 ? 0 : Int.random(in: 0..<(out.count - clapLen))
            let pos = Float(start) / Float(out.count)
            let swell = count == 1 ? 1 : min(1, pos * 6) * min(1, (1 - pos) * 2.5)
            let gain = (count == 1 ? 0.9 : 0.35) * swell * Float.random(in: 0.5...1)
            var prev: Float = 0
            for i in 0..<clapLen {
                let noise = Float.random(in: -1...1)
                let hp = noise - prev   // crude high-pass for the "crack"
                prev = noise
                out[start + i] += hp * gain * exp(-Float(i) / Float(clapLen / 5))
            }
        }
        return out
    }

    /// 16-bit mono PCM WAV, clipped to [-1, 1].
    private static func wav(_ samples: [Float]) -> Data {
        var wav = Data()
        func append(_ s: String) { wav.append(contentsOf: Array(s.utf8)) }
        func append32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { wav.append(contentsOf: $0) } }
        let dataBytes = samples.count * 2
        append("RIFF"); append32(36 + dataBytes); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(rate); append32(rate * 2); append16(2); append16(16)
        append("data"); append32(dataBytes)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * Float(Int16.max))
            withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) }
        }
        return wav
    }
}
