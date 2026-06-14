//
//  MealVisionService.swift
//  Done
//
//  Sends a meal photo to the configured vision-capable LLM and parses back a
//  calorie estimate plus a short evaluation and suggestion. Reuses the same
//  provider abstraction (`LLMProvider.sendVision`) and per-app provider/API-key
//  settings as the agentic calendar intake. Display-only — the result is stored
//  on the note via `MealPhotoAnalysis`.
//

import Foundation

enum MealVisionError: LocalizedError {
    case noImages
    case noAPIKey
    /// The selected provider can't see images (e.g. DeepSeek).
    case visionUnsupported(provider: String)
    case emptyResponse
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .noImages:
            return L(.mealNoPhoto)
        case .noAPIKey:
            return L(.mealNoAPIKey)
        case .visionUnsupported(let provider):
            return String(format: L(.mealVisionUnsupported), provider)
        case .emptyResponse, .parseFailed:
            return L(.mealAnalysisFailed)
        }
    }
}

struct MealVisionService {
    private let assetStore = AgenticIntakeAssetStore()

    /// Analyze the food in the given photo(s). Throws `MealVisionError` for the
    /// recoverable cases (no key, provider can't see images, bad response) so
    /// the UI can surface a clear message.
    func analyze(imageRefs: [AgenticIntakeImageRef]) async throws -> MealPhotoAnalysis {
        guard !imageRefs.isEmpty else { throw MealVisionError.noImages }

        let providerType = UserDefaults.standard.string(forKey: AppSettingsKeys.agentProvider)
            ?? AppSettingsKeys.agentProviderDefault
        let apiKey = UserDefaults.standard.string(forKey: AppSettingsKeys.agentAPIKey) ?? ""
        guard !apiKey.isEmpty else { throw MealVisionError.noAPIKey }

        let provider: any LLMProvider
        let modelName: String
        switch providerType {
        case "openai":
            let p = OpenAIProvider(apiKey: apiKey)
            provider = p; modelName = p.model
        case "deepseek":
            let p = DeepSeekProvider(apiKey: apiKey)
            provider = p; modelName = p.model
        default:
            let p = ClaudeProvider(apiKey: apiKey)
            provider = p; modelName = p.model
        }

        guard provider.supportsVision else {
            throw MealVisionError.visionUnsupported(provider: providerType)
        }

        // Images are already downscaled JPEGs on disk (AgenticIntakeAssetStore).
        let images: [LLMVisionImage] = imageRefs.compactMap { ref in
            guard let data = try? Data(contentsOf: assetStore.absoluteURL(for: ref)) else { return nil }
            return LLMVisionImage(data: data, mimeType: "image/jpeg")
        }
        guard !images.isEmpty else { throw MealVisionError.noImages }

        let chinese = AppLanguage.current == .chinese
        let request = LLMVisionRequest(
            messages: [LLMVisionMessage(role: .user, text: Self.userPrompt(chinese: chinese), images: images)],
            systemPrompt: Self.systemPrompt(chinese: chinese)
        )
        let response = try await provider.sendVision(request)
        guard let content = response.content, !content.isEmpty else { throw MealVisionError.emptyResponse }
        guard let analysis = Self.parse(content, modelName: modelName) else { throw MealVisionError.parseFailed }
        return analysis
    }

    // MARK: - Prompt

    private static func systemPrompt(chinese: Bool) -> String {
        let lang = chinese ? "Reply in Simplified Chinese." : "Reply in English."
        return """
        You are a concise nutrition assistant. Look at the food in the photo(s) and \
        respond with ONLY a single JSON object — no markdown, no code fences, no prose — \
        of exactly this shape:
        {"calories": <integer estimated total kcal>, "items": [<short food names>], \
        "verdict": "<one short sentence judging how healthy/balanced the meal is>", \
        "suggestion": "<one short, actionable suggestion>"}
        Estimate calories for the whole meal shown. Keep verdict and suggestion to one \
        sentence each. \(lang)
        """
    }

    private static func userPrompt(chinese: Bool) -> String {
        chinese ? "请分析这份餐食的热量并给出评价与建议。" : "Analyze this meal's calories and give an evaluation and a suggestion."
    }

    // MARK: - Parsing

    /// Pull the first balanced-looking JSON object out of the model's text and
    /// decode the meal fields, tolerating int/double/string calorie encodings.
    static func parse(_ raw: String, modelName: String) -> MealPhotoAnalysis? {
        let json = extractJSONObject(raw)
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        let calories: Int
        switch obj["calories"] {
        case let i as Int: calories = i
        case let d as Double: calories = Int(d.rounded())
        case let s as String: calories = Int(s.filter(\.isNumber)) ?? 0
        default: calories = 0
        }

        let items = (obj["items"] as? [String]) ?? []
        let verdict = (obj["verdict"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let suggestion = (obj["suggestion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Reject an all-empty parse so the UI shows the failure path rather than
        // a blank card.
        guard calories > 0 || !verdict.isEmpty || !suggestion.isEmpty || !items.isEmpty else {
            return nil
        }
        return MealPhotoAnalysis(
            calories: calories,
            items: items,
            verdict: verdict,
            suggestion: suggestion,
            providerModel: modelName
        )
    }

    private static func extractJSONObject(_ raw: String) -> String {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
            return raw
        }
        return String(raw[start...end])
    }
}
