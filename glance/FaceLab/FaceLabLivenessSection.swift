//
//  FaceLabLivenessSection.swift
//  glance
//
//  Liveness cue telemetry and geometry diagnostics section for `FaceLabView`.
//

import SwiftUI

struct FaceLabLivenessSection: View {
    @Bindable var controller: FaceLabController

    var body: some View {
        GroupBox("Liveness") {
            VStack(alignment: .leading, spacing: 12) {
                decisionStrip

                Picker("Mode", selection: $controller.livenessMode) {
                    ForEach(LivenessMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Text(
                    controller.livenessMode == .light
                        ? "Light: only the deny cues run. Anything not actively rejected is treated as live."
                        : "Heavy: a deny cue fails the scan; at least one confirm cue must fire before it can pass."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)

                Divider()

                cueGroup(
                    title: "Deny — evidence of a spoof",
                    caption: "Either one firing fails face unlock outright, and overrides any confirmation.",
                    cues: LivenessCue.allCases.filter { $0.role == .deny }
                )

                cueGroup(
                    title: "Confirm — evidence of a real face",
                    caption:
                        "Any one firing passes liveness. None firing is not a failure — the scan just keeps looking.",
                    cues: LivenessCue.allCases.filter { $0.role == .confirm }
                )

                rawMeasurementsBlock
                geometryDiagnosticsBlock

                HStack {
                    Button("Reset cues") { controller.resetLiveness() }
                    Text("Cue firing latches for the whole scan — reset to re-test.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var decisionStrip: some View {
        let decision = controller.currentLiveness.decision
        let (color, label): (Color, String) = {
            switch decision {
            case .pending:
                return (.secondary, "Pending — nothing decided yet")
            case .confirmed(let cue):
                return (.green, cue.map { "Live — confirmed by \($0.title)" } ?? "Live — auto-confirmed (Light mode)")
            case .denied(let cue):
                return (.red, "Spoof — denied by \(cue.title)")
            }
        }()
        return HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.system(.body, design: .monospaced))
            Spacer()
            Text("\(controller.currentLiveness.frameCount) frames")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func cueGroup(title: String, caption: String, cues: [LivenessCue]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(cues) { cue in
                cueRow(cue)
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    /// Level bar plus fire counter — the level only matters insofar as it crosses the fire threshold enough frames.
    private func cueRow(_ cue: LivenessCue) -> some View {
        let state = controller.currentLiveness.state(for: cue)
        let isEnabled = controller.isLivenessCueEnabled(cue)
        let threshold = controller.livenessTuning.level(for: cue)
        let framesNeeded = controller.livenessTuning.frames(for: cue)
        let hasEvidence = state.reading.confidence > 0

        return HStack(spacing: 8) {
            Toggle(
                "",
                isOn: Binding(
                    get: { controller.isLivenessCueEnabled(cue) },
                    set: { controller.setLivenessCue(cue, enabled: $0) }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(cue.explanation)

            Text(cue.title)
                .font(.caption)
                .frame(width: 110, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            hasEvidence
                                ? (cue.role == .deny ? Color.orange : Color.accentColor)
                                : Color.gray.opacity(0.3)
                        )
                        .frame(width: geometry.size.width * CGFloat(state.reading.level))
                    // Where this cue starts counting frames.
                    Rectangle()
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 1)
                        .offset(x: geometry.size.width * CGFloat(threshold))
                }
            }
            .frame(height: 8)

            Text(hasEvidence ? String(format: "%.0f%%", state.reading.level * 100) : "—")
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)

            Text("\(state.framesCounted)/\(framesNeeded)")
                .font(.caption2.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.secondary)

            Text(state.hasFired ? "FIRED" : "")
                .font(.caption2.weight(.bold))
                .foregroundStyle(cue.role == .deny ? Color.red : Color.green)
                .frame(width: 44, alignment: .leading)
        }
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var rawMeasurementsBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let frame = controller.lastLivenessFrame {
                Text(
                    "Left EAR: \(ratioString(frame.leftEyeAspectRatio))  Right EAR: \(ratioString(frame.rightEyeAspectRatio))  Nose offset: \(ratioString(frame.noseOffsetRatio))"
                )
                Text("Device overlap: \(percentString(frame.deviceOverlapFraction))")
                if let glare = frame.glare {
                    Text(
                        "Specular: \(String(format: "%.4f", glare.specularFraction))  Cluster: \(String(format: "%.2f", glare.specularClusterRatio))  Crop: \(Int(glare.cropPixelWidth))px"
                    )
                } else {
                    Text("Specular: — (no native-resolution crop this frame)")
                }
            } else {
                Text("No liveness frame yet.")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private var geometryDiagnosticsBlock: some View {
        let geo = controller.currentGeometry
        return VStack(alignment: .leading, spacing: 6) {
            Text("Flat vs 3D diagnostics")
                .font(.caption.weight(.semibold))
            Text(
                "Landmarks: \(geo.validLandmarkCount)   Pairs: \(geo.pairsAnalyzed)   Rejected: \(geo.rejectedPairCount)"
            )
            Text(
                "Fit residual: \(ratioString(geo.medianFitResidual))  Probe residual: \(ratioString(geo.medianProbeResidual))  Excess: \(ratioString(geo.excessRatio))"
            )
            Text("Coherence: \(ratioString(geo.coherence))  Motion: \(ratioString(geo.motionMagnitude))")
            if !geo.diagnosticRatios.isEmpty {
                Text(
                    geo.diagnosticRatios.keys.sorted().map { key in
                        "\(key) \(ratioString(geo.diagnosticRatios[key]))"
                    }.joined(separator: "  ")
                )
            }
            if geo.planarConfidence == 0 {
                Text("Abstaining — not enough head rotation to tell a plane from a still 3D face.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private func ratioString(_ value: CGFloat?) -> String {
        guard let value else { return "—" }
        return String(format: "%+.3f", value)
    }

    private func percentString(_ value: CGFloat?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }
}
