import Foundation

// MARK: - Amazon Bedrock Converse

/// Translates the app's Chat Completions-shaped messages to Bedrock's Converse API, which serves every Bedrock chat
/// model. Transport, signing, and streaming stay in LLMClient.swift.
nonisolated extension LLMClient {
    static func isConverseRequest(_ request: URLRequest) -> Bool {
        guard let url = request.url, let host = url.host else { return false }
        return AmazonBedrock.isRuntimeHost(host) && url.path.hasPrefix("/model/")
    }

    /// The AWS profile to sign with, when the config targets Bedrock with a profile credential.
    static func bedrockProfile(for config: Config) -> String? {
        guard AmazonBedrock.isConverseEndpoint(baseURL: config.baseURL) else { return nil }
        return BedrockCredential(storedValue: config.apiKey).profileName
    }

    func buildConverseRequest(_ config: Config, baseURL: String) throws -> URLRequest {
        var root = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") {
            root.removeLast()
        }
        let model = config.model.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentCharacters) ?? config.model
        let endpoint = "\(root)/model/\(model)/\(config.streaming ? "converse-stream" : "converse")"
        guard let url = URL(string: endpoint) else { throw LLMError.invalidURL }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: self.buildConverseBody(config)) else {
            throw LLMError.encodingError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // An AWS profile is signed with SigV4 in `prepareRequest` instead.
        if case let .apiKey(key) = BedrockCredential(storedValue: config.apiKey), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = jsonData

        DebugLogger.shared.debug(
            "LLMClient: Converse request ready url=\(endpoint) messages=\(config.messages.count) "
                + "model=\(config.model) streaming=\(config.streaming) bodyBytes=\(jsonData.count)",
            source: "LLMClient"
        )
        return request
    }

    /// Model IDs can contain `:` and ARNs `/`, so encode everything outside the unreserved set.
    private static let pathSegmentCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    // MARK: - Request Body

    func buildConverseBody(_ config: Config) -> [String: Any] {
        let converted = Self.converseMessages(from: config.messages)
        var body: [String: Any] = ["messages": converted.messages]
        if !converted.system.isEmpty {
            body["system"] = [["text": converted.system]]
        }

        // Without maxTokens each model uses its own default, which stays within its limit.
        var inference: [String: Any] = [:]
        if let maxTokens = config.maxTokens {
            inference["maxTokens"] = maxTokens
        }
        if let temperature = config.temperature {
            inference["temperature"] = temperature
        }
        if !inference.isEmpty {
            body["inferenceConfig"] = inference
        }

        let tools = Self.converseTools(from: config.tools)
        if !tools.isEmpty {
            body["toolConfig"] = ["tools": tools]
        }

        if !config.extraParameters.isEmpty {
            body["additionalModelRequestFields"] = config.extraParameters
        }
        return body
    }

    /// Bedrock hands `additionalModelRequestFields` to the model unchanged, so the app's `reasoning_effort` setting
    /// moves into the effort field the model publishes, at a level it takes. Models that publish none get it as-is
    /// (gpt-oss takes `reasoning_effort` directly).
    static func converseExtraParameters(for config: Config) async -> [String: Any] {
        guard let effort = config.extraParameters["reasoning_effort"] as? String,
              let region = AmazonBedrock.region(fromBaseURL: config.baseURL),
              let field = await BedrockModelCatalog.effortField(
                  model: config.model, region: region, credential: BedrockCredential(storedValue: config.apiKey)
              )
        else { return config.extraParameters }

        var parameters = config.extraParameters
        parameters["reasoning_effort"] = nil
        field.set(field.level(for: effort), in: &parameters)
        return parameters
    }

    /// Splits out system prompts and converts tool calls and results to content blocks. A tool call
    /// without a result (a cancelled command) gets an error result: Converse rejects an unanswered `toolUse`.
    static func converseMessages(from chatMessages: [[String: Any]]) -> (system: String, messages: [[String: Any]]) {
        var systemParts: [String] = []
        var messages: [[String: Any]] = []
        var unansweredToolUseIDs: [String] = []

        // Converse requires alternating roles, so consecutive turns from one role are merged.
        func append(_ role: String, _ blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if let last = messages.last, last["role"] as? String == role, let content = last["content"] as? [[String: Any]] {
                messages[messages.count - 1]["content"] = content + blocks
            } else {
                messages.append(["role": role, "content": blocks])
            }
        }

        func toolResult(_ id: String, _ text: String, isError: Bool = false) -> [String: Any] {
            var result: [String: Any] = ["toolUseId": id, "content": [["text": text]]]
            if isError {
                result["status"] = "error"
            }
            return ["toolResult": result]
        }

        func closeUnansweredToolUses() {
            guard !unansweredToolUseIDs.isEmpty else { return }
            append("user", unansweredToolUseIDs.map { toolResult($0, "The tool call was not run.", isError: true) })
            unansweredToolUseIDs = []
        }

        for message in chatMessages {
            let role = message["role"] as? String ?? "user"
            let text = message["content"] as? String ?? ""

            switch role {
            case "system":
                if !text.isEmpty {
                    systemParts.append(text)
                }
            case "assistant":
                closeUnansweredToolUses()
                var blocks: [[String: Any]] = []
                if !text.isEmpty {
                    blocks.append(["text": text])
                }
                for toolCall in message["tool_calls"] as? [[String: Any]] ?? [] {
                    guard let function = toolCall["function"] as? [String: Any],
                          let name = function["name"] as? String
                    else { continue }
                    let id = toolCall["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))"
                    let input = (function["arguments"] as? String)
                        .flatMap { $0.data(using: .utf8) }
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                    blocks.append(["toolUse": ["toolUseId": id, "name": name, "input": input]])
                    unansweredToolUseIDs.append(id)
                }
                append("assistant", blocks)
            case "tool":
                let id = message["tool_call_id"] as? String ?? ""
                if let index = unansweredToolUseIDs.firstIndex(of: id) {
                    unansweredToolUseIDs.remove(at: index)
                    append("user", [toolResult(id, text)])
                } else {
                    closeUnansweredToolUses()
                    if !text.isEmpty {
                        append("user", [["text": "Tool result:\n\(text)"]])
                    }
                }
            default:
                closeUnansweredToolUses()
                if !text.isEmpty {
                    append("user", [["text": text]])
                }
            }
        }
        closeUnansweredToolUses()

        return (systemParts.joined(separator: "\n\n"), messages)
    }

    static func converseTools(from chatTools: [[String: Any]]) -> [[String: Any]] {
        chatTools.compactMap { tool in
            guard tool["type"] as? String == "function",
                  let function = tool["function"] as? [String: Any],
                  let name = function["name"] as? String
            else { return nil }
            var spec: [String: Any] = [
                "name": name,
                "inputSchema": ["json": function["parameters"] as? [String: Any] ?? ["type": "object", "properties": [String: Any]()]],
            ]
            if let description = function["description"] as? String {
                spec["description"] = description
            }
            return ["toolSpec": spec]
        }
    }

    // MARK: - Response

    func parseConverseResponse(_ json: [String: Any]) throws -> Response {
        guard let output = json["output"] as? [String: Any],
              let message = output["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { throw LLMError.invalidResponse }

        var textParts: [String] = []
        var thinkingParts: [String] = []
        var toolCalls: [ToolCall] = []
        for block in content {
            if let text = block["text"] as? String {
                textParts.append(text)
            } else if let reasoning = (block["reasoningContent"] as? [String: Any])?["reasoningText"] as? [String: Any],
                      let text = reasoning["text"] as? String, !text.isEmpty
            {
                thinkingParts.append(text)
            } else if let toolUse = block["toolUse"] as? [String: Any], let name = toolUse["name"] as? String {
                toolCalls.append(ToolCall(
                    id: toolUse["toolUseId"] as? String ?? "call_\(UUID().uuidString.prefix(8))",
                    name: name,
                    arguments: toolUse["input"] as? [String: Any] ?? [:]
                ))
            }
        }

        let rawContent = textParts.joined()
        let (tagThinking, cleanedContent) = self.stripThinkingTags(rawContent)
        let thinking = (thinkingParts + [tagThinking]).filter { !$0.isEmpty }.joined(separator: "\n")
        var response = Response(
            thinking: thinking.isEmpty ? nil : thinking,
            content: cleanedContent.isEmpty ? rawContent.trimmingCharacters(in: .whitespacesAndNewlines) : cleanedContent,
            toolCalls: toolCalls
        )
        response.isIncomplete = Self.isIncompleteConverseStopReason(json["stopReason"] as? String)
        return response
    }

    static func isIncompleteConverseStopReason(_ reason: String?) -> Bool {
        [
            "max_tokens", "content_filtered", "guardrail_intervened", "malformed_model_output",
            "malformed_tool_use", "model_context_window_exceeded",
        ].contains(reason ?? "")
    }
}
