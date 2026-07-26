import CoreBluetooth
import Foundation
import Observation

struct StripPeer: Identifiable, Hashable {
    let id: UUID          // CBPeripheral.identifier
    var name: String
    var rssi: Int
    var isConnected: Bool
    var isSelected: Bool  // user wants to control this one
    // Peripheral kept separately (not Codable/Equatable) via BluetoothManager storage
}

@Observable
class BluetoothManager: NSObject {
    static let serviceUUID = CBUUID(string: "FFF0")
    static let writeUUID   = CBUUID(string: "FFF3")

    var status: String = "Idle"
    var isScanning: Bool = false
    var peers: [StripPeer] = []

    private var central: CBCentralManager!
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var writeCharsByID: [UUID: CBCharacteristic] = [:]

    private static let selectedKey = "sunrise_selected_ids_v1"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard central.state == .poweredOn else {
            status = "Bluetooth not powered on"
            return
        }
        isScanning = true
        status = "Scanning..."
        central.scanForPeripherals(withServices: nil, options: nil)
        // Auto-stop scan after 15s
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.stopScan()
        }
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        if status == "Scanning..." { status = "Scan stopped" }
    }

    func toggleSelection(_ peer: StripPeer) {
        guard let idx = peers.firstIndex(where: { $0.id == peer.id }) else { return }
        peers[idx].isSelected.toggle()
        if peers[idx].isSelected && !peers[idx].isConnected {
            if let p = peripheralsByID[peer.id] {
                central.connect(p, options: nil)
                status = "Connecting to \(peer.name)..."
            }
        }
        saveSelected()
    }

    /// Send a command to every selected + connected peer.
    func broadcast(_ bytes: [UInt8]) {
        let data = Data(bytes)
        for peer in peers where peer.isSelected && peer.isConnected {
            if let p = peripheralsByID[peer.id], let wc = writeCharsByID[peer.id] {
                p.writeValue(data, for: wc, type: .withoutResponse)
            }
        }
    }

    func setColor(r: UInt8, g: UInt8, b: UInt8) {
        broadcast(StripProtocol.color(r: r, g: g, b: b))
    }

    func setPower(_ on: Bool) {
        broadcast(on ? StripProtocol.powerOn : StripProtocol.powerOff)
    }

    func setBrightness(_ v: UInt8) {
        broadcast(StripProtocol.brightness(v))
    }

    private func saveSelected() {
        let selected = peers.filter { $0.isSelected }.map { $0.id.uuidString }
        UserDefaults.standard.set(selected, forKey: Self.selectedKey)
    }

    private func loadSelectedSet() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.selectedKey) ?? [])
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:    status = "Bluetooth ready. Tap Scan."
        case .poweredOff:   status = "Turn on Bluetooth"
        case .unauthorized: status = "Grant Bluetooth permission in Settings"
        default:            status = "BT state: \(central.state.rawValue)"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advName ?? ""
        // Show every named BLE device so obscure strip brands are visible too.
        // Filter out unnamed ones to reduce noise (headphones, phones, etc still show but are named).
        guard !name.isEmpty else { return }

        peripheralsByID[peripheral.identifier] = peripheral

        let selectedSet = loadSelectedSet()
        let wasSelected = selectedSet.contains(peripheral.identifier.uuidString)

        if let idx = peers.firstIndex(where: { $0.id == peripheral.identifier }) {
            peers[idx].rssi = RSSI.intValue
            peers[idx].name = name
        } else {
            let peer = StripPeer(
                id: peripheral.identifier,
                name: name,
                rssi: RSSI.intValue,
                isConnected: false,
                isSelected: wasSelected
            )
            peers.append(peer)
            // Auto-connect if previously selected
            if wasSelected {
                central.connect(peripheral, options: nil)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
        if let idx = peers.firstIndex(where: { $0.id == peripheral.identifier }) {
            peers[idx].isConnected = true
        }
        status = "Connected. Discovering..."
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        status = "Connect failed: \(error?.localizedDescription ?? "?")"
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if let idx = peers.firstIndex(where: { $0.id == peripheral.identifier }) {
            peers[idx].isConnected = false
        }
        writeCharsByID.removeValue(forKey: peripheral.identifier)
        // If it was selected, try to reconnect
        if let idx = peers.firstIndex(where: { $0.id == peripheral.identifier }),
           peers[idx].isSelected {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.central.connect(peripheral, options: nil)
            }
        }
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics([Self.writeUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for char in service.characteristics ?? [] where char.uuid == Self.writeUUID {
            writeCharsByID[peripheral.identifier] = char
            status = "Ready"
        }
    }
}
