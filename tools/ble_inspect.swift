import CoreBluetooth
import Foundation

final class Inspector: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private let target: String
    private let timeout: TimeInterval
    private var peripheral: CBPeripheral?

    init(target: String, timeout: TimeInterval) {
        self.target = target.lowercased()
        self.timeout = timeout
        super.init()
        self.central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            print("Bluetooth state: \(central.state.rawValue)")
            return
        }

        print("Looking for \(target) for \(Int(timeout)) seconds...")
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if self.peripheral == nil {
                print("Target not found before timeout.")
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
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
        print("Connected. Discovering services...")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Connect failed: \(error?.localizedDescription ?? "unknown error")")
        CFRunLoopStop(CFRunLoopGetMain())
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            print("Service discovery failed: \(error.localizedDescription)")
            CFRunLoopStop(CFRunLoopGetMain())
            return
        }

        for service in peripheral.services ?? [] {
            print("Service \(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }

        if peripheral.services?.isEmpty ?? true {
            print("No services discovered.")
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            print("Characteristic discovery failed for \(service.uuid.uuidString): \(error.localizedDescription)")
        } else {
            for characteristic in service.characteristics ?? [] {
                print("  Characteristic \(characteristic.uuid.uuidString) properties=\(describe(characteristic.properties))")
            }
        }

        let complete = peripheral.services?.allSatisfy {
            $0.characteristics != nil
        } ?? true

        if complete {
            central.cancelPeripheralConnection(peripheral)
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }

    private func describe(_ properties: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if properties.contains(.broadcast) { names.append("broadcast") }
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { names.append("authenticatedSignedWrites") }
        if properties.contains(.extendedProperties) { names.append("extendedProperties") }
        if properties.contains(.notifyEncryptionRequired) { names.append("notifyEncryptionRequired") }
        if properties.contains(.indicateEncryptionRequired) { names.append("indicateEncryptionRequired") }
        return names.joined(separator: ",")
    }
}

let target = CommandLine.arguments.dropFirst().first ?? "Perdix"
let timeout = CommandLine.arguments.dropFirst(2).first.flatMap(Double.init) ?? 20
let inspector = Inspector(target: target, timeout: timeout)
withExtendedLifetime(inspector) {
    CFRunLoopRun()
}
