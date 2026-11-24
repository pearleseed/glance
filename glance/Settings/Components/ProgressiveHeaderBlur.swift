//
//  ProgressiveHeaderBlur.swift
//  glance
//
//  A backdrop blur behind the header whose strength fades from strongest at
//  the window's top edge to none by the bottom of the blur zone, so
//  scrolled rows sharpen up as they pass underneath rather than cutting
//  from blurred to crisp at a hard line.
//
//  SwiftUI's native `scrollEdgeEffectStyle(.soft, for: .top)` (macOS 26) is
//  used on macOS 26+ in `SettingsWindowView`. On macOS 14–15, this view
//  fakes it with two layered materials (weakest to strongest), masked to fade
//  out over progressively shorter spans to keep GPU overdraw minimal.
//

import SwiftUI

struct ProgressiveHeaderBlur: View {
    var height: CGFloat

    /// Weakest to strongest. The weakest spans the whole zone (top fully
    /// opaque, fading to clear by the bottom edge); the stronger material
    /// fades out over the upper half so only the topmost band accumulates both.
    private static let materials: [Material] = [
        .ultraThinMaterial, .regularMaterial
    ]

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Array(Self.materials.enumerated()), id: \.offset) { index, material in
                let fadeEnd = 1 - CGFloat(index) / CGFloat(Self.materials.count)
                Rectangle()
                    .fill(material)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .clear, location: fadeEnd)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
        .frame(height: height)
        // Purely decorative — never intercept clicks meant for the header
        // buttons layered on top of it or rows scrolling underneath.
        .allowsHitTesting(false)
    }
}
