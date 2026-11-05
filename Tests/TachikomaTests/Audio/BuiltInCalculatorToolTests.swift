import Foundation
import Testing
@testable import TachikomaAudio

@Suite("Built-in calculator expressions")
struct BuiltInCalculatorToolTests {
    @Test
    func `trailing operator returns error instead of trapping`() async {
        let result = await Self.registeredResult(for: "2 +")
        #expect(result == "Error: Could not evaluate expression")
    }

    @Test
    func `percent sign returns error instead of trapping`() async {
        let result = await Self.registeredResult(for: "50%")
        let direct = await CalculatorTool().execute(["expression": .string("50%")])
        #expect(result == "Error: Could not evaluate expression")
        #expect(direct == "Error: Could not evaluate expression")
    }

    @Test
    func `valid addition returns result`() async {
        let result = await Self.registeredResult(for: "2 + 2")
        let direct = await CalculatorTool().execute(["expression": .string("2 + 2")])
        #expect(result == "Result: 4")
        #expect(direct == "Result: 4")
    }

    @Test
    func `format specifiers and method calls return error`() async {
        let expressions = [
            "%d",
            "%@",
            "%K",
            "100%",
            "1 % 2",
            "FUNCTION(1, 'description')",
            "now()",
            "random()",
            "self",
            "",
            "   ",
        ]
        for expression in expressions {
            let result = await Self.registeredResult(for: expression)
            #expect(result == "Error: Could not evaluate expression", "\(expression)")
        }
    }

    @Test
    func `valid arithmetic keeps previous results`() async {
        let cases = [
            ("10 * 5", "Result: 50"),
            ("sqrt(16)", "Result: 4"),
            ("sqrt(16) + 1", "Result: 5"),
            ("sqrt(sqrt(81))", "Result: 3"),
            ("2^3", "Result: 8"),
            ("2 ** 3", "Result: 8"),
            ("2^3^2", "Result: 64"),
            ("1 / 2", "Result: 0"),
            ("-5 / 2", "Result: -2"),
            ("(2 + 3) * 4", "Result: 20"),
            ("2 + 3 * 4", "Result: 14"),
            ("10 - 3 - 2", "Result: 5"),
            ("10 / 4 * 2", "Result: 4"),
            ("(1 / 2) * 4", "Result: 0"),
            ("abs(-5) / 2", "Result: 2"),
            ("5.0 / 2", "Result: 2.5"),
            ("1.0 / 2", "Result: 0.5"),
            ("5 / -2", "Result: -2"),
            ("-5 / -2", "Result: 2"),
            ("4 * 2 ** 3", "Result: 32"),
            ("2*3**2", "Result: 18"),
            ("999999999999999999 * 2", "Result: 1999999999999999998"),
            ("9999999999999999999", "Result: 9999999999999999999"),
            ("-2**2", "Result: 4"),
            ("(-2)**3", "Result: -8"),
            ("2**-2", "Result: 0.25"),
            ("3.5 + 1.5", "Result: 5"),
            (".5 + .5", "Result: 1"),
            ("1e2", "Result: 100"),
            ("0x10 + 1", "Result: 17"),
            ("0002", "Result: 2"),
            ("--4", "Result: 4"),
            ("4--3", "Result: 7"),
            ("2 / 0", "Result: 0"),
            ("0**0", "Result: 1"),
            ("floor(-1.2)", "Result: -2"),
            ("ceiling(-1.2)", "Result: -1"),
            ("trunc(-1.9)", "Result: -1"),
            ("log(100)", "Result: 2"),
            ("ln(1)", "Result: 0"),
            ("exp(0)", "Result: 1"),
            ("2 * sqrt(9)", "Result: 6"),
            ("  8 / 2  ", "Result: 4"),
        ]
        for (expression, expected) in cases {
            let result = await Self.registeredResult(for: expression)
            #expect(result == expected, "\(expression) -> \(result)")
        }

        // These values are real numbers. Darwin's NSNumber text is the first
        // choice; any other text that parses back to the same value is accepted
        // so Linux Foundation can use its own number spelling.
        await Self.expectReal("(2 + 2.0) / 3", appleText: "Result: 1.333333333333333", value: 4.0 / 3.0)
        await Self.expectReal("(2 ** 3) / 3", appleText: "Result: 2.666666666666667", value: 8.0 / 3.0)
        await Self.expectReal("2.0 / 0", appleText: "Result: inf", value: .infinity)
        await Self.expectReal("sqrt(-1)", appleText: "Result: nan", value: .nan)
    }

    @Test
    func `real formatter prints a whole double without a fraction`() {
        #expect(ArithmeticExpression.render(4.0) == "4")
        #expect(ArithmeticExpression.render(3.5) == "3.5")
        #expect(ArithmeticExpression.render(-8.0) == "-8")
        #expect(ArithmeticExpression.render(100.0) == "100")
        #expect(ArithmeticExpression.render(-2.0) == "-2")
    }

    @Test
    func `registered calculator survives invalid then evaluates`() async {
        let registry = RealtimeToolRegistry()
        await registry.registerBuiltInTools()
        let trailing = await registry.execute(
            toolName: "calculate",
            arguments: #"{"expression":"2 +"}"#,
        )
        let percent = await registry.execute(
            toolName: "calculate",
            arguments: #"{"expression":"50%"}"#,
        )
        let valid = await registry.execute(
            toolName: "calculate",
            arguments: #"{"expression":"10 * 5"}"#,
        )
        #expect(trailing == "Error: Could not evaluate expression")
        #expect(percent == "Error: Could not evaluate expression")
        #expect(valid == "Result: 50")
    }

    /// Drives `RealtimeToolRegistry.registerBuiltInTools()` and `execute`,
    /// the entry `registerBuiltInTools()` uses for model tool calls.
    private static func registeredResult(for expression: String) async -> String {
        let registry = RealtimeToolRegistry()
        await registry.registerBuiltInTools()
        let data = try! JSONSerialization.data(withJSONObject: ["expression": expression])
        let arguments = String(bytes: data, encoding: .utf8) ?? ""
        return await registry.execute(toolName: "calculate", arguments: arguments)
    }

    private static func expectReal(
        _ expression: String,
        appleText: String,
        value: Double,
    ) async {
        let result = await registeredResult(for: expression)
        if result == appleText {
            return
        }
        let prefix = "Result: "
        guard result.hasPrefix(prefix), let parsed = Double(result.dropFirst(prefix.count)) else {
            #expect(result == appleText, "\(expression) -> \(result)")
            return
        }
        if value.isNaN {
            #expect(parsed.isNaN, "\(expression) -> \(result)")
        } else if value.isInfinite {
            #expect(parsed.isInfinite && parsed.sign == value.sign, "\(expression) -> \(result)")
        } else {
            #expect(abs(parsed - value) < 0.000_000_000_001, "\(expression) -> \(result)")
        }
    }
}
