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

    var probeMode: Bool {
        if case .interactiveProbe = mode { return true }
        return false
    }

    static func parse(_ args: ArraySlice<String>) -> Arguments {
        var result = Arguments()
        var iterator = args.makeIterator()
        var requestedR3Probe = false
        var requestedInteractiveProbe = false

        while let arg = iterator.next() {
            switch arg {
            case "r3-probe":
                requestedR3Probe = true
            case "--duration":
                if let value = iterator.next(), let seconds = TimeInterval(value) {
                    result.r3ProbeDuration = seconds
                }
            case "--control-tests":
                result.r3ControlTests = true
            case "--i-understand-this-may-move-the-belt":
                result.r3ControlTestsConfirmed = true
            case "--output", "-o":
                result.outputPath = iterator.next()
            case "--scan-seconds":
                if let value = iterator.next(), let seconds = TimeInterval(value) {
                    result.scanSeconds = seconds
                }
            case "--probe":
                requestedInteractiveProbe = true
            case "--help", "-h":
                print("""
                TreadmillTrace captures raw BLE treadmill data on macOS.

                Usage:
                  treadmill-trace [--output path] [--scan-seconds 12] [--probe]
                  treadmill-trace r3-probe [--duration 30] [--output path] [--scan-seconds 12]
                  treadmill-trace r3-probe --control-tests --i-understand-this-may-move-the-belt

                The tool scans for nearby BLE devices, lets you choose one, connects,
                discovers services and characteristics, subscribes to notify/indicate
                characteristics, and writes JSON Lines trace events.

                --probe starts a live FTMS control probe after setup. It shows
                real-time stats and requires pressing a before control writes.

                r3-probe runs a WalkingPad R3 diagnostic. Safe mode sends FTMS
                Request Control and known KingSmith supplement init/query commands,
                but does not start the belt or change speed. Control tests require
                the explicit confirmation flag because they may move the treadmill.
                """)
                exit(0)
            default:
                break
            }
        }

        if requestedR3Probe, requestedInteractiveProbe {
            fputs("r3-probe cannot be combined with --probe\n", stderr)
            exit(2)
        }
        if !requestedR3Probe, result.r3ControlTests {
            fputs("--control-tests requires r3-probe\n", stderr)
            exit(2)
        }
        if requestedR3Probe, result.r3ControlTests, !result.r3ControlTestsConfirmed {
            fputs("--control-tests requires --i-understand-this-may-move-the-belt\n", stderr)
            exit(2)
        }

        if requestedR3Probe {
            result.mode = .r3Probe(duration: result.r3ProbeDuration, controlTests: result.r3ControlTests)
        } else if requestedInteractiveProbe {
            result.mode = .interactiveProbe
        }

        return result
    }
}

enum CaptureMode {
    case guidedCapture
    case interactiveProbe
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
    private var speedRange: FTMSSpeedRange?
    private var inclineRange: FTMSInclineRange?
    private var feature: FTMSFeature?
    private var controlPointCharacteristic: CBCharacteristic?
    private var probeArmed = false
    private var controlAcquired = false
    private var pendingCommand: PendingCommand?
    private var commandTimeoutTimer: Timer?
    private var probeRedrawTimer: Timer?
    private var originalTerminalSettings: termios?
    private var terminalModeActive = false
    private var probeMessage = "Passive notifications and reads are being logged."
    private var lastCommandedSpeedKmh: Double?
    private var lastCommandedInclinePercent: Double?
    private var latestStatus = ProbeStatus()
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

    private struct PendingCommand {
        let name: String
        let requestOpcode: UInt8
        let payloadHex: String
        let target: Double?
    }

    private struct ProbeStatus {
        var speedKmh: Double?
        var distanceMeters: Int?
        var elapsedSeconds: UInt16?
        var inclinePercent: Double?
        var ftmsVendorField: UInt16?
        var fitshowSteps: UInt16?
        var machineStatusOpcode: String?
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
        var requestControlResponses: [[String: Any]] = []
        var controlPointWriteResults: [[String: String]] = []
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
        case .interactiveProbe: "interactiveProbe"
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
            if characteristic.uuid == CBUUID(string: "2AD9") {
                controlPointCharacteristic = characteristic
            }

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

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        logger.write(error == nil ? "ble.tx_result" : "ble.tx_error", [
            "service": characteristic.service?.uuid.uuidString ?? "unknown",
            "characteristic": characteristic.uuid.uuidString,
            "error": error?.localizedDescription ?? "none",
            "pendingCommand": pendingCommand?.name ?? "none",
        ])
        if characteristic.uuid == CBUUID(string: "2AD9") {
            let result = [
                "service": characteristic.service?.uuid.uuidString ?? "unknown",
                "characteristic": characteristic.uuid.uuidString,
                "error": error?.localizedDescription ?? "none",
                "pendingCommand": pendingCommand?.name ?? "none",
            ]
            r3ProbeState.controlPointWriteResults.append(result)
            if r3ProbeState.controlPointWriteResults.count == 1 {
                r3ProbeState.controlPointWriteCompleted = error == nil
                r3ProbeState.controlPointWriteError = error?.localizedDescription
            }
            logger.write("r3_probe.control_point_write", result)
        } else if isKnownR3SupplementService(characteristic.service?.uuid) {
            let result = [
                "service": characteristic.service?.uuid.uuidString ?? "unknown",
                "characteristic": characteristic.uuid.uuidString,
                "error": error?.localizedDescription ?? "none",
            ]
            r3ProbeState.supplementWriteResults.append(result)
            logger.write("r3_probe.supplement_write", result)
        }

        if let error {
            probeMessage = "Write failed: \(error.localizedDescription)"
            commandTimeoutTimer?.invalidate()
            commandTimeoutTimer = nil
            pendingCommand = nil
        }
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
        let decoded = parseKnownCharacteristic(characteristic: characteristic, data: data)
        updateCaptureState(characteristic: characteristic, decoded: decoded)
        updateR3ProbeState(characteristic: characteristic, data: data, decoded: decoded, wasReadRequest: wasReadRequest)
        handleControlPointResponse(characteristic: characteristic, decoded: decoded)
        logger.write("ble.rx", [
            "service": characteristic.service?.uuid.uuidString ?? "unknown",
            "characteristic": characteristic.uuid.uuidString,
            "source": wasReadRequest ? "read" : "notify",
            "length": data.count,
            "hex": data.hexString,
            "base64": data.base64EncodedString(),
            "ftms": decoded,
        ])
    }

    private func characteristicKey(_ characteristic: CBCharacteristic) -> String {
        "\(characteristic.service?.uuid.uuidString ?? "unknown")/\(characteristic.uuid.uuidString)"
    }

    private func updateR3ProbeState(characteristic: CBCharacteristic, data: Data, decoded: [String: Any], wasReadRequest: Bool) {
        let key = characteristicKey(characteristic)
        if wasReadRequest {
            r3ProbeState.readValues[key] = data.hexString
            if !decoded.isEmpty {
                r3ProbeState.parsedReadValues[key] = decoded
            } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                r3ProbeState.parsedReadValues[key] = ["utf8": text]
            }
        }

        switch characteristic.uuid {
        case CBUUID(string: "2ACD"):
            r3ProbeState.treadmillDataPackets += 1
            if r3ProbeState.treadmillSamples.count < 5 {
                r3ProbeState.treadmillSamples.append(decoded.merging(["hex": data.hexString]) { current, _ in current })
            }
        case CBUUID(string: "2AD3"):
            r3ProbeState.trainingStatusPackets += 1
        case CBUUID(string: "2ADA"):
            r3ProbeState.machineStatusPackets += 1
        case CBUUID(string: "2AD9"):
            let response = decoded.merging(["hex": data.hexString]) { current, _ in current }
            r3ProbeState.controlPointResponses.append(response)
            if decoded["requestOpcodeRaw"] as? UInt8 == 0x00 {
                r3ProbeState.requestControlResponses.append(response)
            }
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

    private func updateCaptureState(characteristic: CBCharacteristic, decoded: [String: Any]) {
        switch characteristic.uuid {
        case CBUUID(string: "2ACD"):
            updateTreadmillDataState(decoded)
        case CBUUID(string: "2ADA"):
            updateMachineStatusState(decoded)
        case CBUUID(string: "2ACC"):
            if let fitnessMachineFeatures = decoded["fitnessMachineFeaturesRaw"] as? UInt32,
               let targetSettingFeatures = decoded["targetSettingFeaturesRaw"] as? UInt32
            {
                feature = FTMSFeature(
                    fitnessMachineFeatures: fitnessMachineFeatures,
                    targetSettingFeatures: targetSettingFeatures
                )
            }
        case CBUUID(string: "2AD4"):
            if let minimumKmh = decoded["minimumKmh"] as? Double,
               let maximumKmh = decoded["maximumKmh"] as? Double,
               let incrementKmh = decoded["incrementKmh"] as? Double
            {
                speedRange = FTMSSpeedRange(minimumKmh: minimumKmh, maximumKmh: maximumKmh, incrementKmh: incrementKmh)
            }
        case CBUUID(string: "2AD5"):
            if let minimumPercent = decoded["minimumPercent"] as? Double,
               let maximumPercent = decoded["maximumPercent"] as? Double,
               let incrementPercent = decoded["incrementPercent"] as? Double
            {
                inclineRange = FTMSInclineRange(
                    minimumPercent: minimumPercent,
                    maximumPercent: maximumPercent,
                    incrementPercent: incrementPercent
                )
            }
        case CBUUID(string: "FFF1"):
            if let steps = decoded["candidateSteps"] as? UInt16 {
                latestStatus.fitshowSteps = steps
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
        let inclinePercent = ftms["inclinationPercent"] as? Double
        let vendorField = ftms["vendorFieldRaw16"] as? UInt16

        if let speedKmh {
            latestStatus.speedKmh = speedKmh
            if speedKmh > 0 {
                sawNonzeroSpeed = true
            }
        }
        if let distanceMeters {
            latestStatus.distanceMeters = distanceMeters
            if let previous = lastDistanceMeters, distanceMeters > previous {
                sawDistanceIncrease = true
            }
            lastDistanceMeters = distanceMeters
        }
        if let elapsedTimeSeconds {
            latestStatus.elapsedSeconds = elapsedTimeSeconds
            if let previous = lastElapsedTimeSeconds, elapsedTimeSeconds > previous {
                sawElapsedTimeIncrease = true
            }
            lastElapsedTimeSeconds = elapsedTimeSeconds
        }
        if let inclinePercent {
            latestStatus.inclinePercent = inclinePercent
        }
        if let vendorField {
            latestStatus.ftmsVendorField = vendorField
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
        latestStatus.machineStatusOpcode = opcode

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
            case .interactiveProbe:
                self.startProbeMode()
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
            print("It sends FTMS Request Control and safe KingSmith supplement probe commands.")
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
        let writeType: CBCharacteristicWriteType
        let writeTypeName: String
        if characteristic.properties.contains(.write) {
            writeType = .withResponse
            writeTypeName = "withResponse"
        } else if characteristic.properties.contains(.writeWithoutResponse) {
            writeType = .withoutResponse
            writeTypeName = "withoutResponse"
        } else {
            logger.write("r3_probe.supplement_tx_skipped", [
                "name": name,
                "service": characteristic.service?.uuid.uuidString ?? "unknown",
                "characteristic": characteristic.uuid.uuidString,
                "hex": data.hexString,
                "reason": "write_not_supported",
            ])
            return
        }

        let record = [
            "name": name,
            "service": characteristic.service?.uuid.uuidString ?? "unknown",
            "characteristic": characteristic.uuid.uuidString,
            "hex": data.hexString,
            "writeType": writeTypeName,
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
        let controlResponded = !r3ProbeState.requestControlResponses.isEmpty
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
            "requestControlResponses": r3ProbeState.requestControlResponses,
            "controlPointWriteResults": r3ProbeState.controlPointWriteResults,
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
        restoreTerminalMode()
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
            let unit = self.collectDisplayUnit()
            let steps = DispatchQueue.main.sync {
                self.displayUnit = unit
                return self.buildCaptureSteps()
            }

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

    private func collectDisplayUnit() -> String {
        print("Which unit does the treadmill display use? Type kmh, mph, or press return if unknown:")
        let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let unit: String
        if ["kmh", "km/h", "kph"].contains(input) {
            unit = "kmh"
        } else if input == "mph" {
            unit = "mph"
        } else {
            unit = "unknown"
        }
        logger.write("user.context", ["displayUnit": unit])
        return unit
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

    private func parseKnownCharacteristic(characteristic: CBCharacteristic, data: Data) -> [String: Any] {
        switch characteristic.uuid {
        case CBUUID(string: "2ACD"):
            return FTMSParser.parseTreadmillData(data).dictionary()
        case CBUUID(string: "2ADA"):
            return ["machineStatusOpcode": data.first.map { String(format: "0x%02X", $0) } ?? "none"]
        case CBUUID(string: "2AD9"):
            return [
                "controlPointResponse": data.count >= 3 && data[0] == 0x80,
                "requestOpcode": data.count >= 2 ? String(format: "0x%02X", data[1]) : "none",
                "requestOpcodeRaw": data.count >= 2 ? data[1] : NSNull(),
                "resultCode": data.count >= 3 ? String(format: "0x%02X", data[2]) : "none",
            ]
        case CBUUID(string: "2ACC"):
            guard let feature = FTMSParser.parseFeature(data) else { return ["error": "short_packet"] }
            return [
                "fitnessMachineFeatures": String(format: "0x%08X", feature.fitnessMachineFeatures),
                "targetSettingFeatures": String(format: "0x%08X", feature.targetSettingFeatures),
                "fitnessMachineFeaturesRaw": feature.fitnessMachineFeatures,
                "targetSettingFeaturesRaw": feature.targetSettingFeatures,
                "fitnessMachineFeatureNames": decodedFeatureNames(
                    feature.fitnessMachineFeatures,
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
                    feature.targetSettingFeatures,
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
        case CBUUID(string: "2AD4"):
            guard let range = FTMSParser.parseSupportedSpeedRange(data) else { return ["error": "short_packet"] }
            return [
                "minimumRaw": UInt16((range.minimumKmh * 100).rounded()),
                "maximumRaw": UInt16((range.maximumKmh * 100).rounded()),
                "incrementRaw": UInt16((range.incrementKmh * 100).rounded()),
                "minimumKmh": range.minimumKmh,
                "maximumKmh": range.maximumKmh,
                "incrementKmh": range.incrementKmh,
            ]
        case CBUUID(string: "2AD5"):
            guard let range = FTMSParser.parseSupportedInclinationRange(data) else { return ["error": "short_packet"] }
            return [
                "minimumRaw": Int16((range.minimumPercent * 10).rounded()),
                "maximumRaw": Int16((range.maximumPercent * 10).rounded()),
                "incrementRaw": UInt16((range.incrementPercent * 10).rounded()),
                "minimumPercent": range.minimumPercent,
                "maximumPercent": range.maximumPercent,
                "incrementPercent": range.incrementPercent,
            ]
        case CBUUID(string: "FFF1"):
            guard let metrics = FitshowParser.parseLiveMetrics(data) else { return [:] }
            return metrics.dictionary()
        case CBUUID(string: "2A24"), CBUUID(string: "2A25"), CBUUID(string: "2A26"), CBUUID(string: "2A27"), CBUUID(string: "2A28"), CBUUID(string: "2A29"):
            return ["utf8": String(data: data, encoding: .utf8) ?? "invalid_utf8"]
        default:
            return [:]
        }
    }

    private func decodedFeatureNames(_ flags: UInt32, names: [Int: String]) -> [String] {
        names.keys.sorted().compactMap { bit in
            flags & (1 << UInt32(bit)) == 0 ? nil : names[bit]
        }
    }

    private func startProbeMode() {
        discoveryTimeout?.invalidate()
        print("")
        logger.write("probe.start", ["armed": probeArmed])
        guard enableRawTerminalMode() else {
            logger.write("session.end", ["reason": "terminal_raw_mode_failed"])
            print("Could not enable terminal control mode.")
            finish(1)
        }
        print("\u{001B}[2J\u{001B}[?25l", terminator: "")
        redrawProbeScreen()
        probeRedrawTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.redrawProbeScreen()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while let key = self?.readProbeKey() {
                DispatchQueue.main.async {
                    self?.handleProbeKey(key)
                }
                if case .quit = key {
                    break
                }
            }
        }
    }

    private enum ProbeKey {
        case arm
        case requestControl
        case start
        case stop
        case speedUp
        case speedDown
        case inclineUp
        case inclineDown
        case quit
        case unknown(String)
    }

    private func enableRawTerminalMode() -> Bool {
        var settings = termios()
        guard tcgetattr(STDIN_FILENO, &settings) == 0 else { return false }
        originalTerminalSettings = settings
        settings.c_lflag &= ~UInt(ECHO | ICANON)
        settings.c_cc.16 = 1
        settings.c_cc.17 = 1
        guard tcsetattr(STDIN_FILENO, TCSANOW, &settings) == 0 else { return false }
        terminalModeActive = true
        return true
    }

    private func restoreTerminalMode() {
        probeRedrawTimer?.invalidate()
        probeRedrawTimer = nil
        guard terminalModeActive else { return }
        if var settings = originalTerminalSettings {
            tcsetattr(STDIN_FILENO, TCSANOW, &settings)
            originalTerminalSettings = nil
        }
        terminalModeActive = false
        print("\u{001B}[?25h", terminator: "")
        fflush(stdout)
    }

    private func readProbeKey() -> ProbeKey {
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { return .unknown("read_failed") }
        switch byte {
        case 0x1B:
            var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&input, 1, 100) > 0 else { return .unknown("escape") }
            var prefix: UInt8 = 0
            guard read(STDIN_FILENO, &prefix, 1) == 1, prefix == 0x5B else {
                return .unknown("escape")
            }
            var code: UInt8 = 0
            guard read(STDIN_FILENO, &code, 1) == 1 else {
                return .unknown("escape")
            }
            switch code {
            case 0x41: return .speedUp
            case 0x42: return .speedDown
            case 0x43: return .inclineUp
            case 0x44: return .inclineDown
            default: return .unknown("escape")
            }
        case 0x20:
            return .start
        case UInt8(ascii: "a"), UInt8(ascii: "A"):
            return .arm
        case UInt8(ascii: "r"), UInt8(ascii: "R"):
            return .requestControl
        case UInt8(ascii: "s"), UInt8(ascii: "S"):
            return .stop
        case UInt8(ascii: "q"), UInt8(ascii: "Q"):
            return .quit
        default:
            return .unknown(String(format: "0x%02X", byte))
        }
    }

    private func handleProbeKey(_ key: ProbeKey) {
        switch key {
        case .arm:
            armProbe()
        case .requestControl:
            sendProbeCommand(.requestControl)
        case .start:
            sendProbeCommand(.start)
        case .stop:
            sendProbeCommand(.stop)
        case .speedUp:
            handleSpeedDelta(+1)
        case .speedDown:
            handleSpeedDelta(-1)
        case .inclineUp:
            handleInclineDelta(+1)
        case .inclineDown:
            handleInclineDelta(-1)
        case .quit:
            quitProbe()
        case .unknown(let key):
            rejectProbeCommand(key, reason: "unknown_key")
            probeMessage = "Unknown key. Use arrows, a, r, space, s, or q."
        }
        redrawProbeScreen()
    }

    private func redrawProbeScreen() {
        print("\u{001B}[H", terminator: "")
        printLine("TreadmillTrace probe")
        printLine("Log: \(logger.path)")
        printLine("Stand off the belt and keep the stop control reachable before arming.")
        printLine("")
        printLine("Speed:      \(latestStatus.speedKmh.map { "\(format($0)) km/h" } ?? "unknown")")
        printLine("Commanded:  \(lastCommandedSpeedKmh.map { "\(format($0)) km/h" } ?? "unknown")")
        printLine("Distance:   \(latestStatus.distanceMeters.map { "\($0) m" } ?? "unknown")")
        printLine("Time:       \(latestStatus.elapsedSeconds.map(formatElapsed) ?? "unknown")")
        printLine("Incline:    \(latestStatus.inclinePercent.map { "\(format($0))%" } ?? "unknown")")
        printLine("Steps:      \(latestStatus.fitshowSteps.map(String.init) ?? latestStatus.ftmsVendorField.map(String.init) ?? "unknown")")
        printLine("Status:     \(latestStatus.machineStatusOpcode ?? "unknown")")
        printLine("Armed:      \(probeArmed ? "yes" : "no")")
        printLine("Control:    \(controlAcquired ? "acquired" : "not acquired")")
        printLine("Pending:    \(pendingCommand?.name ?? "none")")
        printLine("")
        printLine("Controls:")
        printLine("  a arm     r request control     space start     s stop     q quit")
        printLine("  up/down speed +/- range increment     left/right incline -/+ range increment")
        printLine("")
        printLine("Message: \(probeMessage)")
        fflush(stdout)
    }

    private func printLine(_ line: String) {
        print("\(line)\u{001B}[K")
    }

    private func formatElapsed(_ seconds: UInt16) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private func armProbe() {
        guard let controlPointCharacteristic else {
            rejectProbeCommand("arm", reason: "missing_control_point")
            probeMessage = "Cannot arm: FTMS Control Point 2AD9 was not found."
            return
        }
        guard controlPointCharacteristic.properties.contains(.write) else {
            rejectProbeCommand("arm", reason: "control_point_without_write")
            probeMessage = "Cannot arm: FTMS Control Point 2AD9 does not support write-with-response."
            return
        }
        guard controlPointCharacteristic.properties.contains(.indicate),
              notifiedCharacteristics.contains(characteristicKey(controlPointCharacteristic))
        else {
            rejectProbeCommand("arm", reason: "control_point_without_indication")
            probeMessage = "Cannot arm: 2AD9 indications are not enabled."
            return
        }
        probeArmed = true
        logger.write("probe.armed", ["controlPoint": characteristicKey(controlPointCharacteristic)])
        probeMessage = "Probe armed. Press r to request control before movement commands."
    }

    private func handleSpeedDelta(_ direction: Double) {
        guard let speedRange else {
            rejectProbeCommand("speed_delta", reason: "missing_speed_range")
            probeMessage = "Speed range is unknown. Refusing to send speed command."
            return
        }
        let baseline = lastCommandedSpeedKmh ?? latestStatus.speedKmh ?? speedRange.minimumKmh
        guard let command = FTMSCommand.speed(requestedKmh: baseline + direction * speedRange.incrementKmh, range: speedRange) else {
            rejectProbeCommand("speed_delta", reason: "invalid_speed")
            probeMessage = "Invalid speed target."
            return
        }
        sendProbeCommand(command)
    }

    private func handleInclineDelta(_ direction: Double) {
        guard let inclineRange else {
            rejectProbeCommand("incline_delta", reason: "missing_incline_range")
            probeMessage = "Incline range is unknown. Refusing to send incline command."
            return
        }
        let baseline = lastCommandedInclinePercent ?? latestStatus.inclinePercent ?? 0
        guard let command = FTMSCommand.incline(requestedPercent: baseline + direction * inclineRange.incrementPercent, range: inclineRange) else {
            rejectProbeCommand("incline_delta", reason: "invalid_incline")
            probeMessage = "Invalid incline target."
            return
        }
        sendProbeCommand(command)
    }

    private func quitProbe() {
        logger.write("probe.end", ["reason": "user_quit"])
        finish(0)
    }

    private func sendProbeCommand(_ command: FTMSCommand) {
        guard probeArmed else {
            rejectProbeCommand(command.name, reason: "not_armed")
            probeMessage = "Control writes are disabled. Press a to arm."
            return
        }
        guard pendingCommand == nil else {
            rejectProbeCommand(command.name, reason: "command_pending")
            probeMessage = "A command is still pending. Wait for response or timeout."
            return
        }
        if command.name != "request", command.name != "stop", !controlAcquired {
            rejectProbeCommand(command.name, reason: "control_not_acquired")
            probeMessage = "Request control first and wait for a successful response."
            return
        }
        guard let selected, let controlPointCharacteristic else {
            rejectProbeCommand(command.name, reason: "missing_control_point")
            probeMessage = "No control point is available."
            return
        }
        guard controlPointCharacteristic.properties.contains(.write) else {
            rejectProbeCommand(command.name, reason: "control_point_without_write")
            probeMessage = "Control point does not support write-with-response."
            return
        }
        guard controlPointCharacteristic.properties.contains(.indicate),
              notifiedCharacteristics.contains(characteristicKey(controlPointCharacteristic))
        else {
            rejectProbeCommand(command.name, reason: "control_point_without_indication")
            probeMessage = "Control point indications are not enabled."
            return
        }

        let payload = command.payload
        pendingCommand = PendingCommand(
            name: command.name,
            requestOpcode: command.requestOpcode,
            payloadHex: payload.hexString,
            target: command.target
        )
        logger.write("probe.command", [
            "name": command.name,
            "requestOpcode": String(format: "0x%02X", command.requestOpcode),
            "requested": command.requested ?? NSNull(),
            "target": command.target ?? NSNull(),
            "clamped": command.clamped,
            "payloadHex": payload.hexString,
        ])
        logger.write("ble.tx", [
            "service": controlPointCharacteristic.service?.uuid.uuidString ?? "unknown",
            "characteristic": controlPointCharacteristic.uuid.uuidString,
            "writeType": "withResponse",
            "length": payload.count,
            "hex": payload.hexString,
            "command": command.name,
        ])
        probeMessage = "Sent \(command.name) \(payload.hexString)."
        selected.writeValue(payload, for: controlPointCharacteristic, type: .withResponse)
        startCommandTimeout()
    }

    private func startCommandTimeout() {
        commandTimeoutTimer?.invalidate()
        commandTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            guard let self, let pending = self.pendingCommand else { return }
            self.logger.write("probe.command_timeout", [
                "name": pending.name,
                "requestOpcode": String(format: "0x%02X", pending.requestOpcode),
                "payloadHex": pending.payloadHex,
            ])
            self.probeMessage = "Command timed out: \(pending.name)."
            self.pendingCommand = nil
            self.redrawProbeScreen()
        }
    }

    private func rejectProbeCommand(_ command: String, reason: String) {
        logger.write("probe.command_rejected", ["command": command, "reason": reason])
    }

    private func handleControlPointResponse(characteristic: CBCharacteristic, decoded: [String: Any]) {
        guard characteristic.uuid == CBUUID(string: "2AD9"),
              decoded["controlPointResponse"] as? Bool == true,
              let requestOpcode = decoded["requestOpcodeRaw"] as? UInt8,
              let pending = pendingCommand
        else { return }

        if pending.requestOpcode == requestOpcode {
            commandTimeoutTimer?.invalidate()
            commandTimeoutTimer = nil
            pendingCommand = nil
            if decoded["resultCode"] as? String == "0x01" {
                if pending.name == "request" {
                    controlAcquired = true
                } else if pending.name == "speed" {
                    lastCommandedSpeedKmh = pending.target
                } else if pending.name == "incline" {
                    lastCommandedInclinePercent = pending.target
                }
                probeMessage = "Command accepted: \(pending.name)."
            } else {
                probeMessage = "Command response for \(pending.name): \(decoded["resultCode"] ?? "none")."
            }
            logger.write("probe.command_response", [
                "name": pending.name,
                "requestOpcode": decoded["requestOpcode"] ?? "none",
                "resultCode": decoded["resultCode"] ?? "none",
            ])
        }
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
