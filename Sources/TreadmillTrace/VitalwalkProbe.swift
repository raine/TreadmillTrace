import Foundation

enum VitalwalkDisplayUnit: String, Equatable {
    case mph
    case kmh

    static func parse(_ input: String) -> VitalwalkDisplayUnit? {
        switch input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mph": .mph
        case "kmh", "km/h": .kmh
        default: nil
        }
    }
}

struct VitalwalkProbeTargets: Equatable {
    let minimumRaw: Double
    let incrementRaw: Double
    let incrementedRaw: Double

    static func make(from range: FTMSSpeedRange) -> VitalwalkProbeTargets? {
        guard range.minimumKmh.isFinite,
              range.maximumKmh.isFinite,
              range.incrementKmh.isFinite,
              range.minimumKmh >= 0,
              range.maximumKmh >= range.minimumKmh,
              range.incrementKmh > 0
        else { return nil }

        let incremented = range.minimumKmh + range.incrementKmh
        guard incremented <= range.maximumKmh else { return nil }

        return VitalwalkProbeTargets(
            minimumRaw: range.minimumKmh,
            incrementRaw: range.incrementKmh,
            incrementedRaw: incremented
        )
    }
}

struct VitalwalkSpeedSample: Equatable {
    let rawTarget: Double
    let reportedSpeedKmh: Double?
    let physicalDisplayValue: Double
    let physicalDisplayUnit: VitalwalkDisplayUnit

    var reportedSpeedMph: Double? {
        reportedSpeedKmh.map { $0 / 1.609_344 }
    }

    var rawMatchesPhysicalDisplay: Bool {
        approximatelyEqual(rawTarget, physicalDisplayValue, tolerance: 0.06)
    }

    var rawBehavesAsMph: Bool {
        guard let reportedSpeedKmh else { return false }
        return approximatelyEqual(reportedSpeedKmh, rawTarget * 1.609_344, tolerance: 0.12)
    }

    var dictionary: [String: Any] {
        [
            "rawTarget": rawTarget,
            "reportedSpeedKmh": reportedSpeedKmh ?? NSNull(),
            "reportedSpeedMph": reportedSpeedMph ?? NSNull(),
            "physicalDisplayValue": physicalDisplayValue,
            "physicalDisplayUnit": physicalDisplayUnit.rawValue,
            "rawMatchesPhysicalDisplay": rawMatchesPhysicalDisplay,
            "rawBehavesAsMph": rawBehavesAsMph,
        ]
    }

    private func approximatelyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}

struct VitalwalkCommandResult: Equatable {
    let name: String
    let requestOpcode: UInt8
    let resultCode: UInt8?
    let responseHex: String?
    let timedOut: Bool

    var succeeded: Bool {
        resultCode == 0x01
    }

    var dictionary: [String: Any] {
        [
            "name": name,
            "requestOpcode": String(format: "0x%02X", requestOpcode),
            "resultCode": resultCode.map { String(format: "0x%02X", $0) } ?? "none",
            "responseHex": responseHex ?? "none",
            "timedOut": timedOut,
            "succeeded": succeeded,
        ]
    }
}
