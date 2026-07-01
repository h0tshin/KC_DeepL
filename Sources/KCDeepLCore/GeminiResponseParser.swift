import Foundation

public enum GeminiResponseParser {
    public static func extractText(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(GeminiFlexibleResponse.self, from: data)
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

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
        case candidates
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
}

private struct CandidateContent: Decodable {
    let parts: [GeminiTextPart]
}

private struct GeminiTextPart: Decodable {
    let text: String?
}
