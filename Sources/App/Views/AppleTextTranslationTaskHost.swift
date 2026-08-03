import SwiftUI
import Translation

@available(macOS 15.0, *)
struct AppleTextTranslationTaskHost: View {
    @ObservedObject var viewModel: TranslationViewModel
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .onAppear {
                configureForPendingRequest()
            }
            .onChange(of: viewModel.appleRequestGeneration) { _, _ in
                configureForPendingRequest()
            }
            .translationTask(configuration) { session in
                await viewModel.performPendingAppleTranslation(using: session)
                if !Task.isCancelled {
                    configuration = nil
                }
            }
    }

    private func configureForPendingRequest() {
        guard let pending = viewModel.pendingAppleTranslation else {
            configuration = nil
            return
        }

        let requestedConfiguration: TranslationSession.Configuration
        do {
            requestedConfiguration = try AppleDocumentTranslationClient.configuration(
                sourceLanguage: pending.sourceLanguage,
                targetLanguage: pending.targetLanguage
            )
        } catch {
            configuration = nil
            viewModel.reportAppleTranslationFailure(
                error,
                generation: pending.generation
            )
            return
        }

        if configuration == requestedConfiguration {
            configuration?.invalidate()
        } else {
            configuration = requestedConfiguration
        }
    }
}

struct AppleTextTranslationUnavailableHost: View {
    @ObservedObject var viewModel: TranslationViewModel

    var body: some View {
        Color.clear
            .onAppear {
                reportIfNeeded()
            }
            .onChange(of: viewModel.appleRequestGeneration) { _, _ in
                reportIfNeeded()
            }
    }

    private func reportIfNeeded() {
        guard let pending = viewModel.pendingAppleTranslation else {
            return
        }
        viewModel.markAppleTranslationUnavailable(for: pending.generation)
    }
}
