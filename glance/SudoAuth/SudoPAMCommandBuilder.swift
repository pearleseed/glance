//
//  SudoPAMCommandBuilder.swift
//  glance
//
//  Pure, Foundation-only command builder and AppleScript error classifier
//  for `glance-sudo-setup.sh` privileged setup, uninstall, and manual fallback.
//

import Foundation

/// Outcome of running privileged Face-for-sudo setup or uninstall via AppleScript.
nonisolated enum SudoPAMInstallOutcome: Equatable, Sendable {
    case succeeded(requiresRelaunch: Bool)
    case cancelled
    case needsAppManagementPermission(String)
    case failed(String)
}

/// Validation errors thrown when constructing AppleScript string literals.
nonisolated enum SudoPAMCommandBuilderError: Error, LocalizedError, Equatable {
    case invalidControlCharacter

    var errorDescription: String? {
        switch self {
        case .invalidControlCharacter:
            return "Command or prompt contains an unsupported newline or null character."
        }
    }
}

/// Pure helpers for POSIX single-quoting, AppleScript string escaping, command
/// assembly, and `NSAppleScript` error classification.
nonisolated enum SudoPAMCommandBuilder {
    static let trustedBundlePath = "/Applications/Glance.app"
    private static let setupScriptRelativePath = "Contents/Resources/glance-sudo-setup.sh"
    private static let pamModuleRelativePath = "Contents/Helpers/pam_glance.so"

    /// Wraps `value` in POSIX single quotes (`'...'`), escaping embedded single quotes as `'\''`.
    static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Formats `value` as a double-quoted AppleScript string literal, rejecting `\0`, `\r`, and `\n`.
    static func appleScriptStringLiteral(_ value: String) throws -> String {
        let hasInvalidControl = value.unicodeScalars.contains { scalar in
            scalar == "\0" || scalar == "\r" || scalar == "\n"
        }
        guard !hasInvalidControl else {
            throw SudoPAMCommandBuilderError.invalidControlCharacter
        }
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Builds the privileged `/bin/bash` install invocation for `glance-sudo-setup.sh`.
    static func buildInstallShellCommand(
        scriptPath: String,
        pamSourcePath: String,
        appSourcePath: String?
    ) -> String {
        var parts = [
            "/bin/bash",
            shellSingleQuote(scriptPath),
            "install",
            "--pam-source",
            shellSingleQuote(pamSourcePath)
        ]
        if let appSourcePath, !appSourcePath.isEmpty {
            parts.append(contentsOf: ["--app-source", shellSingleQuote(appSourcePath)])
        }
        return parts.joined(separator: " ")
    }

    /// Builds the privileged `/bin/bash` uninstall invocation for `glance-sudo-setup.sh`.
    static func buildUninstallShellCommand(scriptPath: String, restoreOwner: String?) -> String {
        var parts = [
            "/bin/bash",
            shellSingleQuote(scriptPath),
            "uninstall"
        ]
        if let restoreOwner, !restoreOwner.isEmpty {
            parts.append(contentsOf: ["--restore-owner", shellSingleQuote(restoreOwner)])
        }
        return parts.joined(separator: " ")
    }

    /// Wraps `shellCommand` and `prompt` into an AppleScript `do shell script ... with administrator privileges` call.
    static func buildAdminAppleScript(shellCommand: String, prompt: String) throws -> String {
        let quotedCommand = try appleScriptStringLiteral(shellCommand)
        let quotedPrompt = try appleScriptStringLiteral(prompt)
        return "do shell script \(quotedCommand) with administrator privileges with prompt \(quotedPrompt)"
    }

    /// Classifies an `NSAppleScript` execution failure into cancellation, App Management TCC denial, or failure.
    static func classifyAppleScriptError(
        errorNumber: Int?,
        briefMessage: String?,
        fullMessage: String?
    ) -> SudoPAMInstallOutcome {
        if errorNumber == -128 {
            return .cancelled
        }

        let brief = trimmedNonEmpty(briefMessage)
        let full = trimmedNonEmpty(fullMessage)
        let combinedLowercased = [brief, full]
            .compactMap { $0?.lowercased() }
            .joined(separator: "\n")

        if combinedLowercased.contains("operation not permitted"),
            combinedLowercased.contains("glance.app")
        {
            return .needsAppManagementPermission(
                "macOS denied permission to update /Applications/Glance.app. "
                    + "Allow Glance under System Settings > Privacy & Security > App Management, "
                    + "or use the manual Terminal commands below."
            )
        }

        let fallback =
            errorNumber.map { "Administrator command failed (error \($0))." }
            ?? "Administrator command failed."
        return .failed(brief ?? full ?? fallback)
    }

    /// Builds a copyable `sudo` Terminal install command pointing to the bundled helper script.
    static func manualInstallCommand(bundlePath: String, requiresRelocation: Bool) -> String {
        let effectiveBundle = requiresRelocation ? normalizedBundlePath(bundlePath) : trustedBundlePath
        let shellCommand = buildInstallShellCommand(
            scriptPath: "\(effectiveBundle)/\(setupScriptRelativePath)",
            pamSourcePath: "\(effectiveBundle)/\(pamModuleRelativePath)",
            appSourcePath: requiresRelocation ? effectiveBundle : nil
        )
        return "sudo \(shellCommand)"
    }

    /// Builds a copyable `sudo` Terminal uninstall command pointing to the bundled helper script.
    static func manualUninstallCommand(bundlePath: String) -> String {
        let effectiveBundle = normalizedBundlePath(bundlePath)
        let scriptQuoted = shellSingleQuote("\(effectiveBundle)/\(setupScriptRelativePath)")
        return #"sudo /bin/bash \#(scriptQuoted) uninstall --restore-owner "$(id -u):$(id -g)""#
    }

    private static func normalizedBundlePath(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed.isEmpty ? trustedBundlePath : trimmed
    }

    private static func trimmedNonEmpty(_ message: String?) -> String? {
        guard let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
