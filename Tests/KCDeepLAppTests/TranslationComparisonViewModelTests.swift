import XCTest
@testable import KCDeepL
import KCDeepLCore

@MainActor
final class TranslationComparisonViewModelTests: XCTestCase {
    func testComparisonModelsMatchRequestedOrder() {
        XCTAssertEqual(
            CodexComparisonModel.allCases.map(\.modelID),
            [
                "gpt-5.6-sol",
                "gpt-5.6-terra",
                "gpt-5.6-luna",
                "gpt-5.5",
                "gpt-5.4",
                "gpt-5.4-mini",
                "gpt-5.3-codex-spark"
            ]
        )
    }

    func testComparisonRunsAllAvailableModelsSequentially() async throws {
        let service = ComparisonTestService()
        let viewModel = TranslationComparisonViewModel(
            client: service,
            modelProvider: service
        )
        var completedRecords: [CompletedComparisonTranslation] = []

        let task = try XCTUnwrap(
            viewModel.startComparison(
                sourceText: "Translate every detail.",
                sourceLanguage: .english,
                targetLanguage: .korean
            ) {
                completedRecords.append($0)
            }
        )
        await task.value

        let snapshot = await service.snapshot()
        let expectedModelIDs = CodexComparisonModel.allCases.map(\.modelID)
        XCTAssertEqual(snapshot.modelIDs, expectedModelIDs)
        XCTAssertEqual(snapshot.maximumConcurrentRequests, 1)
        XCTAssertEqual(completedRecords.map(\.modelID), expectedModelIDs)
        XCTAssertEqual(viewModel.completedCount, 7)
        XCTAssertEqual(viewModel.finishedCount, 7)
        XCTAssertFalse(viewModel.isRunning)

        for model in CodexComparisonModel.allCases {
            XCTAssertEqual(
                viewModel.states[model],
                .completed("result-\(model.modelID)")
            )
        }
    }

    func testComparisonContinuesAfterOneModelFails() async throws {
        let failedModelID = CodexComparisonModel.gpt54.modelID
        let service = ComparisonTestService(failingModelIDs: [failedModelID])
        let viewModel = TranslationComparisonViewModel(
            client: service,
            modelProvider: service
        )
        var completedRecords: [CompletedComparisonTranslation] = []

        let task = try XCTUnwrap(
            viewModel.startComparison(
                sourceText: "Keep going after a failure.",
                sourceLanguage: .english,
                targetLanguage: .korean
            ) {
                completedRecords.append($0)
            }
        )
        await task.value

        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.modelIDs, CodexComparisonModel.allCases.map(\.modelID))
        XCTAssertEqual(completedRecords.count, 6)
        XCTAssertEqual(viewModel.completedCount, 6)
        XCTAssertEqual(viewModel.finishedCount, 7)
        XCTAssertEqual(
            viewModel.states[.gpt54],
            .failed(TranslationClientError.emptyResponse.localizedDescription)
        )
        XCTAssertTrue(viewModel.statusMessage.contains("실패 1개"))
    }
}

private actor ComparisonTestService:
    TranslationClient,
    CodexAppServerModelProviding
{
    struct Snapshot: Sendable {
        let modelIDs: [String]
        let maximumConcurrentRequests: Int
    }

    private let failingModelIDs: Set<String>
    private var requestedModelIDs: [String] = []
    private var activeRequestCount = 0
    private var maximumConcurrentRequests = 0

    init(failingModelIDs: Set<String> = []) {
        self.failingModelIDs = failingModelIDs
    }

    func availableModels() async throws -> [CodexAppServerModel] {
        CodexComparisonModel.allCases.map { model in
            CodexAppServerModel(
                id: model.modelID,
                model: model.modelID,
                displayName: model.displayName,
                description: "",
                isDefault: model == .sol
            )
        }
    }

    func translate(_ request: TranslationRequest) async throws -> String {
        requestedModelIDs.append(request.modelID)
        activeRequestCount += 1
        maximumConcurrentRequests = max(
            maximumConcurrentRequests,
            activeRequestCount
        )
        defer {
            activeRequestCount -= 1
        }

        try await Task.sleep(for: .milliseconds(1))
        if failingModelIDs.contains(request.modelID) {
            throw TranslationClientError.emptyResponse
        }
        return "result-\(request.modelID)"
    }

    func snapshot() -> Snapshot {
        Snapshot(
            modelIDs: requestedModelIDs,
            maximumConcurrentRequests: maximumConcurrentRequests
        )
    }
}
