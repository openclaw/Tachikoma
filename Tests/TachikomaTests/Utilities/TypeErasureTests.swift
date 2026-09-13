import Foundation
import Testing
@testable import Tachikoma

struct TypeErasureTests {
    @Test(arguments: [false, true])
    func `Boxed floating-point negative zero retains its sign`(publicHelper: Bool) throws {
        let values: [String: Any] = [
            "double": NSNumber(value: -0.0),
            "float": NSNumber(value: -Float.zero),
        ]
        let decoded = try JSONDecoder().decode(
            [String: Double].self,
            from: self.encode(values, publicHelper: publicHelper),
        )
        #expect(decoded["double"]?.sign == .minus)
        #expect(decoded["float"]?.sign == .minus)
    }

    @Test(arguments: [false, true])
    func `Foundation JSON preserves boolean numeric and null types`(publicHelper: Bool) throws {
        struct Payload: Decodable, Equatable {
            struct Nested: Decodable, Equatable {
                let flags: [Bool?]
                let counts: [String: Int]
            }

            let flag: Bool
            let zero: Int
            let one: Int
            let missing: String?
            let nested: Nested
        }
        let source = Data(
            #"{"flag":true,"zero":0,"one":1,"missing":null,"nested":{"flags":[true,false,null],"counts":{"zero":0,"one":1}}}"#
                .utf8,
        )
        let expected = try JSONDecoder().decode(Payload.self, from: source)
        let dictionary = try #require(JSONSerialization.jsonObject(with: source) as? [String: Any])
        let data = try self.encode(dictionary, publicHelper: publicHelper)
        #expect(try JSONDecoder().decode(Payload.self, from: data) == expected)
    }

    @Test(arguments: [false, true])
    func `Numbers retain width and precision`(publicHelper: Bool) throws {
        struct Numbers: Decodable {
            let signed: Int64
            let unsigned: UInt64
            let precise: Double
            let decimal: Decimal
            let nativeUnsigned: UInt64
        }
        let decimal = NSDecimalNumber(string: "12345678901234567890.123456789")
        let values: [String: Any] = [
            "signed": NSNumber(value: Int64.min),
            "unsigned": NSNumber(value: UInt64.max),
            "precise": NSNumber(value: 0.123456789012345),
            "decimal": decimal,
            "nativeUnsigned": UInt64.max,
        ]
        let result = try JSONDecoder().decode(Numbers.self, from: self.encode(values, publicHelper: publicHelper))
        #expect(result.signed == Int64.min)
        #expect(result.unsigned == UInt64.max)
        #expect(result.precise == 0.123456789012345)
        #expect(result.decimal == decimal.decimalValue)
        #expect(result.nativeUnsigned == UInt64.max)
    }

    @Test
    func `Public helper retains its nested description fallback`() throws {
        struct CustomValue: Encodable, CustomStringConvertible {
            var description: String {
                "description"
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode("encoded")
            }
        }
        struct Result: Decodable {
            let values: [String]
            let nested: [String: String]
        }
        let value: [String: Any] = ["values": [CustomValue()], "nested": ["value": CustomValue()]]
        let publicResult = try JSONDecoder().decode(Result.self, from: self.encode(value, publicHelper: true))
        #expect(publicResult.values == ["description"])
        #expect(publicResult.nested == ["value": "description"])
        let internalResult = try JSONDecoder().decode(Result.self, from: self.encode(value, publicHelper: false))
        #expect(internalResult.values == ["encoded"])
        #expect(internalResult.nested == ["value": "encoded"])
    }

    @Test(arguments: [false, true])
    func `Nonfinite JSON numbers still throw`(publicHelper: Bool) {
        #expect(throws: EncodingError.self) {
            try self.encode(["number": NSNumber(value: Double.infinity)], publicHelper: publicHelper)
        }
    }

    private func encode(_ value: [String: Any], publicHelper: Bool) throws -> Data {
        if publicHelper {
            try JSONEncoder().encode(PublicJSONPayload(value: value))
        } else {
            try JSONEncoder().encode(AnyEncodable(value))
        }
    }

    @Test
    func `AnyEncodable encodes heterogenous dictionaries`() throws {
        let payload: [String: Any] = [
            "string": "hello",
            "int": 42,
            "double": 3.14,
            "bool": true,
            "array": ["nested", 7, ["deep": "value"]],
            "dict": ["flag": false, "count": 2],
            "null": NSNull(),
        ]

        let encoded = try JSONEncoder().encode(AnyEncodable(payload))
        let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]

        #expect(json?["string"] as? String == "hello")
        #expect(json?["int"] as? Int == 42)
        #expect(json?["double"] as? Double == 3.14)
        #expect(json?["bool"] as? Bool == true)
        #expect((json?["array"] as? [Any])?.count == 3)

        if let dict = json?["dict"] as? [String: Any] {
            #expect(dict["flag"] as? Bool == false)
            #expect(dict["count"] as? Int == 2)
        } else {
            Issue.record("Expected nested dictionary")
        }

        #expect(json?["null"] is NSNull)
    }

    @Test
    func `AnyDecodable decodes heterogenous JSON`() throws {
        let jsonData = """
        {
            "title": "example",
            "value": 1.5,
            "items": [1, "two", {"three": 3}],
            "options": {"enabled": true, "threshold": 0.25},
            "missing": null
        }
        """.utf8Data()

        let decoded = try JSONDecoder().decode(AnyDecodable.self, from: jsonData)
        guard let root = decoded.value as? [String: Any] else {
            Issue.record("Expected dictionary root")
            return
        }

        #expect(root["title"] as? String == "example")
        #expect(root["value"] as? Double == 1.5)
        #expect(root["missing"] is NSNull)

        if let items = root["items"] as? [Any] {
            #expect(items.count == 3)
            #expect(items.first as? Int == 1)
            #expect(items.dropLast().last as? String == "two")
            if let third = items.last as? [String: Any] {
                #expect(third["three"] as? Int == 3)
            } else {
                Issue.record("Expected nested dictionary in array")
            }
        } else {
            Issue.record("Expected array for items")
        }

        if let options = root["options"] as? [String: Any] {
            #expect(options["enabled"] as? Bool == true)
            #expect(options["threshold"] as? Double == 0.25)
        } else {
            Issue.record("Expected options dictionary")
        }
    }
}

private struct PublicJSONPayload: Encodable {
    let value: [String: Any]

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try encodeAnyValue(self.value, to: &container)
    }
}
