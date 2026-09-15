# Architecture

Tachikoma is a SwiftPM package with four library products and three command-line products. `Package.swift` declares the Swift and platform minimums. The libraries share model and tool types without making the core product depend on audio, agents, or MCP.

## Module boundaries

| Product | Owns | Depends on |
| --- | --- | --- |
| `Tachikoma` | Model selection, configuration/authentication, generation, provider adapters, tool values and schemas | Swift Log, Configuration, Algorithms, Crypto |
| `TachikomaAgent` | Conversation history, agent sessions, dynamic tool discovery and dispatch | Tachikoma, Swift Log |
| `TachikomaAudio` | Transcription, speech generation, recording, Realtime sessions and audio processing | Tachikoma, Swift Log |
| `TachikomaMCP` | MCP clients/transports, discovery, schema and result bridges | Tachikoma, Swift Log, MCP Swift SDK |

`ai-cli` and `gpt5cli` are examples built as executable products. `tachikoma` manages configuration and authentication. Their dependencies are declared in the root manifest.

## Generation and providers

`LanguageModel` selects a built-in model, a compatible endpoint, or a caller-supplied `ModelProvider`. Its nested catalogs describe model IDs and capabilities. `ModelSelector` and `ProviderParser` interpret user-facing identifiers; `ProviderFactory` creates the matching adapter.

The active provider protocol is `ModelProvider` in `Sources/Tachikoma/Models/ModelProvider.swift`. It exposes model metadata and accepts `ProviderRequest` values through `generateText(request:)` and `streamText(request:)`. `ModelInterface`, `ModelRequest`, and `ModelResponse` remain public compatibility types; new adapters should follow `ModelProvider`.

`Core/Generation.swift` implements the high-level generation functions. It resolves configuration, drives bounded tool-call steps, accumulates usage, and constructs provider-neutral results. Streaming produces `TextStreamDelta` values, including text, reasoning, tool calls, usage, and terminal status. `StreamTextResult.stream` exposes the asynchronous sequence.

Adapters live under `Sources/Tachikoma/Providers`. Hosted OpenAI-compatible services share `Core/OpenAICompatibleHelper.swift`; Anthropic, Google, Ollama, LM Studio, and the OpenAI Responses API retain their own wire formats. Anthropic and Ollama have separate implementation files. Shared reasoning endpoint identity belongs to Core because generation and multiple adapters use it.

`AsyncThrowingStream` is an event-delivery mechanism, not a guarantee of bounded buffering or producer backpressure. Owners of background tasks must cancel them when the consumer terminates. Some models buffer text until terminal status so a refusal can discard it safely; consult the provider's capabilities and `GenerationSettings.streamBuffering`.

## Messages, reasoning, and tools

`ModelMessage` is a struct with a role, content parts, identity, timestamp, channel, and metadata. Content parts carry text, images, provider reasoning, tool calls, and tool results. Agent conversations preserve these structured parts instead of reconstructing history from displayed text.

Provider-native reasoning is replayed only when its provider/model/endpoint identity matches the next request. This is a trust boundary: changing providers or credentials must not accidentally forward opaque history to another endpoint. Keep the replay and content-filter regression tests when changing generation or conversation merging.

`AgentTool` combines a name, description, `AgentToolParameters`, and an asynchronous executor. Arguments and results use `AnyAgentToolValue`, which preserves typed JSON values. `AgentToolParameters.jsonSchema()` is the shared serialization path; provider-specific normalization is explicit. `AgentToolJSONSchema` offers a recursive typed view while retaining unknown keywords and the source schema. It does not resolve references or validate tool inputs at runtime.

`TypedValue` preserves JSON scalars as well as arrays and objects when converting through Codable. Foundation number conversion shares `AnyAgentToolValue`'s boolean and integer handling, so numeric zero/one remain numbers. Numbers outside `Int`'s range remain doubles; `Int.fromJSON` accepts only exactly representable integers and rejects fractional values, booleans, and non-finite or overflowing numbers.

`TachikomaAgent` binds dynamically discovered tools to the provider that supplied their schemas. Registry refreshes invalidate stale bindings, and duplicate names fail instead of dispatching by discovery order. `TachikomaMCP` uses shared schema and content bridges for both static adapters and dynamic discovery.

## Configuration and concurrency

Use an explicit `TachikomaConfiguration` when callers need different keys, endpoints, or provider factories. `TachikomaConfiguration.resolve` chooses the supplied instance, then the application default, then the automatically loaded singleton. Environment values override stored profile values during automatic loading. `TKAuthManager` owns credential resolution and OAuth refresh coordination.

Actors own asynchronous mutable state such as sessions, tool registries, caches, and transport continuations. Synchronous configuration and conversation access uses locks. `@unchecked Sendable` is a requirement to preserve the associated locking discipline, not proof that every access is safe. Keep locks out of suspension points and preserve generation checks around reconnects and late responses.

Conversation continuations serialize through an actor gate. Generated history is merged against snapshot identities so a concurrent edit cannot silently overwrite the user's conversation.

## Audio and MCP

`TachikomaAudio/Transcription` contains speech/transcription adapters; `Recording` and `Realtime/Audio` contain platform-specific capture and processing. Realtime separates WebSocket transport, session events, conversation state, and tool execution. Hosts own microphone permissions and capture. See [Realtime voice](openai-harmony.md).

`TachikomaMCP/Client` owns stdio, HTTP, and SSE transports. Stdio serializes complete JSON-line frames and tracks pending requests by connection generation. Disconnect and child exit fail pending work and clear cached tools. SSE owns its reader task and prevents superseded readers from mutating replacement state. See the [MCP guide](../Sources/TachikomaMCP/README.md).

## Validation

See [the testing guide](testing.md) for hermetic tests, live provider gates, and the supported tooling. Provider changes need request/response fixtures; lifecycle changes need cancellation, reconnect, and failure-path coverage. Keep credentials out of fixtures and default test runs.
