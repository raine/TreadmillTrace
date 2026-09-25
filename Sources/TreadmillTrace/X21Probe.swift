import CoreBluetooth
import Foundation

/// Runs the X21 handshake, idle polling, guided passive observation, and optional armed
/// control validation. BLE state is owned by the main queue; prompts run on a background queue.
final class X21ProbeSession {
    static let firstWriteDelay: TimeInterval = 0.4
    static let chunkSpacing: TimeInterval = 0.12
    static let commandSpacing: TimeInterval = 0.15
    static let responseTimeout: TimeInterval = 3
    static let pollInterval: TimeInterval = 1
    static let maximumMissedPolls = 3
    static let previousFailureWindow: TimeInterval = 2.1
    static let statusFreshness: TimeInterval = 3

    private struct Phase {
        let id: String
        let instruction: String
        let duration: TimeInterval
        let displayPrompt: String?
    }

    private static let lowSpeedPhase = "start_lowest_speed"
    private static let speedChangePhase = "speed_change"

    private static let phases = [
        Phase(
            id: "idle",
            instruction: "Leave the treadmill stopped and idle.",
            duration: 10,
            displayPrompt: nil
        ),
        Phase(
            id: lowSpeedPhase,
            instruction: "Using only the treadmill panel or remote, start the belt at its lowest speed. Walk on it only if you are comfortable doing so.",
            duration: 20,
            displayPrompt: "Enter the speed shown on the treadmill display, including the unit if shown:"
        ),
        Phase(
            id: speedChangePhase,
            instruction: "Using only the panel or remote, raise the speed by one step and wait for the display to settle.",
            duration: 20,
            displayPrompt: "Enter the displayed speed, steps, distance, time, and calories exactly as shown:"
        ),
        Phase(
            id: "stopped",
            instruction: "Using only the panel or remote, stop the belt and wait until it has fully stopped.",
            duration: 15,
            displayPrompt: "Enter the displayed steps, distance, time, and calories after stopping, or unknown:"
        ),
    ]

    fileprivate let logger: TraceLogger
    private let peripheral: CBPeripheral
    private let writeCharacteristic: CBCharacteristic
    private let table = X21SubstitutionTable.x21V4
    private let subscribedAt: Date
    private let onEnded: (X21ProbeFailure?) -> Void

    private var machine = X21ProbeMachine()
    private var buffer = X21FrameBuffer()
    private var generation = 0
    fileprivate var writing = false
    private var queuedFrames: [Data] = []
    private var commandStartedAt: Date?
    private var lastWriteAt: Date?
    private var firstWriteAt: Date?
    fileprivate var pollOutstanding = false
    private var missedPolls = 0
    private var pollTimer: Timer?
    private var notificationChunks = 0
    private var decodedFrames = 0
    private var decodeFailures = 0
    private var currentPhase: String?
    private var phaseSamples: [String: [[String: Any]]] = [:]
    private var phaseDisplays: [String: String] = [:]
    private var completedPhases: [String] = []
    fileprivate var status: [String: String] = [:]
    fileprivate var statusUpdatedAt: Date?
    private var validated = false
    private var exitedEarly = false
    private var control: [String: Any] = ["offered": false]
    private var controlSteps: [[String: Any]] = []
    private var controlAbortReason: String?
    fileprivate(set) var movementPossible = false
    private(set) var ended = false

    init(
        logger: TraceLogger,
        peripheral: CBPeripheral,
        writeCharacteristic: CBCharacteristic,
        subscribedAt: Date,
        onEnded: @escaping (X21ProbeFailure?) -> Void
    ) {
        self.logger = logger
        self.peripheral = peripheral
        self.writeCharacteristic = writeCharacteristic
        self.subscribedAt = subscribedAt
        self.onEnded = onEnded
    }

    func start() {
        print("Notifications enabled. Starting the X21 handshake with table \(table.id)...")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstWriteDelay) { [weak self] in
            guard let self, !ended else { return }
            send(machine.start(unixTime: Int(Date().timeIntervalSince1970)))
        }
    }

    func receive(_ chunk: Data) {
        notificationChunks += 1
        logger.write("x21_probe.rx_chunk", [
            "hex": chunk.hexString,
            "length": chunk.count,
            "msSinceLastWrite": milliseconds(since: lastWriteAt) ?? NSNull(),
            "msSinceSubscription": milliseconds(since: subscribedAt) ?? NSNull(),
        ])
        guard let frames = buffer.append(chunk) else {
            end(.frameOverflow)
            return
        }
        for frame in frames {
            if writing {
                queuedFrames.append(frame)
            } else {
                handle(frame)
            }
        }
    }

    func peripheralDisconnected(error: Error?) {
        logger.write("x21_probe.disconnect", [
            "error": error?.localizedDescription ?? "none",
            "secondsSinceSubscription": Date().timeIntervalSince(subscribedAt),
            "phase": currentPhase ?? NSNull(),
            "movementPossible": movementPossible,
        ])
        if movementPossible {
            print("Connection lost while the belt may be moving. Use the physical stop control now.")
        }
        end(.disconnected(error?.localizedDescription ?? "none"))
    }

    /// Sends Stop immediately from the main queue, for interruption while the belt may move.
    func emergencyStop(reason: String) {
        guard movementPossible, peripheral.state == .connected else { return }
        logger.write("x21_probe.emergency_stop", ["reason": reason])
        // A lone terminator closes any partially written frame so Stop is parsed on its own.
        generation += 1
        peripheral.writeValue(Data([X21Codec.terminator]), for: writeCharacteristic, type: .withoutResponse)
        send(name: X21ControlCommand.stop.name, plaintext: X21ControlCommand.stop.plaintext, awaitsResponse: false)
    }

    // MARK: Writes

    private func send(_ command: X21SafeCommand) {
        send(name: command.name, plaintext: command.plaintext, awaitsResponse: true)
    }

    fileprivate func send(name: String, plaintext: String, awaitsResponse: Bool) {
        guard !ended else { return }
        generation += 1
        writing = true
        let now = Date()
        commandStartedAt = now
        if firstWriteAt == nil { firstWriteAt = now }
        let encoded = X21Codec.encode(plaintext, table: table)
        let chunks = X21Codec.chunks(encoded)
        logger.write("x21_probe.tx", [
            "command": name,
            "plaintext": plaintext,
            "table": table.id,
            "encodedHex": encoded.hexString,
            "chunkCount": chunks.count,
            "chunks": chunks.map(\.hexString),
            "phase": currentPhase ?? NSNull(),
            "msSinceSubscription": milliseconds(since: subscribedAt) ?? NSNull(),
        ])
        writeChunk(chunks, index: 0, name: name, awaitsResponse: awaitsResponse, attempts: 0, generation: generation)
    }

    private func writeChunk(
        _ chunks: [Data],
        index: Int,
        name: String,
        awaitsResponse: Bool,
        attempts: Int,
        generation: Int
    ) {
        guard !ended, generation == self.generation else { return }
        guard peripheral.state == .connected else {
            end(.writeFailed("peripheral not connected"))
            return
        }
        guard peripheral.canSendWriteWithoutResponse else {
            guard attempts < 20 else {
                end(.writeFailed("write without response not ready for \(name)"))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.writeChunk(chunks, index: index, name: name, awaitsResponse: awaitsResponse, attempts: attempts + 1, generation: generation)
            }
            return
        }

        peripheral.writeValue(chunks[index], for: writeCharacteristic, type: .withoutResponse)
        lastWriteAt = Date()
        logger.write("x21_probe.tx_chunk", [
            "command": name,
            "index": index,
            "count": chunks.count,
            "hex": chunks[index].hexString,
            "readinessRetries": attempts,
            "msSinceCommandStart": milliseconds(since: commandStartedAt) ?? NSNull(),
        ])

        if index + 1 < chunks.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.chunkSpacing) { [weak self] in
                self?.writeChunk(chunks, index: index + 1, name: name, awaitsResponse: awaitsResponse, attempts: 0, generation: generation)
            }
            return
        }

        writing = false
        if awaitsResponse {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.responseTimeout) { [weak self] in
                guard let self, !ended, generation == self.generation else { return }
                responseTimedOut(name)
            }
        }
        let frames = queuedFrames
        queuedFrames = []
        frames.forEach(handle)
    }

    private func responseTimedOut(_ name: String) {
        logger.write("x21_probe.response_timeout", [
            "command": name,
            "timeoutSeconds": Self.responseTimeout,
            "phase": currentPhase ?? NSNull(),
        ])
        guard validated else {
            _ = machine.fail(.timeout(command: name))
            end(.timeout(command: name))
            return
        }
        pollOutstanding = false
        missedPolls += 1
        if missedPolls >= Self.maximumMissedPolls {
            end(.statusStale)
        }
    }

    // MARK: Responses

    private func handle(_ frame: Data) {
        let latency: Any = milliseconds(since: lastWriteAt) ?? NSNull()
        let event: X21ProbeEvent
        switch X21Codec.decodeBytes(frame, table: table) {
        case let .failure(category):
            decodeFailures += 1
            logger.write("x21_probe.rx_frame", [
                "hex": frame.hexString,
                "table": table.id,
                "decodeFailure": category.rawValue,
                "phase": currentPhase ?? NSNull(),
                "msSinceLastWrite": latency,
            ])
            event = machine.decodeFailed(category)
        case let .success(decoded):
            decodedFrames += 1
            let awaiting = machine.awaitingCommand?.name ?? "none"
            event = machine.receive(decoded)
            let text = String(data: decoded, encoding: .utf8)
            var record: [String: Any] = [
                "hex": frame.hexString,
                "decodedHex": decoded.hexString,
                "table": table.id,
                "text": text ?? NSNull(),
                "awaiting": awaiting,
                "result": describe(event),
                "phase": currentPhase ?? NSNull(),
                "msSinceLastWrite": latency,
            ]
            if let text, let properties = X21PropertyMessage.parse(text) {
                record["properties"] = properties.dictionary
            }
            logger.write("x21_probe.rx_frame", record)
        }
        apply(event)
    }

    private func apply(_ event: X21ProbeEvent) {
        switch event {
        case let .advance(command):
            generation += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandSpacing) { [weak self] in
                self?.send(command)
            }
        case .validated:
            generation += 1
            validated = true
            machine.propertyMessages.forEach(updateStatus)
            logger.write("x21_probe.validated", [
                "table": table.id,
                "secondsSinceSubscription": Date().timeIntervalSince(subscribedAt),
                "idleProperties": machine.propertyMessages.map(\.dictionary),
            ])
            print("Idle status: \(statusLine())")
            startObservation()
        case let .pollAnswered(properties):
            generation += 1
            pollOutstanding = false
            missedPolls = 0
            updateStatus(properties)
            if let currentPhase {
                var sample = properties.dictionary
                sample["secondsSinceSubscription"] = Date().timeIntervalSince(subscribedAt)
                phaseSamples[currentPhase, default: []].append(sample)
            }
        case .waiting, .ignored:
            break
        case let .failed(failure):
            end(failure)
        }
    }

    private func updateStatus(_ message: X21PropertyMessage) {
        guard message.hasStatusField else { return }
        for property in message.properties {
            status[property.key] = property.value
        }
        statusUpdatedAt = Date()
    }

    // MARK: Passive observation

    private func startObservation() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            guard let self, !ended, !writing, !pollOutstanding else { return }
            pollOutstanding = true
            send(.shortPropertyQuery)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runGuidedProbe()
        }
    }

    private func runGuidedProbe() {
        guard runPassivePhases() else {
            finishSession()
            return
        }
        runControlValidation()
        finishSession()
    }

    /// Returns true when every passive phase completed.
    private func runPassivePhases() -> Bool {
        print("")
        print("X21 protocol validated. Guided passive observation")
        print("During these phases TreadmillTrace sends only property queries. It does not start, stop, or change the belt.")
        print("Use only the treadmill panel or remote. Keep the physical stop control within reach.")
        print("Type q and press return at any prompt to finish early. The log is kept either way.")

        for phase in Self.phases {
            print("")
            print("[\(phase.id)] \(phase.instruction)")
            print("Press return when ready to record \(Int(phase.duration)) seconds, or q to finish:")
            guard let input = readLine(), !isQuit(input) else {
                markExitedEarly()
                return false
            }
            guard beginPhase(phase) else { return false }
            Thread.sleep(forTimeInterval: phase.duration)
            var display: String?
            if let prompt = phase.displayPrompt {
                print(prompt)
                display = readLine()
                if display == nil || isQuit(display!) {
                    endPhase(phase, display: nil)
                    markExitedEarly()
                    return false
                }
            }
            guard endPhase(phase, display: display) else { return false }
        }
        return true
    }

    private func beginPhase(_ phase: Phase) -> Bool {
        DispatchQueue.main.sync {
            guard !ended else { return false }
            currentPhase = phase.id
            logger.write("x21_probe.phase_start", ["phase": phase.id, "instruction": phase.instruction])
            print("Recording \(phase.id)...")
            return true
        }
    }

    @discardableResult
    private func endPhase(_ phase: Phase, display: String?) -> Bool {
        DispatchQueue.main.sync {
            guard !ended else { return false }
            let samples = phaseSamples[phase.id] ?? []
            if let display { phaseDisplays[phase.id] = display }
            logger.write("x21_probe.phase_end", [
                "phase": phase.id,
                "sampleCount": samples.count,
                "first": samples.first ?? NSNull(),
                "last": samples.last ?? NSNull(),
                "display": display ?? NSNull(),
            ])
            completedPhases.append(phase.id)
            currentPhase = nil
            print("Recorded \(samples.count) samples. Last status: \(statusLine())")
            return true
        }
    }

    private func phaseSpeeds(_ phase: String) -> [Double] {
        (phaseSamples[phase] ?? []).compactMap { ($0["known"] as? [String: Any])?["CurrentSpeed"] as? Double }
    }

    // MARK: Control validation

    private func runControlValidation() {
        let plan = DispatchQueue.main.sync {
            X21ControlPlan.make(
                lowPhaseSpeeds: phaseSpeeds(Self.lowSpeedPhase),
                changePhaseSpeeds: phaseSpeeds(Self.speedChangePhase)
            )
        }
        guard let plan else {
            print("")
            print("Control validation is unavailable: the passive capture did not report a nonzero speed of at most \(X21ControlCommand.formatSpeed(X21ControlPlan.maximumLowSpeedKmh)) km/h.")
            let fields: [String: Any] = ["offered": false, "unavailableReason": "no_safe_low_speed_observed"]
            DispatchQueue.main.sync { control = fields }
            logger.write("x21_probe.control_result", fields)
            return
        }
        let runner = X21ControlRunner(plan: plan, driver: self)
        runner.run()
        DispatchQueue.main.sync {
            control = runner.result
            controlSteps = runner.steps
            controlAbortReason = runner.abortReason
        }
    }

    // MARK: Completion

    private func markExitedEarly() {
        DispatchQueue.main.sync { exitedEarly = true }
    }

    private func finishSession() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            end(controlAbortReason.map(X21ProbeFailure.controlAborted))
        }
    }

    private func end(_ failure: X21ProbeFailure?) {
        guard !ended else { return }
        ended = true
        generation += 1
        pollTimer?.invalidate()
        pollTimer = nil

        let connectedSeconds = Date().timeIntervalSince(subscribedAt)
        let lastStatus = machine.propertyMessages.last { $0.hasStatusField }
        logger.write("x21_probe.summary", [
            "table": table.id,
            "succeeded": failure == nil,
            "failure": failure?.reason ?? NSNull(),
            "protocolValidated": validated,
            "passive": [
                "completed": completedPhases.count == Self.phases.count,
                "exitedEarly": exitedEarly,
                "completedPhases": completedPhases,
                "interruptedPhase": currentPhase ?? NSNull(),
                "displayObservations": phaseDisplays,
                "phaseSampleCounts": phaseSamples.mapValues(\.count),
            ],
            "control": control.merging(["steps": controlSteps]) { current, _ in current },
            "movementPossibleAtEnd": movementPossible,
            "criteria": [
                "remainedConnectedPastPreviousFailureWindow": connectedSeconds > Self.previousFailureWindow,
                "notificationReceived": notificationChunks > 0,
                "decodedWithKnownTable": decodedFrames > 0,
                "handshakeReachedProperties": validated,
                "statusPropertyReturned": lastStatus != nil,
            ],
            "notificationChunks": notificationChunks,
            "decodedFrames": decodedFrames,
            "decodeFailures": decodeFailures,
            "propertyMessages": machine.propertyMessages.count,
            "lastStatus": status,
            "secondsSinceSubscription": connectedSeconds,
            "msSubscriptionToFirstWrite": firstWriteAt.map { $0.timeIntervalSince(subscribedAt) * 1000 } ?? NSNull(),
        ])

        print("")
        print("===== X21 Probe Report =====")
        print("Substitution table: \(table.id)")
        print("Protocol validated: \(validated ? "yes" : "no")")
        if let failure { print("Stopped because: \(failure.reason)") }
        if validated {
            print("Passive phases: \(completedPhases.isEmpty ? "none" : completedPhases.joined(separator: ", "))")
            if exitedEarly { print("Passive observation finished early.") }
            print("Control validation: \(controlOutcome())")
        }
        if movementPossible {
            print("WARNING: the belt was not confirmed stopped. Use the physical stop control.")
        }
        print("Notifications: \(notificationChunks), decoded frames: \(decodedFrames), decode failures: \(decodeFailures)")
        print("Log file: \(logger.path)")
        print("Send this JSONL file with the issue report.")
        print("============================")
        onEnded(failure)
    }

    private func controlOutcome() -> String {
        if let controlAbortReason { return "failed (\(controlAbortReason))" }
        if control["completed"] as? Bool == true { return "completed" }
        if control["declined"] as? Bool == true { return "skipped" }
        if control["offered"] as? Bool == false, control["unavailableReason"] != nil { return "unavailable" }
        return "not run"
    }

    private func statusLine() -> String {
        let mode = status["ControlMode"].map { "\($0) (\(X21PropertyMessage.controlModeName($0)))" } ?? "?"
        let state = status["runState"].map { "\($0) (\(X21PropertyMessage.runStateName($0)))" } ?? "?"
        return "speed=\(status["CurrentSpeed"] ?? "?") mode=\(mode) runState=\(state) steps=\(status["RunningSteps"] ?? "?") distance=\(status["RunningDistance"] ?? "?") time=\(status["RunningTotalTime"] ?? "?")"
    }

    private func isQuit(_ input: String) -> Bool {
        input.trimmingCharacters(in: .whitespaces).lowercased() == "q"
    }

    private func describe(_ event: X21ProbeEvent) -> String {
        switch event {
        case let .advance(command): "accepted, next \(command.name)"
        case .validated: "validated"
        case .pollAnswered: "poll_answered"
        case .waiting: "waiting"
        case .ignored: "ignored"
        case let .failed(failure): "failed: \(failure.reason)"
        }
    }

    private func milliseconds(since date: Date?) -> Double? {
        date.map { (Date().timeIntervalSince($0) * 1000).rounded() }
    }
}

extension X21ProbeSession: X21ControlDriver {
    /// Waits for idle transmit capacity so control frames never interleave with status queries.
    func send(_ command: X21ControlCommand) -> Date? {
        while true {
            let result: (sent: Bool, stop: Bool) = DispatchQueue.main.sync {
                guard !ended else { return (false, true) }
                guard !writing else { return (false, false) }
                pollOutstanding = false
                send(name: command.name, plaintext: command.plaintext, awaitsResponse: false)
                return (true, false)
            }
            if result.stop { return nil }
            if result.sent { return Date() }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func waitForStatus(
        since: Date,
        timeout: TimeInterval,
        plan: X21ControlPlan,
        expect: ([String: String]) -> Bool
    ) -> Date? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot: (status: [String: String], updatedAt: Date?, ended: Bool) = DispatchQueue.main.sync {
                (status, statusUpdatedAt, ended)
            }
            if snapshot.ended { return nil }
            if let updatedAt = snapshot.updatedAt, updatedAt > since {
                if let state = snapshot.status["runState"], !["0", "1", "5", "9"].contains(state) {
                    logger.write("x21_probe.control_unexpected_state", ["status": snapshot.status])
                    return nil
                }
                if let speed = snapshot.status["CurrentSpeed"].flatMap(Double.init),
                   speed > plan.maximumKmh + X21ControlPlan.tolerance
                {
                    logger.write("x21_probe.control_speed_exceeded", ["status": snapshot.status, "maximumKmh": plan.maximumKmh])
                    return nil
                }
                if expect(snapshot.status) { return updatedAt }
            }
            if let updatedAt = snapshot.updatedAt, Date().timeIntervalSince(updatedAt) > Self.statusFreshness,
               Date().timeIntervalSince(since) > Self.statusFreshness
            {
                logger.write("x21_probe.control_status_stale", ["secondsSinceUpdate": Date().timeIntervalSince(updatedAt)])
                return nil
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    func currentStatus() -> [String: String] {
        DispatchQueue.main.sync { status }
    }

    func ask(_ prompt: String) -> String? {
        print(prompt)
        return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func say(_ message: String) {
        print(message)
    }

    func log(_ event: String, _ fields: [String: Any]) {
        logger.write(event, fields)
    }

    func setMovementPossible(_ value: Bool) {
        DispatchQueue.main.sync { movementPossible = value }
    }
}
