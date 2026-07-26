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
    private var onFireHandler: ((AlarmProfile) -> Void)? = nil

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
    func setOnFire(_ handler: @escaping (AlarmProfile) -> Void) {
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

    /// Snooze a currently-firing alarm by N minutes. Uses the same alarm profile again.
    func snooze(alarmID: UUID, minutes: Int) {
        guard let a = alarms.first(where: { $0.id == alarmID }) else { return }
        cancel(id: alarmID)
        let fire = Date().addingTimeInterval(Double(minutes) * 60)
        nextFires[alarmID] = fire
        tasks[alarmID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Double(minutes) * 60 * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                self?.onFireHandler?(a)
                // After snooze, reschedule the normal next occurrence
                if a.repeatDays.isEmpty {
                    self?.toggle(id: a.id, on: false)  // one-shot done
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
        guard let fire = computeNextFire(for: alarm) else { return }
        nextFires[alarm.id] = fire
        let delay = fire.timeIntervalSinceNow
        tasks[alarm.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self = self else { return }
                self.onFireHandler?(alarm)
                if alarm.repeatDays.isEmpty {
                    // Disable one-shot
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
