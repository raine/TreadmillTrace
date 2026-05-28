import Foundation

struct EncodedFTMSCommand: Equatable {
    let name: String
    let requestOpcode: UInt8
    let payload: Data
    let target: Double?
    let requested: Double?
    let clamped: Bool
}

enum FTMSCommand: Equatable {
    case requestControl
    case start
    case stop
    case speed(EncodedFTMSCommand)
    case incline(EncodedFTMSCommand)

    var name: String {
        switch self {
        case .requestControl: "request"
        case .start: "start"
        case .stop: "stop"
        case .speed: "speed"
        case .incline: "incline"
        }
    }

    var requestOpcode: UInt8 {
        switch self {
        case .requestControl: 0x00
        case .start: 0x07
        case .stop: 0x08
        case .speed(let command), .incline(let command): command.requestOpcode
        }
    }

    var payload: Data {
        switch self {
        case .requestControl: Data([0x00])
        case .start: Data([0x07])
        case .stop: Data([0x08, 0x01])
        case .speed(let command), .incline(let command): command.payload
        }
    }

    var target: Double? {
        switch self {
        case .speed(let command), .incline(let command): command.target
        case .requestControl, .start, .stop: nil
        }
    }

    var requested: Double? {
        switch self {
        case .speed(let command), .incline(let command): command.requested
        case .requestControl, .start, .stop: nil
        }
    }

    var clamped: Bool {
        switch self {
        case .speed(let command), .incline(let command): command.clamped
        case .requestControl, .start, .stop: false
        }
    }

    static func speed(requestedKmh: Double, range: FTMSSpeedRange) -> FTMSCommand? {
        guard requestedKmh.isFinite,
              range.minimumKmh.isFinite,
              range.maximumKmh.isFinite,
              range.incrementKmh.isFinite,
              range.incrementKmh > 0
        else { return nil }

        let target = clampAndRound(requestedKmh, minimum: range.minimumKmh, maximum: range.maximumKmh, increment: range.incrementKmh)
        let raw = UInt16((target * 100).rounded())
        return .speed(EncodedFTMSCommand(
            name: "speed",
            requestOpcode: 0x02,
            payload: Data([0x02, UInt8(raw & 0x00FF), UInt8(raw >> 8)]),
            target: target,
            requested: requestedKmh,
            clamped: target != requestedKmh
        ))
    }

    static func incline(requestedPercent: Double, range: FTMSInclineRange) -> FTMSCommand? {
        guard requestedPercent.isFinite,
              range.minimumPercent.isFinite,
              range.maximumPercent.isFinite,
              range.incrementPercent.isFinite,
              range.incrementPercent > 0
        else { return nil }

        let target = clampAndRound(
            requestedPercent,
            minimum: range.minimumPercent,
            maximum: range.maximumPercent,
            increment: range.incrementPercent
        )
        let raw = Int16((target * 10).rounded())
        let bits = UInt16(bitPattern: raw)
        return .incline(EncodedFTMSCommand(
            name: "incline",
            requestOpcode: 0x03,
            payload: Data([0x03, UInt8(bits & 0x00FF), UInt8(bits >> 8)]),
            target: target,
            requested: requestedPercent,
            clamped: target != requestedPercent
        ))
    }

    private static func clampAndRound(_ value: Double, minimum: Double, maximum: Double, increment: Double) -> Double {
        let clamped = min(max(value, minimum), maximum)
        let steps = ((clamped - minimum) / increment).rounded()
        let rounded = minimum + steps * increment
        return min(max((rounded * 10_000).rounded() / 10_000, minimum), maximum)
    }
}
