//
//  SystemAuthentication.swift
//  glance
//
//  Wrapper around LocalAuthentication (.deviceOwnerAuthentication) for Touch ID / password fallback
//  on locked-app curtains and for gating App Lock configuration changes in Settings.
//

import Foundation
import LocalAuthentication

nonisolated enum SystemAuthenticationOutcome: Equatable, Sendable {
    case authenticated
    case cancelled
    case failed(String)

    var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }
}

nonisolated enum SystemAuthentication {
    /// Evaluates `.deviceOwnerAuthentication` (Touch ID, Apple Watch, or macOS login password).
    /// Callers may pass an explicit `LAContext` when they need to cancel an in-flight prompt via `invalidate()`.
    static func authenticate(
        reason: String,
        context suppliedContext: LAContext? = nil
    ) async -> SystemAuthenticationOutcome {
        let context = suppliedContext ?? LAContext()
        defer { context.invalidate() }

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            return .failed(policyError?.localizedDescription ?? "System authentication is unavailable.")
        }

        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return success ? .authenticated : .failed("Authentication was not granted.")
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                return .cancelled
            default:
                return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
