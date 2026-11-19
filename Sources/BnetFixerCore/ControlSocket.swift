import Foundation

public enum ControlError: Error, Equatable, CustomStringConvertible {
    /// Nothing is listening: the daemon isn't running.
    case notRunning
    case pathTooLong
    case system(String, Int32)
    case badMessage

    public var description: String {
        switch self {
        case .notRunning: return "bnet-mac-fixer isn't running"
        case .pathTooLong: return "control socket path is too long"
        case .system(let call, let code): return "\(call): \(String(cString: strerror(code)))"
        case .badMessage: return "malformed control message"
        }
    }
}

/// Serves `ControlRequest`s on a Unix socket. Connections are read on a private queue; the handler
/// runs on `handlerQueue` (main by default, where the daemon's state lives).
public final class ControlServer {
    private let path: String
    private let handlerQueue: DispatchQueue
    private let ioQueue = DispatchQueue(label: "bnet-mac-fixer.control")
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String = FixerPaths.controlSocket, handlerQueue: DispatchQueue = .main) {
        self.path = path
        self.handlerQueue = handlerQueue
    }

    public func start(handler: @escaping (ControlRequest) -> ControlResponse) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var address = try UnixSocket.address(path)
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.system("socket", errno) }
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { let e = errno; close(fd); throw ControlError.system("bind", e) }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { let e = errno; close(fd); throw ControlError.system("listen", e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listener = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                self?.serve(client, handler)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        unlink(path)
    }

    private func serve(_ client: Int32, _ handler: @escaping (ControlRequest) -> ControlResponse) {
        defer { close(client) }
        UnixSocket.configure(client, timeout: 1)
        let response: ControlResponse
        if let line = UnixSocket.readLine(client), let request = try? FixerCoding.decoder.decode(ControlRequest.self, from: line) {
            response = handlerQueue.sync { handler(request) }
        } else {
            response = ControlResponse(ok: false, message: ControlError.badMessage.description)
        }
        if let data = try? FixerCoding.encoder.encode(response) { UnixSocket.write(client, data + [0x0A]) }
    }
}

public enum ControlClient {
    /// Sends one request and waits for the reply. Blocking; call off the main thread in UI code.
    public static func send(_ request: ControlRequest, path: String = FixerPaths.controlSocket, timeout: TimeInterval = 2) throws -> ControlResponse {
        var address = try UnixSocket.address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.system("socket", errno) }
        defer { close(fd) }
        UnixSocket.configure(fd, timeout: timeout)
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else {
            let e = errno
            throw (e == ENOENT || e == ECONNREFUSED) ? ControlError.notRunning : ControlError.system("connect", e)
        }
        UnixSocket.write(fd, try FixerCoding.encoder.encode(request) + [0x0A])
        guard let line = UnixSocket.readLine(fd) else { throw ControlError.badMessage }
        do { return try FixerCoding.decoder.decode(ControlResponse.self, from: line) } catch { throw ControlError.badMessage }
    }
}

enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ControlError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func configure(_ fd: Int32, timeout: TimeInterval) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Reads up to the first newline (or EOF). Nil on timeout/error or if nothing arrived.
    static func readLine(_ fd: Int32, limit: Int = 1 << 20) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < limit {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            if let newline = buffer[..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[..<newline])
                return data
            }
            data.append(contentsOf: buffer[..<n])
        }
        return data.isEmpty ? nil : data
    }

    static func write(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }
}
