import Foundation
import Observation

/// Drives a smooth palette transition over a fixed duration, writing to the strip
/// every ~0.5s. Reports live progress + current color for the UI.
@Observable
class SunriseAnimator {
    var isRunning: Bool = false
    var progress: Double = 0  // 0..1
    var currentColor: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)
    var isReversed: Bool = false           // true = sunset
    var totalDurationSeconds: Double = 0
    var startedAt: Date = .distantPast

    var elapsedSeconds: Double {
        max(0, Date().timeIntervalSince(startedAt))
    }
    var remainingSeconds: Double {
        max(0, totalDurationSeconds - elapsedSeconds)
    }

    private var task: Task<Void, Never>? = nil

    func run(palette: Palette, durationSeconds: Double, ble: BluetoothManager, reversed: Bool = false) {
        cancel()
        isRunning = true
        progress = 0
        isReversed = reversed
        totalDurationSeconds = durationSeconds
        startedAt = Date()
        ble.setPower(true)

        let start = Date()
        let end = start.addingTimeInterval(durationSeconds)
        task = Task {
            while !Task.isCancelled {
                let now = Date()
                let elapsed = now.timeIntervalSince(start)
                let f = min(1.0, elapsed / durationSeconds)
                let effective = reversed ? (1.0 - f) : f
                let (r, g, b) = PaletteInterp.color(at: effective, palette: palette)
                await MainActor.run {
                    self.progress = f
                    self.currentColor = (r, g, b)
                }
                ble.setColor(r: r, g: g, b: b)
                if now >= end {
                    await MainActor.run {
                        self.isRunning = false
                        self.progress = 1
                    }
                    // Sunset ends at "dark" — turn strip off cleanly
                    if reversed {
                        ble.setPower(false)
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}
