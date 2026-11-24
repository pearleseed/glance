import AVFoundation
import Foundation
import AppKit
import CoreImage

@main
struct NotchUISelfTest {
    static func main() async {
        // 1. Verify color resolution semantics across all 3 modes
        let b2gIdle = UnlockAnimationColor.blueToGreen.resolvedTintRGB(for: .idle)
        let b2gFail = UnlockAnimationColor.blueToGreen.resolvedTintRGB(for: .failure)
        let b2gSuccess = UnlockAnimationColor.blueToGreen.resolvedTintRGB(for: .success)
        precondition(b2gIdle == nil, "FAIL: blueToGreen idle must remain original blue")
        precondition(b2gFail == nil, "FAIL: blueToGreen failure must remain original blue")
        precondition(b2gSuccess != nil && abs(b2gSuccess!.green - Double(0xC7) / 255.0) < 0.001, "FAIL: blueToGreen success must tint green")

        precondition(UnlockAnimationColor.blue.resolvedTintRGB(for: .idle) == nil, "FAIL: blue mode must never tint idle")
        precondition(UnlockAnimationColor.blue.resolvedTintRGB(for: .success) == nil, "FAIL: blue mode must never tint success")
        precondition(UnlockAnimationColor.blue.resolvedTintRGB(for: .failure) == nil, "FAIL: blue mode must never tint failure")
        precondition(UnlockAnimationColor.green.resolvedTintRGB(for: .idle) != nil, "FAIL: green mode must tint idle")
        precondition(UnlockAnimationColor.green.resolvedTintRGB(for: .success) != nil, "FAIL: green mode must tint success")
        precondition(UnlockAnimationColor.green.resolvedTintRGB(for: .failure) != nil, "FAIL: green mode must tint failure")

        // 2. Verify CIColorMatrix maps pure blue pixel (0, 0, 255) to systemGreen (#34C759)
        var pixel: [UInt8] = [0, 0, 255, 255]
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let blueCG = ctx.makeImage()!
        let tintedCI = AnimationTint.apply(b2gSuccess, to: CIImage(cgImage: blueCG))
        let outCG = AnimationTint.linearContext.createCGImage(tintedCI, from: tintedCI.extent, format: .RGBA8, colorSpace: srgb)!
        var outPx: [UInt8] = [0, 0, 0, 0]
        let readCtx = CGContext(data: &outPx, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        readCtx.draw(outCG, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        precondition(abs(Int(outPx[0]) - 0x34) <= 3 && abs(Int(outPx[1]) - 0xC7) <= 3 && abs(Int(outPx[2]) - 0x59) <= 3,
                     "FAIL: tinted green RGB off target: \(outPx)")

        // 3. Verify NSImage tinting preserves size and uses linear-sRGB CIContext
        let blueNS = NSImage(cgImage: blueCG, size: NSSize(width: 1, height: 1))
        let tintedNS = AnimationTint.apply(b2gSuccess, to: blueNS)
        precondition(tintedNS.size == blueNS.size, "FAIL: NSImage tinting must preserve image size")
        let tintedNSRep = tintedNS.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        var nsPx: [UInt8] = [0, 0, 0, 0]
        let nsReadCtx = CGContext(data: &nsPx, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        nsReadCtx.draw(tintedNSRep, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        precondition(abs(Int(nsPx[0]) - 0x34) <= 3 && abs(Int(nsPx[1]) - 0xC7) <= 3 && abs(Int(nsPx[2]) - 0x59) <= 3,
                     "FAIL: NSImage tinted green RGB off target: \(nsPx)")

        print("PASS: UnlockAnimationColor semantics & linear-light CIColorMatrix tint accuracy verified.")

        // 4. Verify physical notch size adjustment & safe floor (MacBook Air 13" 178pt must NOT be forced to 200pt)
        let air13 = NotchGeometry.adjustedPhysicalNotchSize(
            measuredWidth: 178, measuredHeight: 32, widthAdjustment: 0, heightAdjustment: 0
        )
        precondition(air13.width == 178 && air13.height == 32, "FAIL: Air 13 notch distorted to \(air13)")

        let adjusted = NotchGeometry.adjustedPhysicalNotchSize(
            measuredWidth: 178, measuredHeight: 32, widthAdjustment: -10, heightAdjustment: 4
        )
        precondition(adjusted.width == 168 && adjusted.height == 36, "FAIL: adjustment math wrong: \(adjusted)")

        let clampedFloor = NotchGeometry.adjustedPhysicalNotchSize(
            measuredWidth: 90, measuredHeight: 10, widthAdjustment: -20, heightAdjustment: -20
        )
        precondition(clampedFloor.width == 80 && clampedFloor.height == 1, "FAIL: safe floor failed: \(clampedFloor)")

        print("PASS: NotchGeometry.adjustedPhysicalNotchSize & safe floor verified.")

        // 5. Verify AnimationTint.cachedStill does not crash and returns nil or valid image
        for color in UnlockAnimationColor.allCases {
            for compact in [false, true] {
                if let still = AnimationTint.cachedStill(for: color, compact: compact) {
                    precondition(
                        still.size.width > 0 && still.size.height > 0,
                        "FAIL: cachedStill(\(color), compact: \(compact)) returned empty image"
                    )
                }
            }
        }

        // 6. Exercise AnimationTint.makeVideoComposition against glance/Resources/unlockanimation.mp4
        let videoURL = URL(fileURLWithPath: "glance/Resources/unlockanimation.mp4")
        if FileManager.default.fileExists(atPath: videoURL.path) {
            let asset = AVURLAsset(url: videoURL)
            let nilComp = await AnimationTint.makeVideoComposition(for: asset, rgb: nil)
            precondition(nilComp == nil, "FAIL: nil tint RGB must return nil video composition")

            let greenComp = await AnimationTint.makeVideoComposition(for: asset, rgb: .systemGreen)
            precondition(
                greenComp != nil,
                "FAIL: systemGreen tint must produce non-nil AVVideoComposition for unlockanimation.mp4"
            )
            if let greenComp {
                precondition(
                    greenComp.renderSize.width > 0 && greenComp.renderSize.height > 0,
                    "FAIL: tinted video composition must have positive renderSize: \(greenComp.renderSize)"
                )
                if #available(macOS 26.0, *) {
                    precondition(
                        greenComp.colorPrimaries == AVVideoColorPrimaries_ITU_R_709_2
                            && greenComp.colorTransferFunction == AVVideoTransferFunction_ITU_R_709_2
                            && greenComp.colorYCbCrMatrix == AVVideoYCbCrMatrix_ITU_R_709_2,
                        "FAIL: tinted video composition must preserve Rec.709 color tags"
                    )
                }
            }

            if let track = try? await asset.loadTracks(withMediaType: .video).first,
                let formatDescriptions = try? await track.load(.formatDescriptions),
                let desc = formatDescriptions.first,
                let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any],
                let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
            {
                precondition(!primaries.isEmpty, "FAIL: unlockanimation.mp4 color primaries must be non-empty")
            }
            print("PASS: AnimationTint.makeVideoComposition & cachedStill verified against unlockanimation.mp4.")
        } else {
            print("PASS: AnimationTint.cachedStill verified (unlockanimation.mp4 not present at relative path).")
        }
    }
}
