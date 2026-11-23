//
//  sudo_protocol_selftest.swift
//  glance (tools)
//
//  Offline self-test for SudoAuthProtocol strict 256-bit nonce validation and
//  SudoAuthServer socket directory permissions, peer UID rejection, and lifecycle cleanup.
//
//  Compile and run from repo root:
//      swiftc -O -o /tmp/sudo_protocol_selftest \
//        glance/SudoAuth/SudoAuthProtocol.swift \
//        glance/SudoAuth/SudoAuthServer.swift \
//        tools/sudo_protocol_selftest.swift \
//      && /tmp/sudo_protocol_selftest
//

import Darwin
import Foundation

@main
struct SudoProtocolSelfTest {
    @MainActor
    static func main() async {
        testProtocolValidation()
        await testServerSocketPermissionsPeerCheckAndCleanup()
        await testStopDuringInFlightAuthSendsFailAndClosesFD()
        await testUnwindingSingleFlightAndRequestIDNonClobbering()
        await testFastSequentialCompletionsReleaseSlotAndStopCleanly()
        print("PASS: SudoAuthProtocol strict 256-bit nonce validation passed.")
    }

    private static func testProtocolValidation() {
        let validNonce = String(repeating: "a1b2c3d4", count: 8) // 64 hex chars
        precondition(SudoAuthProtocol.parseRequest("AUTH \(validNonce)\n") == validNonce, "FAIL: valid AUTH rejected")
        precondition(SudoAuthProtocol.parseRequest("AUTH short\n") == nil, "FAIL: short nonce accepted")
        precondition(SudoAuthProtocol.parseRequest("AUTH " + String(repeating: "z", count: 64) + "\n") == nil, "FAIL: non-hex nonce accepted")
        precondition(SudoAuthProtocol.parseRequest("ALLOW\n") == nil, "FAIL: legacy static ALLOW accepted")
        precondition(SudoAuthProtocol.formatResponse(accepted: true, nonce: validNonce) == "OK \(validNonce)\n", "FAIL: OK response mismatch")
        precondition(SudoAuthProtocol.formatResponse(accepted: false, nonce: validNonce) == "FAIL \(validNonce)\n", "FAIL: FAIL response mismatch")

        // Additional strict protocol edge cases
        let upperNonce = String(repeating: "A1B2C3D4", count: 8)
        let mixedNonce = String(repeating: "aBcDeF09", count: 8)
        precondition(SudoAuthProtocol.parseRequest("AUTH \(upperNonce)\n") == upperNonce, "FAIL: uppercase hex rejected")
        precondition(SudoAuthProtocol.parseRequest("AUTH \(mixedNonce)\n") == mixedNonce, "FAIL: mixed-case hex rejected")
        precondition(SudoAuthProtocol.parseRequest("AUTH \(validNonce)") == validNonce, "FAIL: valid single line without trailing LF rejected")

        // Length boundary checks (63 and 65 chars)
        let nonce63 = String(validNonce.dropLast())
        let nonce65 = validNonce + "0"
        precondition(SudoAuthProtocol.parseRequest("AUTH \(nonce63)\n") == nil, "FAIL: 63-char nonce accepted")
        precondition(SudoAuthProtocol.parseRequest("AUTH \(nonce65)\n") == nil, "FAIL: 65-char nonce accepted")

        // Whitespace, framing, and command smuggling checks
        precondition(SudoAuthProtocol.parseRequest("") == nil, "FAIL: empty request accepted")
        precondition(SudoAuthProtocol.parseRequest("\n") == nil, "FAIL: blank line accepted")
        precondition(SudoAuthProtocol.parseRequest("AUTH \n") == nil, "FAIL: empty nonce accepted")
        precondition(SudoAuthProtocol.parseRequest("AUTH \(validNonce)\r\n") == nil, "FAIL: CRLF request accepted")
        precondition(SudoAuthProtocol.parseRequest("AUTH \(validNonce) \n") == nil, "FAIL: trailing space accepted")
        precondition(SudoAuthProtocol.parseRequest(" AUTH \(validNonce)\n") == nil, "FAIL: leading space accepted")
        precondition(SudoAuthProtocol.parseRequest("AUTH  \(validNonce)\n") == nil, "FAIL: double space accepted")
        precondition(SudoAuthProtocol.parseRequest("AUTH \(validNonce)\n\n") == nil, "FAIL: double newline accepted")
        precondition(SudoAuthProtocol.parseRequest("AUTH \(validNonce)\nALLOW\n") == nil, "FAIL: multi-line smuggled request accepted")
        precondition(SudoAuthProtocol.parseRequest("OK \(validNonce)\n") == nil, "FAIL: OK command accepted as request")
        precondition(SudoAuthProtocol.parseRequest("auth \(validNonce)\n") == nil, "FAIL: lowercase verb accepted")

        // Non-ASCII digits must never pass hex validation
        let arabicDigits = String(repeating: "١", count: 64)
        precondition(SudoAuthProtocol.parseRequest("AUTH \(arabicDigits)\n") == nil, "FAIL: non-ASCII digits accepted")
    }

    @MainActor
    private static func testServerSocketPermissionsPeerCheckAndCleanup() async {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-sudo-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let socketDir = baseDir.appendingPathComponent("glance-sudo", isDirectory: true)
        let socketURL = socketDir.appendingPathComponent("glance-sudo.sock")
        defer {
            try? FileManager.default.removeItem(at: baseDir)
        }

        let server = SudoAuthServer(socketURL: socketURL, authTimeout: .seconds(1))
        var authenticatorCalled = false
        let started = server.start {
            authenticatorCalled = true
            return true
        }
        precondition(started, "FAIL: SudoAuthServer failed to start at \(socketURL.path): \(server.lastError ?? "unknown")")
        precondition(server.isListening, "FAIL: SudoAuthServer.isListening should be true after start")

        // Verify socket directory permissions are strictly 0700 and not a symlink
        var dirStat = stat()
        precondition(lstat(socketDir.path, &dirStat) == 0, "FAIL: lstat on socket dir failed")
        precondition((dirStat.st_mode & S_IFMT) == S_IFDIR, "FAIL: socket dir is not a directory")
        precondition((dirStat.st_mode & 0o777) == 0o700, "FAIL: socket dir permissions must be 0700, got \(String(dirStat.st_mode & 0o777, radix: 8))")

        // Verify socket file exists, is S_IFSOCK, and permissions are 0600
        var sockStat = stat()
        precondition(lstat(socketURL.path, &sockStat) == 0, "FAIL: lstat on socket failed")
        precondition((sockStat.st_mode & S_IFMT) == S_IFSOCK, "FAIL: socket path is not a Unix socket")
        precondition((sockStat.st_mode & 0o777) == 0o600, "FAIL: socket permissions must be 0600, got \(String(sockStat.st_mode & 0o777, radix: 8))")

        // Verify non-root peer is rejected BEFORE reading or invoking authenticator
        if getuid() != 0 {
            let validNonce = String(repeating: "deadbeef", count: 8)
            let response = await Task.detached {
                sendSocketRequest(socketPath: socketURL.path, payload: "AUTH \(validNonce)\n")
            }.value
            precondition(response.isEmpty, "FAIL: non-root peer received unexpected response: \(response)")
            try? await Task.sleep(for: .milliseconds(50))
            precondition(!authenticatorCalled, "FAIL: authenticator must NOT be invoked for non-root peer")
        }

        // Verify rapid stop -> start -> stop unlinks cleanly without race
        server.stop()
        precondition(!server.isListening, "FAIL: isListening should be false after stop")
        precondition(!FileManager.default.fileExists(atPath: socketURL.path), "FAIL: socket file still exists after stop")

        let restarted = server.start { false }
        precondition(restarted, "FAIL: SudoAuthServer failed to restart")
        precondition(FileManager.default.fileExists(atPath: socketURL.path), "FAIL: socket file missing after restart")

        server.stop()
        precondition(!server.isListening, "FAIL: isListening should be false after second stop")
        precondition(!FileManager.default.fileExists(atPath: socketURL.path), "FAIL: socket file still exists after second stop")
    }

    private nonisolated static func sendSocketRequest(socketPath: String, payload: String) -> String {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return "" }
        defer { Darwin.close(fd) }

        var one: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return "" }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            rawPtr.copyBytes(from: pathBytes.map { UInt8(bitPattern: $0) })
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return "" }

        let bytes = Array(payload.utf8)
        _ = bytes.withUnsafeBytes { buf in
            Darwin.send(fd, buf.baseAddress, buf.count, 0)
        }

        var readBuf = [UInt8](repeating: 0, count: 128)
        let n = Darwin.recv(fd, &readBuf, readBuf.count, 0)
        guard n > 0 else { return "" }
        return String(decoding: readBuf[0..<n], as: UTF8.self)
    }

    @MainActor
    private static func testStopDuringInFlightAuthSendsFailAndClosesFD() async {
        var fds: [Int32] = [-1, -1]
        precondition(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "FAIL: socketpair failed")
        let clientFD = fds[0]
        let serverFD = fds[1]
        defer {
            _ = Darwin.close(clientFD)
        }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        _ = Darwin.setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let nonce = String(repeating: "cafebabe", count: 8)
        let request = Array("AUTH \(nonce)\n".utf8)
        let sent = request.withUnsafeBytes { buf in
            Darwin.send(clientFD, buf.baseAddress, buf.count, 0)
        }
        precondition(sent == request.count, "FAIL: failed to write AUTH request on socketpair")

        let authEntered = AsyncFlag()
        let authCancelled = AsyncFlag()

        // Returns right after runner.stop() so caller drops its sole strong reference while auth is suspended.
        let started = await startAndStopInFlightRunner(
            serverFD: serverFD,
            authEntered: authEntered,
            authCancelled: authCancelled
        )
        precondition(started, "FAIL: in-flight authenticator never entered")

        let (response, sawEOF) = await Task.detached {
            readAllUntilEOF(fd: clientFD)
        }.value

        precondition(
            response == "FAIL \(nonce)\n",
            "FAIL: expected FAIL <nonce>\\n on stop during in-flight auth, got \(String(reflecting: response))"
        )
        precondition(sawEOF, "FAIL: expected EOF after FAIL response (server FD leaked open)")

        let cancelled = await authCancelled.waitUntilSet(timeout: .seconds(2))
        precondition(cancelled, "FAIL: in-flight authenticator did not observe cancellation")
    }

    private static func startAndStopInFlightRunner(
        serverFD: Int32,
        authEntered: AsyncFlag,
        authCancelled: AsyncFlag
    ) async -> Bool {
        let runner = SudoAuthInFlightRunner()
        DispatchQueue.global(qos: .userInitiated).async {
            runner.handleAuthenticatedClientFD(
                serverFD,
                authTimeout: .seconds(28)
            ) {
                authEntered.set()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(15))
                }
                authCancelled.set()
                return false
            }
        }

        let entered = await authEntered.waitUntilSet(timeout: .seconds(2))
        runner.stop()
        return entered
    }

    private nonisolated static func readAllUntilEOF(fd: Int32) -> (String, Bool) {
        var collected: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 128)
        var sawEOF = false
        while true {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n > 0 {
                collected.append(contentsOf: buf[0..<n])
            } else if n == 0 {
                sawEOF = true
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        return (String(decoding: collected, as: UTF8.self), sawEOF)
    }

    private nonisolated static func makeSocketPairWithNonce(_ nonce: String) -> (clientFD: Int32, serverFD: Int32) {
        var fds: [Int32] = [-1, -1]
        precondition(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "FAIL: socketpair failed")
        let clientFD = fds[0]
        let serverFD = fds[1]

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        _ = Darwin.setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let request = Array("AUTH \(nonce)\n".utf8)
        let sent = request.withUnsafeBytes { buf in
            Darwin.send(clientFD, buf.baseAddress, buf.count, 0)
        }
        precondition(sent == request.count, "FAIL: failed to write AUTH request on socketpair")
        return (clientFD, serverFD)
    }

    @MainActor
    private static func testUnwindingSingleFlightAndRequestIDNonClobbering() async {
        let runner = SudoAuthInFlightRunner()
        defer { runner.stop() }

        let auth1Entered = AsyncFlag()
        let allowAuth1Unwind = AsyncFlag()
        let auth1Exited = AsyncFlag()

        let nonce1 = String(repeating: "1111aaaa", count: 8)
        let pair1 = makeSocketPairWithNonce(nonce1)
        defer { _ = Darwin.close(pair1.clientFD) }

        DispatchQueue.global(qos: .userInitiated).async {
            runner.handleAuthenticatedClientFD(
                pair1.serverFD,
                authTimeout: .milliseconds(50)
            ) {
                auth1Entered.set()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                while !allowAuth1Unwind.get() {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                auth1Exited.set()
                return false
            }
        }

        let entered = await auth1Entered.waitUntilSet(timeout: .seconds(2))
        precondition(entered, "FAIL: auth1 never entered")

        // Timeout fires at ~50ms and sends FAIL + EOF immediately while auth1 is still blocked unwinding.
        let (resp1, eof1) = await Task.detached { readAllUntilEOF(fd: pair1.clientFD) }.value
        precondition(resp1 == "FAIL \(nonce1)\n", "FAIL: expected timeout FAIL for client 1, got \(String(reflecting: resp1))")
        precondition(eof1, "FAIL: expected EOF for client 1 after timeout")

        // Client 2 arrives while auth1 is still unwinding; single-flight slot MUST still be locked.
        let auth2Entered = AsyncFlag()
        let nonce2 = String(repeating: "2222bbbb", count: 8)
        let pair2 = makeSocketPairWithNonce(nonce2)
        defer { _ = Darwin.close(pair2.clientFD) }

        DispatchQueue.global(qos: .userInitiated).async {
            runner.handleAuthenticatedClientFD(
                pair2.serverFD,
                authTimeout: .seconds(2)
            ) {
                auth2Entered.set()
                return true
            }
        }

        let (resp2, eof2) = await Task.detached { readAllUntilEOF(fd: pair2.clientFD) }.value
        precondition(resp2 == "FAIL \(nonce2)\n", "FAIL: expected busy FAIL for client 2 while auth1 unwinds, got \(String(reflecting: resp2))")
        precondition(eof2, "FAIL: expected EOF for client 2")
        precondition(!auth2Entered.get(), "FAIL: auth2 ran concurrently while auth1 was still unwinding")

        // Release auth1 unwind and verify Client 3 succeeds once auth1's defer releases activeRequestID.
        allowAuth1Unwind.set()
        let exited = await auth1Exited.waitUntilSet(timeout: .seconds(2))
        precondition(exited, "FAIL: auth1 failed to unwind")

        var client3Accepted = false
        for _ in 0..<20 {
            let nonce3 = String(repeating: "3333cccc", count: 8)
            let pair3 = makeSocketPairWithNonce(nonce3)
            DispatchQueue.global(qos: .userInitiated).async {
                runner.handleAuthenticatedClientFD(
                    pair3.serverFD,
                    authTimeout: .seconds(2)
                ) {
                    true
                }
            }
            let (resp3, eof3) = await Task.detached { readAllUntilEOF(fd: pair3.clientFD) }.value
            _ = Darwin.close(pair3.clientFD)
            precondition(eof3, "FAIL: expected EOF for client 3")
            if resp3 == "OK \(nonce3)\n" {
                client3Accepted = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        precondition(client3Accepted, "FAIL: client 3 was never accepted after auth1 unwound")
    }

    @MainActor
    private static func testFastSequentialCompletionsReleaseSlotAndStopCleanly() async {
        let runner = SudoAuthInFlightRunner()

        for iteration in 0..<20 {
            let suffix = String(format: "%08x", iteration)
            let nonce = String(repeating: "abcdef01", count: 7) + suffix
            let pair = makeSocketPairWithNonce(nonce)

            DispatchQueue.global(qos: .userInitiated).async {
                runner.handleAuthenticatedClientFD(
                    pair.serverFD,
                    authTimeout: .seconds(2)
                ) {
                    true
                }
            }

            let (resp, eof) = await Task.detached { readAllUntilEOF(fd: pair.clientFD) }.value
            _ = Darwin.close(pair.clientFD)
            precondition(resp == "OK \(nonce)\n", "FAIL: fast sequential iteration \(iteration) expected OK, got \(String(reflecting: resp))")
            precondition(eof, "FAIL: fast sequential iteration \(iteration) expected EOF")

            // Give Task.detached defer a beat to clear activeRequestID before the next sequential request.
            try? await Task.sleep(for: .milliseconds(5))
        }

        runner.stop()

        let stoppedNonce = String(repeating: "9999eeee", count: 8)
        let stoppedPair = makeSocketPairWithNonce(stoppedNonce)
        DispatchQueue.global(qos: .userInitiated).async {
            runner.handleAuthenticatedClientFD(
                stoppedPair.serverFD,
                authTimeout: .seconds(2)
            ) {
                true
            }
        }
        let (stoppedResp, stoppedEOF) = await Task.detached { readAllUntilEOF(fd: stoppedPair.clientFD) }.value
        _ = Darwin.close(stoppedPair.clientFD)
        precondition(stoppedResp == "FAIL \(stoppedNonce)\n", "FAIL: stopped runner must fail new requests, got \(String(reflecting: stoppedResp))")
        precondition(stoppedEOF, "FAIL: expected EOF after stopped FAIL")
    }
}

nonisolated private final class AsyncFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    func set() {
        lock.withLock {
            isSet = true
        }
    }

    func get() -> Bool {
        lock.withLock { isSet }
    }

    func waitUntilSet(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if lock.withLock({ isSet }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
