import Foundation
import KCDeepLCore
import XCTest
@testable import KCDeepL

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testLaunchSynchronizationRegistersRequestedApp() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: PreferenceKeys.launchAtLogin)
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(defaults: defaults, service: service)

        controller.synchronizeOnLaunch()

        XCTAssertTrue(controller.isRequested)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertEqual(service.registerCallCount, 1)
    }

    func testToggleOnRegistersAndPersistsPreference() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(defaults: defaults, service: service)

        controller.setEnabled(true)

        XCTAssertTrue(defaults.bool(forKey: PreferenceKeys.launchAtLogin))
        XCTAssertTrue(controller.isRequested)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertEqual(service.registerCallCount, 1)
    }

    func testToggleOffUnregistersAndPersistsPreference() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: PreferenceKeys.launchAtLogin)
        let service = FakeLaunchAtLoginService(status: .enabled)
        let controller = LaunchAtLoginController(defaults: defaults, service: service)

        controller.setEnabled(false)

        XCTAssertFalse(defaults.bool(forKey: PreferenceKeys.launchAtLogin))
        XCTAssertFalse(controller.isRequested)
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertEqual(service.unregisterCallCount, 1)
    }

    func testRegistrationFailureRevertsUserToggle() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeLaunchAtLoginService(
            status: .notRegistered,
            registerError: TestError.registrationFailed
        )
        let controller = LaunchAtLoginController(defaults: defaults, service: service)

        controller.setEnabled(true)

        XCTAssertFalse(defaults.bool(forKey: PreferenceKeys.launchAtLogin))
        XCTAssertFalse(controller.isRequested)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testApprovalStateKeepsRequestedPreferenceAndOpensSystemSettings() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: PreferenceKeys.launchAtLogin)
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(defaults: defaults, service: service)

        controller.synchronizeOnLaunch()
        controller.openSystemSettings()

        XCTAssertTrue(controller.isRequested)
        XCTAssertTrue(controller.requiresApproval)
        XCTAssertEqual(service.openSettingsCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 0)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "LaunchAtLoginControllerTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }
}

private enum TestError: Error {
    case registrationFailed
}

private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    private(set) var status: LaunchAtLoginStatus
    private let registerError: Error?
    private let unregisterError: Error?

    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openSettingsCallCount = 0

    init(
        status: LaunchAtLoginStatus,
        registerError: Error? = nil,
        unregisterError: Error? = nil
    ) {
        self.status = status
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    func register() throws {
        registerCallCount += 1
        if let registerError {
            throw registerError
        }
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError {
            throw unregisterError
        }
        status = .notRegistered
    }

    func openSystemSettings() {
        openSettingsCallCount += 1
    }
}
