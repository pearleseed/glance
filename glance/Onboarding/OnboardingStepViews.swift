//
//  OnboardingStepViews.swift
//  glance
//
//  The screens of the notch-hosted onboarding flow. Each fills whatever panel size
//  OnboardingController reports for its step — sizing itself is the notch window's job.
//

import AppKit
import SwiftUI

// MARK: - 1. Intro

struct IntroStepView: View {
    let controller: OnboardingController

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Glance")
                    .font(GlanceTheme.Font.title)
                    .foregroundStyle(GlanceTheme.textPrimary)
                Text("Face Unlock for Mac")
                    .font(GlanceTheme.Font.button)
                    .foregroundStyle(GlanceTheme.textSecondary)

                Spacer(minLength: 12)

                PillButton(title: "Next") {
                    controller.advance()
                }
            }
            .padding(.leading, 4)
            Spacer(minLength: 4)
            GlanceLogoView()
                .frame(width: 106, height: 106)
                .padding(.top, 4)
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlanceTheme.panel)
        .onAppear {
            controller.playIntroSweepIfNeeded()
        }
    }
}

private struct GlanceLogoView: View {
    var body: some View {
        // Video already bakes in its own white rounded-card background — no extra chrome needed.
        LoopingVideoView(resourceName: "logoanimation")
    }
}

// MARK: - 2. Permissions

struct PermissionsStepView: View {
    let controller: OnboardingController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions")
                .font(GlanceTheme.Font.title)
                .foregroundStyle(GlanceTheme.textPrimary)
                .padding(.leading, 4)

            // Spacer(minLength: 0)

            PermissionRow(
                title: "Accessibility",
                detail: "Allow Glance to unlock your Mac",
                granted: controller.accessibilityGranted
            ) { controller.grantAccessibility() }

            PermissionRow(
                title: "Camera",
                detail: "Allow Glance to recognize your face",
                granted: controller.cameraPermission == .granted
            ) { controller.grantCamera() }

            // Spacer(minLength: 0)

            HStack(spacing: 10) {
                PillButton(title: "Back", style: .secondary) {
                    controller.back()
                }
                PillButton(title: "Next", isEnabled: controller.bothPermissionsGranted) {
                    controller.advance()
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlanceTheme.panel)
    }
}

// MARK: - 3. Security notice

struct SecurityNoticeStepView: View {
    let controller: OnboardingController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(GlanceTheme.textPrimary)
                .padding(.top, 25)
                .padding(.leading, 4)

            Text("Glance is not as secure as Apple's FaceID or TouchID.")
                .font(GlanceTheme.Font.title)
                .foregroundStyle(GlanceTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)

            Text(
                "It uses your Mac's standard webcam and is designed for convenience, not high-security authentication."
            )
            .font(GlanceTheme.Font.passwordCaption)
            .foregroundStyle(GlanceTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 4)
            .padding(.bottom, 10)

            HStack(spacing: 10) {
                if controller.isPostUpdateNotice {
                    // Declining isn't a real option here — see `declinePostUpdateNotice()`.
                    PillButton(title: "No thanks", style: .secondary) {
                        controller.declinePostUpdateNotice()
                    }
                } else {
                    PillButton(title: "Back", style: .secondary) {
                        controller.back()
                    }
                }
                PillButton(title: "I understand", isDefault: true) {
                    controller.advance()
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlanceTheme.panel)
    }
}

// MARK: - 4. Pre set-up

struct PreSetupStepView: View {
    let controller: OnboardingController

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .top, spacing: 2) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Set up Face\nRecognition")
                        .font(GlanceTheme.Font.title)
                        .foregroundStyle(GlanceTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Follow the directions\nshown on the screen")
                        .font(GlanceTheme.Font.button)
                        .foregroundStyle(GlanceTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)
                .padding(.leading, 4)
                Spacer(minLength: 0)
                UnlockGlyphView()
                    .frame(width: 120, height: 120)
            }
            Spacer(minLength: 4)

            HStack(spacing: 10) {
                PillButton(title: "Back", style: .secondary) {
                    controller.back()
                }
                PillButton(title: "Next") {
                    controller.advance()
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlanceTheme.panel)
    }
}

private struct UnlockGlyphView: View {
    var body: some View {
        LoopingVideoView(resourceName: "idleanimation")
    }
}

// MARK: - 5. Select camera

struct SelectCameraStepView: View {
    let controller: OnboardingController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select camera")
                .font(GlanceTheme.Font.title)
                .foregroundStyle(GlanceTheme.textPrimary)
                .padding(.leading, 4)
                .padding(.top, 14)

            Text("Used for Face enrollment and for unlocking your Mac")
                .font(GlanceTheme.Font.passwordCaption)
                .foregroundStyle(GlanceTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)

            Spacer(minLength: 2)

            CameraSelectionPill(
                label: controller.cameraSelectionLabel,
                devices: controller.cameraDevices
            ) { id in
                controller.selectCamera(id: id)
            }

            Spacer(minLength: 4)

            HStack(spacing: 10) {
                PillButton(title: "Back", style: .secondary) {
                    controller.back()
                }
                PillButton(title: "Next") {
                    controller.advance()
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlanceTheme.panel)
        .onAppear {
            controller.refreshCameraDevices()
            controller.applyDisplayPinForCameraSelection()
        }
    }
}
