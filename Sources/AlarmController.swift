import Foundation
import Observation

@Observable
class AlarmController {
    var isArmed: Bool = false
    var nextFireDate: Date? = nil

    var alarmHour: Int {
        didSet { UserDefaults.standard.set(alarmHour, forKey: "alarm_hour") }
    }
    var alarmMinute: Int {
        didSet { UserDefaults.standard.set(alarmMinute, forKey: "alarm_minute") }
    }
    var durationMinutes: Int {
        didSet { UserDefaults.standard.set(durationMinutes, forKey: "duration_minutes") }
    }
    /// Weekdays 1=Sun ... 7=Sat. Empty = one-shot (fires once, then disarms).
    var repeatDays: Set<Int> {
        didSet {
            let arr = Array(repeatDays).sorted()
            UserDefaults.standard.set(arr, forKey: "repeat_days")
        }
    }

    private var task: Task<Void, Never>? = nil
    private var currentOnFire: (() -> Void)? = nil  // saved for re-arm / snooze

    init() {
        alarmHour       = (UserDefaults.standard.object(forKey: "alarm_hour")       as? Int) ?? 7
        alarmMinute     = (UserDefaults.standard.object(forKey: "alarm_minute")     as? Int) ?? 0
        durationMinutes = (UserDefaults.standard.object(forKey: "duration_minutes") as? Int) ?? 20
        repeatDays      = Set((UserDefaults.standard.array(forKey: "repeat_days") as? [Int]) ?? [])
    }

    /// Compute the next Date matching alarm time and (if set) repeat days.
    func computeNextFire(now: Date = Date()) -> Date {
        var comps = DateComponents()
        comps.hour = alarmHour
        comps.minute = alarmMinute
        comps.second = 0

        let cal = Calendar.current

        if repeatDays.isEmpty {
            // Single-fire: just next matching time
            let next = cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime, direction: .forward)
                ?? now.addingTimeInterval(60)
            return next
        }

        // Repeat mode: find next date whose weekday is in repeatDays
        for daysAhead in 0..<8 {
            guard let candidate = cal.date(byAdding: .day, value: daysAhead, to: now) else { continue }
            var c = cal.dateComponents([.year, .month, .day], from: candidate)
            c.hour = alarmHour
            c.minute = alarmMinute
            c.second = 0
            if let date = cal.date(from: c),
               date > now,
               repeatDays.contains(cal.component(.weekday, from: date)) {
                return date
            }
        }
        return now.addingTimeInterval(24 * 3600)
    }

    /// Arm the alarm. onFire is called on main actor when time hits.
    /// If repeatDays is non-empty, auto-rearms after firing.
    func arm(onFire: @escaping () -> Void) {
        cancel()
        currentOnFire = onFire
        scheduleNext()
    }

    private func scheduleNext() {
        guard let onFire = currentOnFire else { return }
        let fire = computeNextFire()
        nextFireDate = fire
        isArmed = true
        let delay = fire.timeIntervalSinceNow
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self = self else { return }
                onFire()
                if self.repeatDays.isEmpty {
                    // one-shot: disarm
                    self.isArmed = false
                    self.nextFireDate = nil
                    self.currentOnFire = nil
                } else {
                    // repeating: schedule again for next matching day
                    self.scheduleNext()
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isArmed = false
        nextFireDate = nil
        currentOnFire = nil
    }

    /// Snooze by minutes: cancel current fire, refire after N minutes.
    /// Does not touch alarm settings — just delays the current wake.
    func snooze(minutes: Int, onFire: @escaping () -> Void) {
        task?.cancel()
        currentOnFire = onFire
        isArmed = true
        let fire = Date().addingTimeInterval(Double(minutes) * 60)
        nextFireDate = fire
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Double(minutes) * 60 * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self = self else { return }
                onFire()
                if self.repeatDays.isEmpty {
                    self.isArmed = false
                    self.nextFireDate = nil
                    self.currentOnFire = nil
                } else {
                    self.scheduleNext()
                }
            }
        }
    }
}
