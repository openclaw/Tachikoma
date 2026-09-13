import Foundation
#if os(iOS) || os(tvOS) || os(watchOS)
import UIKit
#endif

protocol ResponseCacheSafetyProviding {
    var isResponseCacheSafe: Bool { get }
}

private final class CacheMemoryObservation: @unchecked Sendable {
    let token: any NSObjectProtocol
    init(_ token: any NSObjectProtocol) {
        self.token = token
    }

    deinit { NotificationCenter.default.removeObserver(self.token) }
}

// MARK: - Cache Key

/// Hashable key for cache entries
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct CacheProviderIdentity: Hashable, Sendable {
    public let providerKind: String
    public let modelId: String
    public let endpointIdentity: String?
    public let isCacheable: Bool

    public init(providerKind: String, modelId: String, baseURL: String?, hasAuthentication: Bool = false) {
        self.providerKind = providerKind
        self.modelId = modelId
        self.endpointIdentity = ReasoningEndpointIdentity.canonical(baseURL)
        self.isCacheable = !hasAuthentication && (baseURL == nil || self.endpointIdentity != nil)
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
struct CacheKey: Hashable {
    let hash: String
    let model: String? // Store model ID for invalidation
    let isCacheable: Bool

    init(from request: ProviderRequest, providerIdentity: CacheProviderIdentity? = nil, model: String? = nil) {
        self.model = providerIdentity?.modelId ?? model
        if providerIdentity?.isCacheable == false {
            self.hash = ""
            self.isCacheable = false
            return
        }
        // Create a unique hash from the request
        var hasher = Hasher()
        if let providerIdentity {
            hasher.combine(providerIdentity.providerKind)
            hasher.combine(providerIdentity.modelId)
            hasher.combine(providerIdentity.endpointIdentity)
        }
        // Combine message content
        for message in request.messages {
            hasher.combine(message.role.rawValue)
            hasher.combine(message.channel?.rawValue)
            hasher.combine(message.metadata?.conversationId)
            hasher.combine(message.metadata?.turnId)
            for key in message.metadata?.customData?.keys.sorted() ?? [] {
                hasher.combine(key)
                hasher.combine(message.metadata?.customData?[key])
            }
            for part in message.content {
                switch part {
                case let .text(text):
                    hasher.combine(text)
                case let .image(image):
                    hasher.combine(image.mimeType)
                    hasher.combine(image.data.prefix(100)) // Use first 100 chars of base64 data
                case let .reasoning(reasoning):
                    hasher.combine(reasoning.id)
                    hasher.combine(reasoning.encryptedContent)
                    for summary in reasoning.summary ?? [] {
                        hasher.combine(summary.type)
                        hasher.combine(summary.text)
                    }
                case let .toolCall(call):
                    hasher.combine(call.id)
                    hasher.combine(call.name)
                case let .toolResult(result):
                    hasher.combine(result.toolCallId)
                }
            }
        }
        // Combine tools
        if let tools = request.tools {
            hasher.combine(tools.map(\.name))
        }
        // Combine settings
        hasher.combine(request.settings.temperature)
        hasher.combine(request.settings.maxTokens)
        hasher.combine(request.settings.topP)
        hasher.combine(request.settings.topK)
        hasher.combine(request.settings.frequencyPenalty)
        hasher.combine(request.settings.presencePenalty)
        hasher.combine(request.settings.stopSequences)
        hasher.combine(request.settings.reasoningEffort?.rawValue)
        hasher.combine(request.settings.seed)
        if let stopConditions = request.settings.stopConditions {
            guard let cacheKey = (stopConditions as? StableCacheKeyStopCondition)?.stableCacheKey else {
                self.hash = ""
                self.isCacheable = false
                return
            }
            hasher.combine(cacheKey)
        }
        if let providerOptionsData = try? Self.providerOptionsEncoder.encode(request.settings.providerOptions) {
            hasher.combine(providerOptionsData)
        }
        self.hash = String(hasher.finalize())
        self.isCacheable = true
    }

    private static let providerOptionsEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

// MARK: - Response Cache

/// Cache with TTL, memory management, and invalidation strategies
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public actor ResponseCache {
    // MARK: - Properties

    private var cache: [CacheKey: CacheEntry] = [:]
    private let configuration: CacheConfiguration
    private var accessOrder: [CacheKey] = []
    private var memoryPressureObserver: CacheMemoryObservation?
    private var cleanupTask: Task<Void, Never>?
    private var statistics = CacheStatisticsTracker()

    // MARK: - Initialization

    public init(configuration: CacheConfiguration = .default) {
        self.configuration = configuration
        Task { [weak self] in
            await self?.setupMemoryPressureHandling()
            await self?.setupPeriodicCleanup()
        }
    }

    deinit { self.cleanupTask?.cancel() }

    // MARK: - Public Methods

    /// Get cached response with TTL validation
    public func get(
        for request: ProviderRequest,
        ttlOverride: TimeInterval? = nil,
        providerIdentity: CacheProviderIdentity? = nil,
    )
        -> ProviderResponse?
    {
        // Get cached response with TTL validation
        let key = CacheKey(from: request, providerIdentity: providerIdentity)
        guard key.isCacheable else {
            self.statistics.recordMiss()
            return nil
        }

        guard let entry = cache[key] else {
            self.statistics.recordMiss()
            return nil
        }

        // Check TTL
        let ttl = ttlOverride ?? entry.ttl ?? self.configuration.defaultTTL
        if entry.isExpired(ttl: ttl) {
            self.cache.removeValue(forKey: key)
            self.accessOrder.removeAll { $0 == key }
            self.statistics.recordEviction(reason: .expired)
            return nil
        }

        // Update access time and order for LRU
        entry.recordAccess()
        self.updateAccessOrder(for: key)

        self.statistics.recordHit()
        return entry.response
    }

    /// Store response with custom TTL and priority
    public func store(
        _ response: ProviderResponse,
        for request: ProviderRequest,
        ttl: TimeInterval? = nil,
        priority: CachePriority = .normal,
        providerIdentity: CacheProviderIdentity? = nil,
    ) {
        // Store response with custom TTL and priority
        let key = CacheKey(from: request, providerIdentity: providerIdentity)
        guard key.isCacheable else {
            return
        }

        // Check memory limit
        if self.shouldEvictForMemory() {
            self.evictByStrategy()
        }

        // Check count limit
        if self.cache.count >= self.configuration.maxEntries, self.cache[key] == nil {
            self.evictByStrategy()
        }

        let entry = CacheEntry(
            response: response,
            ttl: ttl,
            priority: priority,
        )

        self.cache[key] = entry
        self.updateAccessOrder(for: key)
        self.statistics.recordStore()
    }

    /// Invalidate entries matching predicate
    func invalidate(
        matching predicate: @escaping (CacheKey, CacheEntry) -> Bool,
    ) {
        // Invalidate entries matching predicate
        let toRemove = self.cache.filter { predicate($0.key, $0.value) }

        for (key, _) in toRemove {
            self.cache.removeValue(forKey: key)
            self.accessOrder.removeAll { $0 == key }
            self.statistics.recordEviction(reason: .invalidated)
        }
    }

    /// Invalidate entries by model
    public func invalidateModel(_ modelId: String) {
        // Invalidate entries by model
        self.invalidate { key, _ in
            key.model == modelId
        }
    }

    /// Invalidate entries older than specified age
    public func invalidateOlderThan(_ age: TimeInterval) {
        // Invalidate entries older than specified age
        let cutoff = Date().addingTimeInterval(-age)
        self.invalidate { _, entry in
            entry.createdAt < cutoff
        }
    }

    /// Clear all cache entries
    public func clear() {
        // Clear all cache entries
        let count = self.cache.count
        self.cache.removeAll()
        self.accessOrder.removeAll()
        self.statistics.recordBulkEviction(count: count, reason: .cleared)
    }

    /// Get cache statistics
    public func getStatistics() -> EnhancedCacheStatistics {
        // Get cache statistics
        self.statistics.snapshot(
            currentEntries: self.cache.count,
            maxEntries: self.configuration.maxEntries,
        )
    }

    /// Prewarm cache with common requests
    public func prewarm(
        with requests: [(ProviderRequest, ProviderResponse)],
        ttl: TimeInterval? = nil,
    ) {
        // Prewarm cache with common requests
        for (request, response) in requests {
            self.store(response, for: request, ttl: ttl, priority: .high)
        }
    }

    // MARK: - Private Methods

    private func setupMemoryPressureHandling() {
        #if os(iOS) || os(tvOS) || os(watchOS)
        let observation = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task {
                await self?.handleMemoryPressure()
            }
        }
        self.memoryPressureObserver = CacheMemoryObservation(observation)
        #elseif os(macOS)
        // macOS doesn't have UIApplication memory warnings
        // Could use ProcessInfo.processInfo.thermalState monitoring instead
        #endif
    }

    private func setupPeriodicCleanup() {
        self.cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                guard let self else { return }
                await self.performCleanup()
            }
        }
    }

    private func performCleanup() {
        var evictedCount = 0

        // Remove expired entries
        let expiredKeys = self.cache.compactMap { key, entry -> CacheKey? in
            let ttl = entry.ttl ?? self.configuration.defaultTTL
            return entry.isExpired(ttl: ttl) ? key : nil
        }

        for key in expiredKeys {
            self.cache.removeValue(forKey: key)
            self.accessOrder.removeAll { $0 == key }
            evictedCount += 1
        }

        if evictedCount > 0 {
            self.statistics.recordBulkEviction(count: evictedCount, reason: .expired)
        }
    }

    private func handleMemoryPressure() async {
        switch self.configuration.memoryPressureStrategy {
        case .clearAll:
            self.clear()
        case .clearHalf:
            self.evictPercentage(50)
        case .clearLowPriority:
            self.evictLowPriority()
        case .adaptive:
            // Remove 30% of least recently used
            self.evictPercentage(30)
        }
    }

    private func shouldEvictForMemory() -> Bool {
        guard self.configuration.memoryLimit > 0 else { return false }

        // Estimate memory usage (simplified)
        let estimatedSize = self.cache.values.reduce(0) { total, entry in
            total + entry.estimatedMemorySize()
        }

        return estimatedSize > self.configuration.memoryLimit
    }

    private func evictByStrategy() {
        switch self.configuration.evictionStrategy {
        case .lru:
            self.evictLRU()
        case .lfu:
            self.evictLFU()
        case .fifo:
            self.evictFIFO()
        case .priority:
            self.evictLowestPriority()
        }
    }

    private func evictLRU() {
        guard let firstKey = accessOrder.first else { return }
        self.cache.removeValue(forKey: firstKey)
        self.accessOrder.removeFirst()
        self.statistics.recordEviction(reason: .capacityReached)
    }

    private func evictLFU() {
        // Evict least frequently used
        let leastUsed = self.cache.min { $0.value.accessCount < $1.value.accessCount }
        if let key = leastUsed?.key {
            self.cache.removeValue(forKey: key)
            self.accessOrder.removeAll { $0 == key }
            self.statistics.recordEviction(reason: .capacityReached)
        }
    }

    private func evictFIFO() {
        // Evict oldest entry
        let oldest = self.cache.min { $0.value.createdAt < $1.value.createdAt }
        if let key = oldest?.key {
            self.cache.removeValue(forKey: key)
            self.accessOrder.removeAll { $0 == key }
            self.statistics.recordEviction(reason: .capacityReached)
        }
    }

    private func evictLowestPriority() {
        // Find lowest priority entries
        let sorted = self.cache.sorted { $0.value.priority.rawValue < $1.value.priority.rawValue }
        if let first = sorted.first {
            self.cache.removeValue(forKey: first.key)
            self.accessOrder.removeAll { $0 == first.key }
            self.statistics.recordEviction(reason: .capacityReached)
        }
    }

    private func evictLowPriority() {
        let lowPriorityKeys = self.cache.compactMap { key, entry -> CacheKey? in
            entry.priority == .low ? key : nil
        }

        for key in lowPriorityKeys {
            self.cache.removeValue(forKey: key)
            self.accessOrder.removeAll { $0 == key }
        }

        self.statistics.recordBulkEviction(count: lowPriorityKeys.count, reason: .memoryPressure)
    }

    private func evictPercentage(_ percentage: Int) {
        let toRemove = max(1, cache.count * percentage / 100)

        // Remove least recently used
        for _ in 0..<toRemove {
            guard !self.accessOrder.isEmpty else { break }
            let key = self.accessOrder.removeFirst()
            self.cache.removeValue(forKey: key)
        }

        self.statistics.recordBulkEviction(count: toRemove, reason: .memoryPressure)
    }

    private func updateAccessOrder(for key: CacheKey) {
        if let index = accessOrder.firstIndex(of: key) {
            self.accessOrder.remove(at: index)
        }
        self.accessOrder.append(key)
    }
}

// MARK: - Cache Configuration

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct CacheConfiguration: Sendable {
    public let maxEntries: Int
    public let defaultTTL: TimeInterval
    public let memoryLimit: Int // in bytes, 0 = unlimited
    public let evictionStrategy: EvictionStrategy
    public let memoryPressureStrategy: MemoryPressureStrategy

    public init(
        maxEntries: Int = 1000,
        defaultTTL: TimeInterval = 3600, // 1 hour
        memoryLimit: Int = 100 * 1024 * 1024, // 100MB
        evictionStrategy: EvictionStrategy = .lru,
        memoryPressureStrategy: MemoryPressureStrategy = .adaptive,
    ) {
        self.maxEntries = maxEntries
        self.defaultTTL = defaultTTL
        self.memoryLimit = memoryLimit
        self.evictionStrategy = evictionStrategy
        self.memoryPressureStrategy = memoryPressureStrategy
    }

    public static let `default` = CacheConfiguration()

    public static let aggressive = CacheConfiguration(
        maxEntries: 100,
        defaultTTL: 300, // 5 minutes
        memoryLimit: 10 * 1024 * 1024, // 10MB
    )

    public static let generous = CacheConfiguration(
        maxEntries: 10000,
        defaultTTL: 7200, // 2 hours
        memoryLimit: 500 * 1024 * 1024, // 500MB
    )
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum EvictionStrategy: String, Sendable {
    case lru // Least Recently Used
    case lfu // Least Frequently Used
    case fifo // First In First Out
    case priority // Priority-based
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum MemoryPressureStrategy: String, Sendable {
    case clearAll
    case clearHalf
    case clearLowPriority
    case adaptive
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum CachePriority: Int, Sendable, Comparable {
    case low = 0
    case normal = 1
    case high = 2
    case critical = 3

    public static func < (lhs: CachePriority, rhs: CachePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Cache Entry

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
final class CacheEntry: @unchecked Sendable {
    let response: ProviderResponse
    let createdAt: Date
    let ttl: TimeInterval?
    let priority: CachePriority

    private(set) var lastAccessedAt: Date
    private(set) var accessCount: Int

    init(
        response: ProviderResponse,
        ttl: TimeInterval? = nil,
        priority: CachePriority = .normal,
    ) {
        self.response = response
        self.createdAt = Date()
        self.ttl = ttl
        self.priority = priority
        self.lastAccessedAt = Date()
        self.accessCount = 0
    }

    func recordAccess() {
        self.lastAccessedAt = Date()
        self.accessCount += 1
    }

    func isExpired(ttl: TimeInterval) -> Bool {
        Date().timeIntervalSince(self.createdAt) > ttl
    }

    func estimatedMemorySize() -> Int {
        // Rough estimation based on response content
        let textSize = self.response.text.utf8.count
        let toolCallsSize = (response.toolCalls?.count ?? 0) * 100 // Estimate 100 bytes per tool call
        let reasoningSize = self.response.reasoning.reduce(0) { total, block in
            total + block.text.utf8.count +
                (block.signature?.utf8.count ?? 0) +
                (block.rawJSON?.utf8.count ?? 0) +
                block.type.utf8.count
        }
        let assistantMessageSize = self.response.assistantMessages.reduce(0) { total, message in
            let contentSize = message.content.reduce(0) { contentTotal, part in
                switch part {
                case let .text(text):
                    contentTotal + text.utf8.count
                case let .image(image):
                    contentTotal + image.mimeType.utf8.count + image.data.utf8.count
                case let .reasoning(reasoning):
                    contentTotal + reasoning.id.utf8.count + reasoning.encryptedContent.utf8.count +
                        (reasoning.summary?.reduce(0) { $0 + $1.type.utf8.count + $1.text.utf8.count } ?? 0)
                case let .toolCall(call):
                    contentTotal + call.id.utf8.count + call.name.utf8.count + 100
                case let .toolResult(result):
                    contentTotal + result.toolCallId.utf8.count + 100
                }
            }
            let metadataSize = (message.metadata?.customData ?? [:]).reduce(0) { metadataTotal, pair in
                metadataTotal + pair.key.utf8.count + pair.value.utf8.count
            }
            return total + contentSize + metadataSize + (message.channel?.rawValue.utf8.count ?? 0)
        }
        let usageSize = 50 // Fixed overhead for usage data

        return textSize + toolCallsSize + reasoningSize + assistantMessageSize + usageSize + 100
    }
}

// MARK: - Statistics Tracking

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
final class CacheStatisticsTracker: @unchecked Sendable {
    private var hits: Int = 0
    private var misses: Int = 0
    private var stores: Int = 0
    private var evictions: [EvictionReason: Int] = [:]
    private let startTime = Date()

    func recordHit() {
        self.hits += 1
    }

    func recordMiss() {
        self.misses += 1
    }

    func recordStore() {
        self.stores += 1
    }

    func recordEviction(reason: EvictionReason) {
        self.evictions[reason, default: 0] += 1
    }

    func recordBulkEviction(count: Int, reason: EvictionReason) {
        self.evictions[reason, default: 0] += count
    }

    func snapshot(currentEntries: Int, maxEntries: Int) -> EnhancedCacheStatistics {
        let hitRate = self.hits + self.misses > 0 ? Double(self.hits) / Double(self.hits + self.misses) : 0

        return EnhancedCacheStatistics(
            currentEntries: currentEntries,
            maxEntries: maxEntries,
            hits: self.hits,
            misses: self.misses,
            hitRate: hitRate,
            stores: self.stores,
            evictions: self.evictions,
            uptime: Date().timeIntervalSince(self.startTime),
        )
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum EvictionReason: String, Sendable {
    case expired
    case capacityReached
    case memoryPressure
    case invalidated
    case cleared
}

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct EnhancedCacheStatistics: Sendable {
    public let currentEntries: Int
    public let maxEntries: Int
    public let hits: Int
    public let misses: Int
    public let hitRate: Double
    public let stores: Int
    public let evictions: [EvictionReason: Int]
    public let uptime: TimeInterval
}

// MARK: - Cache Extensions

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension ResponseCache {
    /// Create a cache-aware provider
    public func wrapProvider<T: ModelProvider>(_ provider: T) -> CacheAwareProvider<T> {
        // Create a cache-aware provider
        CacheAwareProvider(provider: provider, cache: self)
    }
}

/// Cache-aware provider with enhanced features
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct CacheAwareProvider<Base: ModelProvider>: ModelProvider {
    let provider: Base
    let cache: ResponseCache
    private let providerIdentity: CacheProviderIdentity

    public var modelId: String {
        self.provider.modelId
    }

    public var baseURL: String? {
        self.provider.baseURL
    }

    public var apiKey: String? {
        self.provider.apiKey
    }

    public var capabilities: ModelCapabilities {
        self.provider.capabilities
    }

    init(provider: Base, cache: ResponseCache) {
        self.provider = provider
        self.cache = cache
        self.providerIdentity = CacheProviderIdentity(
            providerKind: String(reflecting: Base.self),
            modelId: provider.modelId,
            baseURL: provider.baseURL,
            hasAuthentication: provider.apiKey?.isEmpty == false ||
                (provider as? any ResponseCacheSafetyProviding)?.isResponseCacheSafe == false,
        )
    }

    public func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        // Check cache with smart TTL based on request type
        let ttl = self.determineTTL(for: request)

        if let cached = await cache.get(for: request, ttlOverride: ttl, providerIdentity: self.providerIdentity) {
            return cached
        }

        // Generate and cache with appropriate priority
        let response = try await provider.generateText(request: request)
        let priority = self.determinePriority(for: request)

        await self.cache.store(
            response,
            for: request,
            ttl: ttl,
            priority: priority,
            providerIdentity: self.providerIdentity,
        )
        return response
    }

    public func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        // Streaming bypasses cache but could cache the final result
        try await self.provider.streamText(request: request)
    }

    private func determineTTL(for request: ProviderRequest) -> TimeInterval {
        // Shorter TTL for requests with tools (more dynamic)
        if request.tools != nil, !request.tools!.isEmpty {
            return 300 // 5 minutes
        }

        // Longer TTL for simple completions
        return 3600 // 1 hour
    }

    private func determinePriority(for request: ProviderRequest) -> CachePriority {
        // Higher priority for expensive requests
        if let maxTokens = request.settings.maxTokens, maxTokens > 2000 {
            return .high
        }

        // Higher priority for requests with many messages (conversation history)
        if request.messages.count > 10 {
            return .high
        }

        return .normal
    }
}
