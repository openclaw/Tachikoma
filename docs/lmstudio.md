# LM Studio

Tachikoma connects to LM Studio's OpenAI-compatible local server. Install LM Studio, load a model that fits your machine, and start its server. Model downloads, loading, quantization, GPU placement, and context allocation are managed in LM Studio.

## Select a model

Use the exact model ID returned by the server's `/v1/models` endpoint:

```swift
import Tachikoma

let provider = LMStudioProvider(baseURL: "http://localhost:1234/v1")
for model in try await provider.listModels() {
    print(model.id)
}
```

The returned entries contain `id`, `object`, `created`, and `owned_by`. The SDK's list API does not report model file sizes, GPU layers, or loading progress.

For generation through the built-in provider factory:

```swift
let result = try await generateText(
    model: .lmstudio(.custom("openai/gpt-oss-20b")),
    messages: [.user("Explain actors in Swift.")],
    settings: GenerationSettings(maxTokens: 512, temperature: 0.7)
)
print(result.text)
```

The default base URL is `http://localhost:1234/v1`. Configure another server using `TachikomaConfiguration.setBaseURL(_:for:)` with `.lmstudio`, or pass an explicit provider:

```swift
let provider = LMStudioProvider(
    baseURL: "http://localhost:1234/v1",
    modelId: "openai/gpt-oss-20b"
)
let result = try await generateText(
    model: .custom(provider: provider),
    messages: [.user("Hello")]
)
```

`LMStudioProvider` also accepts an optional API key and `URLSessionConfiguration` for hosts that need them. `autoDetect()` probes common local addresses and chooses the first returned model when available.

## Streaming and tools

Streaming uses the same high-level API as hosted providers:

```swift
let response = try await streamText(
    model: .lmstudio(.custom("openai/gpt-oss-20b")),
    messages: [.user("Write a short explanation of async/await.")]
)
for try await delta in response.stream {
    if let content = delta.content {
        print(content, terminator: "")
    }
}
```

The adapter can send tool definitions, but its current history conversion drops structured tool calls and results. Full multi-step tool conversations remain a known limitation of this adapter. See the [model catalog](models.md) for provider selection.

## Operational limits

The adapter uses `/models` for discovery and `/chat/completions` for generation. Invalid configured base URLs throw before sending a request. Generation request/resource timeouts default to five and ten minutes respectively to accommodate local inference.

The adapter's advertised capabilities are conservative SDK metadata, not a hardware probe. Choose token limits and context settings that match the loaded model. If connection fails, confirm the server address and port; if the server rejects a model, compare its returned IDs with the exact ID supplied to Tachikoma.

For GPT-OSS identifiers and thinking options, see [GPT-OSS with local providers](gpt-oss.md).
