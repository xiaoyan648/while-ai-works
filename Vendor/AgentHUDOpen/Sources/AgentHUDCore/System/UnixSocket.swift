import Darwin
import Foundation

/// A unix-domain stream socket between the running application and the short-lived processes a client's hooks start. A
/// request is one message, which its sender ends by closing its writing side; only the user can reach the socket.
public enum UnixSocket {
    /// Whether `path` fits a socket address, which holds about a hundred bytes.
    public static func fits(_ path: String) -> Bool { path.utf8.count < 104 }

    /// Connects to the socket at `path`; a write after the other side went away fails instead of raising SIGPIPE. Nil
    /// when there is no socket at `path` or nothing accepts.
    public static func connect(to path: String) -> Int32? {
        var info = stat()
        guard fits(path), stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let size = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: size) { strlcpy($0, path, size) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Writes all of `data`; false when the other side went away.
    public static func send(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            var sent = 0
            while sent < buffer.count {
                let written = Darwin.send(descriptor, base + sent, buffer.count - sent, 0)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                sent += written
            }
            return true
        }
    }

    /// Reads until the other side closes the connection, or until more than `limit` bytes arrived.
    public static func readToEnd(_ descriptor: Int32, limit: Int) -> Data {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count <= limit {
            let read = recv(descriptor, &buffer, buffer.count, 0)
            if read < 0 {
                if errno == EINTR { continue }
                break
            }
            if read == 0 { break }
            response.append(contentsOf: buffer[..<read])
        }
        return response
    }
}
