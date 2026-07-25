import SwiftUI
import UIKit

struct ContentView: View {
    @State private var ble = BluetoothManager()
    @State private var paletteStore = PaletteStore()
    @State private var animator = SunriseAnimator()
    @State private var alarm = AlarmController()
    @State private var keepAlive = BackgroundKeepAlive()

    @State private var showingPaletteEditor = false

    private var hasConnectedPeer: Bool {
        ble.peers.contains { $0.isSelected && $0.isConnected }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    statusText
                    previewSwatch
                    alarmCard
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
        }
    }

    // MARK: - Subviews

    private var statusText: some View {
        Text(ble.status)
            .font(.footnote)
            .foregroundStyle(.secondary)
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
                    Text("Sunrise \(Int(animator.progress * 100))%")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(.leading, 12)
                }
            }
    }

    private var alarmCard: some View {
        VStack(spacing: 12) {
            wakeTimePicker
            durationRow
            paletteRow
            palettePreviewStrip
            armButton
            if alarm.isArmed {
                Text("Keep the phone plugged in overnight. App runs in background.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.10)))
    }

    private var wakeTimePicker: some View {
        DatePicker(
            "Wake up at",
            selection: Binding(
                get: {
                    var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                    comps.hour = alarm.alarmHour
                    comps.minute = alarm.alarmMinute
                    return Calendar.current.date(from: comps) ?? Date()
                },
                set: { newDate in
                    let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                    alarm.alarmHour = c.hour ?? 7
                    alarm.alarmMinute = c.minute ?? 0
                }),
            displayedComponents: .hourAndMinute
        )
        .datePickerStyle(.compact)
    }

    private var durationRow: some View {
        HStack {
            Text("Sunrise length")
            Spacer()
            Picker("Duration", selection: Binding(
                get: { alarm.durationMinutes },
                set: { alarm.durationMinutes = $0 })) {
                ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { m in
                    Text("\(m) min").tag(m)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var paletteRow: some View {
        HStack {
            Text("Palette")
            Spacer()
            Picker("Palette", selection: Binding(
                get: { paletteStore.activeID ?? paletteStore.palettes.first?.id ?? UUID() },
                set: { newID in
                    if let p = paletteStore.palettes.first(where: { $0.id == newID }) {
                        paletteStore.setActive(p)
                    }
                })) {
                ForEach(paletteStore.palettes) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .pickerStyle(.menu)
            Button {
                showingPaletteEditor = true
            } label: {
                Image(systemName: "pencil")
            }
        }
    }

    private var palettePreviewStrip: some View {
        HStack(spacing: 0) {
            ForEach(Array(sampledPreviewColors().enumerated()), id: \.offset) { _, c in
                Rectangle().fill(c)
            }
        }
        .frame(height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var armButton: some View {
        Button {
            toggleAlarm()
        } label: {
            Text(alarm.isArmed
                 ? "Disarm — fires at \(nextFireString())"
                 : "Arm Alarm")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(alarm.isArmed ? .red : .orange)
    }

    private var demoButton: some View {
        Menu {
            Button("10 seconds") { runDemo(seconds: 10) }
            Button("30 seconds") { runDemo(seconds: 30) }
            Button("1 minute")   { runDemo(seconds: 60) }
            Button("2 minutes")  { runDemo(seconds: 120) }
            Button("5 minutes")  { runDemo(seconds: 300) }
            Button("Stop demo", role: .destructive) { animator.cancel() }
        } label: {
            demoLabel
        }
        .disabled(!hasConnectedPeer)
    }

    private var demoLabel: some View {
        HStack {
            Image(systemName: "play.fill")
            Text("Demo")
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.4)))
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
                Text("Tap Scan to find your ELK-BLEDOM strips.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(ble.peers, id: \.id) { peer in
                deviceRow(peer)
            }
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
                Text("\(peer.rssi)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions / helpers

    private func toggleAlarm() {
        if alarm.isArmed {
            alarm.cancel()
            keepAlive.stop()
        } else {
            alarm.arm {
                let seconds = Double(alarm.durationMinutes) * 60
                animator.run(
                    palette: paletteStore.activePalette,
                    durationSeconds: seconds,
                    ble: ble
                )
            }
            keepAlive.start()
        }
    }

    private func runDemo(seconds: Double) {
        animator.run(
            palette: paletteStore.activePalette,
            durationSeconds: seconds,
            ble: ble
        )
    }

    private func sampledPreviewColors() -> [Color] {
        let p = paletteStore.activePalette
        return (0..<40).map { i in
            let (r, g, b) = PaletteInterp.color(at: Double(i) / 39.0, palette: p)
            return Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)
        }
    }

    private func nextFireString() -> String {
        guard let d = alarm.nextFireDate else { return "?" }
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        return df.string(from: d)
    }
}

// MARK: - Palette Editor

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
                for i in indexSet {
                    store.delete(store.palettes[i])
                }
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
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.setActive(p)
        }
    }

    private var colorsSection: some View {
        Section("Colors in \"\(store.activePalette.name)\"") {
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

            Button {
                var p = store.activePalette
                p.colors.append(.warmWht)
                store.update(p)
            } label: {
                Label("Add color", systemImage: "plus.circle")
            }
        }
    }

    private func colorRow(index idx: Int, color: PaletteColor) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.swiftUIColor)
                .frame(width: 44, height: 30)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.4)))
            Text("Color \(idx + 1)")
                .font(.subheadline)
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
                    .labelsHidden()
                    .scaleEffect(1.5)
                    .padding()
                Spacer()
            }
            .navigationTitle("Edit Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        saveEditedColor(index: wrap.index)
                    }
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
