//
//  OnboardingStep.swift
//  glance
//
//  Step definitions and permission state enums for the notch-hosted onboarding flow.
//

import Foundation

/// `String`-backed so `GlanceSettings.onboardingResumeStep` can persist it directly by name.
enum OnboardingStep: String, CaseIterable {
    case intro
    case permissions
    case securityNotice
    case preSetup
    case selectCamera
    case enroll
    case name
    case password
    case complete

    var previous: OnboardingStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index > 0 else { return nil }
        return all[index - 1]
    }

    /// Next step for standard forward navigation via `OnboardingController.advance()`.
    var nextLinearStep: OnboardingStep? {
        switch self {
        case .intro: return .permissions
        case .permissions: return .securityNotice
        case .securityNotice: return .preSetup
        case .preSetup: return .selectCamera
        case .selectCamera: return .enroll
        case .enroll, .name, .password, .complete: return nil
        }
    }

    /// Whether this step shows the Back/primary button pair; enroll is close-control
    /// only, and complete/intro have just one side.
    var showsBackButton: Bool {
        switch self {
        case .securityNotice, .permissions, .preSetup, .selectCamera, .name, .password: return true
        case .intro, .enroll, .complete: return false
        }
    }

    /// Where a first-run flow should resume if the app quit on this step. `.enroll`,
    /// `.name`, and `.password` all depend on in-memory state a fresh launch doesn't
    /// have, so they collapse back to `.preSetup` rather than resuming into a step
    /// whose prerequisites no longer exist.
    var resumeTarget: OnboardingStep {
        switch self {
        case .enroll, .name, .password: return .preSetup
        case .intro, .securityNotice, .permissions, .preSetup, .selectCamera, .complete: return self
        }
    }
}

enum CameraPermissionState {
    case notDetermined
    case granted
    case denied
}
