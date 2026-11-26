import Combine
import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class AppUpdater {
    private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations = Set<AnyCancellable>()
    private(set) var canCheck = false
    private(set) var automaticallyChecks = false
    private(set) var automaticallyInstalls = false

    var isAvailable: Bool { controller != nil }

    init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            controller = nil
            return
        }

        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheck = $0 }
            .store(in: &observations)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] in self?.automaticallyChecks = $0 }
            .store(in: &observations)
        updater.publisher(for: \.automaticallyDownloadsUpdates).sink { [weak self] in self?.automaticallyInstalls = $0 }
            .store(in: &observations)
        controller.startUpdater()
    }

    func check() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticInstallation(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }
}
