//
//  FaceLabRecognitionSection.swift
//  glance
//
//  Recognition scoring, threshold calibration chart, and per-identity disclosure
//  rows for `FaceLabView`.
//

import Charts
import SwiftUI

struct FaceLabRecognitionSection: View {
    @Bindable var controller: FaceLabController

    var body: some View {
        GroupBox("Recognize") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Identify") {
                        controller.recognize()
                    }
                    .disabled(controller.currentResult == nil || controller.store.identities.isEmpty)

                    Spacer()

                    Text("Threshold: \(String(format: "%.2f", controller.threshold))")
                        .font(.caption)
                    Slider(value: $controller.threshold, in: -1...1)
                        .frame(width: 160)
                }

                if let best = controller.bestMatch {
                    HStack {
                        Circle().fill(.green).frame(width: 10, height: 10)
                        Text(
                            "Best match: \(best.name) — centroid \(String(format: "%.3f", best.centroidSimilarity)), max \(String(format: "%.3f", best.maxSampleSimilarity))"
                        )
                        Text("MATCH").font(.caption.bold()).foregroundStyle(.green)
                    }
                } else if let first = controller.recognitionResults.first {
                    HStack {
                        Circle().fill(.red).frame(width: 10, height: 10)
                        Text(
                            "Closest: \(first.name) — centroid \(String(format: "%.3f", first.centroidSimilarity)), max \(String(format: "%.3f", first.maxSampleSimilarity))"
                        )
                        Text("NO MATCH").font(.caption.bold()).foregroundStyle(.red)
                    }
                }

                if !controller.recognitionResults.isEmpty {
                    Divider()
                    ForEach(controller.recognitionResults) { result in
                        HStack {
                            Text(result.name)
                            if result.isStale {
                                Text("stale").font(.caption2.bold()).foregroundStyle(.orange)
                            }
                            Spacer()
                            Text("centroid \(String(format: "%.3f", result.centroidSimilarity))")
                                .foregroundStyle(.secondary)
                            Text("max \(String(format: "%.3f", result.maxSampleSimilarity))")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct FaceLabCalibrationSection: View {
    @Bindable var controller: FaceLabController

    var body: some View {
        GroupBox("Threshold Calibration") {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Run Identify, then tag whether that was really you or someone else — do this across "
                        + "lighting, angle, and expression, and again with a different person, to see where "
                        + "the two score distributions actually fall."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Button("Mark Genuine (this is me)") {
                        controller.recordCalibrationSample(isGenuine: true)
                    }
                    Button("Mark Impostor (not me)") {
                        controller.recordCalibrationSample(isGenuine: false)
                    }
                    .disabled(controller.recognitionResults.isEmpty)
                    Spacer()
                    Button("Clear", role: .destructive) {
                        controller.clearCalibrationSamples()
                    }
                    .disabled(controller.calibrationSamples.isEmpty)
                }
                .disabled(controller.recognitionResults.isEmpty && controller.calibrationSamples.isEmpty)

                if !controller.calibrationSamples.isEmpty {
                    Chart {
                        ForEach(controller.calibrationSamples) { sample in
                            PointMark(
                                x: .value("Similarity", sample.centroidSimilarity),
                                y: .value("Type", sample.isGenuine ? "Genuine" : "Impostor")
                            )
                            .foregroundStyle(sample.isGenuine ? Color.green : Color.red)
                        }
                        RuleMark(x: .value("Threshold", controller.threshold))
                            .foregroundStyle(.blue)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                    }
                    .chartXScale(domain: -1...1)
                    .frame(height: 100)

                    if let suggested = controller.suggestedThreshold {
                        HStack {
                            Text("Suggested threshold: \(String(format: "%.3f", suggested))")
                                .font(.caption)
                            Button("Use it") {
                                controller.threshold = Double(suggested)
                            }
                            if controller.calibrationDistributionsOverlap {
                                Text("Distributions overlap — no single cutoff perfectly separates these samples yet.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    } else {
                        Text("Record at least one genuine and one impostor sample to get a suggestion.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// One enrolled person: a summary line, actions, and a disclosure listing every stored sample's capture quality.
struct FaceLabIdentityRow: View {
    let identity: FaceIdentity
    let isStale: Bool
    let lowQualityCount: Int
    let canStartFlow: Bool
    let recapture: () -> Void
    let delete: () -> Void

    private var posesCaptured: Int {
        Set(identity.samples.compactMap(\.pose)).count
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(identity.samples.enumerated()), id: \.offset) { index, sample in
                    HStack(spacing: 8) {
                        Text(String(format: "%2d", index + 1))
                            .foregroundStyle(.tertiary)
                        Text(sample.pose ?? "untagged")
                            .frame(width: 90, alignment: .leading)
                        Text(FaceLabController.qualityLabel(sample.quality))
                            .frame(width: 44, alignment: .trailing)
                            .foregroundStyle(isLow(sample) ? .orange : .primary)
                        Text(sample.capturedAt.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.caption.monospaced())
                }
            }
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(identity.name).bold()
                    if isStale {
                        Text("stale")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Recapture", action: recapture)
                        .disabled(!canStartFlow)
                    Button(role: .destructive, action: delete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                }

                Text(
                    "\(posesCaptured)/9 poses · \(identity.samples.count) samples · enrolled \(identity.createdAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if lowQualityCount > 0 {
                    Text("\(lowQualityCount) of \(identity.samples.count) samples are low quality")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func isLow(_ sample: FaceSample) -> Bool {
        identity.qualityTier(of: sample) == .poor
    }
}
