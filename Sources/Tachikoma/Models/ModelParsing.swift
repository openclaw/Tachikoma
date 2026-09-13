import Foundation

// MARK: - Convenience Properties

@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
extension LanguageModel {
    /// GPT-OSS-120B via Ollama (default quantization)
    public static let gptOSS120B = LanguageModel.ollama(.gptOSS120B)

    /// GPT-OSS-120B via LMStudio (default quantization)
    public static let gptOSS120B_LMStudio = LanguageModel.lmstudio(.gptOSS120B)

    /// Parse a loose model string (as entered by users or configuration files) into a strongly typed model.
    public static func parse(from modelString: String) -> LanguageModel? {
        // Parse a loose model string (as entered by users or configuration files) into a strongly typed model.
        let trimmed = modelString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let qualified = ProviderParser.parse(trimmed)

        if
            let qualified,
            qualified.provider.lowercased() == "ollama"
        {
            return .ollama(Self.parseOllamaModelIdentifier(qualified.model))
        }

        if
            let qualified,
            ["lmstudio", "lm-studio"].contains(qualified.provider.lowercased())
        {
            return .lmstudio(Self.parseLMStudioModelIdentifier(qualified.model))
        }

        if
            let qualified,
            qualified.provider.lowercased() == "minimax"
        {
            return Self.parseMiniMaxModelIdentifier(qualified.model).map(LanguageModel.minimax)
        }

        if
            let qualified,
            ["minimax-cn", "minimax_cn", "minimaxi"].contains(qualified.provider.lowercased())
        {
            return Self.parseMiniMaxModelIdentifier(qualified.model).map(LanguageModel.minimaxCN)
        }

        if
            let qualified,
            ["kimi", "moonshot"].contains(qualified.provider.lowercased())
        {
            return Self.parseKimiModelIdentifier(qualified.model).map(LanguageModel.kimi)
        }

        if let qualified {
            let provider = qualified.provider.lowercased()
            if provider == "openai" {
                guard
                    let parsed = Self.parse(from: qualified.model),
                    case .openai = parsed else { return nil }

                return parsed
            }
            if provider == "openrouter" {
                return .openRouter(modelId: qualified.model)
            }
            if !["openai", "anthropic", "google", "gemini", "grok", "xai"].contains(provider) {
                return .openRouter(modelId: trimmed)
            }
            return Self.parseKnownProviderQualified(qualified)
        }

        let modelIdentifier = if
            let qualified,
            ["openai", "anthropic", "google", "gemini", "grok", "xai"]
                .contains(qualified.provider.lowercased())
        {
            qualified.model
        } else {
            trimmed
        }

        let normalized = modelIdentifier.lowercased()
        let dashed = normalized.replacingOccurrences(of: "_", with: "-")
        let compact = dashed.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "")
        let dotted = dashed.replacingOccurrences(of: ".", with: "-")

        // MARK: OpenAI models

        if
            compact.contains("gpt4") || compact.contains("gpt3") || compact.contains("o3") || compact.contains("o4") ||
            compact.contains("gpt51") || compact.contains("gpt52") ||
            compact.contains("gpt5thinking")
        {
            return nil
        }

        if dashed == "chat-latest" || compact == "chatlatest" {
            return .openai(.chatLatest)
        }

        if dashed == "gpt-5-chat-latest" || compact == "gpt5chatlatest" {
            return .openai(.gpt5ChatLatest)
        }

        switch compact {
        case "gpt56", "gpt56sol":
            return .openai(.gpt56Sol)
        case "gpt56terra":
            return .openai(.gpt56Terra)
        case "gpt56luna":
            return .openai(.gpt56Luna)
        default:
            break
        }
        if compact.contains("gpt56") {
            return nil
        }

        if dashed == "gpt-5-pro" || compact == "gpt5pro" {
            return .openai(.gpt5Pro)
        }

        if dotted.contains("gpt-5-5") || compact.contains("gpt55") {
            // GPT-5.5 currently has no mini/nano variants; map those suffixes to GPT-5 mini/nano.
            if dotted.contains("nano") || compact.contains("nano") {
                return .openai(.gpt5Nano)
            }
            if dotted.contains("mini") || compact.contains("mini") {
                return .openai(.gpt5Mini)
            }
            return .openai(.gpt55)
        }

        if dotted.contains("gpt-5-4") || compact.contains("gpt54") {
            if dotted.contains("nano") || compact.contains("nano") {
                return .openai(.gpt54Nano)
            }
            if dotted.contains("mini") || compact.contains("mini") {
                return .openai(.gpt54Mini)
            }
            return .openai(.gpt54)
        }

        if dashed == "gpt-5-nano" || compact == "gpt5nano" {
            return .openai(.gpt5Nano)
        }

        if dashed == "gpt-5-mini" || compact == "gpt5mini" {
            return .openai(.gpt5Mini)
        }

        if dashed == "gpt-5" || compact == "gpt5" {
            return .openai(.gpt5)
        }

        // MARK: Anthropic models

        func matchesExactAlias(_ aliases: Set<String>, compactAliases: Set<String> = []) -> Bool {
            aliases.contains(normalized) ||
                aliases.contains(dashed) ||
                aliases.contains(dotted) ||
                compactAliases.contains(compact)
        }

        if dotted.contains("claude-3") || compact.contains("claude3") {
            return nil
        }

        if
            normalized == "claude-opus-4-20250514" ||
            normalized == "claude-sonnet-4-20250514" ||
            normalized.contains("-thinking")
        {
            return nil
        }

        if
            matchesExactAlias(
                [
                    "claude-fable-5",
                    "fable-5",
                    "fable.5",
                    "fable5",
                    "fable",
                ],
                compactAliases: ["claudefable5", "fable5"],
            )
        {
            return .anthropic(.fable5)
        }

        if
            matchesExactAlias(
                [
                    "claude-sonnet-5",
                    "sonnet-5",
                    "sonnet.5",
                    "sonnet5",
                ],
                compactAliases: ["claudesonnet5", "sonnet5"],
            )
        {
            return .anthropic(.sonnet5)
        }

        if
            matchesExactAlias(
                [
                    "claude-opus-5",
                    "claude-opus5",
                    "claude-opus-5-latest",
                    "opus-5",
                    "opus.5",
                    "opus5",
                ],
                compactAliases: ["claudeopus5", "opus5"],
            )
        {
            return .anthropic(.opus5)
        }

        if
            matchesExactAlias(
                [
                    "claude-opus-4-8",
                    "claude-opus-4.8",
                    "opus-4-8",
                    "opus-4.8",
                    "opus48",
                ],
                compactAliases: ["claudeopus48", "opus48"],
            )
        {
            return .anthropic(.opus48)
        }

        if
            dotted.contains("claude-opus-4-7") ||
            dotted.contains("claude-opus-4.7") ||
            compact.contains("claudeopus47") ||
            dotted.contains("opus-4-7") ||
            dotted.contains("opus-4.7") ||
            compact.contains("opus47")
        {
            return .anthropic(.opus47)
        }

        if
            dotted.contains("claude-opus-4-5") ||
            dotted.contains("claude-opus-4.5") ||
            compact.contains("claudeopus45") ||
            dotted.contains("opus-4-5") ||
            dotted.contains("opus-4.5") ||
            compact.contains("opus45")
        {
            return .anthropic(.opus45)
        }

        if
            dotted.contains("claude-opus-4-1-20250805") ||
            dotted.contains("claude-opus-4") ||
            compact.contains("claudeopus4") ||
            dotted.contains("opus-4")
        {
            return .anthropic(.opus4)
        }

        if
            dotted.contains("claude-sonnet-4-6") ||
            compact.contains("claudesonnet46") ||
            dotted.contains("sonnet-4-6")
        {
            return .anthropic(.sonnet46)
        }

        if
            dotted.contains("claude-sonnet-4-5-20250929") ||
            dotted.contains("claude-sonnet-4.5") ||
            compact.contains("claudesonnet45") ||
            dotted.contains("sonnet-4-5")
        {
            return .anthropic(.sonnet45)
        }

        if dotted.contains("claude-sonnet-4") || compact.contains("claudesonnet4") {
            return .anthropic(.sonnet46)
        }

        if
            normalized.contains("claude-haiku-4.5") ||
            dotted.contains("claude-haiku-4-5") ||
            compact.contains("claudehaiku45")
        {
            return .anthropic(.haiku45)
        }

        let genericClaudeIdentifiers: Set = [
            "anthropic",
            "claude",
            "claude-opus",
            "claudelatest",
            "claude-latest",
            "claude_latest",
            "claude-default",
            "claude_default",
            "opus",
        ]

        let canonicalForms = [normalized, dashed, compact]
        if canonicalForms.contains(where: { genericClaudeIdentifiers.contains($0) }) {
            return .anthropic(.opus5)
        }

        // MARK: Google models

        if
            dashed.contains("gemini-3.5-flash") || dotted.contains("gemini-3-5-flash") || compact
                .contains("gemini35flash")
        {
            return .google(.gemini35Flash)
        }

        if
            dashed.contains("gemini-3.1-pro") || dotted.contains("gemini-3-1-pro") || compact
                .contains("gemini31pro")
        {
            return .google(.gemini31ProPreview)
        }

        if
            dashed.contains("gemini-3.1-flash-lite") || dotted.contains("gemini-3-1-flash-lite") || compact
                .contains("gemini31flashlite")
        {
            return .google(.gemini31FlashLite)
        }

        if dashed.contains("gemini-3-flash") || compact.contains("gemini3flash") {
            return .google(.gemini3Flash)
        }

        if dashed.contains("gemini-2.5-pro") || dotted.contains("gemini-2-5-pro") || compact.contains("gemini25pro") {
            return .google(.gemini25Pro)
        }

        if
            dashed.contains("gemini-2.5-flash-lite") || dotted.contains("gemini-2-5-flash-lite") || compact
                .contains("gemini25flashlite")
        {
            return .google(.gemini25FlashLite)
        }

        if
            dashed.contains("gemini-2.5-flash") || dotted.contains("gemini-2-5-flash") || compact
                .contains("gemini25flash")
        {
            return .google(.gemini25Flash)
        }

        let genericGeminiIdentifiers: Set = [
            "gemini",
            "geminiflash",
            "gemini-flash",
            "gemini_flash",
            "google",
        ]

        if canonicalForms.contains(where: { genericGeminiIdentifiers.contains($0) }) {
            return .google(.gemini35Flash)
        }

        // MARK: MiniMax models

        if
            dashed.contains("minimax-cn-m3") ||
            dotted.contains("minimax-cn-m-3") ||
            compact.contains("minimaxcnm3") ||
            compact.contains("minimaxim3")
        {
            return .minimaxCN(.m3)
        }

        if
            dashed.contains("minimax-cn-m2.7-highspeed") ||
            dotted.contains("minimax-cn-m2-7-highspeed") ||
            compact.contains("minimaxcnm27highspeed") ||
            compact.contains("minimaxim27highspeed")
        {
            return .minimaxCN(.m27Highspeed)
        }

        if
            dashed == "minimax-cn" ||
            dashed == "minimaxi" ||
            dashed.contains("minimax-cn-m2.7") ||
            dotted.contains("minimax-cn-m2-7") ||
            compact.contains("minimaxcnm27") ||
            compact.contains("minimaxim27")
        {
            return .minimaxCN(.m27)
        }

        if
            dashed.contains("minimax-m2.7-highspeed") ||
            dotted.contains("minimax-m2-7-highspeed") ||
            compact.contains("minimaxm27highspeed") ||
            dashed == "m2.7-highspeed" ||
            dotted == "m2-7-highspeed"
        {
            return .minimax(.m27Highspeed)
        }

        if
            dashed.contains("minimax-m2.7") ||
            dotted.contains("minimax-m2-7") ||
            compact.contains("minimaxm27") ||
            dashed == "m2.7" ||
            dotted == "m2-7" ||
            normalized == "minimax"
        {
            return .minimax(.m27)
        }

        if
            dashed.contains("minimax-m3") ||
            dotted.contains("minimax-m-3") ||
            compact.contains("minimaxm3") ||
            dashed == "m3" ||
            dotted == "m-3"
        {
            return .minimax(.m3)
        }

        // MARK: Kimi (Moonshot) models

        if
            dashed.contains("kimi-k2.7-code-highspeed") ||
            dotted.contains("kimi-k2-7-code-highspeed") ||
            compact.contains("kimik27codehighspeed")
        {
            return .kimi(.k27CodeHighspeed)
        }

        if
            dashed.contains("kimi-k2.7-code") ||
            dotted.contains("kimi-k2-7-code") ||
            compact.contains("kimik27code") ||
            dashed == "k2.7-code" ||
            dotted == "k2-7-code"
        {
            return .kimi(.k27Code)
        }

        if
            dashed.contains("kimi-k2.6") ||
            dotted.contains("kimi-k2-6") ||
            compact.contains("kimik26") ||
            dashed == "k2.6" ||
            dotted == "k2-6" ||
            normalized == "kimi" ||
            normalized == "moonshot"
        {
            return .kimi(.k26)
        }

        // MARK: Grok models

        let unsupportedGrok = normalized.contains("grok-4.20-multi-agent") ||
            dotted.contains("grok-4-20-multi-agent") ||
            compact.contains("grok420multiagent")
        if unsupportedGrok {
            return nil
        }

        if dotted.contains("grok-4-20-0309-reasoning") || compact.contains("grok4200309reasoning") {
            return .grok(.grok420Reasoning)
        }

        if dotted.contains("grok-4-20-0309-non-reasoning") || compact.contains("grok4200309nonreasoning") {
            return .grok(.grok420NonReasoning)
        }

        if
            dotted.contains("grok-4-3") ||
            normalized.contains("grok-4.3") ||
            compact.contains("grok43") ||
            normalized == "grok-4-latest" ||
            normalized == "grok-4" ||
            normalized == "grok-latest"
        {
            return .grok(.grok43)
        }

        if normalized.hasPrefix("grok-") {
            return .grok(.custom(modelIdentifier))
        }

        if compact.contains("grok") {
            return .grok(.grok43)
        }

        // MARK: Ollama models

        if normalized == "ollama" {
            return .ollama(.llama33)
        }

        if normalized == "lmstudio" || normalized == "lm-studio" {
            return .lmstudio(.gptOSS120B)
        }

        if compact.contains("gptoss") {
            if compact.contains("20b") {
                return .ollama(.gptOSS20B)
            }
            return .ollama(.gptOSS120B)
        }

        if compact.contains("qwen25vl") {
            return .ollama(Self.parseOllamaModelIdentifier(trimmed))
        }

        if normalized == "qwen2.5" || normalized == "qwen2.5:latest" || compact == "qwen25" {
            return .ollama(.qwen25)
        }

        if compact.contains("llama4") {
            return .ollama(.llama4)
        }

        if compact.contains("llama2") {
            return nil
        }

        if compact.contains("llama33") || dashed.contains("llama3.3") {
            return .ollama(.llama33)
        }

        if compact.contains("llama32") || dashed.contains("llama3.2") {
            return .ollama(.llama32)
        }

        if compact.contains("llama31") || dashed.contains("llama3.1") {
            return .ollama(.llama31)
        }

        if compact.contains("llama") {
            return .ollama(.llama33)
        }

        // MARK: Generic fallbacks

        if compact.contains("gpt") {
            return .openai(.gpt55)
        }

        return nil
    }

    private static func parseKnownProviderQualified(_ qualified: ProviderParser.ProviderConfig) -> LanguageModel? {
        let provider = qualified.provider.lowercased()
        let model = qualified.model
        let normalized = model.lowercased()

        func unqualifiedModel(matchingProvider expectedProvider: (LanguageModel) -> Bool) -> LanguageModel? {
            guard let parsed = Self.parse(from: model), expectedProvider(parsed) else { return nil }
            return parsed
        }

        switch provider {
        case "openai":
            guard !Self.looksAnthropic(normalized), !Self.looksGoogle(normalized), !Self.looksGrok(normalized) else {
                return nil
            }
            return unqualifiedModel {
                if case .openai = $0 {
                    true
                } else {
                    false
                }
            }
                ??
                (Self.looksOpenAI(normalized) && !Self
                    .isUnsupportedOpenAI(normalized) ? .openai(.custom(model)) : nil)
        case "anthropic":
            guard !Self.looksOpenAI(normalized), !Self.looksGoogle(normalized), !Self.looksGrok(normalized) else {
                return nil
            }
            return unqualifiedModel {
                if case .anthropic = $0 {
                    true
                } else {
                    false
                }
            }
                ??
                (Self.looksAnthropic(normalized) && !Self
                    .isUnsupportedAnthropic(normalized) ? .anthropic(.custom(model)) : nil)
        case "google", "gemini":
            guard !Self.looksOpenAI(normalized), !Self.looksAnthropic(normalized), !Self.looksGrok(normalized) else {
                return nil
            }
            return unqualifiedModel {
                if case .google = $0 {
                    true
                } else {
                    false
                }
            }
        case "grok", "xai":
            guard !Self.looksOpenAI(normalized), !Self.looksAnthropic(normalized), !Self.looksGoogle(normalized) else {
                return nil
            }
            return unqualifiedModel {
                if case .grok = $0 {
                    true
                } else {
                    false
                }
            }
                ?? (Self.looksGrok(normalized) && !Self.isUnsupportedGrok(normalized) ? .grok(.custom(model)) : nil)
        default:
            return nil
        }
    }

    private static func looksOpenAI(_ normalized: String) -> Bool {
        normalized.contains("gpt") || normalized.hasPrefix("o3") || normalized.hasPrefix("o4") || normalized == "openai"
    }

    private static func looksAnthropic(_ normalized: String) -> Bool {
        normalized.contains("claude") || normalized.contains("fable") || normalized.contains("opus") ||
            normalized.contains("sonnet") || normalized.contains("haiku") || normalized == "anthropic"
    }

    private static func looksGoogle(_ normalized: String) -> Bool {
        normalized.contains("gemini") || normalized == "google"
    }

    private static func looksGrok(_ normalized: String) -> Bool {
        normalized.contains("grok") || normalized == "xai"
    }

    private static func isUnsupportedOpenAI(_ normalized: String) -> Bool {
        let compact = normalized.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "")
        return compact.contains("gpt4") || compact.contains("gpt3") || compact.contains("o3") || compact
            .contains("o4") ||
            compact.contains("gpt51") || compact.contains("gpt52") ||
            compact.contains("gpt5thinking") || compact.contains("gpt5chat")
    }

    private static func isUnsupportedAnthropic(_ normalized: String) -> Bool {
        let compact = normalized.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "")
        return normalized.hasPrefix("claude-3") || compact.hasPrefix("claude3") ||
            normalized == "claude-opus-4-20250514" ||
            normalized == "claude-sonnet-4-20250514" ||
            normalized.contains("-thinking")
    }

    private static func isUnsupportedGrok(_ normalized: String) -> Bool {
        normalized.contains("grok-4.20-multi-agent") ||
            normalized.contains("grok-4-20-multi-agent") ||
            normalized.contains("grok420multiagent")
    }

    private static func parseOllamaModelIdentifier(_ modelString: String) -> Ollama {
        let trimmed = modelString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()

        switch normalized {
        case "gpt-oss:120b", "gpt-oss-120b":
            return .gptOSS120B
        case "gpt-oss:20b", "gpt-oss-20b":
            return .gptOSS20B
        case "llama3.3", "llama3.3:latest":
            return .llama33
        case "llama3.2", "llama3.2:latest":
            return .llama32
        case "llama3.1", "llama3.1:latest":
            return .llama31
        case "llava", "llava:latest":
            return .llava
        case "bakllava", "bakllava:latest":
            return .bakllava
        case "llama3.2-vision:11b":
            return .llama32Vision11b
        case "llama3.2-vision:90b":
            return .llama32Vision90b
        case "qwen2.5vl:7b":
            return .qwen25vl7b
        case "qwen2.5vl:32b":
            return .qwen25vl32b
        case "qwen2.5", "qwen2.5:latest":
            return .qwen25
        default:
            return .custom(trimmed)
        }
    }

    private static func parseLMStudioModelIdentifier(_ modelString: String) -> LMStudio {
        let trimmed = modelString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()

        switch normalized {
        case "openai/gpt-oss-120b", "gpt-oss-120b", "gpt-oss:120b":
            return .gptOSS120B
        case "openai/gpt-oss-20b", "gpt-oss-20b", "gpt-oss:20b":
            return .gptOSS20B
        case "meta/llama-3.3-70b", "llama-3.3-70b", "llama3.3-70b":
            return .llama3370B
        default:
            return .custom(trimmed)
        }
    }

    private static func parseMiniMaxModelIdentifier(_ modelString: String) -> MiniMax? {
        let normalized = modelString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch normalized {
        case "minimax-m2.7", "minimax-m2-7", "m2.7", "m2-7":
            return .m27
        case "minimax-m2.7-highspeed", "minimax-m2-7-highspeed", "m2.7-highspeed", "m2-7-highspeed":
            return .m27Highspeed
        case "minimax-m3", "m3":
            return .m3
        default:
            return nil
        }
    }

    private static func parseKimiModelIdentifier(_ modelString: String) -> Kimi? {
        let normalized = modelString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch normalized {
        case "kimi-k2.6", "kimi-k2-6", "k2.6", "k2-6":
            return .k26
        case "kimi-k2.7-code", "kimi-k2-7-code", "k2.7-code", "k2-7-code":
            return .k27Code
        case "kimi-k2.7-code-highspeed", "kimi-k2-7-code-highspeed", "k2.7-code-highspeed", "k2-7-code-highspeed":
            return .k27CodeHighspeed
        default:
            return nil
        }
    }
}
