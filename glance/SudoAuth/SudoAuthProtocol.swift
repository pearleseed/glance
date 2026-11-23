//
//  SudoAuthProtocol.swift
//  glance
//
//  Strict 256-bit challenge-response wire protocol and single-flight request runner
//  for `SudoAuthServer` / `pam_glance`.
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
            let isDigit = byte >= 0x30 && byte <= 0x39  // '0'...'9'
            let isLowerHex = byte >= 0x61 && byte <= 0x66  // 'a'...'f'
            let isUpperHex = byte >= 0x41 && byte <= 0x46  // 'A'...'F'
            if !isDigit && !isLowerHex && !isUpperHex {
                return false
            }
        }
        return true
    }

    static func parseRequest(_ raw: String) -> String? {
        let line = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
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

/// Manages single-flight client challenge handling, bounded timeouts, and guaranteed
/// single-owner response/close cleanup even if its owning session is stopped and deallocated.
nonisolated final class SudoAuthInFlightRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var isStopped = false
    private var nextRequestID: UInt64 = 0
    private var activeRequestID: UInt64?
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

        Self.applySocketTimeouts(fd: fd, seconds: 5)
        guard let line = Self.readRequestLine(fd: fd, maxBytes: SudoAuthProtocol.maxLineLength),
            let nonce = SudoAuthProtocol.parseRequest(line)
        else { return }

        guard let requestID = claimSingleFlightSlot() else {
            Self.writeAll(fd: fd, text: SudoAuthProtocol.formatResponse(accepted: false, nonce: nonce))
            return
        }

        let ownedFD = fd
        fd = -1  // Ownership transfers exclusively to responder.
        let responder = ClientAuthResponder(fd: ownedFD, nonce: nonce)

        // Strongly capture `self` and `responder` for the bounded task lifetime so stopping/deallocating
        // the outer SocketSession while `authenticator()` is suspended still delivers `FAIL <nonce>\n`
        // and closes `ownedFD` immediately, while holding the single-flight slot until unwind completes.
        let task = Task.detached(priority: .userInitiated) {
            defer {
                responder.completeOnce(accepted: false)
                self.clearActiveAuthState(for: requestID)
            }

            let accepted = await withTaskGroup(of: Bool.self) { group in
                group.addTask { await authenticator() }
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

        registerActiveTask(task, for: requestID)
    }

    private func claimSingleFlightSlot() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped, activeRequestID == nil else { return nil }
        nextRequestID &+= 1
        if nextRequestID == 0 { nextRequestID = 1 }
        activeRequestID = nextRequestID
        return nextRequestID
    }

    private func registerActiveTask(_ task: Task<Void, Never>, for requestID: UInt64) {
        lock.lock()
        guard activeRequestID == requestID else {
            // Task already finished and released `requestID` before `lock` was reacquired.
            lock.unlock()
            return
        }
        if isStopped {
            lock.unlock()
            task.cancel()
        } else {
            activeTask = task
            lock.unlock()
        }
    }

    private func clearActiveAuthState(for requestID: UInt64) {
        lock.lock()
        if activeRequestID == requestID {
            activeRequestID = nil
            activeTask = nil
        }
        lock.unlock()
    }

    private static func applySocketTimeouts(fd: Int32, seconds: Int) {
        var ioTimeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &ioTimeout, socklen_t(MemoryLayout<timeval>.size))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &ioTimeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func readRequestLine(fd: Int32, maxBytes: Int) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(80)

        var byte: UInt8 = 0
        while bytes.count < maxBytes {
            let received = Darwin.recv(fd, &byte, 1, 0)
            if received < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if received == 0 { return nil }
            bytes.append(byte)
            if byte == 0x0A {  // '\n'
                return String(bytes: bytes, encoding: .utf8)
            }
        }
        return nil
    }

    static func writeAll(fd: Int32, text: String) {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let written = bytes.withUnsafeBytes { rawPtr -> Int in
                guard let base = rawPtr.baseAddress else { return -1 }
                return Darwin.send(fd, base.advanced(by: sent), bytes.count - sent, 0)
            }
            if written < 0 {
                if errno == EINTR { continue }
                return
            }
            if written == 0 { return }
            sent += written
        }
    }
}

nonisolated private final class ClientAuthResponder: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    private let nonce: String

    init(fd: Int32, nonce: String) {
        self.fd = fd
        self.nonce = nonce
    }

    func completeOnce(accepted: Bool) {
        lock.lock()
        let currentFD = fd
        fd = -1
        lock.unlock()

        guard currentFD >= 0 else { return }
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
