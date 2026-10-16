import Foundation

private final class OfflineSession: URLProtocol {
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// Release acceptance: use the production downloader and the exact published URL
/// with an empty, disposable cache, then reopen with networking disabled.
@main enum AquariumPublicDownloadChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let manifest = try JSONDecoder().decode(AquariumPackManifest.self, from:
            Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        try manifest.validate()
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("WhileAIWorks-public-pack-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let store = AquariumResourceDownload(manifest: manifest, cacheRoot: cache, bundledReady: false)
        precondition(store.status == .missing)
        let deadline = Date().addingTimeInterval(600)
        var lastProgress = -1
        store.download()
        while !store.isReady && Date() < deadline {
            if case .failed(let error) = store.status { throw NSError(domain: "PublicAquariumCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            if case .downloading(let progress) = store.status {
                let milestone = Int(progress * 5)
                if milestone > lastProgress { print("Published aquarium: \(milestone * 20)%"); lastProgress = milestone }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(store.isReady, "public download timed out")
        precondition(AquariumPackInstaller.isInstalled(manifest, in: cache))
        precondition(AquariumResources.resolve(bundled: nil, manifest: manifest, cache: cache) != nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineSession.self]
        let offline = URLSession(configuration: configuration)
        defer { offline.invalidateAndCancel() }
        let reopened = AquariumResourceDownload(manifest: manifest, cacheRoot: cache, session: offline, bundledReady: false)
        precondition(reopened.isReady)
        reopened.download()
        try await Task.sleep(for: .milliseconds(200))
        precondition(OfflineSession.requests == 0, "cached pack must not need networking")
        print("AquariumPublicDownloadChecks: anonymous production URL, pinned archive hash, \(manifest.files.count) verified files, empty-cache installation and offline reopen passed")
    }
}
