import Foundation
import CryptoKit

private final class LocalTestTrust: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.host == "localhost", let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.performDefaultHandling, nil) }
    }
}

@main enum AquariumResourceChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let cache = fixture.appendingPathComponent("cache")
        let base = URL(string: try String(contentsOf: fixture.appendingPathComponent("server-url")).trimmingCharacters(in: .whitespacesAndNewlines))!
        let original = try JSONDecoder().decode(AquariumPackManifest.self, from: Data(contentsOf: fixture.appendingPathComponent("manifest.json")))
        let archive = fixture.appendingPathComponent("pack.zip")
        let fm = FileManager.default
        func manifest(route: String = "success", hash: String? = nil, version: Int = 1, files: [AquariumPackManifest.File]? = nil) -> AquariumPackManifest {
            .init(schema: 1, version: version, url: base.appendingPathComponent(route), archiveBytes: original.archiveBytes,
                  sha256: hash ?? original.sha256, installedBytes: original.installedBytes, files: files ?? original.files)
        }
        func reject(_ work: () throws -> Void) {
            do { try work(); fatalError("invalid pack was accepted") } catch {}
        }
        let pack = manifest()
        precondition(AquariumResources.resolve(bundled: nil, manifest: pack, cache: cache) == nil)
        reject { try manifest(files: [.init(path: "../outside.png", bytes: original.installedBytes, sha256: original.files[0].sha256)]).validate() }
        reject { _ = try AquariumPackInstaller.install(archive, manifest: manifest(hash: String(repeating: "0", count: 64)), in: cache) }
        precondition(!fm.fileExists(atPath: cache.path), "rejected archive cannot create a cache")
        let folder = try AquariumPackInstaller.install(archive, manifest: pack, in: cache)
        precondition(AquariumPackInstaller.isInstalled(pack, in: cache))
        precondition(AquariumResources.resolve(bundled: nil, manifest: pack, cache: cache) == folder)
        precondition(!AquariumPackInstaller.isInstalled(manifest(version: 2), in: cache), "new versions require their own verified install")
        let receipt = folder.deletingLastPathComponent().appendingPathComponent(".verified")
        let originalDate = try receipt.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = try AquariumPackInstaller.install(archive, manifest: pack, in: cache)
        let reusedDate = try receipt.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        precondition(reusedDate == originalDate, "reuse must not replace a valid install")
        try fm.removeItem(at: folder.appendingPathComponent(original.files[0].path))
        precondition(!AquariumPackInstaller.isInstalled(pack, in: cache))
        _ = try AquariumPackInstaller.install(archive, manifest: pack, in: cache)
        precondition(AquariumPackInstaller.isInstalled(pack, in: cache), "an incomplete cache can be repaired")
        reject { _ = try AquariumPackInstaller.install(archive, manifest: manifest(files: [.init(path: "different.png", bytes: original.installedBytes, sha256: original.files[0].sha256)]), in: fixture.appendingPathComponent("wrong-files")) }
        let cancelled = Task.detached { withUnsafeCurrentTask { $0?.cancel() }; return try AquariumPackInstaller.install(archive, manifest: pack, in: fixture.appendingPathComponent("cancelled-install")) }
        do { _ = try await cancelled.value; fatalError("cancelled install succeeded") } catch is CancellationError {}
        print("Installer: pinned hash, path rejection, exact inventory, atomic repair, reuse, version isolation and cancellation passed")

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: LocalTestTrust(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func controller(_ route: String) -> AquariumResourceDownload {
            AquariumResourceDownload(manifest: manifest(route: route), cacheRoot: fixture.appendingPathComponent("download-" + route), session: session, bundledReady: false)
        }
        func wait(_ store: AquariumResourceDownload, until check: (AquariumResourceDownload.Status) -> Bool) async throws {
            let deadline = Date().addingTimeInterval(15)
            while !check(store.status) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            precondition(check(store.status), "timed out: \(store.status)")
        }
        func failed(_ status: AquariumResourceDownload.Status) -> Bool { if case .failed = status { return true }; return false }
        let download = controller("success")
        precondition(download.status == .missing)
        try await Task.sleep(for: .milliseconds(100))
        precondition(!fm.fileExists(atPath: fixture.appendingPathComponent("requests.log").path), "opening the feature must not start a download")
        download.download()
        try await wait(download) { $0 == .ready }
        let reopened = controller("success")
        precondition(reopened.isReady, "cached resources are immediately ready offline")
        let count = try String(contentsOf: fixture.appendingPathComponent("requests.log"))
        reopened.download()
        try await Task.sleep(for: .milliseconds(100))
        let afterReopen = try String(contentsOf: fixture.appendingPathComponent("requests.log"))
        precondition(afterReopen == count)
        print("HTTPS: downloaded and reused without another request")
        let retry = controller("flaky")
        retry.download(); try await wait(retry, until: failed)
        retry.download(); try await wait(retry) { $0 == .ready }
        for route in ["corrupt", "missing", "partial"] {
            print("HTTPS: checking \(route)")
            let store = controller(route); store.download(); try await wait(store, until: failed)
            precondition(!AquariumPackInstaller.isInstalled(manifest(route: route), in: fixture.appendingPathComponent("download-" + route)))
        }
        print("HTTPS: checking progress and cancel/retry")
        let slow = controller("slow"); slow.download()
        try await wait(slow) { if case .downloading(let fraction) = $0 { return fraction > 0 && fraction < 1 }; return false }
        slow.cancel(); precondition(slow.status == .missing)
        try await Task.sleep(for: .milliseconds(200))
        precondition(!AquariumPackInstaller.isInstalled(manifest(route: "slow"), in: fixture.appendingPathComponent("download-slow")))
        slow.download(); try await wait(slow) { $0 == .ready }
        let clean = try fm.contentsOfDirectory(atPath: fixture.path).filter { $0.hasPrefix("download-") }.allSatisfy { name in
            !(try fm.contentsOfDirectory(atPath: fixture.appendingPathComponent(name).path)).contains { $0.hasPrefix(".download-") || $0.hasPrefix(".install-") }
        }
        precondition(clean, "no partial archives or extraction directories after completion")
        print("HTTPS download: explicit consent, progress, cancellation and retry, offline reuse, HTTP errors, truncated response and checksum failure passed")

        if CommandLine.arguments.count > 3 {
            let realManifest = try JSONDecoder().decode(AquariumPackManifest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            let realCache = fixture.appendingPathComponent("full-pack")
            let real = try AquariumPackInstaller.install(URL(fileURLWithPath: CommandLine.arguments[3]), manifest: realManifest, in: realCache)
            precondition(AquariumResources.resolve(bundled: nil, manifest: realManifest, cache: realCache) == real)
            try real.path.write(to: fixture.appendingPathComponent("installed-assets-path"), atomically: true, encoding: .utf8)
            print("Full aquarium pack: \(realManifest.files.count) files installed and verified in an isolated cache")
        }
    }
}
