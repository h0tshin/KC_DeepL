import Foundation
import KCDeepLCore

enum FileWorkspaceOperationKind: String, Equatable, Sendable {
    case analysisOrTranslation
    case conversion
}

enum FileWorkspaceOperationGateError: LocalizedError, Equatable {
    case busy(FileWorkspaceOperationKind)
    case shuttingDown

    var errorDescription: String? {
        switch self {
        case let .busy(kind):
            switch kind {
            case .analysisOrTranslation:
                "파일 번역이 진행 중입니다. 번역이 끝난 뒤 문서 변환을 시작해 주세요."
            case .conversion:
                "문서 변환이 진행 중입니다. 변환이 끝난 뒤 파일 번역을 시작해 주세요."
            }
        case .shuttingDown:
            "앱이 종료되는 중이라 새 파일 작업을 시작할 수 없습니다."
        }
    }
}

/// Main-actor lease gate shared by file translation and document conversion.
/// SwiftUI `.disabled` is only a projection of this state; public start APIs
/// must acquire the lease as well so same-turn calls cannot race.
@MainActor
final class FileWorkspaceOperationGate: ObservableObject {
    static let shared = FileWorkspaceOperationGate()

    struct Lease: Equatable, Sendable {
        let id: UUID
        let kind: FileWorkspaceOperationKind
        let selectionGeneration: UInt
    }

    @Published private(set) var activeLease: Lease?
    private(set) var isShuttingDown = false

    var isBusy: Bool { activeLease != nil }

    func acquire(
        kind: FileWorkspaceOperationKind,
        selectionGeneration: UInt
    ) throws -> Lease {
        guard !isShuttingDown else {
            throw FileWorkspaceOperationGateError.shuttingDown
        }
        if let activeLease {
            throw FileWorkspaceOperationGateError.busy(activeLease.kind)
        }
        let lease = Lease(
            id: UUID(),
            kind: kind,
            selectionGeneration: selectionGeneration
        )
        activeLease = lease
        return lease
    }

    func release(_ lease: Lease?) {
        guard let lease,
              activeLease?.id == lease.id
        else {
            return
        }
        activeLease = nil
    }

    func beginShutdown() {
        isShuttingDown = true
    }

    func endShutdownForTesting() {
        isShuttingDown = false
    }
}

struct SelectedFileSnapshot: Equatable, Sendable {
    let url: URL
    let kind: SupportedFileDocumentKind
    let selectionGeneration: UInt
    let expectedByteCount: Int64?
    let resourceIdentifier: String?
    let displayFilename: String

    init(
        url: URL,
        kind: SupportedFileDocumentKind,
        selectionGeneration: UInt,
        expectedByteCount: Int64? = nil,
        resourceIdentifier: String? = nil
    ) {
        self.url = url.standardizedFileURL
        self.kind = kind
        self.selectionGeneration = selectionGeneration
        self.expectedByteCount = expectedByteCount
        self.resourceIdentifier = resourceIdentifier
        self.displayFilename = url.lastPathComponent
    }
}
