//
//  SudoAuthServer.swift
//  glance
//
//  User-private Unix domain socket server for `pam_glance`. Intentionally imports
//  only Foundation and Darwin so `tools/sudo_protocol_selftest.swift` can compile
//  and test it standalone alongside `SudoAuthProtocol.swift`.
//

import Darwin
import Foundation

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

nonisolated private final class SocketSession: @unchecked Sendable {
    private let socketPath: String
    private let authTimeout: Duration
    private let authenticator: @MainActor @Sendable () async -> Bool

    private let acceptQueue = DispatchQueue(label: "com.pearleseed.glance.sudo.accept")
    private let clientQueue = DispatchQueue(label: "com.pearleseed.glance.sudo.client", attributes: .concurrent)

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

        try Self.preparePrivateDirectory(at: socketURL.deletingLastPathComponent())
        let listenFD = try Self.createListeningSocket(at: socketPath)

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

    private static func createListeningSocket(at socketPath: String) throws -> Int32 {
        var addr = try makeUnixSocketAddress(for: socketPath)
        try removeExistingSocketIfSafe(at: socketPath)

        let listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw SudoAuthServerError.posixFailure("socket", errno)
        }

        var shouldCloseListenFD = true
        var shouldUnlinkSocket = false
        defer {
            if shouldUnlinkSocket { _ = Darwin.unlink(socketPath) }
            if shouldCloseListenFD { _ = Darwin.close(listenFD) }
        }

        configureNonBlockingFD(listenFD)

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

        shouldCloseListenFD = false
        shouldUnlinkSocket = false
        return listenFD
    }

    private static func makeUnixSocketAddress(for socketPath: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathUTF8 = Array(socketPath.utf8CString)
        guard pathUTF8.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw SudoAuthServerError.socketPathTooLong(socketPath)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            rawPtr.copyBytes(from: pathUTF8.map { UInt8(bitPattern: $0) })
        }
        return addr
    }

    private static func removeExistingSocketIfSafe(at socketPath: String) throws {
        var existingStat = stat()
        guard Darwin.lstat(socketPath, &existingStat) == 0 else { return }
        guard (existingStat.st_mode & S_IFMT) == S_IFSOCK else {
            throw SudoAuthServerError.unsafeSocketPath(socketPath)
        }
        if Darwin.unlink(socketPath) != 0 {
            throw SudoAuthServerError.posixFailure("unlink", errno)
        }
    }

    private static func configureNonBlockingFD(_ fd: Int32) {
        _ = Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let existingFlags = Darwin.fcntl(fd, F_GETFL, 0)
        if existingFlags >= 0 {
            _ = Darwin.fcntl(fd, F_SETFL, existingFlags | O_NONBLOCK)
        }
    }

    private static func preparePrivateDirectory(at dirURL: URL) throws {
        try FileManager.default.createDirectory(
            at: dirURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let dirPath = dirURL.path
        var dirStat = stat()
        guard Darwin.lstat(dirPath, &dirStat) == 0,
            (dirStat.st_mode & S_IFMT) == S_IFDIR,
            dirStat.st_uid == Darwin.getuid()
        else {
            throw SudoAuthServerError.unsafeDirectoryPermissions(dirPath)
        }

        guard Darwin.chmod(dirPath, 0o700) == 0 else {
            throw SudoAuthServerError.posixFailure("chmod(dir)", errno)
        }

        guard Darwin.lstat(dirPath, &dirStat) == 0,
            (dirStat.st_mode & S_IFMT) == S_IFDIR,
            dirStat.st_uid == Darwin.getuid(),
            (dirStat.st_mode & 0o777) == 0o700
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
                if errno == EINTR { continue }
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
                guard let self else {
                    _ = Darwin.close(clientFD)
                    return
                }
                self.handleClient(clientFD)
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
