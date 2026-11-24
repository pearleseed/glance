//
//  unlock_reliability_selftest.swift
//  glance (tools)
//
//  Offline self-test harness for lock-screen unlock reliability contracts:
//    1. `KeystrokeInjector.splitUTF16GraphemeRanges`: ASCII, Vietnamese NFC/NFD diacritics,
//       surrogate pairs, ZWJ emoji sequences, regional indicator flags, oversized clusters, empty input
//    2. `SecureCredentialManager.shouldInvalidateLoginKey(afterPasswordReadError:)`:
//       only invalidates on `.itemNotFound`, preserving login key across transient/ACL Keychain errors
//    3. `NotchGeometry.preferredDisplayIndex`: pinned display connected vs disconnected fallback,
//       physical notch priority, main fallback, and empty display topology
//    4. `UnlockTrigger.shouldResetArmForWake`: suppresses duplicate wake bursts while allowing
//       a wake immediately after `.onLock`
//
//  Compile and run from repo root:
//      swiftc -O -o /tmp/unlock_reliability_selftest \
//        glance/Settings/SettingsModels.swift \
//        glance/Recognition/FaceEmbedder.swift \
//        glance/Recognition/FaceEnrollmentStore.swift \
//        glance/Security/KeychainManager.swift \
//        glance/Security/SecureFaceStore.swift \
//        glance/Security/SecureCredentialManager.swift \
//        glance/Unlock/LockMonitor.swift \
//        glance/Unlock/KeystrokeInjector.swift \
//        glance/NotchOverlay/NotchPanelStyle.swift \
//        glance/NotchOverlay/NotchGeometry.swift \
//        tools/unlock_reliability_selftest.swift \
//      && /tmp/unlock_reliability_selftest
//

import CoreGraphics
import Foundation
import Security

private var passed = 0
private var failed = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if condition() {
        passed += 1
    } else {
        failed += 1
        fputs("FAIL (\(file):\(line)): \(message)\n", stderr)
    }
}

private func testGraphemeSplitting() {
    // 1. Empty input
    check(KeystrokeInjector.splitUTF16GraphemeRanges([]).isEmpty, "Empty UTF-16 buffer should produce no ranges")

    // 2. ASCII splits 1 code unit per event
    let ascii = KeystrokeInjector.decodeUTF8ToUTF16(Data("P@ssw0rd!".utf8))!
    let asciiRanges = KeystrokeInjector.splitUTF16GraphemeRanges(ascii)
    check(asciiRanges.count == 9, "ASCII password should produce 9 single-character events, got \(asciiRanges.count)")
    check(asciiRanges.allSatisfy { $0.count == 1 }, "Each ASCII event should have length 1")

    // 3. Vietnamese NFD combining diacritics stay attached to their base scalar
    // "e\u{0302}\u{0301}" (e + circumflex + acute) + "a"
    let nfdBytes = Data("e\u{0302}\u{0301}a".utf8)
    let nfdUTF16 = KeystrokeInjector.decodeUTF8ToUTF16(nfdBytes)!
    let nfdRanges = KeystrokeInjector.splitUTF16GraphemeRanges(nfdUTF16)
    check(nfdRanges == [0..<3, 3..<4], "NFD combining diacritics must stay in one grapheme cluster, got \(nfdRanges)")

    // 4. Surrogate pair (😀 = U+1F600 = 2 UTF-16 code units)
    let emojiUTF16 = KeystrokeInjector.decodeUTF8ToUTF16(Data("a😀b".utf8))!
    let emojiRanges = KeystrokeInjector.splitUTF16GraphemeRanges(emojiUTF16)
    check(emojiRanges == [0..<1, 1..<3, 3..<4], "Surrogate pair must not be split, got \(emojiRanges)")

    // 5. ZWJ emoji sequence (👩‍👩‍👧 = 8 UTF-16 units) stays in one event
    let zwjUTF16 = KeystrokeInjector.decodeUTF8ToUTF16(Data("x\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}y".utf8))!
    let zwjRanges = KeystrokeInjector.splitUTF16GraphemeRanges(zwjUTF16)
    check(zwjRanges.count == 3, "ZWJ emoji surrounded by ASCII should produce 3 ranges, got \(zwjRanges)")
    check(zwjRanges[1] == 1..<(zwjUTF16.count - 1), "ZWJ cluster must remain intact, got \(zwjRanges[1])")

    // 6. Regional indicator flag pair (🇻🇳 + 🇺🇸) splits between pairs, not inside a pair
    let flagsUTF16 = KeystrokeInjector.decodeUTF8ToUTF16(Data("🇻🇳🇺🇸".utf8))!
    let flagRanges = KeystrokeInjector.splitUTF16GraphemeRanges(flagsUTF16)
    check(flagRanges == [0..<4, 4..<8], "Two flag emojis must split into two 4-unit ranges, got \(flagRanges)")

    // 7. Oversized combining cluster (> maxClusterLength) splits safely without infinite loop
    var oversized: [UInt16] = [0x0061]  // 'a'
    oversized.append(contentsOf: Array(repeating: 0x0301, count: 25))  // 25 combining acutes
    let oversizedRanges = KeystrokeInjector.splitUTF16GraphemeRanges(oversized, maxClusterLength: 10)
    check(oversizedRanges.count == 3, "26-unit cluster with maxClusterLength=10 should split into 3 chunks, got \(oversizedRanges)")
    check(oversizedRanges.allSatisfy { $0.count <= 10 }, "No chunk may exceed maxClusterLength")
    check(oversizedRanges.map(\.count).reduce(0, +) == oversized.count, "Chunks must cover entire buffer")
}

private func testLoginKeyInvalidationPolicy() {
    check(
        SecureCredentialManager.shouldInvalidateLoginKey(afterPasswordReadError: KeychainError.itemNotFound),
        "Missing password item must invalidate stale login key"
    )
    check(
        !SecureCredentialManager.shouldInvalidateLoginKey(
            afterPasswordReadError: KeychainError.osStatus(errSecInteractionNotAllowed)
        ),
        "errSecInteractionNotAllowed must NOT delete login key"
    )
    check(
        !SecureCredentialManager.shouldInvalidateLoginKey(
            afterPasswordReadError: KeychainError.osStatus(errSecAuthFailed)
        ),
        "errSecAuthFailed must NOT delete login key"
    )
    check(
        !SecureCredentialManager.shouldInvalidateLoginKey(
            afterPasswordReadError: KeychainError.authenticationFailed
        ),
        "authenticationFailed must NOT delete login key"
    )
    check(
        !SecureCredentialManager.shouldInvalidateLoginKey(
            afterPasswordReadError: KeychainError.unexpectedData
        ),
        "unexpectedData must NOT delete login key"
    )
}

private func testPreferredDisplaySelection() {
    let external = NotchGeometry.DisplayCandidate(id: "2", hasPhysicalNotch: false, isMain: true)
    let builtin = NotchGeometry.DisplayCandidate(id: "1", hasPhysicalNotch: true, isMain: false)
    let secondary = NotchGeometry.DisplayCandidate(id: "3", hasPhysicalNotch: false, isMain: false)

    // 1. Pinned display connected -> selects pinned display
    check(
        NotchGeometry.preferredDisplayIndex(
            in: [external, builtin],
            preferredDisplayID: "1",
            allowFallbackWhenPinnedMissing: true
        ) == 1,
        "Connected pinned display must be selected"
    )

    // 2. Pinned display temporarily missing during wake with fallback enabled -> falls back to active display
    check(
        NotchGeometry.preferredDisplayIndex(
            in: [external],
            preferredDisplayID: "1",
            allowFallbackWhenPinnedMissing: true
        ) == 0,
        "Missing pinned display with fallback enabled must fall back to active display"
    )

    // 3. Pinned display missing with fallback disabled -> returns nil
    check(
        NotchGeometry.preferredDisplayIndex(
            in: [external],
            preferredDisplayID: "1",
            allowFallbackWhenPinnedMissing: false
        ) == nil,
        "Missing pinned display with fallback disabled must return nil"
    )

    // 4. Auto mode prefers physical notch over main external monitor
    check(
        NotchGeometry.preferredDisplayIndex(
            in: [external, builtin],
            preferredDisplayID: nil,
            allowFallbackWhenPinnedMissing: true
        ) == 1,
        "Auto mode should prefer notched display over non-notched main"
    )

    // 5. Auto mode without notch prefers main display
    check(
        NotchGeometry.preferredDisplayIndex(
            in: [secondary, external],
            preferredDisplayID: nil,
            allowFallbackWhenPinnedMissing: true
        ) == 1,
        "Auto mode without notch should prefer main display"
    )

    // 6. Auto mode without notch or main picks first screen
    check(
        NotchGeometry.preferredDisplayIndex(
            in: [secondary],
            preferredDisplayID: nil,
            allowFallbackWhenPinnedMissing: true
        ) == 0,
        "Auto mode with no main screen should fall back to first screen"
    )

    // 7. Empty candidate list -> nil
    check(
        NotchGeometry.preferredDisplayIndex(
            in: [],
            preferredDisplayID: nil,
            allowFallbackWhenPinnedMissing: true
        ) == nil,
        "Empty display list must return nil"
    )
}

private func testWakeRearmDebounce() {
    let debounce: Duration = .seconds(2)

    // 1. No prior arm -> always allow reset
    check(
        UnlockTrigger.shouldResetArmForWake(
            lastArmedTrigger: nil,
            elapsedSinceLastArm: nil,
            rearmDebounce: debounce
        ),
        "Wake with no prior arm should reset"
    )

    // 2. `.onLock` followed immediately by `.wake` (e.g. lock -> display wake within 0.3s) MUST reset
    check(
        UnlockTrigger.shouldResetArmForWake(
            lastArmedTrigger: .onLock,
            elapsedSinceLastArm: .milliseconds(300),
            rearmDebounce: debounce
        ),
        "Wake shortly after .onLock must NOT be suppressed"
    )

    // 3. Duplicate `.onWake` burst within 2s debounce MUST be suppressed
    check(
        !UnlockTrigger.shouldResetArmForWake(
            lastArmedTrigger: .onWake,
            elapsedSinceLastArm: .milliseconds(450),
            rearmDebounce: debounce
        ),
        "Duplicate .onWake within debounce window must be suppressed"
    )

    // 4. `.onWake` after debounce expires MUST reset
    check(
        UnlockTrigger.shouldResetArmForWake(
            lastArmedTrigger: .onWake,
            elapsedSinceLastArm: .seconds(2),
            rearmDebounce: debounce
        ),
        "Wake at/after debounce boundary must reset"
    )
}

@main
struct UnlockReliabilitySelfTest {
    static func main() {
        testGraphemeSplitting()
        testLoginKeyInvalidationPolicy()
        testPreferredDisplaySelection()
        testWakeRearmDebounce()

        print("unlock_reliability_selftest: \(passed) passed, \(failed) failed")
        if failed > 0 {
            exit(1)
        }
    }
}
