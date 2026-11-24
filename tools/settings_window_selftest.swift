// Offline AppKit + SwiftUI regression self-test for the Settings window close/reopen lifecycle.
//
// Compile & run:
//   swiftc -parse-as-library -target arm64-apple-macosx14.0 \
//     tools/settings_window_selftest.swift \
//     glance/Settings/SettingsMetrics.swift \
//     glance/Settings/Components/SettingsWindowHelpers.swift \
//     -o /tmp/settings_window_selftest && /tmp/settings_window_selftest

import AppKit
import Foundation
import SwiftUI

private func pumpMainRunLoop(seconds: TimeInterval = 0.08) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

@MainActor
private struct HostedSettingsHarness: View {
    @State var isWindowVisible = true
    let onVisibilityRecorded: (Bool) -> Void

    var body: some View {
        ZStack {
            Color.clear
            if isWindowVisible {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .background(
            WindowConfigurator { visible in
                if isWindowVisible != visible {
                    isWindowVisible = visible
                }
                onVisibilityRecorded(visible)
            }
        )
    }
}

@MainActor
private func findWindowConfiguringViews(in root: NSView?) -> [WindowConfiguringView] {
    guard let root else { return [] }
    var matches: [WindowConfiguringView] = []
    if let match = root as? WindowConfiguringView {
        matches.append(match)
    }
    for subview in root.subviews {
        matches.append(contentsOf: findWindowConfiguringViews(in: subview))
    }
    return matches
}

@main
struct SettingsWindowSelfTest {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // 1. Direct WindowConfiguringView test: closing a window must NEVER allow a
        // newly attached WindowConfiguringView instance to reopen or reconfigure it.
        do {
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 320, height: 240),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.alphaValue = 0

            var visibilityEvents: [Bool] = []
            let firstView = WindowConfiguringView()
            firstView.onVisibilityChange = { visibilityEvents.append($0) }
            window.contentView?.addSubview(firstView)
            window.orderFront(nil)
            pumpMainRunLoop()

            precondition(window.isVisible, "FAIL [1]: window must be visible after orderFront")
            precondition(
                window.frame.size == SettingsMetrics.windowSize,
                "FAIL [1]: configure() must apply SettingsMetrics.windowSize, got \(window.frame.size)"
            )
            precondition(
                window.minSize == window.maxSize && window.minSize.width == SettingsMetrics.windowSize.width,
                "FAIL [1]: configure() must pin minSize == maxSize (got min=\(window.minSize) max=\(window.maxSize))"
            )
            precondition(window.titlebarAppearsTransparent, "FAIL [1]: titlebar must be transparent")
            precondition(window.titleVisibility == .hidden, "FAIL [1]: title must be hidden")
            precondition(window.toolbar?.identifier == "GlanceSettingsToolbar", "FAIL [1]: toolbar missing")
            precondition(window.alphaValue == 1, "FAIL [1]: alphaValue must be restored to 1")
            precondition(visibilityEvents.last == true, "FAIL [1]: expected visible=true callback")

            // Close the window and verify it stays closed.
            let initialToolbar = window.toolbar
            window.close()
            pumpMainRunLoop()
            precondition(!window.isVisible, "FAIL [2]: window must stay closed after close()")
            precondition(visibilityEvents.last == false, "FAIL [2]: close() must report visible=false")

            // Simulate SwiftUI tearing down and mounting a brand-new WindowConfiguringView
            // onto the already-closed window. It MUST NOT reopen or replace the toolbar.
            firstView.removeFromSuperview()
            let recreatedView = WindowConfiguringView()
            recreatedView.onVisibilityChange = { visibilityEvents.append($0) }
            window.contentView?.addSubview(recreatedView)
            pumpMainRunLoop()

            precondition(
                !window.isVisible,
                "FAIL [3]: attaching a new WindowConfiguringView to a closed window must NEVER reopen it"
            )
            precondition(
                window.toolbar === initialToolbar,
                "FAIL [3]: already-configured NSWindow must not be reconfigured on view recreation"
            )
            precondition(
                visibilityEvents.last == false,
                "FAIL [3]: closed window must not emit visible=true after view recreation"
            )

            // Reopen the same window, confirm visibility returns to true, verify minimize
            // does NOT unmount/reset Settings, then close again.
            window.orderFront(nil)
            window.makeKey()
            pumpMainRunLoop()
            precondition(window.isVisible, "FAIL [4]: reopened window must be visible")
            precondition(visibilityEvents.last == true, "FAIL [4]: reopen must emit visible=true")

            window.miniaturize(nil)
            pumpMainRunLoop(seconds: 0.12)
            precondition(
                visibilityEvents.last == true,
                "FAIL [4b]: miniaturizing to the Dock must not emit visible=false"
            )
            window.deminiaturize(nil)
            pumpMainRunLoop(seconds: 0.12)

            window.close()
            pumpMainRunLoop()
            precondition(!window.isVisible, "FAIL [4]: second close must keep window hidden")
            precondition(visibilityEvents.last == false, "FAIL [4]: second close must emit visible=false")
        }

        // 2. SwiftUI ZStack container identity test: toggling `isWindowVisible` across
        // close/reopen cycles must keep the exact same WindowConfiguringView instance alive.
        do {
            let window = NSWindow(
                contentRect: NSRect(x: 120, y: 120, width: 500, height: 620),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false

            var events: [Bool] = []
            let hostingView = NSHostingView(
                rootView: HostedSettingsHarness { events.append($0) }
            )
            window.contentView = hostingView
            window.orderFront(nil)
            pumpMainRunLoop(seconds: 0.12)

            let viewsInitially = findWindowConfiguringViews(in: window.contentView)
            precondition(
                viewsInitially.count == 1,
                "FAIL [5]: expected exactly 1 WindowConfiguringView, found \(viewsInitially.count)"
            )
            let originalView = viewsInitially[0]

            for cycle in 1...3 {
                window.close()
                pumpMainRunLoop(seconds: 0.12)
                precondition(!window.isVisible, "FAIL [6.\(cycle)]: window reopened itself after close()")
                precondition(events.last == false, "FAIL [6.\(cycle)]: expected visible=false after close()")

                let viewsAfterClose = findWindowConfiguringViews(in: window.contentView)
                precondition(
                    viewsAfterClose.count == 1 && viewsAfterClose[0] === originalView,
                    "FAIL [6.\(cycle)]: WindowConfiguringView identity changed after close()"
                )

                window.orderFront(nil)
                window.makeKey()
                pumpMainRunLoop(seconds: 0.12)
                precondition(window.isVisible, "FAIL [6.\(cycle)]: window failed to reopen")
                precondition(events.last == true, "FAIL [6.\(cycle)]: expected visible=true after reopen")

                let viewsAfterReopen = findWindowConfiguringViews(in: window.contentView)
                precondition(
                    viewsAfterReopen.count == 1 && viewsAfterReopen[0] === originalView,
                    "FAIL [6.\(cycle)]: WindowConfiguringView identity changed after reopen"
                )
            }

            window.close()
            pumpMainRunLoop(seconds: 0.1)
            precondition(!window.isVisible, "FAIL [7]: final close must keep window hidden")
        }

        print("PASS: settings_window_selftest (all close/reopen & identity invariants verified)")
    }
}
