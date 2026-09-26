# Models

Tachikoma ships with a built-in model catalog (`CaseIterable` enums) plus support for arbitrary model ids via `.custom(...)` and compatible/custom endpoints.

## Default

- `LanguageModel.default`: `claude-opus-5`
- `LanguageModel.defaultStreaming`: `gpt-5.5`

## OpenAI (`LanguageModel.OpenAI`)

- `chat-latest`, `gpt-5-chat-latest`
- `gpt-6-astra`, `gpt-6-sol`, `gpt-6-luna` (`.gpt6Astra`, `.gpt6Sol`, `.gpt6Luna`; bare `gpt-6` selects Astra)
- `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna` (preview; bare `gpt-5.6` selects Sol)
- `gpt-5.5`
- `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.4-nano`
- `gpt-5`, `gpt-5-pro`, `gpt-5-mini`, `gpt-5-nano`

Notes:
- GPT-6 uses the Responses API for generation, streaming, vision, and tools, with a 1,050,000-token context window and 128,000-token maximum output. Existing model defaults are unchanged.
- Set `OpenAIOptions.reasoningEffort` to `low`, `medium`, `high`, `xhigh`, or `max`; Sol and Luna also accept `reasoningEffort: .some(.none)` (distinct from Swift's optional `nil`). GPT-6 rejects `minimal`, and Astra rejects `none`. Temperature and top-p are omitted while reasoning is enabled.
- GPT-6 cost estimates use Standard API token rates; cache writes, cached-input discounts, and service-tier premiums are not included. See the [OpenAI model guide](https://developers.openai.com/api/docs/guides/latest-model) and [pricing](https://developers.openai.com/api/docs/pricing).
- Older `gpt-5.1`, `gpt-5.2`, and `gpt-5-thinking*` ids are not first-class catalog entries.

## Anthropic (`LanguageModel.Anthropic`)

- `claude-opus-5` (1M context, 128K max output, non-streaming until refusal rollback is streaming-safe)
- `claude-sonnet-5` (1M context, 128K max output)
- `claude-fable-5` (1M context, 128K max output, non-streaming, explicit opt-in)
- `claude-opus-4-8` (1M context, 128K max output, non-streaming until refusal rollback is streaming-safe)
- `claude-opus-4-7`
- `claude-opus-4-5`
- `claude-opus-4-1-20250805`
- `claude-sonnet-4-6`
- `claude-sonnet-4-5-20250929`
- `claude-haiku-4-5`

## Google (`LanguageModel.Google`)

- `gemini-3.1-pro-preview`
- `gemini-3.1-flash-lite`
- `gemini-3-flash` (API id currently maps to `gemini-3-flash-preview`)
- `gemini-2.5-pro`, `gemini-2.5-flash`, `gemini-2.5-flash-lite`

## MiniMax (`LanguageModel.MiniMax`)

- `MiniMax-M3` (1M context, multimodal image input)
- `MiniMax-M2.7`
- `MiniMax-M2.7-highspeed`

## Kimi / Moonshot AI (`LanguageModel.Kimi`)

- `kimi-k2.6`
- `kimi-k2.7-code`
- `kimi-k2.7-code-highspeed`

Kimi uses Moonshot's OpenAI-compatible endpoint at `https://api.moonshot.ai/v1`. Configure
`MOONSHOT_API_KEY` (or `KIMI_API_KEY`); override the endpoint with `MOONSHOT_BASE_URL`. K2.7 tool-call
turns preserve Moonshot's provider-native `reasoning_content` when replaying assistant history.

## xAI Grok (`LanguageModel.Grok`)

- `grok-4.3`
- `grok-4.20-0309-reasoning`, `grok-4.20-0309-non-reasoning`

## Mistral (`LanguageModel.Mistral`)

- `mistral-large-latest`, `mistral-medium-latest`, `mistral-medium-3-5`
- `mistral-small-latest`, `open-mistral-nemo-2407`, `codestral-latest`

## Groq (`LanguageModel.Groq`)

- `openai/gpt-oss-120b`, `openai/gpt-oss-20b`
- `llama-3.3-70b-versatile`, `llama-3.1-8b-instant`
- `meta-llama/llama-4-maverick-17b-128e-instruct`
- `meta-llama/llama-4-scout-17b-16e-instruct`

## Local (`LanguageModel.Ollama`, `LanguageModel.LMStudio`)

Local providers ship curated enums plus `.custom("<model-id>")` for anything your server exposes.

## Aggregators / custom endpoints

- `.openRouter(modelId:)`, `.together(modelId:)`, `.replicate(modelId:)`
- `.openaiCompatible(modelId:baseURL:)`, `.anthropicCompatible(modelId:baseURL:)`, `.custom(provider:)`
