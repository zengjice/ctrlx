import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public enum VoiceCorrectionProvider: String, CaseIterable, Identifiable, Sendable {
    case volcengineArk

    public var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .volcengineArk:
            "Volcengine Ark"
        }
    }

    /// Curated models shown by CtrlX. Keeping this list with the provider avoids
    /// a network fetch every time Settings opens and gives each future provider
    /// an explicit, bounded model menu.
    var recommendedModelIDs: [String] {
        switch self {
        case .volcengineArk:
            [
                "deepseek-v4-pro-ga-260813",
                "doubao-seed-2-0-lite-260215",
                "deepseek-v4-flash-260425",
                "deepseek-v4-pro-260425",
                "doubao-seed-2-0-code-preview-260215",
            ]
        }
    }

    fileprivate var baseURL: URL {
        switch self {
        case .volcengineArk:
            // Intentionally fixed. BYOK configuration never accepts a custom base URL.
            URL(string: "https://ark.cn-beijing.volces.com/api/v3")!
        }
    }
}

public struct VoiceCorrectionSelection: Equatable, Sendable {
    let provider: VoiceCorrectionProvider
    let modelID: String

    public init?(provider: VoiceCorrectionProvider, modelID: String) {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelID.isEmpty else { return nil }
        self.provider = provider
        self.modelID = trimmedModelID
    }
}

enum VoiceCorrectionCredentials {
    static func apiKeyAccount(for provider: VoiceCorrectionProvider) -> String {
        "voice-correction.api-key.\(provider.rawValue)"
    }
}

struct VoiceCorrectionProviderClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let transport: Transport

    init(session: URLSession = .shared) {
        self.transport = { request in
            try await session.data(for: request)
        }
    }

    init(transport: @escaping Transport) {
        self.transport = transport
    }

    func fetchModels(
        provider: VoiceCorrectionProvider,
        apiKey: String
    ) async throws -> [String] {
        var request = URLRequest(url: provider.baseURL.appending(path: "models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        authorize(&request, apiKey: apiKey)

        let data = try await send(request)
        let response = try JSONDecoder().decode(ModelListResponse.self, from: data)
        return Array(
            Set(
                response.data.compactMap { model in
                    let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    return id.isEmpty ? nil : id
                }
            )
        ).sorted()
    }

    func correct(
        recognition: VoiceRecognitionResult,
        terminalContext: String?,
        contextualTerms: [String],
        localeIdentifier: String,
        selection: VoiceCorrectionSelection,
        apiKey: String
    ) async throws -> String {
        guard
            let maximumResponseTokens = VoiceCorrectionBudget.providerResponseTokens(
                for: recognition.bestAvailableTranscript
            ) else { throw VoiceCorrectionProviderError.inputTooLong }
        var request = URLRequest(
            url: selection.provider.baseURL.appending(path: "responses")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        authorize(&request, apiKey: apiKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ResponsesRequest(
                model: selection.modelID,
                input: """
                Correction rules:
                \(VoiceTranscriptCorrectionPrompt.instructions(
                    localeIdentifier: localeIdentifier,
                    contextualTerms: contextualTerms
                ))

                Correction task:
                \(VoiceTranscriptCorrectionPrompt.make(
                    recognition: recognition,
                    terminalContext: terminalContext
                ))
                """,
                thinking: ResponsesThinking(type: "disabled"),
                maxOutputTokens: maximumResponseTokens,
                store: false
            )
        )

        let data = try await send(request)
        let response = try JSONDecoder().decode(ResponsesResponse.self, from: data)
        if let status = response.status, status != "completed" {
            throw VoiceCorrectionProviderError.incompleteResponse(reason: response.incompleteDetails?.reason ?? status)
        }
        if let details = response.incompleteDetails {
            throw VoiceCorrectionProviderError.incompleteResponse(reason: details.reason)
        }
        if
            let unfinished = response.output?.first(where: {
                $0.type == "message" && $0.status != nil && $0.status != "completed"
            }) {
            throw VoiceCorrectionProviderError.incompleteResponse(reason: unfinished.status)
        }
        let outputText = response.outputText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let outputText, !outputText.isEmpty {
            return outputText
        }

        let contentText = (response.output ?? [])
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contentText.isEmpty else {
            let outputShape = (response.output ?? []).map { output in
                let contentTypes = (output.content ?? []).map(\.type).joined(separator: ",")
                return contentTypes.isEmpty
                    ? output.type ?? "unknown"
                    : "\(output.type ?? "unknown")[\(contentTypes)]"
            }.joined(separator: ",")
            let reason = [
                response.status.map { "status=\($0)" },
                response.incompleteDetails?.reason.map { "reason=\($0)" },
                outputShape.isEmpty ? nil : "output=\(outputShape)",
            ].compactMap { $0 }.joined(separator: " ")
            throw VoiceCorrectionProviderError.missingOutputText(
                reason: reason.isEmpty ? nil : reason
            )
        }
        return contentText
    }

    private func authorize(_ request: inout URLRequest, apiKey: String) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceCorrectionProviderError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let providerError = try? JSONDecoder().decode(ProviderErrorResponse.self, from: data)
            throw VoiceCorrectionProviderError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: providerError?.error.message
            )
        }
        return data
    }
}

private struct ModelListResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

private struct ResponsesRequest: Encodable {
    let model: String
    let input: String
    let thinking: ResponsesThinking
    let maxOutputTokens: Int
    let store: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case thinking
        case maxOutputTokens = "max_output_tokens"
        case store
    }
}

private struct ResponsesThinking: Encodable {
    let type: String
}

private struct ResponsesResponse: Decodable {
    struct Output: Decodable {
        let type: String?
        let status: String?
        let content: [Content]?
    }

    struct Content: Decodable {
        let type: String
        let text: String?
    }

    struct IncompleteDetails: Decodable {
        let reason: String?
    }

    let outputText: String?
    let output: [Output]?
    let status: String?
    let incompleteDetails: IncompleteDetails?

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
        case status
        case incompleteDetails = "incomplete_details"
    }
}

private struct ProviderErrorResponse: Decodable {
    struct ProviderError: Decodable {
        let message: String
    }

    let error: ProviderError
}

enum VoiceCorrectionProviderError: LocalizedError, Equatable {
    case invalidResponse
    case inputTooLong
    case incompleteResponse(reason: String?)
    case missingOutputText(reason: String?)
    case requestFailed(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The model provider returned an invalid response."
        case .inputTooLong:
            "The transcript is too long to correct safely."
        case let .incompleteResponse(reason):
            "The model provider did not complete the correction (\(reason ?? "incomplete"))."
        case let .missingOutputText(reason):
            if let reason, !reason.isEmpty {
                "The model provider returned no corrected text (\(reason))."
            } else {
                "The model provider returned no corrected text."
            }
        case let .requestFailed(statusCode, message):
            if let message, !message.isEmpty {
                "Provider request failed (HTTP \(statusCode)): \(message)"
            } else {
                "Provider request failed (HTTP \(statusCode))."
            }
        }
    }
}
