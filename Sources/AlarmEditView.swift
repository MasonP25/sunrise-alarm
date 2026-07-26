import SwiftUI

struct AlarmEditView: View {
    @Environment(\.dismiss) var dismiss
    @Bindable var paletteStore: PaletteStore
    let existing: AlarmProfile?
    let onSave: (AlarmProfile) -> Void
    let onDelete: (() -> Void)?

    @State private var name: String = ""
    @State private var hour: Int = 7
    @State private var minute: Int = 0
    @State private var durationMinutes: Int = 20
    @State private var paletteID: UUID? = nil
    @State private var repeatDays: Set<Int> = []

    init(paletteStore: PaletteStore,
         existing: AlarmProfile?,
         onSave: @escaping (AlarmProfile) -> Void,
         onDelete: (() -> Void)? = nil) {
        self.paletteStore = paletteStore
        self.existing = existing
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Alarm name", text: $name)
                }

                Section("Time") {
                    DatePicker("Wake at",
                        selection: Binding(
                            get: {
                                var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                                c.hour = hour; c.minute = minute
                                return Calendar.current.date(from: c) ?? Date()
                            },
                            set: {
                                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                                hour = c.hour ?? 7
                                minute = c.minute ?? 0
                            }),
                        displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                }

                Section("Repeat") {
                    HStack(spacing: 8) {
                        ForEach(1...7, id: \.self) { d in
                            dayChip(d)
                        }
                    }
                    Text(repeatDays.isEmpty
                         ? "Fires once, then disables itself"
                         : "Fires every selected day, then re-arms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Sunrise") {
                    Picker("Length", selection: $durationMinutes) {
                        ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { m in
                            Text("\(m) min").tag(m)
                        }
                    }
                    Picker("Palette", selection: Binding(
                        get: { paletteID ?? paletteStore.palettes.first?.id ?? UUID() },
                        set: { paletteID = $0 })) {
                        ForEach(paletteStore.palettes) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                }

                if let onDelete = onDelete {
                    Section {
                        Button("Delete alarm", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Alarm" : "Edit Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let profile = AlarmProfile(
                            id: existing?.id ?? UUID(),
                            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Alarm" : name,
                            hour: hour, minute: minute,
                            durationMinutes: durationMinutes,
                            paletteID: paletteID,
                            repeatDays: repeatDays,
                            isEnabled: existing?.isEnabled ?? true
                        )
                        onSave(profile)
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let e = existing {
                    name = e.name
                    hour = e.hour
                    minute = e.minute
                    durationMinutes = e.durationMinutes
                    paletteID = e.paletteID ?? paletteStore.palettes.first?.id
                    repeatDays = e.repeatDays
                } else {
                    paletteID = paletteStore.palettes.first?.id
                }
            }
        }
    }

    private func dayChip(_ day: Int) -> some View {
        let selected = repeatDays.contains(day)
        let label = ["S", "M", "T", "W", "T", "F", "S"][day - 1]
        return Button {
            if selected { repeatDays.remove(day) } else { repeatDays.insert(day) }
        } label: {
            Text(label)
                .font(.system(.footnote, design: .rounded)).bold()
                .frame(width: 34, height: 34)
                .background(Circle().fill(selected ? Color.orange : Color.gray.opacity(0.2)))
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
