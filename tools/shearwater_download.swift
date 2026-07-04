import CoreBluetooth
import Foundation

final class RunLogger {
    private let handle: FileHandle?

    init(directory: String?) {
        guard let directory else {
            self.handle = nil
            return
        }

        do {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            let filename = "shearwater-download-\(formatter.string(from: Date())).log"
            let fileURL = url.appendingPathComponent(filename)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            self.handle = try FileHandle(forWritingTo: fileURL)
            self.write("Logging to \(fileURL.path)")
        } catch {
            Swift.print("Failed to initialize log file: \(error)")
            self.handle = nil
        }
    }

    deinit {
        try? handle?.close()
    }

    func write(_ message: String) {
        Swift.print(message)
        guard let handle, let data = (message + "\n").data(using: .utf8) else {
            return
        }
        try? handle.write(contentsOf: data)
    }
}

var logger = RunLogger(directory: nil)

func log(_ message: String) {
    logger.write(message)
}

let serviceUUID = CBUUID(string: "FE25C237-0ECE-443C-B0AA-E02033E7029D")
let characteristicUUID = CBUUID(string: "27B7570B-359E-45A3-91BB-CF7E70049BD2")
let end: UInt8 = 0xC0
let esc: UInt8 = 0xDB
let escEnd: UInt8 = 0xDC
let escEsc: UInt8 = 0xDD

let manifestAddress: UInt32 = 0xE0000000
let manifestSize = 0x600
let recordSize = 0x20
let recordCount = manifestSize / recordSize
let maxDiveSize = 0xFFFFFF

struct DiveRecord {
    let index: Int
    let fingerprint: [UInt8]
    let address: UInt32
}

enum DownloadError: Error, CustomStringConvertible {
    case timeout(String)
    case bluetoothState(Int)
    case characteristicNotFound
    case protocolError(String)
    case filesystem(String)

    var description: String {
        switch self {
        case .timeout(let message): return "Timeout: \(message)"
        case .bluetoothState(let state): return "Bluetooth state is not powered on: \(state)"
        case .characteristicNotFound: return "Shearwater characteristic not found"
        case .protocolError(let message): return "Protocol error: \(message)"
        case .filesystem(let message): return "Filesystem error: \(message)"
        }
    }
}

final class ShearwaterClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
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
                result = .failure(DownloadError.timeout("startup"))
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
            throw DownloadError.protocolError("short RDBI response")
        }
        guard response[0] == 0x62 && response[1] == request[1] && response[2] == request[2] else {
            throw DownloadError.protocolError("unexpected RDBI response \(hex(response))")
        }
        return Array(response.dropFirst(3))
    }

    func shutdownBluetoothMode() {
        do {
            try sendWithoutResponse([0x2E, 0x90, 0x20, 0x00])
            log("Sent shutdown command to leave Bluetooth/upload mode")
        } catch {
            log("Failed to send Bluetooth shutdown command: \(error)")
        }
    }

    func download(address: UInt32, size: Int, compression: Bool) throws -> [UInt8] {
        let initRequest: [UInt8] = [
            0x35,
            compression ? 0x10 : 0x00,
            0x34,
            UInt8((address >> 24) & 0xFF),
            UInt8((address >> 16) & 0xFF),
            UInt8((address >> 8) & 0xFF),
            UInt8(address & 0xFF),
            UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF),
            UInt8(size & 0xFF),
        ]

        let initResponse = try transfer(initRequest, timeout: 10)
        guard initResponse.count == 3 && initResponse[0] == 0x75 && initResponse[1] == 0x10 else {
            throw DownloadError.protocolError("unexpected download init response \(hex(initResponse))")
        }

        var output: [UInt8] = []
        var compressedBytes = 0
        var block: UInt8 = 1
        var done = false

        while compressedBytes < size && !done {
            let response = try transfer([0x36, block], timeout: 10)
            guard response.count >= 2 && response[0] == 0x76 && response[1] == block else {
                throw DownloadError.protocolError("unexpected block response \(hex(response))")
            }

            let body = Array(response.dropFirst(2))
            if compression {
                let final = try decompressLre(body, into: &output)
                done = final
            } else {
                output.append(contentsOf: body)
            }

            compressedBytes += body.count
            block &+= 1

            if output.count % 65536 < body.count {
                log("  received \(output.count) bytes")
            }
        }

        let missingCompressedTerminator = compression && !done
        if compression {
            xorDecompress(&output)
        }

        let quitResponse = try transfer([0x37], timeout: 10)
        guard quitResponse.count == 2 && quitResponse[0] == 0x77 && quitResponse[1] == 0x00 else {
            throw DownloadError.protocolError("unexpected download quit response \(hex(quitResponse))")
        }
        if missingCompressedTerminator {
            throw DownloadError.protocolError("compressed dive ended before LRE terminator")
        }

        return output
    }

    private func transfer(_ input: [UInt8], timeout: TimeInterval) throws -> [UInt8] {
        guard let peripheral, let characteristic else {
            throw DownloadError.characteristicNotFound
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
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        pendingResponse = nil
        guard let packet = result else {
            throw DownloadError.timeout("response for \(hex(input))")
        }

        guard packet.count >= 4 && packet[0] == 0x01 && packet[1] == 0xFF && packet[3] == 0x00 else {
            throw DownloadError.protocolError("bad packet header \(hex(packet))")
        }

        let length = Int(packet[2])
        guard length >= 1 && length - 1 + 4 == packet.count else {
            throw DownloadError.protocolError("bad packet length \(hex(packet))")
        }

        return Array(packet.dropFirst(4))
    }

    private func sendWithoutResponse(_ input: [UInt8]) throws {
        guard let peripheral, let characteristic else {
            throw DownloadError.characteristicNotFound
        }

        let payload = [0xFF, 0x01, UInt8(input.count + 1), 0x00] + input
        let writeType: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        for frame in encodeBleSlipFrames(payload) {
            peripheral.writeValue(Data(frame), for: characteristic, type: writeType)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            startupContinuation?(.failure(DownloadError.bluetoothState(central.state.rawValue)))
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

        log("Found \(name.isEmpty ? "(unnamed)" : name) \(uuid) RSSI=\(RSSI)")
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
            startupContinuation?(.failure(DownloadError.characteristicNotFound))
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
            startupContinuation?(.failure(DownloadError.characteristicNotFound))
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

func decompressLre(_ bytes: [UInt8], into output: inout [UInt8]) throws -> Bool {
    let bitCount = bytes.count * 8
    if bitCount % 9 != 0 {
        throw DownloadError.protocolError("LRE bit count is not divisible by 9")
    }

    var offset = 0
    while offset + 9 <= bitCount {
        let byteIndex = offset / 8
        let bitIndex = offset % 8
        let high = UInt16(bytes[byteIndex]) << 8
        let low = byteIndex + 1 < bytes.count ? UInt16(bytes[byteIndex + 1]) : 0
        let value = Int((high | low) >> UInt16(16 - (bitIndex + 9))) & 0x1FF

        if value & 0x100 != 0 {
            output.append(UInt8(value & 0xFF))
        } else if value == 0 {
            return true
        } else {
            output.append(contentsOf: repeatElement(0, count: value))
        }

        offset += 9
    }

    return false
}

func xorDecompress(_ bytes: inout [UInt8]) {
    guard bytes.count > 32 else {
        return
    }

    for index in 32..<bytes.count {
        bytes[index] ^= bytes[index - 32]
    }
}

func parseManifest(_ data: [UInt8]) -> [DiveRecord] {
    var records: [DiveRecord] = []
    var offset = 0

    while offset + recordSize <= data.count {
        let header = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        if header == 0x5A23 {
            offset += recordSize
            continue
        }
        if header != 0xA5C4 {
            break
        }

        let fingerprint = Array(data[(offset + 4)..<(offset + 8)])
        let address =
            UInt32(data[offset + 20]) << 24 |
            UInt32(data[offset + 21]) << 16 |
            UInt32(data[offset + 22]) << 8 |
            UInt32(data[offset + 23])

        records.append(DiveRecord(index: records.count + 1, fingerprint: fingerprint, address: address))
        offset += recordSize
    }

    return records
}

func parseManifestPage(_ data: [UInt8], firstIndex: Int) -> (records: [DiveRecord], deleted: Int, full: Bool) {
    var records: [DiveRecord] = []
    var deleted = 0
    var offset = 0

    while offset + recordSize <= data.count {
        let header = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        if header == 0x5A23 {
            deleted += 1
            offset += recordSize
            continue
        }
        if header != 0xA5C4 {
            break
        }

        let fingerprint = Array(data[(offset + 4)..<(offset + 8)])
        let address =
            UInt32(data[offset + 20]) << 24 |
            UInt32(data[offset + 21]) << 16 |
            UInt32(data[offset + 22]) << 8 |
            UInt32(data[offset + 23])

        records.append(DiveRecord(index: firstIndex + records.count, fingerprint: fingerprint, address: address))
        offset += recordSize
    }

    return (records, deleted, records.count + deleted == recordCount)
}

func downloadManifestRecords(client: ShearwaterClient) throws -> (records: [DiveRecord], pages: Int) {
    var records: [DiveRecord] = []
    var page = 1
    var previousPage: [UInt8]?

    while true {
        if page > 64 {
            throw DownloadError.protocolError("too many manifest pages")
        }

        log("Downloading manifest page \(page)...")
        let manifest = try client.download(address: manifestAddress, size: manifestSize, compression: false)
        if previousPage == manifest {
            throw DownloadError.protocolError("manifest page repeated before final page")
        }
        previousPage = manifest

        let parsed = parseManifestPage(manifest, firstIndex: records.count + 1)
        records.append(contentsOf: parsed.records)
        log("Manifest page \(page) has \(parsed.records.count) active records and \(parsed.deleted) deleted records")

        if !parsed.full {
            return (records, page)
        }

        page += 1
    }
}

func rawFilename(for record: DiveRecord) -> String {
    String(format: "perdix-ai.%04d.%@.bin", record.index, hex(record.fingerprint))
}

func rawURL(for record: DiveRecord, outputDir: URL) -> URL {
    outputDir.appendingPathComponent(rawFilename(for: record))
}

func xmlURL(for record: DiveRecord, xmlDir: URL) -> URL {
    let raw = rawFilename(for: record)
    let stem = String(raw.dropLast(4))
    return xmlDir.appendingPathComponent(stem + ".xml")
}

func downloadedRecordIndexes(records: [DiveRecord], outputDir: URL) -> Set<Int> {
    var indexes = Set<Int>()
    for record in records {
        if FileManager.default.fileExists(atPath: rawURL(for: record, outputDir: outputDir).path) {
            indexes.insert(record.index)
        }
    }
    return indexes
}

func existingOutputDirectory(records: [DiveRecord], baseOutputDir: URL) -> URL? {
    let fileManager = FileManager.default
    var candidates = [baseOutputDir]
    if let urls = try? fileManager.contentsOfDirectory(
        at: baseOutputDir,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) {
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                candidates.append(url)
            }
        }
    }

    return candidates
        .map { ($0, downloadedRecordIndexes(records: records, outputDir: $0)) }
        .filter { !$0.1.isEmpty }
        .max { $0.1.count < $1.1.count }?
        .0
}

func firstMissingIndex(records: [DiveRecord], downloaded: Set<Int>) -> Int? {
    records.first { !downloaded.contains($0.index) }?.index
}

func boundedDiveSize(for record: DiveRecord, records: [DiveRecord]) -> Int? {
    guard record.index > 1, record.index - 2 < records.count else {
        return nil
    }
    let newerRecord = records[record.index - 2]
    guard newerRecord.address > record.address else {
        return nil
    }
    let gap = newerRecord.address - record.address
    return gap > 0 && gap < UInt32(maxDiveSize) ? Int(gap) : nil
}

func downloadDive(client: ShearwaterClient, record: DiveRecord, records: [DiveRecord], address: UInt32) throws -> [UInt8] {
    do {
        return try client.download(address: address, size: maxDiveSize, compression: true)
    } catch DownloadError.protocolError(let message) where message.contains("unexpected download init response 7F3531") {
        if let boundedSize = boundedDiveSize(for: record, records: records) {
            log(String(format: "Open-ended download was rejected; retrying dive %04d with manifest-bounded size %d bytes", record.index, boundedSize))
            return try client.download(address: address, size: boundedSize, compression: true)
        }
        throw DownloadError.protocolError(message)
    }
}

func logStats(label: String, records: [DiveRecord], pages: Int, outputDir: URL) -> Set<Int> {
    let downloaded = downloadedRecordIndexes(records: records, outputDir: outputDir)
    let missing = max(records.count - downloaded.count, 0)
    let next = firstMissingIndex(records: records, downloaded: downloaded)
    if let next {
        log("\(label): found \(records.count) dives in \(pages) manifest pages; \(downloaded.count) downloaded, \(missing) remaining; next missing dive is \(next)")
    } else {
        log("\(label): found \(records.count) dives in \(pages) manifest pages; \(downloaded.count) downloaded, 0 remaining")
    }
    return downloaded
}

func promptYesNo(_ message: String, defaultYes: Bool) -> Bool {
    let suffix = defaultYes ? " [Y/n] " : " [y/N] "
    log(message + suffix)
    let answer = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if answer.isEmpty {
        return defaultYes
    }
    return answer == "y" || answer == "yes"
}

func convertRawToXML(records: [DiveRecord], outputDir: URL, xmlDir: URL, overwrite: Bool) {
    do {
        try FileManager.default.createDirectory(at: xmlDir, withIntermediateDirectories: true)
    } catch {
        log("Failed to create XML directory \(xmlDir.path): \(error)")
        return
    }

    var converted = 0
    var skipped = 0
    var failed = 0

    for record in records {
        let raw = rawURL(for: record, outputDir: outputDir)
        let xml = xmlURL(for: record, xmlDir: xmlDir)

        guard FileManager.default.fileExists(atPath: raw.path) else {
            skipped += 1
            log("Skipping XML conversion for missing raw file \(raw.path)")
            continue
        }

        if FileManager.default.fileExists(atPath: xml.path) && !overwrite {
            skipped += 1
            log("Skipping existing XML \(xml.path)")
            continue
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "dctool",
            "-d",
            "Shearwater Perdix AI",
            "parse",
            "-o",
            xml.path,
            raw.path,
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            log("Converting \(raw.path) -> \(xml.path)")
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                for line in output.split(separator: "\n") {
                    log(String(line))
                }
            }

            if process.terminationStatus == 0 {
                converted += 1
            } else {
                failed += 1
                log("XML conversion failed for \(raw.path) with exit code \(process.terminationStatus)")
            }
        } catch {
            failed += 1
            log("XML conversion failed for \(raw.path): \(error)")
        }
    }

    log("XML conversion complete: \(converted) converted, \(skipped) skipped, \(failed) failed")
}

func uint32BE(_ bytes: [UInt8], offset: Int = 0) -> UInt32 {
    UInt32(bytes[offset]) << 24 |
    UInt32(bytes[offset + 1]) << 16 |
    UInt32(bytes[offset + 2]) << 8 |
    UInt32(bytes[offset + 3])
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined()
}

func ascii(_ bytes: [UInt8]) -> String {
    String(bytes: bytes, encoding: .ascii) ?? hex(bytes)
}

func storageKey(target: String, serial: String, model: String) -> String {
    let device = target.isEmpty ? "perdix" : target
    let identifier = serial.isEmpty ? model : serial
    let raw = "shearwater-\(device)-\(identifier)"
    let allowed = raw.lowercased().map { character -> Character in
        if character.isLetter || character.isNumber {
            return character
        }
        return "-"
    }
    return String(allowed).replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
}

func argumentValue(_ name: String, default defaultValue: String) -> String {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else {
        return defaultValue
    }
    return args[index + 1]
}

func argumentInt(_ name: String) -> Int? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else {
        return nil
    }
    return Int(args[index + 1])
}

func argumentIntSet(_ name: String) -> Set<Int> {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else {
        return []
    }
    return Set(args[index + 1].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
}

func hasArgument(_ name: String) -> Bool {
    CommandLine.arguments.contains(name)
}

func promptForBluetoothMode(target: String) {
    log("Put \(target) into Bluetooth/upload mode, then press Enter to start scanning.")
    _ = readLine()
}

let target = argumentValue("--target", default: "Perdix")
let baseOutputDir = URL(fileURLWithPath: argumentValue("--output-dir", default: "data/raw"))
let baseXmlDir = URL(fileURLWithPath: argumentValue("--xml-dir", default: "data/xml"))
let logDir = argumentValue("--log-dir", default: "logs")
let limit = argumentInt("--limit")
let explicitStart = argumentInt("--start")
let count = argumentInt("--count")
let listOnly = hasArgument("--list-only")
let skipExisting = hasArgument("--skip-existing")
let skipDives = argumentIntSet("--skip-dives")
let continueOnError = hasArgument("--continue-on-error")
let noPrompt = hasArgument("--no-prompt")
let noConvertPrompt = hasArgument("--no-convert-prompt")
let overwriteXML = hasArgument("--overwrite-xml")
logger = RunLogger(directory: logDir)
log("Command: \(CommandLine.arguments.joined(separator: " "))")

do {
    try FileManager.default.createDirectory(at: baseOutputDir, withIntermediateDirectories: true)

    if !noPrompt {
        promptForBluetoothMode(target: target)
    }

    let client = ShearwaterClient(target: target)
    try client.start(timeout: 20)

    let serial = try client.readDataIdentifier(0x8010)
    let firmware = try client.readDataIdentifier(0x8011)
    let model = try client.readDataIdentifier(0x8060)
    let logUpload = try client.readDataIdentifier(0x8021)

    log("serial: \(ascii(serial))")
    log("firmware: \(ascii(firmware))")
    log("model: \(hex(model))")
    log("logupload: \(hex(logUpload))")
    let deviceStorageKey = storageKey(target: target, serial: ascii(serial), model: hex(model))
    log("storage key: \(deviceStorageKey)")

    let baseAddress = uint32BE(logUpload, offset: 1)
    guard baseAddress == 0x80000000 || baseAddress == 0x90000000 || baseAddress == 0xC0000000 || baseAddress == 0xDD000000 else {
        throw DownloadError.protocolError("unknown logbook base address \(String(format: "%08X", baseAddress))")
    }
    let normalizedBase: UInt32 = baseAddress == 0x80000000 ? baseAddress : 0xC0000000

    let manifest = try downloadManifestRecords(client: client)
    let records = manifest.records
    let pages = manifest.pages
    log("Manifest contains \(records.count) active dive records")
    let existingOutputDir = existingOutputDirectory(records: records, baseOutputDir: baseOutputDir)
    let outputDir = existingOutputDir ?? baseOutputDir.appendingPathComponent(deviceStorageKey)
    let outputKey = outputDir.lastPathComponent
    let xmlDir = outputDir == baseOutputDir ? baseXmlDir : baseXmlDir.appendingPathComponent(outputKey)
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    log("raw output directory: \(outputDir.path)")
    log("xml output directory: \(xmlDir.path)")
    if existingOutputDir != nil {
        log("Using existing output directory because matching dive files were found there.")
    }
    let beforeDownloaded = logStats(label: "Before download", records: records, pages: pages, outputDir: outputDir)

    if listOnly {
        for record in records {
            let address = normalizedBase &+ record.address
            log(String(format: "Dive %04d fingerprint=%@ address=%08X", record.index, hex(record.fingerprint), address))
        }
        client.shutdownBluetoothMode()
        exit(0)
    }

    let start = explicitStart ?? firstMissingIndex(records: records, downloaded: beforeDownloaded) ?? 1
    let startIndex = max(start - 1, 0)
    var selected = Array(records.dropFirst(startIndex))
    if let count {
        selected = Array(selected.prefix(count))
    } else if let limit {
        selected = Array(selected.prefix(limit))
    }

    log("Selected \(selected.count) dive records starting at dive \(start)")
    let batchStarted = Date()
    var completed = 0
    var downloaded = 0
    var failed: [Int] = []
    for record in selected {
        let address = normalizedBase &+ record.address
        let filename = String(format: "perdix-ai.%04d.%@.bin", record.index, hex(record.fingerprint))
        let url = outputDir.appendingPathComponent(filename)
        if skipDives.contains(record.index) {
            log("Skipping requested dive \(record.index)")
            completed += 1
            continue
        }
        if skipExisting && FileManager.default.fileExists(atPath: url.path) {
            log("Skipping existing \(url.path)")
            completed += 1
            continue
        }

        log("Downloading dive \(record.index) at \(String(format: "%08X", address)) fingerprint=\(hex(record.fingerprint))")
        let diveStarted = Date()
        do {
            let dive = try downloadDive(client: client, record: record, records: records, address: address)
            try Data(dive).write(to: url, options: .atomic)
            let elapsed = Date().timeIntervalSince(diveStarted)
            completed += 1
            downloaded += 1
            log(String(format: "Wrote %@ (%d bytes, %.1fs)", url.path, dive.count, elapsed))
            let batchElapsed = Date().timeIntervalSince(batchStarted)
            let average = batchElapsed / Double(max(downloaded, 1))
            let remaining = max(selected.count - completed, 0)
            log(String(format: "Progress %d/%d selected, %.1fs/downloaded dive avg, estimated %.1f minutes remaining in batch", completed, selected.count, average, (average * Double(remaining)) / 60.0))
        } catch {
            if continueOnError {
                completed += 1
                failed.append(record.index)
                log("Failed dive \(record.index); continuing because --continue-on-error is set: \(error)")
                continue
            }
            throw error
        }
    }
    log(String(format: "Batch complete in %.1fs", Date().timeIntervalSince(batchStarted)))
    if !failed.isEmpty {
        log("Failed dives in this batch: \(failed.map(String.init).joined(separator: ","))")
    }
    let afterDownloaded = logStats(label: "After download", records: records, pages: pages, outputDir: outputDir)
    if let next = firstMissingIndex(records: records, downloaded: afterDownloaded) {
        let nextCount = count ?? limit ?? selected.count
        log("Next batch command: /tmp/shearwater_download --target \(target) --start \(next) --count \(nextCount) --skip-existing --output-dir \(baseOutputDir.path) --xml-dir \(baseXmlDir.path) --log-dir \(logDir)")
    } else {
        log("All \(records.count) dives are downloaded.")
    }

    if !listOnly && !noConvertPrompt && promptYesNo("Convert this batch to XML?", defaultYes: true) {
        convertRawToXML(records: selected, outputDir: outputDir, xmlDir: xmlDir, overwrite: overwriteXML)
    }
    client.shutdownBluetoothMode()
} catch {
    log("\(error)")
    exit(1)
}
