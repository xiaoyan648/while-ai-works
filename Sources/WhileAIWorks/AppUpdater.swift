import AppKit
import Combine
import Sparkle

/// Sparkle owns update preferences, scheduling, signature verification and installation.
/// AppState mirrors its observable values for our settings UI, without a second defaults store.
@MainActor
final class AppUpdater {
    let controller: SPUStandardUpdaterController
    private var subscriptions = Set<AnyCancellable>()

    init(state: AppState) {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main)
            .sink { [weak state] in state?.canCheckForUpdates = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main)
            .sink { [weak state] in state?.automaticallyChecksForUpdates = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main)
            .sink { [weak state] in state?.lastUpdateCheck = $0 }.store(in: &subscriptions)
        state.checkForUpdates = { [weak self] in
            guard let self, self.controller.updater.canCheckForUpdates else { return }
            self.controller.checkForUpdates(nil)
        }
        state.setAutomaticUpdateChecks = { [weak self] enabled in
            self?.controller.updater.automaticallyChecksForUpdates = enabled
        }
    }

    func start() { controller.startUpdater() }
}
