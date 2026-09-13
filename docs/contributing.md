# Contributing

This is a SwiftPM package. The supported source minimum is Swift 6.2. CI keeps Swift 6.2.4 coverage (Xcode 26.3 on macOS) and also tests Swift 6.3.3 on Linux. SwiftFormat 0.63.0 and SwiftLint 0.65.1 are installed from checksum-verified release binaries.

## Development

```sh
git clone https://github.com/openclaw/Tachikoma.git
cd Tachikoma
swift build
swiftformat --lint .
swiftlint lint --config .swiftlint.yml --strict
TACHIKOMA_TEST_MODE=mock TACHIKOMA_DISABLE_API_TESTS=true swift test --parallel
```

The macOS `scripts/install-ci-tools.sh <destination>` helper installs the same pinned linters used by CI.

Use the package's existing providers and serializers when adding integrations. See [architecture](ARCHITECTURE.md) for ownership boundaries. Keep user-visible fixes and features in `CHANGELOG.md` under `Unreleased`; maintainers add contributor release notes when landing a PR.

## Tests

Tests use Swift Testing. Default tests must run without credentials or external services:

```swift
import Testing
@testable import Tachikoma

struct ModelParsingExampleTests {
    @Test
    func parsesCustomLocalModel() {
        #expect(LanguageModel.parse(from: "ollama/my-model:latest") == .ollama(.custom("my-model:latest")))
    }
}
```

`python3 scripts/check-doc-examples.py` typechecks the integration-guide snippets and Realtime sample on macOS against the debug build and declared deployment minimum. Pass document paths to check a smaller set.

For provider behavior, inject a fixture `URLSession` or use `TestHelpers` to configure a mock provider. Assert encoded requests as well as decoded results. For concurrent behavior, use controlled events or clocks; avoid upper wall-clock bounds and fixture assumptions about pipe capacity.

The macOS CI job runs the full hermetic suite. Linux excludes the two suites documented in [testing](testing.md) because of FoundationNetworking URLProtocol limitations. Live-provider tests are a separate opt-in workflow.

## Coverage

```sh
TACHIKOMA_TEST_MODE=mock TACHIKOMA_DISABLE_API_TESTS=true swift test --parallel --enable-code-coverage
```

Coverage is optional. The testing guide describes the report command; `scripts/core-coverage.sh` reports the same core/model scope from either per-file SwiftPM objects or a Swift Build module object.
