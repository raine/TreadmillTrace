import Foundation

/// Transport and operator I/O used by `X21ControlRunner`. Calls may block.
protocol X21ControlDriver: AnyObject {
    /// Sends a command after any in-flight frame, returning the send time, or nil when the session ended.
    func send(_ command: X21ControlCommand) -> Date?
    /// Returns the time of a status update newer than `since` that satisfies `expect`, or nil on timeout,
    /// stale status, unknown run state, speed above `plan`, or session end.
    func waitForStatus(
        since: Date,
        timeout: TimeInterval,
        plan: X21ControlPlan,
        expect: ([String: String]) -> Bool
    ) -> Date?
    func currentStatus() -> [String: String]
    /// Returns a trimmed line, or nil when input is closed.
    func ask(_ prompt: String) -> String?
    func say(_ message: String)
    func log(_ event: String, _ fields: [String: Any])
    func setMovementPossible(_ value: Bool)
}

/// Armed control validation. Only an explicit operator confirmation that the belt has
/// physically stopped clears the movement-possible state.
///
/// Command order follows the start sequence reported for this protocol family: manual mode,
/// then Start, then the speed target. Setting a speed before Start is not established for the
/// X21, and the treadmill chooses its own start speed. Status is checked after every command,
/// and any reported speed above the plan triggers Stop. This limits exposure but does not
/// prevent the belt from briefly running at the treadmill's own start speed.
final class X21ControlRunner {
    static let armingPhrase = "RUN X21 CONTROL PROBE"
    static let stopAttempts = 3

    private let plan: X21ControlPlan
    private let driver: X21ControlDriver
    private(set) var steps: [[String: Any]] = []
    private(set) var result: [String: Any] = [:]
    private(set) var abortReason: String?
    private(set) var movementPossible = false {
        didSet { driver.setMovementPossible(movementPossible) }
    }

    init(plan: X21ControlPlan, driver: X21ControlDriver) {
        self.plan = plan
        self.driver = driver
    }

    static func isStopped(_ status: [String: String]) -> Bool {
        status["runState"] == "0" && status["CurrentSpeed"].flatMap(Double.init) == 0
    }

    func run() {
        var base: [String: Any] = ["offered": true, "plan": planDictionary]

        driver.say("")
        driver.say("OPTIONAL CONTROL VALIDATION")
        driver.say("TreadmillTrace can now send movement commands in this order:")
        driver.say(sequenceDescription)
        driver.say("The speeds are the lowest and next speeds the treadmill reported during the passive capture.")
        driver.say("The treadmill chooses its own speed when Start is sent. If it reports a speed above \(X21ControlCommand.formatSpeed(plan.maximumKmh)), the probe sends Stop.")
        driver.say("The belt WILL move. Pause and incline are not tested.")
        guard isYes(driver.ask("Type yes to continue, or press return to skip and keep the passive results:")) else {
            finish(base.merging(["declined": true, "declinedAt": "offer"]) { $1 })
            driver.say("Control validation skipped.")
            return
        }

        driver.say("")
        driver.say("SAFETY CHECK")
        driver.say("Stand off the belt, keep the physical stop control reachable, and keep the treadmill clear.")
        driver.say("The probe sends Stop on failure, timeout, interruption, and normal completion.")
        guard isYes(driver.ask("Confirm the belt is fully stopped. Type yes:")) else {
            finish(base.merging(["declined": true, "declinedAt": "stopped_confirmation"]) { $1 })
            return
        }
        guard driver.waitForStatus(since: Date(), timeout: 5, plan: plan, expect: Self.isStopped) != nil else {
            abortReason = "not_stopped_or_status_stale"
            driver.say("Control validation not armed: the treadmill did not report a fresh stopped status.")
            finish(base.merging(["armed": false, "completed": false, "abortedReason": abortReason!]) { $1 })
            return
        }
        guard driver.ask("Type \(Self.armingPhrase) exactly to arm control commands:") == Self.armingPhrase else {
            finish(base.merging(["declined": true, "declinedAt": "arming_phrase"]) { $1 })
            driver.say("Control validation not armed.")
            return
        }

        base["armed"] = true
        movementPossible = true
        driver.log("x21_probe.control_armed", ["plan": planDictionary])
        let observation = runSequence()
        stopAndConfirm(base: base.merging(observation) { $1 })
    }

    /// Runs the movement commands up to, but not including, Stop. Sets `abortReason` on failure.
    private func runSequence() -> [String: Any] {
        if driver.currentStatus()["ControlMode"] != "1" {
            guard step(.manualMode, timeout: 5, expect: { $0["ControlMode"] == "1" }) else {
                return abort("manual_mode_not_confirmed")
            }
        }
        guard step(.start, timeout: 10, expect: { $0["runState"] == "1" }) else {
            return abort("start_not_confirmed")
        }
        guard step(.speed(plan.lowKmh), timeout: 10, expect: matchesSpeed(plan.lowKmh)) else {
            return abort("low_speed_not_confirmed")
        }
        let answer = driver.ask("Is the belt physically moving at \(X21ControlCommand.formatSpeed(plan.lowKmh))? Enter yes or no:")
        let moved = isYes(answer)
        driver.log("x21_probe.control_observation", [
            "physicalMovement": answer.map { _ in moved } ?? NSNull(),
            "targetKmh": plan.lowKmh,
        ])
        guard moved else {
            var fields = abort(answer == nil ? "movement_observation_missing" : "no_physical_movement_at_low_speed")
            fields["physicalMovementObserved"] = answer.map { _ in false } ?? NSNull()
            return fields
        }
        if let changed = plan.changedKmh {
            guard step(.speed(changed), timeout: 10, expect: matchesSpeed(changed)) else {
                var fields = abort("speed_change_not_confirmed")
                fields["physicalMovementObserved"] = true
                return fields
            }
        }
        return ["physicalMovementObserved": true]
    }

    private func abort(_ reason: String) -> [String: Any] {
        abortReason = reason
        driver.say("Control validation stopped: \(reason)")
        return [:]
    }

    /// Sends Stop until the treadmill reports it, then requires the operator to confirm the
    /// belt has physically stopped. Movement stays possible until that confirmation.
    private func stopAndConfirm(base: [String: Any]) {
        var stopConfirmedByStatus = false
        for _ in 1 ... Self.stopAttempts where !stopConfirmedByStatus {
            stopConfirmedByStatus = step(.stop, timeout: 15, expect: Self.isStopped)
        }
        if !stopConfirmedByStatus {
            if abortReason == nil { abortReason = "stop_not_confirmed" }
            driver.say("The treadmill did not confirm Stop. Use the physical stop control now.")
        }

        var physicalStopConfirmed = false
        while !physicalStopConfirmed {
            guard let answer = driver.ask("Has the belt fully stopped? Type yes once it has. Any other answer sends Stop again:") else {
                driver.say("WARNING: input closed before the belt was confirmed stopped. Use the physical stop control.")
                break
            }
            if isYes(answer) {
                physicalStopConfirmed = true
            } else {
                _ = step(.stop, timeout: 15, expect: Self.isStopped)
            }
        }
        if physicalStopConfirmed {
            movementPossible = false
        } else if abortReason == nil {
            abortReason = "physical_stop_not_confirmed"
        }

        finish(base.merging([
            "completed": abortReason == nil,
            "abortedReason": abortReason ?? NSNull(),
            "stopConfirmedByStatus": stopConfirmedByStatus,
            "physicalStopConfirmed": physicalStopConfirmed,
            "movementPossible": movementPossible,
        ]) { $1 })
    }

    /// Sends a command, then waits for a fresh status update that satisfies `expect`.
    private func step(_ command: X21ControlCommand, timeout: TimeInterval, expect: ([String: String]) -> Bool) -> Bool {
        driver.say("Sending \(command.plaintext)...")
        let sentAt = driver.send(command)
        let confirmed = sentAt.flatMap { driver.waitForStatus(since: $0, timeout: timeout, plan: plan, expect: expect) }
        let record: [String: Any] = [
            "command": command.name,
            "plaintext": command.plaintext,
            "sent": sentAt != nil,
            "confirmed": confirmed != nil,
            "secondsToConfirm": sentAt.flatMap { sent in confirmed.map { $0.timeIntervalSince(sent) } } ?? NSNull(),
            "status": driver.currentStatus(),
        ]
        steps.append(record)
        driver.log("x21_probe.control_step", record)
        driver.say(confirmed != nil ? "Confirmed." : "Not confirmed.")
        return confirmed != nil
    }

    private func finish(_ fields: [String: Any]) {
        result = fields
        driver.log("x21_probe.control_result", fields)
    }

    private func matchesSpeed(_ target: Double) -> ([String: String]) -> Bool {
        { X21ControlPlan.matches($0["CurrentSpeed"].flatMap(Double.init), target) }
    }

    private func isYes(_ answer: String?) -> Bool {
        answer?.lowercased() == "yes"
    }

    private var sequenceDescription: String {
        var commands = ["manual mode (if needed)", "Start", "speed \(X21ControlCommand.formatSpeed(plan.lowKmh))"]
        if let changed = plan.changedKmh { commands.append("speed \(X21ControlCommand.formatSpeed(changed))") }
        commands.append("Stop")
        return commands.joined(separator: ", ")
    }

    private var planDictionary: [String: Any] {
        ["lowKmh": plan.lowKmh, "changedKmh": plan.changedKmh ?? NSNull()]
    }
}
