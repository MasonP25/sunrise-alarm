import SwiftUI
import UIKit

struct ContentView: View {
    @State private var ble = BluetoothManager()
    @State private var paletteStore = PaletteStore()
    @State private var animator = SunriseAnimator()
    @State private var alarm = AlarmController()
    @State private var keepAlive = BackgroundKeepAlive()
    @State private var ambient = AmbientSoundPlayer()

    @State private var editingAlarm: AlarmProfile? = nil
    @State private var creatingAlarm = false
    @State private var firingAlarmID: UUID? = nil
    @State private var showingDevices = false
    @State private var showingPalettes = false

    @State private var tickToRefresh = 0
    private let uiTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @State private var sunsetMinutes: Int = max(30, UserDefaults.standard.integer(forKey: "sunset_minutes"))
    @State private var soundEnabled: Bool = UserDefaults.standard.bool(forKey: "sound_enabled")
    @State private var soundType: AmbientSoundType = AmbientSoundType(rawValue: UserDefaults.standard.string(forKey: "sound_type") ?? "") ?? .brownNoise
    @State private var soundFadeMinutes: Int = max(10, UserDefaults.standard.integer(forKey: "sound_fade"))

    private var hasConnectedPeer: Bool {
        ble.peers.contains { $0.isSelected && $0.isConnected }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient
                ScrollView {
                    VStack(spacing: 16) {
                        heroCard
                        alarmsCard
                        sunsetCard
                        soundCard
                        Divider().padding(.horizontal, 40).opacity(0.4)
                        quickActionsRow
                        Spacer().frame(height: 20)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("Sunrise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingDevices = true
                        } label: {
                            Label("Devices (\(ble.peers.count))", systemImage: "dot.radiowaves.left.and.right")
                        }
                        Button {
                            showingPalettes = true
                        } label: {
                            Label("Palettes", systemImage: "paintpalette")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingPalettes) {
                PaletteEditorView(store: paletteStore)
            }
            .sheet(isPresented: $showingDevices) {
                DevicesSheet(ble: ble)
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
                alarm.setOnFire { profile, duration in
                    fireSunrise(for: profile, duration: duration)
                }
                syncKeepAlive()
            }
            .onReceive(uiTicker) { _ in
                tickToRefresh &+= 1  // trigger view refresh so countdowns tick
            }
        }
    }

    // MARK: - Background + Hero

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.02, blue: 0.10),
                Color(red: 0.10, green: 0.05, blue: 0.18),
                Color(red: 0.18, green: 0.08, blue: 0.15)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var heroCard: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(
                        red:   Double(animator.currentColor.r) / 255,
                        green: Double(animator.currentColor.g) / 255,
                        blue:  Double(animator.currentColor.b) / 255
                    ))
                    .frame(height: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                if animator.isRunning {
                    VStack(spacing: 2) {
                        Text("SUNRISE")
                            .font(.system(.caption2, design: .rounded))
                            .fontWeight(.heavy)
                            .kerning(1.5)
                            .foregroundStyle(.white.opacity(0.9))
                        Text("\(Int(animator.progress * 100))%")
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 3)
                    }
                }
            }
            if let (nextAlarm, wakeAt) = alarm.soonestNextFire {
                HStack(spacing: 6) {
                    Image(systemName: "alarm.fill")
                        .foregroundStyle(.orange)
                    Text("Next: \(nextAlarm.name) — \(formatCountdown(to: wakeAt))")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
    }

    // MARK: - Alarms

    private var alarmsCard: some View {
        card(title: "Alarms", icon: "alarm.fill", accent: .orange, trailing: {
            AnyView(
                Button {
                    creatingAlarm = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.orange)
                }
            )
        }) {
            AnyView(alarmsContent)
        }
    }

    @ViewBuilder
    private var alarmsContent: some View {
        if alarm.alarms.isEmpty {
            emptyState(icon: "alarm", text: "No alarms yet.\nTap + to add one.")
        } else {
            VStack(spacing: 8) {
                ForEach(alarm.alarms) { a in
                    alarmRow(a)
                }
            }
            snoozeButton
        }
    }

    private func alarmRow(_ a: AlarmProfile) -> some View {
        Button {
            editingAlarm = a
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(timeString(hour: a.hour, minute: a.minute))
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        .foregroundStyle(a.isEnabled ? .white : Color.white.opacity(0.4))
                        .monospacedDigit()
                    HStack(spacing: 6) {
                        Text(a.name)
                            .font(.footnote)
                            .foregroundStyle(a.isEnabled ? Color.white.opacity(0.7) : Color.white.opacity(0.3))
                        Text("·")
                            .foregroundStyle(Color.white.opacity(0.3))
                        Text(daysString(a.repeatDays))
                            .font(.footnote)
                            .foregroundStyle(a.isEnabled ? Color.white.opacity(0.7) : Color.white.opacity(0.3))
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { a.isEnabled },
                    set: { on in
                        alarm.toggle(id: a.id, on: on)
                        syncKeepAlive()
                    }))
                    .labelsHidden()
                    .tint(.orange)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(a.isEnabled ? 0.06 : 0.03))
            )
        }
        .buttonStyle(.plain)
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
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.blue.opacity(0.25))
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    // MARK: - Sunset

    private var sunsetCard: some View {
        card(title: "Sunset", icon: "moon.fill", accent: .purple, trailing: {
            AnyView(
                Picker("Length", selection: Binding(
                    get: { sunsetMinutes },
                    set: {
                        sunsetMinutes = $0
                        UserDefaults.standard.set($0, forKey: "sunset_minutes")
                    })) {
                    ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.menu)
                .tint(Color.white.opacity(0.9))
            )
        }) {
            AnyView(
                Button {
                    startSunset()
                } label: {
                    HStack {
                        Image(systemName: "moon.stars.fill")
                        Text("Fade to sleep")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(hasConnectedPeer
                                  ? LinearGradient(colors: [.purple, .indigo], startPoint: .leading, endPoint: .trailing)
                                  : LinearGradient(colors: [Color.gray.opacity(0.4)], startPoint: .top, endPoint: .bottom))
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!hasConnectedPeer)
            )
        }
    }

    // MARK: - Ambient sound

    private var soundCard: some View {
        card(title: "Ambient Sound", icon: "waveform", accent: .teal, trailing: {
            AnyView(
                Toggle("", isOn: $soundEnabled)
                    .labelsHidden()
                    .tint(.teal)
                    .onChange(of: soundEnabled) { _, v in
                        UserDefaults.standard.set(v, forKey: "sound_enabled")
                        if !v { ambient.stop() }
                    }
            )
        }) {
            AnyView(soundContent)
        }
    }

    private var soundContent: some View {
        VStack(spacing: 10) {
            settingRow(label: "Type") {
                AnyView(
                    Picker("Type", selection: Binding(
                        get: { soundType },
                        set: {
                            soundType = $0
                            UserDefaults.standard.set($0.rawValue, forKey: "sound_type")
                        })) {
                        ForEach(AmbientSoundType.allCases) { t in Text(t.rawValue).tag(t) }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.white.opacity(0.9))
                )
            }
            settingRow(label: "Fade in") {
                AnyView(
                    Picker("Fade", selection: Binding(
                        get: { soundFadeMinutes },
                        set: {
                            soundFadeMinutes = $0
                            UserDefaults.standard.set($0, forKey: "sound_fade")
                        })) {
                        ForEach([1, 3, 5, 10, 15, 20, 30], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.white.opacity(0.9))
                )
            }
            Button {
                if ambient.isPlaying { ambient.stop() }
                else { ambient.start(type: soundType, fadeInMinutes: Double(soundFadeMinutes)) }
            } label: {
                HStack {
                    Image(systemName: ambient.isPlaying ? "stop.fill" : "play.fill")
                    Text(ambient.isPlaying ? "Stop Sound" : "Play Sound")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(soundEnabled ? Color.teal.opacity(0.35) : Color.gray.opacity(0.25))
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!soundEnabled)
        }
    }

    // MARK: - Quick actions row (demo + on/off)

    private var quickActionsRow: some View {
        VStack(spacing: 10) {
            Menu {
                Button("10 seconds") { runDemo(seconds: 10) }
                Button("30 seconds") { runDemo(seconds: 30) }
                Button("1 minute")   { runDemo(seconds: 60) }
                Button("2 minutes")  { runDemo(seconds: 120) }
                Button("5 minutes")  { runDemo(seconds: 300) }
                Button("Stop", role: .destructive) { animator.cancel() }
            } label: {
                HStack {
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Test Sunrise")
                        .foregroundStyle(.white)
                        .fontWeight(.medium)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )
                )
            }
            .disabled(!hasConnectedPeer)
            .opacity(hasConnectedPeer ? 1.0 : 0.4)

            if hasConnectedPeer {
                HStack(spacing: 10) {
                    Button {
                        animator.cancel()
                        ble.setPower(false)
                    } label: {
                        Label("Off", systemImage: "power")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Button {
                        ble.setPower(true)
                        ble.setColor(r: 255, g: 240, b: 220)
                    } label: {
                        Label("Warm White", systemImage: "sun.max.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    showingDevices = true
                } label: {
                    Label("Connect a strip", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Card builder + helpers

    private func card(title: String, icon: String, accent: Color,
                      trailing: () -> AnyView,
                      @ViewBuilder content: () -> AnyView) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon).foregroundStyle(accent)
                Text(title.uppercased())
                    .font(.system(.caption, design: .rounded)).fontWeight(.bold).kerning(1.2)
                    .foregroundStyle(Color.white.opacity(0.6))
                Spacer()
                trailing()
            }
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(Color.white.opacity(0.3))
            Text(text)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private func settingRow(label: String, @ViewBuilder content: () -> AnyView) -> some View {
        HStack {
            Text(label).foregroundStyle(Color.white.opacity(0.85))
            Spacer()
            content()
        }
    }

    // MARK: - Actions

    private func fireSunrise(for profile: AlarmProfile, duration: TimeInterval) {
        firingAlarmID = profile.id
        let palette = paletteStore.palettes.first(where: { $0.id == profile.paletteID })
            ?? paletteStore.activePalette
        animator.run(
            palette: palette,
            durationSeconds: duration,
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

    private func formatCountdown(to date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "now" }
        let total = Int(interval)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let mins = (total % 3600) / 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(mins)m" }
        if mins > 0 { return "in \(mins)m" }
        return "in <1m"
    }
}

// MARK: - Devices sheet

struct DevicesSheet: View {
    @Bindable var ble: BluetoothManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if ble.peers.isEmpty {
                        Text("Tap Scan below to find your LED strips.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(ble.peers, id: \.id) { peer in
                        Button {
                            ble.toggleSelection(peer)
                        } label: {
                            HStack {
                                Image(systemName: peer.isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(peer.isSelected ? Color.orange : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.name).font(.body)
                                    Text(peer.isConnected ? "Connected" : "Not connected")
                                        .font(.caption)
                                        .foregroundStyle(peer.isConnected ? .green : .secondary)
                                }
                                Spacer()
                                Text("\(peer.rssi) dBm")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("BLE Devices")
                } footer: {
                    Text("Only devices selected here will be controlled by alarms, sunset, and manual buttons.")
                }
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(ble.isScanning ? "Stop" : "Scan") {
                        if ble.isScanning { ble.stopScan() } else { ble.startScan() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
                Image(systemName: "checkmark").foregroundStyle(Color.orange)
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
