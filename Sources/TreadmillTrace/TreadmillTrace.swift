import CoreBluetooth
import Darwin
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
    private var readRequests: Set<String> = []
    private var notifiedCharacteristics: Set<String> = []
    private var pendingNotifyEnables: Set<String> = []
    private var pendingServiceDiscoveries = 0
    private var setupComplete = false
    private var scanStarted = false
    private var discoveryTimeout: Timer?
    private var signalSources: [DispatchSourceSignal] = []

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
        setupSignalHandlers()
        central = CBCentralManager(delegate: self, queue: nil)
        RunLoop.main.run()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.write("central.state", ["state": describe(central.state)])

        switch central.state {
        case .poweredOn:
            startScanIfNeeded()
        case .unknown, .resetting:
            return
        case .poweredOff, .unauthorized, .unsupported:
            print("Bluetooth is not available: \(describe(central.state))")
            logger.write("session.end", ["reason": "bluetooth_unavailable", "state": describe(central.state)])
            finish(1)
        @unknown default:
            print("Bluetooth is in an unsupported state: \(describe(central.state))")
            logger.write("session.end", ["reason": "bluetooth_unknown_state", "state": describe(central.state)])
            finish(1)
        }
    }

    private func startScanIfNeeded() {
        guard !scanStarted else { return }
        scanStarted = true
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
        startDiscoveryTimeout(reason: "discovery_timeout")
        logger.write("ble.connect", [
            "id": peripheral.identifier.uuidString,
            "name": peripheral.name ?? "Unknown",
            "maximumWriteWithResponse": peripheral.maximumWriteValueLength(for: .withResponse),
            "maximumWriteWithoutResponse": peripheral.maximumWriteValueLength(for: .withoutResponse),
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
        finish(1)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.write("ble.disconnect", [
            "id": peripheral.identifier.uuidString,
            "name": peripheral.name ?? "Unknown",
            "error": error?.localizedDescription ?? "none",
        ])
        print("Disconnected. Log saved to \(logger.path)")
        finish(0)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            logger.write("ble.services_error", ["error": error.localizedDescription])
            print("Service discovery failed: \(error.localizedDescription)")
            finish(1)
        }

        let services = peripheral.services ?? []
        pendingServiceDiscoveries = services.count
        logger.write("ble.services", [
            "count": services.count,
            "uuids": services.map { $0.uuid.uuidString },
        ])

        guard !services.isEmpty else {
            logger.write("session.end", ["reason": "no_services"])
            print("No services found on selected device.")
            finish(1)
        }

        for service in services {
            selectedServices.insert(service.uuid)
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        defer {
            pendingServiceDiscoveries -= 1
            checkSetupComplete()
        }

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

        for characteristic in characteristics {
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                pendingNotifyEnables.insert(characteristicKey(characteristic))
                peripheral.setNotifyValue(true, for: characteristic)
            }

            if characteristic.properties.contains(.read) {
                readRequests.insert(characteristicKey(characteristic))
                peripheral.readValue(for: characteristic)
            }
        }

    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let key = characteristicKey(characteristic)
        pendingNotifyEnables.remove(key)
        if characteristic.isNotifying {
            notifiedCharacteristics.insert(key)
        }

        logger.write("ble.notify_state", [
            "service": characteristic.service?.uuid.uuidString ?? "unknown",
            "characteristic": characteristic.uuid.uuidString,
            "isNotifying": characteristic.isNotifying,
            "error": error?.localizedDescription ?? "none",
        ])
        checkSetupComplete()
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
        let key = characteristicKey(characteristic)
        let wasReadRequest = readRequests.remove(key) != nil
        logger.write("ble.rx", [
            "service": characteristic.service?.uuid.uuidString ?? "unknown",
            "characteristic": characteristic.uuid.uuidString,
            "source": wasReadRequest ? "read" : "notify",
            "length": data.count,
            "hex": data.hexString,
            "base64": data.base64EncodedString(),
            "ftms": parseFTMSIfKnown(characteristic: characteristic, data: data),
        ])
    }

    private func characteristicKey(_ characteristic: CBCharacteristic) -> String {
        "\(characteristic.service?.uuid.uuidString ?? "unknown")/\(characteristic.uuid.uuidString)"
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
            finish(1)
        }

        print("Discovered devices:")
        for (index, device) in devices.enumerated() {
            let marker = device.candidate ? "*" : " "
            let services = device.services.map(\.uuidString).joined(separator: ",")
            print("\(index + 1).\(marker) \(device.name) RSSI=\(device.rssi) services=[\(services)]")
        }
        print("")
        print("Choose the Vitalwalk/treadmill number to connect, or press return for the first candidate:")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                let selectedIndex: Int
                if input.isEmpty {
                    selectedIndex = devices.firstIndex(where: \.candidate) ?? 0
                } else if let number = Int(input), devices.indices.contains(number - 1) {
                    selectedIndex = number - 1
                } else {
                    print("Invalid selection.")
                    self.logger.write("session.end", ["reason": "invalid_selection"])
                    self.finish(1)
                }

                let device = devices[selectedIndex]
                self.selected = device.peripheral
                self.logger.write("ble.selection", [
                    "id": device.peripheral.identifier.uuidString,
                    "name": device.name,
                    "rssi": device.rssi,
                    "candidate": device.candidate,
                ])
                print("Connecting to \(device.name)...")
                self.startDiscoveryTimeout(reason: "connect_timeout")
                self.central.connect(device.peripheral, options: nil)
            }
        }
    }

    private func checkSetupComplete() {
        guard !setupComplete,
              pendingServiceDiscoveries == 0,
              pendingNotifyEnables.isEmpty
        else { return }

        setupComplete = true
        printCaptureInstructions()
    }

    private func setupSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { exit(1) }
                print("\nInterrupted. Closing log...")
                self.logger.write("session.end", ["reason": "interrupted", "signal": signalNumber])
                self.finish(1)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func startDiscoveryTimeout(reason: String) {
        discoveryTimeout?.invalidate()
        discoveryTimeout = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.logger.write("session.end", ["reason": reason])
            print("Timed out while preparing capture: \(reason)")
            self.finish(1)
        }
    }

    private func finish(_ code: Int32) -> Never {
        discoveryTimeout?.invalidate()
        fflush(stdout)
        fflush(stderr)
        logger.finish()
        exit(code)
    }

    private func printCaptureInstructions() {
        discoveryTimeout?.invalidate()
        let hasTreadmillData = notifiedCharacteristics.contains { $0.hasSuffix("/2ACD") }
        guard hasTreadmillData || !notifiedCharacteristics.isEmpty else {
            logger.write("session.end", ["reason": "no_notifications_enabled"])
            print("No notifications could be enabled on the selected device.")
            finish(1)
        }

        if !hasTreadmillData {
            print("Warning: FTMS Treadmill Data notifications were not enabled. The log may not include live treadmill stats.")
            logger.write("capture.warning", ["reason": "missing_2ACD_notification"])
        }

        print("")
        print("Capture is running. Stand off the belt for safety.")
        print("The tool will ask you to press return at each step so the log has markers.")
        print("")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let steps: [(String, [String: Any])] = [
                ("Leave the treadmill connected and idle for 15 seconds, then press return.", ["phase": "idle"]),
                ("Start using the treadmill remote or panel. Wait 15 seconds, then press return.", ["phase": "remote_start"]),
                ("Set speed to exactly 1.0 using the remote or panel. Wait 15 seconds, then press return.", ["phase": "speed", "speed": 1.0]),
                ("Set speed to exactly 2.0 using the remote or panel. Wait 15 seconds, then press return.", ["phase": "speed", "speed": 2.0]),
                ("Set speed to exactly 3.0 using the remote or panel. Wait 15 seconds, then press return.", ["phase": "speed", "speed": 3.0]),
                ("If safe, set speed to exactly 4.0 using the remote or panel. Otherwise leave it unchanged. Wait 15 seconds, then press return.", ["phase": "speed", "speed": 4.0, "optional": true]),
                ("If incline is supported, set incline to 1. Wait 15 seconds, then press return. Otherwise just press return.", ["phase": "incline", "incline": 1, "optional": true]),
                ("If incline is supported, set incline to 2. Wait 15 seconds, then press return. Otherwise just press return.", ["phase": "incline", "incline": 2, "optional": true]),
                ("If incline is supported, set incline back to 0. Wait 15 seconds, then press return. Otherwise just press return.", ["phase": "incline", "incline": 0, "optional": true]),
                ("Stop the treadmill using the remote or panel. Wait 10 seconds, then press return to finish.", ["phase": "remote_stop"]),
            ]

            for (instruction, fields) in steps {
                print(instruction)
                self?.logger.write("user.marker.prompt", fields.merging(["instruction": instruction]) { current, _ in current })
                _ = readLine()
                self?.logger.write("user.marker.done", fields)
            }

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
        case CBUUID(string: "2ACC"):
            return parseFitnessMachineFeature(data)
        case CBUUID(string: "2AD4"):
            return parseSupportedSpeedRange(data)
        case CBUUID(string: "2AD5"):
            return parseSupportedInclinationRange(data)
        case CBUUID(string: "2A24"), CBUUID(string: "2A25"), CBUUID(string: "2A26"), CBUUID(string: "2A27"), CBUUID(string: "2A28"), CBUUID(string: "2A29"):
            return ["utf8": String(data: data, encoding: .utf8) ?? "invalid_utf8"]
        default:
            return [:]
        }
    }

    private func parseFitnessMachineFeature(_ data: Data) -> [String: Any] {
        guard data.count >= 8 else { return ["error": "short_packet"] }
        let fitnessMachineFeatures = UInt32(data[0]) |
            (UInt32(data[1]) << 8) |
            (UInt32(data[2]) << 16) |
            (UInt32(data[3]) << 24)
        let targetSettingFeatures = UInt32(data[4]) |
            (UInt32(data[5]) << 8) |
            (UInt32(data[6]) << 16) |
            (UInt32(data[7]) << 24)
        return [
            "fitnessMachineFeatures": String(format: "0x%08X", fitnessMachineFeatures),
            "targetSettingFeatures": String(format: "0x%08X", targetSettingFeatures),
        ]
    }

    private func parseSupportedSpeedRange(_ data: Data) -> [String: Any] {
        guard data.count >= 6 else { return ["error": "short_packet"] }
        let minimum = UInt16(data[0]) | (UInt16(data[1]) << 8)
        let maximum = UInt16(data[2]) | (UInt16(data[3]) << 8)
        let increment = UInt16(data[4]) | (UInt16(data[5]) << 8)
        return [
            "minimumRaw": minimum,
            "maximumRaw": maximum,
            "incrementRaw": increment,
            "minimumKmh": Double(minimum) / 100.0,
            "maximumKmh": Double(maximum) / 100.0,
            "incrementKmh": Double(increment) / 100.0,
        ]
    }

    private func parseSupportedInclinationRange(_ data: Data) -> [String: Any] {
        guard data.count >= 6 else { return ["error": "short_packet"] }
        let minimum = Int16(bitPattern: UInt16(data[0]) | (UInt16(data[1]) << 8))
        let maximum = Int16(bitPattern: UInt16(data[2]) | (UInt16(data[3]) << 8))
        let increment = UInt16(data[4]) | (UInt16(data[5]) << 8)
        return [
            "minimumRaw": minimum,
            "maximumRaw": maximum,
            "incrementRaw": increment,
            "minimumPercent": Double(minimum) / 10.0,
            "maximumPercent": Double(maximum) / 10.0,
            "incrementPercent": Double(increment) / 10.0,
        ]
    }

    private func parseTreadmillData(_ data: Data) -> [String: Any] {
        guard data.count >= 4 else { return ["error": "short_packet"] }

        let flags = UInt16(data[0]) | (UInt16(data[1]) << 8)
        var offset = 2
        let moreData = flags & 0x0001 != 0

        var result: [String: Any] = [
            "flags": String(format: "0x%04X", flags),
            "moreData": moreData,
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

        if let speedRaw = uint16() {
            result["speedRaw"] = speedRaw
            result["speedKmh"] = Double(speedRaw) / 100.0
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
        if has(0x0020), let pace = uint16() {
            result["instantaneousPaceRaw"] = pace
        }
        if has(0x0040), let pace = uint16() {
            result["averagePaceRaw"] = pace
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
    private let queue = DispatchQueue(label: "fi.zendit.TreadmillTrace.logger")
    private let isoFormatter = ISO8601DateFormatter()

    init(outputPath: String?) {
        if let outputPath {
            path = NSString(string: outputPath).expandingTildeInPath
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            path = FileManager.default.currentDirectoryPath + "/treadmill-trace-\(formatter.string(from: Date())).jsonl"
        }

        FileManager.default.createFile(atPath: path, contents: Data())
        guard let handle = FileHandle(forWritingAtPath: path) else {
            fputs("Failed to create log file at \(path)\n", stderr)
            exit(1)
        }
        self.handle = handle
    }

    func write(_ event: String, _ fields: [String: Any]) {
        var object = fields
        object["event"] = event
        object["timestamp"] = isoFormatter.string(from: Date())
        object["elapsedSeconds"] = Date().timeIntervalSince(start)

        queue.async { [handle] in
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            else { return }
            try? handle.write(contentsOf: data)
            try? handle.write(contentsOf: Data("\n".utf8))
        }
    }

    func finish() {
        queue.sync {
            try? handle.synchronize()
            try? handle.close()
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
            var converted: [String: Any] = [:]
            for (uuid, data) in serviceData {
                converted[uuid.uuidString] = ["hex": data.hexString, "base64": data.base64EncodedString()]
            }
            result[key] = converted
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
