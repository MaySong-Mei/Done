//
//  AFMProvider.swift
//  Done
//

import Foundation
import FoundationModels

struct AFMProvider: LLMProvider {
    var model: String = "apple-on-device"

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw AFMUnavailableError(reason: reason)
        @unknown default:
            throw AFMUnavailableError(reason: nil)
        }

        let prompt = request.messages
            .filter { $0.role == .user }
            .map(\.content)
            .joined(separator: "\n\n")

        let session: LanguageModelSession
        if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
            session = LanguageModelSession(instructions: systemPrompt)
        } else {
            session = LanguageModelSession()
        }

        let response = try await session.respond(to: prompt)
        return LLMResponse(content: response.content, toolCalls: [])
    }
}

enum AFMUnavailableError: Error, LocalizedError {
    case deviceUnsupported
    case intelligenceNotEnabled
    case modelNotReady
    case unknown

    init(reason: SystemLanguageModel.Availability.UnavailableReason?) {
        switch reason {
        case .deviceNotEligible:
            self = .deviceUnsupported
        case .appleIntelligenceNotEnabled:
            self = .intelligenceNotEnabled
        case .modelNotReady:
            self = .modelNotReady
        default:
            self = .unknown
        }
    }

    var errorDescription: String? {
        switch self {
        case .deviceUnsupported:
            return L(.afmErrorDeviceUnsupported)
        case .intelligenceNotEnabled:
            return L(.afmErrorIntelligenceDisabled)
        case .modelNotReady:
            return L(.afmErrorModelNotReady)
        case .unknown:
            return L(.afmErrorDeviceUnsupported)
        }
    }
}
