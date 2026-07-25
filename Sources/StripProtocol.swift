import Foundation

/// ELK-BLEDOM / MELK protocol (7E-framed). No handshake needed for standard ELK-BLEDOM.
enum StripProtocol {
    /// Set solid color. 9 bytes.
    static func color(r: UInt8, g: UInt8, b: UInt8) -> [UInt8] {
        return [0x7E, 0x00, 0x05, 0x03, r, g, b, 0x00, 0xEF]
    }

    /// Power on. 9 bytes.
    static let powerOn: [UInt8] = [0x7E, 0x00, 0x04, 0xF0, 0x00, 0x01, 0xFF, 0x00, 0xEF]

    /// Power off. 9 bytes.
    static let powerOff: [UInt8] = [0x7E, 0x00, 0x04, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xEF]

    /// Set brightness (0-100).
    static func brightness(_ v: UInt8) -> [UInt8] {
        let clamped = min(v, 100)
        return [0x7E, 0x04, 0x01, clamped, 0x01, 0xFF, 0xFF, 0x00, 0xEF]
    }
}
