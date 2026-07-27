import Foundation
import XCTest
@testable import KCDeepL
import KCDeepLCore

final class CodexAppServerIntegrationTests: XCTestCase {
    func testInstalledAppServerListsModelsAndTranslates() async throws {
        guard ProcessInfo.processInfo.environment["KCDEEPL_RUN_CODEX_INTEGRATION"] == "1" else {
            throw XCTSkip("실제 Codex App Server 스모크 테스트는 명시적으로 실행할 때만 동작합니다.")
        }

        let suiteName = "KCDeepL.CodexIntegration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("통합 테스트용 UserDefaults를 만들 수 없습니다.")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KCDeepL-CodexIntegration-\(UUID().uuidString)")
        let client = CodexAppServerClient(
            threadIDStore: UserDefaultsCodexThreadIDStore(defaults: defaults),
            workingDirectory: workingDirectory,
            requestTimeout: 30,
            turnTimeout: 120
        )

        do {
            let models = try await client.availableModels()
            let model = try XCTUnwrap(
                models.first(where: \.isDefault) ?? models.first
            )
            let output = try await client.translate(
                TranslationRequest(
                    sourceText: "Hello, this is a translation smoke test.",
                    sourceLanguage: .english,
                    targetLanguage: .korean,
                    provider: .gemini,
                    modelID: model.model,
                    apiKey: ""
                )
            )

            XCTAssertFalse(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertNotEqual(output, "Hello, this is a translation smoke test.")
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }
}
