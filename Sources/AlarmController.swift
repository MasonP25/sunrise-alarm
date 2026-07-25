import Foundation
import Observation

@Observable
class AlarmController {
    var isArmed: Bool = false
    var nextFireDate: Date? = nil

    // User-facing settings (persisted)
    var alarmHour: Int {
        didSet { UserDefaults.standard.set(alarmHour, forKey: "alarm_hour") }
    }
    var alarmMinute: Int {
        didSet { UserDefaults.standard.set(alarmMinute, forKey: "alarm_minute") }
    }
    var durationMinutes: Int {
        didSet { UserDefaults.standard.set(durationMinutes, forKey: "duration_minutes") }
    }

    private var task: Task<Void, Never>? = nil

    init() {
        alarmHour       = (UserDefaults.standard.object(forKey: "alarm_hour")       as? Int) ?? 7
        alarmMinute     = (UserDefaults.standard.object(forKey: "alarm_minute")     as? Int) ?? 0
        durationMinutes = (UserDefaults.standard.object(forKey: "duration_minutes") as? Int) ?? 20
    }

    /// Compute the next Date matching the alarm's hour/minute, in the future.
    func computeNextFire(now: Date = Date()) -> Date {
        var comps = DateComponents()
        comps.hour = alarmHour
        comps.minute = alarmMinute
        comps.second = 0
        let cal = Calendar.current
        var next = cal.nextDate(
            after: now,
            matching: comps,
            matchingPolicy: .nextTime,
            direction: .forward
        ) ?? now.addingTimeInterval(60)
        // If somehow returned <= now, add a day
        if next <= now {
            next = next.addingTimeInterval(24 * 3600)
        }
        return next
    }

    /// Arm the alarm. onFire is called on the main actor when it's time to start the sunrise.
    func arm(onFire: @escaping () -> Void) {
        cancel()
        let fire = computeNextFire()
        nextFireDate = fire
        isArmed = true
        let delay = fire.timeIntervalSinceNow
        task = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                self.isArmed = false
                self.nextFireDate = nil
                onFire()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isArmed = false
        nextFireDate = nil
    }
}
