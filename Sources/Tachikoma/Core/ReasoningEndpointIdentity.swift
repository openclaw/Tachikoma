#if canImport(CryptoKit)
import CryptoKit

private typealias ReasoningEndpointHasher = CryptoKit.SHA256
#else
import Crypto

private typealias ReasoningEndpointHasher = Crypto.SHA256
#endif
import Foundation

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
enum ReasoningEndpointIdentity {
    static func canonical(_ rawValue: String?) -> String? {
        guard
            let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            components.user == nil,
            components.password == nil,
            components.percentEncodedQuery == nil else
        {
            return nil
        }

        components.scheme = scheme
        components.host = host
        components.fragment = nil
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        guard let value = components.string else { return nil }
        return self.digest(value)
    }

    static func bindingAuthentication(
        to endpointIdentity: String?,
        apiKey: String?,
        headers: [AnyHashable: Any]?,
    )
        -> String?
    {
        guard let endpointIdentity else { return nil }

        // A deterministic digest of authentication material would become an
        // offline verifier when persisted in transcript metadata. Without a
        // process-local keyed identity, fail closed for authenticated sessions.
        guard apiKey?.isEmpty != false, headers?.isEmpty != false else { return nil }
        return endpointIdentity
    }

    private static func digest(_ value: String) -> String? {
        guard let data = value.data(using: .utf8) else { return nil }
        let digest = ReasoningEndpointHasher.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(digest)"
    }
}
