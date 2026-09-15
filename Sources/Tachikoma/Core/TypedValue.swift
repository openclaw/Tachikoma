import Foundation

/// A type-safe enum for representing heterogeneous values in a strongly-typed manner.
/// This replaces AnyCodable, AnyAgentToolValue and other type-erased patterns throughout the codebase.
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum TypedValue: Codable, Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([TypedValue])
    case object([String: TypedValue])

    // MARK: - Type Information

    /// The type category of this value
    public enum ValueType: String, Codable, Sendable {
        case null
        case boolean
        case integer
        case number
        case string
        case array
        case object
    }

    /// Returns the type of this value
    public var valueType: ValueType {
        switch self {
        case .null: .null
        case .bool: .boolean
        case .int: .integer
        case .double: .number
        case .string: .string
        case .array: .array
        case .object: .object
        }
    }

    // MARK: - Convenience Accessors

    /// Returns the value as a Bool if it is one
    public var boolValue: Bool? {
        if case let .bool(value) = self {
            return value
        }
        return nil
    }

    /// Returns the value as an Int if it is one
    public var intValue: Int? {
        if case let .int(value) = self {
            return value
        }
        return nil
    }

    /// Returns the value as a Double, converting from Int if needed
    public var doubleValue: Double? {
        switch self {
        case let .double(value): value
        case let .int(value): Double(value)
        default: nil
        }
    }

    /// Returns the value as a String if it is one
    public var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    /// Returns the value as an array if it is one
    public var arrayValue: [TypedValue]? {
        if case let .array(value) = self {
            return value
        }
        return nil
    }

    /// Returns the value as an object/dictionary if it is one
    public var objectValue: [String: TypedValue]? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }

    /// Returns true if this is a null value
    public var isNull: Bool {
        if case .null = self {
            return true
        }
        return false
    }

    // MARK: - JSON Conversion

    /// Convert to a JSON-compatible Any type
    public func toJSON() -> Any {
        // Convert to a JSON-compatible Any type
        switch self {
        case .null:
            NSNull()
        case let .bool(value):
            value
        case let .int(value):
            value
        case let .double(value):
            value
        case let .string(value):
            value
        case let .array(values):
            values.map { $0.toJSON() }
        case let .object(dict):
            dict.mapValues { $0.toJSON() }
        }
    }

    /// Create from a JSON-compatible Any type
    public static func fromJSON(_ json: Any) throws -> TypedValue {
        // Create from a JSON-compatible Any type
        switch json {
        case is NSNull:
            return .null
        case let number as NSNumber:
            return try .from(AnyAgentToolValue.fromJSON(number))
        case let string as String:
            return .string(string)
        case let array as [Any]:
            let values = try array.map { try TypedValue.fromJSON($0) }
            return .array(values)
        case let dict as [String: Any]:
            let values = try dict.mapValues { try TypedValue.fromJSON($0) }
            return .object(values)
        default:
            throw TypedValueError.unsupportedType(type: String(describing: type(of: json)))
        }
    }

    // MARK: - Codable Implementation

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            if let int = Int(exactly: double) {
                self = .int(int)
            } else {
                self = .double(double)
            }
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([TypedValue].self) {
            self = .array(array)
        } else if let dict = try? container.decode([String: TypedValue].self) {
            self = .object(dict)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unable to decode TypedValue from container",
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(values):
            try container.encode(values)
        case let .object(dict):
            try container.encode(dict)
        }
    }
}

// MARK: - Error Types

public enum TypedValueError: LocalizedError {
    case unsupportedType(type: String)
    case conversionFailed(from: String, to: String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedType(type):
            "Unsupported type for TypedValue: \(type)"
        case let .conversionFailed(from, to):
            "Failed to convert from \(from) to \(to)"
        }
    }
}

// MARK: - Convenience Initializers

extension TypedValue {
    /// Create from any Encodable value
    public init(from value: some Encodable) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }

    /// Decode into a specific Decodable type
    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

// MARK: - Collection Helpers

extension TypedValue {
    /// Create from a dictionary with string keys
    public static func fromDictionary(_ dict: [String: Any]) throws -> TypedValue {
        // Create from a dictionary with string keys
        try self.fromJSON(dict)
    }

    /// Convert to dictionary if this is an object type
    public func toDictionary() throws -> [String: Any] {
        // Convert to dictionary if this is an object type
        guard case let .object(dict) = self else {
            throw TypedValueError.conversionFailed(from: "\(self.valueType)", to: "dictionary")
        }
        return dict.mapValues { $0.toJSON() }
    }
}

// MARK: - ExpressibleBy Conformances

extension TypedValue: ExpressibleByNilLiteral {
    public init(nilLiteral _: ()) {
        self = .null
    }
}

extension TypedValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension TypedValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension TypedValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension TypedValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension TypedValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: TypedValue...) {
        self = .array(elements)
    }
}

extension TypedValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, TypedValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MARK: - AnyAgentToolValue Compatibility

extension TypedValue {
    /// Convert from AnyAgentToolValue for backwards compatibility
    public static func from(_ value: AnyAgentToolValue) -> TypedValue {
        // Convert from AnyAgentToolValue for backwards compatibility
        if value.isNull {
            .null
        } else if let bool = value.boolValue {
            .bool(bool)
        } else if let int = value.intValue {
            .int(int)
        } else if let double = value.doubleValue {
            .double(double)
        } else if let string = value.stringValue {
            .string(string)
        } else if let array = value.arrayValue {
            .array(array.map { self.from($0) })
        } else if let object = value.objectValue {
            .object(object.mapValues { self.from($0) })
        } else {
            .null
        }
    }

    /// Convert to AnyAgentToolValue for backwards compatibility
    public func toAnyAgentToolValue() -> AnyAgentToolValue {
        // Convert to AnyAgentToolValue for backwards compatibility
        switch self {
        case .null:
            AnyAgentToolValue(null: ())
        case let .bool(v):
            AnyAgentToolValue(bool: v)
        case let .int(v):
            AnyAgentToolValue(int: v)
        case let .double(v):
            AnyAgentToolValue(double: v)
        case let .string(v):
            AnyAgentToolValue(string: v)
        case let .array(values):
            AnyAgentToolValue(array: values.map { $0.toAnyAgentToolValue() })
        case let .object(dict):
            AnyAgentToolValue(object: dict.mapValues { $0.toAnyAgentToolValue() })
        }
    }
}
