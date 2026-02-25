//
//  LLMProvider.swift
//  Done
//

import Foundation

// MARK: - Types

struct LLMMessage {
    enum Role: String {
        case system
        case user
        case assistant
        case tool
    }

    var role: Role
    var content: String
    var toolCalls: [LLMToolCall]?
    var toolCallId: String?
}

struct LLMToolCall {
    var id: String
    var name: String
    var arguments: String // JSON string
}

struct LLMToolDefinition {
    var name: String
    var description: String
    var parameters: [String: Any] // JSON Schema
}

struct LLMRequest {
    var messages: [LLMMessage]
    var tools: [LLMToolDefinition]
    var systemPrompt: String?
}

struct LLMResponse {
    var content: String?
    var toolCalls: [LLMToolCall]
}

struct LLMVisionImage {
    var data: Data
    var mimeType: String

    init(data: Data, mimeType: String = "image/jpeg") {
        self.data = data
        self.mimeType = mimeType
    }
}

struct LLMVisionMessage {
    enum Role: String {
        case user
    }

    var role: Role
    var text: String
    var images: [LLMVisionImage]
}

struct LLMVisionRequest {
    var messages: [LLMVisionMessage]
    var systemPrompt: String?
}

// MARK: - Protocol

protocol LLMProvider {
    var supportsVision: Bool { get }
    func send(_ request: LLMRequest) async throws -> LLMResponse
    func sendVision(_ request: LLMVisionRequest) async throws -> LLMResponse
}

extension LLMProvider {
    var supportsVision: Bool { false }

    func sendVision(_ request: LLMVisionRequest) async throws -> LLMResponse {
        _ = request
        throw LLMError.visionUnsupported
    }
}

// MARK: - Claude Provider

struct ClaudeProvider: LLMProvider {
    var apiKey: String
    var model: String = "claude-sonnet-4-20250514"

    var supportsVision: Bool { true }

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
        ]

        if let systemPrompt = request.systemPrompt {
            body["system"] = systemPrompt
        }

        // Build messages
        var messages: [[String: Any]] = []
        for msg in request.messages {
            switch msg.role {
            case .user:
                messages.append(["role": "user", "content": msg.content])
            case .assistant:
                if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                    var contentBlocks: [[String: Any]] = []
                    if !msg.content.isEmpty {
                        contentBlocks.append(["type": "text", "text": msg.content])
                    }
                    for tc in toolCalls {
                        let inputData = tc.arguments.data(using: .utf8) ?? Data()
                        let input = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] ?? [:]
                        contentBlocks.append([
                            "type": "tool_use",
                            "id": tc.id,
                            "name": tc.name,
                            "input": input,
                        ])
                    }
                    messages.append(["role": "assistant", "content": contentBlocks])
                } else {
                    messages.append(["role": "assistant", "content": msg.content])
                }
            case .tool:
                messages.append([
                    "role": "user",
                    "content": [
                        [
                            "type": "tool_result",
                            "tool_use_id": msg.toolCallId ?? "",
                            "content": msg.content,
                        ] as [String: Any]
                    ],
                ])
            case .system:
                break
            }
        }
        body["messages"] = messages

        // Build tools
        if !request.tools.isEmpty {
            let tools: [[String: Any]] = request.tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.parameters,
                ]
            }
            body["tools"] = tools
        }

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]] else {
            throw LLMError.invalidResponse
        }

        var textContent = ""
        var toolCalls: [LLMToolCall] = []

        for block in contentArray {
            let type = block["type"] as? String ?? ""
            if type == "text" {
                textContent += block["text"] as? String ?? ""
            } else if type == "tool_use" {
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? ""
                let input = block["input"] ?? [:]
                let inputData = try JSONSerialization.data(withJSONObject: input)
                let arguments = String(data: inputData, encoding: .utf8) ?? "{}"
                toolCalls.append(LLMToolCall(id: id, name: name, arguments: arguments))
            }
        }

        return LLMResponse(content: textContent.isEmpty ? nil : textContent, toolCalls: toolCalls)
    }

    func sendVision(_ request: LLMVisionRequest) async throws -> LLMResponse {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
        ]
        if let systemPrompt = request.systemPrompt {
            body["system"] = systemPrompt
        }

        let messages: [[String: Any]] = request.messages.map { msg in
            var blocks: [[String: Any]] = []
            if !msg.text.isEmpty {
                blocks.append(["type": "text", "text": msg.text])
            }
            for image in msg.images {
                blocks.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": image.mimeType,
                        "data": image.data.base64EncodedString()
                    ]
                ])
            }
            return [
                "role": msg.role.rawValue,
                "content": blocks
            ]
        }
        body["messages"] = messages
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]] else {
            throw LLMError.invalidResponse
        }

        let text = contentArray
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return LLMResponse(content: text.isEmpty ? nil : text, toolCalls: [])
    }
}

// MARK: - OpenAI Provider

struct OpenAIProvider: LLMProvider {
    var apiKey: String
    var model: String = "gpt-4o"
    var baseURL: String = "https://api.openai.com/v1/chat/completions"

    var supportsVision: Bool { true }

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        let url = URL(string: baseURL)!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
        ]

        // Build messages
        var messages: [[String: Any]] = []

        if let systemPrompt = request.systemPrompt {
            messages.append(["role": "system", "content": systemPrompt])
        }

        for msg in request.messages {
            switch msg.role {
            case .system:
                messages.append(["role": "system", "content": msg.content])
            case .user:
                messages.append(["role": "user", "content": msg.content])
            case .assistant:
                if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                    var entry: [String: Any] = ["role": "assistant"]
                    if !msg.content.isEmpty {
                        entry["content"] = msg.content
                    }
                    let tcs: [[String: Any]] = toolCalls.map { tc in
                        [
                            "id": tc.id,
                            "type": "function",
                            "function": [
                                "name": tc.name,
                                "arguments": tc.arguments,
                            ] as [String: Any],
                        ]
                    }
                    entry["tool_calls"] = tcs
                    messages.append(entry)
                } else {
                    messages.append(["role": "assistant", "content": msg.content])
                }
            case .tool:
                messages.append([
                    "role": "tool",
                    "tool_call_id": msg.toolCallId ?? "",
                    "content": msg.content,
                ])
            }
        }
        body["messages"] = messages

        // Build tools
        if !request.tools.isEmpty {
            let tools: [[String: Any]] = request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters,
                    ] as [String: Any],
                ]
            }
            body["tools"] = tools
        }

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw LLMError.invalidResponse
        }

        let textContent = message["content"] as? String
        var toolCalls: [LLMToolCall] = []

        if let tcs = message["tool_calls"] as? [[String: Any]] {
            for tc in tcs {
                let id = tc["id"] as? String ?? ""
                let function = tc["function"] as? [String: Any] ?? [:]
                let name = function["name"] as? String ?? ""
                let arguments = function["arguments"] as? String ?? "{}"
                toolCalls.append(LLMToolCall(id: id, name: name, arguments: arguments))
            }
        }

        return LLMResponse(content: textContent, toolCalls: toolCalls)
    }

    func sendVision(_ request: LLMVisionRequest) async throws -> LLMResponse {
        let url = URL(string: baseURL)!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
        ]

        var messages: [[String: Any]] = []
        if let systemPrompt = request.systemPrompt {
            messages.append(["role": "system", "content": systemPrompt])
        }

        for message in request.messages {
            var contentBlocks: [[String: Any]] = []
            if !message.text.isEmpty {
                contentBlocks.append([
                    "type": "text",
                    "text": message.text
                ])
            }
            for image in message.images {
                let dataURL = "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
                contentBlocks.append([
                    "type": "image_url",
                    "image_url": [
                        "url": dataURL
                    ]
                ])
            }
            messages.append([
                "role": message.role.rawValue,
                "content": contentBlocks
            ])
        }

        body["messages"] = messages
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw LLMError.invalidResponse
        }

        let textContent = message["content"] as? String
        return LLMResponse(content: textContent, toolCalls: [])
    }
}

// MARK: - DeepSeek Provider (OpenAI-compatible)

struct DeepSeekProvider: LLMProvider {
    var apiKey: String
    var model: String = "deepseek-chat"

    private var openAI: OpenAIProvider {
        OpenAIProvider(
            apiKey: apiKey,
            model: model,
            baseURL: "https://api.deepseek.com/v1/chat/completions"
        )
    }

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        try await openAI.send(request)
    }
}

// MARK: - Error

enum LLMError: Error, LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case noAPIKey
    case visionUnsupported

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from LLM"
        case .apiError(let statusCode, let message):
            return "API error (\(statusCode)): \(message)"
        case .noAPIKey:
            return "No API key configured. Please set your API key in Agent settings."
        case .visionUnsupported:
            return "The selected provider does not support image analysis."
        }
    }
}
