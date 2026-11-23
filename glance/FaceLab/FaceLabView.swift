//
//  FaceLabView.swift
//  glance
//
//  Debug console: camera preview, face detection + alignment, enrollment,
//  liveness telemetry, and recognition calibration.
//

import SwiftUI

struct FaceLabView: View {
    /// Retained only while the hidden debug tab is visible.
    @Bindable var controller: FaceLabController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerBar
                modelStatusSection
                sessionLockSection
                previewSection
                detectionSection
                FaceLabLivenessSection(controller: controller)
                enrollSection
                identitiesSection
                FaceLabRecognitionSection(controller: controller)
                FaceLabCalibrationSection(controller: controller)
                logSection
            }
            .padding(20)
        }
        .onDisappear {
            controller.stop()
        }
        // Guided enrollment runs in the notch, outside this view hierarchy, so nothing else prompts a re-read once
        // it closes. Same trick YourFaceSettingsPage uses.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            controller.store.reloadIfUnlocked()
        }
    }

    /// True while the notch (a single shared panel) is already hosting an onboarding flow.
    private var enrollmentFlowIsRunning: Bool {
        NotchOverlayController.shared.phase == .onboarding
    }

    private var headerBar: some View {
        HStack {
            Text("Face Lab — On-Device Face Recognition (Debug)")
                .font(.headline)
            Spacer()
            Button("Preview ✓") {
                NotchOverlayController.shared.present()
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    NotchOverlayController.shared.finish(success: true)
                }
            }
            Button("Preview ✗") {
                NotchOverlayController.shared.present(onRetry: {
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        NotchOverlayController.shared.finish(success: false)
                    }
                })
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    NotchOverlayController.shared.finish(success: false)
                }
            }
            Button("Start Onboarding") {
                controller.startFullOnboarding()
            }
            .disabled(enrollmentFlowIsRunning)
        }
    }

    // MARK: - Which embedder is active

    private var modelStatusSection: some View {
        HStack {
            Circle()
                .fill(controller.pipeline.usingFallbackEmbedder ? .orange : .green)
                .frame(width: 8, height: 8)
            Text("Embedder: \(controller.pipeline.embedder.name)")
                .font(.caption)
            if controller.pipeline.usingFallbackEmbedder {
                Text("(ArcFace unavailable — see log)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
    }

    // MARK: - Session lock

    private var sessionLockSection: some View {
        Group {
            if controller.store.isLocked {
                HStack {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("Session locked — enrolled faces are encrypted and can't be read or saved yet.")
                        .font(.caption)
                    Spacer()
                    Button("Unlock") {
                        Task { await controller.unlockSession() }
                    }
                }
                if let error = controller.sessionError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        GroupBox("Camera Preview") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(controller.camera.isRunning ? .green : .gray)
                        .frame(width: 10, height: 10)
                    Text(controller.camera.isRunning ? "Running" : "Stopped")
                    Spacer()
                    Button(controller.camera.isRunning ? "Stop" : "Start") {
                        if controller.camera.isRunning {
                            controller.stop()
                        } else {
                            Task { await controller.start() }
                        }
                    }
                }

                if let error = controller.camera.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                CameraPreviewView(session: controller.camera.session, faces: controller.detectedFaces)
                    .frame(height: 300)
                    .background(Color.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Detection + alignment + embedding

    private var detectionSection: some View {
        GroupBox("Detection") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Faces detected: \(controller.detectedFaces.count)")
                    if let quality = controller.currentResult?.quality {
                        Text("Capture quality: \(String(format: "%.0f%%", quality * 100))")
                    } else {
                        Text("Capture quality: —")
                            .foregroundStyle(.secondary)
                    }
                    if let result = controller.currentResult {
                        Text("Alignment: \(result.alignmentTier.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Embedding: \(result.embedding.count) numbers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Yaw: \(yawPitchString(result.face.yaw))  Pitch: \(yawPitchString(result.face.pitch))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(spacing: 4) {
                    Text("Aligned input").font(.caption).foregroundStyle(.secondary)
                    if let aligned = controller.currentResult?.alignedImage {
                        Image(aligned, scale: 1, orientation: .up, label: Text("Aligned face"))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.gray.opacity(0.15))
                            .frame(width: 96, height: 96)
                            .overlay(Text("No face").font(.caption2).foregroundStyle(.secondary))
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Enrollment

    private var enrollSection: some View {
        GroupBox("Enroll") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Name", text: $controller.enrollName)
                        .textFieldStyle(.roundedBorder)
                    Button("Capture Sample") {
                        controller.captureSample()
                    }
                    .disabled(controller.currentResult == nil || controller.store.isLocked)
                }

                if controller.store.identities.isEmpty {
                    Text(
                        controller.store.isLocked
                            ? "Unlock the session to view enrolled identities."
                            : "No identities enrolled yet."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.store.identities) { identity in
                        HStack {
                            Text(identity.name)
                            Text("\(identity.samples.count) sample\(identity.samples.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if identity.isStale(comparedTo: controller.pipeline.embedder) {
                                Text("stale")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                controller.deleteIdentity(identity)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Multi-identity enrollment

    private var identitiesSection: some View {
        GroupBox("Identities") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(controller.store.identities.count) enrolled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Identity") {
                        controller.startAddIdentity()
                    }
                    .disabled(controller.store.isLocked || enrollmentFlowIsRunning)
                }

                if controller.store.identities.isEmpty {
                    Text(
                        controller.store.isLocked
                            ? "Unlock the session to view enrolled identities."
                            : "No identities enrolled yet — run the guided nine-pose capture with Add Identity."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.store.identities) { identity in
                        FaceLabIdentityRow(
                            identity: identity,
                            isStale: identity.isStale(comparedTo: controller.pipeline.embedder),
                            lowQualityCount: controller.lowQualityCount(in: identity),
                            canStartFlow: !enrollmentFlowIsRunning,
                            recapture: { controller.startRecapture(of: identity) },
                            delete: { controller.deleteIdentity(identity) }
                        )
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Debug log

    private var logSection: some View {
        GroupBox("Log") {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(controller.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
        }
    }

    private func yawPitchString(_ value: Float?) -> String {
        guard let value else { return "—" }
        return String(format: "%+.2f", value)
    }
}

#Preview {
    FaceLabView(controller: FaceLabController())
}
