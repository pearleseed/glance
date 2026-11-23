//
//  SettingsRowControls.swift
//  glance
//
//  Layout primitives for the Settings window: section titles, captions,
//  empty states, grouped cards, and standard pill rows.
//

import SwiftUI

/// What a tab's icon actually is — a built-in SF Symbol, or a template
/// image from the asset catalog for marks with no SF Symbol equivalent.
enum SettingsTabIcon {
    case system(String)
    case asset(String)
}

/// Small "i" glyph that reveals a short explanation in a native popover on
/// tap. Drop it next to a row's title (see `SettingsRowContent.info`) or
/// standalone anywhere a setting needs a one-line explanation.
struct SettingsInfoButton: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(SettingsMetrics.textTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More information")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(SettingsMetrics.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 220, alignment: .leading)
                .padding(12)
        }
    }
}

/// One settings row: label (+ optional subtitle) on the leading edge,
/// arbitrary trailing control. Pill-shaped, 430x50, radius 17, translucent
/// fill + hairline border.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    /// Explanatory text for an inline `SettingsInfoButton`; `nil` renders no icon.
    var info: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        SettingsRowContent(title: title, subtitle: subtitle, info: info, trailing: trailing)
            .background(SettingsMetrics.rowColor)
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                    .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius))
    }
}

/// Inner label + trailing control shared by standalone rows and grouped cards.
struct SettingsRowContent<Trailing: View>: View {
    let title: String
    var subtitle: String?
    /// Caps the subtitle's width so it wraps instead of stretching toward
    /// the trailing control; `nil` (the default) leaves it unconstrained.
    var subtitleMaxWidth: CGFloat?
    /// Explanatory text for an inline `SettingsInfoButton`; `nil` renders no icon.
    var info: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(SettingsMetrics.rowFont)
                        .foregroundStyle(SettingsMetrics.textPrimary)
                    if let info {
                        SettingsInfoButton(text: info)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsMetrics.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: subtitleMaxWidth, alignment: .leading)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        // `minHeight`, not a fixed `height` — every existing (subtitle-less)
        // row still sizes to exactly `rowHeight`, but a wrapped subtitle can
        // grow the row taller instead of getting clipped.
        .frame(minHeight: SettingsMetrics.rowHeight)
        .padding(.vertical, subtitle == nil ? 0 : 10)
    }
}

/// Multiple `SettingsRowContent` rows in one card, separated by hairline
/// dividers that match `rowBorder`.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(SettingsMetrics.rowColor)
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius))
    }
}

/// Hairline between rows inside a `SettingsGroup`, inset to line up with
/// the rows' own text and trailing controls rather than the card's edges.
struct SettingsGroupDivider: View {
    var body: some View {
        Rectangle()
            .fill(SettingsMetrics.rowBorder)
            .frame(height: SettingsMetrics.rowBorderWidth)
            .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
    }
}

/// Centered icon + message + primary button — a settings page's "needs
/// unlocking" or "nothing set up yet" state. Shared by Password and Your
/// Face rather than each page keeping its own copy.
struct SettingsEmptyStateView: View {
    let icon: String
    let message: String
    let buttonTitle: String
    var isButtonEnabled: Bool = true
    var caption: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: SettingsMetrics.emptyStateSpacing) {
            Image(systemName: icon)
                .font(.system(size: SettingsMetrics.emptyStateIconSize, weight: .regular))
                .foregroundStyle(SettingsMetrics.textTertiary)

            Text(message)
                .font(SettingsMetrics.rowFont)
                .foregroundStyle(SettingsMetrics.textSecondary)

            SettingsPrimaryButton(title: buttonTitle, isEnabled: isButtonEnabled, action: action)

            if let caption {
                SettingsCaption(text: caption)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: SettingsMetrics.emptyStateMinHeight)
    }
}

/// Section caption used above a group of rows on a settings page (distinct
/// from the sidebar's own section headers).
struct SettingsCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(SettingsMetrics.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Left-aligned section title sitting above a settings card.
struct SettingsSectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(SettingsMetrics.sectionTitleFont)
            .foregroundStyle(SettingsMetrics.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, SettingsMetrics.sectionTitleHorizontalInset)
            .padding(.top, SettingsMetrics.sectionTitleVerticalPadding)
    }
}
