#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Arithmetic subset previously accepted by `NSExpression` after `^` was
/// rewritten to `**`. Format specifiers, method calls, and predicate syntax
/// are not in this grammar, so they return nil instead of raising.
enum ArithmeticExpression {
    static func evaluate(_ expression: String) -> String? {
        var parser = Parser(expression)
        guard let value = parser.parseExpression(), parser.reachedEnd() else {
            return nil
        }
        return value.rendered
    }

    /// Linux `NSNumber.stringValue` is `Double.description`, so a whole
    /// value is spelled `4.0`. Darwin and the previous calculator spell it
    /// as `4`. A fractional value such as `3.5` stays on `NSNumber`.
    static func render(_ value: Double) -> String {
        guard value.isFinite, value == value.rounded(.towardZero) else {
            return NSNumber(value: value).stringValue
        }
        return self.wholeRealText(value)
    }

    /// Prefer plain integer digits when the platform spelling is `4` or `4.0`.
    /// Larger whole values that Darwin already prints in scientific form stay
    /// as that spelling, still without a trailing `.0`.
    private static func wholeRealText(_ value: Double) -> String {
        let platform = NSNumber(value: value).stringValue
        if let exact = Int64(exactly: value) {
            let digits = exact == 0 && value.sign == .minus ? "-0" : String(exact)
            if platform == digits || platform == "\(digits).0" {
                return digits
            }
        }
        return self.withoutTrailingWholeFraction(platform)
    }

    private static func withoutTrailingWholeFraction(_ spelled: String) -> String {
        guard spelled.hasSuffix(".0") else { return spelled }
        let digits = spelled.dropLast(2)
        let body = digits.first == "-" ? digits.dropFirst() : Substring(digits)
        guard !body.isEmpty, body.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            return spelled
        }
        return String(digits)
    }

    /// "/" of two integers truncates toward zero. `1 / 2` stays 0.
    private static func truncatingDivide(_ lhs: Decimal, by rhs: Decimal) -> Decimal {
        if rhs == 0 {
            return 0
        }
        var quotient = lhs / rhs
        var truncated = Decimal()
        let mode: NSDecimalNumber.RoundingMode = quotient < 0 ? .up : .down
        NSDecimalRound(&truncated, &quotient, 0, mode)
        return truncated
    }

    private enum Value {
        case integer(Decimal)
        case real(Double)

        var rendered: String {
            switch self {
            case let .integer(value):
                NSDecimalNumber(decimal: value).stringValue
            case let .real(value):
                ArithmeticExpression.render(value)
            }
        }

        private var asReal: Double {
            switch self {
            case let .integer(value):
                NSDecimalNumber(decimal: value).doubleValue
            case let .real(value):
                value
            }
        }

        func adding(_ other: Value) -> Value {
            switch (self, other) {
            case let (.integer(lhs), .integer(rhs)):
                .integer(lhs + rhs)
            default:
                .real(self.asReal + other.asReal)
            }
        }

        func subtracting(_ other: Value) -> Value {
            switch (self, other) {
            case let (.integer(lhs), .integer(rhs)):
                .integer(lhs - rhs)
            default:
                .real(self.asReal - other.asReal)
            }
        }

        func multiplying(by other: Value) -> Value {
            switch (self, other) {
            case let (.integer(lhs), .integer(rhs)):
                .integer(lhs * rhs)
            default:
                .real(self.asReal * other.asReal)
            }
        }

        func dividing(by other: Value) -> Value {
            switch (self, other) {
            case let (.integer(lhs), .integer(rhs)):
                .integer(ArithmeticExpression.truncatingDivide(lhs, by: rhs))
            default:
                .real(self.asReal / other.asReal)
            }
        }

        /// `^` and `**` are exponentiation. The previous tool rewrote `^` to `**`
        /// before evaluating, and that result was a real number (`(2 ** 3) / 3`
        /// is not integer division).
        func raising(to other: Value) -> Value {
            .real(Math.power(self.asReal, other.asReal))
        }

        func negated() -> Value {
            switch self {
            case let .integer(value):
                .integer(-value)
            case let .real(value):
                .real(-value)
            }
        }

        func absolute() -> Value {
            switch self {
            case let .integer(value):
                .integer(value < 0 ? -value : value)
            case let .real(value):
                .real(abs(value))
            }
        }

        static func apply(_ name: String, to argument: Value) -> Value? {
            switch name {
            case "abs":
                argument.absolute()
            case "sqrt":
                .real(argument.asReal.squareRoot())
            case "floor":
                .real(Math.floor(argument.asReal))
            case "ceiling":
                .real(Math.ceiling(argument.asReal))
            case "trunc":
                .real(Math.truncate(argument.asReal))
            case "ln":
                .real(Math.naturalLog(argument.asReal))
            case "log":
                .real(Math.log10(argument.asReal))
            case "exp":
                .real(Math.exp(argument.asReal))
            default:
                nil
            }
        }
    }

    /// Qualify libm so Darwin and Glibc do not leave `log`/`pow` ambiguous.
    private enum Math {
        static func power(_ base: Double, _ exponent: Double) -> Double {
            #if canImport(Darwin)
            Darwin.pow(base, exponent)
            #else
            Glibc.pow(base, exponent)
            #endif
        }

        static func floor(_ value: Double) -> Double {
            #if canImport(Darwin)
            Darwin.floor(value)
            #else
            Glibc.floor(value)
            #endif
        }

        static func ceiling(_ value: Double) -> Double {
            #if canImport(Darwin)
            Darwin.ceil(value)
            #else
            Glibc.ceil(value)
            #endif
        }

        static func truncate(_ value: Double) -> Double {
            #if canImport(Darwin)
            Darwin.trunc(value)
            #else
            Glibc.trunc(value)
            #endif
        }

        static func naturalLog(_ value: Double) -> Double {
            #if canImport(Darwin)
            Darwin.log(value)
            #else
            Glibc.log(value)
            #endif
        }

        static func log10(_ value: Double) -> Double {
            #if canImport(Darwin)
            Darwin.log10(value)
            #else
            Glibc.log10(value)
            #endif
        }

        static func exp(_ value: Double) -> Double {
            #if canImport(Darwin)
            Darwin.exp(value)
            #else
            Glibc.exp(value)
            #endif
        }
    }

    private struct Parser {
        private let characters: [Character]
        private var index = 0

        init(_ source: String) {
            self.characters = Array(source)
        }

        mutating func reachedEnd() -> Bool {
            self.skipWhitespace()
            return self.index == self.characters.count
        }

        mutating func parseExpression() -> Value? {
            guard var value = parseTerm() else { return nil }
            while true {
                if self.consume("+") {
                    guard let rhs = parseTerm() else { return nil }
                    value = value.adding(rhs)
                } else if self.consume("-") {
                    guard let rhs = parseTerm() else { return nil }
                    value = value.subtracting(rhs)
                } else {
                    break
                }
            }
            return value
        }

        private mutating func parseTerm() -> Value? {
            guard var value = parsePower() else { return nil }
            while true {
                // `**` belongs to exponentiation, which parsePower already consumed.
                // Do not treat the first star of a leftover `**` as multiplication.
                self.skipWhitespace()
                if self.lookingAt("**") {
                    break
                }
                if self.consume("*") {
                    guard let rhs = parsePower() else { return nil }
                    value = value.multiplying(by: rhs)
                } else if self.consume("/") {
                    guard let rhs = parsePower() else { return nil }
                    value = value.dividing(by: rhs)
                } else {
                    break
                }
            }
            return value
        }

        private mutating func parsePower() -> Value? {
            guard var value = parseUnary() else { return nil }
            while self.consume("**") || self.consume("^") {
                guard let rhs = parseUnary() else { return nil }
                value = value.raising(to: rhs)
            }
            return value
        }

        private mutating func parseUnary() -> Value? {
            if self.consume("+") {
                return self.parseUnary()
            }
            if self.consume("-") {
                guard let value = parseUnary() else { return nil }
                return value.negated()
            }
            return self.parsePrimary()
        }

        private mutating func parsePrimary() -> Value? {
            if self.consume("(") {
                guard let value = parseExpression(), consume(")") else { return nil }
                return value
            }
            if let name = parseIdentifier() {
                guard self.consume("("), let argument = parseExpression(), consume(")") else {
                    return nil
                }
                return Value.apply(name, to: argument)
            }
            return self.parseNumber()
        }

        private mutating func parseIdentifier() -> String? {
            self.skipWhitespace()
            guard let first = peek(), first.isASCII, first.isLetter else { return nil }
            let start = self.index
            self.index += 1
            while let character = peek(), character.isASCII, character.isLetter {
                self.index += 1
            }
            return String(self.characters[start..<self.index])
        }

        private mutating func parseNumber() -> Value? {
            self.skipWhitespace()
            if self.peek() == "0", let marker = peek(1), marker == "x" || marker == "X" {
                return self.parseHexadecimal()
            }

            let start = self.index
            var sawDigit = false
            while let character = peek(), isDigit(character) {
                sawDigit = true
                self.index += 1
            }

            var sawDot = false
            if self.peek() == ".", let fraction = peek(1), isDigit(fraction) {
                sawDot = true
                self.index += 1
                while let character = peek(), isDigit(character) {
                    self.index += 1
                }
            }

            var sawExponent = false
            if sawDigit || sawDot, let marker = peek(), marker == "e" || marker == "E" {
                let saved = self.index
                self.index += 1
                if let sign = peek(), sign == "+" || sign == "-" {
                    self.index += 1
                }
                var exponentDigits = 0
                while let character = peek(), isDigit(character) {
                    exponentDigits += 1
                    self.index += 1
                }
                if exponentDigits == 0 {
                    self.index = saved
                } else {
                    sawExponent = true
                }
            }

            guard sawDigit || sawDot else { return nil }
            let token = String(characters[start..<self.index])
            if !sawDot, !sawExponent {
                guard let decimal = Decimal(string: token) else { return nil }
                return .integer(decimal)
            }
            guard let real = Double(token) else { return nil }
            return .real(real)
        }

        private mutating func parseHexadecimal() -> Value? {
            self.index += 2
            let start = self.index
            while let character = peek(), character.isASCII, character.hexDigitValue != nil {
                self.index += 1
            }
            guard self.index > start else { return nil }
            var result = Decimal(0)
            let sixteen = Decimal(16)
            for character in self.characters[start..<self.index] {
                guard let digit = character.hexDigitValue else { return nil }
                result = result * sixteen + Decimal(digit)
            }
            return .integer(result)
        }

        private mutating func consume(_ token: String) -> Bool {
            self.skipWhitespace()
            guard self.lookingAt(token) else { return false }
            self.index += token.count
            return true
        }

        private func lookingAt(_ token: String) -> Bool {
            let end = self.index + token.count
            guard end <= self.characters.count else { return false }
            return String(self.characters[self.index..<end]) == token
        }

        private mutating func skipWhitespace() {
            while let character = peek(), character.isWhitespace {
                self.index += 1
            }
        }

        private func peek(_ offset: Int = 0) -> Character? {
            let next = self.index + offset
            guard self.characters.indices.contains(next) else { return nil }
            return self.characters[next]
        }

        private func isDigit(_ character: Character) -> Bool {
            character >= "0" && character <= "9"
        }
    }
}
