@_exported import Logging

/// Compatibility namespace retained for existing consumers.
public enum TachikomaCore {}

/// Compatibility indicator; the API is available on all supported package platforms.
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public var modernAPIAvailable: Bool {
    true
}
