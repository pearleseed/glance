//
//  OnboardingEnrollmentStepViews.swift
//  glance
//
//  Guided enrollment, naming, password, and completion step views for the
//  notch-hosted onboarding flow.
//

import AppKit
import SwiftUI

// MARK: - 6-8. Guided enrollment (camera + tick ring + camera-complete)

struct EnrollStepView: View {
    let controller: OnboardingController
    @Environment(\.notchPanelStyle) private var style

    var body: some View {
        VStack(spacing: 0) {
            cameraCluster
                .padding(.top, cameraTopPadding)
            Spacer(minLength: 8)
            instructionLabel
                .padding(.horizontal, OnboardingMetrics.enrollInstructionHorizontalPadding)
                .padding(.bottom, OnboardingMetrics.enrollInstructionBottomPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if showsCloseButton {
                EnrollmentCloseButton {
                    controller.back()
                }
                .padding(OnboardingMetrics.enrollCloseButtonEdgePadding)
            }
        }
        .background(GlanceTheme.panel)
    }

    private var showsCloseButton: Bool {
        !controller.enrollmentComplete && !controller.showCheckmark
    }

    private var cameraTopPadding: CGFloat {
        style == .pill
            ? OnboardingMetrics.enrollCameraTopPaddingPill
            : OnboardingMetrics.enrollCameraTopPaddingNotch
    }

    private var cameraCluster: some View {
        ZStack {
            EnrollmentRingView(controller: controller)

            CameraPreviewView(session: controller.camera.session, faces: [])
                .frame(
                    width: OnboardingMetrics.cameraCircleDiameter,
                    height: OnboardingMetrics.cameraCircleDiameter
                )
                .clipShape(Circle())
                .opacity(controller.cameraPreviewVisible ? 1 : 0)
                .animation(
                    .easeInOut(duration: OnboardingMetrics.previewFadeOut),
                    value: controller.cameraPreviewVisible
                )
                .overlay {
                    if controller.isTooFar && controller.cameraPreviewVisible && !controller.showCheckmark {
                        EnrollmentTooFarChevron()
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: controller.isTooFar)

            if controller.showCheckmark {
                AnimatedCheckmark(color: GlanceTheme.accent, lineWidth: 8)
                    .frame(width: 70, height: 59)
                    .transition(.opacity)
                    .padding(.top, 4)
            }
        }
        .frame(
            width: OnboardingMetrics.enrollCameraClusterDiameter,
            height: OnboardingMetrics.enrollCameraClusterDiameter
        )
    }

    private var instructionLabel: some View {
        Text(controller.enrollmentInstruction)
            .font(GlanceTheme.Font.instruction)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .id(controller.enrollmentInstruction)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: controller.enrollmentInstruction)
            .opacity(controller.guideVisible ? 1 : 0)
            .animation(
                .easeInOut(
                    duration: controller.guideVisible
                        ? OnboardingMetrics.enrollInstructionFadeIn
                        : OnboardingMetrics.enrollInstructionFadeOut
                ),
                value: controller.guideVisible
            )
    }
}

private struct EnrollmentCloseButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.8))
                .frame(
                    width: OnboardingMetrics.enrollCloseButtonSize,
                    height: OnboardingMetrics.enrollCloseButtonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Close")
    }
}

private struct EnrollmentTooFarChevron: View {
    @State private var isBouncing = false

    var body: some View {
        Group {
            if #available(macOS 15, *) {
                Image(systemName: "chevron.up.2")
                    .font(.system(size: OnboardingMetrics.enrollTooFarChevronSize, weight: .semibold))
                    .symbolEffect(.bounce.up.byLayer, options: .repeating)
            } else {
                VStack(spacing: -OnboardingMetrics.enrollTooFarChevronSize * 0.42) {
                    Image(systemName: "chevron.up")
                    Image(systemName: "chevron.up")
                }
                .font(.system(size: OnboardingMetrics.enrollTooFarChevronSize * 0.72, weight: .semibold))
                .offset(y: isBouncing ? -5 : 2)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                        isBouncing = true
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
        .accessibilityHidden(true)
    }
}

// MARK: - 9. Name

/// Asks who was just captured — for a recapture, pre-filled with the existing name so
/// this doubles as rename.
struct NameStepView: View {
    @Bindable var controller: OnboardingController

    private var trimmedName: String {
        controller.pendingName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name this face")
                .font(GlanceTheme.Font.title)
                .foregroundStyle(GlanceTheme.textPrimary)
                .padding(.leading, 4)

            Text("Used to tell enrolled faces apart when more than one person is set up on this Mac.")
                .font(GlanceTheme.Font.passwordCaption)
                .foregroundStyle(GlanceTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)

            Spacer(minLength: 2)

            PillTextField(placeholder: "Enter a name...", text: $controller.pendingName, autofocus: true) {
                controller.confirmName()
            }

            if let error = controller.nameError {
                Text(error)
                    .font(GlanceTheme.Font.rowDetail)
                    .foregroundStyle(GlanceTheme.statusDenied)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                PillButton(title: "Back", style: .secondary) {
                    controller.back()
                }
                PillButton(title: controller.nameStepPrimaryTitle, isEnabled: !trimmedName.isEmpty, isDefault: true) {
                    controller.confirmName()
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlanceTheme.panel)
    }
}

// MARK: - 10. Password

struct PasswordStepView: View {
    let controller: OnboardingController

    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter your password")
                .font(GlanceTheme.Font.title)
                .foregroundStyle(GlanceTheme.textPrimary)
                .padding(.leading, 4)

            Text(
                "Your password is required to unlock your Mac. It is encrypted and securely stored "
                    + "on your device. Glance works entirely offline, so your password never leaves your Mac."
            )
            .font(GlanceTheme.Font.passwordCaption)
            .foregroundStyle(GlanceTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 4)

            Spacer(minLength: 2)

            PillSecureField(placeholder: "Enter password...", text: $password, autofocus: true) {
                guard !password.isEmpty, !controller.isSavingPassword else { return }
                Task { _ = await controller.finish(password: password) }
            }

            if let error = controller.passwordError {
                Text(error)
                    .font(GlanceTheme.Font.rowDetail)
                    .foregroundStyle(GlanceTheme.statusDenied)
            }

            HStack(spacing: 10) {
                PillButton(title: "Back", style: .secondary) {
                    controller.back()
                }
                PillButton(
                    title: controller.isSavingPassword ? "Saving…" : "Confirm",
                    isEnabled: !password.isEmpty && !controller.isSavingPassword,
                    isDefault: true
                ) {
                    Task { _ = await controller.finish(password: password) }
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlanceTheme.panel)
    }
}

// MARK: - 11. Complete

struct CompleteStepView: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("You're all set")
                .font(GlanceTheme.Font.title)
                .foregroundStyle(GlanceTheme.textPrimary)
            Spacer(minLength: 4)
            AnimatedCheckmark(color: .white, lineWidth: 5)
                .frame(width: 20, height: 15)
        }
        .onboardingContentHorizontalPadding()
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(GlanceTheme.panel)
    }
}
