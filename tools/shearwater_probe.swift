import CoreBluetooth
import Foundation

let serviceUUID = CBUUID(string: "FE25C237-0ECE-443C-B0AA-E02033E7029D")
let characteristicUUID = CBUUID(string: "27B7570B-359E-45A3-91BB-CF7E70049BD2")
let end: UInt8 = 0xC0
let esc: UInt8 = 0xDB
let escEnd: UInt8 = 0xDC
let escEsc: UInt8 = 0xDD

enum ProbeError: Error, CustomStringConvertible {
    case timeout(String)
    case bluetoothState(Int)
    case targetNotFound
    case characteristicNotFound
    case protocolError(String)

    var description: String {
        switch self {
        case .timeout(let message): return "Timeout: \(message)"
        case .bluetoothState(let state): return "Bluetooth state is not powered on: \(state)"
        case .targetNotFound: return "Target not found"
        case .characteristicNotFound: return "Shearwater characteristic not found"
        case .protocolError(let message): return "Protocol error: \(message)"
        }
    }
}

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private let target: String
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var packetBytes: [UInt8] = []
    private var escaped = false
    private var pendingResponse: (([UInt8]) -> Void)?
    private var startupContinuation: ((Result<Void, Error>) -> Void)?

    init(target: String) {
        self.target = target.lowercased()
        super.init()
        self.central = CBCentralManager(delegate: self, queue: nil)
    }

    func start(timeout: TimeInterval) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>?
        startupContinuation = {
            result = $0
            semaphore.signal()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if result == nil {
                result = .failure(ProbeError.timeout("startup"))
                semaphore.signal()
            }
        }

        while semaphore.wait(timeout: .now()) != .success {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        try result!.get()
    }

    func readDataIdentifier(_ id: UInt16, timeout: TimeInterval = 5) throws -> [UInt8] {
        let request: [UInt8] = [0x22, UInt8(id >> 8), UInt8(id & 0xFF)]
        let response = try transfer(request, timeout: timeout)
        guard response.count >= 3 else {
            throw ProbeError.protocolError("short RDBI response")
        }
        guard response[0] == 0x62 && response[1] == request[1] && response[2] == request[2] else {
            throw ProbeError.protocolError("unexpected RDBI response \(hex(response))")
        }
        return Array(response.dropFirst(3))
    }

    private func transfer(_ input: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
        guard let peripheral, let characteristic else {
            throw ProbeError.characteristicNotFound
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: [UInt8]?
        pendingResponse = {
            result = $0
            semaphore.signal()
        }

        packetBytes.removeAll()
        escaped = false
        let payload = [0xFF, 0x01, UInt8(input.count + 1), 0x00] + input
        let writeType: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        for frame in encodeBleSlipFrames(payload) {
            peripheral.writeValue(Data(frame), for: characteristic, type: writeType)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while result == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        pendingResponse = nil
        guard let packet = result else {
            throw ProbeError.timeout("response for \(hex(input))")
        }

        guard packet.count >= 4 && packet[0] == 0x01 && packet[1] == 0xFF && packet[3] == 0x00 else {
            throw ProbeError.protocolError("bad packet header \(hex(packet))")
        }

        let length = Int(packet[2])
        guard length >= 1 && length - 1 + 4 == packet.count else {
            throw ProbeError.protocolError("bad packet length \(hex(packet))")
        }

        return Array(packet.dropFirst(4))
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            startupContinuation?(.failure(ProbeError.bluetoothState(central.state.rawValue)))
            startupContinuation = nil
            return
        }

        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? localName ?? ""
        let uuid = peripheral.identifier.uuidString

        guard name.lowercased().contains(target) || uuid.lowercased() == target else {
            return
        }

        print("Found \(name.isEmpty ? "(unnamed)" : name) \(uuid) RSSI=\(RSSI)")
        self.peripheral = peripheral
        central.stopScan()
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            startupContinuation?(.failure(error))
            startupContinuation = nil
            return
        }

        guard let service = peripheral.services?.first else {
            startupContinuation?(.failure(ProbeError.characteristicNotFound))
            startupContinuation = nil
            return
        }

        peripheral.discoverCharacteristics([characteristicUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            startupContinuation?(.failure(error))
            startupContinuation = nil
            return
        }

        guard let characteristic = service.characteristics?.first else {
            startupContinuation?(.failure(ProbeError.characteristicNotFound))
            startupContinuation = nil
            return
        }

        self.characteristic = characteristic
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            startupContinuation?(.failure(error))
        } else {
            startupContinuation?(.success(()))
        }
        startupContinuation = nil
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else {
            return
        }

        let bytes = [UInt8](data)
        guard bytes.count >= 2 else {
            return
        }

        for byte in bytes.dropFirst(2) {
            if byte == end || byte == esc {
                if escaped {
                    return
                }

                if byte == end {
                    if !packetBytes.isEmpty {
                        let packet = packetBytes
                        packetBytes.removeAll()
                        pendingResponse?(packet)
                    }
                } else {
                    escaped = true
                }
                continue
            }

            if escaped {
                if byte == escEnd {
                    packetBytes.append(end)
                } else if byte == escEsc {
                    packetBytes.append(esc)
                } else {
                    packetBytes.append(byte)
                }
                escaped = false
            } else {
                packetBytes.append(byte)
            }
        }
    }
}

func encodeBleSlipFrames(_ payload: [UInt8]) -> [[UInt8]] {
    var encoded: [UInt8] = []
    for byte in payload {
        if byte == end {
            encoded.append(contentsOf: [esc, escEnd])
        } else if byte == esc {
            encoded.append(contentsOf: [esc, escEsc])
        } else {
            encoded.append(byte)
        }
    }
    encoded.append(end)

    let frameCount = UInt8((encoded.count + 29) / 30)
    var frames: [[UInt8]] = []
    var offset = 0
    var index: UInt8 = 0
    while offset < encoded.count {
        let count = min(30, encoded.count - offset)
        frames.append([frameCount, index] + Array(encoded[offset..<(offset + count)]))
        offset += count
        index += 1
    }
    return frames
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined()
}

func ascii(_ bytes: [UInt8]) -> String {
    String(bytes: bytes, encoding: .ascii) ?? hex(bytes)
}

let target = CommandLine.arguments.dropFirst().first ?? "Perdix"
let probe = Probe(target: target)

do {
    try probe.start(timeout: 20)
    let serial = try probe.readDataIdentifier(0x8010)
    let firmware = try probe.readDataIdentifier(0x8011)
    let hardware = try? probe.readDataIdentifier(0x8050)
    let model = try probe.readDataIdentifier(0x8060)
    let logUpload = try probe.readDataIdentifier(0x8021)

    print("serial: \(ascii(serial)) hex=\(hex(serial))")
    print("firmware: \(ascii(firmware)) hex=\(hex(firmware))")
    if let hardware {
        print("hardware: \(ascii(hardware)) hex=\(hex(hardware))")
    } else {
        print("hardware: unsupported")
    }
    print("model: \(hex(model))")
    print("logupload: \(hex(logUpload))")
} catch {
    print("\(error)")
    exit(1)
}
