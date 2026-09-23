import Foundation

// MARK: - Convenience API

/// Default model for the entire SDK
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public let defaultModel: Model = .default

/// Legacy no-op retained for source compatibility. Pass the model to generation calls explicitly.
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func setDefaultModel(_: Model) {}

// MARK: - Version Information

/// Current version of the Tachikoma SDK
public let tachikomaVersion = "0.5.1"

/// Minimum supported platform versions
public enum PlatformSupport {
    public static let macOS = "14.0"
    public static let iOS = "17.0"
    public static let watchOS = "10.0"
    public static let tvOS = "17.0"
}

// MARK: - Legacy Compatibility

/// Namespace for legacy API compatibility
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum Legacy {
    /// Legacy compatibility note
    @available(*, deprecated, message: "Use modern API with dependency injection instead")
    public static let compatibilityMessage = "Legacy types have been renamed with Legacy* prefix"

    /// Legacy model provider (deprecated) - now available as LegacyAIModelProvider
    @available(*, deprecated, message: "Use Model enum and global functions instead")
    public static let modelProviderNote = "Use LegacyAIModelProvider directly"

    /// Legacy model factory (deprecated) - now available as LegacyAIModelFactory
    @available(*, deprecated, message: "Use Model enum instead")
    public static let modelFactoryNote = "Use LegacyAIModelFactory directly"

    /// Legacy configuration (deprecated) - now available as LegacyAIConfiguration
    @available(*, deprecated, message: "Use AIConfiguration.fromEnvironment() instead")
    public static let configurationNote = "Use LegacyAIConfiguration directly"
}

/// Historical API-description constants retained for source compatibility. See README for current APIs.
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum API {
    public enum Generation {
        public static let generate = "Global function for text generation"

        public static let stream = "Global function for streaming generation"

        public static let analyze = "Global function for vision/multimodal generation"
    }

    public enum Models {
        public static let typed = "Provider-specific model enums"

        public static let custom = "Support for OpenRouter and custom endpoints"

        public static let capabilities = "Automatic capability detection"
    }

    public enum Conversations {
        public static let fluent = "Chainable conversation builder"

        public static let management = "Built-in conversation state management"

        public static let branching = "Conversation branching and merging"
    }

    public enum Tools {
        public static let builder = "Declarative tool definitions with @ToolKit"

        public static let manual = "Functional tool creation"

        public static let execution = "Seamless tool integration"
    }

    public enum SwiftUI {
        public static let propertyWrapper = "Reactive AI assistant property wrapper"

        public static let chatUI = "Ready-to-use chat interface"

        public static let observable = "ObservableObject-based state management"
    }

    public enum CLI {
        public static let parsing = "Intelligent model string parsing with shortcuts"

        public static let validation = "Model capability requirements validation"

        public static let help = "Automatic CLI help and model listing"
    }
}

// MARK: - Migration Guide

/// Historical migration strings retained for source compatibility; these are not current usage examples.
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum MigrationGuide {
    /// Legacy: `Tachikoma.shared.getModel("gpt-5.5").getResponse(request)`
    /// Modern: `generate("Hello", using: .openai(.gpt55))`
    public static let simpleGeneration = """
    // OLD (deprecated)
    let model = try await Tachikoma.shared.getModel("gpt-5.5")
    let request = ModelRequest(messages: [.user(content: .text("Hello"))], settings: .default)
    let response = try await model.getResponse(request: request)

    // NEW (modern)
    let response = try await generate("Hello", using: .openai(.gpt55))
    """

    /// Legacy: Complex ModelRequest/ModelResponse handling
    /// Modern: Fluent conversation management
    public static let conversations = """
    // OLD (deprecated)
    var messages: [Message] = [.system(content: "You are helpful")]
    messages.append(.user(content: .text("Hello")))
    let request = ModelRequest(messages: messages, settings: .default)
    let response = try await model.getResponse(request: request)
    messages.append(.assistant(content: response.content))

    // NEW (modern)
    let conversation = Conversation()
        .system("You are helpful")
        .user("Hello")
    let response = try await conversation.continue(using: .claude)
    """

    /// Legacy: Manual tool definitions
    /// Modern: @ToolKit result builder
    public static let tools = """
    // OLD (deprecated)
    let toolDef = AgentToolDefinition(
        type: .function,
        function: AgentFunctionDefinition(name: "weather", description: "Get weather", parameters: ...)
    )
    let tools = [toolDef]
    let request = ModelRequest(messages: messages, tools: tools, settings: .default)

    // NEW (modern)
    // @ToolKit
    struct MyTools {
        func getWeather(location: String) async throws -> String {
            return "Sunny, 22°C"
        }
    }

    let response = try await generate("Weather in Tokyo", using: .claude, tools: MyTools())
    """

    /// Legacy: Manual SwiftUI state management
    /// Modern: @AI property wrapper
    public static let swiftUI = """
    // OLD (deprecated)
    @StateObject private var viewModel = ChatViewModel()
    // Manual message management, loading states, error handling...

    // NEW (modern)
    @AI(.claude, systemPrompt: "You are helpful")
    var assistant

    // Automatic state management, built-in chat UI, reactive updates
    """
}

/// Legacy migration hook; always returns false.
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func checkMigrationNeeded() -> Bool {
    false
}
