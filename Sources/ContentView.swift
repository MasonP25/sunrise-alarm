import SwiftUI
import UIKit

struct ContentView: View {
    @State private var ble = BluetoothManager()
    @State private var paletteStore = PaletteStore()
    @State private var animator = SunriseAnimator()
    @State private var alarm = AlarmController()
    @State private var keepAlive = BackgroundKeepAlive()
    @State private var ambient = AmbientSoundPlayer()

    @State private var showingPaletteEditor = false
    @State private var editingAlarm: AlarmProfile? = nil
    @State private var creatingAlarm = false
    @State private var firingAlarmID: UUID? = nil    // tracked so snooze knows which alarm to reschedule

    // Sunset
    @State private var sunsetMinutes: Int = max(30, UserDefaults.standard.integer(forKey: "sunset_minutes"))

    // Ambient sound
    @State private var soundEnabled: Bool = UserDefaults.standard.bool(forKey: "sound_enabled")
    @State private var soundType: AmbientSoundType = AmbientSoundType(rawValue: UserDefaults.standard.string(forKey: "sound_type") ?? "") ?? .brownNoise
    @State private var soundFadeMinutes: Int = max(10, UserDefaults.standard.integer(forKey: "sound_fade"))

    private var hasConnectedPeer: Bool {
        ble.peers.contains { $0.isSelected && $0.isConnected }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    statusText
                    previewSwatch
                    alarmsCard
                    sunsetCard
                    soundCard
                    demoButton
                    manualControls
                    devicesCard
                }
                .padding()
            }
            .navigationTitle("Sunrise")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingPaletteEditor) {
                PaletteEditorView(store: paletteStore)
            }
            .sheet(item: $editingAlarm) { existing in
                AlarmEditView(
                    paletteStore: paletteStore,
                    existing: existing,
                    onSave: { updated in
                        alarm.updateAlarm(updated)
                        syncKeepAlive()
                    },
                    onDelete: {
                        alarm.removeAlarm(id: existing.id)
                        syncKeepAlive()
                    }
                )
            }
            .sheet(isPresented: $creatingAlarm) {
                AlarmEditView(
                    paletteStore: paletteStore,
                    existing: nil,
                    onSave: { newAlarm in
                        alarm.addAlarm(newAlarm)
                        syncKeepAlive()
                    },
                    onDelete: nil
                )
            }
            .onAppear {
                alarm.setOnFire { profile in
                    fireSunrise(for: profile)
                }
                syncKeepAlive()
            }
        }
    }

    // MARK: - Status + preview

    private var statusText: some View {
        VStack(spacing: 2) {
            Text(ble.status)
                .font(.footnote).foregroundStyle(.secondary)
            if let (a, d) = alarm.soonestNextFire {
                Text("Next: \(a.name) — \(formatFireDate(d))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var previewSwatch: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(
                red:   Double(animator.currentColor.r) / 255,
                green: Double(animator.currentColor.g) / 255,
                blue:  Double(animator.currentColor.b) / 255
            ))
            .frame(height: 60)
            .overlay(alignment: .leading) {
                if animator.isRunning {
                    Text("\(Int(animator.progress * 100))%")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(.leading, 12)
                }
            }
    }

    // MARK: - Alarms list

    private var alarmsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Alarms").font(.headline)
                Spacer()
                Button {
                    creatingAlarm = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
            }
            if alarm.alarms.isEmpty {
                Text("No alarms yet. Tap + to add one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(alarm.alarms) { a in
                alarmRow(a)
            }
            snoozeButton
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.10)))
    }

    private func alarmRow(_ a: AlarmProfile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(a.name).font(.subheadline).bold()
                Text(timeString(hour: a.hour, minute: a.minute))
                    .font(.system(.title2, design: .rounded))
                Text(daysString(a.repeatDays))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { a.isEnabled },
                set: { on in
                    alarm.toggle(id: a.id, on: on)
                    syncKeepAlive()
                }))
                .labelsHidden()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            editingAlarm = a
        }
    }

    @ViewBuilder
    private var snoozeButton: some View {
        if animator.isRunning, let id = firingAlarmID {
            Button {
                snoozeCurrent(id: id)
            } label: {
                HStack {
                    Image(systemName: "zzz")
                    Text("Snooze 10 min")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(.blue)
        }
    }

    // MARK: - Sunset

    private var sunsetCard: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Sunset (fade to sleep)").font(.headline)
                Spacer()
                Picker("Length", selection: Binding(
                    get: { sunsetMinutes },
                    set: {
                        sunsetMinutes = $0
                        UserDefaults.standard.set($0, forKey: "sunset_minutes")
                    })) {
                    ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.menu)
            }
            Button {
                startSunset()
            } label: {
                HStack {
                    Image(systemName: "moon.fill")
                    Text("Start Sunset")
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(!hasConnectedPeer)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.10)))
    }

    // MARK: - Ambient sound

    private var soundCard: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Ambient Sound").font(.headline)
                Spacer()
                Toggle("", isOn: $soundEnabled)
                    .labelsHidden()
                    .onChange(of: soundEnabled) { _, v in
                        UserDefaults.standard.set(v, forKey: "sound_enabled")
                        if !v { ambient.stop() }
                    }
            }
            HStack {
                Text("Type")
                Spacer()
                Picker("Type", selection: Binding(
                    get: { soundType },
                    set: {
                        soundType = $0
                        UserDefaults.standard.set($0.rawValue, forKey: "sound_type")
                    })) {
                    ForEach(AmbientSoundType.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.menu)
            }
            HStack {
                Text("Fade in over")
                Spacer()
                Picker("Fade", selection: Binding(
                    get: { soundFadeMinutes },
                    set: {
                        soundFadeMinutes = $0
                        UserDefaults.standard.set($0, forKey: "sound_fade")
                    })) {
                    ForEach([1, 3, 5, 10, 15, 20, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.menu)
            }
            Button {
                if ambient.isPlaying { ambient.stop() }
                else { ambient.start(type: soundType, fadeInMinutes: Double(soundFadeMinutes)) }
            } label: {
                HStack {
                    Image(systemName: ambient.isPlaying ? "stop.fill" : "play.fill")
                    Text(ambient.isPlaying ? "Stop Sound" : "Play Sound")
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .disabled(!soundEnabled)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.10)))
    }

    // MARK: - Demo + manual + devices

    private var demoButton: some View {
        Menu {
            Button("10 seconds") { runDemo(seconds: 10) }
            Button("30 seconds") { runDemo(seconds: 30) }
            Button("1 minute")   { runDemo(seconds: 60) }
            Button("2 minutes")  { runDemo(seconds: 120) }
            Button("5 minutes")  { runDemo(seconds: 300) }
            Button("Stop", role: .destructive) { animator.cancel() }
        } label: {
            HStack {
                Image(systemName: "play.fill")
                Text("Demo Sunrise")
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.4)))
        }
        .disabled(!hasConnectedPeer)
    }

    @ViewBuilder
    private var manualControls: some View {
        if hasConnectedPeer {
            HStack(spacing: 10) {
                Button {
                    animator.cancel()
                    ble.setPower(false)
                } label: {
                    Text("Off").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    ble.setPower(true)
                    ble.setColor(r: 255, g: 240, b: 220)
                } label: {
                    Text("On").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Strips").font(.headline)
                Spacer()
                Button {
                    if ble.isScanning { ble.stopScan() } else { ble.startScan() }
                } label: {
                    Text(ble.isScanning ? "Stop" : "Scan")
                }
                .buttonStyle(.bordered)
            }
            if ble.peers.isEmpty {
                Text("Tap Scan to find your LED strips.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ble.peers, id: \.id) { peer in
                deviceRow(peer)
            }
            NavigationLink {
                PaletteEditorRoot(store: paletteStore)
            } label: {
                HStack {
                    Text("Palettes").font(.subheadline)
                    Spacer()
                    Text("\(paletteStore.palettes.count)")
                        .font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.10)))
    }

    private func deviceRow(_ peer: StripPeer) -> some View {
        Button {
            ble.toggleSelection(peer)
        } label: {
            HStack {
                Image(systemName: peer.isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(peer.isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(peer.name).font(.subheadline)
                    Text(peer.isConnected ? "connected" : "not connected")
                        .font(.caption2)
                        .foregroundStyle(peer.isConnected ? .green : .secondary)
                }
                Spacer()
                Text("\(peer.rssi)").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func fireSunrise(for profile: AlarmProfile) {
        firingAlarmID = profile.id
        let palette = paletteStore.palettes.first(where: { $0.id == profile.paletteID })
            ?? paletteStore.activePalette
        animator.run(
            palette: palette,
            durationSeconds: Double(profile.durationMinutes) * 60,
            ble: ble
        )
    }

    private func snoozeCurrent(id: UUID) {
        animator.cancel()
        alarm.snooze(alarmID: id, minutes: 10)
    }

    private func startSunset() {
        animator.run(
            palette: paletteStore.activePalette,
            durationSeconds: Double(sunsetMinutes) * 60,
            ble: ble,
            reversed: true
        )
        keepAlive.start()
    }

    private func runDemo(seconds: Double) {
        animator.run(
            palette: paletteStore.activePalette,
            durationSeconds: seconds,
            ble: ble
        )
    }

    /// Keep the app awake whenever any alarm is enabled (so it can actually fire overnight).
    private func syncKeepAlive() {
        if alarm.hasEnabledAlarm {
            keepAlive.start()
        } else if !ambient.isPlaying && !animator.isRunning {
            keepAlive.stop()
        }
    }

    // MARK: - Formatters

    private func timeString(hour: Int, minute: Int) -> String {
        let c = DateComponents(hour: hour, minute: minute)
        let d = Calendar.current.date(from: c) ?? Date()
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        return df.string(from: d)
    }

    private func daysString(_ days: Set<Int>) -> String {
        if days.isEmpty { return "Once" }
        if days == [1,2,3,4,5,6,7] { return "Every day" }
        if days == [2,3,4,5,6] { return "Weekdays" }
        if days == [1,7] { return "Weekends" }
        let labels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return days.sorted().map { labels[$0 - 1] }.joined(separator: " ")
    }

    private func formatFireDate(_ d: Date) -> String {
        let df = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(d) { df.dateFormat = "'today' h:mm a" }
        else if cal.isDateInTomorrow(d) { df.dateFormat = "'tomorrow' h:mm a" }
        else { df.dateFormat = "EEE h:mm a" }
        return df.string(from: d)
    }
}

// MARK: - Palettes list root (wraps PaletteEditorView for NavigationLink use)

struct PaletteEditorRoot: View {
    @Bindable var store: PaletteStore
    var body: some View {
        PaletteEditorView(store: store)
    }
}

// MARK: - Palette Editor (up to 15 colors)

struct PaletteEditorView: View {
    @Bindable var store: PaletteStore
    @Environment(\.dismiss) var dismiss
    @State private var editingIndex: Int? = nil
    @State private var editingColor: Color = .white
    @State private var newPaletteName: String = ""

    var body: some View {
        NavigationStack {
            List {
                palettesSection
                colorsSection
            }
            .navigationTitle("Palettes")
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, .constant(.active))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: Binding(
                get: { editingIndex.map { IndexWrapper(index: $0) } },
                set: { editingIndex = $0?.index }
            )) { wrap in
                colorEditSheet(wrap)
            }
        }
    }

    private var palettesSection: some View {
        Section("Palettes") {
            ForEach(store.palettes) { p in
                paletteRow(p)
            }
            .onDelete { indexSet in
                for i in indexSet { store.delete(store.palettes[i]) }
            }
            HStack {
                TextField("New palette name", text: $newPaletteName)
                Button("Add") {
                    let name = newPaletteName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        store.addNew(name: name)
                        newPaletteName = ""
                    }
                }
                .disabled(newPaletteName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func paletteRow(_ p: Palette) -> some View {
        HStack {
            Text(p.name)
            Spacer()
            if store.activeID == p.id {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.setActive(p) }
    }

    private var colorsSection: some View {
        Section("Colors in \"\(store.activePalette.name)\" (up to 15)") {
            ForEach(Array(store.activePalette.colors.enumerated()), id: \.element.id) { idx, color in
                colorRow(index: idx, color: color)
            }
            .onDelete { indexSet in
                var p = store.activePalette
                for i in indexSet.sorted(by: >) {
                    if p.colors.count > 1 { p.colors.remove(at: i) }
                }
                store.update(p)
            }
            .onMove { indices, newOffset in
                var p = store.activePalette
                p.colors.move(fromOffsets: indices, toOffset: newOffset)
                store.update(p)
            }
            if store.activePalette.colors.count < 15 {
                Button {
                    var p = store.activePalette
                    p.colors.append(.warmWht)
                    store.update(p)
                } label: {
                    Label("Add color", systemImage: "plus.circle")
                }
            }
        }
    }

    private func colorRow(index idx: Int, color: PaletteColor) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.swiftUIColor)
                .frame(width: 44, height: 30)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.4)))
            Text("Color \(idx + 1)").font(.subheadline)
            Spacer()
            Button("Edit") {
                editingIndex = idx
                editingColor = color.swiftUIColor
            }
            .buttonStyle(.bordered)
        }
    }

    private func colorEditSheet(_ wrap: IndexWrapper) -> some View {
        NavigationStack {
            VStack {
                ColorPicker("Color \(wrap.index + 1)", selection: $editingColor, supportsOpacity: false)
                    .labelsHidden().scaleEffect(1.5).padding()
                Spacer()
            }
            .navigationTitle("Edit Color").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { saveEditedColor(index: wrap.index) }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { editingIndex = nil }
                }
            }
        }
    }

    private func saveEditedColor(index: Int) {
        var p = store.activePalette
        guard index < p.colors.count else { return }
        let ui = UIColor(editingColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        p.colors[index].r = UInt8(max(0, min(255, (r * 255).rounded())))
        p.colors[index].g = UInt8(max(0, min(255, (g * 255).rounded())))
        p.colors[index].b = UInt8(max(0, min(255, (b * 255).rounded())))
        store.update(p)
        editingIndex = nil
    }
}

private struct IndexWrapper: Identifiable {
    let index: Int
    var id: Int { index }
}
