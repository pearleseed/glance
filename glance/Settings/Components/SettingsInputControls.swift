//
//  SettingsInputControls.swift
//  glance
//
//  Interactive controls for Settings rows: toggles, sliders, menu pickers,
//  shortcut recorder, action buttons, and hold-to-confirm controls.
//

import AppKit
import SwiftUI

/// A trailing `Menu` rendered as a pill that hugs its label — the capsule
/// grows and shrinks with the current selection's text rather than sitting
/// at a fixed width. Shared by General's "Display on" row and Camera's
/// per-slot device pickers, so every dropdown in Settings looks the same.
struct SettingsMenuPickerPill<MenuContent: View>: View {
    let label: String
    @ViewBuilder var menuContent: () -> MenuContent

    var body: some View {
        Menu {
            menuContent()
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(SettingsMetrics.textPrimary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SettingsMetrics.textSecondary)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(SettingsMetrics.pickerPillFill))
            .overlay {
                Capsule()
                    .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
            }
            .contentShape(Capsule())
        }
        // `.button` + `.plain` renders the label as ordinary SwiftUI
        // content, so the capsule chrome and padding above are honored.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // Window-level accent tint otherwise paints the menu label blue.
        .tint(SettingsMetrics.textPrimary)
    }
}

/// Pill-shaped global shortcut recorder matching `SettingsMenuPickerPill`'s chrome.
/// Captures key-downs locally while `isRecording` is active: Escape cancels,
/// Delete/Backspace clears to `nil`, and any key with ⌘/⌃/⌥ saves and ends recording.
struct ShortcutRecorderPill: View {
    @Binding var shortcut: HotKeyShortcut?
    @Binding var isRecording: Bool

    @State private var keyMonitor: Any?

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(labelText)
                    .font(.system(size: 13, weight: isRecording ? .medium : .regular))
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                    .padding(.leading, 12)
                    .padding(.trailing, showsClearButton ? 6 : 12)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsClearButton {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsMetrics.textTertiary)
                        .padding(.trailing, 8)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear shortcut")
            }
        }
        .background(
            Capsule().fill(
                isRecording ? GlanceTheme.accent.opacity(0.14) : SettingsMetrics.pickerPillFill
            )
        )
        .overlay {
            Capsule()
                .strokeBorder(
                    isRecording ? GlanceTheme.accent : SettingsMetrics.rowBorder,
                    lineWidth: isRecording ? 1.5 : SettingsMetrics.rowBorderWidth
                )
        }
        .clipShape(Capsule())
        .fixedSize()
        .onChange(of: isRecording) { _, recording in
            if !recording {
                removeKeyMonitor()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var showsClearButton: Bool {
        shortcut != nil && !isRecording
    }

    private var labelText: String {
        if isRecording { return "Type shortcut…" }
        return shortcut?.displayString ?? "Record shortcut"
    }

    private var labelColor: Color {
        if isRecording { return GlanceTheme.accent }
        return shortcut == nil ? SettingsMetrics.textSecondary : SettingsMetrics.textPrimary
    }

    private func startRecording() {
        removeKeyMonitor()
        isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch HotKeyShortcut.classify(keyDownEvent: event) {
            case .cancel:
                stopRecording()
                return nil
            case .clear:
                shortcut = nil
                stopRecording()
                return nil
            case .assign(let newShortcut):
                shortcut = newShortcut
                stopRecording()
                return nil
            case .ignore:
                return nil
            }
        }
    }

    private func stopRecording() {
        removeKeyMonitor()
        if isRecording {
            isRecording = false
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

/// The system switch, so it picks up AppKit's own rendering rather than a
/// hand-drawn approximation. Only renders correctly because the window is
/// `.titled` and can become key — see `WindowConfiguringView.configure`;
/// a never-key window draws this desaturated and ignores `.tint`.
struct GlanceToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .tint(GlanceTheme.accent)
    }
}

/// A row combining a title/subtitle with a slider and its live numeric
/// value — used for the raw threshold controls on the Recognition page.
struct SettingsSlider: View {
    let title: String
    var subtitle: String?
    let value: Binding<Float>
    let range: ClosedRange<Float>
    var format: (Float) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SettingsMetrics.rowFont)
                        .foregroundStyle(SettingsMetrics.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsMetrics.textSecondary)
                    }
                }
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(SettingsMetrics.textSecondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Float($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            .tint(GlanceTheme.accent)
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, 10)
        .background(SettingsMetrics.rowColor)
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius))
    }
}

/// A row pairing a title/subtitle with an action button — used for "Redo
/// Face Enrollment", "Change Password", etc.
struct SettingsActionRow: View {
    let title: String
    var subtitle: String?
    let buttonTitle: String
    var isDestructive: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            SettingsActionButton(title: buttonTitle, isDestructive: isDestructive, isEnabled: isEnabled, action: action)
        }
    }
}

/// The un-chromed twin of `SettingsActionRow`, for dropping directly inside
/// a `SettingsGroup` alongside other rows.
struct SettingsActionRowContent: View {
    let title: String
    var subtitle: String?
    let buttonTitle: String
    var isDestructive: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        SettingsRowContent(title: title, subtitle: subtitle) {
            SettingsActionButton(title: buttonTitle, isDestructive: isDestructive, isEnabled: isEnabled, action: action)
        }
    }
}

/// The accent pill button both action-row flavors above render.
private struct SettingsActionButton: View {
    let title: String
    var isDestructive: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isDestructive ? Color.red.opacity(0.85) : GlanceTheme.accent)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// A grouped row whose control is a discrete slider: title on the leading
/// edge, the currently-selected option's label on the trailing edge, and
/// the slider itself beneath both. Sized by its content, not
/// `SettingsMetrics.rowHeight`, since it needs two stacked lines.
struct SettingsSteppedSliderRowContent: View {
    let title: String
    let valueLabel: String
    /// Index into the option list, not a real quantity — see `AutoLockInterval.sliderIndex`.
    @Binding var index: Double
    let stopCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(SettingsMetrics.rowFont)
                    .foregroundStyle(SettingsMetrics.textPrimary)
                Spacer(minLength: 8)
                Text(valueLabel)
                    .font(SettingsMetrics.rowFont)
                    .foregroundStyle(SettingsMetrics.textSecondary)
            }
            Slider(value: $index, in: 0...Double(max(stopCount - 1, 1)), step: 1)
                .controlSize(.regular)
                .tint(GlanceTheme.accent)
                .padding(.top, 8)
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, SettingsMetrics.sliderRowVerticalPadding)
    }
}

/// A grouped row whose control is a discrete slider with every stop's own
/// label laid out beneath it — leading/center/trailing for three — instead
/// of a single "current value" readout on the title line. Used by
/// Recognition's confidence and distance sliders, both of which snap to
/// three named stops.
struct SettingsOptionSliderRowContent: View {
    let title: String
    /// One label per stop, left-to-right; the first is leading-aligned, the
    /// last trailing-aligned, and any in between centered.
    let stepLabels: [String]
    /// Index into the option list, not a real quantity — see `AutoLockInterval.sliderIndex`.
    @Binding var index: Double
    let stopCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(SettingsMetrics.rowFont)
                .foregroundStyle(SettingsMetrics.textPrimary)
            // Tighter than the title-to-slider gap above, so the labels
            // read as annotating the slider's stops rather than floating a
            // full row's worth of space below it.
            VStack(alignment: .leading, spacing: 2) {
                Slider(value: $index, in: 0...Double(max(stopCount - 1, 1)), step: 1)
                    .controlSize(.regular)
                    .tint(GlanceTheme.accent)
                HStack {
                    ForEach(Array(stepLabels.enumerated()), id: \.offset) { position, label in
                        Text(label)
                            .font(.system(size: 13))
                            .foregroundStyle(SettingsMetrics.textTertiary)
                            .frame(maxWidth: .infinity, alignment: alignment(at: position))
                    }
                }
            }
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, SettingsMetrics.sliderRowVerticalPadding)
    }

    private func alignment(at position: Int) -> Alignment {
        if position == 0 { return .leading }
        if position == stepLabels.count - 1 { return .trailing }
        return .center
    }
}

/// A destructive button that only fires after being held down continuously,
/// filling with red left-to-right as confirmation of progress — used
/// instead of a confirmation dialog so the commitment is cancellable
/// mid-hold rather than a single easy-to-reflex click.
struct HoldToConfirmButton: View {
    let title: String
    var holdDuration: TimeInterval = 3
    let action: () -> Void

    @State private var fillProgress: CGFloat = 0

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(SettingsMetrics.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        SettingsMetrics.neutralButtonFill
                        // Plain rectangle, not a capsule — a capsule scaled
                        // down renders as a shrunken pill, not a growing edge.
                        Rectangle()
                            .fill(SettingsMetrics.destructiveFill)
                            .frame(width: proxy.size.width * fillProgress)
                    }
                }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: holdDuration) {
                action()
            } onPressingChanged: { isPressing in
                // The animation itself is the progress indicator, driven
                // purely off press state — no separate timer to drift out
                // of step with the gesture's `minimumDuration`.
                withAnimation(.linear(duration: isPressing ? holdDuration : 0.18)) {
                    fillProgress = isPressing ? 1 : 0
                }
            }
    }
}

/// Standalone accent-filled button matching `SettingsActionRow`'s trailing
/// button. Used both inside rows (`compact`) and on its own in centered
/// empty/locked states.
struct SettingsPrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    /// Row-height padding; `false` gives the roomier standalone size.
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 14 : 16)
                .padding(.vertical, compact ? 6 : 7)
                .background(GlanceTheme.accent)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}
