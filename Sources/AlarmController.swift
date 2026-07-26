import Foundation
import Observation

struct AlarmProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var hour: Int
    var minute: Int
    var durationMinutes: Int
    var paletteID: UUID?
    var repeatDays: Set<Int>   // 1=Sun..7=Sat, empty = one-shot
    var isEnabled: Bool

    init(id: UUID = UUID(),
         name: String,
         hour: Int, minute: Int,
         durationMinutes: Int = 20,
         paletteID: UUID? = nil,
         repeatDays: Set<Int> = [],
         isEnabled: Bool = false) {
        self.id = id
        self.name = name
        self.hour = hour
        self.minute = minute
        self.durationMinutes = durationMinutes
        self.paletteID = paletteID
        self.repeatDays = repeatDays
        self.isEnabled = isEnabled
    }
}

@Observable
class AlarmController {
    private static let key = "alarms_v2"
    var alarms: [AlarmProfile] = []
    /// Latest computed next-fire per enabled alarm, for display.
    var nextFires: [UUID: Date] = [:]

    private var tasks: [UUID: Task<Void, Never>] = [:]
    // Callback receives (profile, effectiveDurationSeconds).
    // effectiveDuration is the profile's full duration when scheduled normally,
    // or reduced if the app opened after the intended start time.
    private var onFireHandler: ((AlarmProfile, TimeInterval) -> Void)? = nil

    var hasEnabledAlarm: Bool { alarms.contains { $0.isEnabled } }

    /// Soonest upcoming fire across all enabled alarms.
    var soonestNextFire: (alarm: AlarmProfile, date: Date)? {
        var best: (AlarmProfile, Date)? = nil
        for a in alarms where a.isEnabled {
            guard let d = nextFires[a.id] else { continue }
            if best == nil || d < best!.1 {
                best = (a, d)
            }
        }
        return best
    }

    init() {
        load()
        if alarms.isEmpty {
            alarms = [
                AlarmProfile(name: "Weekdays", hour: 6, minute: 30, repeatDays: [2,3,4,5,6]),
                AlarmProfile(name: "Weekends", hour: 8, minute: 0, repeatDays: [1,7]),
            ]
            save()
        }
    }

    /// Wire up what to do when any alarm fires (called on main).
    /// Handler receives (profile, effectiveDurationSeconds).
    func setOnFire(_ handler: @escaping (AlarmProfile, TimeInterval) -> Void) {
        onFireHandler = handler
        rescheduleAll()
    }

    func addAlarm(_ alarm: AlarmProfile) {
        alarms.append(alarm)
        save()
        if alarm.isEnabled { schedule(alarm) }
    }

    func removeAlarm(id: UUID) {
        cancel(id: id)
        alarms.removeAll { $0.id == id }
        save()
    }

    func updateAlarm(_ alarm: AlarmProfile) {
        guard let idx = alarms.firstIndex(where: { $0.id == alarm.id }) else { return }
        alarms[idx] = alarm
        save()
        cancel(id: alarm.id)
        if alarm.isEnabled { schedule(alarm) }
    }

    func toggle(id: UUID, on: Bool) {
        guard let idx = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[idx].isEnabled = on
        save()
        cancel(id: id)
        if on { schedule(alarms[idx]) }
    }

    /// Snooze a currently-firing alarm by N minutes. Runs a compressed 5-minute sunrise then.
    func snooze(alarmID: UUID, minutes: Int) {
        guard let a = alarms.first(where: { $0.id == alarmID }) else { return }
        cancel(id: alarmID)
        let fire = Date().addingTimeInterval(Double(minutes) * 60)
        nextFires[alarmID] = fire
        tasks[alarmID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Double(minutes) * 60 * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                // Snooze wake = punchy 5-min sunrise (they want to actually get up now).
                self?.onFireHandler?(a, 5 * 60)
                if a.repeatDays.isEmpty {
                    self?.toggle(id: a.id, on: false)
                } else {
                    self?.schedule(a)
                }
            }
        }
    }

    // MARK: - Internals

    private func rescheduleAll() {
        for a in alarms {
            cancel(id: a.id)
            if a.isEnabled { schedule(a) }
        }
    }

    private func schedule(_ alarm: AlarmProfile) {
        guard onFireHandler != nil else { return }
        guard let wakeTime = computeNextFire(for: alarm) else { return }
        // Sunrise should PEAK at wake time — schedule the animation start
        // durationMinutes BEFORE wake time so the final bright frame lands at wake.
        nextFires[alarm.id] = wakeTime  // display: user's set wake time
        let fullDuration = Double(alarm.durationMinutes) * 60
        let startTime = wakeTime.addingTimeInterval(-fullDuration)
        let now = Date()

        let delay: TimeInterval
        let effectiveDuration: TimeInterval
        if startTime <= now && now < wakeTime {
            // We're already inside the sunrise window (app opened late).
            // Start immediately with reduced duration ending at wake time.
            delay = 0
            effectiveDuration = max(30, wakeTime.timeIntervalSince(now))
        } else if now >= wakeTime {
            // Already past wake time (shouldn't happen for future wake but guard anyway).
            // Just fire immediately with the full duration.
            delay = 0
            effectiveDuration = fullDuration
        } else {
            delay = startTime.timeIntervalSince(now)
            effectiveDuration = fullDuration
        }

        tasks[alarm.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self = self else { return }
                self.onFireHandler?(alarm, effectiveDuration)
                if alarm.repeatDays.isEmpty {
                    self.toggle(id: alarm.id, on: false)
                } else {
                    self.schedule(alarm)
                }
            }
        }
    }

    private func cancel(id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        nextFires.removeValue(forKey: id)
    }

    private func computeNextFire(for alarm: AlarmProfile, now: Date = Date()) -> Date? {
        var comps = DateComponents()
        comps.hour = alarm.hour
        comps.minute = alarm.minute
        comps.second = 0
        let cal = Calendar.current

        if alarm.repeatDays.isEmpty {
            return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime, direction: .forward)
        }
        for daysAhead in 0..<8 {
            guard let candidate = cal.date(byAdding: .day, value: daysAhead, to: now) else { continue }
            var c = cal.dateComponents([.year, .month, .day], from: candidate)
            c.hour = alarm.hour
            c.minute = alarm.minute
            c.second = 0
            if let date = cal.date(from: c),
               date > now,
               alarm.repeatDays.contains(cal.component(.weekday, from: date)) {
                return date
            }
        }
        return nil
    }

    private func save() {
        if let data = try? JSONEncoder().encode(alarms) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else { return }
        if let decoded = try? JSONDecoder().decode([AlarmProfile].self, from: data) {
            alarms = decoded
        }
    }
}
