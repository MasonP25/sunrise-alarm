import Foundation
import AVFoundation
import Observation

enum AmbientSoundType: String, CaseIterable, Identifiable, Codable {
    case whiteNoise  = "White Noise"
    case pinkNoise   = "Pink Noise"
    case brownNoise  = "Brown Noise (Ocean-like)"
    var id: String { rawValue }
}

/// Plays ambient sound (generated noise) with gradual fade-in over N minutes.
/// Also keeps the app alive in background (audio-mode background is enough).
@Observable
class AmbientSoundPlayer {
    var isPlaying: Bool = false
    var currentType: AmbientSoundType = .brownNoise

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var fadeTask: Task<Void, Never>?

    /// Start playing the chosen noise type with a fade-in from 0 to maxVolume over fadeInMinutes.
    func start(type: AmbientSoundType, fadeInMinutes: Double, maxVolume: Float = 0.6) {
        stop()
        currentType = type

        // Audio session
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("AmbientSound audio session err: \(error)")
            return
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) else { return }
        engine.connect(player, to: engine.mainMixerNode, format: format)

        // Generate 5s buffer of the chosen noise, loop it
        guard let buffer = makeBuffer(type: type, format: format, seconds: 5) else { return }

        engine.mainMixerNode.outputVolume = 0
        do { try engine.start() } catch {
            print("AmbientSound engine err: \(error)")
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()

        self.engine = engine
        self.player = player
        isPlaying = true

        // Fade in over the specified minutes
        let fadeSeconds = max(0.5, fadeInMinutes * 60)
        fadeTask = Task { [weak self] in
            let steps = 100
            let stepDuration = fadeSeconds / Double(steps)
            for i in 1...steps {
                if Task.isCancelled { return }
                let f = Float(i) / Float(steps)
                await MainActor.run {
                    self?.engine?.mainMixerNode.outputVolume = maxVolume * f
                }
                try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
            }
        }
    }

    func stop() {
        fadeTask?.cancel(); fadeTask = nil
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Noise generation

    private func makeBuffer(type: AmbientSoundType, format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard let ptr = buffer.floatChannelData?[0] else { return nil }

        switch type {
        case .whiteNoise:
            for i in 0..<Int(frames) {
                ptr[i] = Float.random(in: -0.3...0.3)
            }
        case .pinkNoise:
            // Voss-McCartney approximation with 7 rows
            var rows = [Float](repeating: 0, count: 7)
            var counter: UInt32 = 0
            for i in 0..<Int(frames) {
                counter += 1
                var idx = 0
                while (counter & (1 << idx)) == 0 && idx < 7 {
                    idx += 1
                }
                if idx < 7 { rows[idx] = Float.random(in: -1...1) }
                let sum = rows.reduce(0, +)
                ptr[i] = (sum / 7.0) * 0.4
            }
        case .brownNoise:
            var last: Float = 0
            for i in 0..<Int(frames) {
                let white = Float.random(in: -1...1)
                last = (last + 0.02 * white) / 1.02
                ptr[i] = last * 3.0  // scale up (brown noise is naturally low amplitude)
            }
            // Normalize peaks
            var peak: Float = 0
            for i in 0..<Int(frames) { peak = max(peak, abs(ptr[i])) }
            if peak > 0 {
                let scale = 0.4 / peak
                for i in 0..<Int(frames) { ptr[i] *= scale }
            }
        }
        return buffer
    }
}
