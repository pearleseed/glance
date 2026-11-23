//
//  SettingsOptionPickers.swift
//  glance
//
//  Tile-based option pickers for Settings: unlock animation style, color,
//  liveness strength, and unlock triggers.
//

import AppKit
import SwiftUI

/// A row of `SettingsOptionTile`s with no chrome of its own — the option
/// picker's equivalent of `SettingsRowContent`. Drop directly inside a
/// `SettingsGroup`, or wrap in `SettingsOptionCard` for a standalone picker.
struct SettingsOptionRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: SettingsMetrics.optionItemSpacing) {
            content()
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, SettingsMetrics.optionCardVerticalPadding)
    }
}

/// `SettingsOptionRow` with its own card chrome, for a picker that stands
/// alone rather than connecting to a row above it.
struct SettingsOptionCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        SettingsOptionRow(content: content)
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                    .fill(SettingsMetrics.rowColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                    .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
            )
    }
}

/// A title (+ optional subtitle) on the leading edge and a trailing run of
/// fixed-width `SettingsOptionTile`s — for pickers compact enough to share
/// a row with their label. Drop directly inside a `SettingsGroup`.
struct SettingsLabeledOptionRow<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        // Top-aligned, and the vertical padding puts the title's first line
        // where a single-line `SettingsRowContent`'s title sits.
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SettingsMetrics.rowFont)
                    .foregroundStyle(SettingsMetrics.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsMetrics.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        // Same cap as `SettingsRowContent`'s Liveness
                        // detection subtitle, so both wrap at the same
                        // width instead of one stretching further than the
                        // other depending on how many tiles sit beside it.
                        .frame(maxWidth: SettingsMetrics.rowSubtitleMaxWidth, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 12)

            HStack(alignment: .top, spacing: SettingsMetrics.optionItemSpacing) {
                content()
            }
            // Tiles keep their size; a long subtitle wraps instead.
            .layoutPriority(1)
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, SettingsMetrics.optionCardVerticalPadding)
    }
}

/// One selectable preview tile: artwork on a filled rounded rect, a label
/// beneath, and an accent ring when selected. Selection is just a `Bool`, so
/// this serves single-select and multi-select pickers alike.
struct SettingsOptionTile<Preview: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    /// Defaults to the standard swatch height every other option picker
    /// uses; `UnlockAnimationPicker` passes a taller value so its artwork
    /// has real room — see `SettingsMetrics.unlockAnimationOptionPreviewSize`.
    var previewHeight: CGFloat = SettingsMetrics.optionPreviewHeight
    /// `nil` shares the row's width equally with sibling tiles; a value
    /// pins it, for tiles in a `SettingsLabeledOptionRow`.
    var previewWidth: CGFloat?
    @ViewBuilder var preview: () -> Preview

    /// Tint for artwork drawn as plain shapes, so tiles that don't supply
    /// their own coloring still read as selected/unselected.
    static func previewTint(isSelected: Bool) -> Color {
        isSelected
            ? SettingsMetrics.textPrimary.opacity(0.55)
            : SettingsMetrics.textSecondary.opacity(0.7)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview()
                    .frame(width: previewWidth)
                    .frame(maxWidth: previewWidth == nil ? .infinity : nil)
                    .frame(height: previewHeight)
                    .background {
                        SettingsMetrics.optionPreviewFill
                        if isSelected {
                            GlanceTheme.accent.opacity(SettingsMetrics.optionPreviewSelectedTintOpacity)
                        }
                    }
                    .clipShape(
                        RoundedRectangle(cornerRadius: SettingsMetrics.optionPreviewCornerRadius, style: .continuous)
                    )
                    // Shadow the filled tile alone — selection stroke is overlaid
                    // after so it never changes shadow weight across options.
                    .compositingGroup()
                    .shadow(
                        color: SettingsMetrics.optionPreviewShadowColor,
                        radius: SettingsMetrics.optionPreviewShadowRadius,
                        x: 0,
                        y: 0
                    )
                    .overlay(
                        // Outer black ring (dark mode only) — sits just outside
                        // the rowBorder stroke.
                        RoundedRectangle(
                            cornerRadius: SettingsMetrics.optionPreviewCornerRadius
                                + SettingsMetrics.optionPreviewOuterStrokeWidth,
                            style: .continuous
                        )
                        .strokeBorder(
                            SettingsMetrics.optionPreviewOuterStroke,
                            lineWidth: SettingsMetrics.optionPreviewOuterStrokeWidth
                        )
                        .padding(-SettingsMetrics.optionPreviewOuterStrokeWidth)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SettingsMetrics.optionPreviewCornerRadius, style: .continuous)
                            .strokeBorder(
                                SettingsMetrics.rowBorder,
                                lineWidth: SettingsMetrics.optionPreviewBorderWidth
                            )
                    )
                    .overlay {
                        if isSelected {
                            // Accent ring ~4pt outside the tile, in addition to
                            // the always-on rowBorder above.
                            let expansion =
                                SettingsMetrics.optionSelectionOutset
                                + SettingsMetrics.optionSelectionStrokeWidth
                            RoundedRectangle(
                                cornerRadius: SettingsMetrics.optionPreviewCornerRadius + expansion,
                                style: .continuous
                            )
                            .strokeBorder(
                                GlanceTheme.accent,
                                lineWidth: SettingsMetrics.optionSelectionStrokeWidth
                            )
                            .padding(-expansion)
                        }
                    }

                Text(title)
                    .font(SettingsMetrics.optionLabelFont)
                    .foregroundStyle(isSelected ? SettingsMetrics.textPrimary : SettingsMetrics.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: previewWidth)
            }
            .frame(maxWidth: previewWidth == nil ? .infinity : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@MainActor
private enum UnlockAnimationPreview {
    private static var activeTask: Task<Void, Never>?
    private static let holdDuration: Duration = .seconds(1.5)

    static func trigger(style: UnlockAnimationStyle) {
        activeTask?.cancel()
        NotchOverlayController.shared.present(styleOverride: style)
        activeTask = Task {
            try? await Task.sleep(for: holdDuration)
            guard !Task.isCancelled else { return }
            NotchOverlayController.shared.finish(success: true)
        }
    }
}

/// Unlock animation picker — connects, inside one `SettingsGroup`, to the
/// "Show animation" toggle above it (see `GeneralSettingsPage`).
struct UnlockAnimationPicker: View {
    @Binding var selection: UnlockAnimationStyle
    var color: UnlockAnimationColor = .blue
    var isEnabled: Bool = true

    var body: some View {
        SettingsLabeledOptionRow(
            title: "Style",
            subtitle: "The animation that appears when unlocking your Mac"
        ) {
            ForEach(UnlockAnimationStyle.selectableCases) { style in
                SettingsOptionTile(
                    title: style.title,
                    isSelected: selection == style,
                    action: {
                        selection = style
                        UnlockAnimationPreview.trigger(style: style)
                    },
                    previewHeight: SettingsMetrics.unlockAnimationOptionPreviewSize.height,
                    previewWidth: SettingsMetrics.unlockAnimationOptionPreviewSize.width,
                    preview: {
                        preview(for: style)
                    }
                )
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }

    /// A black pill (minimal) or rounded panel (original), each showing the
    /// real unlock animation's still frame.
    @ViewBuilder
    private func preview(for style: UnlockAnimationStyle) -> some View {
        switch style {
        case .minimal:
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 6)
                UnlockStillThumbnail(color: color)
                    .frame(width: 18, height: 18)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.black, in: Capsule(style: .continuous))
            .padding(.horizontal, 12)
        case .original:
            VStack {
                UnlockStillThumbnail(color: color)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.black, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .frame(width: 50, height: 50)
            .padding(.vertical, 10)
        case .none:
            EmptyView()
        }
    }
}

/// Unlock animation color picker — connects, inside one `SettingsGroup`, below
/// `UnlockAnimationPicker` (see `GeneralSettingsPage`).
struct UnlockAnimationColorPicker: View {
    @Binding var selection: UnlockAnimationColor
    var style: UnlockAnimationStyle = .original
    var isEnabled: Bool = true

    var body: some View {
        SettingsLabeledOptionRow(
            title: "Color",
            subtitle: "Color of the face scan and unlock animation"
        ) {
            ForEach(UnlockAnimationColor.allCases) { color in
                SettingsOptionTile(
                    title: color.title,
                    isSelected: selection == color,
                    action: {
                        selection = color
                        UnlockAnimationPreview.trigger(style: style)
                    },
                    previewHeight: SettingsMetrics.triggerOptionPreviewSize.height,
                    previewWidth: SettingsMetrics.triggerOptionPreviewSize.width,
                    preview: {
                        preview(for: color)
                    }
                )
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }

    @ViewBuilder
    private func preview(for color: UnlockAnimationColor) -> some View {
        switch color {
        case .blueToGreen:
            HStack(spacing: 4) {
                UnlockStillThumbnail(color: .blueToGreen, media: .idle)
                    .frame(width: 16, height: 16)
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
                UnlockStillThumbnail(color: .blueToGreen, media: .success)
                    .frame(width: 16, height: 16)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        case .blue, .green:
            UnlockStillThumbnail(color: color, media: .success)
                .padding(5)
                .frame(width: 30, height: 30)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
}

@MainActor
private struct UnlockStillThumbnail: View {
    nonisolated private struct CacheKey: Hashable {
        let color: UnlockAnimationColor
        let media: ScanMedia
    }

    private static let baseImage: NSImage? = {
        guard
            let url = Bundle.main.url(forResource: "unlockstatic-small", withExtension: "png")
                ?? Bundle.main.url(forResource: "unlockstatic", withExtension: "png")
        else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    private static var cache: [CacheKey: NSImage] = [:]

    var color: UnlockAnimationColor = .blue
    var media: ScanMedia = .success

    private static func cachedImage(for color: UnlockAnimationColor, media: ScanMedia) -> NSImage? {
        let key = CacheKey(color: color, media: media)
        if let cached = cache[key] {
            return cached
        }
        guard let baseImage else { return nil }
        let tinted = AnimationTint.apply(color.resolvedTintRGB(for: media), to: baseImage)
        cache[key] = tinted
        return tinted
    }

    var body: some View {
        if let tinted = Self.cachedImage(for: color, media: media) {
            Image(nsImage: tinted)
                .resizable()
                .scaledToFit()
        } else {
            Color.clear
        }
    }
}

/// Liveness depth picker — connects, inside one `SettingsGroup`, to the
/// "Liveness checks" toggle above it (see `RecognitionSettingsPage`). Same
/// title-left/tiles-right shape as `UnlockTriggerPicker`.
struct LivenessModePicker: View {
    @Binding var selection: LivenessMode
    var isEnabled: Bool = true

    var body: some View {
        SettingsLabeledOptionRow(
            title: "Strength",
            subtitle: "Light includes basic protection. Heavy requires you to blink or slightly move your head."
        ) {
            ForEach(LivenessMode.allCases) { mode in
                SettingsOptionTile(
                    title: mode.title,
                    isSelected: selection == mode,
                    action: { selection = mode },
                    previewHeight: SettingsMetrics.triggerOptionPreviewSize.height,
                    previewWidth: SettingsMetrics.triggerOptionPreviewSize.width,
                    preview: {
                        Image(systemName: iconName(for: mode))
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(SettingsOptionTile<EmptyView>.previewTint(isSelected: selection == mode))
                    }
                )
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }

    /// A half-filled shield for Light (it only screens *out* spoofs) versus
    /// a checked one for Heavy (it also demands positive proof of life).
    private func iconName(for mode: LivenessMode) -> String {
        switch mode {
        case .light: return "sun.min.fill"
        case .heavy: return "sun.max.fill"
        }
    }
}

/// Multi-select picker for what arms Face Unlock — connects, inside one
/// `SettingsGroup`, to the "Enable Face Unlock" toggle above it. Tiles
/// toggle rather than replace, but the last remaining selection is sticky:
/// with nothing selected the notch would never appear.
struct UnlockTriggerPicker: View {
    @Binding var selection: Set<UnlockTrigger>
    var isEnabled: Bool = true

    var body: some View {
        SettingsLabeledOptionRow(title: "Triggers", subtitle: "Select multiple") {
            ForEach(UnlockTrigger.allCases) { trigger in
                let isSelected = selection.contains(trigger)
                SettingsOptionTile(
                    title: trigger.title,
                    isSelected: isSelected,
                    action: { toggle(trigger, isSelected: isSelected) },
                    previewHeight: SettingsMetrics.triggerOptionPreviewSize.height,
                    previewWidth: SettingsMetrics.triggerOptionPreviewSize.width,
                    preview: {
                        Image(systemName: trigger.iconName)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(SettingsOptionTile<EmptyView>.previewTint(isSelected: isSelected))
                    }
                )
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }

    private func toggle(_ trigger: UnlockTrigger, isSelected: Bool) {
        guard isSelected else {
            selection.insert(trigger)
            return
        }
        // Deselecting the last one is a no-op rather than an error state.
        guard selection.count > 1 else { return }
        selection.remove(trigger)
    }
}
