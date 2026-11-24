//
//  SudoPAMInstaller.swift
//  glance
//
//  Privileged Face-for-sudo installer, anti-TCC staging into per-user temporary
//  storage, administrator AppleScript runner, and relaunch helper.
//

import AppKit
import Darwin
import Foundation

/// Coordinates anti-TCC staging, privileged PAM setup/uninstall via macOS
/// administrator authorization, and clean relaunch to `/Applications/Glance.app`.
@MainActor
enum SudoPAMInstaller {
    enum ProgressPhase: Equatable, Sendable {
        case preparing
        case awaitingAuthorization
        case restarting
    }

    /// Installs, repairs, relocates, or updates Face-for-sudo PAM configuration.
    static func installOrRepair(
        onPhase: @escaping @MainActor (ProgressPhase) -> Void
    ) async -> SudoPAMInstallOutcome {
        let bundleURL = Bundle.main.bundleURL
        let bundledPAM = SudoPAMStatus.bundledPAMURL(in: bundleURL)
        let bundledScript = SudoPAMStatus.bundledSetupScriptURL(in: bundleURL)

        guard InstallerSupport.isRegularReadableFile(atPath: bundledPAM.path),
            InstallerSupport.isRegularReadableFile(atPath: bundledScript.path)
        else {
            return .failed(InstallerSupport.missingHelpersMessage)
        }

        let location = InstallerSupport.classifyRunningLocation(bundleURL: bundleURL)
        let preparation: InstallerSupport.PreparationResult

        if location == .exactTrustedBundle {
            let shellCommand = SudoPAMCommandBuilder.buildInstallShellCommand(
                scriptPath: bundledScript.path,
                pamSourcePath: bundledPAM.path,
                appSourcePath: nil
            )
            preparation = .ready(
                InstallerSupport.PreparedCommand(
                    stagingDirectory: nil,
                    shellCommand: shellCommand,
                    prompt: InstallerSupport.installPrompt,
                    requiresRelaunch: false
                )
            )
        } else {
            onPhase(.preparing)
            preparation = await Task.detached(priority: .userInitiated) {
                InstallerSupport.prepareStagedInstall(
                    bundleURL: bundleURL,
                    bundledScriptURL: bundledScript,
                    bundledPAMURL: bundledPAM,
                    location: location
                )
            }.value
        }

        return await runPreparedCommand(preparation, onPhase: onPhase)
    }

    /// Removes `pam_glance.so`, cleans `/etc/pam.d/sudo_local`, and restores user ownership when non-root.
    static func uninstall(
        onPhase: @escaping @MainActor (ProgressPhase) -> Void
    ) async -> SudoPAMInstallOutcome {
        let bundleURL = Bundle.main.bundleURL
        let bundledScript = SudoPAMStatus.bundledSetupScriptURL(in: bundleURL)

        guard InstallerSupport.isRegularReadableFile(atPath: bundledScript.path) else {
            return .failed(InstallerSupport.missingSetupScriptMessage)
        }

        let uid = Darwin.getuid()
        let restoreOwner = uid != 0 ? "\(uid):\(Darwin.getgid())" : nil
        let location = InstallerSupport.classifyRunningLocation(bundleURL: bundleURL)
        let preparation: InstallerSupport.PreparationResult

        if location == .exactTrustedBundle {
            let shellCommand = SudoPAMCommandBuilder.buildUninstallShellCommand(
                scriptPath: bundledScript.path,
                restoreOwner: restoreOwner
            )
            preparation = .ready(
                InstallerSupport.PreparedCommand(
                    stagingDirectory: nil,
                    shellCommand: shellCommand,
                    prompt: InstallerSupport.uninstallPrompt,
                    requiresRelaunch: false
                )
            )
        } else {
            onPhase(.preparing)
            preparation = await Task.detached(priority: .userInitiated) {
                InstallerSupport.prepareStagedUninstall(
                    bundledScriptURL: bundledScript,
                    restoreOwner: restoreOwner
                )
            }.value
        }

        return await runPreparedCommand(preparation, onPhase: onPhase)
    }

    /// Terminates other Glance instances, schedules relaunch of `/Applications/Glance.app`
    /// once running PIDs exit, and terminates the current process. Returns `false` if launching
    /// the detached helper fails so callers can show manual guidance instead of quitting.
    static func relaunchInstalledApp(openTab: SettingsTab = .sudo) -> Bool {
        guard FileManager.default.fileExists(atPath: SudoPAMStatus.trustedBundlePath) else {
            return false
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? InstallerSupport.defaultBundleIdentifier
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let otherApplications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier > 0 && $0.processIdentifier != currentPID }

        for application in otherApplications {
            application.terminate()
        }

        let waitPIDs = [currentPID] + otherApplications.map(\.processIdentifier)
        let relaunchScript = """
            tab="$1"
            shift
            attempts=0
            for pid in "$@"; do
                while /bin/kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 80 ]; do
                    /bin/sleep 0.1
                    attempts=$((attempts + 1))
                done
            done
            exec /usr/bin/open -n /Applications/Glance.app --args --open-settings-tab "$tab"
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", relaunchScript, "_", openTab.rawValue] + waitPIDs.map(String.init)
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }

        NSApp.terminate(nil)
        return true
    }

    /// Returns a copyable Terminal `sudo` install command referencing the bundled helper.
    static func manualInstallCommand() -> String {
        let bundleURL = Bundle.main.bundleURL
        let location = InstallerSupport.classifyRunningLocation(bundleURL: bundleURL)
        return SudoPAMCommandBuilder.manualInstallCommand(
            bundlePath: InstallerSupport.canonicalPath(of: bundleURL),
            requiresRelocation: location != .exactTrustedBundle
        )
    }

    /// Returns a copyable Terminal `sudo` uninstall command referencing the bundled helper.
    static func manualUninstallCommand() -> String {
        SudoPAMCommandBuilder.manualUninstallCommand(
            bundlePath: InstallerSupport.canonicalPath(of: Bundle.main.bundleURL)
        )
    }

    /// Opens System Settings → Privacy & Security → App Management (or Security root if unavailable).
    static func openAppManagementSettings() {
        if let appManagementURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles"
        ),
            NSWorkspace.shared.open(appManagementURL)
        {
            return
        }
        if let securityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(securityURL)
        }
    }

    private static func runPreparedCommand(
        _ preparation: InstallerSupport.PreparationResult,
        onPhase: @escaping @MainActor (ProgressPhase) -> Void
    ) async -> SudoPAMInstallOutcome {
        let prepared: InstallerSupport.PreparedCommand
        switch preparation {
        case .ready(let command):
            prepared = command
        case .failed(let outcome):
            return outcome
        }

        if Task.isCancelled {
            await InstallerSupport.removeDirectoryIfNeeded(prepared.stagingDirectory)
            return .cancelled
        }

        let appleScriptSource: String
        do {
            appleScriptSource = try SudoPAMCommandBuilder.buildAdminAppleScript(
                shellCommand: prepared.shellCommand,
                prompt: prepared.prompt
            )
        } catch {
            await InstallerSupport.removeDirectoryIfNeeded(prepared.stagingDirectory)
            return .failed(error.localizedDescription)
        }

        onPhase(.awaitingAuthorization)

        let stagingDirectory = prepared.stagingDirectory
        let requiresRelaunch = prepared.requiresRelaunch
        return await Task.detached(priority: .userInitiated) {
            defer {
                if let stagingDirectory {
                    try? FileManager.default.removeItem(at: stagingDirectory)
                }
            }
            return InstallerSupport.executeAdminAppleScript(
                appleScriptSource,
                requiresRelaunch: requiresRelaunch
            )
        }.value
    }
}

nonisolated private enum InstallerSupport {
    enum RunningLocation: Equatable, Sendable {
        case exactTrustedBundle
        case wrongCasing
        case outsideApplications
    }

    struct PreparedCommand: Sendable {
        let stagingDirectory: URL?
        let shellCommand: String
        let prompt: String
        let requiresRelaunch: Bool
    }

    enum PreparationResult: Sendable {
        case ready(PreparedCommand)
        case failed(SudoPAMInstallOutcome)
    }

    struct StagingFailure: Error {
        let message: String
    }

    static let installPrompt =
        "Glance needs administrator permission to set up Face authentication for sudo."
    static let uninstallPrompt =
        "Glance needs administrator permission to remove Face authentication for sudo."
    static let missingHelpersMessage =
        "Bundled PAM helper files are missing. Reinstall Glance and try again."
    static let missingSetupScriptMessage =
        "Bundled PAM setup script is missing. Reinstall Glance and try again."
    static let defaultBundleIdentifier = "com.pearleseed.glance"

    static func prepareStagedInstall(
        bundleURL: URL,
        bundledScriptURL: URL,
        bundledPAMURL: URL,
        location: RunningLocation
    ) -> PreparationResult {
        prepareStagedCommand(prompt: installPrompt, requiresRelaunch: true) { stageDir in
            if location == .wrongCasing {
                let stagedScript = stageDir.appendingPathComponent("glance-sudo-setup.sh", isDirectory: false)
                let stagedPAM = stageDir.appendingPathComponent("pam_glance.so", isDirectory: false)
                try copyAndVerify(from: bundledScriptURL, to: stagedScript, failureLabel: "PAM setup script")
                try copyAndVerify(from: bundledPAMURL, to: stagedPAM, failureLabel: "PAM module")
                return SudoPAMCommandBuilder.buildInstallShellCommand(
                    scriptPath: stagedScript.path,
                    pamSourcePath: stagedPAM.path,
                    appSourcePath: nil
                )
            }

            let stagedApp = stageDir.appendingPathComponent("Glance.app", isDirectory: true)
            try runDitto(from: bundleURL, to: stagedApp)

            let stagedExecutable = stagedApp.appendingPathComponent("Contents/MacOS/glance", isDirectory: false)
            let stagedScript = SudoPAMStatus.bundledSetupScriptURL(in: stagedApp)
            let stagedPAM = SudoPAMStatus.bundledPAMURL(in: stagedApp)
            guard isRegularReadableFile(atPath: stagedExecutable.path, requireExecutable: true),
                isRegularReadableFile(atPath: stagedPAM.path),
                isRegularReadableFile(atPath: stagedScript.path)
            else {
                throw StagingFailure(
                    message: "Staged Glance.app bundle is incomplete. Reinstall Glance and try again."
                )
            }

            return SudoPAMCommandBuilder.buildInstallShellCommand(
                scriptPath: stagedScript.path,
                pamSourcePath: stagedPAM.path,
                appSourcePath: stagedApp.path
            )
        }
    }

    static func prepareStagedUninstall(bundledScriptURL: URL, restoreOwner: String?) -> PreparationResult {
        prepareStagedCommand(prompt: uninstallPrompt, requiresRelaunch: false) { stageDir in
            let stagedScript = stageDir.appendingPathComponent("glance-sudo-setup.sh", isDirectory: false)
            try copyAndVerify(from: bundledScriptURL, to: stagedScript, failureLabel: "PAM setup script")
            return SudoPAMCommandBuilder.buildUninstallShellCommand(
                scriptPath: stagedScript.path,
                restoreOwner: restoreOwner
            )
        }
    }

    private static func prepareStagedCommand(
        prompt: String,
        requiresRelaunch: Bool,
        buildShellCommand: (URL) throws -> String
    ) -> PreparationResult {
        let stageDir: URL
        do {
            stageDir = try createPrivateStagingDirectory()
        } catch {
            return .failed(.failed("Failed to create temporary staging directory: \(error.localizedDescription)"))
        }

        var keepStageDir = false
        defer {
            if !keepStageDir {
                try? FileManager.default.removeItem(at: stageDir)
            }
        }

        do {
            let shellCommand = try buildShellCommand(stageDir)
            keepStageDir = true
            return .ready(
                PreparedCommand(
                    stagingDirectory: stageDir,
                    shellCommand: shellCommand,
                    prompt: prompt,
                    requiresRelaunch: requiresRelaunch
                )
            )
        } catch let failure as StagingFailure {
            return .failed(.failed(failure.message))
        } catch {
            return .failed(.failed("Failed to stage Glance setup files: \(error.localizedDescription)"))
        }
    }

    private static func copyAndVerify(from source: URL, to destination: URL, failureLabel: String) throws {
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw StagingFailure(message: "Failed to stage \(failureLabel): \(error.localizedDescription)")
        }
        guard isRegularReadableFile(atPath: destination.path) else {
            throw StagingFailure(message: "Staged \(failureLabel) is incomplete. Reinstall Glance and try again.")
        }
    }

    private static func createPrivateStagingDirectory() throws -> URL {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let stageDir = tempRoot.appendingPathComponent(
            "glance-sudo-stage-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stageDir,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )

        if Darwin.chmod(stageDir.path, mode_t(0o700)) != 0 {
            let errorCode = errno
            try? fileManager.removeItem(at: stageDir)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: String(cString: Darwin.strerror(errorCode))]
            )
        }

        return URL(fileURLWithPath: canonicalPath(of: stageDir), isDirectory: true)
    }

    private static func runDitto(from source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [source.path, destination.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw StagingFailure(message: "Failed to start bundle staging copy: \(error.localizedDescription)")
        }

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stderrText =
            String(bytes: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stderrText.isEmpty {
            throw StagingFailure(message: "Failed to stage Glance.app: \(stderrText)")
        }
        if !stderrData.isEmpty {
            throw StagingFailure(message: "Failed to stage Glance.app (ditto reported unreadable error output).")
        }
        if process.terminationStatus != 0 {
            throw StagingFailure(
                message: "Failed to stage Glance.app (ditto exited with status \(process.terminationStatus))."
            )
        }
    }

    static func executeAdminAppleScript(_ source: String, requiresRelaunch: Bool) -> SudoPAMInstallOutcome {
        guard let script = NSAppleScript(source: source) else {
            return .failed("Failed to initialize administrator authorization script.")
        }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        if errorInfo == nil {
            return .succeeded(requiresRelaunch: requiresRelaunch)
        }

        let errorNumber =
            (errorInfo?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            ?? (errorInfo?[NSAppleScript.errorNumber] as? Int)
        let briefMessage = errorInfo?[NSAppleScript.errorBriefMessage] as? String
        let fullMessage = errorInfo?[NSAppleScript.errorMessage] as? String
        return SudoPAMCommandBuilder.classifyAppleScriptError(
            errorNumber: errorNumber,
            briefMessage: briefMessage,
            fullMessage: fullMessage
        )
    }

    static func removeDirectoryIfNeeded(_ url: URL?) async {
        guard let url else { return }
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }

    static func canonicalPath(of url: URL) -> String {
        if let canonical = try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            return canonical
        }
        return url.standardizedFileURL.path
    }

    static func classifyRunningLocation(bundleURL: URL) -> RunningLocation {
        let runningCanonical = canonicalPath(of: bundleURL)
        let trustedURL = URL(fileURLWithPath: SudoPAMStatus.trustedBundlePath, isDirectory: true)
        let parentCanonical = canonicalPath(of: trustedURL.deletingLastPathComponent())
        let expectedCanonical = URL(fileURLWithPath: parentCanonical, isDirectory: true)
            .appendingPathComponent(trustedURL.lastPathComponent)
            .path

        if runningCanonical == expectedCanonical {
            return .exactTrustedBundle
        }
        if runningCanonical.lowercased() == expectedCanonical.lowercased() {
            return .wrongCasing
        }
        return .outsideApplications
    }

    static func isRegularReadableFile(atPath path: String, requireExecutable: Bool = false) -> Bool {
        var fileStat = stat()
        guard Darwin.lstat(path, &fileStat) == 0 else {
            return false
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG, fileStat.st_size > 0 else {
            return false
        }
        let fileManager = FileManager.default
        if requireExecutable {
            return fileManager.isReadableFile(atPath: path) && fileManager.isExecutableFile(atPath: path)
        }
        return fileManager.isReadableFile(atPath: path)
    }
}
