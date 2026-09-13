# Examples

The root Swift package builds two sample command-line products:

```sh
swift run ai-cli --help
swift build --product gpt5cli
```

`gpt5cli` prints usage when invoked without a query (exit status 1).

See [AI CLI](AI-CLI/README.md) for generation options. Requests need the selected provider's credentials or a running local server.

[RealtimeExample.swift](RealtimeExample.swift) is a small host-integration example. Add it to an application target that links `Tachikoma` and `TachikomaAudio`, start it with your configuration, send text, and call `stop()` when finished. The host owns microphone permission and audio capture; see [Realtime voice](../docs/openai-harmony.md).

The old loose Harmony, realtime, and advanced demo files duplicated outdated APIs and were not SwiftPM targets. Current examples live here and in the [README](../README.md), [local-model guides](../docs/lmstudio.md), and [tool guide](../docs/tool-system-migration.md).
