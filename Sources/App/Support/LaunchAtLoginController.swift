import Combine
import Foundation
import KCDeepLCore
import os
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginStatus { get }

    func register() throws
    func unregister() throws
    func openSystemSettings()
}

final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    static let shared = LaunchAtLoginController()

    @Published private(set) var isRequested: Bool
    @Published private(set) var status: LaunchAtLoginStatus
    @Published private(set) var errorMessage: String?

    var requiresApproval: Bool {
        status == .requiresApproval
    }

    var statusMessage: String? {
        switch status {
        case .enabled:
            "로그인 시 자동 실행이 등록되어 있습니다."
        case .requiresApproval:
            "macOS 승인이 필요합니다. 로그인 항목 설정에서 KC DeepL을 허용해 주세요."
        case .notRegistered:
            isRequested ? "자동 실행을 등록하지 못했습니다." : nil
        case .notFound:
            "현재 앱 번들을 로그인 항목으로 찾지 못했습니다."
        }
    }

    private let defaults: UserDefaults
    private let service: LaunchAtLoginServicing
    private let logger = Logger(subsystem: "com.h0tshin.KCDeepL", category: "LaunchAtLogin")

    init(
        defaults: UserDefaults = .standard,
        service: LaunchAtLoginServicing = SystemLaunchAtLoginService()
    ) {
        self.defaults = defaults
        self.service = service
        self.isRequested = defaults.bool(forKey: PreferenceKeys.launchAtLogin)
        self.status = service.status
    }

    func synchronizeOnLaunch() {
        isRequested = defaults.bool(forKey: PreferenceKeys.launchAtLogin)
        apply(isRequested, revertPreferenceOnFailure: false)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isRequested || !matchesRequestedState else {
            refreshStatus()
            return
        }

        isRequested = enabled
        defaults.set(enabled, forKey: PreferenceKeys.launchAtLogin)
        apply(enabled, revertPreferenceOnFailure: true)
    }

    func refreshStatus() {
        status = service.status
        errorMessage = nil
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }

    private var matchesRequestedState: Bool {
        switch (isRequested, status) {
        case (true, .enabled), (true, .requiresApproval), (false, .notRegistered):
            true
        default:
            false
        }
    }

    private func apply(_ enabled: Bool, revertPreferenceOnFailure: Bool) {
        errorMessage = nil
        status = service.status

        do {
            if enabled {
                switch status {
                case .enabled, .requiresApproval:
                    break
                case .notRegistered, .notFound:
                    try service.register()
                }
            } else {
                switch status {
                case .enabled, .requiresApproval:
                    try service.unregister()
                case .notRegistered, .notFound:
                    break
                }
            }
            status = service.status
            logger.info("Launch-at-login state updated: requested=\(enabled), status=\(String(describing: self.status))")
        } catch {
            status = service.status

            if status == .requiresApproval {
                logger.notice("Launch-at-login requires user approval")
                return
            }

            let action = enabled ? "등록" : "해제"
            errorMessage = "자동 실행 \(action)에 실패했습니다: \(error.localizedDescription)"
            logger.error("Launch-at-login update failed: \(error.localizedDescription, privacy: .public)")

            if revertPreferenceOnFailure {
                isRequested.toggle()
                defaults.set(isRequested, forKey: PreferenceKeys.launchAtLogin)
            }
        }
    }
}
