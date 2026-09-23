# Testing

## Hermetic suite

```sh
TACHIKOMA_TEST_MODE=mock TACHIKOMA_DISABLE_API_TESTS=true swift test --parallel
```

This runs the unit and mocked provider suites without API keys or external services. Provider fixtures use URLProtocol and injected sessions; MCP lifecycle fixtures start local child processes. `TestHelpers` creates isolated provider configurations and mock factory overrides.

CI runs the complete suite on macOS with Swift 6.2.4. Linux covers both Swift 6.2.4 and Swift 6.4.0. Its Linux job retains two platform exclusions, `OpenAIAudioProviderTests` and `ProviderEndToEndTests`, because FoundationNetworking's URLProtocol implementation cannot host those fixtures. No credentialed provider tests belong in the default CI run.

## Live provider smoke tests

Configure the credentials for the providers you intend to test, then run:

```sh
INTEGRATION_TESTS=1 swift test --no-parallel -Xswiftc -DLIVE_PROVIDER_TESTS --filter ProviderIntegrationTests
```

The compile-time flag includes the integration suite; `INTEGRATION_TESTS=1` enables it. The suite requires at least one eligible provider credential. The manual **Live Providers** workflow runs the same command on the default branch and rejects an empty credential set before building.

The Codex OAuth vision smoke also requires `TACHIKOMA_INTEGRATION_PROFILE_DIR` naming a profile with usable OAuth credentials and no higher-priority OpenAI API key. Credentials should be supplied through the environment or configured profile, never committed to fixtures.

## Environment

| Variable | Purpose |
| --- | --- |
| `TACHIKOMA_TEST_MODE=mock` | Selects mock provider/audio behavior in test helpers. |
| `TACHIKOMA_DISABLE_API_TESTS=true` | Disables real provider tests even if credentials are available. |
| `INTEGRATION_TESTS=1` | Enables the compiled live-provider suite. |
| `TACHIKOMA_INTEGRATION_PROFILE_DIR` | Profile for the opt-in OAuth vision smoke. |
| `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY` / `GOOGLE_API_KEY`, `MISTRAL_API_KEY`, `GROQ_API_KEY`, `X_AI_API_KEY` / `XAI_API_KEY` | Live provider credentials. |
| `OPENROUTER_REFERER`, `OPENROUTER_TITLE` | Optional OpenRouter request headers. |
| `REPLICATE_PREFERRED_OUTPUT=turbo` | Enables the Replicate `Prefer: wait=false` header. |

## Focused tests and coverage

```sh
TACHIKOMA_TEST_MODE=mock TACHIKOMA_DISABLE_API_TESTS=true swift test --filter StopConditions
TACHIKOMA_TEST_MODE=mock TACHIKOMA_DISABLE_API_TESTS=true swift test --parallel --enable-code-coverage
```

On toolchains that produce the traditional combined macOS test bundle, inspect coverage with:

```sh
xcrun llvm-cov report \
  .build/debug/TachikomaPackageTests.xctest/Contents/MacOS/TachikomaPackageTests \
  -instr-profile=.build/debug/codecov/default.profdata
```

Use the binary/profile paths printed by your toolchain if its SwiftPM output layout differs. `scripts/core-coverage.sh` selects the debug build path and supports both per-file objects in `Tachikoma.build` and the newer `Tachikoma.o` module object.

On macOS, `python3 scripts/check-doc-examples.py` compiles the Swift snippets in the Azure, GPT-OSS, LM Studio, and tool guides plus the Realtime source example against the built module. The check uses the package's declared macOS minimum and fails on compiler errors.

## Regression fixtures

| Area | Location |
| --- | --- |
| Provider requests, responses, and schemas | `Tests/TachikomaTests/Providers/ProviderEndToEndTests.swift` |
| Responses API | `Tests/TachikomaTests/Providers/OpenAIResponsesProviderTests.swift` |
| Base-URL validation and encoded paths | `Tests/TachikomaTests/Providers/InvalidProviderBaseURLTests.swift` |
| Generation, history, stop conditions | `Tests/TachikomaTests/Core/` |
| Schema/value bridges and transport lifecycle | `Tests/TachikomaMCPTests/` |
| Live providers | `Tests/TachikomaTests/Providers/Integration/ProviderIntegrationTests.swift` |

Generation timeouts use seconds; MCP health-check timeouts use milliseconds. Zero is an immediate deadline that races the operation. Negative, non-finite, and overflowing values are rejected before starting the timed operation. Timeout stop conditions are checked as text deltas arrive; they are not an idle-network timer.

Request-scoped streams propagate consumer cancellation to producer tasks and HTTP requests. UI stream adapters also close on upstream EOF without requiring a terminal delta. Retry configurations reject invalid attempts and durations before starting work.

`RetryHandler` validates positive attempt counts and nonnegative policy values before invoking an operation. Base delays, backoff multipliers, and jitter must be finite; `maxDelay` may be infinity to mean no cap. Each effective jittered delay and server retry-after value must be finite and representable before callbacks or sleeping. Cancellation errors bypass retry predicates and callbacks, and already-cancelled callers do not start requests. Stream retries apply only to stream creation; consuming a stream never retries partial output.

Embedding batch tests use gated synthetic providers to verify concurrency bounds, input-order results, and cancellation without scheduling queued requests. OpenAI embedding request/response fixtures run on macOS because they use URLProtocol; they check token input, response indices, and malformed vector rejection without contacting a provider.

MCP SSE cancellation fixtures wait for an HTTP request to start, then verify that cancelling the caller stops the request and throws `CancellationError`. Transport errors retain their original code when the caller has not been cancelled.
