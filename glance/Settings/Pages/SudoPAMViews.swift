//
//  SudoPAMViews.swift
//  glance
//
//  Reusable status/command row views and badge color mappings for `SudoSettingsPage`.
//

import SwiftUI

struct SudoStatusRow: View {
    let title: String
    let path: String
    let badgeText: String
    let badgeColor: Color

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SettingsMetrics.rowFont)
                    .foregroundStyle(SettingsMetrics.textPrimary)
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(SettingsMetrics.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 6, height: 6)
                Text(badgeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SettingsMetrics.textSecondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(SettingsMetrics.optionPreviewFill)
            .overlay(
                Capsule().strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
            )
            .clipShape(Capsule())
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, 9)
    }
}

struct SudoCommandRow: View {
    let title: String
    let subtitle: String
    let command: String
    let isCopied: Bool
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SettingsMetrics.rowFont)
                        .foregroundStyle(SettingsMetrics.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsMetrics.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: onCopy) {
                    Text(isCopied ? "Copied" : "Copy")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsMetrics.textPrimary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(SettingsMetrics.neutralButtonFill)
                        .overlay(
                            Capsule().strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(SettingsMetrics.textSecondary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SettingsMetrics.optionPreviewFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, 10)
    }
}

extension SudoPAMStatus.ModuleState {
    var color: Color {
        switch self {
        case .installed: return SettingsMetrics.qualityGoodColor
        case .outdated: return SettingsMetrics.qualityFairColor
        case .unsafePermissions: return SettingsMetrics.qualityPoorColor
        case .notInstalled: return SettingsMetrics.textTertiary
        }
    }
}

extension SudoPAMStatus.ConfigState {
    var color: Color {
        switch self {
        case .configured: return SettingsMetrics.qualityGoodColor
        case .configuredAfterTouchID: return SettingsMetrics.qualityFairColor
        case .notConfigured: return SettingsMetrics.textTertiary
        }
    }
}

extension SudoPAMStatus.BinaryState {
    var color: Color {
        switch self {
        case .verified: return SettingsMetrics.qualityGoodColor
        case .runningOutsideApplications, .wrongCasing, .notRootOwned:
            return SettingsMetrics.qualityFairColor
        case .missing: return SettingsMetrics.textTertiary
        }
    }
}
