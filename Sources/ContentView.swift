import SwiftUI
import UIKit

struct ContentView: View {
    @State private var ble = BluetoothManager()
    @State private var paletteStore = PaletteStore()
    @State private var animator = SunriseAnimator()
    @State private var alarm = AlarmController()
    @State private var keepAlive = BackgroundKeepAlive()

    @State private var showingPaletteEditor = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text(ble.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    // Live preview swatch
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(
                            red:   Double(animator.currentColor.r) / 255,
                            green: Double(animator.currentColor.g) / 255,
                            blue:  Double(animator.currentColor.b) / 255
                        ))
                        .frame(height: 60)
                        .overlay(
                            HStack {
                                if animator.isRunning {
                                    Text("Sunrise \(Int(animator.progress * 100))%")
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundStyle(.white)
                                        .shadow(radius: 2)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                        )

                    // Alarm section
                    VStack(spacing: 12) {
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

                        // Palette preview strip
                        GeometryReader { geo in
                            HStack(spacing: 0) {
                                ForEach(Array(sampledPreviewColors().enumerated()), id: \.offset) { _, c in
                                    Rectangle().fill(c)
                                }
                            }
                            .frame(height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .frame(height: 20)

                        Button {
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
                        } label: {
                            Text(alarm.isArmed
                                 ? "Disarm — fires at \(nextFireString())"
                                 : "Arm Alarm")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(alarm.isArmed ? .red : .orange)

                        if alarm.isArmed {
                            Text("Keep the phone plugged in overnight. App runs in background.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.10)))

                    // Demo button with duration menu
                    Menu {
                        Button("10 seconds") { runDemo(seconds: 10) }
                        Button("30 seconds") { runDemo(seconds: 30) }
                        Button("1 minute")   { runDemo(seconds: 60) }
                        Button("2 minutes")  { runDemo(seconds: 120) }
                        Button("5 minutes")  { runDemo(seconds: 300) }
                        Button("Stop demo", role: .destructive) { animator.cancel() }
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Demo")
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hasConnectedPeer)

                    // Manual controls
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
                                ble.setColor(r: 255, g: 240, b: 220)  // warm white
                            } label: {
                                Text("On").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    // Devices list
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
                            Button {
                                ble.toggleSelection(peer)
                            } label: {
                                HStack {
                                    Image(systemName: peer.isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(peer.isSelected ? .accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(peer.name).font(.subheadline)
                                        Text(peer.isConnected ? "connected" : "not connected")
                                            .font(.caption2).foregroundStyle(peer.isConnected ? .green : .secondary)
                                    }
                                    Spacer()
                                    Text("\(peer.rssi)").font(.caption2).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.10)))
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

    private var hasConnectedPeer: Bool {
        ble.peers.contains { $0.isSelected && $0.isConnected }
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
                Section("Palettes") {
                    ForEach(store.palettes) { p in
                        HStack {
                            Text(p.name)
                            Spacer()
                            if store.activeID == p.id {
                                Image(systemName: "checkmark").foregroundStyle(.accent)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.setActive(p)
                        }
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

                Section("Colors in \"\(store.activePalette.name)\"") {
                    ForEach(Array(store.activePalette.colors.enumerated()), id: \.element.id) { idx, color in
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
                set: { new in editingIndex = new?.index })
            ) { wrap in
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
                                var p = store.activePalette
                                if wrap.index < p.colors.count {
                                    let ui = UIColor(editingColor)
                                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                                    ui.getRed(&r, green: &g, blue: &b, alpha: &a)
                                    p.colors[wrap.index].r = UInt8(max(0, min(255, (r * 255).rounded())))
                                    p.colors[wrap.index].g = UInt8(max(0, min(255, (g * 255).rounded())))
                                    p.colors[wrap.index].b = UInt8(max(0, min(255, (b * 255).rounded())))
                                    store.update(p)
                                }
                                editingIndex = nil
                            }
                        }
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancel") { editingIndex = nil }
                        }
                    }
                }
            }
        }
    }
}

private struct IndexWrapper: Identifiable {
    let index: Int
    var id: Int { index }
}
