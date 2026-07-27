import Foundation
import KCDeepLCore

enum CodexComparisonModel: String, CaseIterable, Identifiable, Sendable {
    case sol = "gpt-5.6-sol"
    case terra = "gpt-5.6-terra"
    case luna = "gpt-5.6-luna"
    case gpt55 = "gpt-5.5"
    case gpt54 = "gpt-5.4"
    case gpt54Mini = "gpt-5.4-mini"
    case gpt53 = "gpt-5.3-codex-spark"

    var id: String { rawValue }
    var modelID: String { rawValue }

    var tabTitle: String {
        switch self {
        case .sol:
            "SOL"
        case .terra:
            "Terra"
        case .luna:
            "Luna"
        case .gpt55:
            "5.5"
        case .gpt54:
            "5.4"
        case .gpt54Mini:
            "5.4 mini"
        case .gpt53:
            "5.3"
        }
    }

    var displayName: String {
        switch self {
        case .sol:
            "GPT-5.6 SOL"
        case .terra:
            "GPT-5.6 Terra"
        case .luna:
            "GPT-5.6 Luna"
        case .gpt55:
            "GPT-5.5"
        case .gpt54:
            "GPT-5.4"
        case .gpt54Mini:
            "GPT-5.4 mini"
        case .gpt53:
            "GPT-5.3 Codex Spark"
        }
    }
}

enum TranslationComparisonState: Equatable, Sendable {
    case idle
    case queued
    case translating
    case completed(String)
    case failed(String)
    case unavailable
    case cancelled

    var translatedText: String? {
        guard case let .completed(text) = self else {
            return nil
        }
        return text
    }

    var isFinished: Bool {
        switch self {
        case .completed, .failed, .unavailable, .cancelled:
            true
        case .idle, .queued, .translating:
            false
        }
    }
}

struct CompletedComparisonTranslation: Equatable, Sendable {
    let sourceText: String
    let translatedText: String
    let sourceLanguage: LanguageOption
    let targetLanguage: LanguageOption
    let modelID: String
}

@MainActor
final class TranslationComparisonViewModel: ObservableObject {
    typealias CompletionHandler = @MainActor (CompletedComparisonTranslation) -> Void

    @Published var selectedModel: CodexComparisonModel = .sol
    @Published private(set) var states: [CodexComparisonModel: TranslationComparisonState]
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "원문을 입력한 뒤 번역 비교를 실행해 주세요."

    private let client: any TranslationClient
    private let modelProvider: any CodexAppServerModelProviding
    private var comparisonTask: Task<Void, Never>?
    private var runGeneration: UInt = 0

    init(
        client: any TranslationClient,
        modelProvider: any CodexAppServerModelProviding
    ) {
        self.client = client
        self.modelProvider = modelProvider
        states = Dictionary(
            uniqueKeysWithValues: CodexComparisonModel.allCases.map { ($0, .idle) }
        )
    }

    deinit {
        comparisonTask?.cancel()
    }

    var completedCount: Int {
        states.values.reduce(into: 0) { count, state in
            if case .completed = state {
                count += 1
            }
        }
    }

    var finishedCount: Int {
        states.values.filter(\.isFinished).count
    }

    var selectedState: TranslationComparisonState {
        states[selectedModel] ?? .idle
    }

    @discardableResult
    func startComparison(
        sourceText: String,
        sourceLanguage: LanguageOption,
        targetLanguage: LanguageOption,
        onCompleted: @escaping CompletionHandler
    ) -> Task<Void, Never>? {
        let trimmedText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            resetForInputChange()
            statusMessage = "번역 비교할 원문을 입력해 주세요."
            return nil
        }

        comparisonTask?.cancel()
        runGeneration &+= 1
        let generation = runGeneration
        isRunning = true
        statusMessage = "사용 가능한 Codex 모델을 확인하는 중입니다."
        states = Dictionary(
            uniqueKeysWithValues: CodexComparisonModel.allCases.map { ($0, .queued) }
        )

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let availableModelIDs: Set<String>
            do {
                availableModelIDs = Set(
                    try await self.modelProvider.availableModels().map(\.model)
                )
            } catch is CancellationError {
                self.finishCancelledRun(generation: generation)
                return
            } catch {
                guard self.isCurrentRun(generation) else {
                    return
                }
                let message = Self.errorMessage(from: error)
                for model in CodexComparisonModel.allCases {
                    self.states[model] = .failed(message)
                }
                self.finishRun(
                    generation: generation,
                    message: "Codex 모델 목록을 불러오지 못했습니다."
                )
                return
            }

            guard self.isCurrentRun(generation), !Task.isCancelled else {
                return
            }

            for model in CodexComparisonModel.allCases
                where !availableModelIDs.contains(model.modelID) {
                self.states[model] = .unavailable
            }

            let runnableModels = CodexComparisonModel.allCases.filter {
                availableModelIDs.contains($0.modelID)
            }
            guard !runnableModels.isEmpty else {
                self.finishRun(
                    generation: generation,
                    message: "비교 대상 Codex 모델을 현재 App Server에서 사용할 수 없습니다."
                )
                return
            }

            for model in runnableModels {
                guard self.isCurrentRun(generation), !Task.isCancelled else {
                    self.finishCancelledRun(generation: generation)
                    return
                }

                self.states[model] = .translating
                self.statusMessage = "\(model.displayName) 번역 중 · \(self.finishedCount)/\(CodexComparisonModel.allCases.count)"

                let request = TranslationRequest(
                    sourceText: sourceText,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    provider: .chatGPT,
                    modelID: model.modelID,
                    apiKey: "",
                    temperature: 0.2
                )

                do {
                    let output = try await self.client.translate(request)
                    guard self.isCurrentRun(generation), !Task.isCancelled else {
                        return
                    }
                    self.states[model] = .completed(output)
                    onCompleted(
                        CompletedComparisonTranslation(
                            sourceText: sourceText,
                            translatedText: output,
                            sourceLanguage: sourceLanguage,
                            targetLanguage: targetLanguage,
                            modelID: model.modelID
                        )
                    )
                } catch is CancellationError {
                    self.finishCancelledRun(generation: generation)
                    return
                } catch {
                    guard self.isCurrentRun(generation) else {
                        return
                    }
                    self.states[model] = .failed(Self.errorMessage(from: error))
                }
            }

            guard self.isCurrentRun(generation) else {
                return
            }
            let failedCount = runnableModels.count - self.completedCount
            let unavailableCount = CodexComparisonModel.allCases.count - runnableModels.count
            let message = failedCount == 0 && unavailableCount == 0
                ? "7개 Codex 모델의 번역 비교가 완료되었습니다."
                : "번역 비교 완료 · 성공 \(self.completedCount)개 · 실패 \(failedCount)개 · 사용 불가 \(unavailableCount)개"
            self.finishRun(generation: generation, message: message)
        }

        comparisonTask = task
        return task
    }

    func cancelComparison() {
        guard isRunning || comparisonTask != nil else {
            return
        }

        comparisonTask?.cancel()
        comparisonTask = nil
        runGeneration &+= 1
        isRunning = false
        states = states.mapValues { state in
            switch state {
            case .queued, .translating:
                .cancelled
            default:
                state
            }
        }
        statusMessage = "번역 비교를 중단했습니다."
    }

    func resetForInputChange() {
        comparisonTask?.cancel()
        comparisonTask = nil
        runGeneration &+= 1
        isRunning = false
        states = Dictionary(
            uniqueKeysWithValues: CodexComparisonModel.allCases.map { ($0, .idle) }
        )
        statusMessage = "원문을 입력한 뒤 번역 비교를 실행해 주세요."
    }

    private func finishCancelledRun(generation: UInt) {
        guard isCurrentRun(generation) else {
            return
        }
        comparisonTask = nil
        isRunning = false
        states = states.mapValues { state in
            switch state {
            case .queued, .translating:
                .cancelled
            default:
                state
            }
        }
        statusMessage = "번역 비교를 중단했습니다."
    }

    private func finishRun(generation: UInt, message: String) {
        guard isCurrentRun(generation) else {
            return
        }
        comparisonTask = nil
        isRunning = false
        statusMessage = message
    }

    private func isCurrentRun(_ generation: UInt) -> Bool {
        generation == runGeneration
    }

    private static func errorMessage(from error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
