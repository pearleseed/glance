//
//  CameraDeviceCatalog.swift
//  glance
//
//  Resolves the app's camera preference (flat default, or split by built-in vs. external display) into the device to open.
//

@preconcurrency import AVFoundation
import AppKit

struct CameraDevice: Identifiable, Hashable {
    let id: String // AVCaptureDevice.uniqueID
    let name: String
    let isUsable: Bool
}

enum CameraDeviceCatalog {
    nonisolated private static func discoveredDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    nonisolated private static func isUsable(_ device: AVCaptureDevice) -> Bool {
        device.isConnected && !device.isSuspended
    }

    static func availableDevices() -> [CameraDevice] {
        discoveredDevices().map {
            CameraDevice(id: $0.uniqueID, name: $0.localizedName, isUsable: isUsable($0))
        }
    }

    static func usableDevices() -> [CameraDevice] {
        availableDevices().filter(\.isUsable)
    }

    /// True if the currently-active screen is the Mac's built-in display
    /// (vs. an external monitor) — used to pick between the built-in/
    /// external camera overrides.
    static func isUsingBuiltInDisplay() -> Bool {
        guard let screen = NSScreen.main,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return true }
        return CGDisplayIsBuiltin(screenNumber) != 0
    }

    /// Reads the MainActor-isolated preference for the active display context so
    /// off-actor session reconciliation can resolve the device without touching UI state.
    static func preferredCameraID() -> String? {
        let settings = GlanceSettings.shared
        return isUsingBuiltInDisplay()
            ? (settings.builtInDisplayCameraID ?? settings.defaultCameraID)
            : (settings.externalDisplayCameraID ?? settings.defaultCameraID)
    }

    /// Usable system default camera when no explicit override applies: built-in front camera,
    /// any other discovered usable camera (e.g. USB webcam in clamshell mode), then AVFoundation's default.
    nonisolated static func resolvedDefaultDevice() -> AVCaptureDevice? {
        if let builtIn = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
           isUsable(builtIn) {
            return builtIn
        }
        if let usable = discoveredDevices().first(where: isUsable) {
            return usable
        }
        if let fallback = AVCaptureDevice.default(for: .video), isUsable(fallback) {
            return fallback
        }
        return nil
    }

    /// Display-specific override, then flat default, then the usable system default camera.
    static func resolvedDevice() -> AVCaptureDevice? {
        resolvedDevice(preferredID: preferredCameraID())
    }

    /// Resolves `preferredID` if usable, falling back to `resolvedDefaultDevice()`.
    nonisolated static func resolvedDevice(preferredID: String?) -> AVCaptureDevice? {
        if let preferredID,
           let device = AVCaptureDevice(uniqueID: preferredID),
           isUsable(device) {
            return device
        }
        return resolvedDefaultDevice()
    }
}
