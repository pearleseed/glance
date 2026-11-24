//
//  AppIconCache.swift
//  glance
//
//  Main-actor NSCache + detached thumbnail decoder for App Lock picker and settings rows.
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppIconCache {
    static let shared = AppIconCache()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 150
        return cache
    }()

    private init() {}

    func cachedIcon(forPath path: String) -> NSImage? {
        cachedIcon(forPath: path, bundleIdentifier: nil)
    }

    func cachedIcon(forPath path: String?, bundleIdentifier: String?) -> NSImage? {
        let key = Self.cacheKey(forPath: path, bundleIdentifier: bundleIdentifier)
        guard !key.isEmpty else { return nil }
        return cache.object(forKey: key as NSString)
    }

    func loadIcon(forPath path: String, bundleIdentifier: String? = nil) async -> NSImage {
        let key = Self.cacheKey(forPath: path, bundleIdentifier: bundleIdentifier)
        if !key.isEmpty, let existing = cache.object(forKey: key as NSString) {
            return existing
        }

        let cgImage = await Task.detached(priority: .utility) {
            Self.renderThumbnailCGImage(forPath: path, bundleIdentifier: bundleIdentifier)
        }.value

        let image: NSImage
        if let cgImage {
            image = NSImage(cgImage: cgImage, size: NSSize(width: 32, height: 32))
        } else {
            image = NSWorkspace.shared.icon(for: .applicationBundle)
        }

        if !key.isEmpty {
            cache.setObject(image, forKey: key as NSString)
        }
        return image
    }

    private static func cacheKey(forPath path: String?, bundleIdentifier: String?) -> String {
        if let path, !path.isEmpty {
            return "path:\(path)"
        }
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return "bundle:\(bundleIdentifier.lowercased())"
        }
        return ""
    }

    nonisolated private static func renderThumbnailCGImage(
        forPath path: String,
        bundleIdentifier: String?
    ) -> CGImage? {
        let sourceImage: NSImage
        if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            sourceImage = NSWorkspace.shared.icon(forFile: path)
        } else if let bundleIdentifier,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        {
            sourceImage = NSWorkspace.shared.icon(forFile: url.path)
        } else if let bundleIdentifier,
            let runningIcon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?
                .icon
        {
            sourceImage = runningIcon
        } else {
            sourceImage = NSWorkspace.shared.icon(for: .applicationBundle)
        }

        let targetPixels = 64
        var proposedRect = CGRect(x: 0, y: 0, width: targetPixels, height: targetPixels)
        guard let sourceCG = sourceImage.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        if sourceCG.width == targetPixels && sourceCG.height == targetPixels {
            return sourceCG
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: targetPixels,
                height: targetPixels,
                bitsPerComponent: 8,
                bytesPerRow: targetPixels * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return sourceCG
        }

        let srcW = CGFloat(sourceCG.width)
        let srcH = CGFloat(sourceCG.height)
        let scale = min(CGFloat(targetPixels) / max(srcW, 1), CGFloat(targetPixels) / max(srcH, 1))
        let drawW = srcW * scale
        let drawH = srcH * scale
        let drawRect = CGRect(
            x: (CGFloat(targetPixels) - drawW) * 0.5,
            y: (CGFloat(targetPixels) - drawH) * 0.5,
            width: drawW,
            height: drawH
        )

        context.interpolationQuality = .high
        context.draw(sourceCG, in: drawRect)
        return context.makeImage() ?? sourceCG
    }
}

/// Lightweight SwiftUI app icon thumbnail backed by `AppIconCache`.
struct AppIconThumbnail: View {
    let path: String?
    let bundleIdentifier: String
    let size: CGFloat

    @State private var icon: NSImage?
    @State private var loadedTaskID: String?

    private var taskID: String {
        "\(bundleIdentifier)|\(path ?? "")"
    }

    var body: some View {
        let displayedIcon =
            (loadedTaskID == taskID ? icon : nil)
            ?? AppIconCache.shared.cachedIcon(
                forPath: path,
                bundleIdentifier: bundleIdentifier
            )

        Group {
            if let displayedIcon {
                Image(nsImage: displayedIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(SettingsMetrics.neutralButtonFill)
                    .overlay(
                        Image(systemName: "app.fill")
                            .font(.system(size: size * 0.5))
                            .foregroundStyle(SettingsMetrics.textTertiary)
                    )
            }
        }
        .frame(width: size, height: size)
        .task(id: taskID) {
            let expectedID = taskID
            if let cached = AppIconCache.shared.cachedIcon(
                forPath: path,
                bundleIdentifier: bundleIdentifier
            ) {
                icon = cached
                loadedTaskID = expectedID
            } else {
                icon = nil
                loadedTaskID = nil
                let loaded = await AppIconCache.shared.loadIcon(
                    forPath: path ?? "",
                    bundleIdentifier: bundleIdentifier
                )
                guard !Task.isCancelled, expectedID == taskID else { return }
                icon = loaded
                loadedTaskID = expectedID
            }
        }
    }
}
