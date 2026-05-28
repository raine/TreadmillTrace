import Foundation
import Testing
@testable import TreadmillTrace

@Test func parsesFullVitalwalkTreadmillPacket() throws {
    let data = Data(hexString: "8C 05 00 00 31 01 00 00 00 00 00 10 00 FF FF FF 00 E9 00")

    let decoded = FTMSParser.parseTreadmillData(data)

    #expect(decoded.flags == 0x058C)
    #expect(decoded.moreData == false)
    #expect(decoded.speedKmh == 0)
    #expect(decoded.totalDistanceMeters == 305)
    #expect(decoded.inclinationPercent == 0)
    #expect(decoded.totalEnergyCalories == 16)
    #expect(decoded.elapsedTimeSeconds == 233)
    #expect(decoded.vendorFieldRaw16 == nil)
}

@Test func parsesMoreDataPacketWithoutSpeed() throws {
    let data = Data(hexString: "01 20 1B 00 00")

    let decoded = FTMSParser.parseTreadmillData(data)

    #expect(decoded.flags == 0x2001)
    #expect(decoded.moreData == true)
    #expect(decoded.speedKmh == nil)
    #expect(decoded.vendorFieldRaw16 == 27)
}

@Test func parsesFitshowCandidateSteps() throws {
    let data = Data(hexString: "02 51 0A 00 00 E9 00 BE 00 A9 00 C7 00 00 00 62 03")

    let decoded = try #require(FitshowParser.parseLiveMetrics(data))

    #expect(decoded.speedDisplayTimesTen == 0)
    #expect(decoded.elapsedSeconds == 233)
    #expect(decoded.distanceField == 190)
    #expect(decoded.candidateSteps == 199)
}

@Test func encodesBasicControlPointCommands() {
    #expect(FTMSCommand.requestControl.payload == Data([0x00]))
    #expect(FTMSCommand.start.payload == Data([0x07]))
    #expect(FTMSCommand.stop.payload == Data([0x08, 0x01]))
}

@Test func encodesAndClampsSpeedCommands() throws {
    let range = FTMSSpeedRange(minimumKmh: 0.6, maximumKmh: 4.0, incrementKmh: 0.1)

    let speed = try #require(FTMSCommand.speed(requestedKmh: 3.5, range: range))
    #expect(speed.payload == Data([0x02, 0x5E, 0x01]))
    #expect(speed.target == 3.5)

    let clamped = try #require(FTMSCommand.speed(requestedKmh: 99, range: range))
    #expect(clamped.payload == Data([0x02, 0x90, 0x01]))
    #expect(clamped.target == 4.0)

    let rounded = try #require(FTMSCommand.speed(requestedKmh: 3.26, range: range))
    #expect(rounded.payload == Data([0x02, 0x4A, 0x01]))
    #expect(rounded.target == 3.3)

    #expect(FTMSCommand.speed(requestedKmh: .infinity, range: range) == nil)
}

@Test func encodesInclineCommands() throws {
    let range = FTMSInclineRange(minimumPercent: -3.0, maximumPercent: 6.0, incrementPercent: 0.5)

    let incline = try #require(FTMSCommand.incline(requestedPercent: 2, range: range))
    #expect(incline.payload == Data([0x03, 0x14, 0x00]))
    #expect(incline.target == 2)

    let negative = try #require(FTMSCommand.incline(requestedPercent: -1.5, range: range))
    #expect(negative.payload == Data([0x03, 0xF1, 0xFF]))
    #expect(negative.target == -1.5)
}

@Test func parsesProbeArgument() {
    #expect(Arguments.parse(["--probe"]).probeMode == true)
    #expect(Arguments.parse([]).probeMode == false)
}

private extension Data {
    init(hexString: String) {
        self.init()
        for byte in hexString.split(separator: " ") {
            append(UInt8(byte, radix: 16)!)
        }
    }
}
