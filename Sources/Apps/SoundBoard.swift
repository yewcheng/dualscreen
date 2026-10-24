import AVFoundation
import UIKit

/// Stream sound effects. Ding is synthesised; the rest are recordings in
/// Sources/Sounds, trimmed and loudness-matched. Plays through the same
/// .mixWithOthers session as KeepAlive, so Spotify keeps playing underneath.
///
/// All capped at 3 s. Recordings from Wikimedia Commons: applause
/// "277021_sandermotions_applause-2" (CC0); cheer mixes that applause with
/// "LL-Q1860_(eng)-Vealhurl-woohoo" (CC BY-SA 4.0) and a synthesised wolf
/// whistle; crickets "Cricket_Gryllus_bimaculatus_Chirps" (CC BY-SA 4.0); crow
/// "Corvus_brachyrhynchos_-_American_Crow_-_XC80525" (CC BY-SA 3.0).
enum SoundBoard {
    struct Sound: Identifiable {
        let id: String
        let symbol: String
        let wav: Data
    }

    static let sounds: [Sound] = [
        Sound(id: "Ding", symbol: "bell.fill", wav: wav(bell())),
        recording("Applause", "hands.clap.fill", "applause"),
        recording("Cheer", "megaphone.fill", "cheer"),
        recording("Crickets", "ellipsis.bubble", "crickets"),
        recording("Crow", "bird.fill", "crow"),
    ].compactMap { $0 }

    private static func recording(_ name: String, _ symbol: String, _ file: String) -> Sound? {
        guard let url = Bundle.main.url(forResource: file, withExtension: "m4a"),
              let data = try? Data(contentsOf: url) else { return nil }
        return Sound(id: name, symbol: symbol, wav: data)
    }

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
