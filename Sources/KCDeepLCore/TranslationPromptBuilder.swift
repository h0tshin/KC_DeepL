import Foundation

public enum TranslationPromptBuilder {
    public static func prompt(for request: TranslationRequest) -> String {
        let sourceName = request.sourceLanguage == .autoDetect
            ? "the detected source language"
            : request.sourceLanguage.displayName

        return """
        You are a professional translation engine.
        Translate the user's text from \(sourceName) to \(request.targetLanguage.displayName).
        Preserve meaning, formatting, line breaks, lists, and domain-specific terms.
        If the source text is already in the target language, improve naturalness without changing meaning.
        Return only the translated text. Do not include explanations.

        Text:
        \(request.sourceText)
        """
    }
}
