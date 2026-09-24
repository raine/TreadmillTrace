import Foundation
import Testing
@testable import TreadmillTrace

/// Scripted driver: each sent command moves the treadmill to a status, and answers are consumed in order.
private final class FakeDriver: X21ControlDriver {
    var status: [String: String] = ["ControlMode": "2", "runState": "0", "CurrentSpeed": "0.0"]
    var answers: [String?]
    var statusAfter: (X21ControlCommand, [String: String]) -> [String: String] = FakeDriver.obedient
    var sent: [X21ControlCommand] = []
    var movementHistory: [Bool] = []
    var prompts: [String] = []

    init(answers: [String?]) {
        self.answers = answers
    }

    static func obedient(_ command: X21ControlCommand, _ status: [String: String]) -> [String: String] {
        var next = status
        switch command {
        case .manualMode: next["ControlMode"] = "1"
        case .start: next["runState"] = "1"
        case .stop: next["runState"] = "0"; next["CurrentSpeed"] = "0.0"
        case let .speed(kmh): next["CurrentSpeed"] = X21ControlCommand.formatSpeed(kmh)
        }
        return next
    }

    func send(_ command: X21ControlCommand) -> Date? {
        sent.append(command)
        status = statusAfter(command, status)
        return Date()
    }

    func waitForStatus(since _: Date, timeout _: TimeInterval, plan _: X21ControlPlan, expect: ([String: String]) -> Bool) -> Date? {
        expect(status) ? Date() : nil
    }

    func currentStatus() -> [String: String] { status }

    func ask(_ prompt: String) -> String? {
        prompts.append(prompt)
        guard !answers.isEmpty else { return nil }
        return answers.removeFirst()
    }

    func say(_: String) {}
    func log(_: String, _: [String: Any]) {}
    func setMovementPossible(_ value: Bool) { movementHistory.append(value) }
}

private let plan = X21ControlPlan(lowKmh: 1.0, changedKmh: 1.5)
private let armed = ["yes", "yes", X21ControlRunner.armingPhrase]

private func run(_ driver: FakeDriver, plan: X21ControlPlan = plan) -> X21ControlRunner {
    let runner = X21ControlRunner(plan: plan, driver: driver)
    runner.run()
    return runner
}

@Test func runsX21ControlSequenceInDocumentedOrder() {
    let driver = FakeDriver(answers: armed + ["yes", "yes"])
    let runner = run(driver)

    #expect(driver.sent == [.manualMode, .start, .speed(1.0), .speed(1.5), .stop])
    #expect(runner.abortReason == nil)
    #expect(runner.result["completed"] as? Bool == true)
    #expect(runner.result["physicalStopConfirmed"] as? Bool == true)
    #expect(!runner.movementPossible)
    #expect(driver.movementHistory == [true, false])
}

@Test func skipsManualModeWhenAlreadyManualAndSpeedChangeWithoutPlan() {
    let driver = FakeDriver(answers: armed + ["yes", "yes"])
    driver.status["ControlMode"] = "1"
    _ = run(driver, plan: X21ControlPlan(lowKmh: 1.0, changedKmh: nil))
    #expect(driver.sent == [.start, .speed(1.0), .stop])
}

@Test func sendsNothingUnlessArmed() {
    for answers: [String?] in [[""], ["yes", "no"], ["yes", "yes", "run x21 control probe"], []] {
        let driver = FakeDriver(answers: answers)
        let runner = run(driver)
        #expect(driver.sent.isEmpty)
        #expect(driver.movementHistory.isEmpty)
        #expect(runner.result["completed"] as? Bool != true)
    }
}

@Test func refusesToArmWhenTreadmillIsNotReportedStopped() {
    let driver = FakeDriver(answers: armed)
    driver.status["runState"] = "1"
    let runner = run(driver)
    #expect(driver.sent.isEmpty)
    #expect(driver.movementHistory.isEmpty)
    #expect(runner.abortReason == "not_stopped_or_status_stale")
    // The arming phrase is never requested.
    #expect(!driver.prompts.contains { $0.contains(X21ControlRunner.armingPhrase) })
}

@Test func stopsWithoutRaisingSpeedWhenNoPhysicalMovement() {
    let driver = FakeDriver(answers: armed + ["no", "yes"])
    let runner = run(driver)

    #expect(driver.sent == [.manualMode, .start, .speed(1.0), .stop])
    #expect(!driver.sent.contains(.speed(1.5)))
    #expect(runner.abortReason == "no_physical_movement_at_low_speed")
    #expect(runner.result["completed"] as? Bool == false)
    #expect(runner.result["physicalMovementObserved"] as? Bool == false)
    #expect(!runner.movementPossible)
}

@Test func keepsMovementPossibleWhenStopIsUnconfirmedAndInputCloses() {
    let driver = FakeDriver(answers: armed + ["yes"])
    driver.statusAfter = { command, status in
        command == .stop ? status : FakeDriver.obedient(command, status)
    }
    let runner = run(driver)

    #expect(driver.sent.suffix(X21ControlRunner.stopAttempts) == Array(repeating: .stop, count: X21ControlRunner.stopAttempts))
    #expect(runner.abortReason == "stop_not_confirmed")
    #expect(runner.movementPossible)
    #expect(driver.movementHistory == [true])
    #expect(runner.result["physicalStopConfirmed"] as? Bool == false)
    #expect(runner.result["movementPossible"] as? Bool == true)
    #expect(runner.result["completed"] as? Bool == false)
}

@Test func requiresPhysicalConfirmationBeforeClearingMovement() {
    // Status never confirms Stop; the operator first says no (Stop is resent), then yes.
    let driver = FakeDriver(answers: armed + ["yes", "no", "yes"])
    driver.statusAfter = { command, status in
        command == .stop ? status : FakeDriver.obedient(command, status)
    }
    let runner = run(driver)

    #expect(driver.sent.filter { $0 == .stop }.count == X21ControlRunner.stopAttempts + 1)
    #expect(!runner.movementPossible)
    #expect(driver.movementHistory == [true, false])
    #expect(runner.result["physicalStopConfirmed"] as? Bool == true)
    #expect(runner.result["stopConfirmedByStatus"] as? Bool == false)
    #expect(runner.abortReason == "stop_not_confirmed")
}

@Test func keepsMovementPossibleWhenStatusStopsButOperatorNeverConfirms() {
    let driver = FakeDriver(answers: armed + ["yes", "no"])
    let runner = run(driver)
    #expect(runner.movementPossible)
    #expect(runner.abortReason == "physical_stop_not_confirmed")
}

@Test func stopsOnInterruptedMovementObservation() {
    // Closed input at the movement prompt, as after an interrupt, still sends Stop and keeps the danger state.
    let driver = FakeDriver(answers: armed)
    let runner = run(driver)
    #expect(driver.sent == [.manualMode, .start, .speed(1.0), .stop])
    #expect(runner.abortReason == "movement_observation_missing")
    #expect(runner.movementPossible)
}

@Test func stopsWhenStartOrSpeedIsNotConfirmed() {
    let startIgnored = FakeDriver(answers: armed + ["yes"])
    startIgnored.statusAfter = { command, status in
        command == .start ? status : FakeDriver.obedient(command, status)
    }
    let startRunner = run(startIgnored)
    #expect(startIgnored.sent == [.manualMode, .start, .stop])
    #expect(startRunner.abortReason == "start_not_confirmed")
    #expect(!startRunner.movementPossible)

    let speedIgnored = FakeDriver(answers: armed + ["yes"])
    speedIgnored.statusAfter = { command, status in
        if case .speed = command { return status }
        return FakeDriver.obedient(command, status)
    }
    let speedRunner = run(speedIgnored)
    #expect(speedIgnored.sent == [.manualMode, .start, .speed(1.0), .stop])
    #expect(speedRunner.abortReason == "low_speed_not_confirmed")
}

@Test func formatsSpeedWithDotDecimalInAnyLocale() {
    #expect(X21ControlCommand.formatSpeed(0.8) == "0.8")
    #expect(X21ControlCommand.speed(1.5).plaintext == "props CurrentSpeed 1.5")
    #expect(String(format: "%.1f", locale: Locale(identifier: "fi_FI"), 1.5) == "1,5")
    #expect(!X21ControlCommand.formatSpeed(1.5).contains(","))
}
