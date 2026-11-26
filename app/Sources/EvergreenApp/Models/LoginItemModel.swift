import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class LoginItemModel {
    private let service: SMAppService
    private let agentPlist: String?
    private(set) var status: SMAppService.Status = .notRegistered

    var isAvailable: Bool {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return false }
        guard let agentPlist else { return true }
        return FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents/\(agentPlist)").path)
    }

    var isRegistered: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }
    var isEnabled: Bool { status == .enabled }

    init(agentPlist: String? = nil) {
        self.agentPlist = agentPlist
        service = agentPlist.map { SMAppService.agent(plistName: $0) } ?? .mainApp
        refresh()
    }

    func refresh() {
        status = isAvailable ? service.status : .notRegistered
    }

    func setRegistered(_ enabled: Bool) throws {
        guard isAvailable else { return }
        refresh()
        guard enabled != isRegistered else { return }
        defer { refresh() }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            refresh()
            if enabled != isRegistered { throw error }
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
