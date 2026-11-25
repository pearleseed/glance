//
//  KeystrokeInjector.swift
//  glance
//
//  Synthesizes keystrokes via CGEvent, posted at the HID tap so they reach the lock screen's secure text field.
//

import ApplicationServices
import CoreGraphics
import Foundation

enum KeystrokeError: LocalizedError {
    case accessibilityNotGranted
    case eventCreationFailed
    case invalidUTF8Password
    case screenUnlockedDuringInjection

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return
                "Accessibility permission required. Open System Settings → Privacy & Security → "
                + "Accessibility and enable glance."
        case .eventCreationFailed:
            return "Couldn't create CGEvent for keystroke."
        case .invalidUTF8Password:
            return "Stored password bytes were not valid UTF-8."
        case .screenUnlockedDuringInjection:
            return "Screen unlocked before password injection completed."
        }
    }
}

enum KeystrokeInjector {
    /// Returns true if the app has Accessibility permission (no prompt).
    nonisolated static func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Triggers the system prompt to grant Accessibility (deep links to System Settings).
    @discardableResult
    nonisolated static func promptForAccessibility() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Types the UTF-8 bytes into whatever has keyboard focus, then presses Return.
    /// Decodes UTF-8 directly into `[UInt16]` (never `Swift.String`) and wipes it with `memset_s` on exit.
    /// When `requireLockedScreen` is true, checks authoritative lock state before each phase and key event. Blocking.
    /// - Parameter singleGraphemeMode: Uses conservative per-grapheme events and longer settle delays
    ///   (used automatically on retry if the fast batched path left the screen locked).
    nonisolated static func typeAndReturn(
        _ passwordBytes: Data,
        requireLockedScreen: Bool = true,
        singleGraphemeMode: Bool = false
    ) throws {
        guard isAccessibilityTrusted() else { throw KeystrokeError.accessibilityNotGranted }
        guard var utf16 = decodeUTF8ToUTF16(passwordBytes) else { throw KeystrokeError.invalidUTF8Password }
        defer { zeroizeUTF16Buffer(&utf16) }

        try verifyScreenLockedIfNeeded(requireLockedScreen)
        let source = CGEventSource(stateID: .privateState)
        try clearFocusedField(source: source, requireLockedScreen: requireLockedScreen)
        if requireLockedScreen {
            // Give loginwindow a brief beat to unhide/focus the secure password field
            // after `clearFocusedField` wakes it (measured ~10ms in practice; 80ms on conservative retry).
            let settle = singleGraphemeMode ? retryPostClearSettleInterval : fastPostClearSettleInterval
            Thread.sleep(forTimeInterval: settle)
        }
        try verifyScreenLockedIfNeeded(requireLockedScreen)
        try postUnicodeBuffer(
            utf16,
            source: source,
            requireLockedScreen: requireLockedScreen,
            singleGraphemeMode: singleGraphemeMode
        )
        let preReturn = singleGraphemeMode ? retryPreReturnSettleInterval : fastPreReturnSettleInterval
        Thread.sleep(forTimeInterval: preReturn)
        try verifyScreenLockedIfNeeded(requireLockedScreen)
        try postReturn(source: source)
    }

    nonisolated private static func verifyScreenLockedIfNeeded(_ requireLockedScreen: Bool) throws {
        if requireLockedScreen, !LockMonitor.isScreenActuallyLocked() {
            throw KeystrokeError.screenUnlockedDuringInjection
        }
    }

    /// Decodes UTF-8 directly to UTF-16 code units without allocating a `Swift.String`.
    /// Zeroizes any partially decoded buffer before returning `nil` on malformed UTF-8.
    nonisolated static func decodeUTF8ToUTF16(_ data: Data) -> [UInt16]? {
        var utf16: [UInt16] = []
        utf16.reserveCapacity(data.count)
        var decoder = UTF8()
        var iterator = data.makeIterator()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                UTF16.encode(scalar) { utf16.append($0) }
            case .emptyInput:
                return utf16
            case .error:
                zeroizeUTF16Buffer(&utf16)
                return nil
            }
        }
    }

    nonisolated static func zeroizeUTF16Buffer(_ buffer: inout [UInt16]) {
        buffer.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress, ptr.count > 0 else { return }
            let byteCount = ptr.count * MemoryLayout<UInt16>.stride
            _ = memset_s(base, byteCount, 0, byteCount)
        }
    }

    /// Splits UTF-16 code units into batch ranges of at most `maxBatchLength` (clamped >= 2)
    /// without separating surrogate pairs or Unicode grapheme clusters across adjacent batches.
    /// Operates directly on `[UInt16]` and `Unicode.Scalar` so password data never touches `Swift.String`.
    nonisolated static func splitUTF16BatchRanges(
        _ utf16: [UInt16],
        maxBatchLength: Int = maximumUnicodeBatchLength
    ) -> [Range<Int>] {
        let limit = max(maxBatchLength, 2)
        var ranges: [Range<Int>] = []
        var start = 0
        while start < utf16.count {
            let rawEnd = min(start + limit, utf16.count)
            var end = rawEnd
            if end < utf16.count {
                while end > start && !isGraphemeBoundary(in: utf16, at: end) {
                    end = scalarStart(in: utf16, at: end - 1)
                }
                if end <= start {
                    // Single grapheme cluster exceeds `limit`; fall back to a surrogate-safe boundary
                    // so the loop always advances.
                    end = rawEnd
                    if end - 1 > start,
                        UTF16.isLeadSurrogate(utf16[end - 1]),
                        UTF16.isTrailSurrogate(utf16[end])
                    {
                        end -= 1
                    }
                }
            }
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    private nonisolated static func scalarStart(in utf16: [UInt16], at index: Int) -> Int {
        if index > 0,
            UTF16.isTrailSurrogate(utf16[index]),
            UTF16.isLeadSurrogate(utf16[index - 1])
        {
            return index - 1
        }
        return index
    }

    private nonisolated static func decodeScalar(in utf16: [UInt16], startingAt index: Int) -> Unicode.Scalar? {
        let unit = utf16[index]
        if UTF16.isLeadSurrogate(unit) {
            guard index + 1 < utf16.count, UTF16.isTrailSurrogate(utf16[index + 1]) else {
                return nil
            }
            let codePoint =
                0x10000
                + ((UInt32(unit) - 0xD800) << 10)
                + (UInt32(utf16[index + 1]) - 0xDC00)
            return Unicode.Scalar(codePoint)
        }
        if UTF16.isTrailSurrogate(unit) {
            return nil
        }
        return Unicode.Scalar(unit)
    }

    private nonisolated static func isGraphemeExtendingScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        let props = scalar.properties
        return props.canonicalCombiningClass != .notReordered
            || props.isGraphemeExtend
            || props.isVariationSelector
            || v == 0x200D
            || (0xFE00...0xFE0F).contains(v)
            || (0xE0100...0xE01EF).contains(v)
            || (0x1F3FB...0x1F3FF).contains(v)
    }

    private nonisolated static func isRegionalIndicator(_ scalar: Unicode.Scalar) -> Bool {
        (0x1F1E6...0x1F1FF).contains(scalar.value)
    }

    private nonisolated static func isGraphemeBoundary(in utf16: [UInt16], at index: Int) -> Bool {
        if UTF16.isTrailSurrogate(utf16[index]), UTF16.isLeadSurrogate(utf16[index - 1]) {
            return false
        }
        if utf16[index] == 0x000A, utf16[index - 1] == 0x000D {
            return false
        }
        guard let current = decodeScalar(in: utf16, startingAt: index) else {
            return true
        }
        if isGraphemeExtendingScalar(current) {
            return false
        }

        let prevStart = scalarStart(in: utf16, at: index - 1)
        guard let prev = decodeScalar(in: utf16, startingAt: prevStart) else {
            return true
        }
        if prev.value == 0x200D {
            return false
        }
        if isRegionalIndicator(current), isRegionalIndicator(prev) {
            var riCount = 1
            var cursor = prevStart
            while cursor > 0 {
                let earlierStart = scalarStart(in: utf16, at: cursor - 1)
                guard let earlier = decodeScalar(in: utf16, startingAt: earlierStart),
                    isRegionalIndicator(earlier)
                else {
                    break
                }
                riCount += 1
                cursor = earlierStart
            }
            if !riCount.isMultiple(of: 2) {
                return false
            }
        }
        return true
    }

    /// Wipes anything already typed into the focused field (e.g. a stray keypress
    /// on the lock screen) so it isn't prepended to the password: ⌘→ to the end,
    /// then ⌘⌫ to delete back to the start. Both are positional keys, so this
    /// behaves the same on every keyboard layout — unlike ⌘A, whose "A" moves.
    private nonisolated static func clearFocusedField(source: CGEventSource?, requireLockedScreen: Bool) throws {
        let rightArrow: CGKeyCode = 0x7C
        let delete: CGKeyCode = 0x33
        try verifyScreenLockedIfNeeded(requireLockedScreen)
        try postKey(rightArrow, flags: .maskCommand, source: source)
        try verifyScreenLockedIfNeeded(requireLockedScreen)
        try postKey(delete, flags: .maskCommand, source: source)
    }

    /// Posts a virtual key down/up, wrapped in a real ⌘ down/up when `flags`
    /// includes `.maskCommand` — some text fields ignore a bare flag without it.
    private nonisolated static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = [], source: CGEventSource?)
        throws
    {
        let command: CGKeyCode = 0x37
        let usesCommand = flags.contains(.maskCommand)
        if usesCommand {
            guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true) else {
                throw KeystrokeError.eventCreationFailed
            }
            commandDown.flags = .maskCommand
            commandDown.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: controlKeyInterval)
        }
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            throw KeystrokeError.eventCreationFailed
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: controlKeyInterval)
        keyUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: controlKeyInterval)
        if usesCommand {
            guard let commandUp = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false) else {
                throw KeystrokeError.eventCreationFailed
            }
            commandUp.flags = []
            commandUp.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: controlKeyInterval)
        }
    }

    /// Splits UTF-16 code units into single-grapheme-cluster ranges so each `CGEvent` delivers one
    /// character (keeping surrogate pairs, combining diacritics, and ZWJ emoji clusters intact).
    /// Avoids multi-character payload truncation or losing the entire password if one event is dropped
    /// while `loginwindow` is settling focus. Oversized clusters (> `maxClusterLength`) fall back to
    /// `splitUTF16BatchRanges` while zeroizing the temporary slice.
    nonisolated static func splitUTF16GraphemeRanges(
        _ utf16: [UInt16],
        maxClusterLength: Int = maximumUnicodeBatchLength
    ) -> [Range<Int>] {
        guard !utf16.isEmpty else { return [] }
        let limit = max(maxClusterLength, 2)
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(utf16.count)
        var start = 0
        while start < utf16.count {
            var end = start + 1
            while end < utf16.count && !isGraphemeBoundary(in: utf16, at: end) {
                end += 1
            }
            if end - start <= limit {
                ranges.append(start..<end)
            } else {
                var slice = Array(utf16[start..<end])
                defer { zeroizeUTF16Buffer(&slice) }
                for subrange in splitUTF16BatchRanges(slice, maxBatchLength: limit) {
                    ranges.append((start + subrange.lowerBound)..<(start + subrange.upperBound))
                }
            }
            start = end
        }
        return ranges
    }

    /// Quartz reliably delivers only a small Unicode payload per keyboard event.
    /// Batching at this conservative limit avoids the undocumented truncation seen
    /// with longer payloads while keeping lock-screen typing fast (~1 event for ≤20 chars).
    nonisolated static let maximumUnicodeBatchLength = 20
    nonisolated private static let controlKeyInterval: TimeInterval = 0.008
    nonisolated private static let unicodeEventInterval: TimeInterval = 0.003
    nonisolated private static let fastPostClearSettleInterval: TimeInterval = 0.025
    nonisolated private static let retryPostClearSettleInterval: TimeInterval = 0.08
    nonisolated private static let fastPreReturnSettleInterval: TimeInterval = 0.015
    nonisolated private static let retryPreReturnSettleInterval: TimeInterval = 0.03

    /// Posts the UTF-16 password buffer in surrogate/grapheme-safe batches (or single-grapheme events on retry),
    /// verifying lock state before each event.
    private nonisolated static func postUnicodeBuffer(
        _ utf16: [UInt16],
        source: CGEventSource?,
        requireLockedScreen: Bool,
        singleGraphemeMode: Bool
    ) throws {
        let ranges = singleGraphemeMode ? splitUTF16GraphemeRanges(utf16) : splitUTF16BatchRanges(utf16)
        try utf16.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for range in ranges {
                try verifyScreenLockedIfNeeded(requireLockedScreen)
                try postUnicode(
                    base.advanced(by: range.lowerBound),
                    length: range.count,
                    source: source
                )
            }
        }
    }

    /// Unicode injection bypasses keyboard-layout issues. The password is placed
    /// on a key-down event as a text batch; the matching key-up maintains normal
    /// secure-field event semantics.
    private nonisolated static func postUnicode(
        _ unicode: UnsafePointer<UInt16>,
        length: Int,
        source: CGEventSource?
    ) throws {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            throw KeystrokeError.eventCreationFailed
        }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.keyboardSetUnicodeString(stringLength: length, unicodeString: unicode)
        keyUp.keyboardSetUnicodeString(stringLength: length, unicodeString: unicode)
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: unicodeEventInterval)
        keyUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: unicodeEventInterval)
    }

    /// Physical Return key (virtual key 0x24).
    private nonisolated static func postReturn(source: CGEventSource?) throws {
        let returnKey: CGKeyCode = 0x24
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false)
        else {
            throw KeystrokeError.eventCreationFailed
        }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
        keyUp.post(tap: .cghidEventTap)
    }
}
