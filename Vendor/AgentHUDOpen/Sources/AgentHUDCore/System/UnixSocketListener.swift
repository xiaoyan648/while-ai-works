import Foundation
import Network
import os.log

/// The application's side of a `UnixSocket`: it listens at `path` and hands each request, once its sender stopped
/// writing, to `onRequest` with the connection, which answers it or lets it go. One process serves a path: a lock beside
/// the socket keeps a second copy of the application from replacing it, and a process removes only the socket it made.
@MainActor
public final class UnixSocketListener {
    public let path: String
    /// The largest request read; a longer one closes its connection.
    public let requestLimit: Int
    private let onRequest: @MainActor (Data, NWConnection) -> Void
    private let log: Logger
    private var listener: NWListener?
    /// The lock that makes this process the one serving the path, and the socket file it made, by device and inode.
    private var lock: Int32 = -1
    private var socket: [Int]?

    /// - category: names the socket in the application's log.
    public init(path: String, requestLimit: Int, category: String, onRequest: @escaping @MainActor (Data, NWConnection) -> Void) {
        self.path = path
        self.requestLimit = requestLimit
        self.onRequest = onRequest
        log = Logger(subsystem: "app.agenthud", category: category)
    }

    public var isListening: Bool { listener != nil }

    /// Starts listening; false when the path does not fit a socket address, another process serves it or the socket
    /// cannot be made.
    @discardableResult
    public func start() -> Bool {
        guard listener == nil else { return true }
        let path = path
        guard UnixSocket.fits(path) else {
            log.error("Socket path is too long for a unix socket: \(path, privacy: .public)")
            return false
        }
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Another copy of the app opened beside this one, which shares its data directory, leaves the socket to the one
        // that serves it rather than replacing it; the lock goes with the process that holds it.
        let lock = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if lock >= 0 { close(lock) }
            log.info("Another instance serves \(path, privacy: .public)")
            return false
        }
        unlink(path)
        // The socket must never be readable by anyone else, not even for the moment between bind and chmod.
        let previous = umask(0o077)
        let parameters = NWParameters()
        parameters.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        parameters.requiredLocalEndpoint = .unix(path: path)
        guard let listener = try? NWListener(using: parameters) else {
            umask(previous)
            close(lock)
            log.error("Could not listen on \(path, privacy: .public)")
            return false
        }
        self.lock = lock
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    umask(previous)
                    chmod(path, 0o700)
                    self?.socket = Self.identity(path)
                case .failed:
                    umask(previous)
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                connection.start(queue: .main)
                self?.receive(connection, accumulated: Data())
            }
        }
        listener.start(queue: .main)
        return true
    }

    /// Stops listening. Only the socket this process made is removed.
    public func stop() {
        listener?.cancel()
        listener = nil
        if let socket, Self.identity(path) == socket { unlink(path) }
        socket = nil
        if lock >= 0 { close(lock) }
        lock = -1
    }

    private static func identity(_ path: String) -> [Int]? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return [Int(info.st_dev), Int(truncatingIfNeeded: info.st_ino)]
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            MainActor.assumeIsolated {
                var data = accumulated
                if let content { data.append(content) }
                guard let self, data.count <= self.requestLimit else { return connection.cancel() }
                if isComplete || error != nil {
                    self.onRequest(data, connection)
                } else {
                    self.receive(connection, accumulated: data)
                }
            }
        }
    }
}
