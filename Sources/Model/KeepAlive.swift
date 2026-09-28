import AVFoundation
import UIKit

/// iPadOS presents the external scene only while the app is foreground. Leave
/// DualScreen and the system reclaims the display and resumes mirroring.
///
/// There is no API to hold the screen, but an app that keeps running in the
/// background keeps its scenes alive, and the only background mode available to
/// us here is audio. So we play silence on a loop while a display is attached.
///
/// Honest caveats: this costs battery, it is an App Store rejection risk (fine
/// for a sideloaded app), and whether iPadOS keeps *presenting* the external
/// scene — rather than merely keeping it connected — has to be verified on the
/// device. `isRunning` is surfaced in the controller so it can be seen.
final class KeepAlive {
    static let shared = KeepAlive()

    private(set) var isRunning = false
    private var player: AVAudioPlayer?

    private init() {}

    func start() {
        guard !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // .mixWithOthers so this never interrupts music or a video call.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let player = try AVAudioPlayer(data: Self.silentWAV())
            player.numberOfLoops = -1
            player.volume = 0.01
            player.play()
            self.player = player
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        isRunning = false
    }

    /// One second of 8 kHz mono silence, built rather than bundled so there is
    /// no binary asset to explain.
    private static func silentWAV() -> Data {
        let sampleRate = 8000
        let seconds = 1
        let samples = sampleRate * seconds
        let dataBytes = samples * 2          // 16-bit mono

        var wav = Data()
        func append(_ string: String) { wav.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { wav.append(contentsOf: $0) } }

        append("RIFF")
        append32(36 + dataBytes)
        append("WAVE")
        append("fmt ")
        append32(16)                  // PCM header size
        append16(1)                   // PCM
        append16(1)                   // mono
        append32(sampleRate)
        append32(sampleRate * 2)      // byte rate
        append16(2)                   // block align
        append16(16)                  // bits per sample
        append("data")
        append32(dataBytes)
        wav.append(Data(count: dataBytes))
        return wav
    }
}
