# GPT-OSS with local providers

Tachikoma includes GPT-OSS model selections for Ollama and LM Studio. Install and load the model through the local server before sending SDK requests. Available memory, quantization, and context length are server/deployment choices; Tachikoma does not download models or configure GPU memory.

## Ollama

With Ollama running, load a model using its CLI:

```sh
ollama pull gpt-oss:20b
```

Select the corresponding catalog case:

```swift
import Tachikoma

let result = try await generateText(
    model: .ollama(.gptOSS20B),
    messages: [.user("Explain actors in Swift.")],
    settings: GenerationSettings(maxTokens: 512, reasoningEffort: .medium)
)
print(result.text)
```

`.ollama(.gptOSS120B)` uses `gpt-oss:120b`. The convenience value `.gptOSS120B` selects that same Ollama model. Custom IDs remain available through `.ollama(.custom("your-model:tag"))`.

The Ollama adapter uses `http://localhost:11434` by default. `OLLAMA_BASE_URL` or an explicit `.ollama` configuration base URL selects another server; `OLLAMA_API_KEY` supplies optional bearer authentication. Both normal and streaming generation use `/api/chat`.

## Thinking and tools

For GPT-OSS, `GenerationSettings.reasoningEffort` maps to Ollama's supported low, medium, or high thinking level. The provider preserves returned thinking separately from answer text. Provider-bound reasoning history can be reused only with the matching endpoint and authentication context.

```swift
let response = try await streamText(
    model: .ollama(.gptOSS20B),
    messages: [.user("Compare value and reference semantics.")],
    settings: GenerationSettings(reasoningEffort: .low)
)
for try await delta in response {
    switch delta.type {
    case .textDelta:
        print(delta.content ?? "", terminator: "")
    case .reasoning:
        break
    default:
        break
    }
}
```

Use regular `[AgentTool]` values for tool calls. The shared generation loop executes tools and sends their structured results back for subsequent steps. Ollama's terminal status determines whether returned calls are complete enough to execute.

## LM Studio

LM Studio uses server-specific model IDs, such as `openai/gpt-oss-20b`. Query `LMStudioProvider.listModels()` and select an exact returned ID:

```swift
let result = try await generateText(
    model: .lmstudio(.custom("openai/gpt-oss-20b")),
    messages: [.user("Summarize Swift concurrency.")]
)
```

See [LM Studio](lmstudio.md) for discovery, configuration, and streaming. The curated `.lmstudio(.gptOSS120B)` case and `.gptOSS120B_LMStudio` shortcut are available when their ID matches the loaded model.

## Troubleshooting

Check the server's own generation path first when a model cannot load or runs out of memory. For request failures, check the configured base URL and exact model ID. For tool failures, check whether the loaded model/server supports tools and inspect the structured result. Streaming requires valid NDJSON from Ollama; malformed records, server errors, or a missing terminal record are reported as errors.

See [models](models.md) for the catalog and [testing](testing.md) for hermetic provider fixtures.
