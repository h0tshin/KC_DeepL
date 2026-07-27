import Foundation

@MainActor
final class CodexAppServerModelStore: ObservableObject {
    @Published private(set) var models: [CodexAppServerModel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let provider: any CodexAppServerModelProviding

    init(provider: any CodexAppServerModelProviding) {
        self.provider = provider
    }

    var defaultModel: CodexAppServerModel? {
        models.first(where: \.isDefault) ?? models.first
    }

    func refresh() async {
        guard !isLoading else {
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            models = try await provider.availableModels()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
