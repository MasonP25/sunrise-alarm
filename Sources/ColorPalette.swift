import Foundation
import SwiftUI
import Observation

struct PaletteColor: Codable, Identifiable, Equatable {
    let id: UUID
    var r: UInt8
    var g: UInt8
    var b: UInt8

    init(id: UUID = UUID(), r: UInt8, g: UInt8, b: UInt8) {
        self.id = id; self.r = r; self.g = g; self.b = b
    }

    var swiftUIColor: Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    static let black   = PaletteColor(r: 0,   g: 0,   b: 0)
    static let red     = PaletteColor(r: 120, g: 15,  b: 0)
    static let orange  = PaletteColor(r: 255, g: 100, b: 20)
    static let yellow  = PaletteColor(r: 255, g: 200, b: 80)
    static let warmWht = PaletteColor(r: 255, g: 240, b: 220)
}

struct Palette: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var colors: [PaletteColor]

    init(id: UUID = UUID(), name: String, colors: [PaletteColor]) {
        self.id = id; self.name = name; self.colors = colors
    }

    static let classicSunrise = Palette(
        name: "Classic Sunrise",
        colors: [.black, .red, .orange, .yellow, .warmWht]
    )
}

@Observable
class PaletteStore {
    private static let key = "palettes_v1"
    private static let activeKey = "active_palette_id_v1"

    var palettes: [Palette] = []
    var activeID: UUID? = nil

    var activePalette: Palette {
        get {
            if let id = activeID, let p = palettes.first(where: { $0.id == id }) { return p }
            return palettes.first ?? .classicSunrise
        }
    }

    init() {
        load()
        if palettes.isEmpty {
            palettes = [.classicSunrise]
            activeID = palettes.first?.id
            save()
        }
        if activeID == nil { activeID = palettes.first?.id }
    }

    func setActive(_ palette: Palette) {
        activeID = palette.id
        UserDefaults.standard.set(palette.id.uuidString, forKey: Self.activeKey)
    }

    func addNew(name: String) {
        let p = Palette(name: name, colors: [.black, .warmWht])
        palettes.append(p)
        setActive(p)
        save()
    }

    func update(_ palette: Palette) {
        if let i = palettes.firstIndex(where: { $0.id == palette.id }) {
            palettes[i] = palette
            save()
        }
    }

    func delete(_ palette: Palette) {
        palettes.removeAll { $0.id == palette.id }
        if activeID == palette.id { activeID = palettes.first?.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(palettes) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        if let id = activeID {
            UserDefaults.standard.set(id.uuidString, forKey: Self.activeKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([Palette].self, from: data) {
            palettes = decoded
        }
        if let s = UserDefaults.standard.string(forKey: Self.activeKey),
           let uuid = UUID(uuidString: s) {
            activeID = uuid
        }
    }
}

/// Interpolate the palette across [0, 1] and return RGB at fraction f.
enum PaletteInterp {
    static func color(at f: Double, palette: Palette) -> (r: UInt8, g: UInt8, b: UInt8) {
        let colors = palette.colors
        guard colors.count > 0 else { return (0, 0, 0) }
        if colors.count == 1 {
            let c = colors[0]; return (c.r, c.g, c.b)
        }
        let clamped = max(0, min(1, f))
        let segments = Double(colors.count - 1)
        let scaled = clamped * segments
        let idx = min(Int(scaled), colors.count - 2)
        let local = scaled - Double(idx)
        let a = colors[idx]
        let b = colors[idx + 1]
        let r = Double(a.r) + (Double(b.r) - Double(a.r)) * local
        let g = Double(a.g) + (Double(b.g) - Double(a.g)) * local
        let bl = Double(a.b) + (Double(b.b) - Double(a.b)) * local
        return (UInt8(r.rounded()), UInt8(g.rounded()), UInt8(bl.rounded()))
    }
}
