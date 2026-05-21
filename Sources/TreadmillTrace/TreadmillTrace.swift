import CoreBluetooth
import Foundation

@main
struct TreadmillTrace {
    static func main() {
        let arguments = Arguments.parse(CommandLine.arguments.dropFirst())
        let logger = TraceLogger(outputPath: arguments.outputPath)
        let capture = BLECapture(logger: logger, scanSeconds: arguments.scanSeconds)
        capture.run()
    }
}

struct Arguments {
    var outputPath: String?
    var scanSeconds: TimeInterval = 12

    static func parse(_ args: ArraySlice<String>) -> Arguments {
        var result = Arguments()
        var iterator = args.makeIterator()

        while let arg = iterator.next() {
            switch arg {
            case "--output", "-o":
                result.outputPath = iterator.next()
            case "--scan-seconds":
                if let value = iterator.next(), let seconds = TimeInterval(value) {
                    result.scanSeconds = seconds
                }
            case "--help", "-h":
                print("""
                TreadmillTrace captures raw BLE treadmill data on macOS.

                Usage:
                  treadmill-trace [--output path] [--scan-seconds 12]

                The tool scans for nearby BLE devices, lets you choose one, connects,
                discovers services and characteristics, subscribes to notify/indicate
                characteristics, and writes JSON Lines trace events.
                """)
                exit(0)
            default:
                break
            }
        }

        return result
    }
}

final class BLECapture: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let logger: TraceLogger
    private let scanSeconds: TimeInterval
    private var central: CBCentralManager!
    private var discovered: [UUID: DiscoveredPeripheral] = [:]
    private var selected: CBPeripheral?
    private var selectedServices: Set<CBUUID> = []
    private var pendingServiceDiscoveries = 0
    private var pendingCharacteristicDiscoveries = 0

    init(logger: TraceLogger, scanSeconds: TimeInterval) {
        self.logger = logger
        self.scanSeconds = scanSeconds
        super.init()
    }

    func run() {
        print("TreadmillTrace")
        print("Log: \(logger.path)")
        print("Scanning for \(Int(scanSeconds)) seconds...")
        print("")
        logger.write("session.start", [
            "tool": "TreadmillTrace",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ])
        central = CBCentralManager(delegate: self, queue: nil)
        RunLoop.main.run()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.write("central.state", ["state": describe(central.state)])

        guard central.state == .poweredOn else {
            print("Bluetooth is not powered on: \(describe(central.state))")
            return
        }

        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        Timer.scheduledTimer(withTimeInterval: scanSeconds, repeats: false) { [weak self] _ in
            self?.finishScan()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let candidate = isLikelyTreadmill(name: name, services: services, serviceData: serviceData)

        discovered[peripheral.identifier] = DiscoveredPeripheral(
            peripheral: peripheral,
            name: name,
            rssi: RSSI.intValue,
            services: services,
            candidate: candidate
        )

        logger.write("ble.advertisement", [
            "id": peripheral.identifier.uuidString,
            "name": name,
            "rssi": RSSI.intValue,
            "candidate": candidate,
            "advertisementData": describeAdvertisement(advertisementData),
        ])
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to \(peripheral.name ?? "device"). Discovering services...")
        logger.write("ble.connect", [
            "id": peripheral.identifier.uuidString,
            "name": peripheral.name ?? "Unknown",
        ])
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.write("ble.connect_failed", [
            "id": peripheral.identifier.uuidString,
            "name": peripheral.name ?? "Unknown",
            "error": error?.localizedDescription ?? "none",
        ])
        print("Failed to connect: \(error?.localizedDescription ?? "unknown error")")
        exit(1)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.write("ble.disconnect", [
            "id": peripheral.identifier.uuidString,
            "name": peripheral.name ?? "Unknown",
            "error": error?.localizedDescription ?? "none",
        ])
        print("Disconnected. Log saved to \(logger.path)")
        exit(0)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            logger.write("ble.services_error", ["error": error.localizedDescription])
            print("Service discovery failed: \(error.localizedDescription)")
            exit(1)
        }

        let services = peripheral.services ?? []
        pendingServiceDiscoveries = services.count
        logger.write("ble.services", [
            "count": services.count,
            "uuids": services.map { $0.uuid.uuidString },
        ])

        for service in services {
            selectedServices.insert(service.uuid)
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            logger.write("ble.characteristics_error", [
                "service": service.uuid.uuidString,
                "error": error.localizedDescription,
            ])
            print("Characteristic discovery failed for \(service.uuid.uuidString): \(error.localizedDescription)")
            return
        }

        let characteristics = service.characteristics ?? []
        logger.write("ble.characteristics", [
            "service": service.uuid.uuidString,
            "count": characteristics.count,
            "characteristics": characteristics.map { characteristic in
                [
                    "uuid": characteristic.uuid.uuidString,
                    "properties": describe(characteristic.properties),
                ]
            },
        ])

        for characteristic in characteristics where characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
            pendingCharacteristicDiscoveries += 1
            peripheral.setNotifyValue(true, for: characteristic)
        }

        pendingServiceDiscoveries -= 1
        if pendingServiceDiscoveries == 0 {
            printCaptureInstructions()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        logger.write("ble.notify_state", [
            "service": characteristic.service?.uuid.uuidString ?? "unknown",
            "characteristic": characteristic.uuid.uuidString,
            "isNotifying": characteristic.isNotifying,
            "error": error?.localizedDescription ?? "none",
        ])
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logger.write("ble.rx_error", [
                "service": characteristic.service?.uuid.uuidString ?? "unknown",
                "characteristic": characteristic.uuid.uuidString,
                "error": error.localizedDescription,
            ])
            return
        }

        guard let data = characteristic.value else { return }
        logger.write("ble.rx", [
            "service": characteristic.service?.uuid.uuidString ?? "unknown",
            "characteristic": characteristic.uuid.uuidString,
            "length": data.count,
            "hex": data.hexString,
            "base64": data.base64EncodedString(),
            "ftms": parseFTMSIfKnown(characteristic: characteristic, data: data),
        ])
    }

    private func finishScan() {
        central.stopScan()

        let devices = discovered.values.sorted { lhs, rhs in
            if lhs.candidate != rhs.candidate { return lhs.candidate && !rhs.candidate }
            return lhs.rssi > rhs.rssi
        }

        guard !devices.isEmpty else {
            print("No BLE devices found.")
            logger.write("session.end", ["reason": "no_devices"])
            exit(1)
        }

        print("Discovered devices:")
        for (index, device) in devices.enumerated() {
            let marker = device.candidate ? "*" : " "
            let services = device.services.map(\.uuidString).joined(separator: ",")
            print("\(index + 1).\(marker) \(device.name) RSSI=\(device.rssi) services=[\(services)]")
        }
        print("")
        print("Choose the Vitalwalk/treadmill number to connect, or press return for the first candidate:")

        let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedIndex: Int
        if input.isEmpty {
            selectedIndex = devices.firstIndex(where: \.candidate) ?? 0
        } else if let number = Int(input), devices.indices.contains(number - 1) {
            selectedIndex = number - 1
        } else {
            print("Invalid selection.")
            exit(1)
        }

        let device = devices[selectedIndex]
        selected = device.peripheral
        logger.write("ble.selection", [
            "id": device.peripheral.identifier.uuidString,
            "name": device.name,
            "rssi": device.rssi,
            "candidate": device.candidate,
        ])
        print("Connecting to \(device.name)...")
        central.connect(device.peripheral, options: nil)
    }

    private func printCaptureInstructions() {
        print("")
        print("Capture is running. Stand off the belt for safety.")
        print("Suggested script:")
        print("1. Leave treadmill idle for 15 seconds.")
        print("2. Start using the treadmill remote or panel, then wait 15 seconds.")
        print("3. Set known speeds from the remote or panel, waiting 15 seconds each.")
        print("4. Try incline levels if supported, waiting 15 seconds each.")
        print("5. Stop the treadmill from the remote or panel.")
        print("6. Press return here to disconnect and finish the log.")
        print("")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = readLine()
            DispatchQueue.main.async {
                guard let self, let selected = self.selected else { return }
                self.logger.write("user.finished_script", [:])
                self.central.cancelPeripheralConnection(selected)
            }
        }
    }

    private func isLikelyTreadmill(name: String, services: [CBUUID], serviceData: [CBUUID: Data]) -> Bool {
        let lowerName = name.lowercased()
        let ftms = CBUUID(string: "1826")
        return services.contains(ftms) || serviceData[ftms] != nil || lowerName.contains("tread") || lowerName.contains("walk") || lowerName.contains("vital")
    }

    private func parseFTMSIfKnown(characteristic: CBCharacteristic, data: Data) -> [String: Any] {
        switch characteristic.uuid {
        case CBUUID(string: "2ACD"):
            return parseTreadmillData(data)
        case CBUUID(string: "2ADA"):
            return ["machineStatusOpcode": data.first.map { String(format: "0x%02X", $0) } ?? "none"]
        case CBUUID(string: "2AD9"):
            return [
                "controlPointResponse": data.count >= 3 && data[0] == 0x80,
                "requestOpcode": data.count >= 2 ? String(format: "0x%02X", data[1]) : "none",
                "resultCode": data.count >= 3 ? String(format: "0x%02X", data[2]) : "none",
            ]
        default:
            return [:]
        }
    }

    private func parseTreadmillData(_ data: Data) -> [String: Any] {
        guard data.count >= 4 else { return ["error": "short_packet"] }

        let flags = UInt16(data[0]) | (UInt16(data[1]) << 8)
        var offset = 2
        let speedRaw = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        offset += 2

        var result: [String: Any] = [
            "flags": String(format: "0x%04X", flags),
            "speedRaw": speedRaw,
            "speedKmh": Double(speedRaw) / 100.0,
        ]

        func has(_ bit: UInt16) -> Bool { flags & bit != 0 }
        func uint16() -> UInt16? {
            guard offset + 2 <= data.count else { return nil }
            defer { offset += 2 }
            return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
        func sint16() -> Int16? {
            guard let value = uint16() else { return nil }
            return Int16(bitPattern: value)
        }
        func uint24() -> Int? {
            guard offset + 3 <= data.count else { return nil }
            defer { offset += 3 }
            return Int(data[offset]) | (Int(data[offset + 1]) << 8) | (Int(data[offset + 2]) << 16)
        }

        if has(0x0002), let averageSpeed = uint16() {
            result["averageSpeedKmh"] = Double(averageSpeed) / 100.0
        }
        if has(0x0004), let totalDistance = uint24() {
            result["totalDistanceMeters"] = totalDistance
        }
        if has(0x0008) {
            if let inclination = sint16(), let rampAngle = sint16() {
                result["inclinationPercent"] = Double(inclination) / 10.0
                result["rampAngleDegrees"] = Double(rampAngle) / 10.0
            }
        }
        if has(0x0010) {
            if let positive = uint16(), let negative = uint16() {
                result["positiveElevationGainMeters"] = positive
                result["negativeElevationGainMeters"] = negative
            }
        }
        if has(0x0020), offset + 1 <= data.count {
            result["instantaneousPaceRaw"] = data[offset]
            offset += 1
        }
        if has(0x0040), offset + 1 <= data.count {
            result["averagePaceRaw"] = data[offset]
            offset += 1
        }
        if has(0x0080), offset + 5 <= data.count {
            result["totalEnergyCalories"] = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            result["energyPerHourCalories"] = UInt16(data[offset + 2]) | (UInt16(data[offset + 3]) << 8)
            result["energyPerMinuteCalories"] = data[offset + 4]
            offset += 5
        }
        if has(0x0100), offset + 1 <= data.count {
            result["heartRateBpm"] = data[offset]
            offset += 1
        }
        if has(0x0200), offset + 1 <= data.count {
            result["metabolicEquivalent"] = Double(data[offset]) / 10.0
            offset += 1
        }
        if has(0x0400), let elapsedTime = uint16() {
            result["elapsedTimeSeconds"] = elapsedTime
        }
        if has(0x0800), let remainingTime = uint16() {
            result["remainingTimeSeconds"] = remainingTime
        }
        if has(0x1000) {
            if let force = sint16(), let power = sint16() {
                result["forceOnBeltNewtons"] = force
                result["powerOutputWatts"] = power
            }
        }
        if has(0x2000), offset + 2 <= data.count {
            result["vendorFieldRaw16"] = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            offset += 2
        }

        result["consumedBytes"] = offset
        result["trailingBytes"] = max(0, data.count - offset)
        if offset < data.count {
            result["trailingHex"] = Data(data[offset...]).hexString
        }
        return result
    }
}

struct DiscoveredPeripheral {
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    let services: [CBUUID]
    let candidate: Bool
}

final class TraceLogger {
    let path: String
    private let handle: FileHandle
    private let start = Date()
    private let encoder = JSONSerialization.self
    private let queue = DispatchQueue(label: "fi.zendit.TreadmillTrace.logger")

    init(outputPath: String?) {
        if let outputPath {
            path = NSString(string: outputPath).expandingTildeInPath
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            path = FileManager.default.currentDirectoryPath + "/treadmill-trace-\(formatter.string(from: Date())).jsonl"
        }

        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            fputs("Failed to create log file at \(path)\n", stderr)
            exit(1)
        }
        self.handle = handle
    }

    func write(_ event: String, _ fields: [String: Any]) {
        var object = fields
        object["event"] = event
        object["timestamp"] = ISO8601DateFormatter().string(from: Date())
        object["elapsedSeconds"] = Date().timeIntervalSince(start)

        queue.async { [handle] in
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            else { return }
            handle.write(data)
            handle.write(Data("\n".utf8))
        }
    }
}

func describe(_ state: CBManagerState) -> String {
    switch state {
    case .unknown: "unknown"
    case .resetting: "resetting"
    case .unsupported: "unsupported"
    case .unauthorized: "unauthorized"
    case .poweredOff: "poweredOff"
    case .poweredOn: "poweredOn"
    @unknown default: "future"
    }
}

func describe(_ properties: CBCharacteristicProperties) -> [String] {
    var result: [String] = []
    if properties.contains(.broadcast) { result.append("broadcast") }
    if properties.contains(.read) { result.append("read") }
    if properties.contains(.writeWithoutResponse) { result.append("writeWithoutResponse") }
    if properties.contains(.write) { result.append("write") }
    if properties.contains(.notify) { result.append("notify") }
    if properties.contains(.indicate) { result.append("indicate") }
    if properties.contains(.authenticatedSignedWrites) { result.append("authenticatedSignedWrites") }
    if properties.contains(.extendedProperties) { result.append("extendedProperties") }
    if properties.contains(.notifyEncryptionRequired) { result.append("notifyEncryptionRequired") }
    if properties.contains(.indicateEncryptionRequired) { result.append("indicateEncryptionRequired") }
    return result
}

func describeAdvertisement(_ advertisementData: [String: Any]) -> [String: Any] {
    var result: [String: Any] = [:]
    for (key, value) in advertisementData {
        switch value {
        case let data as Data:
            result[key] = ["hex": data.hexString, "base64": data.base64EncodedString()]
        case let uuids as [CBUUID]:
            result[key] = uuids.map(\.uuidString)
        case let serviceData as [CBUUID: Data]:
            result[key] = serviceData.mapValues { ["hex": $0.hexString, "base64": $0.base64EncodedString()] }
        default:
            result[key] = String(describing: value)
        }
    }
    return result
}

extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
