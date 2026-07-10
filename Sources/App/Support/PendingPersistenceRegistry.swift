import Foundation

@MainActor
final class PendingPersistenceRegistry {
    static let shared = PendingPersistenceRegistry()

    private var preparations: [@MainActor () -> Void] = []
    private var flushers: [@MainActor () async -> Void] = []

    private init() {}

    func registerPreparation(_ preparation: @escaping @MainActor () -> Void) {
        preparations.append(preparation)
    }

    func register(_ flusher: @escaping @MainActor () async -> Void) {
        flushers.append(flusher)
    }

    func flushAll() async {
        preparations.forEach { $0() }
        for flusher in flushers {
            await flusher()
        }
    }
}
