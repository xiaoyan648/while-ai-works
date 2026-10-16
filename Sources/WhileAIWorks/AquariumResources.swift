import Foundation
import Combine
import CryptoKit

struct AquariumPackManifest: Codable {
    struct File: Codable {
        let path: String
        let bytes: Int64
        let sha256: String
    }
    let schema: Int
    let version: Int
    let url: URL
    let archiveBytes: Int64
    let sha256: String
    let installedBytes: Int64
    let files: [File]
    var directoryName: String { "aquarium-v\(version)-\(sha256)" }

    func validate() throws {
        func hash(_ value: String) -> Bool {
            value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
        }
        guard schema == 1, version > 0, hash(sha256), archiveBytes > 0,
              installedBytes > 0, installedBytes < 2_000_000_000,
              !files.isEmpty, files.count < 10_000,
              Set(files.map(\.path)).count == files.count else { throw AquariumPackError.invalidManifest }
        var total: Int64 = 0
        for file in files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !file.path.contains("\\"), !file.path.contains("\0"),
                  ["png", "json", "meshbin"].contains(URL(fileURLWithPath: file.path).pathExtension),
                  file.bytes > 0, file.bytes <= installedBytes, hash(file.sha256),
                  total <= installedBytes - file.bytes else { throw AquariumPackError.invalidManifest }
            total += file.bytes
        }
        guard total == installedBytes else { throw AquariumPackError.invalidManifest }
    }
}

enum AquariumPackError: LocalizedError {
    case invalidManifest, checksum, incomplete, unavailable, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidManifest: return "鱼缸资源信息不可用，请更新应用后重试。"
        case .checksum: return "资源包校验失败，请重新下载。"
        case .incomplete: return "鱼缸资源不完整，请重新下载。"
        case .unavailable: return "鱼缸资源暂不可用，请稍后重试。"
        case .http(404): return "鱼缸资源包暂未发布，请稍后重试。"
        case .http: return "资源包下载失败，请稍后重试。"
        }
    }
}

/// Only data lives outside the application bundle. A version is pinned by the
/// manifest shipped in the signed app, and is reused across ordinary app updates.
enum AquariumResources {
    static let manifest: AquariumPackManifest? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "AquariumPack", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(AquariumPackManifest.self, from: data),
              (try? value.validate()) != nil else { return nil }
        return value
    }()
    static var cacheRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhileAIWorks/ResourcePacks", isDirectory: true)
    }
    static var directory: URL? {
        // Native resource checks and older full bundles may still carry assets.
        #if SWIFT_PACKAGE
        let bundled = Bundle.module.resourceURL?.appendingPathComponent("AquariumAssets")
        #else
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("AquariumAssets")
        #endif
        return resolve(bundled: bundled, manifest: manifest, cache: cacheRoot)
    }
    static func resolve(bundled: URL?, manifest: AquariumPackManifest?, cache: URL) -> URL? {
        if let bundled, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("fish-envelopes.json").path) {
            return bundled
        }
        guard let manifest, AquariumPackInstaller.isInstalled(manifest, in: cache) else { return nil }
        return cache.appendingPathComponent(manifest.directoryName).appendingPathComponent("AquariumAssets")
    }
}

enum AquariumPackInstaller {
    static func digest(_ url: URL) throws -> String {
        let stream = try FileHandle(forReadingFrom: url)
        defer { try? stream.close() }
        var hash = SHA256()
        while let data = try stream.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func isInstalled(_ manifest: AquariumPackManifest, in cache: URL) -> Bool {
        let root = cache.appendingPathComponent(manifest.directoryName)
        guard let receipt = try? String(contentsOf: root.appendingPathComponent(".verified"), encoding: .utf8),
              receipt == manifest.sha256 else { return false }
        return manifest.files.allSatisfy { file in
            guard let info = try? root.appendingPathComponent("AquariumAssets/" + file.path)
                .resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return info.isRegularFile == true && info.isSymbolicLink != true && Int64(info.fileSize ?? -1) == file.bytes
        }
    }
    static func install(_ archive: URL, manifest: AquariumPackManifest, in cache: URL) throws -> URL {
        try manifest.validate()
        let manager = FileManager.default
        let bytes = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard Int64(bytes ?? -1) == manifest.archiveBytes, try digest(archive) == manifest.sha256 else { throw AquariumPackError.checksum }
        try Task.checkCancellation()
        try manager.createDirectory(at: cache, withIntermediateDirectories: true)
        let staging = cache.appendingPathComponent(".install-" + UUID().uuidString)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        // Extraction only runs after matching the archive pinned by the signed app.
        let extraction = Process()
        extraction.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        extraction.arguments = ["-x", "-k", archive.path, staging.path]
        extraction.standardOutput = FileHandle.nullDevice; extraction.standardError = FileHandle.nullDevice
        try extraction.run(); extraction.waitUntilExit()
        try Task.checkCancellation()
        guard extraction.terminationStatus == 0 else { throw AquariumPackError.incomplete }
        let assets = staging.appendingPathComponent("AquariumAssets")
        let expected = Set(manifest.files.map(\.path))
        var actual = Set<String>()
        // Relative enumeration avoids Foundation's /var vs /private/var aliases.
        // Trimming absolute URL prefixes can incorrectly reject complete packs.
        guard let entries = manager.enumerator(atPath: assets.path) else {
            throw AquariumPackError.incomplete
        }
        for case let relative as String in entries {
            let file = assets.appendingPathComponent(relative)
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            guard info.isSymbolicLink != true else { throw AquariumPackError.incomplete }
            if info.isDirectory == true { continue }
            guard info.isRegularFile == true else { throw AquariumPackError.incomplete }
            actual.insert(relative)
        }
        guard actual == expected else { throw AquariumPackError.incomplete }
        for file in manifest.files {
            try Task.checkCancellation()
            let url = assets.appendingPathComponent(file.path)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard Int64(size ?? -1) == file.bytes, try digest(url) == file.sha256 else { throw AquariumPackError.checksum }
        }
        try manifest.sha256.write(to: staging.appendingPathComponent(".verified"), atomically: true, encoding: .utf8)
        try Task.checkCancellation()
        let destination = cache.appendingPathComponent(manifest.directoryName)
        if isInstalled(manifest, in: cache) { return destination.appendingPathComponent("AquariumAssets") }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else { try manager.moveItem(at: staging, to: destination) }
        return destination.appendingPathComponent("AquariumAssets")
    }
}

/// Keep the Foundation download task (and its observable Progress) alive until
/// completion. Its temporary URL is only valid inside the completion handler.
private final class AquariumDownloadTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    func fetch(session: URLSession, request: URLRequest, destination: URL, bytes: Int64,
               progress: @escaping (Double) -> Void) async throws -> HTTPURLResponse {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let download = session.downloadTask(with: request) { [self] temporary, response, error in
                    lock.lock()
                    observation = nil; task = nil
                    let wasCancelled = cancelled
                    lock.unlock()
                    do {
                        if wasCancelled { throw CancellationError() }
                        if let error { throw error }
                        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                            throw AquariumPackError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
                        }
                        guard let temporary else { throw AquariumPackError.unavailable }
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.moveItem(at: temporary, to: destination)
                        continuation.resume(returning: response)
                    } catch { continuation.resume(throwing: error) }
                }
                lock.lock()
                task = download
                observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak download] _, _ in
                    guard let download else { return }
                    let received = download.countOfBytesReceived
                    if received > bytes { download.cancel() }
                    else { progress(min(1, Double(received) / Double(bytes))) }
                }
                let wasCancelled = cancelled
                lock.unlock()
                download.resume()
                if wasCancelled { download.cancel() }
            }
        }, onCancel: { self.cancel() })
    }
    private func cancel() {
        lock.lock(); cancelled = true; let current = task; lock.unlock()
        current?.cancel()
    }
}

@MainActor
final class AquariumResourceDownload: ObservableObject {
    enum Status: Equatable { case missing, downloading(Double), installing, ready, failed(String) }
    static let shared = AquariumResourceDownload()
    @Published private(set) var status: Status
    let manifest: AquariumPackManifest?
    private let cacheRoot: URL
    private let session: URLSession
    private var task: Task<Void, Never>?
    private var operation: UUID?
    var isReady: Bool { status == .ready }
    var downloadSize: String { ByteCountFormatter.string(fromByteCount: manifest?.archiveBytes ?? 0, countStyle: .file) }
    var installedSize: String { ByteCountFormatter.string(fromByteCount: manifest?.installedBytes ?? 0, countStyle: .file) }

    init(manifest: AquariumPackManifest? = AquariumResources.manifest, cacheRoot: URL = AquariumResources.cacheRoot,
         session: URLSession = .shared, bundledReady: Bool = AquariumResources.directory != nil) {
        self.manifest = manifest; self.cacheRoot = cacheRoot; self.session = session
        status = bundledReady || manifest.map({ AquariumPackInstaller.isInstalled($0, in: cacheRoot) }) == true ? .ready : .missing
    }
    func download() {
        guard task == nil, !isReady else { return }
        guard let manifest, manifest.url.scheme == "https", (try? manifest.validate()) != nil else {
            status = .failed(AquariumPackError.invalidManifest.localizedDescription); return
        }
        let id = UUID(); operation = id; status = .downloading(0)
        let cache = cacheRoot, session = session
        task = Task { [weak self] in
            var local: URL?
            defer {
                if let local { try? FileManager.default.removeItem(at: local) }
                if self?.operation == id { self?.task = nil; self?.operation = nil }
            }
            do {
                let archive = cache.appendingPathComponent(".download-" + UUID().uuidString + ".zip")
                local = archive
                var request = URLRequest(url: manifest.url)
                request.timeoutInterval = 60
                let transfer = AquariumDownloadTransfer()
                _ = try await transfer.fetch(session: session, request: request, destination: archive, bytes: manifest.archiveBytes) { [weak self] fraction in
                    Task { @MainActor in
                        guard self?.operation == id, case .downloading = self?.status else { return }
                        self?.status = .downloading(fraction)
                    }
                }
                try Task.checkCancellation()
                guard self?.operation == id else { return }
                self?.status = .installing
                let install = Task.detached(priority: .userInitiated) {
                    try AquariumPackInstaller.install(archive, manifest: manifest, in: cache)
                }
                _ = try await withTaskCancellationHandler(operation: { try await install.value }, onCancel: { install.cancel() })
                try Task.checkCancellation()
                if self?.operation == id { self?.status = .ready }
            } catch {
                guard self?.operation == id else { return }
                if Task.isCancelled { self?.status = .missing }
                else if let error = error as? AquariumPackError { self?.status = .failed(error.localizedDescription) }
                else if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileWriteOutOfSpaceError {
                    self?.status = .failed("磁盘空间不足，请清理空间后重试。")
                } else { self?.status = .failed("下载未完成，请检查网络或磁盘空间后重试。") }
            }
        }
    }
    func cancel() {
        operation = nil; task?.cancel(); task = nil; status = .missing
    }
}
