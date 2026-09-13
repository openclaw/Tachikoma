# Changelog

All notable changes to the Tachikoma project will be documented in this file.

## Unreleased

### Fixed
- JSON encoding now preserves Foundation booleans, numeric precision, and nested nulls through one shared encoder instead of changing booleans to numbers or nulls to strings.

### Changed
- CI now checks Swift 6.3.3 alongside the existing Swift 6.2.4 checks, pins Actions and linter binaries, isolates compiler caches, and typechecks guide examples; core coverage also supports the newer Swift Build object layout.
- Replaced outdated Azure, LM Studio, GPT-OSS, and tool guides with current SDK examples and a maintained Realtime sample.

## 0.4.2 - 2026-09-11

**Highlights:** Fix legacy log-handler forwarding and improve compiler compatibility with Swift Log 1.15.1.

### Changed
- Updated Swift Log to 1.15.1, including upstream fixes for legacy log-handler forwarding and Swift 6.5+ WASI builds.

## [0.4.1] - 2026-09-05

**Highlights:** Prevent timeout crashes and preserve Google proxy routes while rejecting invalid base URLs.

### Fixed
- Generation and MCP health checks now reject negative, non-finite, and overflowing timeouts before starting work instead of crashing; zero retains its immediate-deadline behavior. Thanks @SebTardif (#84).
- Google generation and streaming now reject empty and malformed base URLs; shared endpoint joining preserves percent-encoded proxy paths. Thanks @SebTardif (#85).
- SDK version metadata now reports the current release instead of the stale `4.0.0` value.

### Changed
- Updated Swift Crypto to 4.5.2, ASN.1 to 1.7.2, and NIO to 2.102.0; refreshed CI to Swift 6.2.4 and SwiftFormat 0.63.0 while retaining Swift 6.2 support.

## [0.4.0] - 2026-08-31

### Added
- MCP-to-Agent adapters now expose a typed recursive JSON Schema view with defaults, constraints, unions, composition, conditionals, and lossless extension-keyword retention.
- MCP tools can now advertise optional structured-result schemas while existing conformers remain source-compatible.
- Added first-class Claude Opus 5 support and moved generation-agnostic Claude aliases and defaults to the new flagship.

### Fixed
- Realtime sessions now reject empty and unparsable base URLs before connecting instead of crashing or leaving invalid state. Thanks @SebTardif (#71).
- OpenAI Responses, embeddings, and LM Studio now reject invalid provider base URLs instead of crashing. Thanks @SebTardif (#67).
- Realtime tool execution now preserves completion order, distinguishes cancellation from timeout, rejects invalid deadlines before dispatch, and bounds cancellation cleanup. Thanks @SebTardif (#68, #69, #70).
- CLI and generation diagnostics no longer expose credential fragments, and OAuth configuration now requires HTTPS authorization and token endpoints (#72, #73).
- Profile loading now preserves automatic text decoding, including BOM-encoded files, without deprecated Foundation APIs (#82).
- Cancelling a stdio MCP request now clears its continuation and timeout without closing the child, and cancelled initialization no longer retries legacy protocol variants.
- Stdio MCP child exit now atomically closes the connection, clears cached tools, fails pending requests without waiting for their timeout, rejects later sends, and preserves generation-safe reconnects.
- The root package no longer declares unused Commander products for its hand-parsed CLIs, avoiding local/remote package-identity conflicts in consumers; hermetic macOS/Linux tests now block merges on failure, and live-provider CI uses its documented compile/runtime gates.
- Concurrent stdio MCP requests now serialize complete JSON-line frames so payloads and delimiters cannot interleave across tool calls.
- Tool schemas now preserve nested object fields, required arrays, enums, array items, and scalar constraints consistently across static/dynamic MCP discovery and every provider serializer, including LM Studio.
- Provider schema normalization now reaches draft-07 tuple items, additional-item schemas, and schema-valued legacy dependencies.
- MCP tool discovery now uses one schema conversion path so static and dynamic tools preserve matching descriptions, enums, array item types, and required fields.
- Composite dynamic tool providers now recover unchanged bindings after transient discovery failures while keeping real ownership changes fail-closed.
- Dynamic tool aggregation now binds execution to the provider that supplied each schema, invalidates stale plans, avoids repeated discovery on registry execution, and rejects duplicate names instead of dispatching nondeterministically.
- MCP tool arguments now use one typed conversion path across adapters, providers, managers, and transport while preserving Foundation booleans and integers exactly.
- MCP tool failures now retain their error status, content, structured values, and safe metadata through agent generation instead of being shaped as successful tool results.
- MCP tool responses now preserve metadata consistently across adapter and dynamic-provider execution paths.
- SSE transports now own and cancel their background reader, replace it safely on reconnect, and fail pending requests when the stream terminates instead of leaking work until timeout.
- Audio abort-signal timeouts now handle zero, negative, non-finite, and unrepresentably large durations without trapping.
- MCP tool arguments now reject non-finite numbers and lossy or overflowing integer conversions instead of truncating or trapping.
- OpenAI Responses tools now preserve omission-based optional parameters and emit one canonical flattened function schema instead of duplicating it in a nested `function` object.
- OpenAI Responses tool errors now keep their diagnostic output without sending an unsupported `failed` status that caused request-level errors.

### Changed
- Refreshed Swift package pins to EventSource 1.5.1, ServiceLifecycle 2.12.0, and System 1.8.1.

## [0.3.0] - 2026-08-02

### Added
- Added ChatGPT OAuth (Codex Responses endpoint) support for OpenAI vision requests, with stored-login refresh persistence and process-local environment credential refresh. Thanks @scotthuang (#40).

### Changed
- Updated Swift package requirements and refreshed transitive pins, including swift-crypto 4.5.1, swift-nio 2.101.3, and swift-system 1.7.5.

### Fixed
- Replayed encrypted OpenAI reasoning items across Codex OAuth tool-call turns so stateless follow-up requests retain the required reasoning context.
- Corrected `tachikoma config init` guidance so it no longer claims to write a file or suggests commands from another application.

## [0.2.2] - 2026-07-15

### Fixed
- SwiftPM dependency checkouts no longer mistake another resolved Commander checkout for a sibling development package, avoiding conflicting package identities and a future resolution error.

## [0.2.1] - 2026-07-15

### Added
- Added first-class Claude Sonnet 5 and OpenAI GPT-5.6 Sol/Terra/Luna support with parsing aliases, capabilities, provider routing, and usage estimates.
- Added `MiniMax-M3` with 1M context, image input, provider/model parsing, and Anthropic-compatible routing. Thanks @Tugser.
- Added first-class OpenAI `chat-latest` support with parsing aliases, Responses API routing, model capabilities, and usage estimates.
- Added first-class MiniMax support with the `MiniMax-M2.7` catalog models, `MINIMAX_API_KEY` / `MINIMAX_BASE_URL` configuration, bearer-token Anthropic-compatible transport, model parsing shortcuts, usage estimates, and provider tests.
- Added first-class Kimi support for the official K2.6 and K2.7 Code model IDs, Moonshot's OpenAI-compatible endpoint, multimodal/tool capabilities, and provider-bound `reasoning_content` replay. Thanks @Tugser.
- Added explicit LM Studio model shortcuts such as `lmstudio` and `lmstudio/openai/gpt-oss-120b` so local provider selections no longer fall through to Ollama custom IDs.

### Changed
- Refreshed the first-class model catalog to current provider IDs: OpenAI GPT-5.5/5.4, Claude Fable 5/Opus 4.8/Opus 4.7/Sonnet 4.6/Haiku 4.5, Gemini 3.1, Mistral latest aliases, Groq current production IDs, and xAI Grok 4.3/4.20.
- Added explicit `claude-fable-5` support with 1M context, 128K max output, signed-thinking replay, refusal handling, and non-streaming generation; `LanguageModel.default` remains `claude-opus-4-8`, while `LanguageModel.defaultStreaming` now uses streaming-safe `gpt-5.5`.
- Removed stale direct model support for retired or non-canonical IDs including GPT-5.1/5.2/pseudo-thinking models, deprecated Claude Sonnet/Opus 4 snapshots, Grok 2/3/4-fast rows, old Groq Llama/Mixtral/Gemma aliases, stale Mistral aliases, and invalid LM Studio `current`.

### Fixed
- Ollama now applies configured bearer auth, requests and exposes thinking, safely preserves same-endpoint history without persisting authentication material, maps terminal reasons without executing truncated tool calls, and streams strict NDJSON incrementally across supported platforms.
- Ollama tool conversations now replay assistant calls and named results, preserve recursive arguments and array schemas, report tool-call finishes, and surface HTTP-200 stream errors instead of silently succeeding.
- Sonnet 5 usage estimates now switch from introductory to standard pricing after August 31, 2026.
- GPT-5.6 models now retain their 372K context and 128K output limits through OpenAI-compatible, OpenRouter, and Together endpoints.
- GPT-5.6 OpenRouter routes with terminal variants such as `:online`, `:nitro`, `:floor`, and `:exacto` now retain those limits without rewriting the routed model ID.
- OpenAI `gpt-5-chat-latest` now preserves its distinct model identity, appears in model listings, and applies GPT-5 parameter filtering instead of being rewritten to `chat-latest`.
- SwiftPM consumers now resolve Commander from the package URL instead of accidentally inheriting a sibling local checkout.
- Ollama model parsing now preserves explicit custom vision model IDs such as `qwen2.5vl:3b` instead of falling back to `llama3.3` (#16).
- Auth resolution now snapshots environment-ignore state consistently, preventing parallel tests and concurrent callers from falling back to stored OpenRouter credentials when an environment override is present.
- SwiftPM consumers can now resolve Commander remotely instead of requiring a local `../Commander` checkout. Thanks @malpern.
- Custom OpenAI-compatible and Anthropic-compatible providers now honor per-provider `options.apiKey` values from profile config. Thanks @381181295.
- Google/Gemini request encoding now sends tool results as documented user `functionResponse` turns and merges consecutive same-role contents before calling the API. Thanks @hsrvc.
- Google/Gemini tool schemas now drop orphan `required` entries before request encoding so Gemini accepts simplified MCP tool definitions. Thanks @bcharleson.
- OpenAI Responses API providers now resolve shared OAuth/API-key credentials instead of requiring `OPENAI_API_KEY` directly.
- Credential loading now only maps exact API-key credential names to provider API keys, so OAuth access/refresh tokens no longer overwrite configured OpenAI or Anthropic keys.
- Custom OpenAI-compatible and Anthropic-compatible providers now forward configured proxy headers to request calls.
- Anthropic base URL environment overrides now survive Swift release builds, so `ANTHROPIC_BASE_URL` can route requests through local proxies. Thanks @shraderdm.

## [0.2.0] - 2026-04-28

### Added
- First-class Azure OpenAI provider: deployment-based model case `.azureOpenAI`, Azure-specific URL/header/query wiring (api-version, api-key or bearer token), env overrides (`AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_BEARER_TOKEN`, `AZURE_OPENAI_ENDPOINT`/`RESOURCE`, `AZURE_OPENAI_API_VERSION`), and README guidance.
- Azure provider unit tests using URLProtocol stubs to verify path, query, and auth header construction.

### Changed
- Added OpenAI's GPT-5.1 family (flagship/mini/nano) throughout the model enums, selectors, provider factories, capability registry, pricing tables, docs, and test suites. GPT aliases (`gpt`, `gpt-5`) now normalize to supported GPT-5 models so downstream apps inherit the new default seamlessly.
- Expanded xAI Grok support to the full November 2025 catalog (`grok-4-fast-*`, `grok-code-fast-1`, `grok-2-*`, `grok-vision-beta`, etc.), updated the CLI shortcuts so `grok` now maps to `grok-4-fast-reasoning`, and refreshed selectors, provider parsers, capability tables, and docs snippets to match the official API lineup.
- Google/Gemini support now targets the Gemini 2.5 family exclusively (`gemini-2.5-pro`, `gemini-2.5-flash`, `gemini-2.5-flash-lite`), with updated model selectors, parsers, docs, and pricing tables; older 1.5/2.0 IDs are no longer recognized.
- Removed deprecated OpenAI reasoning models (`o1`, `o1-mini`, `o3`, `o3-mini`, `o4-mini`) in favour of the GPT‑5 family, updating enums, provider factories, capability tables, prompts, and documentation metadata accordingly.
- Google/Gemini integration now uses the documented `x-goog-api-key` header with `alt=sse` streaming, adds fallbacks for `GOOGLE_API_KEY` / `GOOGLE_APPLICATION_CREDENTIALS`, and hardens the SSE decoder so live tests succeed consistently.
- Pruned Anthropic model support to the Claude 4.x line (Opus 4, Sonnet 4 / 4.5, Haiku 4.5) to match current API availability and reduce maintenance burden.
- `TachikomaConfiguration` now loads credentials first and lets environment variables override them so operators can supersede stored settings without editing credentials files.
- `TachikomaConfiguration` can optionally override the provider factory so test harnesses can inject mock providers without affecting production defaults, improving hermetic test runs.
- Implemented OpenRouter, Together, Replicate, and Anthropic-compatible providers on top of the shared helpers so aggregator models no longer throw “not yet implemented” errors and honour custom base URLs/headers.
- `Provider.environmentValue` falls back to classic `getenv` lookups when the modern configuration reader returns no value, ensuring environment overrides succeed on macOS 14 deployments.
- Provider environment reads now use direct process environment lookups, so test overrides and runtime unsets behave deterministically across SwiftPM/Xcode runs.

### Fixed
- MCP bridge conversions now handle embedded resources and resource links from `swift-sdk` 0.11, and test helpers no longer swap mock keys for live environment credentials during provider/audio suites.
- `retryWithCancellation` now registers token handlers per-attempt and cancels in-flight work, resolving hangs when external cancellation should short-circuit retries.
- Audio provider tests and helpers consistently force mock mode when exercising stub audio payloads, preventing accidental live API calls that fail to decode fixtures.
- `TestHelpers` expose discardable configuration helpers and stricter mock-key detection, reducing compiler warnings and flaky skips.
- OpenAI transcription timestamp tests no longer hit the live API and succeed reliably under both mock and real key configurations.
- Google provider API-key resolution no longer treats `GOOGLE_APPLICATION_CREDENTIALS` file paths as credential strings.
- Anthropic OAuth login token exchange now uses the correct request format (JSON body + `state`). Thanks @jonathanglasmeyer.

### Testing
- Added dedicated Grok catalog tests (selector + capability assertions) plus provider factory/e2e coverage so every supported xAI model is exercised in mock suites without hitting the live API.
- Integration suites now respect real API keys loaded from the environment, covering Anthropic Sonnet 4 tool-calling, OpenAI GPT‑5 responses, Grok/Grok vision flows, and Google/Mistral smoke tests.
- Full `INTEGRATION_TESTS=1 swift test` runs complete without recorded issues, including agent ergonomics and audio suites.
- Added provider-level network E2E coverage using local `URLProtocol` stubs plus new OpenAI Responses API tests (request encoding + streaming) so critical serialization paths are exercised without live traffic.
- `ProviderEndToEndTests` now exercise every provider flavor (OpenRouter/Together/Replicate, OpenAI/Anthropic compatible, etc.), pushing overall line coverage above 40 % while keeping the suite deterministic via URLProtocol stubs.

## [0.1.0] - 2026-01-18

### Added
- Core Swift 6 AI SDK with strict concurrency, streaming responses, and typed tool calling.
- Unified message/content model (text, images, audio) with structured tool results.
- Provider support for OpenAI (Chat + Responses), Anthropic, xAI (Grok), Google Gemini, Ollama, and OpenAI-compatible endpoints (OpenRouter/Together/Replicate).
- Config system with credential store + env overrides, model registry, and capability lookup helpers.
- Test helpers and mock infrastructure for deterministic provider/unit coverage.

## [1.0.0] - 2025-01-XX

### Added

#### Core Framework
- Initial release of Tachikoma AI integration library
- Unified `ModelInterface` protocol for all AI providers
- Comprehensive message type system with multimodal support
- Real-time streaming response handling with `AsyncThrowingStream`
- Type-safe tool calling system with generic context support
- Actor-based provider registry with intelligent caching
- Swift 6 strict concurrency compliance throughout

#### Provider Support
- **OpenAI Provider**: Complete integration with dual API support
  - Chat Completions API for standard custom models
  - Responses API for GPT-5 models
  - Automatic API selection based on model capabilities
  - Parameter filtering for reasoning models
  - Full streaming support for both APIs
  - Reasoning summary handling for thinking models

- **Anthropic Provider**: Native Claude API integration
  - Support for Claude 4 (Opus, Sonnet) with thinking modes
  - Claude 4.x series compatibility
  - Content block handling for multimodal inputs
  - System prompt separation
  - Server-Sent Events streaming
  - Extended reasoning capabilities

- **Grok Provider**: xAI integration with OpenAI compatibility
  - Grok 4, Grok 3, Grok 2 series support
  - Vision model capabilities
  - Parameter filtering for Grok 3/4 models
  - Standard streaming implementation
  - OpenAI-compatible Chat Completions API

- **Ollama Provider**: Local model inference support
  - Support for Llama 3.3 (recommended), Mistral, CodeLlama
  - Vision models (llava, bakllava) without tool calling
  - Configurable endpoints for self-hosted deployments
  - Extended timeouts for local model loading
  - Tool calling detection for compatible models

#### Message System
- **Unified Message Types**: Support for system, user, assistant, tool, and reasoning messages
- **Content Types**: Text, images (URL/base64), multimodal, files, audio with transcripts
- **Assistant Content**: Text output, refusals, tool calls with proper typing
- **Image Support**: High/low detail levels, multiple formats, base64 encoding
- **Audio Support**: Transcript extraction, duration metadata

#### Streaming System
- **Event-Based Architecture**: Comprehensive streaming event types
- **Real-Time Processing**: Incremental text deltas, tool call construction
- **Memory Efficiency**: Constant memory usage regardless of response size
- **Error Handling**: Structured error events with recovery information
- **Provider Abstraction**: Unified events across different provider formats

#### Tool Calling
- **Generic Tool System**: Type-safe tool execution with context support
- **Parameter Validation**: JSON Schema-based parameter validation
- **Async Execution**: Non-blocking tool execution with proper error handling
- **Tool Definitions**: Provider-agnostic tool definition format
- **Context Management**: Type-safe context passing to tool functions

#### Error Handling
- **Comprehensive Error Types**: Structured error hierarchy with recovery guidance
- **Provider-Specific Errors**: Tailored error handling for each provider
- **Retry Logic**: Built-in retry detection with exponential backoff support
- **Error Categories**: Client, authentication, network, and provider errors
- **Localized Descriptions**: User-friendly error messages with recovery suggestions

#### Configuration System
- **Environment Variables**: Support for standard API key environment variables
- **Provider Configuration**: Flexible configuration for custom endpoints
- **Model Registration**: Runtime model factory registration
- **Lenient Matching**: Intelligent model name resolution
- **Cache Management**: Configurable caching policies

### Technical Features

#### Swift 6 Compliance
- **Strict Concurrency**: Full Swift 6 strict concurrency mode compliance
- **Sendable Conformance**: All public types conform to Sendable protocol
- **Actor Safety**: Thread-safe operations with proper isolation
- **Memory Safety**: No data races or concurrency issues
- **Performance**: Optimized for concurrent execution

#### Performance Optimizations
- **Intelligent Caching**: Model instance caching with smart invalidation
- **Connection Pooling**: Efficient network connection management
- **Memory Management**: Minimal allocations and efficient garbage collection
- **Streaming Efficiency**: Incremental processing without accumulation
- **JSON Optimization**: Fast encoding/decoding without reflection

#### Type Safety
- **Compile-Time Verification**: Strong typing throughout the API
- **Generic Constraints**: Type-safe tool contexts and parameters
- **Enum-Based Design**: Exhaustive pattern matching for robustness
- **Protocol-Oriented**: Clean abstractions with concrete implementations

### Documentation
- Comprehensive README with quick start guide
- Detailed architecture documentation
- API reference documentation
- Code examples for common usage patterns
- Migration guide from PeekabooCore
- Performance optimization guidelines

### Testing
- Unit tests for all core components
- Integration tests for provider functionality
- Mock providers for testing scenarios
- Performance benchmarks
- Concurrency safety tests

### Platform Support
- macOS 14.0+
- iOS 17.0+
- watchOS 10.0+
- tvOS 17.0+
- Swift 6.0+
- Xcode 16.0+

## Version History

- **v1.0.0**: Initial release extracted from PeekabooCore with Swift 6 compliance
- **v0.x.x**: Development versions (internal)

## Migration Notes

### From PeekabooCore
When migrating from PeekabooCore's AI system:

1. **Error Types**: Replace `PeekabooError` with `TachikomaError`
2. **Import Statements**: Update to `import Tachikoma`
3. **Model Creation**: Use `Tachikoma.shared.getModel()` instead of direct instantiation
4. **Streaming Events**: Update event handling for new event type hierarchy
5. **Message Types**: Adopt new unified message type system
6. **Tool Calling**: Update to generic tool system with context support

### Breaking Changes
This is the initial release, so no breaking changes from previous versions.

## Contributors

- **Extraction Lead**: AI Assistant
- **Original Code**: Peekaboo project contributors
- **Architecture Design**: Based on proven patterns from PeekabooCore
- **Swift 6 Migration**: Complete rewrite for strict concurrency compliance

## License

This project is licensed under the MIT License. See LICENSE file for details.
