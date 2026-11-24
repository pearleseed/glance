//
//  sudo_installer_selftest.swift
//  glance (tools)
//
//  Offline self-tests for `sudo-support/glance-sudo-setup.sh`,
//  `SudoPAMCommandBuilder`, and `SudoPAMStatus`.
//
//  Compile and run from repo root:
//      swiftc -O -o /tmp/sudo_installer_selftest \
//        glance/SudoAuth/SudoPAMCommandBuilder.swift \
//        glance/SudoAuth/SudoPAMStatus.swift \
//        tools/sudo_installer_selftest.swift \
//      && /tmp/sudo_installer_selftest
//

import Darwin
import Foundation

@main
struct SudoInstallerSelfTest {
    private static let expectedBundleID = "com.pearleseed.glance"
    private static let expectedPAMLine = "auth       sufficient     /usr/local/lib/pam/pam_glance.so"

    static func main() {
        testCommandBuilderAndErrorClassification()
        testPAMStatusProbe()
        testSetupScriptEndToEnd()
        print("PASS: glance-sudo-setup.sh, SudoPAMCommandBuilder, and SudoPAMStatus self-tests passed.")
    }

    private static func testCommandBuilderAndErrorClassification() {
        testShellSingleQuoting()
        testAppleScriptStringLiteral()
        testInstallAndUninstallShellCommands()
        testAdminAppleScriptBuildAndSyntax()
        testClassifyAppleScriptError()
        testManualCommands()
    }

    private static func testShellSingleQuoting() {
        require(
            SudoPAMCommandBuilder.shellSingleQuote("/Applications/Glance.app") == "'/Applications/Glance.app'",
            "FAIL [quote]: plain path mismatch"
        )
        require(
            SudoPAMCommandBuilder.shellSingleQuote("/Users/Jane Doe/Downloads/Glance (1).app")
                == "'/Users/Jane Doe/Downloads/Glance (1).app'",
            "FAIL [quote]: spaces/parens mismatch"
        )
        require(
            SudoPAMCommandBuilder.shellSingleQuote("/Users/O'Brien/Glance.app")
                == "'/Users/O'\\''Brien/Glance.app'",
            "FAIL [quote]: apostrophe mismatch"
        )

        let metacharacters = #"/Users/O'Brien/$(rm -rf /) `id` $HOME; echo hi "double" \slash"#
        let quoted = SudoPAMCommandBuilder.shellSingleQuote(metacharacters)
        let echoResult = runShellCommand("printf '%s' \(quoted)")
        require(echoResult.status == 0, "FAIL [quote]: bash printf failed: \(echoResult.stderr)")
        require(
            echoResult.stdout == metacharacters,
            "FAIL [quote]: round-trip mismatch: got \(echoResult.stdout), want \(metacharacters)"
        )
    }

    private static func testAppleScriptStringLiteral() {
        let escaped = try! SudoPAMCommandBuilder.appleScriptStringLiteral(#"C:\Program Files\"Glance""#)
        require(
            escaped == #""C:\\Program Files\\\"Glance\"""#,
            "FAIL [asLiteral]: backslash/quote escaping mismatch: \(escaped)"
        )

        let metachars = try! SudoPAMCommandBuilder.appleScriptStringLiteral(#"O'Brien $(id) `uname`"#)
        require(
            metachars == #""O'Brien $(id) `uname`""#,
            "FAIL [asLiteral]: metacharacters unexpected modification: \(metachars)"
        )

        for bad in ["line1\nline2", "line1\rline2", "line1\r\nline2", "bad\0null"] {
            do {
                _ = try SudoPAMCommandBuilder.appleScriptStringLiteral(bad)
                require(false, "FAIL [asLiteral]: expected invalidControlCharacter for \(bad.debugDescription)")
            } catch let error as SudoPAMCommandBuilderError {
                require(
                    error == .invalidControlCharacter,
                    "FAIL [asLiteral]: unexpected error \(error)"
                )
            } catch {
                require(false, "FAIL [asLiteral]: unexpected error type \(error)")
            }
        }
    }

    private static func testInstallAndUninstallShellCommands() {
        let script = "/Users/O'Brien/Downloads/Glance (1)/Glance.app/Contents/Resources/glance-sudo-setup.sh"
        let pam = "/Users/O'Brien/Downloads/Glance (1)/Glance.app/Contents/Helpers/pam_glance.so"
        let app = "/Users/O'Brien/Downloads/Glance (1)/Glance.app"

        let withoutApp = SudoPAMCommandBuilder.buildInstallShellCommand(
            scriptPath: script,
            pamSourcePath: pam,
            appSourcePath: nil
        )
        let expectedWithoutApp =
            "/bin/bash '/Users/O'\\''Brien/Downloads/Glance (1)/Glance.app/Contents/Resources/glance-sudo-setup.sh' "
            + "install --pam-source "
            + "'/Users/O'\\''Brien/Downloads/Glance (1)/Glance.app/Contents/Helpers/pam_glance.so'"
        require(withoutApp == expectedWithoutApp, "FAIL [installCmd]: withoutApp mismatch: \(withoutApp)")
        require(!withoutApp.contains("--app-source"), "FAIL [installCmd]: unexpected --app-source")

        let withApp = SudoPAMCommandBuilder.buildInstallShellCommand(
            scriptPath: script,
            pamSourcePath: pam,
            appSourcePath: app
        )
        let expectedWithApp =
            expectedWithoutApp
            + " --app-source '/Users/O'\\''Brien/Downloads/Glance (1)/Glance.app'"
        require(withApp == expectedWithApp, "FAIL [installCmd]: withApp mismatch: \(withApp)")

        let uninstallPlain = SudoPAMCommandBuilder.buildUninstallShellCommand(
            scriptPath: "/Applications/Glance.app/Contents/Resources/glance-sudo-setup.sh",
            restoreOwner: nil
        )
        require(
            uninstallPlain
                == "/bin/bash '/Applications/Glance.app/Contents/Resources/glance-sudo-setup.sh' uninstall",
            "FAIL [uninstallCmd]: plain mismatch: \(uninstallPlain)"
        )

        let uninstallRestore = SudoPAMCommandBuilder.buildUninstallShellCommand(
            scriptPath: "/Applications/Glance.app/Contents/Resources/glance-sudo-setup.sh",
            restoreOwner: "501:20"
        )
        require(
            uninstallRestore
                == "/bin/bash '/Applications/Glance.app/Contents/Resources/glance-sudo-setup.sh' "
                + "uninstall --restore-owner '501:20'",
            "FAIL [uninstallCmd]: restore mismatch: \(uninstallRestore)"
        )
    }

    private static func testAdminAppleScriptBuildAndSyntax() {
        let shellCmd = SudoPAMCommandBuilder.buildInstallShellCommand(
            scriptPath: #"/Users/O'Brien/$(test) "q"/Glance.app/Contents/Resources/glance-sudo-setup.sh"#,
            pamSourcePath: #"/Users/O'Brien/$(test) "q"/Glance.app/Contents/Helpers/pam_glance.so"#,
            appSourcePath: #"/Users/O'Brien/$(test) "q"/Glance.app"#
        )
        let prompt = #"Glance needs administrator permission to install "Face for sudo" (O'Brien)."#
        let appleScript = try! SudoPAMCommandBuilder.buildAdminAppleScript(
            shellCommand: shellCmd,
            prompt: prompt
        )
        require(
            appleScript.hasPrefix("do shell script ")
                && appleScript.contains(" with administrator privileges with prompt "),
            "FAIL [appleScript]: unexpected structure: \(appleScript)"
        )

        // Verify invalid control chars are rejected in both shellCommand and prompt
        for bad in ["echo\nhello", "echo\rhello", "echo\0hello"] {
            do {
                _ = try SudoPAMCommandBuilder.buildAdminAppleScript(shellCommand: bad, prompt: "Prompt")
                require(false, "FAIL [appleScript]: expected throw for bad shellCommand")
            } catch SudoPAMCommandBuilderError.invalidControlCharacter {
                // Expected
            } catch {
                require(false, "FAIL [appleScript]: unexpected error \(error)")
            }

            do {
                _ = try SudoPAMCommandBuilder.buildAdminAppleScript(shellCommand: "/bin/true", prompt: bad)
                require(false, "FAIL [appleScript]: expected throw for bad prompt")
            } catch SudoPAMCommandBuilderError.invalidControlCharacter {
                // Expected
            } catch {
                require(false, "FAIL [appleScript]: unexpected error \(error)")
            }
        }

        // Verify AppleScript compiles cleanly with /usr/bin/osacompile (offline, no UI prompt)
        let tmpDir = makeTempDir(prefix: "glance-osacompile")
        defer { removeItemIfExists(tmpDir) }
        let scptOut = tmpDir.appendingPathComponent("test.scpt")
        let compileResult = runExecutable(
            "/usr/bin/osacompile",
            arguments: ["-o", scptOut.path, "-e", appleScript]
        )
        require(
            compileResult.status == 0,
            "FAIL [osacompile]: AppleScript syntax check failed (\(compileResult.status)): \(compileResult.stderr)"
        )
    }

    private static func testClassifyAppleScriptError() {
        require(
            SudoPAMCommandBuilder.classifyAppleScriptError(
                errorNumber: -128,
                briefMessage: "User canceled.",
                fullMessage: "User canceled."
            ) == .cancelled,
            "FAIL [classify]: -128 must map to .cancelled"
        )

        let tccApp = SudoPAMCommandBuilder.classifyAppleScriptError(
            errorNumber: 1,
            briefMessage: "mv: /Applications/Glance.app: Operation not permitted",
            fullMessage: "full details"
        )
        guard case .needsAppManagementPermission = tccApp else {
            require(false, "FAIL [classify]: expected .needsAppManagementPermission, got \(tccApp)")
            return
        }

        let tccCaseInsensitiveSplit = SudoPAMCommandBuilder.classifyAppleScriptError(
            errorNumber: 1,
            briefMessage: "Command failed",
            fullMessage: "cannot replace glance.app: operation not permitted"
        )
        guard case .needsAppManagementPermission = tccCaseInsensitiveSplit else {
            require(
                false,
                "FAIL [classify]: expected case-insensitive split .needsAppManagementPermission, got \(tccCaseInsensitiveSplit)"
            )
            return
        }

        let unrelatedPerm = SudoPAMCommandBuilder.classifyAppleScriptError(
            errorNumber: 1,
            briefMessage: "cp: /etc/pam.d/sudo_local: Operation not permitted",
            fullMessage: "verbose full message"
        )
        require(
            unrelatedPerm == .failed("cp: /etc/pam.d/sudo_local: Operation not permitted"),
            "FAIL [classify]: unrelated Operation not permitted should be .failed with briefMessage, got \(unrelatedPerm)"
        )

        let briefPreferred = SudoPAMCommandBuilder.classifyAppleScriptError(
            errorNumber: 2,
            briefMessage: "Short error",
            fullMessage: "Very long verbose AppleScript message"
        )
        require(
            briefPreferred == .failed("Short error"),
            "FAIL [classify]: should prefer briefMessage, got \(briefPreferred)"
        )

        let fallbackFull = SudoPAMCommandBuilder.classifyAppleScriptError(
            errorNumber: 2,
            briefMessage: "   \n ",
            fullMessage: "Full fallback message"
        )
        require(
            fallbackFull == .failed("Full fallback message"),
            "FAIL [classify]: should fall back to fullMessage, got \(fallbackFull)"
        )

        let fallbackEmpty = SudoPAMCommandBuilder.classifyAppleScriptError(
            errorNumber: 42,
            briefMessage: nil,
            fullMessage: ""
        )
        if case .failed(let msg) = fallbackEmpty {
            require(!msg.isEmpty, "FAIL [classify]: fallback message must be non-empty")
        } else {
            require(false, "FAIL [classify]: expected .failed fallback, got \(fallbackEmpty)")
        }
    }

    private static func testManualCommands() {
        let externalBundle = "/Users/O'Brien/Downloads/Glance (1)/Glance.app"

        let noReloc = SudoPAMCommandBuilder.manualInstallCommand(
            bundlePath: externalBundle,
            requiresRelocation: false
        )
        require(
            noReloc
                == "sudo /bin/bash '/Applications/Glance.app/Contents/Resources/glance-sudo-setup.sh' "
                + "install --pam-source '/Applications/Glance.app/Contents/Helpers/pam_glance.so'",
            "FAIL [manualInstall]: requiresRelocation=false mismatch: \(noReloc)"
        )

        let withReloc = SudoPAMCommandBuilder.manualInstallCommand(
            bundlePath: externalBundle,
            requiresRelocation: true
        )
        require(
            withReloc
                == "sudo /bin/bash "
                + "'/Users/O'\\''Brien/Downloads/Glance (1)/Glance.app/Contents/Resources/glance-sudo-setup.sh' "
                + "install --pam-source "
                + "'/Users/O'\\''Brien/Downloads/Glance (1)/Glance.app/Contents/Helpers/pam_glance.so' "
                + "--app-source '/Users/O'\\''Brien/Downloads/Glance (1)/Glance.app'",
            "FAIL [manualInstall]: requiresRelocation=true mismatch: \(withReloc)"
        )

        let uninstall = SudoPAMCommandBuilder.manualUninstallCommand(bundlePath: externalBundle)
        require(
            uninstall
                == "sudo /bin/bash "
                + "'/Users/O'\\''Brien/Downloads/Glance (1)/Glance.app/Contents/Resources/glance-sudo-setup.sh' "
                + #"uninstall --restore-owner "$(id -u):$(id -g)""#,
            "FAIL [manualUninstall]: mismatch: \(uninstall)"
        )
    }

    // MARK: - SudoPAMStatus probe tests

    private static func testPAMStatusProbe() {
        require(
            SudoPAMStatus.pamModulePath == "/usr/local/lib/pam/pam_glance.so",
            "FAIL [probeConst]: unexpected pamModulePath"
        )
        require(
            SudoPAMStatus.pamConfigPath == "/etc/pam.d/sudo_local",
            "FAIL [probeConst]: unexpected pamConfigPath"
        )
        require(
            SudoPAMStatus.trustedBundlePath == "/Applications/Glance.app",
            "FAIL [probeConst]: unexpected trustedBundlePath"
        )
        require(
            SudoPAMStatus.trustedExecutablePath == "/Applications/Glance.app/Contents/MacOS/glance",
            "FAIL [probeConst]: unexpected trustedExecutablePath"
        )

        testProbeModuleInstalledOutdatedAndUnsafePermissions()
        testProbeRunningOutsideApplicationsAndMissing()
        testProbeWrongCasingAndSetupActionPrecedence()
        testProbeSudoLocalOrderingAndComments()
        testProbeCanUninstallAndBundledHelpers()
    }

    private static func testProbeModuleInstalledOutdatedAndUnsafePermissions() {
        let root = makeTempDir(prefix: "glance-probe-case1")
        defer { removeItemIfExists(root) }

        let appsDir = root.appendingPathComponent("Applications", isDirectory: true)
        let appURL = appsDir.appendingPathComponent("Glance.app", isDirectory: true)
        let pamBytes = Data("pam-binary-v1".utf8)
        createFakeGlanceApp(at: appURL, pamHelperBytes: pamBytes, includeSetupScript: true)

        let pamDir = root.appendingPathComponent("usr/local/lib/pam", isDirectory: true)
        try! FileManager.default.createDirectory(at: pamDir, withIntermediateDirectories: true)
        let installedPAM = pamDir.appendingPathComponent("pam_glance.so")
        try! pamBytes.write(to: installedPAM)
        chmod(installedPAM.path, 0o755)

        let confDir = root.appendingPathComponent("etc/pam.d", isDirectory: true)
        try! FileManager.default.createDirectory(at: confDir, withIntermediateDirectories: true)
        let sudoLocal = confDir.appendingPathComponent("sudo_local")
        try! """
        auth       sufficient     /usr/local/lib/pam/pam_glance.so
        auth       sufficient     pam_tid.so
        """.appending("\n").write(to: sudoLocal, atomically: true, encoding: .utf8)

        let readyStatus = SudoPAMStatus.probe(
            pamModulePath: installedPAM.path,
            pamConfigPath: sudoLocal.path,
            trustedBundlePath: appURL.path,
            runningBundleURL: appURL,
            requireRootOwnership: false
        )
        require(readyStatus.module == .installed, "FAIL [probe1]: expected .installed, got \(readyStatus.module)")
        require(readyStatus.config == .configured, "FAIL [probe1]: expected .configured, got \(readyStatus.config)")
        require(
            readyStatus.trustedBinary == .verified,
            "FAIL [probe1]: expected .verified, got \(readyStatus.trustedBinary)"
        )
        require(readyStatus.hasBundledHelpers, "FAIL [probe1]: expected hasBundledHelpers == true")
        require(readyStatus.isInstalledArtifactPresent, "FAIL [probe1]: expected isInstalledArtifactPresent == true")
        require(readyStatus.setupAction == .ready, "FAIL [probe1]: expected .ready, got \(readyStatus.setupAction)")
        require(!readyStatus.requiresRelocation, "FAIL [probe1]: expected requiresRelocation == false")
        require(readyStatus.canUninstall, "FAIL [probe1]: expected canUninstall == true")

        // Modified installed pam_glance.so bytes -> .outdated / .update
        try! Data("pam-binary-older".utf8).write(to: installedPAM)
        chmod(installedPAM.path, 0o755)
        let outdatedStatus = SudoPAMStatus.probe(
            pamModulePath: installedPAM.path,
            pamConfigPath: sudoLocal.path,
            trustedBundlePath: appURL.path,
            runningBundleURL: appURL,
            requireRootOwnership: false
        )
        require(
            outdatedStatus.module == .outdated,
            "FAIL [probe1]: expected .outdated, got \(outdatedStatus.module)"
        )
        require(
            outdatedStatus.setupAction == .update,
            "FAIL [probe1]: expected .update, got \(outdatedStatus.setupAction)"
        )

        // Unsafe permissions (group/other writable) -> .unsafePermissions (not .outdated), .repair
        chmod(installedPAM.path, 0o777)
        let unsafeStatus = SudoPAMStatus.probe(
            pamModulePath: installedPAM.path,
            pamConfigPath: sudoLocal.path,
            trustedBundlePath: appURL.path,
            runningBundleURL: appURL,
            requireRootOwnership: false
        )
        require(
            unsafeStatus.module == .unsafePermissions,
            "FAIL [probe1]: expected .unsafePermissions, got \(unsafeStatus.module)"
        )
        require(
            unsafeStatus.setupAction == .repair,
            "FAIL [probe1]: expected .repair for unsafePermissions, got \(unsafeStatus.setupAction)"
        )
    }

    private static func testProbeRunningOutsideApplicationsAndMissing() {
        let root = makeTempDir(prefix: "glance-probe-case2")
        defer { removeItemIfExists(root) }

        let appsDir = root.appendingPathComponent("Applications", isDirectory: true)
        let trustedApp = appsDir.appendingPathComponent("Glance.app", isDirectory: true)
        let pamBytes = Data("pam-v2".utf8)
        createFakeGlanceApp(at: trustedApp, pamHelperBytes: pamBytes, includeSetupScript: true)

        let downloadsApp = root.appendingPathComponent("Downloads/Glance.app", isDirectory: true)
        createFakeGlanceApp(at: downloadsApp, pamHelperBytes: pamBytes, includeSetupScript: true)

        let pamDir = root.appendingPathComponent("usr/local/lib/pam", isDirectory: true)
        try! FileManager.default.createDirectory(at: pamDir, withIntermediateDirectories: true)
        let installedPAM = pamDir.appendingPathComponent("pam_glance.so")
        try! pamBytes.write(to: installedPAM)
        chmod(installedPAM.path, 0o755)

        let confDir = root.appendingPathComponent("etc/pam.d", isDirectory: true)
        try! FileManager.default.createDirectory(at: confDir, withIntermediateDirectories: true)
        let sudoLocal = confDir.appendingPathComponent("sudo_local")
        try! "auth       sufficient     /usr/local/lib/pam/pam_glance.so\n"
            .write(to: sudoLocal, atomically: true, encoding: .utf8)

        // Even with valid trustedApp, PAM module, and sudo_local on disk, running from Downloads must relocate
        let externalStatus = SudoPAMStatus.probe(
            pamModulePath: installedPAM.path,
            pamConfigPath: sudoLocal.path,
            trustedBundlePath: trustedApp.path,
            runningBundleURL: downloadsApp,
            requireRootOwnership: false
        )
        require(
            externalStatus.trustedBinary == .runningOutsideApplications,
            "FAIL [probe2]: expected .runningOutsideApplications, got \(externalStatus.trustedBinary)"
        )
        require(
            externalStatus.setupAction == .installAndRelocate,
            "FAIL [probe2]: expected .installAndRelocate, got \(externalStatus.setupAction)"
        )
        require(externalStatus.requiresRelocation, "FAIL [probe2]: expected requiresRelocation == true")

        // When runningBundleURL == trustedBundlePath on disk that doesn't exist -> .missing -> .installAndRelocate
        let missingTrustedApp = appsDir.appendingPathComponent("MissingGlance.app", isDirectory: true)
        let missingStatus = SudoPAMStatus.probe(
            pamModulePath: installedPAM.path,
            pamConfigPath: sudoLocal.path,
            trustedBundlePath: missingTrustedApp.path,
            runningBundleURL: missingTrustedApp,
            requireRootOwnership: false
        )
        require(
            missingStatus.trustedBinary == .missing,
            "FAIL [probe2]: expected .missing, got \(missingStatus.trustedBinary)"
        )
        require(
            missingStatus.setupAction == .installAndRelocate,
            "FAIL [probe2]: expected .installAndRelocate for .missing, got \(missingStatus.setupAction)"
        )
        require(missingStatus.requiresRelocation, "FAIL [probe2]: expected requiresRelocation == true for .missing")
    }

    private static func testProbeWrongCasingAndSetupActionPrecedence() {
        let root = makeTempDir(prefix: "glance-probe-case3")
        defer { removeItemIfExists(root) }

        let appsDir = root.appendingPathComponent("Applications", isDirectory: true)
        let lowercaseApp = appsDir.appendingPathComponent("glance.app", isDirectory: true)
        let expectedTrustedPath = appsDir.appendingPathComponent("Glance.app", isDirectory: true).path
        let pamBytes = Data("pam-v3".utf8)
        createFakeGlanceApp(at: lowercaseApp, pamHelperBytes: pamBytes, includeSetupScript: true)

        let missingPAM = root.appendingPathComponent("usr/local/lib/pam/pam_glance.so")
        let missingConf = root.appendingPathComponent("etc/pam.d/sudo_local")

        // Absent PAM & config with wrongCasing -> .install & requiresRelocation == true
        let cleanCasingStatus = SudoPAMStatus.probe(
            pamModulePath: missingPAM.path,
            pamConfigPath: missingConf.path,
            trustedBundlePath: expectedTrustedPath,
            runningBundleURL: lowercaseApp,
            requireRootOwnership: false
        )
        require(
            cleanCasingStatus.trustedBinary == .wrongCasing,
            "FAIL [probe3a]: expected .wrongCasing, got \(cleanCasingStatus.trustedBinary)"
        )
        require(cleanCasingStatus.requiresRelocation, "FAIL [probe3a]: expected requiresRelocation == true")
        require(
            cleanCasingStatus.setupAction == .install,
            "FAIL [probe3a]: expected .install when PAM/config absent, got \(cleanCasingStatus.setupAction)"
        )

        // Present PAM & config with wrongCasing -> .repair & requiresRelocation == true
        try! FileManager.default.createDirectory(
            at: missingPAM.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! pamBytes.write(to: missingPAM)
        chmod(missingPAM.path, 0o755)
        try! FileManager.default.createDirectory(
            at: missingConf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! "auth       sufficient     /usr/local/lib/pam/pam_glance.so\n"
            .write(to: missingConf, atomically: true, encoding: .utf8)

        let dirtyCasingStatus = SudoPAMStatus.probe(
            pamModulePath: missingPAM.path,
            pamConfigPath: missingConf.path,
            trustedBundlePath: expectedTrustedPath,
            runningBundleURL: lowercaseApp,
            requireRootOwnership: false
        )
        require(
            dirtyCasingStatus.trustedBinary == .wrongCasing,
            "FAIL [probe3b]: expected .wrongCasing, got \(dirtyCasingStatus.trustedBinary)"
        )
        require(dirtyCasingStatus.requiresRelocation, "FAIL [probe3b]: expected requiresRelocation == true")
        require(
            dirtyCasingStatus.setupAction == .repair,
            "FAIL [probe3b]: expected .repair when PAM/config present, got \(dirtyCasingStatus.setupAction)"
        )
    }

    private static func testProbeSudoLocalOrderingAndComments() {
        let root = makeTempDir(prefix: "glance-probe-case4")
        defer { removeItemIfExists(root) }

        let appsDir = root.appendingPathComponent("Applications", isDirectory: true)
        let appURL = appsDir.appendingPathComponent("Glance.app", isDirectory: true)
        let pamBytes = Data("pam-v4".utf8)
        createFakeGlanceApp(at: appURL, pamHelperBytes: pamBytes, includeSetupScript: true)

        let pamDir = root.appendingPathComponent("usr/local/lib/pam", isDirectory: true)
        try! FileManager.default.createDirectory(at: pamDir, withIntermediateDirectories: true)
        let installedPAM = pamDir.appendingPathComponent("pam_glance.so")
        try! pamBytes.write(to: installedPAM)
        chmod(installedPAM.path, 0o755)

        let confDir = root.appendingPathComponent("etc/pam.d", isDirectory: true)
        try! FileManager.default.createDirectory(at: confDir, withIntermediateDirectories: true)
        let sudoLocal = confDir.appendingPathComponent("sudo_local")

        // Before pam_tid.so -> .configured
        try! """
        # comment
        auth       sufficient     /usr/local/lib/pam/pam_glance.so
        auth       sufficient     pam_tid.so
        """.appending("\n").write(to: sudoLocal, atomically: true, encoding: .utf8)
        let beforeTid = SudoPAMStatus.probe(
            pamModulePath: installedPAM.path,
            pamConfigPath: sudoLocal.path,
            trustedBundlePath: appURL.path,
            runningBundleURL: appURL,
            requireRootOwnership: false
        )
        require(beforeTid.config == .configured, "FAIL [probe4]: expected .configured, got \(beforeTid.config)")

        // After pam_tid.so -> .configuredAfterTouchID, setupAction == .repair
        try! """
        auth       sufficient     pam_tid.so
        auth       sufficient     /usr/local/lib/pam/pam_glance.so
        """.appending("\n").write(to: sudoLocal, atomically: true, encoding: .utf8)
        let afterTid = SudoPAMStatus.probe(
            pamModulePath: installedPAM.path,
            pamConfigPath: sudoLocal.path,
            trustedBundlePath: appURL.path,
            runningBundleURL: appURL,
            requireRootOwnership: false
        )
        require(
            afterTid.config == .configuredAfterTouchID,
            "FAIL [probe4]: expected .configuredAfterTouchID, got \(afterTid.config)"
        )
        require(afterTid.setupAction == .repair, "FAIL [probe4]: expected .repair, got \(afterTid.setupAction)")

        // Commented out -> .notConfigured
        try! """
        # auth       sufficient     /usr/local/lib/pam/pam_glance.so
        auth       sufficient     pam_tid.so
        """.appending("\n").write(to: sudoLocal, atomically: true, encoding: .utf8)
        let commentedOut = SudoPAMStatus.probe(
            pamModulePath: installedPAM.path,
            pamConfigPath: sudoLocal.path,
            trustedBundlePath: appURL.path,
            runningBundleURL: appURL,
            requireRootOwnership: false
        )
        require(
            commentedOut.config == .notConfigured,
            "FAIL [probe4]: expected .notConfigured, got \(commentedOut.config)"
        )
    }

    private static func testProbeCanUninstallAndBundledHelpers() {
        let root = makeTempDir(prefix: "glance-probe-case5")
        defer { removeItemIfExists(root) }

        let appsDir = root.appendingPathComponent("Applications", isDirectory: true)
        let appURL = appsDir.appendingPathComponent("Glance.app", isDirectory: true)
        let pamBytes = Data("pam-v5".utf8)
        createFakeGlanceApp(at: appURL, pamHelperBytes: pamBytes, includeSetupScript: false)

        let pamDir = root.appendingPathComponent("usr/local/lib/pam", isDirectory: true)
        let installedPAM = pamDir.appendingPathComponent("pam_glance.so")
        let confDir = root.appendingPathComponent("etc/pam.d", isDirectory: true)
        let sudoLocal = confDir.appendingPathComponent("sudo_local")

        // Completely clean -> canUninstall == false, hasBundledHelpers == false (setup script missing)
        let clean = SudoPAMStatus.probe(
            pamModulePath: installedPAM.path,
            pamConfigPath: sudoLocal.path,
            trustedBundlePath: appURL.path,
            runningBundleURL: appURL,
            requireRootOwnership: false
        )
        require(!clean.isInstalledArtifactPresent, "FAIL [probe5]: clean isInstalledArtifactPresent must be false")
        require(!clean.isApplicationRootOwned, "FAIL [probe5]: non-root temp app must not be root-owned")
        require(clean.config == .notConfigured, "FAIL [probe5]: clean config must be .notConfigured")
        require(!clean.canUninstall, "FAIL [probe5]: clean canUninstall must be false")
        require(!clean.hasBundledHelpers, "FAIL [probe5]: missing setup script must make hasBundledHelpers false")
        require(clean.setupAction == .install, "FAIL [probe5]: clean setupAction must be .install")

        // Adding setup script enables hasBundledHelpers
        let scriptURL = SudoPAMStatus.bundledSetupScriptURL(in: appURL)
        try! Data("#!/bin/bash\n".utf8).write(to: scriptURL)
        let withHelpers = SudoPAMStatus.probe(
            pamModulePath: installedPAM.path,
            pamConfigPath: sudoLocal.path,
            trustedBundlePath: appURL.path,
            runningBundleURL: appURL,
            requireRootOwnership: false
        )
        require(withHelpers.hasBundledHelpers, "FAIL [probe5]: expected hasBundledHelpers == true")

        // Condition 1: only pam_glance.so present -> canUninstall == true
        try! FileManager.default.createDirectory(at: pamDir, withIntermediateDirectories: true)
        try! pamBytes.write(to: installedPAM)
        let pamOnly = SudoPAMStatus.probe(
            pamModulePath: installedPAM.path,
            pamConfigPath: sudoLocal.path,
            trustedBundlePath: appURL.path,
            runningBundleURL: appURL,
            requireRootOwnership: false
        )
        require(pamOnly.isInstalledArtifactPresent, "FAIL [probe5]: expected isInstalledArtifactPresent == true")
        require(pamOnly.canUninstall, "FAIL [probe5]: canUninstall must be true when pam_glance.so exists")
        removeItemIfExists(installedPAM)

        // Condition 2: only config != .notConfigured -> canUninstall == true
        try! FileManager.default.createDirectory(at: confDir, withIntermediateDirectories: true)
        try! "auth       sufficient     /usr/local/lib/pam/pam_glance.so\n"
            .write(to: sudoLocal, atomically: true, encoding: .utf8)
        let configOnly = SudoPAMStatus.probe(
            pamModulePath: installedPAM.path,
            pamConfigPath: sudoLocal.path,
            trustedBundlePath: appURL.path,
            runningBundleURL: appURL,
            requireRootOwnership: false
        )
        require(configOnly.config == .configured, "FAIL [probe5]: expected config == .configured")
        require(configOnly.canUninstall, "FAIL [probe5]: canUninstall must be true when config != .notConfigured")

        // Condition 3: only isApplicationRootOwned == true -> canUninstall == true
        let rootOwnedOnly = SudoPAMStatus(
            module: .notInstalled,
            config: .notConfigured,
            trustedBinary: .notRootOwned,
            hasBundledHelpers: true,
            isInstalledArtifactPresent: false,
            isApplicationRootOwned: true
        )
        require(
            rootOwnedOnly.canUninstall,
            "FAIL [probe5]: canUninstall must be true when isApplicationRootOwned == true"
        )
    }

    private static func testSetupScriptEndToEnd() {
        let scriptPath = resolveSetupScriptPath()
        require(
            FileManager.default.fileExists(atPath: scriptPath),
            "FAIL: setup script missing at \(scriptPath)"
        )

        testFreshInstallAndTemplateSeeding(scriptPath: scriptPath)
        testMisorderedDuplicateSudoLocalAndIdempotency(scriptPath: scriptPath)
        testAPFSTwoStepCasingRenameAndSamePathCheck(scriptPath: scriptPath)
        testRelocationAndCorruptedBundleRollback(scriptPath: scriptPath)
        testSymlinkRejections(scriptPath: scriptPath)
        testUninstallAndRestoreOwnerValidation(scriptPath: scriptPath)
        testNonRootRejectedWithoutTestRoot(scriptPath: scriptPath)
    }

    // MARK: - Case 1: Fresh install

    private static func testFreshInstallAndTemplateSeeding(scriptPath: String) {
        // 1a. Completely fresh root (no sudo_local, no sudo_local.template)
        do {
            let root = makeTempDir(prefix: "glance-setup-case1a")
            defer { removeItemIfExists(root) }

            let srcDir = makeTempDir(prefix: "glance-src-case1a")
            defer { removeItemIfExists(srcDir) }

            let pamBytes = Data([0xCF, 0xFA, 0xED, 0xFE, 0x01, 0x02, 0x03, 0x04])
            let pamSource = srcDir.appendingPathComponent("pam_glance.so")
            try! pamBytes.write(to: pamSource)

            let fakeApp = srcDir.appendingPathComponent("Glance.app", isDirectory: true)
            createFakeGlanceApp(at: fakeApp, pamHelperBytes: pamBytes, marker: "v1")
            setQuarantineXattr(on: fakeApp)
            setQuarantineXattr(on: fakeApp.appendingPathComponent("Contents/MacOS/glance"))

            let result = runSetupScript(
                scriptPath: scriptPath,
                arguments: [
                    "install",
                    "--pam-source", pamSource.path,
                    "--app-source", fakeApp.path,
                    "--test-root", root.path
                ]
            )
            require(result.status == 0, "FAIL [1a]: install exited \(result.status): \(result.stderr)")

            let installedApp = root.appendingPathComponent("Applications/Glance.app", isDirectory: true)
            assertNotSymlinkDirectory(installedApp, label: "[1a] installed Glance.app")
            assertExactChildName("Glance.app", in: root.appendingPathComponent("Applications"), label: "[1a]")
            assertNoHiddenTempEntries(
                in: root.appendingPathComponent("Applications"), prefix: ".Glance.app.", label: "[1a]")

            let installedExe = installedApp.appendingPathComponent("Contents/MacOS/glance")
            require(
                FileManager.default.isExecutableFile(atPath: installedExe.path),
                "FAIL [1a]: installed executable missing or non-executable"
            )
            assertNotWritableByGroupOrOther(installedApp, label: "[1a] Glance.app")
            assertNotWritableByGroupOrOther(installedExe, label: "[1a] glance binary")
            assertQuarantineRemoved(on: installedApp, label: "[1a] app")
            assertQuarantineRemoved(on: installedExe, label: "[1a] exe")

            let installedPAM = root.appendingPathComponent("usr/local/lib/pam/pam_glance.so")
            assertRegularFileMatching(installedPAM, expectedBytes: pamBytes, mode: 0o755, label: "[1a] pam_glance.so")
            assertNoHiddenTempEntries(
                in: root.appendingPathComponent("usr/local/lib/pam"), prefix: ".pam_glance.so.", label: "[1a]")

            let sudoLocal = root.appendingPathComponent("etc/pam.d/sudo_local")
            let confText = try! String(contentsOf: sudoLocal, encoding: .utf8)
            require(confText.hasSuffix("\n"), "FAIL [1a]: sudo_local missing trailing newline")
            require(
                confText.contains(expectedPAMLine),
                "FAIL [1a]: sudo_local missing expected PAM line:\n\(confText)"
            )
            assertFileMode(sudoLocal, expected: 0o644, label: "[1a] sudo_local")
            assertNoHiddenTempEntries(
                in: root.appendingPathComponent("etc/pam.d"), prefix: ".sudo_local.", label: "[1a]")
        }

        // 1b. Fresh install seeding from sudo_local.template with active pam_tid.so
        do {
            let root = makeTempDir(prefix: "glance-setup-case1b")
            defer { removeItemIfExists(root) }

            let pamDir = root.appendingPathComponent("etc/pam.d", isDirectory: true)
            try! FileManager.default.createDirectory(at: pamDir, withIntermediateDirectories: true)
            let templateURL = pamDir.appendingPathComponent("sudo_local.template")
            try! """
            # sudo_local: local customizations for sudo
            auth       sufficient     pam_tid.so
            """.appending("\n").write(to: templateURL, atomically: true, encoding: .utf8)

            let srcDir = makeTempDir(prefix: "glance-src-case1b")
            defer { removeItemIfExists(srcDir) }

            let pamBytes = Data("universal-pam-binary".utf8)
            let pamSource = srcDir.appendingPathComponent("pam_glance.so")
            try! pamBytes.write(to: pamSource)

            let fakeApp = srcDir.appendingPathComponent("Glance.app", isDirectory: true)
            createFakeGlanceApp(at: fakeApp, pamHelperBytes: pamBytes)

            let result = runSetupScript(
                scriptPath: scriptPath,
                arguments: [
                    "install",
                    "--pam-source", pamSource.path,
                    "--app-source", fakeApp.path,
                    "--test-root", root.path
                ]
            )
            require(result.status == 0, "FAIL [1b]: install exited \(result.status): \(result.stderr)")

            let sudoLocal = pamDir.appendingPathComponent("sudo_local")
            let lines = readNonEmptyLinesPreservingOrder(sudoLocal)
            require(
                lines == [
                    "# sudo_local: local customizations for sudo",
                    expectedPAMLine,
                    "auth       sufficient     pam_tid.so"
                ],
                "FAIL [1b]: unexpected sudo_local lines: \(lines)"
            )
        }
    }

    // MARK: - Case 2: Misordered/duplicate sudo_local + comments + no trailing newline + idempotency

    private static func testMisorderedDuplicateSudoLocalAndIdempotency(scriptPath: String) {
        let root = makeTempDir(prefix: "glance-setup-case2")
        defer { removeItemIfExists(root) }

        let existingApp = root.appendingPathComponent("Applications/Glance.app", isDirectory: true)
        createFakeGlanceApp(at: existingApp, pamHelperBytes: Data("helper".utf8))

        let pamConfDir = root.appendingPathComponent("etc/pam.d", isDirectory: true)
        try! FileManager.default.createDirectory(at: pamConfDir, withIntermediateDirectories: true)
        let sudoLocal = pamConfDir.appendingPathComponent("sudo_local")

        // Intentionally NO trailing newline, commented pam_tid.so, active pam_tid.so,
        // stale/duplicate pam_glance.so lines (including bracketed/tabbed), and an extra custom module.
        let malformed = [
            "# sudo_local: local customizations for sudo",
            "# auth       sufficient     pam_tid.so",
            "auth       sufficient     pam_tid.so",
            "auth       sufficient     /usr/local/lib/pam/pam_glance.so",
            "auth\t[success=done default=ignore]\t/opt/old/pam_glance.so",
            "auth       sufficient     pam_glance.so",
            "auth       optional       /usr/local/lib/pam/pam_custom.so"
        ].joined(separator: "\n")
        try! malformed.write(to: sudoLocal, atomically: true, encoding: .utf8)

        let srcDir = makeTempDir(prefix: "glance-src-case2")
        defer { removeItemIfExists(srcDir) }
        let pamBytes = Data("pam-binary-v2".utf8)
        let pamSource = srcDir.appendingPathComponent("pam_glance.so")
        try! pamBytes.write(to: pamSource)

        let firstRun = runSetupScript(
            scriptPath: scriptPath,
            arguments: [
                "install",
                "--pam-source", pamSource.path,
                "--test-root", root.path
            ]
        )
        require(firstRun.status == 0, "FAIL [2]: first install exited \(firstRun.status): \(firstRun.stderr)")

        let repairedText = try! String(contentsOf: sudoLocal, encoding: .utf8)
        require(repairedText.hasSuffix("\n"), "FAIL [2]: repaired sudo_local must end with trailing newline")

        let expectedLines = [
            "# sudo_local: local customizations for sudo",
            "# auth       sufficient     pam_tid.so",
            expectedPAMLine,
            "auth       sufficient     pam_tid.so",
            "auth       optional       /usr/local/lib/pam/pam_custom.so"
        ]
        let actualLines = repairedText.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(
            String.init)
        require(actualLines == expectedLines, "FAIL [2]: expected \(expectedLines), got \(actualLines)")

        let glanceLineCount = actualLines.filter { $0.contains("pam_glance.so") }.count
        require(glanceLineCount == 1, "FAIL [2]: expected exactly 1 pam_glance.so line, got \(glanceLineCount)")

        // Run a second time to verify idempotency.
        let secondRun = runSetupScript(
            scriptPath: scriptPath,
            arguments: [
                "install",
                "--pam-source", pamSource.path,
                "--test-root", root.path
            ]
        )
        require(secondRun.status == 0, "FAIL [2]: idempotent rerun exited \(secondRun.status): \(secondRun.stderr)")
        let afterRerunText = try! String(contentsOf: sudoLocal, encoding: .utf8)
        require(afterRerunText == repairedText, "FAIL [2]: rerun mutated sudo_local")

        // When only commented pam_tid.so exists, append pam_glance.so at the end (not before the comment).
        let commentedOnly = [
            "# sudo_local: local customizations for sudo",
            "#auth       sufficient     pam_tid.so",
            "auth       optional       /usr/local/lib/pam/pam_custom.so"
        ].joined(separator: "\n")
        try! commentedOnly.write(to: sudoLocal, atomically: true, encoding: .utf8)
        let commentedRun = runSetupScript(
            scriptPath: scriptPath,
            arguments: [
                "install",
                "--pam-source", pamSource.path,
                "--test-root", root.path
            ]
        )
        require(commentedRun.status == 0, "FAIL [2b]: commented-only install exited \(commentedRun.status)")
        let commentedText = try! String(contentsOf: sudoLocal, encoding: .utf8)
        require(commentedText.hasSuffix("\n"), "FAIL [2b]: missing trailing newline")
        let commentedActual = commentedText.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(
            String.init)
        require(
            commentedActual == [
                "# sudo_local: local customizations for sudo",
                "#auth       sufficient     pam_tid.so",
                "auth       optional       /usr/local/lib/pam/pam_custom.so",
                expectedPAMLine
            ],
            "FAIL [2b]: unexpected order for commented-only pam_tid.so: \(commentedActual)"
        )
    }

    // MARK: - Case 3: APFS two-step casing rename & same-path APFS check

    private static func testAPFSTwoStepCasingRenameAndSamePathCheck(scriptPath: String) {
        // 3a. No --app-source: existing lowercase glance.app -> two-step rename to Glance.app
        do {
            let root = makeTempDir(prefix: "glance-setup-case3a")
            defer { removeItemIfExists(root) }

            let appsDir = root.appendingPathComponent("Applications", isDirectory: true)
            let lowercaseApp = appsDir.appendingPathComponent("glance.app", isDirectory: true)
            createFakeGlanceApp(at: lowercaseApp, pamHelperBytes: Data("helper".utf8), marker: "keep-me")

            let srcDir = makeTempDir(prefix: "glance-src-case3a")
            defer { removeItemIfExists(srcDir) }
            let pamSource = srcDir.appendingPathComponent("pam_glance.so")
            try! Data("pam-v3a".utf8).write(to: pamSource)

            let result = runSetupScript(
                scriptPath: scriptPath,
                arguments: [
                    "install",
                    "--pam-source", pamSource.path,
                    "--test-root", root.path
                ]
            )
            require(result.status == 0, "FAIL [3a]: casing rename exited \(result.status): \(result.stderr)")

            assertExactChildName("Glance.app", in: appsDir, label: "[3a]")
            assertNoHiddenTempEntries(in: appsDir, prefix: ".Glance.app.", label: "[3a]")

            let renamedApp = appsDir.appendingPathComponent("Glance.app", isDirectory: true)
            let nestedLowercase = renamedApp.appendingPathComponent("glance.app")
            require(
                !FileManager.default.fileExists(atPath: nestedLowercase.path),
                "FAIL [3a]: nested glance.app was created inside Glance.app"
            )
            let marker = try! String(
                contentsOf: renamedApp.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8)
            require(marker == "keep-me", "FAIL [3a]: bundle contents altered during casing rename")
        }

        // 3b. --app-source points to <root>/Applications/Glance.app while on-disk entry is glance.app
        // On case-insensitive APFS, naive path comparison could falsely skip relocation!
        do {
            let root = makeTempDir(prefix: "glance-setup-case3b")
            defer { removeItemIfExists(root) }

            let appsDir = root.appendingPathComponent("Applications", isDirectory: true)
            let lowercaseApp = appsDir.appendingPathComponent("glance.app", isDirectory: true)
            let pamBytes = Data("pam-v3b".utf8)
            createFakeGlanceApp(at: lowercaseApp, pamHelperBytes: pamBytes, marker: "v3b")

            let pamSource = lowercaseApp.appendingPathComponent("Contents/Helpers/pam_glance.so")
            let requestedAppSource = appsDir.appendingPathComponent("Glance.app", isDirectory: true)

            let result = runSetupScript(
                scriptPath: scriptPath,
                arguments: [
                    "install",
                    "--pam-source", pamSource.path,
                    "--app-source", requestedAppSource.path,
                    "--test-root", root.path
                ]
            )
            require(result.status == 0, "FAIL [3b]: APFS same-dir casing fix exited \(result.status): \(result.stderr)")
            assertExactChildName("Glance.app", in: appsDir, label: "[3b]")
        }

        // 3c. --app-source already at exact <root>/Applications/Glance.app skips relocation cleanly
        do {
            let root = makeTempDir(prefix: "glance-setup-case3c")
            defer { removeItemIfExists(root) }

            let appsDir = root.appendingPathComponent("Applications", isDirectory: true)
            let exactApp = appsDir.appendingPathComponent("Glance.app", isDirectory: true)
            let pamBytes = Data("pam-v3c".utf8)
            createFakeGlanceApp(at: exactApp, pamHelperBytes: pamBytes, marker: "exact")

            let pamSource = exactApp.appendingPathComponent("Contents/Helpers/pam_glance.so")
            let result = runSetupScript(
                scriptPath: scriptPath,
                arguments: [
                    "install",
                    "--pam-source", pamSource.path,
                    "--app-source", exactApp.path,
                    "--test-root", root.path
                ]
            )
            require(result.status == 0, "FAIL [3c]: in-place install exited \(result.status): \(result.stderr)")
            assertExactChildName("Glance.app", in: appsDir, label: "[3c]")
            let marker = try! String(
                contentsOf: exactApp.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8)
            require(marker == "exact", "FAIL [3c]: in-place bundle marker lost")
        }
    }

    // MARK: - Case 4: Relocation over existing app & corrupted bundle untouched rollback

    private static func testRelocationAndCorruptedBundleRollback(scriptPath: String) {
        let root = makeTempDir(prefix: "glance-setup-case4")
        defer { removeItemIfExists(root) }

        let srcDir = makeTempDir(prefix: "glance-src-case4")
        defer { removeItemIfExists(srcDir) }

        let appsDir = root.appendingPathComponent("Applications", isDirectory: true)
        let existingApp = appsDir.appendingPathComponent("Glance.app", isDirectory: true)
        let v1Bytes = Data("pam-v1".utf8)
        createFakeGlanceApp(at: existingApp, pamHelperBytes: v1Bytes, marker: "v1")

        // Valid relocation v2 replaces v1 cleanly.
        let v2App = srcDir.appendingPathComponent("v2/Glance.app", isDirectory: true)
        let v2Bytes = Data("pam-v2".utf8)
        createFakeGlanceApp(at: v2App, pamHelperBytes: v2Bytes, marker: "v2")
        let v2Result = runSetupScript(
            scriptPath: scriptPath,
            arguments: [
                "install",
                "--pam-source", v2App.appendingPathComponent("Contents/Helpers/pam_glance.so").path,
                "--app-source", v2App.path,
                "--test-root", root.path
            ]
        )
        require(v2Result.status == 0, "FAIL [4]: valid relocation exited \(v2Result.status): \(v2Result.stderr)")

        let installedMarker = existingApp.appendingPathComponent("Contents/Resources/marker.txt")
        require((try! String(contentsOf: installedMarker, encoding: .utf8)) == "v2", "FAIL [4]: v2 marker mismatch")
        let installedPAM = root.appendingPathComponent("usr/local/lib/pam/pam_glance.so")
        assertRegularFileMatching(installedPAM, expectedBytes: v2Bytes, mode: 0o755, label: "[4] v2 pam")

        // 4a: Corrupted --app-source missing Contents/MacOS/glance
        let missingBinApp = srcDir.appendingPathComponent("missing-bin/Glance.app", isDirectory: true)
        createFakeGlanceApp(at: missingBinApp, pamHelperBytes: Data("evil".utf8), marker: "evil-bin")
        try! FileManager.default.removeItem(at: missingBinApp.appendingPathComponent("Contents/MacOS/glance"))

        let missingBinRes = runSetupScript(
            scriptPath: scriptPath,
            arguments: [
                "install",
                "--pam-source", missingBinApp.appendingPathComponent("Contents/Helpers/pam_glance.so").path,
                "--app-source", missingBinApp.path,
                "--test-root", root.path
            ]
        )
        require(missingBinRes.status != 0, "FAIL [4a]: missing binary --app-source unexpectedly succeeded")
        require(!missingBinRes.stderr.isEmpty, "FAIL [4a]: expected diagnostic on stderr")

        // 4b: Corrupted --app-source wrong CFBundleIdentifier
        let wrongIDApp = srcDir.appendingPathComponent("wrong-id/Glance.app", isDirectory: true)
        createFakeGlanceApp(
            at: wrongIDApp,
            bundleID: "com.example.notglance",
            pamHelperBytes: Data("evil".utf8),
            marker: "evil-id"
        )
        let wrongIDRes = runSetupScript(
            scriptPath: scriptPath,
            arguments: [
                "install",
                "--pam-source", wrongIDApp.appendingPathComponent("Contents/Helpers/pam_glance.so").path,
                "--app-source", wrongIDApp.path,
                "--test-root", root.path
            ]
        )
        require(wrongIDRes.status != 0, "FAIL [4b]: wrong bundle ID unexpectedly succeeded")
        require(!wrongIDRes.stderr.isEmpty, "FAIL [4b]: expected diagnostic on stderr")

        // 4c: Corrupted --app-source missing Contents/Helpers/pam_glance.so
        let missingHelperApp = srcDir.appendingPathComponent("missing-helper/Glance.app", isDirectory: true)
        createFakeGlanceApp(at: missingHelperApp, pamHelperBytes: Data("evil".utf8), marker: "evil-helper")
        try! FileManager.default.removeItem(
            at: missingHelperApp.appendingPathComponent("Contents/Helpers/pam_glance.so"))
        let missingHelperRes = runSetupScript(
            scriptPath: scriptPath,
            arguments: [
                "install",
                "--pam-source", v2App.appendingPathComponent("Contents/Helpers/pam_glance.so").path,
                "--app-source", missingHelperApp.path,
                "--test-root", root.path
            ]
        )
        require(missingHelperRes.status != 0, "FAIL [4c]: missing Helpers/pam_glance.so unexpectedly succeeded")

        // 4d: Mid-copy ditto failure (unreadable nested directory inside --app-source)
        let unreadableApp = srcDir.appendingPathComponent("unreadable/Glance.app", isDirectory: true)
        createFakeGlanceApp(at: unreadableApp, pamHelperBytes: Data("evil".utf8), marker: "evil-ditto")
        let lockedDir = unreadableApp.appendingPathComponent("Contents/Resources/locked", isDirectory: true)
        try! FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        try! Data("secret".utf8).write(to: lockedDir.appendingPathComponent("file.txt"))
        chmod(lockedDir.path, 0o000)
        defer { chmod(lockedDir.path, 0o755) }

        let dittoFailRes = runSetupScript(
            scriptPath: scriptPath,
            arguments: [
                "install",
                "--pam-source", unreadableApp.appendingPathComponent("Contents/Helpers/pam_glance.so").path,
                "--app-source", unreadableApp.path,
                "--test-root", root.path
            ]
        )
        require(dittoFailRes.status != 0, "FAIL [4d]: unreadable --app-source unexpectedly succeeded")

        // 4e: Missing/invalid --pam-source with valid --app-source on fresh root leaves zero half-installed state
        do {
            let freshRoot = makeTempDir(prefix: "glance-setup-case4e")
            defer { removeItemIfExists(freshRoot) }
            let emptyPAM = srcDir.appendingPathComponent("empty.so")
            try! Data().write(to: emptyPAM)
            let badPAMRes = runSetupScript(
                scriptPath: scriptPath,
                arguments: [
                    "install",
                    "--pam-source", emptyPAM.path,
                    "--app-source", v2App.path,
                    "--test-root", freshRoot.path
                ]
            )
            require(badPAMRes.status != 0, "FAIL [4e]: empty --pam-source must fail")
            require(
                !FileManager.default.fileExists(
                    atPath: freshRoot.appendingPathComponent("Applications/Glance.app").path),
                "FAIL [4e]: half-installed Glance.app created when --pam-source was invalid"
            )
        }

        // Verify existing v2 Glance.app and v2 pam_glance.so are completely untouched with zero temp artifacts!
        require(
            (try! String(contentsOf: installedMarker, encoding: .utf8)) == "v2",
            "FAIL [4]: existing app was modified on error"
        )
        require(
            FileManager.default.isExecutableFile(
                atPath: existingApp.appendingPathComponent("Contents/MacOS/glance").path),
            "FAIL [4]: existing glance binary lost"
        )
        assertRegularFileMatching(installedPAM, expectedBytes: v2Bytes, mode: 0o755, label: "[4] pam untouched")
        assertNoHiddenTempEntries(in: appsDir, prefix: ".Glance.app.", label: "[4] rollback cleanup")
    }

    // MARK: - Case 5: Symlink rejections

    private static func testSymlinkRejections(scriptPath: String) {
        // 5a. Symlinked --pam-source
        do {
            let root = makeTempDir(prefix: "glance-setup-case5a")
            defer { removeItemIfExists(root) }
            let srcDir = makeTempDir(prefix: "glance-src-case5a")
            defer { removeItemIfExists(srcDir) }

            let appsDir = root.appendingPathComponent("Applications", isDirectory: true)
            let existingApp = appsDir.appendingPathComponent("Glance.app", isDirectory: true)
            createFakeGlanceApp(at: existingApp, pamHelperBytes: Data("h".utf8))

            let realPAM = srcDir.appendingPathComponent("real_pam.so")
            try! Data("real-bytes".utf8).write(to: realPAM)
            let symlinkPAM = srcDir.appendingPathComponent("link_pam.so")
            try! FileManager.default.createSymbolicLink(at: symlinkPAM, withDestinationURL: realPAM)

            let res = runSetupScript(
                scriptPath: scriptPath,
                arguments: [
                    "install",
                    "--pam-source", symlinkPAM.path,
                    "--test-root", root.path
                ]
            )
            require(res.status != 0, "FAIL [5a]: symlinked --pam-source must be rejected")
            require(!res.stderr.isEmpty, "FAIL [5a]: expected stderr diagnostic")
            require(
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("usr/local/lib/pam/pam_glance.so").path),
                "FAIL [5a]: pam_glance.so was installed from symlinked source"
            )
        }

        // 5b. Symlinked <root>/Applications/Glance.app
        do {
            let root = makeTempDir(prefix: "glance-setup-case5b")
            defer { removeItemIfExists(root) }
            let srcDir = makeTempDir(prefix: "glance-src-case5b")
            defer { removeItemIfExists(srcDir) }

            let targetDir = srcDir.appendingPathComponent("Target.app", isDirectory: true)
            createFakeGlanceApp(at: targetDir, pamHelperBytes: Data("h".utf8), marker: "target")
            let targetMarker = targetDir.appendingPathComponent("Contents/Resources/marker.txt")
            chmod(targetMarker.path, 0o666)

            let appsDir = root.appendingPathComponent("Applications", isDirectory: true)
            try! FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
            let symlinkApp = appsDir.appendingPathComponent("Glance.app")
            try! FileManager.default.createSymbolicLink(at: symlinkApp, withDestinationURL: targetDir)

            let pamSource = srcDir.appendingPathComponent("pam_glance.so")
            try! Data("pam".utf8).write(to: pamSource)

            let res = runSetupScript(
                scriptPath: scriptPath,
                arguments: [
                    "install",
                    "--pam-source", pamSource.path,
                    "--test-root", root.path
                ]
            )
            require(res.status != 0, "FAIL [5b]: symlinked Applications/Glance.app must be rejected")
            require(!res.stderr.isEmpty, "FAIL [5b]: expected stderr diagnostic")

            var st = stat()
            require(lstat(symlinkApp.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK, "FAIL [5b]: symlink replaced")
            var targetStat = stat()
            require(
                lstat(targetMarker.path, &targetStat) == 0 && (targetStat.st_mode & 0o777) == 0o666,
                "FAIL [5b]: symlink target permissions were mutated!"
            )
        }

        // 5c. Symlinked --app-source and symlinked internal Contents/MacOS/glance
        do {
            let root = makeTempDir(prefix: "glance-setup-case5c")
            defer { removeItemIfExists(root) }
            let srcDir = makeTempDir(prefix: "glance-src-case5c")
            defer { removeItemIfExists(srcDir) }

            let realApp = srcDir.appendingPathComponent("Real.app", isDirectory: true)
            createFakeGlanceApp(at: realApp, pamHelperBytes: Data("pam".utf8))
            let symlinkApp = srcDir.appendingPathComponent("Symlink.app")
            try! FileManager.default.createSymbolicLink(at: symlinkApp, withDestinationURL: realApp)

            let res1 = runSetupScript(
                scriptPath: scriptPath,
                arguments: [
                    "install",
                    "--pam-source", realApp.appendingPathComponent("Contents/Helpers/pam_glance.so").path,
                    "--app-source", symlinkApp.path,
                    "--test-root", root.path
                ]
            )
            require(res1.status != 0, "FAIL [5c]: symlinked --app-source must be rejected")

            // Real dir with symlinked Contents/MacOS/glance
            let badBinApp = srcDir.appendingPathComponent("BadBin.app", isDirectory: true)
            createFakeGlanceApp(at: badBinApp, pamHelperBytes: Data("pam".utf8))
            let binPath = badBinApp.appendingPathComponent("Contents/MacOS/glance")
            try! FileManager.default.removeItem(at: binPath)
            try! FileManager.default.createSymbolicLink(
                at: binPath,
                withDestinationURL: realApp.appendingPathComponent("Contents/MacOS/glance")
            )

            let res2 = runSetupScript(
                scriptPath: scriptPath,
                arguments: [
                    "install",
                    "--pam-source", badBinApp.appendingPathComponent("Contents/Helpers/pam_glance.so").path,
                    "--app-source", badBinApp.path,
                    "--test-root", root.path
                ]
            )
            require(res2.status != 0, "FAIL [5c]: symlinked Contents/MacOS/glance must be rejected")
        }
    }

    // MARK: - Case 6: Uninstall & --restore-owner validation

    private static func testUninstallAndRestoreOwnerValidation(scriptPath: String) {
        let root = makeTempDir(prefix: "glance-setup-case6")
        defer { removeItemIfExists(root) }
        let srcDir = makeTempDir(prefix: "glance-src-case6")
        defer { removeItemIfExists(srcDir) }

        let pamBytes = Data("pam-install".utf8)
        let pamSource = srcDir.appendingPathComponent("pam_glance.so")
        try! pamBytes.write(to: pamSource)
        let fakeApp = srcDir.appendingPathComponent("Glance.app", isDirectory: true)
        createFakeGlanceApp(at: fakeApp, pamHelperBytes: pamBytes)

        let pamConfDir = root.appendingPathComponent("etc/pam.d", isDirectory: true)
        try! FileManager.default.createDirectory(at: pamConfDir, withIntermediateDirectories: true)
        let sudoLocal = pamConfDir.appendingPathComponent("sudo_local")
        try! """
        # sudo_local: local customizations for sudo
        # auth       sufficient     pam_tid.so
        auth       sufficient     pam_tid.so
        auth       optional       /usr/local/lib/pam/pam_custom.so
        """.appending("\n").write(to: sudoLocal, atomically: true, encoding: .utf8)

        let installRes = runSetupScript(
            scriptPath: scriptPath,
            arguments: [
                "install",
                "--pam-source", pamSource.path,
                "--app-source", fakeApp.path,
                "--test-root", root.path
            ]
        )
        require(installRes.status == 0, "FAIL [6]: setup before uninstall failed: \(installRes.stderr)")

        let installedPAM = root.appendingPathComponent("usr/local/lib/pam/pam_glance.so")
        require(
            FileManager.default.fileExists(atPath: installedPAM.path),
            "FAIL [6]: pam_glance.so missing before uninstall"
        )

        // Invalid --restore-owner inputs must fail without deleting pam_glance.so
        for badOwner in ["0:0", "root:wheel", "0:20", "501", "501:", ":20", "-1:20", "abc:20"] {
            let badRes = runSetupScript(
                scriptPath: scriptPath,
                arguments: [
                    "uninstall",
                    "--restore-owner", badOwner,
                    "--test-root", root.path
                ]
            )
            require(badRes.status != 0, "FAIL [6]: invalid --restore-owner '\(badOwner)' unexpectedly succeeded")
            require(!badRes.stderr.isEmpty, "FAIL [6]: expected stderr for invalid --restore-owner '\(badOwner)'")
            require(
                FileManager.default.fileExists(atPath: installedPAM.path),
                "FAIL [6]: pam_glance.so was deleted despite invalid --restore-owner '\(badOwner)'"
            )
        }

        // Make installed app read-only to confirm uninstall restores u+w
        let installedApp = root.appendingPathComponent("Applications/Glance.app", isDirectory: true)
        let markerFile = installedApp.appendingPathComponent("Contents/Resources/marker.txt")
        chmod(markerFile.path, 0o444)

        let uninstallRes = runSetupScript(
            scriptPath: scriptPath,
            arguments: [
                "uninstall",
                "--restore-owner", "501:20",
                "--test-root", root.path
            ]
        )
        require(
            uninstallRes.status == 0, "FAIL [6]: valid uninstall exited \(uninstallRes.status): \(uninstallRes.stderr)")
        require(
            !FileManager.default.fileExists(atPath: installedPAM.path),
            "FAIL [6]: pam_glance.so still exists after uninstall"
        )

        let afterConf = try! String(contentsOf: sudoLocal, encoding: .utf8)
        require(afterConf.hasSuffix("\n"), "FAIL [6]: sudo_local missing trailing newline after uninstall")
        let afterLines = afterConf.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        require(
            afterLines == [
                "# sudo_local: local customizations for sudo",
                "# auth       sufficient     pam_tid.so",
                "auth       sufficient     pam_tid.so",
                "auth       optional       /usr/local/lib/pam/pam_custom.so"
            ],
            "FAIL [6]: unexpected sudo_local after uninstall: \(afterLines)"
        )

        var markerStat = stat()
        require(
            lstat(markerFile.path, &markerStat) == 0 && (markerStat.st_mode & mode_t(S_IWUSR)) != 0,
            "FAIL [6]: uninstall did not restore user write bit (u+w)"
        )

        // Idempotent second uninstall
        let secondUninstall = runSetupScript(
            scriptPath: scriptPath,
            arguments: [
                "uninstall",
                "--test-root", root.path
            ]
        )
        require(
            secondUninstall.status == 0,
            "FAIL [6]: idempotent second uninstall failed: \(secondUninstall.stderr)"
        )

        // Uninstall --restore-owner must refuse symlinked Glance.app without mutating target
        do {
            let linkRoot = makeTempDir(prefix: "glance-setup-case6link")
            defer { removeItemIfExists(linkRoot) }
            let targetDir = srcDir.appendingPathComponent("UninstallTarget.app", isDirectory: true)
            createFakeGlanceApp(at: targetDir, pamHelperBytes: pamBytes)
            let targetMarker = targetDir.appendingPathComponent("Contents/Resources/marker.txt")
            chmod(targetMarker.path, 0o444)

            let linkAppsDir = linkRoot.appendingPathComponent("Applications", isDirectory: true)
            try! FileManager.default.createDirectory(at: linkAppsDir, withIntermediateDirectories: true)
            try! FileManager.default.createSymbolicLink(
                at: linkAppsDir.appendingPathComponent("Glance.app"),
                withDestinationURL: targetDir
            )

            let linkRes = runSetupScript(
                scriptPath: scriptPath,
                arguments: [
                    "uninstall",
                    "--restore-owner", "501:20",
                    "--test-root", linkRoot.path
                ]
            )
            require(linkRes.status != 0, "FAIL [6]: uninstall --restore-owner on symlinked Glance.app must fail")
            var targetStat = stat()
            require(
                lstat(targetMarker.path, &targetStat) == 0 && (targetStat.st_mode & 0o777) == 0o444,
                "FAIL [6]: symlink target permissions were mutated during uninstall"
            )
        }
    }

    // MARK: - Case 7: Non-root rejection without --test-root

    private static func testNonRootRejectedWithoutTestRoot(scriptPath: String) {
        guard getuid() != 0 else { return }

        let srcDir = makeTempDir(prefix: "glance-src-case7")
        defer { removeItemIfExists(srcDir) }
        let pamSource = srcDir.appendingPathComponent("pam_glance.so")
        try! Data("pam".utf8).write(to: pamSource)

        let installRes = runSetupScript(
            scriptPath: scriptPath,
            arguments: [
                "install",
                "--pam-source", pamSource.path
            ]
        )
        require(installRes.status != 0, "FAIL [7]: install without --test-root as non-root must fail")
        require(
            installRes.stderr.lowercased().contains("root") || installRes.stderr.contains("EUID"),
            "FAIL [7]: expected clear root-required error on stderr, got: \(installRes.stderr)"
        )

        let uninstallRes = runSetupScript(
            scriptPath: scriptPath,
            arguments: ["uninstall"]
        )
        require(uninstallRes.status != 0, "FAIL [7]: uninstall without --test-root as non-root must fail")
        require(
            uninstallRes.stderr.lowercased().contains("root") || uninstallRes.stderr.contains("EUID"),
            "FAIL [7]: expected clear root-required error on stderr for uninstall, got: \(uninstallRes.stderr)"
        )

        // CLI validation edge cases with --test-root
        let root = makeTempDir(prefix: "glance-setup-case7cli")
        defer { removeItemIfExists(root) }
        for badArgs in [
            [],
            ["bogus", "--test-root", root.path],
            ["install", "--test-root", root.path],
            ["install", "--pam-source", pamSource.path, "--restore-owner", "501:20", "--test-root", root.path],
            ["uninstall", "--pam-source", pamSource.path, "--test-root", root.path],
            [
                "install", "--pam-source", pamSource.path, "--app-source", "relative/Glance.app", "--test-root",
                root.path
            ],
            ["install", "--pam-source", pamSource.path, "--app-source", "/tmp/NotAnApp", "--test-root", root.path],
            ["install", "--pam-source", pamSource.path, "--test-root", root.appendingPathComponent("missing").path]
        ] {
            let res = runSetupScript(scriptPath: scriptPath, arguments: badArgs)
            require(res.status != 0, "FAIL [7cli]: invalid args \(badArgs) unexpectedly succeeded")
            require(!res.stderr.isEmpty, "FAIL [7cli]: expected stderr for invalid args \(badArgs)")
        }
    }

    // MARK: - Helpers

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs(message + "\n", Darwin.stderr)
            exit(1)
        }
    }

    private static func resolveSetupScriptPath() -> String {
        let cwdPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("sudo-support/glance-sudo-setup.sh").path
        if FileManager.default.fileExists(atPath: cwdPath) {
            return cwdPath
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent("sudo-support/glance-sudo-setup.sh").path
    }

    private static func makeTempDir(prefix: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func removeItemIfExists(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func createFakeGlanceApp(
        at bundleURL: URL,
        bundleID: String = expectedBundleID,
        pamHelperBytes: Data,
        marker: String = "default",
        includeSetupScript: Bool = false
    ) {
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)

        for dir in [macos, helpers, resources] {
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let bin = macos.appendingPathComponent("glance")
        try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: bin)
        chmod(bin.path, 0o755)

        let helper = helpers.appendingPathComponent("pam_glance.so")
        try! pamHelperBytes.write(to: helper)
        chmod(helper.path, 0o755)

        if includeSetupScript {
            let setupScript = resources.appendingPathComponent("glance-sudo-setup.sh")
            try! Data("#!/bin/bash\nexit 0\n".utf8).write(to: setupScript)
            chmod(setupScript.path, 0o644)
        }

        let markerFile = resources.appendingPathComponent("marker.txt")
        try! Data(marker.utf8).write(to: markerFile)

        let infoPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleIdentifier</key>
                <string>\(bundleID)</string>
                <key>CFBundleExecutable</key>
                <string>glance</string>
            </dict>
            </plist>
            """
        try! infoPlist.write(
            to: contents.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func setQuarantineXattr(on url: URL) {
        let value = "0081;65555555;Safari;00000000-0000-0000-0000-000000000000"
        _ = value.withCString { ptr in
            setxattr(url.path, "com.apple.quarantine", ptr, strlen(ptr), 0, XATTR_NOFOLLOW)
        }
    }

    private static func assertQuarantineRemoved(on url: URL, label: String) {
        let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        require(size < 0 && errno == ENOATTR, "FAIL \(label): com.apple.quarantine xattr still present")
    }

    private static func runSetupScript(
        scriptPath: String,
        arguments: [String]
    ) -> (status: Int32, stdout: String, stderr: String) {
        runExecutable("/bin/bash", arguments: [scriptPath] + arguments)
    }

    private static func runShellCommand(_ command: String) -> (status: Int32, stdout: String, stderr: String) {
        runExecutable("/bin/bash", arguments: ["-c", command])
    }

    private static func runExecutable(
        _ executablePath: String,
        arguments: [String]
    ) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()

        try! process.run()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    private static func assertNotSymlinkDirectory(_ url: URL, label: String) {
        var st = stat()
        require(lstat(url.path, &st) == 0, "FAIL \(label): lstat failed for \(url.path)")
        require((st.st_mode & S_IFMT) == S_IFDIR, "FAIL \(label): expected real directory at \(url.path)")
    }

    private static func assertNotWritableByGroupOrOther(_ url: URL, label: String) {
        var st = stat()
        require(lstat(url.path, &st) == 0, "FAIL \(label): lstat failed for \(url.path)")
        require(
            (st.st_mode & mode_t(S_IWGRP | S_IWOTH)) == 0,
            "FAIL \(label): unexpected group/other write bits \(String(st.st_mode & 0o777, radix: 8))"
        )
    }

    private static func assertFileMode(_ url: URL, expected: mode_t, label: String) {
        var st = stat()
        require(lstat(url.path, &st) == 0, "FAIL \(label): lstat failed for \(url.path)")
        require((st.st_mode & S_IFMT) == S_IFREG, "FAIL \(label): expected regular file at \(url.path)")
        require(
            (st.st_mode & 0o777) == expected,
            "FAIL \(label): expected mode \(String(expected, radix: 8)), got \(String(st.st_mode & 0o777, radix: 8))"
        )
    }

    private static func assertRegularFileMatching(_ url: URL, expectedBytes: Data, mode: mode_t, label: String) {
        assertFileMode(url, expected: mode, label: label)
        let actual = try! Data(contentsOf: url)
        require(actual == expectedBytes, "FAIL \(label): file bytes do not match source")
    }

    private static func assertExactChildName(_ expected: String, in directory: URL, label: String) {
        let entries = try! FileManager.default.contentsOfDirectory(atPath: directory.path)
        require(entries.contains(expected), "FAIL \(label): expected exact entry '\(expected)' in \(entries)")
    }

    private static func assertNoHiddenTempEntries(in directory: URL, prefix: String, label: String) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let leftovers = entries.filter { $0.hasPrefix(prefix) }
        require(leftovers.isEmpty, "FAIL \(label): leftover temp entries in \(directory.path): \(leftovers)")
    }

    private static func readNonEmptyLinesPreservingOrder(_ url: URL) -> [String] {
        let text = try! String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
