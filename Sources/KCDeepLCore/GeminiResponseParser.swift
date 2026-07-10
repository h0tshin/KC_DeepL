import Foundation

public enum GeminiResponseParser {
    public static func extractText(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(GeminiFlexibleResponse.self, from: data)

        if let blockReason = response.promptFeedback?.normalizedBlockReason {
            throw TranslationClientError.responseBlocked(blockReason)
        }

        for candidate in response.candidates ?? [] {
            guard let finishReason = candidate.normalizedFinishReason else {
                continue
            }

            switch finishReason {
            case "MAX_TOKENS":
                throw TranslationClientError.responseTruncated
            case "SAFETY", "RECITATION", "LANGUAGE", "BLOCKLIST", "PROHIBITED_CONTENT",
                 "SPII", "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT":
                throw TranslationClientError.responseBlocked(finishReason)
            default:
                break
            }
        }

        guard let text = response.extractedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            throw TranslationClientError.emptyResponse
        }
        return text
    }
}

private struct GeminiFlexibleResponse: Decodable {
    let outputText: String?
    let output: [OutputItem]?
    let candidates: [Candidate]?
    let promptFeedback: PromptFeedback?

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
        case candidates
        case promptFeedback
    }

    var extractedText: String? {
        if let outputText, !outputText.isEmpty {
            return outputText
        }

        if let outputText = output?
            .compactMap(\.text)
            .first(where: { !$0.isEmpty }) {
            return outputText
        }

        let interactionText = output?
            .flatMap { $0.content ?? [] }
            .compactMap(\.text)
            .joined(separator: "\n")

        if let interactionText, !interactionText.isEmpty {
            return interactionText
        }

        let candidateText = candidates?
            .flatMap { $0.content?.parts ?? [] }
            .compactMap(\.text)
            .joined(separator: "\n")

        return candidateText?.isEmpty == false ? candidateText : nil
    }
}

private struct OutputItem: Decodable {
    let text: String?
    let content: [GeminiTextPart]?
}

private struct Candidate: Decodable {
    let content: CandidateContent?
    let finishReason: String?

    var normalizedFinishReason: String? {
        finishReason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }
}

private struct CandidateContent: Decodable {
    let parts: [GeminiTextPart]?
}

private struct GeminiTextPart: Decodable {
    let text: String?
}

private struct PromptFeedback: Decodable {
    let blockReason: String?

    var normalizedBlockReason: String? {
        guard let reason = blockReason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
              !reason.isEmpty,
              reason != "BLOCK_REASON_UNSPECIFIED"
        else {
            return nil
        }
        return reason
    }
}
