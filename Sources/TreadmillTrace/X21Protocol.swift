import CoreBluetooth
import Foundation

struct X21SubstitutionTable: Equatable {
    let id: String
    let alphabet: [UInt8]

    static let v1 = X21SubstitutionTable(
        id: "v1",
        alphabet: Array("SaCw4FGHIJqLhN+P9RVTU/WcY6ObDdefgEijklmnopQrsBuvMxXz1yA2t5078KZ3=".utf8)
    )
}

enum X21DecodeFailure: String, Error, Equatable {
    case unknownByte = "unknown_byte"
    case invalidBase64 = "invalid_base64"
    case invalidUTF8 = "invalid_utf8"
}

enum X21Codec {
    static let plainAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".utf8)
    static let terminator: UInt8 = 0x0D
    static let maximumChunkLength = 16

    static func encode(_ plaintext: String, table: X21SubstitutionTable) -> Data {
        var result = Data()
        for byte in Data(plaintext.utf8).base64EncodedString().utf8 {
            result.append(table.alphabet[plainAlphabet.firstIndex(of: byte)!])
        }
        result.append(terminator)
        return result
    }

    static func chunks(_ message: Data) -> [Data] {
        let bytes = [UInt8](message)
        return stride(from: 0, to: bytes.count, by: maximumChunkLength).map { start in
            Data(bytes[start ..< min(start + maximumChunkLength, bytes.count)])
        }
    }

    /// Decodes one frame whose terminator has already been removed.
    static func decode(_ frame: Data, table: X21SubstitutionTable) -> Result<String, X21DecodeFailure> {
        var base64 = Data()
        for byte in frame {
            guard let index = table.alphabet.firstIndex(of: byte) else { return .failure(.unknownByte) }
            base64.append(plainAlphabet[index])
        }
        guard let decoded = Data(base64Encoded: base64) else { return .failure(.invalidBase64) }
        guard let text = String(data: decoded, encoding: .utf8) else { return .failure(.invalidUTF8) }
        return .success(text)
    }
}

/// Reassembles notification chunks into frames terminated by 0x0D.
struct X21FrameBuffer {
    static let maximumPendingLength = 1024

    private(set) var pending = Data()

    /// Returns complete frames without terminators, or nil when unterminated input exceeds the limit.
    mutating func append(_ chunk: Data) -> [Data]? {
        var frames: [Data] = []
        for byte in chunk {
            if byte == X21Codec.terminator {
                frames.append(pending)
                pending = Data()
            } else {
                pending.append(byte)
                if pending.count > Self.maximumPendingLength {
                    pending = Data()
                    return nil
                }
            }
        }
        return frames
    }
}

struct X21Property: Equatable {
    let key: String
    let value: String
}

struct X21PropertyMessage: Equatable {
    static let statusKeys: Set<String> = ["CurrentSpeed", "ControlMode", "runState"]
    static let knownKeys: Set<String> = statusKeys.union([
        "spm", "RunningDistance", "RunningSteps", "BurnCalories", "RunningTotalTime", "mcu_version", "goal",
    ])
    static let numericKeys: Set<String> = [
        "CurrentSpeed", "spm", "RunningDistance", "RunningSteps", "BurnCalories", "RunningTotalTime",
    ]

    let properties: [X21Property]
    /// Tokens after an `Error` key, whose grammar is not established.
    let errorTokens: [String]?
    let danglingKey: String?

    static func parse(_ text: String) -> X21PropertyMessage? {
        guard let tokens = tokenize(text), tokens.first == "props" else { return nil }
        var properties: [X21Property] = []
        var index = 1
        while index < tokens.count {
            let key = tokens[index]
            if key == "Error" {
                return X21PropertyMessage(properties: properties, errorTokens: Array(tokens[(index + 1)...]), danglingKey: nil)
            }
            guard index + 1 < tokens.count else {
                return X21PropertyMessage(properties: properties, errorTokens: nil, danglingKey: key)
            }
            properties.append(X21Property(key: key, value: tokens[index + 1]))
            index += 2
        }
        return X21PropertyMessage(properties: properties, errorTokens: nil, danglingKey: nil)
    }

    /// Splits on whitespace, keeping double-quoted values intact. Returns nil for an unterminated quote.
    static func tokenize(_ text: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                hasToken = true
            } else if character.isWhitespace, !inQuotes {
                if hasToken { tokens.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
                hasToken = true
            }
        }
        guard !inQuotes else { return nil }
        if hasToken { tokens.append(current) }
        return tokens
    }

    func value(_ key: String) -> String? {
        properties.last { $0.key == key }?.value
    }

    func number(_ key: String) -> Double? {
        value(key).flatMap(Double.init)
    }

    var hasStatusField: Bool {
        properties.contains { Self.statusKeys.contains($0.key) }
    }

    var dictionary: [String: Any] {
        var known: [String: Any] = [:]
        for key in Self.knownKeys {
            guard let value = value(key) else { continue }
            known[key] = Self.numericKeys.contains(key) ? (Double(value) ?? value) : value
        }
        var result: [String: Any] = [
            "pairs": properties.map { [$0.key, $0.value] },
            "known": known,
            "unknownKeys": properties.map(\.key).filter { !Self.knownKeys.contains($0) },
        ]
        if let mode = value("ControlMode") { result["controlModeName"] = X21PropertyMessage.controlModeName(mode) }
        if let state = value("runState") { result["runStateName"] = X21PropertyMessage.runStateName(state) }
        if let errorTokens { result["errorTokens"] = errorTokens }
        if let danglingKey { result["danglingKey"] = danglingKey }
        return result
    }

    static func controlModeName(_ value: String) -> String {
        switch value {
        case "0": "automatic"
        case "1": "manual"
        case "2": "standby"
        default: "unknown"
        }
    }

    static func runStateName(_ value: String) -> String {
        switch value {
        case "0": "stopped"
        case "1": "running"
        case "5": "standby"
        case "9": "starting"
        default: "unknown"
        }
    }
}

/// Handshake and status queries. None of them changes mode, run state, or speed.
enum X21SafeCommand: Equatable {
    case formatProbe
    case shake
    case net
    case getDN
    case getPK
    case timePosix(Int)
    case version
    case shortPropertyQuery

    static func handshake(unixTime: Int) -> [X21SafeCommand] {
        [.formatProbe, .shake, .net, .getDN, .getPK, .timePosix(unixTime), .version, .shortPropertyQuery]
    }

    var name: String {
        switch self {
        case .formatProbe: "format_probe"
        case .shake: "shake"
        case .net: "net"
        case .getDN: "get_dn"
        case .getPK: "get_pk"
        case .timePosix: "time_posix"
        case .version: "version"
        case .shortPropertyQuery: "short_property_query"
        }
    }

    var plaintext: String {
        switch self {
        case .formatProbe: ""
        case .shake: "shake"
        case .net: "net"
        case .getDN: "get_dn"
        case .getPK: "get_pk"
        case let .timePosix(seconds): "time_posix \(seconds)"
        case .version: "version"
        case .shortPropertyQuery: "servers getProp 1 2 7 12 23 24 31"
        }
    }

    func accepts(_ response: String) -> Bool {
        let tokens = X21PropertyMessage.tokenize(response) ?? []
        switch self {
        case .formatProbe:
            return response.lowercased().contains("format error")
        case .shortPropertyQuery:
            return tokens.contains("servers") || X21PropertyMessage.parse(response) != nil
        case .shake, .net, .getDN, .getPK, .timePosix, .version:
            return tokens.contains(plaintext.split(separator: " ").first.map(String.init) ?? plaintext)
        }
    }
}

enum X21ProbeFailure: Equatable, Error {
    case layoutMismatch(String)
    case notificationSetupFailed(String)
    case decodeFailed(X21DecodeFailure)
    case frameOverflow
    case unexpectedResponse(command: String, text: String)
    case timeout(command: String)
    case writeFailed(String)
    case disconnected(String)
    case noStatusProperties
    case statusStale
    case controlAborted(String)

    var reason: String {
        switch self {
        case let .layoutMismatch(detail): "layout_mismatch: \(detail)"
        case let .notificationSetupFailed(detail): "notification_setup_failed: \(detail)"
        case let .decodeFailed(category): "table_mismatch_\(category.rawValue)"
        case .frameOverflow: "frame_overflow"
        case let .unexpectedResponse(command, text): "unexpected_response to \(command): \(text)"
        case let .timeout(command): "timeout waiting for \(command)"
        case let .writeFailed(detail): "write_failed: \(detail)"
        case let .disconnected(detail): "disconnected: \(detail)"
        case .noStatusProperties: "no_status_properties"
        case .statusStale: "status_stale"
        case let .controlAborted(reason): "control_aborted: \(reason)"
        }
    }
}

enum X21ProbeEvent: Equatable {
    /// The awaited response was valid; send this command next.
    case advance(X21SafeCommand)
    /// Idle polling returned status properties; passive observation may begin.
    case validated
    /// An observation poll returned properties.
    case pollAnswered(X21PropertyMessage)
    /// Acknowledgement or unsolicited properties; keep waiting for the awaited response.
    case waiting
    case ignored
    case failed(X21ProbeFailure)
}

/// Validates the ordered handshake and idle property polls, then accepts observation poll responses.
struct X21ProbeMachine {
    enum State: Equatable {
        case idle
        case handshake(Int)
        case idlePoll(Int)
        case observing
        case failed(X21ProbeFailure)
    }

    let idlePollCount: Int
    private(set) var state = State.idle
    private(set) var handshake: [X21SafeCommand] = []
    private(set) var propertyMessages: [X21PropertyMessage] = []

    init(idlePollCount: Int = 3) {
        self.idlePollCount = idlePollCount
    }

    var awaitingCommand: X21SafeCommand? {
        switch state {
        case let .handshake(index): handshake[index]
        case .idlePoll, .observing: .shortPropertyQuery
        case .idle, .failed: nil
        }
    }

    mutating func start(unixTime: Int) -> X21SafeCommand {
        handshake = X21SafeCommand.handshake(unixTime: unixTime)
        state = .handshake(0)
        return handshake[0]
    }

    mutating func receive(_ text: String) -> X21ProbeEvent {
        let properties = X21PropertyMessage.parse(text)
        if let properties { propertyMessages.append(properties) }

        switch state {
        case .idle, .failed:
            return .ignored
        case let .handshake(index):
            let command = handshake[index]
            if command.accepts(text) {
                if index + 1 < handshake.count {
                    state = .handshake(index + 1)
                    return .advance(handshake[index + 1])
                }
                state = .idlePoll(0)
                return .advance(.shortPropertyQuery)
            }
            if properties != nil { return .waiting }
            return fail(.unexpectedResponse(command: command.name, text: text))
        case let .idlePoll(index):
            guard properties != nil else {
                if X21SafeCommand.shortPropertyQuery.accepts(text) { return .waiting }
                return fail(.unexpectedResponse(command: X21SafeCommand.shortPropertyQuery.name, text: text))
            }
            if index + 1 < idlePollCount {
                state = .idlePoll(index + 1)
                return .advance(.shortPropertyQuery)
            }
            guard propertyMessages.contains(where: \.hasStatusField) else { return fail(.noStatusProperties) }
            state = .observing
            return .validated
        case .observing:
            if let properties { return .pollAnswered(properties) }
            return X21SafeCommand.shortPropertyQuery.accepts(text) ? .waiting : .ignored
        }
    }

    /// Decode failures reject table v1 until passive observation has begun, after which they are logged only.
    mutating func decodeFailed(_ failure: X21DecodeFailure) -> X21ProbeEvent {
        switch state {
        case .observing, .failed: .ignored
        case .idle, .handshake, .idlePoll: fail(.decodeFailed(failure))
        }
    }

    mutating func fail(_ failure: X21ProbeFailure) -> X21ProbeEvent {
        state = .failed(failure)
        return .failed(failure)
    }
}

struct X21GATTCharacteristic {
    let uuid: String
    let properties: CBCharacteristicProperties
}

struct X21GATTService {
    let uuid: String
    let characteristics: [X21GATTCharacteristic]
}

enum X21Layout {
    static let service = "00021234-0000-1000-8000-00805F9B34FB"
    static let write = "0002FED7-0000-1000-8000-00805F9B34FB"
    static let notify = "0002FED8-0000-1000-8000-00805F9B34FB"

    static func normalized(_ uuid: String) -> String {
        let upper = uuid.uppercased()
        switch upper.count {
        case 4: return "0000\(upper)-0000-1000-8000-00805F9B34FB"
        case 8: return "\(upper)-0000-1000-8000-00805F9B34FB"
        default: return upper
        }
    }

    /// Returns nil only for the revision-2 layout with usable write and notify characteristics.
    static func validate(_ services: [X21GATTService], maximumWriteWithoutResponse: Int) -> X21ProbeFailure? {
        let matching = services.filter { normalized($0.uuid) == service }
        guard matching.count == 1, let service = matching.first else {
            let uuids = services.map { normalized($0.uuid) }.joined(separator: ",")
            return .layoutMismatch("expected one \(Self.service) service, found [\(uuids)]")
        }
        guard let write = service.characteristics.first(where: { normalized($0.uuid) == Self.write }),
              write.properties.contains(.writeWithoutResponse)
        else { return .layoutMismatch("missing \(Self.write) with writeWithoutResponse") }
        guard let notify = service.characteristics.first(where: { normalized($0.uuid) == Self.notify }),
              notify.properties.contains(.notify)
        else { return .layoutMismatch("missing \(Self.notify) with notify") }
        guard maximumWriteWithoutResponse >= X21Codec.maximumChunkLength else {
            return .layoutMismatch("maximum write without response \(maximumWriteWithoutResponse) is below 16")
        }
        return nil
    }
}

/// Movement-related commands. The probe sends these only after the operator arms control validation.
enum X21ControlCommand: Equatable {
    case manualMode
    case start
    case stop
    case speed(Double)

    var name: String {
        switch self {
        case .manualMode: "manual_mode"
        case .start: "start"
        case .stop: "stop"
        case .speed: "speed"
        }
    }

    var plaintext: String {
        switch self {
        case .manualMode: "props ControlMode 1"
        case .start: "props runState 1"
        case .stop: "props runState 0"
        case let .speed(kmh): "props CurrentSpeed \(Self.formatSpeed(kmh))"
        }
    }

    /// Formats km/h with one decimal and a dot separator regardless of the user's locale.
    static func formatSpeed(_ kmh: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), kmh)
    }
}

/// Speed targets for control validation, taken only from speeds the treadmill reported
/// while the operator ran it from the panel or remote.
struct X21ControlPlan: Equatable {
    static let maximumLowSpeedKmh = 2.0
    static let maximumChangeKmh = 0.5
    static let tolerance = 0.05

    let lowKmh: Double
    let changedKmh: Double?

    var maximumKmh: Double { changedKmh ?? lowKmh }

    static func make(lowPhaseSpeeds: [Double], changePhaseSpeeds: [Double]) -> X21ControlPlan? {
        guard let low = lowPhaseSpeeds.filter({ $0 > 0 && $0.isFinite }).min(),
              low <= maximumLowSpeedKmh
        else { return nil }
        let changed = changePhaseSpeeds.last { speed in
            speed.isFinite && speed > low + tolerance && speed - low <= maximumChangeKmh + tolerance
        }
        return X21ControlPlan(lowKmh: rounded(low), changedKmh: changed.map(rounded))
    }

    static func matches(_ speed: Double?, _ target: Double) -> Bool {
        guard let speed else { return false }
        return abs(speed - target) <= tolerance
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}
