# OpenAI Realtime voice

Tachikoma’s `TachikomaAudio` product includes a typed client for OpenAI’s Realtime WebSocket API. It supports text and caller-supplied PCM audio input, streamed text and audio events, response interruption, and `AgentTool` function calls.

The current default model is `gpt-realtime`, represented as `.custom("gpt-realtime")`. Realtime is independent of the regular `generateText` API and does not use a GPT-4-era model case.

## Add the module

Add both products to the target that owns the conversation:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "Tachikoma", package: "Tachikoma"),
        .product(name: "TachikomaAudio", package: "Tachikoma"),
    ]
)
```

```swift
import Tachikoma
import TachikomaAudio
```

Realtime requires an OpenAI API key. `TachikomaConfiguration` resolves `OPENAI_API_KEY` and Tachikoma’s stored credential profile in the same way as the other OpenAI providers.

## Start a conversation

```swift
let configuration = TachikomaConfiguration()
let conversation = try await startRealtimeConversation(
    model: .custom("gpt-realtime"),
    voice: .alloy,
    instructions: "Answer concisely.",
    configuration: configuration
)

let transcriptUpdates = await conversation.transcriptUpdates
let transcriptTask = Task {
    for await delta in transcriptUpdates {
        print(delta, terminator: "")
    }
}

try await conversation.sendText("What is actor isolation?")

// Later, when the owner is done with the session:
await conversation.end()
transcriptTask.cancel()
```

`RealtimeConversation` is main-actor isolated and publishes `state`, `connectionStatus`, `messages`, `isRecording`, `isPlaying`, and `audioLevel` when Combine is available. It also exposes asynchronous transcript, state, and audio-level streams.

## Send audio

Tachikoma does not start system microphone capture for you. `startListening()` opens the conversation’s input gate; the host app remains responsible for permissions, capture, and conversion before calling `sendAudio(_:)`.

```swift
try await conversation.startListening()

// Feed 24 kHz mono PCM16 chunks produced by the host audio pipeline.
try await conversation.sendAudio(pcmChunk)

await conversation.stopListening()
```

`stopListening()` commits buffered audio. Use `interrupt()` to cancel the current model response.

## Use tools

Pass regular `[AgentTool]` values to `startRealtimeConversation`. Tachikoma converts their schemas to Realtime tools, executes completed calls through its registry, sends the result back to the session, and requests the next model response.

```swift
let conversation = try await startRealtimeConversation(
    tools: [weatherTool],
    configuration: configuration
)
```

The built-in tool registry can also be enabled after construction:

```swift
await conversation.registerBuiltInTools()
```

## Lifecycle and errors

- Call `end()` to stop event processing, disconnect the WebSocket, and finish the public streams.
- A non-Realtime model passed to `startRealtimeConversation` throws `unsupportedOperation`.
- Missing OpenAI credentials throw `authenticationFailed` during construction.
- `RealtimeConversation` requires Combine. Platforms without Combine receive `TachikomaError.unavailable`.
- The Swift package currently requires Swift 6.2 and declares macOS 14, iOS 17, tvOS 17, watchOS 10, and visionOS 1 as its deployment floors.

The implementation lives under `Sources/TachikomaAudio/Realtime`; a host-integration example lives in [Examples/RealtimeExample.swift](../Examples/RealtimeExample.swift).
