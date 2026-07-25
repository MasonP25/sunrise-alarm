import Foundation
import AVFoundation

/// Silent audio keep-alive so the app stays running when the phone is locked.
final class BackgroundKeepAlive {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    var isActive: Bool { engine?.isRunning ?? false }

    func start() {
        guard !isActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("KeepAlive audio session err: \(error)")
            return
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) else { return }
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let frameCount = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        if let ch = buffer.floatChannelData {
            memset(ch[0], 0, Int(frameCount) * MemoryLayout<Float>.size)
        }
        do { try engine.start() } catch {
            print("KeepAlive engine err: \(error)")
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()
        self.engine = engine
        self.player = player
    }

    func stop() {
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
