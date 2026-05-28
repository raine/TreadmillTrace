import Foundation

struct FTMSSpeedRange: Equatable {
    let minimumKmh: Double
    let maximumKmh: Double
    let incrementKmh: Double

    func contains(_ speed: Double) -> Bool {
        speed >= minimumKmh && speed <= maximumKmh
    }
}

struct FTMSInclineRange: Equatable {
    let minimumPercent: Double
    let maximumPercent: Double
    let incrementPercent: Double

    var isSupported: Bool {
        minimumPercent != 0 || maximumPercent != 0 || incrementPercent != 0
    }
}

struct FTMSFeature: Equatable {
    let fitnessMachineFeatures: UInt32
    let targetSettingFeatures: UInt32
}

struct FTMSTreadmillData: Equatable {
    let flags: UInt16
    let moreData: Bool
    var speedRaw: UInt16?
    var speedKmh: Double?
    var averageSpeedKmh: Double?
    var totalDistanceMeters: Int?
    var inclinationPercent: Double?
    var rampAngleDegrees: Double?
    var positiveElevationGainMeters: UInt16?
    var negativeElevationGainMeters: UInt16?
    var instantaneousPaceRaw: UInt16?
    var averagePaceRaw: UInt16?
    var totalEnergyCalories: UInt16?
    var energyPerHourCalories: UInt16?
    var energyPerMinuteCalories: UInt8?
    var heartRateBpm: UInt8?
    var metabolicEquivalent: Double?
    var elapsedTimeSeconds: UInt16?
    var remainingTimeSeconds: UInt16?
    var forceOnBeltNewtons: Int16?
    var powerOutputWatts: Int16?
    var vendorFieldRaw16: UInt16?
    var consumedBytes: Int
    var trailingBytes: Int
    var trailingHex: String?

    func dictionary() -> [String: Any] {
        var result: [String: Any] = [
            "flags": String(format: "0x%04X", flags),
            "moreData": moreData,
            "consumedBytes": consumedBytes,
            "trailingBytes": trailingBytes,
        ]
        if let speedRaw { result["speedRaw"] = speedRaw }
        if let speedKmh { result["speedKmh"] = speedKmh }
        if let averageSpeedKmh { result["averageSpeedKmh"] = averageSpeedKmh }
        if let totalDistanceMeters { result["totalDistanceMeters"] = totalDistanceMeters }
        if let inclinationPercent { result["inclinationPercent"] = inclinationPercent }
        if let rampAngleDegrees { result["rampAngleDegrees"] = rampAngleDegrees }
        if let positiveElevationGainMeters { result["positiveElevationGainMeters"] = positiveElevationGainMeters }
        if let negativeElevationGainMeters { result["negativeElevationGainMeters"] = negativeElevationGainMeters }
        if let instantaneousPaceRaw { result["instantaneousPaceRaw"] = instantaneousPaceRaw }
        if let averagePaceRaw { result["averagePaceRaw"] = averagePaceRaw }
        if let totalEnergyCalories { result["totalEnergyCalories"] = totalEnergyCalories }
        if let energyPerHourCalories { result["energyPerHourCalories"] = energyPerHourCalories }
        if let energyPerMinuteCalories { result["energyPerMinuteCalories"] = energyPerMinuteCalories }
        if let heartRateBpm { result["heartRateBpm"] = heartRateBpm }
        if let metabolicEquivalent { result["metabolicEquivalent"] = metabolicEquivalent }
        if let elapsedTimeSeconds { result["elapsedTimeSeconds"] = elapsedTimeSeconds }
        if let remainingTimeSeconds { result["remainingTimeSeconds"] = remainingTimeSeconds }
        if let forceOnBeltNewtons { result["forceOnBeltNewtons"] = forceOnBeltNewtons }
        if let powerOutputWatts { result["powerOutputWatts"] = powerOutputWatts }
        if let vendorFieldRaw16 { result["vendorFieldRaw16"] = vendorFieldRaw16 }
        if let trailingHex { result["trailingHex"] = trailingHex }
        return result
    }
}

struct FitshowLiveMetrics: Equatable {
    let command: UInt8
    let speedDisplayTimesTen: UInt8
    let elapsedSeconds: UInt16
    let distanceField: UInt16
    let unknownField: UInt16
    let candidateSteps: UInt16
    let checksum: UInt8

    func dictionary() -> [String: Any] {
        [
            "fitshowCommand": command,
            "speedDisplayTimesTen": speedDisplayTimesTen,
            "elapsedSeconds": elapsedSeconds,
            "distanceField": distanceField,
            "unknownField": unknownField,
            "candidateSteps": candidateSteps,
            "checksum": checksum,
        ]
    }
}

enum FTMSParser {
    static func parseTreadmillData(_ data: Data) -> FTMSTreadmillData {
        guard data.count >= 2 else {
            return FTMSTreadmillData(
                flags: 0,
                moreData: false,
                consumedBytes: 0,
                trailingBytes: data.count,
                trailingHex: data.hexString
            )
        }

        let flags = data.uint16(at: 0)!
        let moreData = flags & 0x0001 != 0
        var offset = 2
        var result = FTMSTreadmillData(
            flags: flags,
            moreData: moreData,
            consumedBytes: offset,
            trailingBytes: 0,
            trailingHex: nil
        )

        func has(_ bit: UInt16) -> Bool { flags & bit != 0 }
        func readUInt16() -> UInt16? {
            guard let value = data.uint16(at: offset) else { return nil }
            offset += 2
            return value
        }
        func readInt16() -> Int16? {
            guard let value = readUInt16() else { return nil }
            return Int16(bitPattern: value)
        }
        func readUInt24() -> Int? {
            guard offset + 3 <= data.count else { return nil }
            let value = Int(data[offset]) | (Int(data[offset + 1]) << 8) | (Int(data[offset + 2]) << 16)
            offset += 3
            return value
        }

        if !moreData, let speedRaw = readUInt16() {
            result.speedRaw = speedRaw
            result.speedKmh = Double(speedRaw) / 100.0
        }
        if has(0x0002), let averageSpeed = readUInt16() {
            result.averageSpeedKmh = Double(averageSpeed) / 100.0
        }
        if has(0x0004), let totalDistance = readUInt24() {
            result.totalDistanceMeters = totalDistance
        }
        if has(0x0008), let inclination = readInt16(), let rampAngle = readInt16() {
            result.inclinationPercent = Double(inclination) / 10.0
            result.rampAngleDegrees = Double(rampAngle) / 10.0
        }
        if has(0x0010), let positive = readUInt16(), let negative = readUInt16() {
            result.positiveElevationGainMeters = positive
            result.negativeElevationGainMeters = negative
        }
        if has(0x0020), let pace = readUInt16() {
            result.instantaneousPaceRaw = pace
        }
        if has(0x0040), let pace = readUInt16() {
            result.averagePaceRaw = pace
        }
        if has(0x0080), offset + 5 <= data.count {
            result.totalEnergyCalories = data.uint16(at: offset)
            result.energyPerHourCalories = data.uint16(at: offset + 2)
            result.energyPerMinuteCalories = data[offset + 4]
            offset += 5
        }
        if has(0x0100), offset + 1 <= data.count {
            result.heartRateBpm = data[offset]
            offset += 1
        }
        if has(0x0200), offset + 1 <= data.count {
            result.metabolicEquivalent = Double(data[offset]) / 10.0
            offset += 1
        }
        if has(0x0400), let elapsedTime = readUInt16() {
            result.elapsedTimeSeconds = elapsedTime
        }
        if has(0x0800), let remainingTime = readUInt16() {
            result.remainingTimeSeconds = remainingTime
        }
        if has(0x1000), let force = readInt16(), let power = readInt16() {
            result.forceOnBeltNewtons = force
            result.powerOutputWatts = power
        }
        if has(0x2000), let vendorField = readUInt16() {
            result.vendorFieldRaw16 = vendorField
        }

        result.consumedBytes = offset
        result.trailingBytes = max(0, data.count - offset)
        if offset < data.count {
            result.trailingHex = Data(data[offset...]).hexString
        }
        return result
    }

    static func parseFeature(_ data: Data) -> FTMSFeature? {
        guard data.count >= 8 else { return nil }
        return FTMSFeature(
            fitnessMachineFeatures: data.uint32(at: 0)!,
            targetSettingFeatures: data.uint32(at: 4)!
        )
    }

    static func parseSupportedSpeedRange(_ data: Data) -> FTMSSpeedRange? {
        guard data.count >= 6,
              let minimum = data.uint16(at: 0),
              let maximum = data.uint16(at: 2),
              let increment = data.uint16(at: 4)
        else { return nil }
        return FTMSSpeedRange(
            minimumKmh: Double(minimum) / 100.0,
            maximumKmh: Double(maximum) / 100.0,
            incrementKmh: Double(increment) / 100.0
        )
    }

    static func parseSupportedInclinationRange(_ data: Data) -> FTMSInclineRange? {
        guard data.count >= 6,
              let minimum = data.int16(at: 0),
              let maximum = data.int16(at: 2),
              let increment = data.uint16(at: 4)
        else { return nil }
        return FTMSInclineRange(
            minimumPercent: Double(minimum) / 10.0,
            maximumPercent: Double(maximum) / 10.0,
            incrementPercent: Double(increment) / 10.0
        )
    }
}

enum FitshowParser {
    static func parseLiveMetrics(_ data: Data) -> FitshowLiveMetrics? {
        guard data.count == 17,
              data[0] == 0x02,
              data[1] == 0x51,
              data[16] == 0x03,
              let elapsed = data.uint16(at: 5),
              let distance = data.uint16(at: 7),
              let unknown = data.uint16(at: 9),
              let steps = data.uint16(at: 11)
        else { return nil }

        return FitshowLiveMetrics(
            command: data[2],
            speedDisplayTimesTen: data[3],
            elapsedSeconds: elapsed,
            distanceField: distance,
            unknownField: unknown,
            candidateSteps: steps,
            checksum: data[15]
        )
    }
}

extension Data {
    func uint16(at offset: Int) -> UInt16? {
        guard offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func int16(at offset: Int) -> Int16? {
        guard let value = uint16(at: offset) else { return nil }
        return Int16(bitPattern: value)
    }

    func uint32(at offset: Int) -> UInt32? {
        guard offset + 4 <= count else { return nil }
        return UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }
}
