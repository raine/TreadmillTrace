import CoreBluetooth
import Darwin
import Foundation

@main
struct TreadmillTrace {
    static func main() {
        let arguments = Arguments.parse(CommandLine.arguments.dropFirst())
        let logger = TraceLogger(outputPath: arguments.outputPath)
        let capture = BLECapture(logger: logger, scanSeconds: arguments.scanSeconds, mode: arguments.mode)
        capture.run()
    }
}

struct Arguments {
    var outputPath: String?
    var scanSeconds: TimeInterval = 12
    var r3ProbeDuration: TimeInterval = 30
    var r3ControlTests = false
    var r3ControlTestsConfirmed = false
    var mode: CaptureMode = .guidedCapture

    static func parse(_ args: ArraySlice<String>) -> Arguments {
        var result = Arguments()
        var iterator = args.makeIterator()

        while let arg = iterator.next() {
            switch arg {
            case "r3-probe":
                result.mode = .r3Probe(duration: result.r3ProbeDuration, controlTests: result.r3ControlTests)
            case "--duration":
                if let value = iterator.next(), let seconds = TimeInterval(value) {
                    result.r3ProbeDuration = seconds
                    result.mode = .r3Probe(duration: seconds, controlTests: result.r3ControlTests)
                }
            case "--control-tests":
                result.r3ControlTests = true
                result.mode = .r3Probe(duration: result.r3ProbeDuration, controlTests: true)
            case "--i-understand-this-may-move-the-belt":
                result.r3ControlTestsConfirmed = true
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
                  treadmill-trace r3-probe [--duration 30] [--output path] [--scan-seconds 12]
                  treadmill-trace r3-probe --control-tests --i-understand-this-may-move-the-belt

                The default capture asks you to drive the treadmill with the remote or panel.
                r3-probe runs a safe WalkingPad R3 diagnostic. It discovers services,
                subscribes to telemetry, sends only FTMS Request Control, and prints a
                copy-pasteable report. It does not start the belt or change speed unless
                the explicit --control-tests confirmation flag is also provided.
                """)
                exit(0)
            default:
                break
            }
        }

        if result.r3ControlTests, !result.r3ControlTestsConfirmed {
            fputs("--control-tests requires --i-understand-this-may-move-the-belt\n", stderr)
            exit(2)
        }

        return result
    }
}

enum CaptureMode {
    case guidedCapture
    case r3Probe(duration: TimeInterval, controlTests: Bool)
}

final class BLECapture: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let logger: TraceLogger
    private let scanSeconds: TimeInterval
    private let mode: CaptureMode
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
    private var displayUnit = "unknown"
    private var speedRange: SpeedRange?
    private var inclineRange: InclineRange?
    private var currentPhase: CapturePhase?
    private var phaseStats: [String: PhaseStats] = [:]
    private var totalTreadmillDataPackets = 0
    private var r3ProbeState = R3ProbeState()
    private var sawNonzeroSpeed = false
    private var sawDistanceIncrease = false
    private var sawElapsedTimeIncrease = false
    private var sawStatusTransition = false
    private var lastDistanceMeters: Int?
    private var lastElapsedTimeSeconds: UInt16?
    private var lastMachineStatusOpcode: String?
    private let phaseDuration: TimeInterval = 15
    private let stopPhaseDuration: TimeInterval = 10
    private let minimumPhaseSamples = 3

    private struct SpeedRange {
        let minimumKmh: Double
        let maximumKmh: Double
        let incrementKmh: Double

        func contains(_ speed: Double) -> Bool {
            speed >= minimumKmh && speed <= maximumKmh
        }
    }

    private struct InclineRange {
        let minimumPercent: Double
        let maximumPercent: Double
        let incrementPercent: Double

        var isSupported: Bool {
            minimumPercent != 0 || maximumPercent != 0 || incrementPercent != 0
        }
    }

    private struct CapturePhase {
        let id: String
        let fields: [String: Any]
        let startedAt: Date
    }

    private struct PhaseStats {
        var treadmillDataPackets = 0
        var nonzeroSpeedSamples = 0
        var firstSpeedKmh: Double?
        var lastSpeedKmh: Double?
        var firstDistanceMeters: Int?
        var lastDistanceMeters: Int?
        var firstElapsedTimeSeconds: UInt16?
        var lastElapsedTimeSeconds: UInt16?
        var machineStatusOpcodes: Set<String> = []
    }

    private struct CaptureStep {
        let instruction: String
        let fields: [String: Any]
        let duration: TimeInterval
    }

    private struct R3ProbeState {
        var discoveredServices: Set<String> = []
        var discoveredCharacteristics: [String: [String]] = [:]
        var notifyingCharacteristics: Set<String> = []
        var readableCharacteristics: Set<String> = []
        var readValues: [String: String] = [:]
        var treadmillDataPackets = 0
        var treadmillSamples: [[String: Any]] = []
        var machineStatusPackets = 0
        var trainingStatusPackets = 0
        var controlPointResponses: [[String: Any]] = []
        var controlPointWriteError: String?
        var controlPointWriteCompleted = false
        var controlPointRequestSent = false
        var supplementCommandsSent: [[String: String]] = []
        var supplementWriteResults: [[String: String]] = []
        var supplementNotifications: [[String: String]] = []
        var vendorServices: Set<String> = []
        var parsedReadValues: [String: [String: Any]] = [:]
    }

    init(logger: TraceLogger, scanSeconds: TimeInterval, mode: CaptureMode) {
        self.logger = logger
        self.scanSeconds = scanSeconds
        self.mode = mode
        super.init()
    }

    func run() {
        print("TreadmillTrace")
        if case .r3Probe = mode {
            print("Mode: R3 safe diagnostic probe")
        }
        print("Log: \(logger.path)")
        print("Scanning for \(Int(scanSeconds)) seconds...")
        print("")
        logger.write("session.start", [
            "tool": "TreadmillTrace",
            "mode": modeName,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ])
        setupSignalHandlers()
        central = CBCentralManager(delegate: self, queue: nil)
        RunLoop.main.run()
    }

    private var modeName: String {
        switch mode {
        case .guidedCapture: "guidedCapture"
        case let .r3Probe(_, controlTests): controlTests ? "r3ProbeControlTests" : "r3Probe"
        }
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
        r3ProbeState.discoveredServices.insert(service.uuid.uuidString)
        r3ProbeState.discoveredCharacteristics[service.uuid.uuidString] = characteristics.map { characteristic in
            "\(characteristic.uuid.uuidString): \(describe(characteristic.properties).joined(separator: ","))"
        }
        if isKnownR3SupplementService(service.uuid) {
            r3ProbeState.vendorServices.insert(service.uuid.uuidString)
        }
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
                let key = characteristicKey(characteristic)
                readRequests.insert(key)
                r3ProbeState.readableCharacteristics.insert(key)
                peripheral.readValue(for: characteristic)
            }
        }

    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let key = characteristicKey(characteristic)
        pendingNotifyEnables.remove(key)
        if characteristic.isNotifying {
            notifiedCharacteristics.insert(key)
            r3ProbeState.notifyingCharacteristics.insert(key)
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
        let key = characteristicKey(characteristic)
        let wasReadRequest = readRequests.remove(key) != nil
        defer {
            if wasReadRequest {
                checkSetupComplete()
            }
        }

        if let error {
            logger.write("ble.rx_error", [
                "service": characteristic.service?.uuid.uuidString ?? "unknown",
                "characteristic": characteristic.uuid.uuidString,
                "source": wasReadRequest ? "read" : "notify",
                "error": error.localizedDescription,
            ])
            return
        }

        guard let data = characteristic.value else { return }
        let ftms = parseFTMSIfKnown(characteristic: characteristic, data: data)
        updateCaptureState(characteristic: characteristic, ftms: ftms)
        updateR3ProbeState(characteristic: characteristic, data: data, ftms: ftms, wasReadRequest: wasReadRequest)
        logger.write("ble.rx", [
            "service": characteristic.service?.uuid.uuidString ?? "unknown",
            "characteristic": characteristic.uuid.uuidString,
            "source": wasReadRequest ? "read" : "notify",
            "length": data.count,
            "hex": data.hexString,
            "base64": data.base64EncodedString(),
            "ftms": ftms,
        ])
    }

    func peripheral(_: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == CBUUID(string: "2AD9") {
            r3ProbeState.controlPointWriteCompleted = error == nil
            r3ProbeState.controlPointWriteError = error?.localizedDescription
            logger.write("r3_probe.control_point_write", [
                "service": characteristic.service?.uuid.uuidString ?? "unknown",
                "characteristic": characteristic.uuid.uuidString,
                "error": error?.localizedDescription ?? "none",
            ])
        } else if isKnownR3SupplementService(characteristic.service?.uuid) {
            let result = [
                "service": characteristic.service?.uuid.uuidString ?? "unknown",
                "characteristic": characteristic.uuid.uuidString,
                "error": error?.localizedDescription ?? "none",
            ]
            r3ProbeState.supplementWriteResults.append(result)
            logger.write("r3_probe.supplement_write", result)
        }
    }

    private func characteristicKey(_ characteristic: CBCharacteristic) -> String {
        "\(characteristic.service?.uuid.uuidString ?? "unknown")/\(characteristic.uuid.uuidString)"
    }

    private func updateR3ProbeState(characteristic: CBCharacteristic, data: Data, ftms: [String: Any], wasReadRequest: Bool) {
        let key = characteristicKey(characteristic)
        if wasReadRequest {
            r3ProbeState.readValues[key] = data.hexString
            if !ftms.isEmpty {
                r3ProbeState.parsedReadValues[key] = ftms
            } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                r3ProbeState.parsedReadValues[key] = ["utf8": text]
            }
        }

        switch characteristic.uuid {
        case CBUUID(string: "2ACD"):
            r3ProbeState.treadmillDataPackets += 1
            if r3ProbeState.treadmillSamples.count < 5 {
                r3ProbeState.treadmillSamples.append(ftms.merging(["hex": data.hexString]) { current, _ in current })
            }
        case CBUUID(string: "2AD3"):
            r3ProbeState.trainingStatusPackets += 1
        case CBUUID(string: "2ADA"):
            r3ProbeState.machineStatusPackets += 1
        case CBUUID(string: "2AD9"):
            r3ProbeState.controlPointResponses.append(ftms.merging(["hex": data.hexString]) { current, _ in current })
        default:
            if isKnownR3SupplementService(characteristic.service?.uuid), !wasReadRequest {
                r3ProbeState.supplementNotifications.append([
                    "service": characteristic.service?.uuid.uuidString ?? "unknown",
                    "characteristic": characteristic.uuid.uuidString,
                    "hex": data.hexString,
                ])
            }
        }
    }

    private func updateCaptureState(characteristic: CBCharacteristic, ftms: [String: Any]) {
        switch characteristic.uuid {
        case CBUUID(string: "2ACD"):
            updateTreadmillDataState(ftms)
        case CBUUID(string: "2ADA"):
            updateMachineStatusState(ftms)
        case CBUUID(string: "2AD4"):
            if let minimumKmh = ftms["minimumKmh"] as? Double,
               let maximumKmh = ftms["maximumKmh"] as? Double,
               let incrementKmh = ftms["incrementKmh"] as? Double
            {
                speedRange = SpeedRange(minimumKmh: minimumKmh, maximumKmh: maximumKmh, incrementKmh: incrementKmh)
            }
        case CBUUID(string: "2AD5"):
            if let minimumPercent = ftms["minimumPercent"] as? Double,
               let maximumPercent = ftms["maximumPercent"] as? Double,
               let incrementPercent = ftms["incrementPercent"] as? Double
            {
                inclineRange = InclineRange(
                    minimumPercent: minimumPercent,
                    maximumPercent: maximumPercent,
                    incrementPercent: incrementPercent
                )
            }
        default:
            break
        }
    }

    private func updateTreadmillDataState(_ ftms: [String: Any]) {
        totalTreadmillDataPackets += 1

        let speedKmh = ftms["speedKmh"] as? Double
        let distanceMeters = ftms["totalDistanceMeters"] as? Int
        let elapsedTimeSeconds = ftms["elapsedTimeSeconds"] as? UInt16

        if let speedKmh, speedKmh > 0 {
            sawNonzeroSpeed = true
        }
        if let distanceMeters {
            if let previous = lastDistanceMeters, distanceMeters > previous {
                sawDistanceIncrease = true
            }
            lastDistanceMeters = distanceMeters
        }
        if let elapsedTimeSeconds {
            if let previous = lastElapsedTimeSeconds, elapsedTimeSeconds > previous {
                sawElapsedTimeIncrease = true
            }
            lastElapsedTimeSeconds = elapsedTimeSeconds
        }

        guard let phase = currentPhase else { return }
        var stats = phaseStats[phase.id] ?? PhaseStats()
        stats.treadmillDataPackets += 1
        if let speedKmh {
            if stats.firstSpeedKmh == nil { stats.firstSpeedKmh = speedKmh }
            stats.lastSpeedKmh = speedKmh
            if speedKmh > 0 { stats.nonzeroSpeedSamples += 1 }
        }
        if let distanceMeters {
            if stats.firstDistanceMeters == nil { stats.firstDistanceMeters = distanceMeters }
            stats.lastDistanceMeters = distanceMeters
        }
        if let elapsedTimeSeconds {
            if stats.firstElapsedTimeSeconds == nil { stats.firstElapsedTimeSeconds = elapsedTimeSeconds }
            stats.lastElapsedTimeSeconds = elapsedTimeSeconds
        }
        phaseStats[phase.id] = stats
    }

    private func updateMachineStatusState(_ ftms: [String: Any]) {
        guard let opcode = ftms["machineStatusOpcode"] as? String else { return }
        if let previous = lastMachineStatusOpcode, previous != opcode {
            sawStatusTransition = true
        }
        lastMachineStatusOpcode = opcode

        guard let phase = currentPhase else { return }
        var stats = phaseStats[phase.id] ?? PhaseStats()
        stats.machineStatusOpcodes.insert(opcode)
        phaseStats[phase.id] = stats
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            if !self.readRequests.isEmpty {
                self.logger.write("capture.warning", [
                    "reason": "read_requests_incomplete",
                    "pendingReads": Array(self.readRequests).sorted(),
                ])
            }
            switch self.mode {
            case .guidedCapture:
                self.printCaptureInstructions()
            case let .r3Probe(duration, controlTests):
                self.startR3Probe(duration: duration, controlTests: controlTests)
            }
        }
    }

    private func startR3Probe(duration: TimeInterval, controlTests: Bool) {
        discoveryTimeout?.invalidate()
        print("")
        print("R3 probe is running for \(Int(duration)) seconds.")
        if controlTests {
            print("Control tests are enabled. Commands in this mode may start or stop the belt.")
            print("Stand off the treadmill and keep the remote or safety stop ready.")
        } else {
            print("This safe probe will not start the belt or change speed.")
            print("It sends only FTMS Request Control (00) to test whether the device responds.")
        }
        print("")

        if let selected, let controlPoint = findCharacteristic(uuid: CBUUID(string: "2AD9"), in: selected) {
            print("Sending FTMS Request Control to 2AD9...")
            r3ProbeState.controlPointRequestSent = true
            logger.write("r3_probe.control_point_request", [
                "service": controlPoint.service?.uuid.uuidString ?? "unknown",
                "characteristic": controlPoint.uuid.uuidString,
                "hex": "00",
            ])
            selected.writeValue(Data([0x00]), for: controlPoint, type: .withResponse)
        } else {
            print("No FTMS Control Point (2AD9) found.")
            logger.write("r3_probe.control_point_missing", [:])
        }

        sendSafeSupplementProbeCommands()

        if controlTests {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.runR3ControlTests()
            }
        } else {
            Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.finishR3Probe()
            }
        }
    }

    private func finishR3Probe() {
        printR3ProbeReport()
        logger.write("r3_probe.summary", r3ProbeSummary())
        if let selected {
            central.cancelPeripheralConnection(selected)
        } else {
            finish(0)
        }
    }

    private func findCharacteristic(uuid: CBUUID, in peripheral: CBPeripheral) -> CBCharacteristic? {
        peripheral.services?
            .flatMap { $0.characteristics ?? [] }
            .first { $0.uuid == uuid }
    }

    private func sendSafeSupplementProbeCommands() {
        guard let selected else { return }
        let commands: [(name: String, service: String, characteristic: String, hex: [UInt8])] = [
            (
                "supplement_init_0",
                "24E2521C-F63B-48ED-85BE-C5330A00FDF7",
                "24E2521C-F63B-48ED-85BE-C5330D00FDF7",
                [0x71, 0x00, 0x05, 0xFE, 0x2B, 0x5B, 0x31, 0x44, 0x6F]
            ),
            (
                "supplement_init_1",
                "24E2521C-F63B-48ED-85BE-C5330A00FDF7",
                "24E2521C-F63B-48ED-85BE-C5330D00FDF7",
                [0x71, 0x01, 0x08, 0x79, 0xE5, 0x92, 0x69, 0xAF, 0x30, 0x59, 0x00, 0x0B]
            ),
            (
                "supplement_query_all_properties",
                "24E2521C-F63B-48ED-85BE-C5330A00FDF7",
                "24E2521C-F63B-48ED-85BE-C5330D00FDF7",
                [0x72, 0x00, 0x00, 0x00, 0x72]
            ),
        ]

        for command in commands {
            guard let characteristic = findCharacteristic(
                serviceUUID: CBUUID(string: command.service),
                characteristicUUID: CBUUID(string: command.characteristic),
                in: selected
            ) else { continue }
            sendSupplementCommand(command.name, Data(command.hex), characteristic: characteristic)
        }
    }

    private func sendSupplementCommand(_ name: String, _ data: Data, characteristic: CBCharacteristic) {
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        let record = [
            "name": name,
            "service": characteristic.service?.uuid.uuidString ?? "unknown",
            "characteristic": characteristic.uuid.uuidString,
            "hex": data.hexString,
            "writeType": writeType == .withResponse ? "withResponse" : "withoutResponse",
        ]
        print("Sending safe supplement probe \(name): \(data.hexString)")
        r3ProbeState.supplementCommandsSent.append(record)
        logger.write("r3_probe.supplement_tx", record)
        selected?.writeValue(data, for: characteristic, type: writeType)
    }

    private func findCharacteristic(serviceUUID: CBUUID, characteristicUUID: CBUUID, in peripheral: CBPeripheral) -> CBCharacteristic? {
        peripheral.services?
            .first { $0.uuid == serviceUUID }?
            .characteristics?
            .first { $0.uuid == characteristicUUID }
    }

    private struct R3ControlCommand {
        let name: String
        let hex: [UInt8]
        let waitSeconds: TimeInterval
        let prompt: String
    }

    private func runR3ControlTests() {
        guard let selected, let controlPoint = findCharacteristic(uuid: CBUUID(string: "2AD9"), in: selected) else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                print("No FTMS Control Point (2AD9) found. Control tests cannot run.")
                self.finishR3Probe()
            }
            return
        }

        print("")
        print("CONTROL TESTS MAY MOVE THE BELT.")
        print("Confirm the treadmill is clear, you are standing off the belt, and you can stop it immediately.")
        print("Type RUN to continue, anything else to skip control tests:")
        guard (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "RUN" else {
            logger.write("r3_probe.control_tests_skipped", ["reason": "user_declined_runtime_confirmation"])
            DispatchQueue.main.async { [weak self] in self?.finishR3Probe() }
            return
        }

        let commands = [
            R3ControlCommand(
                name: "ftms_request_control",
                hex: [0x00],
                waitSeconds: 5,
                prompt: "Did anything visible happen after Request Control?"
            ),
            R3ControlCommand(
                name: "ftms_start_resume",
                hex: [0x07],
                waitSeconds: 6,
                prompt: "Did the belt start or did the treadmill display change?"
            ),
            R3ControlCommand(
                name: "ftms_set_speed_1_0_kmh",
                hex: [0x02, 0x64, 0x00],
                waitSeconds: 6,
                prompt: "Did speed change to 1.0 km/h or did the display acknowledge it?"
            ),
            R3ControlCommand(
                name: "ftms_pause",
                hex: [0x08, 0x02],
                waitSeconds: 6,
                prompt: "Did the treadmill pause or stop?"
            ),
            R3ControlCommand(
                name: "ftms_stop",
                hex: [0x08, 0x01],
                waitSeconds: 6,
                prompt: "Did the treadmill stop?"
            ),
        ]

        logger.write("r3_probe.control_tests_begin", ["commandCount": commands.count])
        for command in commands {
            print("")
            print("About to send \(command.name): \(Data(command.hex).hexString)")
            print("Press return to send, or type skip to skip this command:")
            if (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "skip" {
                logger.write("r3_probe.control_test_skipped", ["command": command.name])
                continue
            }

            DispatchQueue.main.sync {
                logger.write("r3_probe.control_test_tx", ["command": command.name, "hex": Data(command.hex).hexString])
                selected.writeValue(Data(command.hex), for: controlPoint, type: .withResponse)
            }
            Thread.sleep(forTimeInterval: command.waitSeconds)

            print(command.prompt)
            print("Type what happened, or press return for no visible change:")
            let observation = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            logger.write("r3_probe.control_test_observation", [
                "command": command.name,
                "hex": Data(command.hex).hexString,
                "observation": observation.isEmpty ? "no visible change" : observation,
            ])
        }
        logger.write("r3_probe.control_tests_end", [:])

        DispatchQueue.main.async { [weak self] in
            self?.finishR3Probe()
        }
    }

    private func printR3ProbeReport() {
        let summary = r3ProbeSummary()
        print("")
        print("===== TreadmillTrace R3 Probe Report =====")
        print("Log file: \(logger.path)")
        print("Device: \(selected?.name ?? "Unknown")")
        print("Device ID: \(selected?.identifier.uuidString ?? "unknown")")
        print("FTMS service present: \(yesNo(r3ProbeState.discoveredServices.contains("1826")))")
        print("FTMS data stream works: \(yesNo(r3ProbeState.treadmillDataPackets > 0)) (packets: \(r3ProbeState.treadmillDataPackets))")
        print("FTMS Request Control sent: \(yesNo(r3ProbeState.controlPointRequestSent))")
        print("FTMS Request Control write completed: \(yesNo(r3ProbeState.controlPointWriteCompleted))")
        print("FTMS Control Point responses: \(r3ProbeState.controlPointResponses.count)")
        if let error = r3ProbeState.controlPointWriteError {
            print("FTMS Control Point write error: \(error)")
        }
        if r3ProbeState.controlPointRequestSent, r3ProbeState.controlPointResponses.isEmpty {
            print("FTMS Control Point result: timeout or no indication observed")
        }
        print("Training Status packets: \(r3ProbeState.trainingStatusPackets)")
        print("Machine Status packets: \(r3ProbeState.machineStatusPackets)")
        print("Supplement/vendor services present: \(yesNo(!r3ProbeState.vendorServices.isEmpty))")
        if !r3ProbeState.vendorServices.isEmpty {
            print("Supplement/vendor services: \(Array(r3ProbeState.vendorServices).sorted().joined(separator: ", "))")
        }
        print("Supplement/vendor safe commands sent: \(r3ProbeState.supplementCommandsSent.count)")
        print("Supplement/vendor write responses: \(r3ProbeState.supplementWriteResults.count)")
        print("Supplement/vendor notifications observed: \(r3ProbeState.supplementNotifications.count)")
        print("")
        print("Read values:")
        for key in r3ProbeState.readValues.keys.sorted() {
            print("- \(key): \(r3ProbeState.readValues[key] ?? "")")
            if let parsed = r3ProbeState.parsedReadValues[key], !parsed.isEmpty {
                print("  decoded: \(formatJSONObject(parsed))")
            }
        }
        print("")
        if !r3ProbeState.treadmillSamples.isEmpty {
            print("Treadmill data samples:")
            for sample in r3ProbeState.treadmillSamples {
                print("- \(formatJSONObject(sample))")
            }
            print("")
        }
        if !r3ProbeState.controlPointResponses.isEmpty {
            print("FTMS Control Point responses:")
            for response in r3ProbeState.controlPointResponses {
                print("- \(formatJSONObject(response))")
            }
            print("")
        }
        if !r3ProbeState.supplementNotifications.isEmpty {
            print("Supplement/vendor notifications:")
            for notification in r3ProbeState.supplementNotifications.prefix(10) {
                print("- \(formatJSONObject(notification))")
            }
            print("")
        }
        print("Services and characteristics:")
        for service in r3ProbeState.discoveredServices.sorted() {
            print("- \(service)")
            for characteristic in r3ProbeState.discoveredCharacteristics[service] ?? [] {
                print("  - \(characteristic)")
            }
        }
        print("")
        print("Conclusion: \(summary["conclusion"] ?? "unknown")")
        print("==========================================")
        print("")
    }

    private func r3ProbeSummary() -> [String: Any] {
        let ftmsPresent = r3ProbeState.discoveredServices.contains("1826")
        let dataWorks = r3ProbeState.treadmillDataPackets > 0
        let controlResponded = !r3ProbeState.controlPointResponses.isEmpty
        let supplementPresent = !r3ProbeState.vendorServices.isEmpty
        let supplementNotified = !r3ProbeState.supplementNotifications.isEmpty
        let supplementCommandsSent = !r3ProbeState.supplementCommandsSent.isEmpty
        let supplementWritesCompleted = r3ProbeState.supplementWriteResults.contains { $0["error"] == "none" }
        let conclusion: String
        if dataWorks, r3ProbeState.controlPointRequestSent, !controlResponded {
            if supplementNotified {
                conclusion = "FTMS data works, standard FTMS control did not respond, and supplement notifications were observed. Prioritize the KingSmith supplement control path."
            } else if supplementCommandsSent, supplementWritesCompleted {
                conclusion = "FTMS data works and safe supplement commands were accepted, but no supplement notification was observed. Inspect the log for write type or command sequencing differences."
            } else {
                conclusion = supplementPresent
                    ? "FTMS data works, but standard FTMS control did not respond. Investigate supplement/vendor control path or use read-only fallback."
                    : "FTMS data works, but standard FTMS control did not respond. Treat this device as read-only unless another control path is found."
            }
        } else if dataWorks, controlResponded {
            conclusion = "FTMS data and standard FTMS control response both work. WalkingMate should inspect the response code and command sequencing."
        } else if ftmsPresent {
            conclusion = "FTMS service is present, but no treadmill data packets were observed during the probe."
        } else {
            conclusion = "FTMS service was not discovered on this device."
        }

        return [
            "ftmsPresent": ftmsPresent,
            "treadmillDataPackets": r3ProbeState.treadmillDataPackets,
            "dataWorks": dataWorks,
            "controlPointRequestSent": r3ProbeState.controlPointRequestSent,
            "controlPointWriteCompleted": r3ProbeState.controlPointWriteCompleted,
            "controlPointWriteError": r3ProbeState.controlPointWriteError ?? NSNull(),
            "controlPointResponses": r3ProbeState.controlPointResponses,
            "trainingStatusPackets": r3ProbeState.trainingStatusPackets,
            "machineStatusPackets": r3ProbeState.machineStatusPackets,
            "supplementServices": Array(r3ProbeState.vendorServices).sorted(),
            "supplementCommandsSent": r3ProbeState.supplementCommandsSent,
            "supplementWriteResults": r3ProbeState.supplementWriteResults,
            "supplementNotifications": r3ProbeState.supplementNotifications,
            "supplementPresent": supplementPresent,
            "supplementCommandsSentAny": supplementCommandsSent,
            "supplementWritesCompleted": supplementWritesCompleted,
            "supplementNotified": supplementNotified,
            "readValues": r3ProbeState.readValues,
            "parsedReadValues": r3ProbeState.parsedReadValues,
            "treadmillSamples": r3ProbeState.treadmillSamples,
            "conclusion": conclusion,
        ]
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private func formatJSONObject(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return String(describing: value)
        }
        return string
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
        print("Press return when each requested treadmill state is ready. The tool will then record a timed sample automatically.")
        print("")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.collectDisplayUnit()
            let steps = self.buildCaptureSteps()

            for step in steps {
                self.run(step: step)
            }

            DispatchQueue.main.async {
                guard let selected = self.selected else { return }
                self.logCaptureQuality()
                self.logger.write("user.finished_script", [:])
                self.central.cancelPeripheralConnection(selected)
            }
        }
    }

    private func collectDisplayUnit() {
        print("Which unit does the treadmill display use? Type kmh, mph, or press return if unknown:")
        let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if ["kmh", "km/h", "kph"].contains(input) {
            displayUnit = "kmh"
        } else if input == "mph" {
            displayUnit = "mph"
        } else {
            displayUnit = "unknown"
        }
        logger.write("user.context", ["displayUnit": displayUnit])
    }

    private func buildCaptureSteps() -> [CaptureStep] {
        var steps: [CaptureStep] = [
            CaptureStep(
                instruction: "Leave the treadmill connected and idle, then press return to record 15 seconds.",
                fields: ["phase": "idle"],
                duration: phaseDuration
            ),
            CaptureStep(
                instruction: "Start using the treadmill remote or panel, then press return to record 15 seconds.",
                fields: ["phase": "remote_start"],
                duration: phaseDuration
            ),
        ]

        let candidateDisplaySpeeds = [1.0, 2.0, 3.0, 4.0]
        var speedSteps = candidateDisplaySpeeds.map { displaySpeed in
            let targetKmh = displayUnit == "mph" ? displaySpeed * 1.609_344 : displaySpeed
            return (displaySpeed: displaySpeed, targetKmh: targetKmh)
        }
        if let speedRange {
            speedSteps = speedSteps.filter { speedRange.contains($0.targetKmh) }
            if speedSteps.isEmpty {
                logger.write("capture.warning", [
                    "reason": "no_candidate_speeds_in_range",
                    "minimumKmh": speedRange.minimumKmh,
                    "maximumKmh": speedRange.maximumKmh,
                    "displayUnit": displayUnit,
                ])
                let midpoint = ((speedRange.minimumKmh + speedRange.maximumKmh) / 2.0 * 10).rounded() / 10
                let displaySpeed = displayUnit == "mph" ? midpoint / 1.609_344 : midpoint
                speedSteps = [(displaySpeed: displaySpeed, targetKmh: midpoint)]
            }
        }
        logger.write("capture.plan", [
            "displayUnit": displayUnit,
            "speedRange": speedRange.map { ["minimumKmh": $0.minimumKmh, "maximumKmh": $0.maximumKmh, "incrementKmh": $0.incrementKmh] } ?? NSNull(),
            "inclineRange": inclineRange.map { ["minimumPercent": $0.minimumPercent, "maximumPercent": $0.maximumPercent, "incrementPercent": $0.incrementPercent] } ?? NSNull(),
            "speeds": speedSteps.map { ["displaySpeed": $0.displaySpeed, "targetKmh": $0.targetKmh] },
            "includesIncline": inclineRange?.isSupported ?? true,
        ])

        for speed in speedSteps {
            let unitLabel = displayUnit == "mph" ? "mph" : "km/h"
            steps.append(CaptureStep(
                instruction: "Set speed to exactly \(format(speed.displaySpeed)) \(unitLabel) using the remote or panel, then press return to record 15 seconds.",
                fields: [
                    "phase": "speed",
                    "displaySpeed": speed.displaySpeed,
                    "displayUnit": displayUnit,
                    "targetSpeedKmh": speed.targetKmh,
                ],
                duration: phaseDuration
            ))
        }

        if inclineRange?.isSupported ?? true {
            for incline in [1.0, 2.0, 0.0] {
                steps.append(CaptureStep(
                    instruction: "If incline is supported, set incline to \(incline), then press return to record 15 seconds. Otherwise press return to skip this timed sample.",
                    fields: ["phase": "incline", "incline": incline, "optional": true],
                    duration: phaseDuration
                ))
            }
        } else {
            logger.write("phase.skipped", ["phase": "incline", "reason": "unsupported_by_range"])
            print("Skipping incline steps because the treadmill reports no supported incline range.")
        }

        steps.append(CaptureStep(
            instruction: "Stop the treadmill using the remote or panel, then press return to record 10 seconds.",
            fields: ["phase": "remote_stop"],
            duration: stopPhaseDuration
        ))
        return steps
    }

    private func run(step: CaptureStep) {
        print(step.instruction)
        _ = readLine()

        let phaseId = UUID().uuidString
        let fields = step.fields.merging(["phaseId": phaseId, "durationSeconds": step.duration]) { current, _ in current }
        DispatchQueue.main.sync {
            currentPhase = CapturePhase(id: phaseId, fields: fields, startedAt: Date())
            phaseStats[phaseId] = PhaseStats()
        }
        logger.write("phase.begin", fields)

        Thread.sleep(forTimeInterval: step.duration)

        let summary = DispatchQueue.main.sync { finishCurrentPhase(phaseId: phaseId) }
        logger.write("phase.summary", summary)
    }

    private func finishCurrentPhase(phaseId: String) -> [String: Any] {
        let stats = phaseStats[phaseId] ?? PhaseStats()
        currentPhase = nil

        let distanceIncreased = if let first = stats.firstDistanceMeters, let last = stats.lastDistanceMeters {
            last > first
        } else {
            false
        }
        let elapsedIncreased = if let first = stats.firstElapsedTimeSeconds, let last = stats.lastElapsedTimeSeconds {
            last > first
        } else {
            false
        }

        return [
            "phaseId": phaseId,
            "treadmillDataPackets": stats.treadmillDataPackets,
            "nonzeroSpeedSamples": stats.nonzeroSpeedSamples,
            "firstSpeedKmh": stats.firstSpeedKmh ?? NSNull(),
            "lastSpeedKmh": stats.lastSpeedKmh ?? NSNull(),
            "distanceIncreased": distanceIncreased,
            "elapsedTimeIncreased": elapsedIncreased,
            "machineStatusOpcodes": Array(stats.machineStatusOpcodes).sorted(),
            "hasEnoughSamples": stats.treadmillDataPackets >= minimumPhaseSamples,
        ]
    }

    private func logCaptureQuality() {
        let shortPhases = phaseStats.values.filter { $0.treadmillDataPackets < minimumPhaseSamples }.count
        logger.write("capture.quality", [
            "displayUnit": displayUnit,
            "treadmillDataPackets": totalTreadmillDataPackets,
            "sawNonzeroSpeed": sawNonzeroSpeed,
            "sawDistanceIncrease": sawDistanceIncrease,
            "sawElapsedTimeIncrease": sawElapsedTimeIncrease,
            "sawStatusTransition": sawStatusTransition,
            "shortPhases": shortPhases,
            "phaseCount": phaseStats.count,
            "actionable": totalTreadmillDataPackets > 0 && (sawNonzeroSpeed || sawDistanceIncrease || sawElapsedTimeIncrease || sawStatusTransition),
        ])
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func isLikelyTreadmill(name: String, services: [CBUUID], serviceData: [CBUUID: Data]) -> Bool {
        let lowerName = name.lowercased()
        let ftms = CBUUID(string: "1826")
        return services.contains(ftms) || serviceData[ftms] != nil || lowerName.contains("tread") || lowerName.contains("walk") || lowerName.contains("vital") || lowerName.hasPrefix("ks-")
    }

    private func isKnownR3SupplementService(_ uuid: CBUUID?) -> Bool {
        guard let uuid else { return false }
        return uuid == CBUUID(string: "24E2521C-F63B-48ED-85BE-C5330A00FDF7") || uuid == CBUUID(string: "5833FF01-9B8B-5191-6142-22A4536EF123") || uuid == CBUUID(string: "FE00")
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
            "fitnessMachineFeatureNames": decodedFeatureNames(
                fitnessMachineFeatures,
                names: [
                    0: "averageSpeed",
                    1: "cadence",
                    2: "totalDistance",
                    3: "inclination",
                    4: "elevationGain",
                    5: "pace",
                    6: "stepCount",
                    7: "resistanceLevel",
                    8: "strideCount",
                    9: "expendedEnergy",
                    10: "heartRateMeasurement",
                    11: "metabolicEquivalent",
                    12: "elapsedTime",
                    13: "remainingTime",
                    14: "powerMeasurement",
                    15: "forceOnBeltAndPowerOutput",
                    16: "userDataRetention",
                ]
            ),
            "targetSettingFeatureNames": decodedFeatureNames(
                targetSettingFeatures,
                names: [
                    0: "speedTargetSetting",
                    1: "inclinationTargetSetting",
                    2: "resistanceTargetSetting",
                    3: "powerTargetSetting",
                    4: "heartRateTargetSetting",
                    5: "targetedExpendedEnergyConfiguration",
                    6: "targetedStepNumberConfiguration",
                    7: "targetedStrideNumberConfiguration",
                    8: "targetedDistanceConfiguration",
                    9: "targetedTrainingTimeConfiguration",
                    10: "targetedTimeInTwoHeartRateZonesConfiguration",
                    11: "targetedTimeInThreeHeartRateZonesConfiguration",
                    12: "targetedTimeInFiveHeartRateZonesConfiguration",
                    13: "indoorBikeSimulationParameters",
                    14: "wheelCircumferenceConfiguration",
                    15: "spinDownControl",
                    16: "targetedCadenceConfiguration",
                ]
            ),
        ]
    }

    private func decodedFeatureNames(_ flags: UInt32, names: [Int: String]) -> [String] {
        names.keys.sorted().compactMap { bit in
            flags & (1 << UInt32(bit)) == 0 ? nil : names[bit]
        }
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

        if !moreData, let speedRaw = uint16() {
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
