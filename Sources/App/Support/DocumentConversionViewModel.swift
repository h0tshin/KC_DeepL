import Foundation
import KCDeepLCore

@MainActor
final class DocumentConversionViewModel: ObservableObject {
    @Published private(set) var selectedFormat: DocumentConversionFormat = .pptx
    @Published private(set) var options: DocumentConversionOptions
    @Published private(set) var stage: DocumentConversionStage = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusMessage = "PDF를 선택하면 파워포인트 또는 워드로 변환할 수 있습니다."
    @Published private(set) var errorMessage: String?
    @Published private(set) var warnings: [String] = []
    @Published private(set) var outputURL: URL?
    @Published private(set) var reportURL: URL?
    @Published private(set) var report: DocumentConversionReport?

    private let operationGate: FileWorkspaceOperationGate
    private let outputResolver: DocumentConversionOutputURLResolver
    private let reportStore: DocumentConversionReportStore
    private var operationTask: Task<Void, Never>?
    private var lease: FileWorkspaceOperationGate.Lease?
    private var operationGeneration: UInt = 0
    private var isPreparingToTerminate = false
    private let defaults: UserDefaults

    private static let optionsKey = "kcdeepl.documentConversion.options.v1"

    init(
        operationGate: FileWorkspaceOperationGate? = nil,
        outputResolver: DocumentConversionOutputURLResolver = DocumentConversionOutputURLResolver(),
        reportStore: DocumentConversionReportStore = DocumentConversionReportStore(),
        defaults: UserDefaults = .standard
    ) {
        self.operationGate = operationGate ?? .shared
        self.outputResolver = outputResolver
        self.reportStore = reportStore
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.optionsKey),
           let decoded = try? JSONDecoder().decode(
               DocumentConversionOptions.self,
               from: data
           ) {
            self.options = decoded
        } else {
            self.options = .default
        }
    }

    var isBusy: Bool { stage.isBusy }

    func selectFormat(_ format: DocumentConversionFormat) {
        guard !isBusy else { return }
        selectedFormat = format
    }

    func updatePresentationOptions(_ options: PresentationConversionOptions) {
        guard !isBusy else { return }
        self.options.presentation = options
        persistOptions()
    }

    func updateWordOptions(_ options: WordConversionOptions) {
        guard !isBusy else { return }
        self.options.word = options
        persistOptions()
    }

    func start(
        sourceURL: URL?,
        sourceGeneration: UInt,
        format: DocumentConversionFormat,
        downloadLocation: String,
        explicitlySelectedDestination: URL? = nil,
        conversionOptions: DocumentConversionOptions? = nil
    ) {
        guard !isPreparingToTerminate else {
            fail(with: FileWorkspaceOperationGateError.shuttingDown)
            return
        }
        guard let sourceURL else {
            fail(with: DocumentConversionError.sourceUnavailable)
            return
        }
        guard sourceURL.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame else {
            fail(with: DocumentConversionError.sourceNotPDF)
            return
        }

        cancelCurrentOperation(setCancelledStage: false)
        let lease: FileWorkspaceOperationGate.Lease
        do {
            lease = try operationGate.acquire(
                kind: .conversion,
                selectionGeneration: sourceGeneration
            )
        } catch {
            fail(with: error)
            return
        }
        self.lease = lease
        selectedFormat = format
        let selectedOptions = conversionOptions ?? options
        operationGeneration &+= 1
        let generation = operationGeneration
        errorMessage = nil
        warnings = []
        outputURL = nil
        reportURL = nil
        report = nil
        progress = 0.05
        stage = .preparing
        statusMessage = "PDF 장면과 이미지·텍스트 구조를 분석하는 중입니다."

        let destination: URL
        do {
            destination = try outputResolver.resolve(
                sourceURL: sourceURL,
                format: format,
                locationRawValue: downloadLocation,
                explicitlySelectedURL: explicitlySelectedDestination
            )
            try validateDestinationDirectory(destination)
        } catch {
            operationGate.release(lease)
            self.lease = nil
            fail(with: error)
            return
        }

        let temporaryURL = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".kcdeepl-conversion-\(UUID().uuidString).\(format.fileExtension)"
            )
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        operationTask = Task { [weak self] in
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
                try? FileManager.default.removeItem(at: temporaryURL)
            }

            do {
                let service = PDFOfficeConversionService()
                let progressHandler: DocumentConversionProgressHandler = { [weak self] update in
                    Task { @MainActor [weak self] in
                        self?.applyProgress(
                            update,
                            generation: generation,
                            leaseID: lease.id
                        )
                    }
                }
                let worker = Task.detached(priority: .userInitiated) {
                    try service.convert(
                        sourceURL: sourceURL,
                        format: format,
                        destinationURL: temporaryURL,
                        options: selectedOptions,
                        progress: progressHandler
                    )
                }
                let conversionReport = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                guard let self,
                      self.operationGeneration == generation,
                      self.lease?.id == lease.id
                else { return }

                self.stage = .validating
                self.progress = max(self.progress, 0.92)
                self.statusMessage = "Office package 구조와 저장 결과를 검증하는 중입니다."
                guard FileManager.default.fileExists(atPath: temporaryURL.path) else {
                    throw DocumentConversionError.packageWriteFailed("임시 결과가 사라졌습니다.")
                }
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw DocumentConversionError.destinationAlreadyExists
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)

                self.report = conversionReport
                self.warnings = conversionReport.warnings
                do {
                    self.reportURL = try self.reportStore.save(conversionReport)
                } catch {
                    self.warnings.append("품질 보고서를 Application Support에 저장하지 못했습니다: \(error.localizedDescription)")
                }
                self.outputURL = destination
                self.progress = 1
                self.stage = .completed
                self.statusMessage = "\(format.shortName) 문서를 저장했습니다: \(destination.lastPathComponent)"
                self.operationGate.release(lease)
                self.lease = nil
                self.operationTask = nil
            } catch is CancellationError {
                guard let self,
                      self.operationGeneration == generation
                else { return }
                self.operationGate.release(lease)
                self.lease = nil
                self.stage = .cancelled
                self.statusMessage = "문서 변환을 취소했습니다."
                self.operationTask = nil
            } catch {
                guard let self,
                      self.operationGeneration == generation
                else { return }
                self.operationGate.release(lease)
                self.lease = nil
                self.fail(with: error)
                self.operationTask = nil
            }
        }
    }

    func cancelConversion() {
        cancelCurrentOperation(setCancelledStage: true)
    }

    func prepareForApplicationTermination() {
        isPreparingToTerminate = true
        operationGate.beginShutdown()
        cancelCurrentOperation(setCancelledStage: false)
    }

    func shutdownAndReapWorker() async {
        operationTask?.cancel()
        await operationTask?.value
        operationTask = nil
    }

    func clearOutput() {
        outputURL = nil
        reportURL = nil
        report = nil
        warnings = []
    }

    private func cancelCurrentOperation(setCancelledStage: Bool) {
        operationGeneration &+= 1
        operationTask?.cancel()
        operationTask = nil
        if let lease {
            operationGate.release(lease)
            self.lease = nil
        }
        if setCancelledStage, stage.isBusy {
            stage = .cancelled
            statusMessage = "문서 변환을 취소했습니다."
        }
    }

    private func validateDestinationDirectory(_ destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw DocumentConversionError.destinationUnavailable(directory.path)
        }
        let probe = directory.appendingPathComponent(
            ".kcdeepl-conversion-probe-\(UUID().uuidString)"
        )
        do {
            try Data().write(to: probe, options: .withoutOverwriting)
            try FileManager.default.removeItem(at: probe)
        } catch {
            try? FileManager.default.removeItem(at: probe)
            throw DocumentConversionError.destinationUnavailable(directory.path)
        }
    }

    private func fail(with error: Error) {
        errorMessage = error.localizedDescription
        stage = .failed
        progress = 0
        statusMessage = "문서 변환을 시작하지 못했습니다."
    }

    private func applyProgress(
        _ update: DocumentConversionProgress,
        generation: UInt,
        leaseID: UUID
    ) {
        guard operationGeneration == generation,
              lease?.id == leaseID,
              stage.isBusy
        else {
            return
        }
        progress = max(progress, update.fraction)
        statusMessage = update.message
        switch update.phase {
        case .preparing:
            stage = .preparing
        case .analyzing, .extracting, .writing:
            stage = .converting(
                page: update.completedUnits,
                total: max(1, update.totalUnits)
            )
        case .validating, .saving:
            stage = .validating
        }
    }

    private func persistOptions() {
        guard let data = try? JSONEncoder().encode(options) else {
            return
        }
        defaults.set(data, forKey: Self.optionsKey)
    }
}
