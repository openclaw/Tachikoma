import Foundation
import Tachikoma

// MARK: - Built-in Tools

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct BuiltInTools {
    /// Get all built-in tools
    public static func all() -> [any RealtimeExecutableTool] {
        // Get all built-in tools
        [
            WeatherTool(),
            TimeTool(),
            CalculatorTool(),
            WebSearchTool(),
            TranslationTool(),
        ]
    }
}

// MARK: - Weather Tool

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct WeatherTool: RealtimeExecutableTool {
    public var metadata: RealtimeToolExecutor.ToolMetadata {
        RealtimeToolExecutor.ToolMetadata(
            name: "getWeather",
            description: "Get current weather information for a location",
            category: .information,
            parameters: AgentToolParameters(
                properties: [
                    "location": AgentToolParameterProperty(
                        name: "location",
                        type: .string,
                        description: "The city and state/country, e.g. 'San Francisco, CA' or 'London, UK'",
                    ),
                    "units": AgentToolParameterProperty(
                        name: "units",
                        type: .string,
                        description: "Temperature units: 'celsius' or 'fahrenheit' (default: celsius)",
                        enumValues: ["celsius", "fahrenheit"],
                    ),
                ],
                required: ["location"],
            ),
        )
    }

    public func execute(_ arguments: RealtimeToolArguments) async -> String {
        guard let location = arguments["location"]?.stringValue else {
            return "Error: Location is required"
        }

        let units = arguments["units"]?.stringValue ?? "celsius"

        // In a real implementation, this would call a weather API
        // For now, return mock data
        let temp = units == "fahrenheit" ? "72°F" : "22°C"
        return """
        Weather in \(location):
        Temperature: \(temp)
        Conditions: Partly cloudy
        Humidity: 65%
        Wind: 10 km/h NW
        """
    }

    public init() {}
}

// MARK: - Time Tool

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct TimeTool: RealtimeExecutableTool {
    public var metadata: RealtimeToolExecutor.ToolMetadata {
        RealtimeToolExecutor.ToolMetadata(
            name: "getCurrentTime",
            description: "Get the current time in a specific timezone",
            category: .information,
            parameters: AgentToolParameters(
                properties: [
                    "timezone": AgentToolParameterProperty(
                        name: "timezone",
                        type: .string,
                        description: "Timezone identifier (e.g., 'America/New_York', 'Europe/London'). Default is system timezone.",
                    ),
                    "format": AgentToolParameterProperty(
                        name: "format",
                        type: .string,
                        description: "Time format: '12hour' or '24hour' (default: 24hour)",
                        enumValues: ["12hour", "24hour"],
                    ),
                ],
                required: [],
            ),
        )
    }

    public func execute(_ arguments: RealtimeToolArguments) async -> String {
        let timezoneId = arguments["timezone"]?.stringValue ?? TimeZone.current.identifier
        let format = arguments["format"]?.stringValue ?? "24hour"

        guard let timezone = TimeZone(identifier: timezoneId) else {
            return "Error: Invalid timezone '\(timezoneId)'"
        }

        let formatter = DateFormatter()
        formatter.timeZone = timezone

        if format == "12hour" {
            formatter.dateFormat = "h:mm:ss a"
        } else {
            formatter.dateFormat = "HH:mm:ss"
        }

        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = timezone
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .none

        let now = Date()
        return """
        Current time in \(timezone.identifier):
        Time: \(formatter.string(from: now))
        Date: \(dateFormatter.string(from: now))
        """
    }

    public init() {}
}

// MARK: - Calculator Tool

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct CalculatorTool: RealtimeExecutableTool {
    public var metadata: RealtimeToolExecutor.ToolMetadata {
        RealtimeToolExecutor.ToolMetadata(
            name: "calculate",
            description: "Perform mathematical calculations",
            category: .calculation,
            parameters: AgentToolParameters(
                properties: [
                    "expression": AgentToolParameterProperty(
                        name: "expression",
                        type: .string,
                        description: "Mathematical expression to evaluate (e.g., '2 + 2', '10 * 5', 'sqrt(16)')",
                    ),
                ],
                required: ["expression"],
            ),
        )
    }

    public func execute(_ arguments: RealtimeToolArguments) async -> String {
        guard let expression = arguments["expression"]?.stringValue else {
            return "Error: Expression is required"
        }

        // Model text is not an NSExpression format string. A trailing operator
        // or "%" raises NSInvalidArgumentException, and "%@" can fault the
        // process. Swift does not catch that exception.
        guard let result = ArithmeticExpression.evaluate(expression) else {
            return "Error: Could not evaluate expression"
        }
        return "Result: \(result)"
    }

    public init() {}
}

// MARK: - Web Search Tool

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct WebSearchTool: RealtimeExecutableTool {
    public var metadata: RealtimeToolExecutor.ToolMetadata {
        RealtimeToolExecutor.ToolMetadata(
            name: "webSearch",
            description: "Search the web for information",
            category: .information,
            parameters: AgentToolParameters(
                properties: [
                    "query": AgentToolParameterProperty(
                        name: "query",
                        type: .string,
                        description: "Search query",
                    ),
                    "maxResults": AgentToolParameterProperty(
                        name: "maxResults",
                        type: .integer,
                        description: "Maximum number of results to return (default: 5)",
                    ),
                ],
                required: ["query"],
            ),
        )
    }

    public func execute(_ arguments: RealtimeToolArguments) async -> String {
        guard let query = arguments["query"]?.stringValue else {
            return "Error: Query is required"
        }

        let maxResults = arguments["maxResults"]?.integerValue ?? 5

        // In a real implementation, this would call a search API
        // For now, return mock results
        return """
        Search results for "\(query)" (showing \(maxResults) results):

        1. Example Result Title
           Brief description of the search result...
           https://example.com/result1

        2. Another Result
           More information about the topic...
           https://example.com/result2

        3. Third Result
           Additional relevant information...
           https://example.com/result3
        """
    }

    public init() {}
}

// MARK: - Translation Tool

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public struct TranslationTool: RealtimeExecutableTool {
    public var metadata: RealtimeToolExecutor.ToolMetadata {
        RealtimeToolExecutor.ToolMetadata(
            name: "translate",
            description: "Translate text between languages",
            category: .utility,
            parameters: AgentToolParameters(
                properties: [
                    "text": AgentToolParameterProperty(
                        name: "text",
                        type: .string,
                        description: "Text to translate",
                    ),
                    "sourceLanguage": AgentToolParameterProperty(
                        name: "sourceLanguage",
                        type: .string,
                        description: "Source language code (e.g., 'en', 'es', 'fr'). Auto-detect if not specified.",
                    ),
                    "targetLanguage": AgentToolParameterProperty(
                        name: "targetLanguage",
                        type: .string,
                        description: "Target language code (e.g., 'en', 'es', 'fr')",
                    ),
                ],
                required: ["text", "targetLanguage"],
            ),
        )
    }

    public func execute(_ arguments: RealtimeToolArguments) async -> String {
        guard
            let text = arguments["text"]?.stringValue,
            let targetLang = arguments["targetLanguage"]?.stringValue else
        {
            return "Error: Text and target language are required"
        }

        let sourceLang = arguments["sourceLanguage"]?.stringValue ?? "auto"

        // In a real implementation, this would call a translation API
        // For now, return a mock translation
        let mockTranslation = switch targetLang {
        case "es":
            "[Spanish translation of: \(text)]"
        case "fr":
            "[French translation of: \(text)]"
        case "de":
            "[German translation of: \(text)]"
        case "ja":
            "[Japanese translation of: \(text)]"
        default:
            "[\(targetLang.uppercased()) translation of: \(text)]"
        }

        return """
        Translation (\(sourceLang) → \(targetLang)):
        Original: \(text)
        Translated: \(mockTranslation)
        """
    }

    public init() {}
}

// MARK: - Tool Registry

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class RealtimeToolRegistry: Sendable {
    private let executor: RealtimeToolExecutor

    public init() {
        self.executor = RealtimeToolExecutor()
    }

    /// Register all built-in tools
    public func registerBuiltInTools() async {
        // Register all built-in tools
        for tool in BuiltInTools.all() {
            await self.executor.register(tool)
        }
    }

    /// Register a custom tool
    public func register(_ tool: some RealtimeExecutableTool) async {
        // Register a custom tool
        await self.executor.register(tool)
    }

    /// Execute a tool
    public func execute(
        toolName: String,
        arguments: String,
    ) async
        -> String
    {
        // Execute a tool
        await self.executor.executeSimple(
            toolName: toolName,
            arguments: arguments,
        )
    }

    /// Get available tools as RealtimeTools for the API
    public func getRealtimeTools() async -> [RealtimeTool] {
        // Get available tools as RealtimeTools for the API
        let metadata = await executor.availableTools()
        return metadata.map { meta in
            RealtimeTool(
                name: meta.name,
                description: meta.description,
                parameters: meta.parameters,
            )
        }
    }

    /// Get execution history
    public func getHistory(limit: Int? = nil) async -> [RealtimeToolExecutor.ToolExecution] {
        // Get execution history
        await self.executor.getHistory(limit: limit)
    }
}
