//
//  SudoAuthServer.swift
//  glance
//
//  User-private Unix domain socket server and strict 256-bit challenge-response
//  protocol for pam_glance. Intentionally imports only Foundation and Darwin so
//  tools/sudo_protocol_selftest.swift can compile and test it standalone.
//

import Darwin
import Foundation

nonisolated enum SudoAuthProtocol {
    static let maxLineLength = 256
    static let nonceByteCount = 32
    static let nonceHexLength = nonceByteCount * 2

    static func isValidNonce(_ candidate: String) -> Bool {
        let utf8 = candidate.utf8
        guard utf8.count == nonceHexLength else { return false }
        for byte in utf8 {
            let isDigit = byte >= 0x30 && byte <= 0x39 // '0'...'9'
            let isLowerHex = byte >= 0x61 && byte <= 0x66 // 'a'...'f'
            let isUpperHex = byte >= 0x41 && byte <= 0x46 // 'A'...'F'
            if !isDigit && !isLowerHex && !isUpperHex {
                return false
            }
        }
        return true
    }

    static func parseRequest(_ raw: String) -> String? {
        let line: String
        if raw.hasSuffix("\n") {
            line = String(raw.dropLast())
        } else {
            line = raw
        }

        let prefix = "AUTH "
        guard line.hasPrefix(prefix) else { return nil }
        let nonce = String(line.dropFirst(prefix.count))
        guard isValidNonce(nonce) else { return nil }
        return nonce
    }

    static func formatResponse(accepted: Bool, nonce: String) -> String {
        "\(accepted ? "OK" : "FAIL") \(nonce)\n"
    }
}

@MainActor
final class SudoAuthServer {
    nonisolated static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/glance-sudo", isDirectory: true)
    }

    nonisolated static var defaultSocketURL: URL {
        defaultDirectoryURL.appendingPathComponent("glance-sudo.sock", isDirectory: false)
    }

    private let socketURL: URL
    private let authTimeout: Duration
    nonisolated private let runtime = SocketRuntime()

    private(set) var isListening = false
    private(set) var lastError: String?

    init(
        socketURL: URL = SudoAuthServer.defaultSocketURL,
        authTimeout: Duration = .seconds(28)
    ) {
        self.socketURL = socketURL
        self.authTimeout = authTimeout
    }

    @discardableResult
    func start(authenticator: @escaping @MainActor @Sendable () async -> Bool) -> Bool {
        do {
            try runtime.start(
                socketURL: socketURL,
                authTimeout: authTimeout,
                authenticator: authenticator
            )
            isListening = true
            lastError = nil
            return true
        } catch {
            isListening = false
            lastError = error.localizedDescription
            return false
        }
    }

    func stop() {
        runtime.stop()
        isListening = false
    }
}

nonisolated private enum SudoAuthServerError: LocalizedError {
    case socketPathTooLong(String)
    case unsafeDirectoryPermissions(String)
    case unsafeSocketPath(String)
    case posixFailure(String, Int32)

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong(let path):
            return "Socket path exceeds Unix domain limit: \(path)"
        case .unsafeDirectoryPermissions(let path):
            return "Socket directory has unsafe ownership or permissions: \(path)"
        case .unsafeSocketPath(let path):
            return "Socket path exists and is not a Unix socket: \(path)"
        case .posixFailure(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code))) (\(code))"
        }
    }
}

nonisolated private final class SocketRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var session: SocketSession?

    func start(
        socketURL: URL,
        authTimeout: Duration,
        authenticator: @escaping @MainActor @Sendable () async -> Bool
    ) throws {
        stop()
        let newSession = try SocketSession(
            socketURL: socketURL,
            authTimeout: authTimeout,
            authenticator: authenticator
        )
        lock.lock()
        session = newSession
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let active = session
        session = nil
        lock.unlock()
        active?.stop()
    }

    deinit {
        stop()
    }
}

/// Manages single-flight client challenge handling, bounded timeouts, and guaranteed
/// single-owner response/close cleanup even if its owning session is stopped and deallocated.
nonisolated final class SudoAuthInFlightRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var isStopped = false
    private var isHandlingAuth = false
    private var activeTask: Task<Void, Never>?

    func stop() {
        lock.lock()
        if isStopped {
            lock.unlock()
            return
        }
        isStopped = true
        let task = activeTask
        activeTask = nil
        lock.unlock()

        task?.cancel()
    }

    /// Consumes `clientFD` (always writing a response if valid and closing `clientFD`).
    func handleAuthenticatedClientFD(
        _ clientFD: Int32,
        authTimeout: Duration,
        authenticator: @escaping @MainActor @Sendable () async -> Bool
    ) {
        var fd = clientFD
        defer {
            if fd >= 0 {
                _ = Darwin.close(fd)
            }
        }

        var ioTimeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &ioTimeout, socklen_t(MemoryLayout<timeval>.size))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &ioTimeout, socklen_t(MemoryLayout<timeval>.size))

        guard let line = Self.readRequestLine(fd: fd, maxBytes: SudoAuthProtocol.maxLineLength),
              let nonce = SudoAuthProtocol.parseRequest(line)
        else {
            return
        }

        lock.lock()
        let canClaim = !isStopped && !isHandlingAuth
        if canClaim {
            isHandlingAuth = true
        }
        lock.unlock()

        guard canClaim else {
            Self.writeAll(fd: fd, text: SudoAuthProtocol.formatResponse(accepted: false, nonce: nonce))
            return
        }

        let ownedFD = fd
        fd = -1 // Ownership transfers exclusively to responder.

        let responder = ClientAuthResponder(fd: ownedFD, nonce: nonce) {
            self.clearActiveAuthState()
        }

        // Strongly capture `self` and `responder` for the bounded task lifetime so stopping/deallocating
        // the outer SocketSession while `authenticator()` is suspended still delivers `FAIL <nonce>\n`
        // and closes `ownedFD` immediately.
        let task = Task.detached(priority: .userInitiated) {
            defer {
                responder.completeOnce(accepted: false)
                self.clearActiveAuthState()
            }

            let accepted = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await authenticator()
                }
                group.addTask {
                    try? await Task.sleep(for: authTimeout)
                    return false
                }
                let firstResult = await group.next() ?? false
                responder.completeOnce(accepted: firstResult)
                group.cancelAll()
                return firstResult
            }
            responder.completeOnce(accepted: accepted)
        }

        lock.lock()
        if isStopped {
            lock.unlock()
            task.cancel()
        } else {
            activeTask = task
            lock.unlock()
        }
    }

    private func clearActiveAuthState() {
        lock.lock()
        isHandlingAuth = false
        activeTask = nil
        lock.unlock()
    }

    private static func readRequestLine(fd: Int32, maxBytes: Int) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(80)

        var ch: UInt8 = 0
        while bytes.count < maxBytes {
            let n = Darwin.recv(fd, &ch, 1, 0)
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                return nil
            }
            if n == 0 {
                return nil
            }
            bytes.append(ch)
            if ch == 0x0A { // '\n'
                return String(bytes: bytes, encoding: .utf8)
            }
        }
        return nil
    }

    static func writeAll(fd: Int32, text: String) {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { rawPtr -> Int in
                guard let base = rawPtr.baseAddress else { return -1 }
                return Darwin.send(fd, base.advanced(by: sent), bytes.count - sent, 0)
            }
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                return
            }
            if n == 0 {
                return
            }
            sent += n
        }
    }
}

nonisolated private final class ClientAuthResponder: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    private let nonce: String
    private let onComplete: @Sendable () -> Void

    init(fd: Int32, nonce: String, onComplete: @escaping @Sendable () -> Void) {
        self.fd = fd
        self.nonce = nonce
        self.onComplete = onComplete
    }

    func completeOnce(accepted: Bool) {
        lock.lock()
        let currentFD = fd
        fd = -1
        lock.unlock()

        guard currentFD >= 0 else { return }
        onComplete()
        SudoAuthInFlightRunner.writeAll(
            fd: currentFD,
            text: SudoAuthProtocol.formatResponse(accepted: accepted, nonce: nonce)
        )
        _ = Darwin.close(currentFD)
    }

    deinit {
        completeOnce(accepted: false)
    }
}

nonisolated private final class SocketSession: @unchecked Sendable {
    private let socketPath: String
    private let authTimeout: Duration
    private let authenticator: @MainActor @Sendable () async -> Bool

    private let acceptQueue = DispatchQueue(label: "com.jonathan.glance.sudo.accept")
    private let clientQueue = DispatchQueue(label: "com.jonathan.glance.sudo.client", attributes: .concurrent)

    private let stateLock = NSLock()
    private var isStopped = false
    private var source: DispatchSourceRead?
    private let inFlightRunner = SudoAuthInFlightRunner()

    init(
        socketURL: URL,
        authTimeout: Duration,
        authenticator: @escaping @MainActor @Sendable () async -> Bool
    ) throws {
        self.socketPath = socketURL.path
        self.authTimeout = authTimeout
        self.authenticator = authenticator

        let dirURL = socketURL.deletingLastPathComponent()
        try Self.preparePrivateDirectory(at: dirURL)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathUTF8 = Array(socketPath.utf8CString)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathUTF8.count <= maxPathLen else {
            throw SudoAuthServerError.socketPathTooLong(socketPath)
        }

        var existingStat = stat()
        if Darwin.lstat(socketPath, &existingStat) == 0 {
            guard (existingStat.st_mode & S_IFMT) == S_IFSOCK else {
                throw SudoAuthServerError.unsafeSocketPath(socketPath)
            }
            if Darwin.unlink(socketPath) != 0 {
                throw SudoAuthServerError.posixFailure("unlink", errno)
            }
        }

        let listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw SudoAuthServerError.posixFailure("socket", errno)
        }

        var shouldCloseListenFD = true
        var shouldUnlinkSocket = false
        defer {
            if shouldUnlinkSocket {
                _ = Darwin.unlink(socketPath)
            }
            if shouldCloseListenFD {
                _ = Darwin.close(listenFD)
            }
        }

        _ = Darwin.fcntl(listenFD, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = Darwin.setsockopt(listenFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let existingFlags = Darwin.fcntl(listenFD, F_GETFL, 0)
        if existingFlags >= 0 {
            _ = Darwin.fcntl(listenFD, F_SETFL, existingFlags | O_NONBLOCK)
        }

        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            rawPtr.copyBytes(from: pathUTF8.map { UInt8(bitPattern: $0) })
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(listenFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw SudoAuthServerError.posixFailure("bind", errno)
        }
        shouldUnlinkSocket = true

        guard Darwin.chmod(socketPath, 0o600) == 0 else {
            throw SudoAuthServerError.posixFailure("chmod(socket)", errno)
        }

        guard Darwin.listen(listenFD, 8) == 0 else {
            throw SudoAuthServerError.posixFailure("listen", errno)
        }

        let readSource = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: acceptQueue)
        readSource.setEventHandler { [weak self] in
            self?.drainPendingConnections(listenFD: listenFD)
        }
        readSource.setCancelHandler {
            _ = Darwin.close(listenFD)
        }

        stateLock.lock()
        source = readSource
        stateLock.unlock()

        shouldCloseListenFD = false
        shouldUnlinkSocket = false
        readSource.resume()
    }

    func stop() {
        stateLock.lock()
        if isStopped {
            stateLock.unlock()
            return
        }
        isStopped = true
        let activeSource = source
        source = nil
        stateLock.unlock()

        _ = Darwin.unlink(socketPath)
        inFlightRunner.stop()
        activeSource?.cancel()
    }

    private static func preparePrivateDirectory(at dirURL: URL) throws {
        try FileManager.default.createDirectory(
            at: dirURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let dirPath = dirURL.path
        var st = stat()
        guard Darwin.lstat(dirPath, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == Darwin.getuid()
        else {
            throw SudoAuthServerError.unsafeDirectoryPermissions(dirPath)
        }

        guard Darwin.chmod(dirPath, 0o700) == 0 else {
            throw SudoAuthServerError.posixFailure("chmod(dir)", errno)
        }

        guard Darwin.lstat(dirPath, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == Darwin.getuid(),
              (st.st_mode & 0o777) == 0o700
        else {
            throw SudoAuthServerError.unsafeDirectoryPermissions(dirPath)
        }
    }

    private func drainPendingConnections(listenFD: Int32) {
        while true {
            stateLock.lock()
            let stopped = isStopped
            stateLock.unlock()
            if stopped { break }

            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }

            stateLock.lock()
            let stoppedAfterAccept = isStopped
            stateLock.unlock()
            if stoppedAfterAccept {
                _ = Darwin.close(clientFD)
                break
            }

            clientQueue.async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private func handleClient(_ clientFD: Int32) {
        _ = Darwin.fcntl(clientFD, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = Darwin.setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let flags = Darwin.fcntl(clientFD, F_GETFL, 0)
        if flags >= 0 && (flags & O_NONBLOCK) != 0 {
            _ = Darwin.fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)
        }

        // Security gate: only accept connections from a root-owned client (sudo PAM running as euid 0).
        var peerUID = uid_t.max
        var peerGID = gid_t.max
        guard Darwin.getpeereid(clientFD, &peerUID, &peerGID) == 0, peerUID == 0 else {
            _ = Darwin.close(clientFD)
            return
        }

        inFlightRunner.handleAuthenticatedClientFD(
            clientFD,
            authTimeout: authTimeout,
            authenticator: authenticator
        )
    }
}
