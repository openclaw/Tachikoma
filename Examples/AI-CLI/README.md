# AI CLI

A command-line interface for querying AI models through the Tachikoma library.

## Building

```bash
# Clone and build
git clone https://github.com/openclaw/Tachikoma.git
cd Tachikoma
swift build --product ai-cli

# Install globally (optional)
swift build -c release --product ai-cli
cp .build/release/ai-cli /usr/local/bin/ai-cli
```

## Usage

```bash
# Basic usage
ai-cli "What is the capital of France?"

# Specify a model
ai-cli --model claude "Explain quantum computing"

# Stream the response
ai-cli --stream --model gpt-5.5 "Write a short story"
```

## Parameters

| Option | Description |
|--------|-------------|
| `-m, --model <MODEL>` | Specify the AI model to use |
| `--api <chat\|responses>` | For OpenAI models: select API type (default: responses for GPT-5) |
| `-s, --stream` | Stream the response in real-time |
| `--thinking` | Request and display the GPT-5 reasoning summary through the Responses API |
| `--verbose, -v` | Show detailed debug output |
| `--config` | Show current configuration and API key status |
| `--help, -h` | Show help message |
| `--version` | Show version information |

## Environment Variables

Set API keys for your providers:

```bash
export OPENAI_API_KEY='sk-...'         # OpenAI models
export ANTHROPIC_API_KEY='sk-ant-...'  # Claude models
export GEMINI_API_KEY='...'            # Gemini models (legacy GOOGLE_API_KEY also accepted)
export MISTRAL_API_KEY='...'           # Mistral models
export GROQ_API_KEY='gsk-...'          # Groq models
export X_AI_API_KEY='xai-...'          # Grok models
# Ollama runs locally, no API key needed
```

Add to your shell profile (`~/.zshrc`, `~/.bashrc`) for persistence.

## Supported Models

The [model catalog](../../docs/models.md) lists the current provider IDs and defaults. The CLI defaults to `gpt-5.5`; `--model claude` selects `LanguageModel.claude`. Local IDs can be explicit, for example `--model ollama/llama3.3` or `--model lmstudio/openai/gpt-oss-20b`.

## Examples

```bash
# Quick queries
ai-cli "What is 2+2?"
ai-cli --model claude "Write a haiku about coding"

# Streaming
ai-cli --stream --model gpt-5 "Explain the theory of relativity"

# API selection for OpenAI
ai-cli --model gpt-5 --api chat "Use Chat Completions API"
ai-cli --model gpt-5.5 --api responses "Use Responses API"

# Debug mode
ai-cli --verbose --model opus "Debug this request"

# Check configuration
ai-cli --config
```

## License

MIT License - See [LICENSE](../../LICENSE) file for details.
