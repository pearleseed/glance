//
//  AppLockCurtainView.swift
//  glance
//
//  Frosted-glass privacy curtain displayed over each window of a locked application.
//

import AppKit
import Observation
import SwiftUI

@Observable
@MainActor
final class AppLockCurtainViewModel {
    let appName: String
    let appIcon: NSImage
    var statusMessage: String
    var isScanning: Bool
    var canRetry: Bool
    var onRetry: (() -> Void)?
    var onUseSystemAuth: (() -> Void)?

    init(
        appName: String,
        appIcon: NSImage,
        statusMessage: String = "Looking for your face…",
        isScanning: Bool = true,
        canRetry: Bool = false,
        onRetry: (() -> Void)? = nil,
        onUseSystemAuth: (() -> Void)? = nil
    ) {
        self.appName = appName
        self.appIcon = appIcon
        self.statusMessage = statusMessage
        self.isScanning = isScanning
        self.canRetry = canRetry
        self.onRetry = onRetry
        self.onUseSystemAuth = onUseSystemAuth
    }
}

struct AppLockCurtainView: View {
    let model: AppLockCurtainViewModel
    let isPrimary: Bool
    let isFullscreen: Bool

    var body: some View {
        let cornerRadius: CGFloat = isFullscreen ? 0 : 12
        GeometryReader { proxy in
            ZStack {
                CurtainBackdropView(cornerRadius: cornerRadius)

                if isPrimary {
                    primaryContent(size: proxy.size)
                } else {
                    secondaryContent(size: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if !isFullscreen {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(SettingsMetrics.rowBorder, lineWidth: 1)
                }
            }
        }
    }

    @ViewBuilder
    private func primaryContent(size: CGSize) -> some View {
        let compact = size.width < 320 || size.height < 250
        let iconSize: CGFloat = compact ? 42 : 60

        VStack(spacing: compact ? 10 : 16) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: model.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .shadow(color: Color.black.opacity(0.28), radius: 8, y: 3)

                Image(systemName: "lock.fill")
                    .font(.system(size: compact ? 10 : 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(compact ? 4 : 5)
                    .background(Circle().fill(GlanceTheme.accent))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
                    .offset(x: 4, y: 4)
            }

            VStack(spacing: 4) {
                Text(model.appName)
                    .font(.system(size: compact ? 15 : 18, weight: .semibold))
                    .foregroundStyle(SettingsMetrics.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if model.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "faceid")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SettingsMetrics.textSecondary)
                    }

                    Text(model.statusMessage)
                        .font(.system(size: compact ? 11 : 13))
                        .foregroundStyle(SettingsMetrics.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: max(size.width - 40, 140))

            primaryActionButtons(compact: compact)
        }
        .padding(compact ? 14 : 24)
    }

    private func primaryActionButtons(compact: Bool) -> some View {
        HStack(spacing: 10) {
            if !model.isScanning && model.canRetry {
                Button {
                    model.onRetry?()
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(.system(size: compact ? 11 : 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, compact ? 11 : 14)
                        .padding(.vertical, compact ? 6 : 8)
                        .background(GlanceTheme.accent)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Button {
                model.onUseSystemAuth?()
            } label: {
                Label("Use Touch ID / Password", systemImage: "touchid")
                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                    .foregroundStyle(SettingsMetrics.textPrimary)
                    .padding(.horizontal, compact ? 11 : 14)
                    .padding(.vertical, compact ? 6 : 8)
                    .background(SettingsMetrics.neutralButtonFill)
                    .overlay(
                        Capsule()
                            .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                    )
                    .clipShape(Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func secondaryContent(size: CGSize) -> some View {
        let showTitle = size.width >= 200 && size.height >= 120
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: showTitle ? 22 : 16, weight: .medium))
                .foregroundStyle(SettingsMetrics.textSecondary)

            if showTitle {
                Text("\(model.appName) is locked")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SettingsMetrics.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
    }
}

private struct CurtainBackdropView: View {
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            ActiveBehindWindowBlurView()
            Rectangle()
                .fill(SettingsMetrics.windowTintColor)
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.65)
            Color(nsColor: .windowBackgroundColor)
                .opacity(0.58)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Always stays `.active` so behind-window blur blurs the locked app's real contents
/// even though Glance itself is not the active application.
private struct ActiveBehindWindowBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .hudWindow
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}
