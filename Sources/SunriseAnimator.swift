import Foundation
import Observation

/// Drives a smooth palette transition over a fixed duration, writing to the strip
/// every ~0.5s. Reports live progress + current color for the UI.
@Observable
class SunriseAnimator {
    var isRunning: Bool = false
    var progress: Double = 0  // 0..1
    var currentColor: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)

    private var task: Task<Void, Never>? = nil

    func run(palette: Palette, durationSeconds: Double, ble: BluetoothManager) {
        cancel()
        isRunning = true
        progress = 0
        // Turn strip on before we start setting colors (some ELK-BLEDOM strips ignore
        // color commands when in "off" state).
        ble.setPower(true)

        let start = Date()
        let end = start.addingTimeInterval(durationSeconds)
        task = Task {
            while !Task.isCancelled {
                let now = Date()
                let elapsed = now.timeIntervalSince(start)
                let f = min(1.0, elapsed / durationSeconds)
                let (r, g, b) = PaletteInterp.color(at: f, palette: palette)
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
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}
