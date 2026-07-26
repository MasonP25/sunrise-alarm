import Foundation
import Observation

struct AlarmProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var hour: Int
    var minute: Int
    var durationMinutes: Int
    var paletteID: UUID?
    var repeatDays: Set<Int>
    var isEnabled: Bool

    // Ambient sound settings (per-alarm)
    var soundEnabled: Bool
    var soundType: AmbientSoundType
    var soundMinutesBefore: Int   // how many min before wake to start ramping in

    init(id: UUID = UUID(),
         name: String,
         hour: Int, minute: Int,
         durationMinutes: Int = 20,
         paletteID: UUID? = nil,
         repeatDays: Set<Int> = [],
         isEnabled: Bool = false,
         soundEnabled: Bool = false,
         soundType: AmbientSoundType = .brownNoise,
         soundMinutesBefore: Int = 15) {
        self.id = id
        self.name = name
        self.hour = hour
        self.minute = minute
        self.durationMinutes = durationMinutes
        self.paletteID = paletteID
        self.repeatDays = repeatDays
        self.isEnabled = isEnabled
        self.soundEnabled = soundEnabled
        self.soundType = soundType
        self.soundMinutesBefore = soundMinutesBefore
    }

    // Custom Codable: allow older stored alarms (without sound fields) to decode.
    enum CodingKeys: String, CodingKey {
        case id, name, hour, minute, durationMinutes, paletteID, repeatDays, isEnabled
        case soundEnabled, soundType, soundMinutesBefore
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        hour = try c.decode(Int.self, forKey: .hour)
        minute = try c.decode(Int.self, forKey: .minute)
        durationMinutes = try c.decode(Int.self, forKey: .durationMinutes)
        paletteID = try c.decodeIfPresent(UUID.self, forKey: .paletteID)
        repeatDays = try c.decode(Set<Int>.self, forKey: .repeatDays)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? false
        soundType = try c.decodeIfPresent(AmbientSoundType.self, forKey: .soundType) ?? .brownNoise
        soundMinutesBefore = try c.decodeIfPresent(Int.self, forKey: .soundMinutesBefore) ?? 15
    }
}

@Observable
class AlarmController {
    private static let key = "alarms_v2"
    var alarms: [AlarmProfile] = []
    var nextFires: [UUID: Date] = [:]

    private var tasks: [UUID: [Task<Void, Never>]] = [:]
    // Sunrise handler: (profile, effectiveDurationSeconds)
    private var onSunriseFire: ((AlarmProfile, TimeInterval) -> Void)? = nil
    // Sound handler: (profile) — reads soundType, soundMinutesBefore
    private var onSoundFire:  ((AlarmProfile) -> Void)? = nil

    var hasEnabledAlarm: Bool { alarms.contains { $0.isEnabled } }

    var soonestNextFire: (alarm: AlarmProfile, date: Date)? {
        var best: (AlarmProfile, Date)? = nil
        for a in alarms where a.isEnabled {
            guard let d = nextFires[a.id] else { continue }
            if best == nil || d < best!.1 { best = (a, d) }
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

    func setOnFire(sunrise: @escaping (AlarmProfile, TimeInterval) -> Void,
                   sound:   @escaping (AlarmProfile) -> Void) {
        onSunriseFire = sunrise
        onSoundFire = sound
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

    func snooze(alarmID: UUID, minutes: Int) {
        guard let a = alarms.first(where: { $0.id == alarmID }) else { return }
        cancel(id: alarmID)
        let fire = Date().addingTimeInterval(Double(minutes) * 60)
        nextFires[alarmID] = fire
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Double(minutes) * 60 * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                self?.onSunriseFire?(a, 5 * 60)  // 5 min mini-sunrise on snooze
                if a.repeatDays.isEmpty {
                    self?.toggle(id: a.id, on: false)
                } else {
                    self?.schedule(a)
                }
            }
        }
        tasks[alarmID] = [task]
    }

    // MARK: - Internals

    private func rescheduleAll() {
        for a in alarms {
            cancel(id: a.id)
            if a.isEnabled { schedule(a) }
        }
    }

    private func schedule(_ alarm: AlarmProfile) {
        guard onSunriseFire != nil else { return }
        guard let wakeTime = computeNextFire(for: alarm) else { return }
        nextFires[alarm.id] = wakeTime

        let fullSunrise = Double(alarm.durationMinutes) * 60
        let sunriseStart = wakeTime.addingTimeInterval(-fullSunrise)
        let now = Date()

        let sunriseDelay: TimeInterval
        let effectiveDuration: TimeInterval
        if sunriseStart <= now && now < wakeTime {
            sunriseDelay = 0
            effectiveDuration = max(30, wakeTime.timeIntervalSince(now))
        } else if now >= wakeTime {
            sunriseDelay = 0
            effectiveDuration = fullSunrise
        } else {
            sunriseDelay = sunriseStart.timeIntervalSince(now)
            effectiveDuration = fullSunrise
        }

        var alarmTasks: [Task<Void, Never>] = []

        // Sunrise task
        let sunriseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(sunriseDelay * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run { self?.onSunriseFire?(alarm, effectiveDuration) }
            // After the animation completes (+ small buffer), re-arm if repeating
            try? await Task.sleep(nanoseconds: UInt64((effectiveDuration + 30) * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self = self else { return }
                if alarm.repeatDays.isEmpty {
                    self.toggle(id: alarm.id, on: false)
                } else {
                    self.schedule(alarm)
                }
            }
        }
        alarmTasks.append(sunriseTask)

        // Sound task (if enabled)
        if alarm.soundEnabled && alarm.soundMinutesBefore > 0 {
            let soundStart = wakeTime.addingTimeInterval(-Double(alarm.soundMinutesBefore * 60))
            let soundDelay: TimeInterval
            if soundStart <= now && now < wakeTime {
                soundDelay = 0
            } else if now >= wakeTime {
                soundDelay = -1  // skip; alarm already fired
            } else {
                soundDelay = soundStart.timeIntervalSince(now)
            }
            if soundDelay >= 0 {
                let soundTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(soundDelay * 1_000_000_000))
                    if Task.isCancelled { return }
                    await MainActor.run { self?.onSoundFire?(alarm) }
                }
                alarmTasks.append(soundTask)
            }
        }

        tasks[alarm.id] = alarmTasks
    }

    private func cancel(id: UUID) {
        tasks[id]?.forEach { $0.cancel() }
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
