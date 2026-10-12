import Foundation

/// Raw JSON tree. Used as the source of truth for fields the app does not know about,
/// so they survive a read → write round trip (ADR-002).
///
/// Integers that fit Int64 are kept as `.integer`: a Double has only 53 bits of mantissa, so ids like
/// 9007199254740993 would otherwise be silently changed on save. Everything else is `.number(Double)`.
/// `.integer(n) == .number(d)` holds when `d` is exactly `n`, so callers need not care which case they get.
enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// For `.integer` beyond 2^53 this is the nearest Double.
    var doubleValue: Double? {
        switch self {
        case .number(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }

    /// `nil` for fractions and out-of-range values. `Int(exactly:)` matters: `Double(Int.max)` rounds up
    /// to 2^63, so a range check followed by `Int(value)` would trap on exactly 2^63.
    var intValue: Int? {
        switch self {
        case .integer(let value): Int(exactly: value)
        case .number(let value): Int(exactly: value)
        default: nil
        }
    }

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.integer(a), .integer(b)): a == b
        case let (.number(a), .number(b)): a == b
        case let (.integer(i), .number(d)), let (.number(d), .integer(i)): Double(exactly: i) == d
        case let (.string(a), .string(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)): a == b
        default: false
        }
    }

    var isNull: Bool { self == .null }

    /// Shallow merge: keys from `other` overwrite, all other existing keys are preserved.
    /// A non-object receiver is treated as an empty object.
    func merging(_ other: [String: JSONValue]) -> JSONValue {
        var result = objectValue ?? [:]
        for (key, value) in other {
            result[key] = value
        }
        return .object(result)
    }

    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try makeEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONValue.makeDecoder().decode(type, from: data)
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
