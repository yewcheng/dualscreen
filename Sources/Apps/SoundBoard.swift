import AVFoundation
import UIKit

/// Stream sound effects. Ding is synthesised; the rest are recordings in
/// Sources/Sounds, trimmed and loudness-matched. Mixed over other apps, so
/// Spotify keeps playing underneath (dipped while an effect plays, if asked).
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
        let url: URL
    }

    static let sounds: [Sound] = [
        dingFile().map { Sound(id: "Ding", symbol: "bell.fill", url: $0) },
        recording("Applause", "hands.clap.fill", "applause"),
        recording("Cheer", "megaphone.fill", "cheer"),
        recording("Crickets", "ellipsis.bubble", "crickets"),
        recording("Crow", "bird.fill", "crow"),
    ].compactMap { $0 }

    private static func recording(_ name: String, _ symbol: String, _ file: String) -> Sound? {
        Bundle.main.url(forResource: file, withExtension: "m4a").map { Sound(id: name, symbol: symbol, url: $0) }
    }

    /// AVAudioFile reads files, so the synthesised ding is written to Caches once.
    private static func dingFile() -> URL? {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ding.wav")
        return (try? wav(bell()).write(to: url)) == nil ? nil : url
    }

    // MARK: Playback

    /// players -> bus -> boost (EQ global gain) -> peak limiter -> output.
    /// AVAudioPlayer stops at 100%; the EQ goes past it and the limiter keeps
    /// a 500% boost from clipping into crackle.
    private static let engine = AVAudioEngine()
    private static let bus = AVAudioMixerNode()
    private static let boost = AVAudioUnitEQ(numberOfBands: 0)
    private static let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private static var wired = false
    private static var ducking = 0
    private static let rate = 44_100

    /// `gain` 1...5 is 100%...500%. `duck` lowers other apps' audio (Spotify)
    /// while the effect plays.
    static func play(_ sound: Sound, gain: Double, duck: Bool) {
        guard let file = try? AVAudioFile(forReading: sound.url) else { return }
        let session = AVAudioSession.sharedInstance()
        if duck {
            ducking += 1
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
        } else if ducking == 0 {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? session.setActive(true)

        if !wired {
            [bus, boost, limiter].forEach(engine.attach)
            engine.connect(bus, to: boost, format: nil)
            engine.connect(boost, to: limiter, format: nil)
            engine.connect(limiter, to: engine.mainMixerNode, format: nil)
            wired = true
        }
        boost.globalGain = Float(20 * log10(max(1, min(5, gain))))   // 500% = +14 dB
        if !engine.isRunning { try? engine.start() }

        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: bus, format: file.processingFormat)
        node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in
            DispatchQueue.main.async {
                engine.detach(node)
                guard duck else { return }
                ducking -= 1
                // back to plain mixing so KeepAlive's silent loop doesn't hold Spotify down
                if ducking == 0 {
                    try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                    try? session.setActive(true)
                }
            }
        }
        node.play()
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
