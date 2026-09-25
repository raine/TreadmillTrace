import CoreBluetooth
import Foundation
import Testing
@testable import TreadmillTrace

private func hex(_ data: Data) -> String { data.hexString }

private func encoded(_ text: String, table: X21SubstitutionTable = .v1) -> Data {
    X21Codec.encode(text, table: table)
}

private func frame(_ text: String, table: X21SubstitutionTable = .v1) -> Data {
    encoded(text, table: table).dropLast()
}

@Test func encodesX21TestVectors() {
    #expect(hex(encoded("")) == "0D")
    #expect(hex(encoded("shake")) == "44 41 45 45 4F 41 55 3D 0D")
    #expect(hex(encoded("props runState 0")) ==
        "44 48 4A 76 44 48 68 67 44 6E 2F 75 55 32 52 45 64 47 55 67 68 53 3D 3D 0D")
    #expect(hex(encoded("props CurrentSpeed 3.0")) ==
        "44 48 4A 76 44 48 68 67 39 32 2F 58 44 6D 2F 75 64 46 4E 4D 36 57 2F 6B 49 77 68 75 68 53 3D 3D 0D")

    let query = encoded("servers getProp 1 2 7 12 23 24 31")
    #expect(hex(query) == """
    44 41 2F 58 64 6D 2F 58 44 58 61 6E 36 63 52 39 \
    44 6D 4B 4D 49 77 34 67 68 69 53 32 49 77 34 58 \
    49 77 49 7A 49 77 49 31 49 77 68 78 0D
    """)
    let chunks = X21Codec.chunks(query)
    #expect(chunks.map(\.count) == [16, 16, 13])
    #expect(Data(chunks.joined()) == query)
}

@Test func decodesX21FramesAndClassifiesFailures() {
    #expect(X21Codec.decode(frame("props runState 0"), table: .v1) == .success("props runState 0"))
    #expect(X21Codec.decode(Data("!!".utf8), table: .v1) == .failure(.unknownByte))
    #expect(X21Codec.decode(Data("S".utf8), table: .v1) == .failure(.invalidBase64))
    let invalidUTF8 = Data(Data([0xFF, 0xFE]).base64EncodedString().utf8)
    let substituted = Data(invalidUTF8.map { X21SubstitutionTable.v1.alphabet[X21Codec.plainAlphabet.firstIndex(of: $0)!] })
    #expect(X21Codec.decode(substituted, table: .v1) == .failure(.invalidUTF8))
}

@Test func decodesObservedBinaryX21V4Handshake() throws {
    let formatFrame = Data("6mKXbWF1IG/XDmKXw9==".utf8)
    let shakeFrame = Data("DAEEOAUGHwiN".utf8)

    #expect(try X21Codec.decodeBytes(formatFrame, table: .x21V4).get() == Data("format error\r".utf8))
    #expect(try X21Codec.decodeBytes(shakeFrame, table: .x21V4).get() == Data([0x73, 0x68, 0x61, 0x6B, 0x65, 0x06, 0x1C, 0x30, 0x0D]))
    #expect(X21Codec.decode(shakeFrame, table: .v1) == .failure(.invalidUTF8))

    var machine = X21ProbeMachine()
    #expect(machine.start(unixTime: 1_700_000_000) == .formatProbe)
    #expect(machine.receive(Data("format error\r".utf8)) == .advance(.shake))
    #expect(machine.receive(Data([0x73, 0x68, 0x61, 0x6B, 0x65, 0x06, 0x1C, 0x30, 0x0D])) == .advance(.net))
}

@Test func encodesX21V4CommandsWithObservedTable() {
    #expect(encoded("shake", table: .x21V4) == encoded("shake", table: .v1))
    #expect(hex(encoded("servers getProp 1 2 7 12 23 24 31", table: .x21V4)) == """
    44 41 2F 58 64 6D 2F 58 44 58 61 6E 36 63 52 39 \
    44 6D 4B 4D 49 77 34 67 68 5A 69 32 49 77 34 58 \
    49 77 49 7A 49 77 49 31 49 77 68 78 0D
    """)
}

@Test func reassemblesFragmentedX21Frames() {
    let first = encoded("shake 00")
    let second = encoded("net cloud")
    let stream = [UInt8](first + second)
    var buffer = X21FrameBuffer()

    let partial = buffer.append(Data(stream[0 ..< 3]))
    #expect(partial == [])
    let frames = buffer.append(Data(stream[3 ..< (first.count + 2)]))
    #expect(frames == [first.dropLast()])
    let rest = buffer.append(Data(stream[(first.count + 2)...])) ?? []
    #expect(rest.map { X21Codec.decode($0, table: .v1) } == [.success("net cloud")])
    #expect(buffer.pending.isEmpty)

    var overflow = X21FrameBuffer()
    let overflowed = overflow.append(Data(repeating: 0x41, count: X21FrameBuffer.maximumPendingLength + 1))
    #expect(overflowed == nil)
}

@Test func parsesX21Properties() throws {
    let message = try #require(X21PropertyMessage.parse(
        #"props CurrentSpeed 0.0 ControlMode 2 runState 0 mcu_version "1.2 beta" goal 0 Mystery 7"#
    ))
    #expect(message.number("CurrentSpeed") == 0)
    #expect(message.value("mcu_version") == "1.2 beta")
    #expect(message.value("goal") == "0")
    #expect(message.hasStatusField)
    let dictionary = message.dictionary
    #expect(dictionary["unknownKeys"] as? [String] == ["Mystery"])
    #expect((dictionary["known"] as? [String: Any])?["mcu_version"] as? String == "1.2 beta")
    #expect(dictionary["controlModeName"] as? String == "standby")

    let error = try #require(X21PropertyMessage.parse("props runState 1 Error 3 motor fault"))
    #expect(error.properties == [X21Property(key: "runState", value: "1")])
    #expect(error.errorTokens == ["3", "motor", "fault"])

    #expect(X21PropertyMessage.parse("props runState")?.danglingKey == "runState")
    #expect(X21PropertyMessage.parse("net cloud") == nil)
    #expect(X21PropertyMessage.parse(#"props goal "open"#) == nil)
    #expect(X21PropertyMessage.runStateName("7") == "unknown")
}

@Test func advancesX21HandshakeInOrder() {
    var machine = X21ProbeMachine(idlePollCount: 2)
    #expect(machine.start(unixTime: 1_700_000_000) == .formatProbe)

    let responses = ["format error", "shake 00", "net cloud", "get_dn ABC", "get_pk XYZ", "time_posix 0", "version 1.0.3"]
    let expected: [X21SafeCommand] = [.shake, .net, .getDN, .getPK, .timePosix(1_700_000_000), .version, .shortPropertyQuery]
    for (response, next) in zip(responses, expected) {
        #expect(machine.receive(response) == .advance(next))
    }
    #expect(machine.receive("servers ok") == .advance(.shortPropertyQuery))
    #expect(machine.receive("props CurrentSpeed 0.0 runState 0") == .advance(.shortPropertyQuery))
    #expect(machine.receive("props ControlMode 2") == .validated)
    #expect(machine.state == .observing)
    #expect(machine.receive("props runState 1") == .pollAnswered(X21PropertyMessage.parse("props runState 1")!))
}

@Test func rejectsInvalidX21Responses() {
    var unexpected = X21ProbeMachine()
    _ = unexpected.start(unixTime: 0)
    #expect(unexpected.receive("shake 00") == .failed(.unexpectedResponse(command: "format_probe", text: "shake 00")))
    #expect(unexpected.receive("format error") == .ignored)

    var tableMismatch = X21ProbeMachine()
    _ = tableMismatch.start(unixTime: 0)
    #expect(tableMismatch.decodeFailed(.unknownByte) == .failed(.decodeFailed(.unknownByte)))

    var noStatus = X21ProbeMachine(idlePollCount: 1)
    _ = noStatus.start(unixTime: 0)
    for response in ["format error", "shake", "net", "get_dn", "get_pk", "time_posix 0", "version", "servers"] {
        _ = noStatus.receive(response)
    }
    #expect(noStatus.receive("props Mystery 1") == .failed(.noStatusProperties))

    var observing = X21ProbeMachine(idlePollCount: 1)
    _ = observing.start(unixTime: 0)
    for response in ["format error", "shake", "net", "get_dn", "get_pk", "time_posix 0", "version", "servers", "props runState 0"] {
        _ = observing.receive(response)
    }
    #expect(observing.decodeFailed(.invalidBase64) == .ignored)
}

@Test func requiresRevisionTwoX21Layout() {
    let valid = [X21GATTService(uuid: "00021234-0000-1000-8000-00805F9B34FB", characteristics: [
        X21GATTCharacteristic(uuid: "0002FED7-0000-1000-8000-00805F9B34FB", properties: [.read, .writeWithoutResponse]),
        X21GATTCharacteristic(uuid: "0002FED8-0000-1000-8000-00805F9B34FB", properties: [.read, .notify]),
    ])]
    #expect(X21Layout.validate(valid, maximumWriteWithoutResponse: 20) == nil)
    #expect(X21Layout.validate(valid, maximumWriteWithoutResponse: 12) != nil)

    let revisionOne = [X21GATTService(uuid: "00011234", characteristics: [
        X21GATTCharacteristic(uuid: "0001FED7", properties: [.writeWithoutResponse]),
        X21GATTCharacteristic(uuid: "0001FED8", properties: [.notify]),
    ])]
    #expect(X21Layout.validate(revisionOne, maximumWriteWithoutResponse: 20) != nil)

    let noNotify = [X21GATTService(uuid: "00021234", characteristics: [
        X21GATTCharacteristic(uuid: "0002FED7", properties: [.writeWithoutResponse]),
        X21GATTCharacteristic(uuid: "0002FED8", properties: [.read]),
    ])]
    #expect(X21Layout.validate(noNotify, maximumWriteWithoutResponse: 20) != nil)
}

@Test func x21SafeCommandsNeverControlMovement() {
    for command in X21SafeCommand.handshake(unixTime: 1_700_000_000) {
        let tokens = Set(command.plaintext.split(separator: " ").map(String.init))
        #expect(!tokens.contains("props"))
        #expect(tokens.isDisjoint(with: ["ControlMode", "runState", "CurrentSpeed"]))
    }
}

@Test func encodesX21ControlCommands() {
    #expect(X21ControlCommand.stop.plaintext == "props runState 0")
    #expect(X21ControlCommand.start.plaintext == "props runState 1")
    #expect(X21ControlCommand.manualMode.plaintext == "props ControlMode 1")
    #expect(X21ControlCommand.speed(3).plaintext == "props CurrentSpeed 3.0")
    #expect(hex(encoded(X21ControlCommand.speed(3).plaintext)).hasSuffix("68 53 3D 3D 0D"))
}

@Test func plansX21ControlOnlyFromObservedLowSpeeds() throws {
    let plan = try #require(X21ControlPlan.make(lowPhaseSpeeds: [0, 1.0, 1.0], changePhaseSpeeds: [1.0, 1.2, 1.5]))
    #expect(plan.lowKmh == 1.0)
    #expect(plan.changedKmh == 1.5)

    let noChange = try #require(X21ControlPlan.make(lowPhaseSpeeds: [0.8], changePhaseSpeeds: [0.8, 3.0]))
    #expect(noChange.changedKmh == nil)
    #expect(noChange.maximumKmh == 0.8)

    #expect(X21ControlPlan.make(lowPhaseSpeeds: [0, 0], changePhaseSpeeds: [1]) == nil)
    #expect(X21ControlPlan.make(lowPhaseSpeeds: [2.5], changePhaseSpeeds: []) == nil)
    #expect(X21ControlPlan.make(lowPhaseSpeeds: [.nan], changePhaseSpeeds: []) == nil)
}
