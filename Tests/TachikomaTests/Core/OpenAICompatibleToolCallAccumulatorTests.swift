import Foundation
import Testing
@testable import Tachikoma

struct OpenAICompatibleToolCallAccumulatorTests {
    @Test
    func `Interleaved calls preserve first seen order and recursive JSON`() throws {
        var accumulator = OpenAICompatibleToolCallAccumulator()
        try accumulator.append(Self.fragment(index: 1, id: "second", name: "lookup", arguments: #"{"nested":"#))
        try accumulator.append(Self.fragment(index: 0, id: "first", name: "empty", arguments: "{}"))
        try accumulator.append(Self.fragment(index: 1, arguments: #"{"values":[true,false,null,1,1.5,"a\"😀"]}}"#))
        let calls = try accumulator.finish()
        #expect(calls.map(\.id) == ["second", "first"])
        #expect(calls.map(\.name) == ["lookup", "empty"])
        let expected = try JSONDecoder().decode(
            [String: AnyAgentToolValue].self,
            from: Data(#"{"nested":{"values":[true,false,null,1,1.5,"a\"😀"]}}"#.utf8),
        )
        #expect(calls[0].arguments == expected)
        #expect(calls[1].arguments.isEmpty)
    }

    @Test(arguments: ["{", #"{"query":"#, "[]", "null", "true", "42"])
    func `Invalid or incomplete argument objects refuse the entire batch`(arguments: String) throws {
        var accumulator = OpenAICompatibleToolCallAccumulator()
        try accumulator.append(Self.fragment(index: 0, id: "valid", name: "lookup", arguments: "{}"))
        try accumulator.append(Self.fragment(index: 1, id: "invalid", name: "lookup", arguments: arguments))
        #expect(throws: TachikomaError.self) { try accumulator.finish() }
    }

    @Test
    func `Indexed metadata can precede or follow argument fragments`() throws {
        var accumulator = OpenAICompatibleToolCallAccumulator()
        try accumulator.append(Self.fragment(index: 0, arguments: "{"))
        try accumulator.append(Self.fragment(index: 0, id: "call", name: "lookup"))
        try accumulator.append(Self.fragment(index: 0, id: "call", name: "lookup", arguments: "}"))
        let calls = try accumulator.finish()
        #expect(calls.count == 1)
        #expect(calls[0].id == "call")
        #expect(calls[0].name == "lookup")
        #expect(calls[0].arguments.isEmpty)
    }

    @Test(arguments: [false, true], ["", "{}"])
    func `Complete empty argument forms remain equivalent`(indexed: Bool, arguments: String) throws {
        var accumulator = OpenAICompatibleToolCallAccumulator()
        try accumulator.append(Self.fragment(
            index: indexed ? 0 : nil,
            id: "empty",
            name: "lookup",
            arguments: arguments,
        ))
        let calls = try accumulator.finish()
        #expect(calls.count == 1)
        #expect(calls[0].id == "empty")
        #expect(calls[0].arguments.isEmpty)
    }

    @Test
    func `Unindexed complete calls remain supported without inventing fragment associations`() throws {
        var accumulator = OpenAICompatibleToolCallAccumulator()
        try accumulator.append(Self.fragment(id: "a", name: "first", arguments: "{}"))
        try accumulator.append(Self.fragment(name: "second", arguments: "{}"))
        let calls = try accumulator.finish()
        #expect(calls.map(\.name) == ["first", "second"])
        #expect(calls[0].id == "a")
        #expect(!calls[1].id.isEmpty)
        #expect(calls[1].id != "a")
        #expect(throws: TachikomaError.self) {
            try accumulator.append(Self.fragment(arguments: "}"))
        }
    }

    @Test
    func `Conflicting indexed identities and negative indices are refused`() throws {
        var accumulator = OpenAICompatibleToolCallAccumulator()
        try accumulator.append(Self.fragment(index: 0, id: "a", name: "lookup", arguments: "{}"))
        #expect(throws: TachikomaError.self) {
            try accumulator.append(Self.fragment(index: 0, id: "b"))
        }
        #expect(throws: TachikomaError.self) {
            try accumulator.append(Self.fragment(index: 0, name: "different"))
        }
        #expect(throws: TachikomaError.self) {
            try accumulator.append(Self.fragment(index: -1, name: "lookup", arguments: "{}"))
        }
    }

    @Test
    func `Unnamed and duplicate identified calls are refused`() throws {
        var unnamed = OpenAICompatibleToolCallAccumulator()
        try unnamed.append(Self.fragment(index: 0, arguments: "{}"))
        #expect(throws: TachikomaError.self) { try unnamed.finish() }
        var missingArguments = OpenAICompatibleToolCallAccumulator()
        try missingArguments.append(Self.fragment(index: 0, name: "lookup"))
        #expect(throws: TachikomaError.self) { try missingArguments.finish() }
        var duplicated = OpenAICompatibleToolCallAccumulator()
        try duplicated.append(Self.fragment(index: 0, id: "same", name: "lookup", arguments: "{}"))
        try duplicated.append(Self.fragment(index: 1, id: "same", name: "lookup", arguments: "{}"))
        #expect(throws: TachikomaError.self) { try duplicated.finish() }
        #expect(try OpenAICompatibleToolCallAccumulator().finish().isEmpty)
    }

    private static func fragment(
        index: Int? = nil,
        id: String? = nil,
        name: String? = nil,
        arguments: String? = nil,
    )
        -> OpenAIStreamChunk.Delta.ToolCall
    {
        .init(index: index, id: id, type: "function", function: .init(name: name, arguments: arguments))
    }
}
