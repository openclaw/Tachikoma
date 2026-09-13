# Azure OpenAI

Tachikoma routes Azure deployments through `AzureOpenAIProvider` and the shared OpenAI-compatible chat serializer. Supply your Azure **deployment name**, which may differ from the underlying model ID.

```swift
import Tachikoma

let result = try await generateText(
    model: .azureOpenAI(
        deployment: "my-chat-deployment",
        resource: "my-resource",
        apiVersion: "2025-04-01-preview"
    ),
    messages: [.user("Explain actors in Swift.")]
)
print(result.text)
```

The provider uses:

```text
POST https://{resource}.openai.azure.com/openai/deployments/{deployment}/chat/completions?api-version={version}
```

Streaming uses the same route with `stream: true`. The Azure adapter does not select the OpenAI Responses API.

## Configuration

| Setting | Resolution |
| --- | --- |
| Endpoint | Model `endpoint`, configured `.azureOpenAI` base URL, `AZURE_OPENAI_ENDPOINT`, then the model `resource` or `AZURE_OPENAI_RESOURCE` |
| API version | Model `apiVersion`, `AZURE_OPENAI_API_VERSION`, then `configuration.azureOpenAIDefaultAPIVersion` (currently `2025-04-01-preview`) |
| Bearer token | `AZURE_OPENAI_BEARER_TOKEN`, then `AZURE_OPENAI_TOKEN`; a nonempty token takes precedence over an API key |
| API key | Configuration's `.azureOpenAI` key, then `AZURE_OPENAI_API_KEY` |

Bearer authentication uses `Authorization: Bearer …`; API-key authentication uses `api-key: …`. Tachikoma does not acquire an Entra token for you.

For a custom domain or sovereign-cloud endpoint, pass `endpoint:` instead of a resource name:

```swift
let model = LanguageModel.azureOpenAI(
    deployment: "my-chat-deployment",
    apiVersion: "2025-04-01-preview",
    endpoint: "https://example.openai.azure.com"
)
```

Use an API version supported by your deployment and requested features. The SDK's default is a configuration default, not a claim that it is the newest Azure API version.

## Troubleshooting

A 401 usually requires checking the selected credential and authentication header. A 404 requires checking the endpoint and deployment name. A 400 may indicate unsupported request parameters or an incompatible API version. The adapter's URL/header behavior is covered by `AzureOpenAIProviderTests`; custom OpenAI-compatible endpoints continue to use their own routing.
