import Foundation

/// The wire format of the local control socket.
///
/// Newline-delimited JSON in both directions, one object per line. Chosen over
/// anything framed by a length prefix because the socket exists to be driven by
/// scripts and by an MCP server, and a format you can produce with `echo` and
/// read with `cat` is worth more here than a few saved bytes.
///
/// Requests carry an `id` that is echoed back untouched, so a client may have
/// several in flight. A request without one still gets a reply; it just has no
/// `id` to match it against.

// MARK: - Values

/// A JSON value, because command parameters have no single static shape.
///
/// Spelled out rather than reaching for `JSONSerialization` and `Any` so that
/// the accessors below can be total functions: a client sending `"2"` where a
/// number belongs is a wrong type, not a crash, and `intValue` says so by
/// returning nil. That leniency is deliberate — shells stringify everything.
public enum ControlValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ControlValue])
    case object([String: ControlValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ControlValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ControlValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Not a JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Accessors

    public subscript(key: String) -> ControlValue? {
        guard case .object(let fields) = self else { return nil }
        let value = fields[key]
        // A key present but explicitly null reads the same as an absent key,
        // so callers only need one "was it given?" check.
        return value == .null ? nil : value
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        // Tolerated because a shell has no booleans: `--paused true` arrives as
        // a string however carefully the client is written.
        case .string(let value):
            switch value.lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    public var intValue: Int? {
        guard let value = doubleValue, value.isFinite else { return nil }
        return Int(value.rounded())
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            // Whole numbers print as `2`, not `2.0`, because these end up in
            // error messages and scene names.
            return value == value.rounded() && abs(value) < 1e15
                ? String(Int(value))
                : String(value)
        case .bool(let value): return String(value)
        default: return nil
        }
    }

    public var arrayValue: [ControlValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    // MARK: Construction

    public init(_ value: Bool) { self = .bool(value) }
    public init(_ value: Int) { self = .number(Double(value)) }
    public init(_ value: Double) { self = .number(value) }
    public init(_ value: String) { self = .string(value) }
    public init(_ value: [ControlValue]) { self = .array(value) }
    public init(_ value: [String: ControlValue]) { self = .object(value) }

    /// Deliberately not an `init(String?)` overload: with Swift's implicit
    /// promotion to optional, a plain string literal could pick either one.
    public static func string(orNull value: String?) -> ControlValue {
        value.map { ControlValue.string($0) } ?? .null
    }
}

// MARK: - Messages

public struct ControlRequest: Codable, Equatable, Sendable {
    public var id: ControlValue?
    public var command: String
    public var params: ControlValue?

    public init(id: ControlValue? = nil, command: String, params: ControlValue? = nil) {
        self.id = id
        self.command = command
        self.params = params
    }

    /// Reads one parameter, treating a missing `params` object as an empty one.
    public func param(_ key: String) -> ControlValue? {
        params?[key]
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public var id: ControlValue?
    public var ok: Bool
    public var result: ControlValue?
    public var error: String?

    public init(
        id: ControlValue? = nil,
        ok: Bool,
        result: ControlValue? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
    }

    public static func success(
        id: ControlValue?,
        _ result: ControlValue = .object([:])
    ) -> ControlResponse {
        ControlResponse(id: id, ok: true, result: result)
    }

    public static func failure(id: ControlValue?, _ message: String) -> ControlResponse {
        ControlResponse(id: id, ok: false, error: message)
    }
}

/// An unsolicited push, sent to clients that asked for one with
/// `events.subscribe`.
///
/// Without this a Stream Deck key can only show what it last did, not what is
/// true: switching scenes with ⌥3 or in the app itself would leave every key on
/// the deck lit for the wrong one. Polling would close that gap, but at the
/// price of waking the app several times a second forever.
///
/// A client tells the two message kinds apart by shape — a response carries
/// `ok`, an event carries `event` — so a single reader can handle both.
public struct ControlEvent: Codable, Equatable, Sendable {
    public var event: String
    public var state: ControlValue

    public init(event: String = ControlEvent.stateChanged, state: ControlValue) {
        self.event = event
        self.state = state
    }

    public static let stateChanged = "state"
}

// MARK: - Codec

public enum ControlCodec {
    /// Sorted keys so that a response is byte-for-byte reproducible, which is
    /// what makes the tests below able to compare against a literal — and what
    /// lets the event broadcaster suppress a push whose bytes have not changed.
    public static func encode(_ response: ControlResponse) throws -> Data {
        try line(response)
    }

    public static func encode(_ event: ControlEvent) throws -> Data {
        try line(event)
    }

    private static func line<Message: Encodable>(_ message: Message) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(message)
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: Data) throws -> ControlRequest {
        try JSONDecoder().decode(ControlRequest.self, from: line)
    }
}

/// Commands the socket answers itself, because a subscription belongs to one
/// connection rather than to the app's state.
public enum ControlSubscriptionCommand {
    public static let subscribe = "events.subscribe"
    public static let unsubscribe = "events.unsubscribe"
}

// MARK: - Framing

/// Splits a byte stream into newline-delimited messages.
///
/// A socket read is not a message: one `recv` can carry half a request, or three
/// of them. Keeping this separate from the socket is what lets the awkward cases
/// — a split in the middle of a multi-byte character, a client that never sends
/// a newline — be tested without opening one.
public struct LineFramer {
    /// A client that opens the socket and streams megabytes without a newline
    /// would otherwise grow this buffer until the app dies. There is no
    /// legitimate request anywhere near this size.
    public static let maximumLineLength = 1 << 20

    private var buffer = Data()

    public init() {}

    public var isOverflowing: Bool { buffer.count > Self.maximumLineLength }

    /// Appends a chunk and returns whatever complete lines it finished.
    /// Empty lines are dropped, so a stray blank line is not a parse error.
    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        guard buffer.contains(0x0A) else { return [] }

        var lines: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            let line = buffer[start..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            start = buffer.index(after: newline)
        }
        buffer = Data(buffer[start...])
        return lines
    }
}

// MARK: - Socket location

public enum ControlSocket {
    public static let fileName = "control.sock"

    /// The hard limit on `sockaddr_un.sun_path`, which is 104 bytes on Darwin
    /// including the terminator. Worth checking rather than discovering: `bind`
    /// does not truncate, it fails, and the app group container sits under the
    /// user's home directory, so a long enough user name pushes a perfectly
    /// ordinary install over the edge.
    public static let maximumPathLength = 104

    public static func url(inContainer container: URL) -> URL {
        container.appendingPathComponent(fileName)
    }

    public static func isUsable(path: String) -> Bool {
        !path.isEmpty && path.utf8.count < maximumPathLength
    }
}
