import Foundation
import Testing
@testable import Tachikoma

struct TypedValueTests {
    @Test
    func `foundation numbers remain distinct from booleans`() throws {
        let data = Data(#"{"zero":0,"one":1,"flag":true,"large":9007199254740993,"max":9223372036854775807}"#.utf8)
        let json = try JSONSerialization.jsonObject(with: data)
        let value = try TypedValue.fromJSON(json)
        #expect(value == .object([
            "zero": .int(0), "one": .int(1), "flag": .bool(true),
            "large": .int(9_007_199_254_740_993), "max": .int(.max),
        ]))
    }

    @Test(arguments: [Double(Int.max), Double(Int.min).nextDown, 1e100])
    func `large numbers decode without integer overflow`(_ number: Double) throws {
        let data = try JSONEncoder().encode(number)
        #expect(try JSONDecoder().decode(TypedValue.self, from: data) == .double(number))
        #expect(try TypedValue.fromJSON(number) == .double(number))
        let wrapped = try AnyAgentToolValue.fromJSON(NSNumber(value: number))
        #expect(wrapped.intValue == nil)
        #expect(wrapped.doubleValue == number)
    }

    @Test(arguments: [TypedValue.null, .bool(true), .int(1), .double(1.5), .string("hello")])
    func `scalar codable conversions`(_ value: TypedValue) throws {
        #expect(try TypedValue(from: value) == value)
        #expect(try value.decode(as: TypedValue.self) == value)
    }

    @Test
    func `exact integer boundaries remain integers`() throws {
        for value in [Int.min, -1, 0, 1, 9_007_199_254_740_993, Int.max] {
            #expect(try TypedValue.fromJSON(value) == .int(value))
            #expect(try JSONDecoder().decode(TypedValue.self, from: JSONEncoder().encode(value)) == .int(value))
            #expect(try Int.fromJSON(value) == value)
        }
        #expect(try Int.fromJSON(42.0) == 42)
    }

    @Test(arguments: [1.5, Double(Int.max), Double(Int.min).nextDown, .infinity, -.infinity, .nan])
    func `integer tool inputs reject lossy numbers`(_ number: Double) {
        #expect(throws: TachikomaError.self) { try Int.fromJSON(number) }
        #expect(throws: TachikomaError.self) { try Int.fromJSON(NSNumber(value: number)) }
    }

    @Test
    func `integer tool inputs reject booleans`() {
        #expect(throws: TachikomaError.self) { try Int.fromJSON(true) }
        #expect(throws: TachikomaError.self) { try Int.fromJSON(NSNumber(value: false)) }
    }
}
