import Foundation

// MARK: - Provider Helper Types

/// A coding key that can represent any string
public struct AnyCodingKey: CodingKey {
    public let stringValue: String
    public let intValue: Int?

    public init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    public init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Dynamic coding key for encoding arbitrary JSON structures
public struct DynamicCodingKey: CodingKey {
    public let stringValue: String
    public let intValue: Int?

    public init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    public init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }

    public init(stringLiteral value: String) {
        self.stringValue = value
        self.intValue = nil
    }
}

// MARK: - JSON Encoding Helpers

/// Encode dictionary entries as JSON values, describing unsupported values as strings.
public func encodeAnyValue(
    _ value: Any,
    to container: inout KeyedEncodingContainer<DynamicCodingKey>,
) throws {
    guard let dictionary = value as? [String: Any] else { return }
    for (key, value) in dictionary {
        try container.encode(
            AnyEncodable(value, stringifyUnsupportedValues: true),
            forKey: DynamicCodingKey(stringLiteral: key),
        )
    }
}
