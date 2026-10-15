import AppKit
import Sparkle

/// Test-only user driver. It acts solely on a disposable app under .build, never /Applications.
/// The signed candidate is the actual release archive. Sparkle performs the download and install.
@main @MainActor
final class NativeUpdateChecks: NSObject, NSApplicationDelegate, SPUUserDriver, SPUUpdaterDelegate {
    private var updater: SPUUpdater!
    private var found = false
    private var install = false
    private var expectedError = false
    private var expectsInvalidFeed = false
    private var receipt: URL!

    static func main() {
        let application = NSApplication.shared
        let delegate = NativeUpdateChecks()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, Bundle.main.bundleURL.path.contains("/.build/") else { exit(2) }
        receipt = URL(fileURLWithPath: arguments[1])
        install = arguments[2] == "install"
        expectedError = arguments[3] != "success"
        expectsInvalidFeed = arguments[3] == "feed-error"
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do { try updater.start() } catch { finish("startup-error: \(error)", success: false); return }
        record("started")
        updater.checkForUpdates()
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { self.finish("timeout", success: false) }
    }

    private func record(_ value: String) {
        let line = Data((value + "\n").utf8)
        if !FileManager.default.fileExists(atPath: receipt.path) { FileManager.default.createFile(atPath: receipt.path, contents: nil) }
        if let file = try? FileHandle(forWritingTo: receipt) {
            _ = try? file.seekToEnd(); try? file.write(contentsOf: line); try? file.close()
        }
    }
    private func finish(_ value: String, success: Bool) { record(value); exit(success ? 0 : 1) }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        finish("unexpected-permission-request", success: false)
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { record("checking") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        found = true; record("found: \(appcastItem.versionString)")
        if expectsInvalidFeed { reply(.dismiss); finish("unexpected-valid-feed", success: false) }
        reply(install ? .install : .dismiss)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { finish("notes-error", success: false) }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement(); finish("no-update", success: !install && !expectedError)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        record("error: \((error as NSError).code)"); acknowledgement()
        finish("rejected", success: expectedError)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { record("downloading") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { record("extracting") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if expectedError { reply(.skip); finish("unexpected-valid-archive", success: false) }
        record("ready-to-install"); reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { record("installing") }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement(); finish("installed", success: !expectedError)
    }
    func dismissUpdateInstallation() {
        if found && !install && !expectedError { finish("dismissed", success: true) }
    }
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { true }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { record("will-relaunch") }
}
