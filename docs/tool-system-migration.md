# Tool values and schemas

Current tool executors return `AnyAgentToolValue`. Tool calls carry typed arguments through `AgentToolArguments`; JSON conversion belongs at adapter boundaries.

## Create a tool

```swift
import Tachikoma

let add = createTool(
    name: "add",
    description: "Add two integers",
    parameters: [
        .init(name: "a", type: .integer, description: "First value"),
        .init(name: "b", type: .integer, description: "Second value")
    ],
    required: ["a", "b"]
) { arguments in
    let a = try arguments.integerValue("a")
    let b = try arguments.integerValue("b")
    return AnyAgentToolValue(int: a + b)
}
```

Pass `[add]` as the `tools` argument to `generateText`. The generation loop executes calls and includes the results in subsequent model requests, up to `maxSteps`.

## Represent JSON values

| Value | Constructor |
| --- | --- |
| String | `AnyAgentToolValue(string: "hello")` |
| Integer | `AnyAgentToolValue(int: 42)` |
| Floating-point number | `AnyAgentToolValue(double: 3.14)` |
| Boolean | `AnyAgentToolValue(bool: true)` |
| Null | `AnyAgentToolValue(null: ())` |
| Array | `AnyAgentToolValue(array: values)` |
| Object | `AnyAgentToolValue(object: fields)` |

Read values with `stringValue`, `intValue`, `doubleValue`, `boolValue`, `arrayValue`, `objectValue`, and `isNull`. Argument accessors such as `integerValue(_:)` throw when required input is missing or has the wrong type.

At a Foundation JSON boundary:

```swift
let value = try AnyAgentToolValue.fromJSON(["count": 42, "ready": true])
let json = try value.toJSON()
```

`AgentToolValue` is the protocol for values with a declared `agentValueType` and JSON conversion. `AnyAgentToolValue` erases the concrete value type for heterogeneous arguments and results. Earlier examples using an `AgentToolArgument` enum should use the constructors above.

## Preserve schemas

`AgentToolParameters` stores properties and required names. Parameters adapted from MCP can also retain the complete original schema in `sourceSchema`. Use `jsonSchema()` for provider serialization and `typedSchema()` when inspecting its recursive structure. Both paths preserve nested schemas; provider-specific adjustments are explicit serialization options.

The typed schema view retains constraints, unions, defaults, composition, conditionals, and unknown keywords. It preserves `$ref` without resolving it and does not perform runtime argument validation. Tool owners remain responsible for validating business rules before executing side effects.

For protocol-based typed executors, see `AgentToolProtocol` and `AnyAgentTool` in `Sources/Tachikoma/Tools/ToolExtensions.swift`. `TachikomaAgent` supplies additional builders and dynamic tool registries. See the [MCP guide](../Sources/TachikomaMCP/README.md#schema-fidelity) for adapter behavior.
