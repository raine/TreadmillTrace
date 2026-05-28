import CoreBluetooth
import Darwin
import Foundation

@main
struct TreadmillTrace {
    static func main() {
        let arguments = Arguments.parse(CommandLine.arguments.dropFirst())
        let logger = TraceLogger(outputPath: arguments.outputPath)
        let capture = BLECapture(logger: logger, scanSeconds: arguments.scanSeconds, probeMode: arguments.probeMode)
        capture.run()
    }
}

struct Arguments {
    var outputPath: String?
    var scanSeconds: TimeInterval = 12
    var probeMode = false

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
            case "--probe":
                result.probeMode = true
            case "--help", "-h":
                print("""
                TreadmillTrace captures raw BLE treadmill data on macOS.

                Usage:
                  treadmill-trace [--output path] [--scan-seconds 12] [--probe]

                The tool scans for nearby BLE devices, lets you choose one, connects,
                discovers services and characteristics, subscribes to notify/indicate
                characteristics, and writes JSON Lines trace events.

                --probe starts a live FTMS control probe after setup. It shows
                real-time stats and requires pressing a before control writes.
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
    private let probeMode: Bool
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

    init(logger: TraceLogger, scanSeconds: TimeInterval, probeMode: Bool) {
        self.logger = logger
        self.scanSeconds = scanSeconds
        self.probeMode = probeMode
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
            if characteristic.uuid == CBUUID(string: "2AD9") {
                controlPointCharacteristic = characteristic
            }

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

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        logger.write(error == nil ? "ble.tx_result" : "ble.tx_error", [
            "service": characteristic.service?.uuid.uuidString ?? "unknown",
            "characteristic": characteristic.uuid.uuidString,
            "error": error?.localizedDescription ?? "none",
            "pendingCommand": pendingCommand?.name ?? "none",
        ])
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
            if self.probeMode {
                self.startProbeMode()
            } else {
                self.printCaptureInstructions()
            }
        }
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
        return services.contains(ftms) || serviceData[ftms] != nil || lowerName.contains("tread") || lowerName.contains("walk") || lowerName.contains("vital")
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

    private func startProbeMode() {
        discoveryTimeout?.invalidate()
        print("")
        logger.write("probe.start", ["armed": probeArmed])
        guard enableRawTerminalMode() else {
            logger.write("session.end", ["reason": "terminal_raw_mode_failed"])
            print("Could not enable terminal control mode.")
            finish(1)
        }
        print("\u{001B}[?25l", terminator: "")
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
            var sequence = [UInt8](repeating: 0, count: 2)
            guard read(STDIN_FILENO, &sequence, 2) == 2, sequence[0] == 0x5B else {
                return .unknown("escape")
            }
            switch sequence[1] {
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
        print("TreadmillTrace probe")
        print("Log: \(logger.path)")
        print("Stand off the belt and keep the stop control reachable before arming.")
        print("")
        print("Speed:      \(latestStatus.speedKmh.map { "\(format($0)) km/h" } ?? "unknown")")
        print("Commanded:  \(lastCommandedSpeedKmh.map { "\(format($0)) km/h" } ?? "unknown")")
        print("Distance:   \(latestStatus.distanceMeters.map { "\($0) m" } ?? "unknown")")
        print("Time:       \(latestStatus.elapsedSeconds.map(formatElapsed) ?? "unknown")")
        print("Incline:    \(latestStatus.inclinePercent.map { "\(format($0))%" } ?? "unknown")")
        print("Steps:      \(latestStatus.fitshowSteps.map(String.init) ?? latestStatus.ftmsVendorField.map(String.init) ?? "unknown")")
        print("Status:     \(latestStatus.machineStatusOpcode ?? "unknown")")
        print("Armed:      \(probeArmed ? "yes" : "no")")
        print("Pending:    \(pendingCommand?.name ?? "none")")
        print("")
        print("Controls:")
        print("  a arm     r request control     space start     s stop     q quit")
        print("  up/down speed +/- range increment     left/right incline -/+ range increment")
        print("")
        print("Message: \(probeMessage)")
        fflush(stdout)
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
        if let selected {
            central.cancelPeripheralConnection(selected)
        } else {
            finish(0)
        }
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
                if pending.name == "speed" {
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
