import Foundation

// MARK: - Tachikoma - Modern AI SDK

// MARK: - Module Re-exports

//
// Tachikoma - A comprehensive Swift package for AI model integration
//
// Named after the AI entity from Ghost in the Shell, Tachikoma embodies
// the cyberpunk aesthetic of autonomous AI systems.
//
// ## Modern API Design
//
// Tachikoma 4.0+ provides a Swift-native API that feels like a natural extension
// of Swift itself, providing powerful AI capabilities with minimal complexity.
//
// ### Core Features
// - **Type-safe model selection** with provider-specific enums
// - **Global generation functions** for simple one-line AI calls
// - **Fluent conversation management** for multi-turn interactions
// - **Result builder toolkits** for easy tool integration
// - **SwiftUI property wrappers** for reactive AI components
// - **Comprehensive provider support** (OpenAI, Anthropic, Grok, Ollama, custom)
//
// ### Quick Start
//
// ```swift
// // Simple generation
// let answer = try await generate("What is 2+2?", using: .openai(.gpt55))
//
// // Conversation management
// let conversation = Conversation()
//     .system("You are a helpful assistant")
//     .user("Hello!")
// let response = try await conversation.continue(using: .claude)
//
// // SwiftUI integration
// @AI(.anthropic(.opus4), systemPrompt: "You are helpful")
// var assistant
// ```

// All functionality is now included directly in the Tachikoma module
// No need for internal imports since everything is in the same target

// MARK: - Convenience API

/// Default model for the entire SDK
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public let defaultModel: Model = .default

/// Set the default model for all operations (placeholder - would use actor in real implementation)
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func setDefaultModel(_: Model) {
    // In real implementation, would use actor or other thread-safe mechanism
    // For now, this is just a placeholder function
}

// MARK: - Version Information

/// Current version of the Tachikoma SDK
public let tachikomaVersion = "0.4.2"

/// Minimum supported platform versions
public enum PlatformSupport {
    public static let macOS = "13.0"
    public static let iOS = "16.0"
    public static let watchOS = "9.0"
    public static let tvOS = "16.0"
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

// MARK: - Modern API Summary

/// Summary of the Tachikoma API for documentation
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public enum API {
    /// Core generation functions
    public enum Generation {
        /// Generate a response from a prompt
        /// - `generate(_ prompt: String, using model: Model?, ...) async throws -> String`
        public static let generate = "Global function for text generation"

        /// Stream a response from a prompt
        /// - `stream(_ prompt: String, using model: Model?, ...) -> AsyncThrowingStream<StreamToken, Error>`
        public static let stream = "Global function for streaming generation"

        /// Analyze an image with a prompt
        /// - `analyze(image: ImageInput, prompt: String, using model: Model?) async throws -> String`
        public static let analyze = "Global function for vision/multimodal generation"
    }

    /// Model selection system
    public enum Models {
        /// Type-safe model selection
        /// - `.openai(.gpt55)`, `.anthropic(.opus47)`, `.grok(.grok43)`, `.ollama(.llama3_3)`
        public static let typed = "Provider-specific model enums"

        /// Custom endpoints
        /// - `.openRouter(modelId: String)`, `.openaiCompatible(modelId: String, baseURL: String)`
        public static let custom = "Support for OpenRouter and custom endpoints"

        /// Model capabilities
        /// - `.supportsVision`, `.supportsTools`, `.supportsStreaming`
        public static let capabilities = "Automatic capability detection"
    }

    /// Conversation management
    public enum Conversations {
        /// Fluent conversation building
        /// - `Conversation().system(...).user(...).continue(using: model)`
        public static let fluent = "Chainable conversation builder"

        /// Multi-turn management
        /// - Automatic message history, tool call handling, response accumulation
        public static let management = "Built-in conversation state management"

        /// Branching and copying
        /// - `.copy()`, `.branch(fromIndex:)`, `.merge(_:)`
        public static let branching = "Conversation branching and merging"
    }

    /// Tool system
    public enum Tools {
        /// Result builder syntax
        /// - ```
        ///   @ToolKit struct MyTools {
        ///       func myTool() async throws -> String
        ///   }
        ///   ```
        public static let builder = "Declarative tool definitions with @ToolKit"

        /// Manual tool creation
        /// - `tool(name: "example", description: "...", parameters: ...) { input, context in ... }`
        public static let manual = "Functional tool creation"

        /// Automatic execution
        /// - Tool calls are automatically handled during conversation
        public static let execution = "Seamless tool integration"
    }

    /// SwiftUI integration
    public enum SwiftUI {
        /// Property wrapper
        /// - `@AI(.claude, systemPrompt: "...") var assistant`
        public static let propertyWrapper = "Reactive AI assistant property wrapper"

        /// Built-in chat UI
        /// - `.aiChat(model: .claude, isPresented: $showChat)`
        public static let chatUI = "Ready-to-use chat interface"

        /// Observable state
        /// - Automatic UI updates, loading states, error handling
        public static let observable = "ObservableObject-based state management"
    }

    /// CLI utilities
    public enum CLI {
        /// Smart model parsing
        /// - `ModelSelector.parseModel("claude")` → `.anthropic(.opus4)`
        public static let parsing = "Intelligent model string parsing with shortcuts"

        /// Capability validation
        /// - `ModelSelector.validateModel(model, requiresVision: true)`
        public static let validation = "Model capability requirements validation"

        /// Help generation
        /// - `getAllAvailableModels()` for comprehensive CLI help
        public static let help = "Automatic CLI help and model listing"
    }
}

// MARK: - Migration Guide

/// Migration guide from legacy API to modern API
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

/// Check if migration is needed based on current usage
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public func checkMigrationNeeded() -> Bool {
    // In a real implementation, this could check for deprecated API usage
    false
}
