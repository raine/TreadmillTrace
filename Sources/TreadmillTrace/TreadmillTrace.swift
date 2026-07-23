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
        var requestedTimeProbe = false
        var requestedVitalwalkProbe = false

        while let arg = iterator.next() {
            switch arg {
            case "r3-probe":
                requestedR3Probe = true
            case "time-probe":
                requestedTimeProbe = true
            case "vitalwalk-probe":
                requestedVitalwalkProbe = true
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
                  treadmill-trace time-probe [--output path] [--scan-seconds 12]
                  treadmill-trace vitalwalk-probe [--output path] [--scan-seconds 12]
                  treadmill-trace r3-probe [--duration 30] [--output path] [--scan-seconds 12]
                  treadmill-trace r3-probe --control-tests --i-understand-this-may-move-the-belt

                The tool scans for nearby BLE devices, lets you choose one, connects,
                discovers services and characteristics, subscribes to notify/indicate
                characteristics, and writes JSON Lines trace events.

                --probe starts a live FTMS control probe after setup. It shows
                real-time stats and requires pressing a before control writes.

                time-probe guides a passive comparison of normal and countdown
                workouts. It records raw FTMS flags, bytes, elapsed time, and
                remaining time without sending treadmill control commands.

                vitalwalk-probe runs a guided low-speed diagnostic for Vitalwalk
                speed units, native increments, pause, resume, incline, and steps.
                It requires runtime confirmation because it moves the belt.

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

        let requestedModes = [requestedR3Probe, requestedInteractiveProbe, requestedTimeProbe, requestedVitalwalkProbe].filter { $0 }.count
        if requestedModes > 1 {
            fputs("r3-probe, time-probe, vitalwalk-probe, and --probe cannot be combined\n", stderr)
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
        } else if requestedTimeProbe {
            result.mode = .timeProbe
        } else if requestedVitalwalkProbe {
            result.mode = .vitalwalkProbe
        }

        return result
    }
}

enum CaptureMode {
    case guidedCapture
    case interactiveProbe
    case timeProbe
    case vitalwalkProbe
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
    private var vitalwalkProbeState = VitalwalkProbeState()
    private var vitalwalkMovementPossible = false
    private var vitalwalkExitCode: Int32 = 0
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
        var machineStatusParametersHex: String?
        var trainingStatus: String?
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
        var firstRemainingTimeSeconds: UInt16?
        var lastRemainingTimeSeconds: UInt16?
        var treadmillDataFlags: Set<String> = []
        var machineStatusOpcodes: Set<String> = []
    }

    private struct CaptureStep {
        let instruction: String
        let fields: [String: Any]
        let duration: TimeInterval
    }

    private struct VitalwalkProbeState {
        var displayUnit: VitalwalkDisplayUnit?
        var targets: VitalwalkProbeTargets?
        var commandResults: [[String: Any]] = []
        var speedSamples: [[String: Any]] = []
        var inclineObservation: [String: Any]?
        var pauseObservation: String?
        var resumeObservation: String?
        var finalDisplayValues: [String: Any] = [:]
        var abortedReason: String?
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
        case .timeProbe: "timeProbe"
        case .vitalwalkProbe: "vitalwalkProbe"
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
        _: CBCentralManager,
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

    func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
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

    func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.write("ble.connect_failed", [
            "id": peripheral.identifier.uuidString,
            "name": peripheral.name ?? "Unknown",
            "error": error?.localizedDescription ?? "none",
        ])
        print("Failed to connect: \(error?.localizedDescription ?? "unknown error")")
        finish(1)
    }

    func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.write("ble.disconnect", [
            "id": peripheral.identifier.uuidString,
            "name": peripheral.name ?? "Unknown",
            "error": error?.localizedDescription ?? "none",
        ])
        print("Disconnected. Log saved to \(logger.path)")
        if case .vitalwalkProbe = mode {
            finish(vitalwalkExitCode)
        }
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

    func peripheral(_: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
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

    func peripheral(_: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
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

    func peripheral(_: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
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
        case CBUUID(string: "2AD3"):
            latestStatus.trainingStatus = decoded["trainingStatus"] as? String
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
        let remainingTimeSeconds = ftms["remainingTimeSeconds"] as? UInt16
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
        if let remainingTimeSeconds {
            if stats.firstRemainingTimeSeconds == nil { stats.firstRemainingTimeSeconds = remainingTimeSeconds }
            stats.lastRemainingTimeSeconds = remainingTimeSeconds
        }
        if let flags = ftms["flags"] as? String {
            stats.treadmillDataFlags.insert(flags)
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
        latestStatus.machineStatusParametersHex = ftms["machineStatusParametersHex"] as? String

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
            case .timeProbe:
                self.startTimeProbe()
            case .vitalwalkProbe:
                self.startVitalwalkProbe()
            case let .r3Probe(duration, controlTests):
                self.startR3Probe(duration: duration, controlTests: controlTests)
            }
        }
    }

    private func startVitalwalkProbe() {
        discoveryTimeout?.invalidate()
        print("")
        print("Vitalwalk one-run diagnostic")
        print("This probe tests speed units, one native speed increment, incline, pause, resume, and displayed totals.")
        print("The belt will run only at the reported minimum speed and one increment above it.")
        print("")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runVitalwalkProbe()
        }
    }

    private func runVitalwalkProbe() {
        guard waitForVitalwalkPrerequisites() else {
            abortVitalwalkProbe(reason: "prerequisites_unavailable", attemptStop: false)
            return
        }
        guard let speedRange, let targets = VitalwalkProbeTargets.make(from: speedRange) else {
            abortVitalwalkProbe(reason: "invalid_speed_range", attemptStop: false)
            return
        }
        vitalwalkProbeState.targets = targets

        guard let unit = promptVitalwalkDisplayUnit() else {
            abortVitalwalkProbe(reason: "input_closed", attemptStop: false)
            return
        }
        vitalwalkProbeState.displayUnit = unit
        logger.write("vitalwalk_probe.context", [
            "displayUnit": unit.rawValue,
            "minimumRaw": targets.minimumRaw,
            "incrementRaw": targets.incrementRaw,
            "incrementedRaw": targets.incrementedRaw,
            "speedRangeMinimumRaw": speedRange.minimumKmh,
            "speedRangeMaximumRaw": speedRange.maximumKmh,
            "speedRangeIncrementRaw": speedRange.incrementKmh,
            "fitshowServicePresent": selectedServices.contains(CBUUID(string: "FFF0")),
        ])

        print("")
        print("SAFETY CHECK")
        print("Stand off the belt, keep the physical stop control reachable, and keep the treadmill clear.")
        print("The probe always attempts FTMS Stop on failure, interruption, and normal completion.")
        print("Type RUN VITALWALK PROBE exactly to continue:")
        guard readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) == "RUN VITALWALK PROBE" else {
            abortVitalwalkProbe(reason: "runtime_confirmation_declined", attemptStop: false)
            return
        }

        guard requireVitalwalkCommand(
            name: "request_control",
            payload: FTMSCommand.requestControl.payload,
            opcode: FTMSCommand.requestControl.requestOpcode
        ) else {
            abortVitalwalkProbe(reason: "request_control_failed", attemptStop: false)
            return
        }
        guard requireVitalwalkCommand(
            name: "initial_stop",
            payload: FTMSCommand.stop.payload,
            opcode: FTMSCommand.stop.requestOpcode
        ) else {
            abortVitalwalkProbe(reason: "initial_stop_failed", attemptStop: true)
            return
        }
        let initiallyStopped = waitForVitalwalkBeltToStop(timeout: 8)
        guard confirmVitalwalkBeltStoppedIfNeeded(
            telemetryStopped: initiallyStopped,
            context: "before setting the initial speed target"
        ) else {
            abortVitalwalkProbe(reason: "initial_physical_stop_not_confirmed", attemptStop: true)
            return
        }

        let minimumCommand = FTMSCommand.speed(requestedKmh: targets.minimumRaw, range: speedRange)
        guard let minimumCommand,
              requireVitalwalkCommand(
                  name: "set_speed_minimum_raw",
                  payload: minimumCommand.payload,
                  opcode: minimumCommand.requestOpcode,
                  fields: ["rawTarget": targets.minimumRaw]
              )
        else {
            abortVitalwalkProbe(reason: "minimum_speed_target_failed", attemptStop: false)
            return
        }

        vitalwalkMovementPossible = true
        guard requireVitalwalkCommand(
            name: "start_at_minimum",
            payload: FTMSCommand.start.payload,
            opcode: FTMSCommand.start.requestOpcode
        ) else {
            abortVitalwalkProbe(reason: "start_failed", attemptStop: true)
            return
        }

        print("Waiting 8 seconds for minimum speed to stabilize...")
        Thread.sleep(forTimeInterval: 8)
        guard let minimumDisplay = promptRequiredDouble(
            "Enter the exact speed shown on the treadmill display at minimum (number only):"
        ) else {
            abortVitalwalkProbe(reason: "minimum_display_value_missing", attemptStop: true)
            return
        }
        recordVitalwalkSpeedSample(rawTarget: targets.minimumRaw, physicalDisplayValue: minimumDisplay, unit: unit, phase: "minimum")

        let incrementedCommand = FTMSCommand.speed(requestedKmh: targets.incrementedRaw, range: speedRange)
        guard let incrementedCommand,
              requireVitalwalkCommand(
                  name: "set_speed_one_increment_raw",
                  payload: incrementedCommand.payload,
                  opcode: incrementedCommand.requestOpcode,
                  fields: ["rawTarget": targets.incrementedRaw, "rawIncrement": targets.incrementRaw]
              )
        else {
            abortVitalwalkProbe(reason: "incremented_speed_target_failed", attemptStop: true)
            return
        }

        print("Waiting 6 seconds for the one-increment speed to stabilize...")
        Thread.sleep(forTimeInterval: 6)
        guard let incrementedDisplay = promptRequiredDouble(
            "Enter the exact speed shown after one native increment (number only):"
        ) else {
            abortVitalwalkProbe(reason: "incremented_display_value_missing", attemptStop: true)
            return
        }
        recordVitalwalkSpeedSample(rawTarget: targets.incrementedRaw, physicalDisplayValue: incrementedDisplay, unit: unit, phase: "one_increment")

        guard requireVitalwalkCommand(
            name: "restore_speed_minimum_raw",
            payload: minimumCommand.payload,
            opcode: minimumCommand.requestOpcode,
            fields: ["rawTarget": targets.minimumRaw]
        ) else {
            abortVitalwalkProbe(reason: "restore_minimum_speed_failed", attemptStop: true)
            return
        }
        Thread.sleep(forTimeInterval: 4)

        runVitalwalkInclineTestIfAvailable()

        let pauseResult = sendVitalwalkCommand(name: "pause", payload: FTMSCommand.pause.payload, opcode: FTMSCommand.pause.requestOpcode)
        recordVitalwalkCommandResult(pauseResult)
        print("Waiting 6 seconds after FTMS Pause...")
        Thread.sleep(forTimeInterval: 6)
        guard let pauseObservation = promptRequiredText(
            "Describe exactly what Pause did (for example: stopped, slowed, or no visible change):"
        ) else {
            abortVitalwalkProbe(reason: "pause_observation_missing", attemptStop: true)
            return
        }
        vitalwalkProbeState.pauseObservation = pauseObservation
        logger.write("vitalwalk_probe.pause_observation", [
            "observation": pauseObservation,
            "snapshot": vitalwalkSnapshot(),
            "commandResult": pauseResult.dictionary,
        ])

        let stopAfterPause = sendVitalwalkCommand(
            name: "stop_after_pause",
            payload: FTMSCommand.stop.payload,
            opcode: FTMSCommand.stop.requestOpcode
        )
        recordVitalwalkCommandResult(stopAfterPause)
        let stoppedAfterPause = waitForVitalwalkBeltToStop(timeout: 12)

        guard stopAfterPause.succeeded else {
            abortVitalwalkProbe(reason: "stop_after_pause_failed", attemptStop: true)
            return
        }
        guard confirmVitalwalkBeltStoppedIfNeeded(
            telemetryStopped: stoppedAfterPause,
            context: "before the resume test"
        ) else {
            abortVitalwalkProbe(reason: "physical_stop_not_confirmed", attemptStop: true)
            return
        }

        let resumeResult = sendVitalwalkCommand(
            name: "start_after_stop",
            payload: FTMSCommand.start.payload,
            opcode: FTMSCommand.start.requestOpcode
        )
        recordVitalwalkCommandResult(resumeResult)
        guard resumeResult.succeeded else {
            abortVitalwalkProbe(reason: "resume_after_stop_failed", attemptStop: true)
            return
        }

        print("Waiting 8 seconds to observe Start after Stop...")
        Thread.sleep(forTimeInterval: 8)
        guard let resumeObservation = promptRequiredText(
            "Describe what Start did after Stop, including the displayed speed:"
        ) else {
            abortVitalwalkProbe(reason: "resume_observation_missing", attemptStop: true)
            return
        }
        vitalwalkProbeState.resumeObservation = resumeObservation
        logger.write("vitalwalk_probe.resume_observation", [
            "observation": resumeObservation,
            "snapshot": vitalwalkSnapshot(),
            "commandResult": resumeResult.dictionary,
        ])

        print("")
        print("Enter the values visible on the treadmill before it is stopped.")
        vitalwalkProbeState.finalDisplayValues = [
            "steps": promptOptionalDouble("Displayed steps (number, or unknown):") ?? NSNull(),
            "distance": promptOptionalDouble("Displayed distance (number, or unknown):") ?? NSNull(),
            "calories": promptOptionalDouble("Displayed calories (number, or unknown):") ?? NSNull(),
            "speed": promptOptionalDouble("Displayed speed (number, or unknown):") ?? NSNull(),
            "displayUnit": unit.rawValue,
        ]
        logger.write("vitalwalk_probe.final_display", [
            "values": vitalwalkProbeState.finalDisplayValues,
            "snapshot": vitalwalkSnapshot(),
        ])

        let finalStop = sendVitalwalkCommand(
            name: "final_stop",
            payload: FTMSCommand.stop.payload,
            opcode: FTMSCommand.stop.requestOpcode
        )
        recordVitalwalkCommandResult(finalStop)
        let stoppedAtCompletion = waitForVitalwalkBeltToStop(timeout: 12)
        guard finalStop.succeeded else {
            abortVitalwalkProbe(reason: "final_stop_failed", attemptStop: true)
            return
        }
        guard confirmVitalwalkBeltStoppedIfNeeded(
            telemetryStopped: stoppedAtCompletion,
            context: "before the probe exits"
        ) else {
            abortVitalwalkProbe(reason: "final_physical_stop_not_confirmed", attemptStop: true)
            return
        }
        vitalwalkMovementPossible = false

        finishVitalwalkProbe()
    }

    private func waitForVitalwalkPrerequisites() -> Bool {
        for attempt in 1 ... 6 {
            var missing: [String] = []
            DispatchQueue.main.sync {
                if !selectedServices.contains(CBUUID(string: "1826")) { missing.append("FTMS service 1826") }
                if speedRange == nil { missing.append("Supported Speed Range 2AD4") }
                if feature == nil { missing.append("Fitness Machine Feature 2ACC") }
                if !notifiedCharacteristics.contains(where: { $0.hasSuffix("/2ACD") }) {
                    missing.append("Treadmill Data notifications 2ACD")
                }
                if let controlPointCharacteristic {
                    if !controlPointCharacteristic.properties.contains(.write) { missing.append("2AD9 write-with-response") }
                    if !controlPointCharacteristic.properties.contains(.indicate) { missing.append("2AD9 indication property") }
                    if !notifiedCharacteristics.contains(characteristicKey(controlPointCharacteristic)) {
                        missing.append("2AD9 indications enabled")
                    }
                } else {
                    missing.append("FTMS Control Point 2AD9")
                }
            }

            if missing.isEmpty,
               let feature,
               feature.targetSettingFeatures & 0x0000_0001 != 0,
               let speedRange,
               VitalwalkProbeTargets.make(from: speedRange) != nil
            {
                logger.write("vitalwalk_probe.preflight", [
                    "status": "ready",
                    "attempt": attempt,
                    "feature": [
                        "fitnessMachineFeatures": String(format: "0x%08X", feature.fitnessMachineFeatures),
                        "targetSettingFeatures": String(format: "0x%08X", feature.targetSettingFeatures),
                    ],
                    "speedRange": [
                        "minimumRaw": speedRange.minimumKmh,
                        "maximumRaw": speedRange.maximumKmh,
                        "incrementRaw": speedRange.incrementKmh,
                    ],
                    "inclineRangeKnown": inclineRange != nil,
                    "fitshowServicePresent": selectedServices.contains(CBUUID(string: "FFF0")),
                ])
                return true
            }

            if let feature, feature.targetSettingFeatures & 0x0000_0001 == 0 {
                missing.append("speed target feature")
            }
            logger.write("vitalwalk_probe.preflight", [
                "status": attempt == 6 ? "failed" : "waiting",
                "attempt": attempt,
                "missing": missing,
            ])
            if attempt == 6 {
                print("Vitalwalk probe cannot run safely. Missing: \(missing.joined(separator: ", "))")
                return false
            }

            DispatchQueue.main.sync {
                rereadVitalwalkPrerequisites()
            }
            Thread.sleep(forTimeInterval: 2)
        }
        return false
    }

    private func rereadVitalwalkPrerequisites() {
        guard let selected else { return }
        for uuid in ["2ACC", "2AD4", "2AD5"] {
            guard let characteristic = findCharacteristic(uuid: CBUUID(string: uuid), in: selected),
                  characteristic.properties.contains(.read)
            else { continue }
            logger.write("vitalwalk_probe.read_retry", [
                "characteristic": uuid,
                "service": characteristic.service?.uuid.uuidString ?? "unknown",
            ])
            readRequests.insert(characteristicKey(characteristic))
            selected.readValue(for: characteristic)
        }
    }

    private func promptVitalwalkDisplayUnit() -> VitalwalkDisplayUnit? {
        while true {
            print("Does the treadmill display speed in mph or km/h?")
            guard let input = readLine() else { return nil }
            if let unit = VitalwalkDisplayUnit.parse(input) { return unit }
            print("Enter mph or km/h.")
        }
    }

    private func promptRequiredDouble(_ prompt: String) -> Double? {
        while true {
            print(prompt)
            guard let input = readLine() else { return nil }
            if let value = Double(input.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite, value >= 0 {
                return value
            }
            print("Enter a non-negative number.")
        }
    }

    private func promptOptionalDouble(_ prompt: String) -> Double? {
        while true {
            print(prompt)
            guard let input = readLine() else { return nil }
            let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "unknown" || normalized.isEmpty { return nil }
            if let value = Double(normalized), value.isFinite, value >= 0 { return value }
            print("Enter a non-negative number or unknown.")
        }
    }

    private func promptRequiredText(_ prompt: String) -> String? {
        while true {
            print(prompt)
            guard let input = readLine() else { return nil }
            let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty { return normalized }
            print("Enter what you observed so it is recorded in the trace.")
        }
    }

    private func requireVitalwalkCommand(
        name: String,
        payload: Data,
        opcode: UInt8,
        fields: [String: Any] = [:]
    ) -> Bool {
        let result = sendVitalwalkCommand(name: name, payload: payload, opcode: opcode, fields: fields)
        recordVitalwalkCommandResult(result, fields: fields)
        if !result.succeeded {
            print("Command \(name) failed or timed out. The probe will stop safely.")
        }
        return result.succeeded
    }

    private func recordVitalwalkCommandResult(
        _ result: VitalwalkCommandResult,
        fields: [String: Any] = [:]
    ) {
        vitalwalkProbeState.commandResults.append(result.dictionary)
        logger.write(
            "vitalwalk_probe.command_result",
            result.dictionary.merging(fields) { current, _ in current }
        )
    }

    private func sendVitalwalkCommand(
        name: String,
        payload: Data,
        opcode: UInt8,
        fields: [String: Any] = [:],
        timeout: TimeInterval = 5
    ) -> VitalwalkCommandResult {
        var responseStart = 0
        var canSend = false
        DispatchQueue.main.sync {
            responseStart = r3ProbeState.controlPointResponses.count
            guard let selected, let controlPointCharacteristic else { return }
            canSend = true
            logger.write("vitalwalk_probe.tx", [
                "name": name,
                "requestOpcode": String(format: "0x%02X", opcode),
                "hex": payload.hexString,
                "fields": fields,
            ])
            selected.writeValue(payload, for: controlPointCharacteristic, type: .withResponse)
        }

        guard canSend else {
            return VitalwalkCommandResult(
                name: name,
                requestOpcode: opcode,
                resultCode: nil,
                responseHex: nil,
                timedOut: false
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var response: [String: Any]?
            DispatchQueue.main.sync {
                response = r3ProbeState.controlPointResponses
                    .dropFirst(responseStart)
                    .first { $0["requestOpcodeRaw"] as? UInt8 == opcode }
            }
            if let response {
                let resultCode = parseHexByte(response["resultCode"] as? String)
                if opcode == 0x00, resultCode == 0x01 {
                    DispatchQueue.main.sync { controlAcquired = true }
                }
                return VitalwalkCommandResult(
                    name: name,
                    requestOpcode: opcode,
                    resultCode: resultCode,
                    responseHex: response["hex"] as? String,
                    timedOut: false
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        return VitalwalkCommandResult(
            name: name,
            requestOpcode: opcode,
            resultCode: nil,
            responseHex: nil,
            timedOut: true
        )
    }

    private func parseHexByte(_ value: String?) -> UInt8? {
        guard let value else { return nil }
        return UInt8(value.replacingOccurrences(of: "0x", with: ""), radix: 16)
    }

    private func recordVitalwalkSpeedSample(
        rawTarget: Double,
        physicalDisplayValue: Double,
        unit: VitalwalkDisplayUnit,
        phase: String
    ) {
        let reportedSpeed = DispatchQueue.main.sync { latestStatus.speedKmh }
        let sample = VitalwalkSpeedSample(
            rawTarget: rawTarget,
            reportedSpeedKmh: reportedSpeed,
            physicalDisplayValue: physicalDisplayValue,
            physicalDisplayUnit: unit
        )
        let record = sample.dictionary.merging([
            "phase": phase,
            "snapshot": vitalwalkSnapshot(),
        ]) { current, _ in current }
        vitalwalkProbeState.speedSamples.append(record)
        logger.write("vitalwalk_probe.speed_sample", record)
    }

    private func runVitalwalkInclineTestIfAvailable() {
        guard let inclineRange,
              inclineRange.isSupported,
              inclineRange.incrementPercent > 0,
              (feature?.targetSettingFeatures ?? 0) & 0x0000_0002 != 0
        else {
            logger.write("vitalwalk_probe.incline", ["status": "unsupported_or_unknown"])
            return
        }

        print("")
        print("Incline support was reported as \(inclineRange.minimumPercent)...\(inclineRange.maximumPercent)% in \(inclineRange.incrementPercent)% steps.")
        print("Test one incline increment while the belt remains at minimum speed? Type yes or no:")
        guard readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "yes" else {
            logger.write("vitalwalk_probe.incline", ["status": "user_skipped"])
            return
        }

        let minimum = FTMSCommand.incline(requestedPercent: inclineRange.minimumPercent, range: inclineRange)
        let incremented = FTMSCommand.incline(
            requestedPercent: inclineRange.minimumPercent + inclineRange.incrementPercent,
            range: inclineRange
        )
        guard let minimum, let incremented,
              requireVitalwalkCommand(
                  name: "set_incline_minimum",
                  payload: minimum.payload,
                  opcode: minimum.requestOpcode,
                  fields: ["targetPercent": minimum.target ?? inclineRange.minimumPercent]
              ),
              requireVitalwalkCommand(
                  name: "set_incline_one_increment",
                  payload: incremented.payload,
                  opcode: incremented.requestOpcode,
                  fields: ["targetPercent": incremented.target ?? inclineRange.minimumPercent + inclineRange.incrementPercent]
              )
        else {
            logger.write("vitalwalk_probe.incline", ["status": "command_failed"])
            return
        }

        Thread.sleep(forTimeInterval: 5)
        let displayed = promptOptionalDouble("Displayed incline after one increment (number, or unknown):")
        let record: [String: Any] = [
            "status": "tested",
            "minimumPercent": inclineRange.minimumPercent,
            "incrementPercent": inclineRange.incrementPercent,
            "targetPercent": incremented.target ?? NSNull(),
            "physicalDisplayPercent": displayed ?? NSNull(),
            "snapshot": vitalwalkSnapshot(),
        ]
        vitalwalkProbeState.inclineObservation = record
        logger.write("vitalwalk_probe.incline", record)
        _ = requireVitalwalkCommand(
            name: "restore_incline_minimum",
            payload: minimum.payload,
            opcode: minimum.requestOpcode,
            fields: ["targetPercent": minimum.target ?? inclineRange.minimumPercent]
        )
    }

    private func vitalwalkSnapshot() -> [String: Any] {
        DispatchQueue.main.sync {
            [
                "speedKmh": latestStatus.speedKmh ?? NSNull(),
                "speedMph": latestStatus.speedKmh.map { $0 / 1.609_344 } ?? NSNull(),
                "distanceMeters": latestStatus.distanceMeters ?? NSNull(),
                "elapsedSeconds": latestStatus.elapsedSeconds ?? NSNull(),
                "inclinePercent": latestStatus.inclinePercent ?? NSNull(),
                "ftmsVendorField": latestStatus.ftmsVendorField ?? NSNull(),
                "fitshowSteps": latestStatus.fitshowSteps ?? NSNull(),
                "machineStatusOpcode": latestStatus.machineStatusOpcode ?? "unknown",
                "machineStatusParametersHex": latestStatus.machineStatusParametersHex ?? "unknown",
                "trainingStatus": latestStatus.trainingStatus ?? "unknown",
            ]
        }
    }

    private func waitForVitalwalkBeltToStop(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let speed = DispatchQueue.main.sync { latestStatus.speedKmh }
            if speed == 0 { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        logger.write("vitalwalk_probe.warning", [
            "reason": "belt_stop_not_observed",
            "snapshot": vitalwalkSnapshot(),
        ])
        return false
    }

    private func confirmVitalwalkBeltStoppedIfNeeded(telemetryStopped: Bool, context: String) -> Bool {
        guard !telemetryStopped else { return true }

        print("")
        print("TreadmillTrace could not verify zero belt speed from telemetry.")
        print("Use the physical stop control. Type STOPPED only after the belt is fully stopped \(context):")
        let confirmed = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) == "STOPPED"
        logger.write("vitalwalk_probe.physical_stop_confirmation", [
            "confirmed": confirmed,
            "context": context,
            "snapshot": vitalwalkSnapshot(),
        ])
        return confirmed
    }

    private func abortVitalwalkProbe(reason: String, attemptStop: Bool) {
        vitalwalkExitCode = 1
        vitalwalkProbeState.abortedReason = reason
        logger.write("vitalwalk_probe.aborted", [
            "reason": reason,
            "attemptStop": attemptStop,
            "snapshot": vitalwalkSnapshot(),
        ])
        if attemptStop {
            let result = sendVitalwalkCommand(
                name: "emergency_stop",
                payload: FTMSCommand.stop.payload,
                opcode: FTMSCommand.stop.requestOpcode,
                timeout: 3
            )
            recordVitalwalkCommandResult(result)
            let stopped = waitForVitalwalkBeltToStop(timeout: 8)
            _ = confirmVitalwalkBeltStoppedIfNeeded(
                telemetryStopped: stopped,
                context: "before the probe exits"
            )
        }
        vitalwalkMovementPossible = false
        finishVitalwalkProbe()
    }

    private func finishVitalwalkProbe() {
        let summary: [String: Any] = [
            "completed": vitalwalkProbeState.abortedReason == nil,
            "abortedReason": vitalwalkProbeState.abortedReason ?? NSNull(),
            "displayUnit": vitalwalkProbeState.displayUnit?.rawValue ?? "unknown",
            "targets": vitalwalkProbeState.targets.map {
                [
                    "minimumRaw": $0.minimumRaw,
                    "incrementRaw": $0.incrementRaw,
                    "incrementedRaw": $0.incrementedRaw,
                ]
            } ?? NSNull(),
            "commandResults": vitalwalkProbeState.commandResults,
            "speedSamples": vitalwalkProbeState.speedSamples,
            "inclineObservation": vitalwalkProbeState.inclineObservation ?? NSNull(),
            "pauseObservation": vitalwalkProbeState.pauseObservation ?? NSNull(),
            "resumeObservation": vitalwalkProbeState.resumeObservation ?? NSNull(),
            "finalDisplayValues": vitalwalkProbeState.finalDisplayValues,
            "finalSnapshot": vitalwalkSnapshot(),
        ]
        logger.write("vitalwalk_probe.summary", summary)

        print("")
        print("===== Vitalwalk Probe Report =====")
        print("Completed: \(vitalwalkProbeState.abortedReason == nil ? "yes" : "no")")
        if let reason = vitalwalkProbeState.abortedReason { print("Stopped because: \(reason)") }
        print("Speed samples captured: \(vitalwalkProbeState.speedSamples.count)")
        print("Pause observation captured: \(vitalwalkProbeState.pauseObservation != nil ? "yes" : "no")")
        print("Resume observation captured: \(vitalwalkProbeState.resumeObservation != nil ? "yes" : "no")")
        print("Log file: \(logger.path)")
        print("Send this JSONL file with the issue report.")
        print("==================================")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let selected {
                central.cancelPeripheralConnection(selected)
            } else {
                finish(vitalwalkProbeState.abortedReason == nil ? 0 : 1)
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

    private func attemptVitalwalkEmergencyStopFromMain(reason: String) {
        guard let selected, let controlPointCharacteristic else { return }
        let payload = FTMSCommand.stop.payload
        logger.write("vitalwalk_probe.emergency_stop", [
            "reason": reason,
            "hex": payload.hexString,
        ])
        selected.writeValue(payload, for: controlPointCharacteristic, type: .withResponse)
        vitalwalkMovementPossible = false
    }

    private func setupSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { exit(1) }
                print("\nInterrupted. Closing log...")
                if self.vitalwalkMovementPossible, case .vitalwalkProbe = self.mode {
                    self.attemptVitalwalkEmergencyStopFromMain(reason: "signal_\(signalNumber)")
                    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                        guard let self else { exit(1) }
                        self.logger.write("session.end", ["reason": "interrupted", "signal": signalNumber])
                        self.finish(1)
                    }
                } else {
                    self.logger.write("session.end", ["reason": "interrupted", "signal": signalNumber])
                    self.finish(1)
                }
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

    private func startTimeProbe() {
        discoveryTimeout?.invalidate()
        let hasTreadmillData = notifiedCharacteristics.contains { $0.hasSuffix("/2ACD") }
        guard hasTreadmillData else {
            logger.write("session.end", ["reason": "missing_2ACD_notification"])
            print("FTMS Treadmill Data notifications could not be enabled.")
            finish(1)
        }

        print("")
        print("Time diagnostic capture is ready.")
        print("Use only the treadmill remote or panel. The tool sends no control commands.")
        print("Follow each prompt and press return only after the requested state is visible.")
        print("")

        let steps = [
            CaptureStep(
                instruction: "Leave the treadmill idle, then press return to record 10 seconds.",
                fields: ["phase": "idle"],
                duration: 10
            ),
            CaptureStep(
                instruction: "Start a normal workout without a duration target. When its timer is running, press return to record 20 seconds.",
                fields: ["phase": "normal_workout", "expectedTimer": "count_up"],
                duration: 20
            ),
            CaptureStep(
                instruction: "Stop the treadmill and wait for the belt to stop, then press return to record 10 seconds.",
                fields: ["phase": "between_workouts"],
                duration: 10
            ),
            CaptureStep(
                instruction: "Configure a duration target, start the workout, and wait for its countdown to begin. Then press return to record 20 seconds.",
                fields: ["phase": "countdown_workout", "expectedTimer": "count_down"],
                duration: 20
            ),
            CaptureStep(
                instruction: "Stop the treadmill and wait for the belt to stop, then press return to record 10 seconds.",
                fields: ["phase": "final_stop"],
                duration: 10
            ),
        ]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for step in steps {
                self.run(step: step)
            }

            DispatchQueue.main.async {
                self.logCaptureQuality()
                self.logger.write("time_probe.finished", ["phaseCount": steps.count])
                print("")
                print("Capture complete.")
                print("Send this file with your report:")
                print(self.logger.path)
                print("")
                if let selected = self.selected {
                    self.central.cancelPeripheralConnection(selected)
                } else {
                    self.finish(0)
                }
            }
        }
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
        let phaseFields = currentPhase?.fields ?? [:]
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

        let summary: [String: Any] = [
            "phaseId": phaseId,
            "treadmillDataPackets": stats.treadmillDataPackets,
            "nonzeroSpeedSamples": stats.nonzeroSpeedSamples,
            "firstSpeedKmh": stats.firstSpeedKmh ?? NSNull(),
            "lastSpeedKmh": stats.lastSpeedKmh ?? NSNull(),
            "firstDistanceMeters": stats.firstDistanceMeters ?? NSNull(),
            "lastDistanceMeters": stats.lastDistanceMeters ?? NSNull(),
            "distanceIncreased": distanceIncreased,
            "firstElapsedTimeSeconds": stats.firstElapsedTimeSeconds ?? NSNull(),
            "lastElapsedTimeSeconds": stats.lastElapsedTimeSeconds ?? NSNull(),
            "elapsedTimeTrend": timeTrend(first: stats.firstElapsedTimeSeconds, last: stats.lastElapsedTimeSeconds),
            "elapsedTimeIncreased": elapsedIncreased,
            "firstRemainingTimeSeconds": stats.firstRemainingTimeSeconds ?? NSNull(),
            "lastRemainingTimeSeconds": stats.lastRemainingTimeSeconds ?? NSNull(),
            "remainingTimeTrend": timeTrend(first: stats.firstRemainingTimeSeconds, last: stats.lastRemainingTimeSeconds),
            "treadmillDataFlags": Array(stats.treadmillDataFlags).sorted(),
            "machineStatusOpcodes": Array(stats.machineStatusOpcodes).sorted(),
            "hasEnoughSamples": stats.treadmillDataPackets >= minimumPhaseSamples,
        ]
        return phaseFields.merging(summary) { _, summaryValue in summaryValue }
    }

    private func timeTrend(first: UInt16?, last: UInt16?) -> String {
        guard let first, let last else { return "absent" }
        if last > first { return "increasing" }
        if last < first { return "decreasing" }
        return "unchanged"
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
            let opcode = data.first
            let parameters = data.count > 1 ? Data(data.dropFirst()).hexString : ""
            return [
                "machineStatusOpcode": opcode.map { String(format: "0x%02X", $0) } ?? "none",
                "machineStatusName": opcode.map(machineStatusName) ?? "none",
                "machineStatusParametersHex": parameters,
            ]
        case CBUUID(string: "2AD3"):
            let status = data.count >= 2 ? data[1] : data.first
            return [
                "trainingStatusFlags": data.first.map { String(format: "0x%02X", $0) } ?? "none",
                "trainingStatusRaw": status.map { String(format: "0x%02X", $0) } ?? "none",
                "trainingStatus": status.map(trainingStatusName) ?? "none",
            ]
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

    private func machineStatusName(_ opcode: UInt8) -> String {
        switch opcode {
        case 0x01: "reset"
        case 0x02: "stoppedOrPausedByUser"
        case 0x03: "stoppedBySafetyKey"
        case 0x04: "startedOrResumedByUser"
        case 0x05: "targetSpeedChanged"
        case 0x06: "targetInclineChanged"
        default: "other"
        }
    }

    private func trainingStatusName(_ status: UInt8) -> String {
        switch status {
        case 0x00: "other"
        case 0x01: "idle"
        case 0x02: "warmingUp"
        case 0x0D: "preWorkout"
        case 0x0E: "postWorkout"
        case 0x0F: "paused"
        default: "status_\(String(format: "%02X", status))"
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
        case let .unknown(key):
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
        let baseline = lastCommandedSpeedKmh ?? speedRange.minimumKmh
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
