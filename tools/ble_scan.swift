import CoreBluetooth
import Foundation

final class Scanner: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!
    private let timeout: TimeInterval
    private var seen = Set<UUID>()

    init(timeout: TimeInterval) {
        self.timeout = timeout
        super.init()
        self.central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            print("Bluetooth state: \(central.state.rawValue)")
            return
        }

        print("Scanning for \(Int(timeout)) seconds...")
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            self.central.stopScan()
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard !seen.contains(peripheral.identifier) else {
            return
        }

        seen.insert(peripheral.identifier)
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? localName ?? "(unnamed)"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map { $0.uuidString }
            .joined(separator: ",")

        print("\(name)\t\(peripheral.identifier.uuidString)\tRSSI=\(RSSI)\tservices=\(services)")
    }
}

let timeout = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 15
let scanner = Scanner(timeout: timeout)
withExtendedLifetime(scanner) {
    CFRunLoopRun()
}
