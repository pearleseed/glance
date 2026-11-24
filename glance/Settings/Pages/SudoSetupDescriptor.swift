//
//  SudoSetupDescriptor.swift
//  glance
//
//  Resolves the primary Setup card title, subtitle, and trailing button/badge
//  for `SudoSettingsPage` from live PAM status and session/model readiness.
//

import SwiftUI

/// Presentation descriptor for the primary row in `SudoSettingsPage`'s Setup card.
struct SudoSetupDescriptor {
    enum TrailingContent {
        case primaryButton(title: String, isSetupAction: Bool)
        case symbol(name: String, color: Color)
    }

    struct Context {
        let status: SudoPAMStatus
        let isSessionUnlocked: Bool
        let isUnlockingSession: Bool
        let hasActiveIdentities: Bool
        let hasUnlockCapableEmbedder: Bool
        let sudoFaceAuthEnabled: Bool
    }

    let title: String
    let subtitle: String
    let trailing: TrailingContent

    /// Maps live PAM installation state and runtime prerequisites to UI copy and action state.
    static func resolve(for context: Context) -> SudoSetupDescriptor {
        switch context.status.setupAction {
        case .installAndRelocate:
            return SudoSetupDescriptor(
                title: "Install Glance & Set Up Sudo",
                subtitle:
                    "Copies Glance to /Applications/Glance.app, installs the PAM module, "
                    + "configures sudo_local, and restarts Glance.",
                trailing: .primaryButton(title: "Set Up", isSetupAction: true)
            )
        case .install:
            return SudoSetupDescriptor(
                title: "Automatic Setup",
                subtitle:
                    "Installs the PAM module, configures /etc/pam.d/sudo_local, "
                    + "and secures /Applications/Glance.app.",
                trailing: .primaryButton(title: "Set Up", isSetupAction: true)
            )
        case .repair:
            return SudoSetupDescriptor(
                title: "Repair Sudo Setup",
                subtitle: "Restores root ownership, PAM configuration order, and safe permissions.",
                trailing: .primaryButton(title: "Repair", isSetupAction: true)
            )
        case .update:
            return SudoSetupDescriptor(
                title: "Update PAM Module",
                subtitle: "Updates /usr/local/lib/pam/pam_glance.so to match this version of Glance.",
                trailing: .primaryButton(title: "Update", isSetupAction: true)
            )
        case .ready:
            return resolveReadyDescriptor(for: context)
        }
    }

    private static func resolveReadyDescriptor(for context: Context) -> SudoSetupDescriptor {
        if !context.isSessionUnlocked {
            return SudoSetupDescriptor(
                title: "System setup complete",
                subtitle: "Unlock your Glance session to start using Face for sudo.",
                trailing: .primaryButton(
                    title: context.isUnlockingSession ? "Authenticating…" : "Unlock",
                    isSetupAction: false
                )
            )
        }
        if !context.hasActiveIdentities {
            return SudoSetupDescriptor(
                title: "System setup complete",
                subtitle: "Enroll or enable a face on the Face tab before testing sudo.",
                trailing: .symbol(name: "info.circle.fill", color: SettingsMetrics.textTertiary)
            )
        }
        if !context.hasUnlockCapableEmbedder {
            return SudoSetupDescriptor(
                title: "System setup complete",
                subtitle: "Discriminative face model is unavailable, so Face-for-sudo is disabled for safety.",
                trailing: .symbol(name: "exclamationmark.circle.fill", color: SettingsMetrics.qualityFairColor)
            )
        }
        if !context.sudoFaceAuthEnabled {
            return SudoSetupDescriptor(
                title: "System setup complete",
                subtitle: "Turn on Face authentication for sudo above, then run sudo -v in Terminal.",
                trailing: .symbol(name: "checkmark.circle.fill", color: SettingsMetrics.textSecondary)
            )
        }
        return SudoSetupDescriptor(
            title: "Ready for sudo",
            subtitle: "Everything is installed and active. Open Terminal and run sudo -v to test.",
            trailing: .symbol(name: "checkmark.circle.fill", color: SettingsMetrics.qualityGoodColor)
        )
    }
}
