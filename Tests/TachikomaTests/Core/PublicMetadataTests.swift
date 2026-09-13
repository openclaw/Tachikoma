import Foundation
import Testing
@testable import Tachikoma

struct PublicMetadataTests {
    @Test(arguments: Provider.standardProviders)
    func `Standard provider identifiers round trip`(_ provider: Provider) {
        #expect(Provider.from(identifier: provider.identifier) == provider)
    }

    @Test
    func `LM Studio remains a local provider when configured by name`() {
        #expect(Provider.standardProviders.contains(.lmstudio))
        let provider = Provider.from(identifier: "LMSTUDIO")
        #expect(provider == .lmstudio)
        #expect(!provider.requiresAPIKey)
        #expect(provider.defaultBaseURL == "http://localhost:1234/v1")
        #expect(Provider.from(identifier: "custom-server") == .custom("custom-server"))
    }

    @Test
    func `Public platform metadata matches the package deployment declarations`() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let declarations = [
            "macOS": PlatformSupport.macOS,
            "iOS": PlatformSupport.iOS,
            "watchOS": PlatformSupport.watchOS,
            "tvOS": PlatformSupport.tvOS,
        ]
        for (platform, version) in declarations {
            let swiftVersion = version.hasSuffix(".0") ? String(version.dropLast(2)) : version.replacingOccurrences(
                of: ".",
                with: "_",
            )
            #expect(manifest.contains(".\(platform)(.v\(swiftVersion))"))
        }
    }
}
