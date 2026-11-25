//
//  RelockPolicyTests.swift
//  GlanceTests
//
//  Swift Testing suite for `RelockPolicy`, monotonic `AppLockEngine` relock timing,
//  and hostless test-bundle isolation verification.
//

import AppKit
import Foundation
import Testing

@Suite("RelockPolicy")
struct RelockPolicyTests {
    private let notes = AppLockEngine.App(pid: 101, bundleID: "com.apple.Notes", isRegular: true)
    private let safari = AppLockEngine.App(pid: 102, bundleID: "com.apple.Safari", isRegular: true)
    private let mail = AppLockEngine.App(pid: 104, bundleID: "com.apple.mail", isRegular: true)
    private let messages = AppLockEngine.App(pid: 105, bundleID: "com.apple.MobileSMS", isRegular: true)
    private let helper = AppLockEngine.App(pid: 103, bundleID: "com.apple.SecurityAgent", isRegular: false)
    private let glanceOwn = "com.pearleseed.glance"

    private func requireChallenge(
        in effects: [AppLockEngine.Effect],
        for expectedApp: AppLockEngine.App? = nil
    ) throws -> AppLockEngine.Challenge {
        for effect in effects {
            if case .raiseCurtain(let challenge) = effect {
                if let expectedApp {
                    #expect(challenge.app == expectedApp)
                }
                return challenge
            }
        }
        Issue.record("Expected raiseCurtain effect, got \(effects)")
        throw CancellationError()
    }

    @Test("Pure-logic bundle runs hostlessly in xctest without launching Glance.app")
    func pureLogicBundleDoesNotLaunchMainApp() {
        #expect(NSApp == nil)
        #expect(ProcessInfo.processInfo.processName == "xctest")
        #expect(Bundle.main.bundleIdentifier != glanceOwn)
        #expect(!Bundle.main.bundleURL.lastPathComponent.lowercased().hasSuffix(".app"))
    }

    @Test("Formats titles, shortTitles, durationSeconds, and clamps negative minutes")
    func formattingAndDurationProperties() {
        let everyTime = RelockPolicy.everyTime
        #expect(everyTime.title == "Every time")
        #expect(everyTime.shortTitle == "Every time")
        #expect(everyTime.durationSeconds == nil)

        let oneMinute = RelockPolicy.afterMinutes(1)
        #expect(oneMinute.title == "After 1 minute")
        #expect(oneMinute.shortTitle == "1m")
        #expect(oneMinute.durationSeconds == 60.0)

        let fiveMinutes = RelockPolicy.afterMinutes(5)
        #expect(fiveMinutes.title == "After 5 minutes")
        #expect(fiveMinutes.shortTitle == "5m")
        #expect(fiveMinutes.durationSeconds == 300.0)

        let oneFocusLoss = RelockPolicy.afterFocusLossMinutes(1)
        #expect(oneFocusLoss.title == "1 minute after leaving")
        #expect(oneFocusLoss.shortTitle == "1m away")
        #expect(oneFocusLoss.durationSeconds == 60.0)

        let fifteenFocusLoss = RelockPolicy.afterFocusLossMinutes(15)
        #expect(fifteenFocusLoss.title == "15 minutes after leaving")
        #expect(fifteenFocusLoss.shortTitle == "15m away")
        #expect(fifteenFocusLoss.durationSeconds == 900.0)

        #expect(RelockPolicy.afterMinutes(0).title == "After 0 minutes")
        #expect(RelockPolicy.afterMinutes(0).durationSeconds == 0.0)
        #expect(RelockPolicy.afterMinutes(-5).shortTitle == "0m")
        #expect(RelockPolicy.afterMinutes(-5).durationSeconds == 0.0)
        #expect(RelockPolicy.afterFocusLossMinutes(-3).shortTitle == "0m away")
        #expect(RelockPolicy.afterFocusLossMinutes(-3).durationSeconds == 0.0)
    }

    @Test("Preserves all RelockPolicy variants across JSON Codable round-trips and Set/Identifiable identity")
    func codableRoundTripAndIdentity() throws {
        let cases: [RelockPolicy] = [
            .everyTime,
            .afterMinutes(0),
            .afterMinutes(5),
            .afterFocusLossMinutes(1),
            .afterFocusLossMinutes(15)
        ]
        let encoded = try JSONEncoder().encode(cases)
        let decoded = try JSONDecoder().decode([RelockPolicy].self, from: encoded)
        #expect(decoded == cases)

        let uniqueSet: Set<RelockPolicy> = [.everyTime, .everyTime, .afterMinutes(5), .afterFocusLossMinutes(5)]
        #expect(uniqueSet.count == 3)
        #expect(Set(uniqueSet.map(\.id)).count == 3)
    }

    @Test("Every-time policy ignores non-regular helpers, hides on switch, and relocks on return")
    func everyTimeRelockBehavior() throws {
        var engine = AppLockEngine(ownBundleID: glanceOwn)
        _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])

        let challenge = try requireChallenge(in: engine.appActivated(notes, monotonicNow: 100), for: notes)
        _ = engine.passed(challengeID: challenge.id, monotonicNow: 101)

        #expect(engine.appActivated(notes, monotonicNow: 101.5).isEmpty)
        #expect(engine.appActivated(helper, monotonicNow: 102).isEmpty)

        let leaveEffects = engine.appActivated(safari, monotonicNow: 103)
        #expect(leaveEffects == [.hide(notes)])

        _ = try requireChallenge(in: engine.appActivated(notes, monotonicNow: 104), for: notes)
    }

    @Test("After-minutes policy stays unlocked before exact monotonic deadline and relocks at expiry")
    func afterMinutesMonotonicBoundaries() throws {
        var engine = AppLockEngine(ownBundleID: glanceOwn)
        _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(5)])

        let challenge = try requireChallenge(in: engine.appActivated(notes, monotonicNow: 1000.0), for: notes)
        _ = engine.passed(challengeID: challenge.id, monotonicNow: 1000.0)

        #expect(engine.appActivated(safari, monotonicNow: 1100.0).isEmpty)
        #expect(engine.appActivated(notes, monotonicNow: 1299.999).isEmpty)

        // Exact 300.0s boundary hides when leaving and challenges on return.
        let leaveAtExpiry = engine.appActivated(safari, monotonicNow: 1300.0)
        #expect(leaveAtExpiry == [.hide(notes)])
        _ = try requireChallenge(in: engine.appActivated(notes, monotonicNow: 1300.0), for: notes)
    }

    @Test("After-minutes expires on direct re-activation even without intermediate switch and clamps <= 0")
    func afterMinutesDirectExpiryAndZeroNegativeClamp() throws {
        var engine = AppLockEngine(ownBundleID: glanceOwn)
        _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(5)])

        let challenge = try requireChallenge(in: engine.appActivated(notes, monotonicNow: 1000.0), for: notes)
        _ = engine.passed(challengeID: challenge.id, monotonicNow: 1000.0)
        #expect(engine.appActivated(notes, monotonicNow: 1200.0).isEmpty)
        _ = try requireChallenge(in: engine.appActivated(notes, monotonicNow: 1300.0), for: notes)

        for nonPositive in [0, -1] {
            var immediateEngine = AppLockEngine(ownBundleID: glanceOwn)
            _ = immediateEngine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(nonPositive)])
            let c = try requireChallenge(in: immediateEngine.appActivated(notes, monotonicNow: 100), for: notes)
            _ = immediateEngine.passed(challengeID: c.id, monotonicNow: 100)
            #expect(immediateEngine.appActivated(safari, monotonicNow: 100.1) == [.hide(notes)])
            _ = try requireChallenge(in: immediateEngine.appActivated(notes, monotonicNow: 100.2), for: notes)
        }
    }

    @Test("After-focus-loss policy stays unlocked while focused, resets on return, and relocks at exact deadline")
    func afterFocusLossMonotonicBoundaries() throws {
        var engine = AppLockEngine(ownBundleID: glanceOwn)
        _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterFocusLossMinutes(2)])

        let challenge = try requireChallenge(in: engine.appActivated(notes, monotonicNow: 1000.0), for: notes)
        _ = engine.passed(challengeID: challenge.id, monotonicNow: 1000.0)

        // Staying focused or triggering a non-regular helper does not start the focus-loss timer.
        #expect(engine.appActivated(notes, monotonicNow: 5000.0).isEmpty)
        #expect(engine.appActivated(helper, monotonicNow: 6000.0).isEmpty)
        #expect(engine.appActivated(notes, monotonicNow: 7000.0).isEmpty)

        // Two separate 110s departures stay unlocked because focus return resets the timer.
        _ = engine.appActivated(safari, monotonicNow: 7010.0)
        #expect(engine.appActivated(notes, monotonicNow: 7120.0).isEmpty)
        _ = engine.appActivated(safari, monotonicNow: 7130.0)
        #expect(engine.appActivated(notes, monotonicNow: 7249.999).isEmpty)

        // 120.0s away triggers relock.
        _ = engine.appActivated(safari, monotonicNow: 7300.0)
        _ = try requireChallenge(in: engine.appActivated(notes, monotonicNow: 7420.0), for: notes)

        for nonPositive in [0, -2] {
            var immediateEngine = AppLockEngine(ownBundleID: glanceOwn)
            _ = immediateEngine.configure(
                isEnabled: true, policies: [notes.bundleID: .afterFocusLossMinutes(nonPositive)])
            let c = try requireChallenge(in: immediateEngine.appActivated(notes, monotonicNow: 100), for: notes)
            _ = immediateEngine.passed(challengeID: c.id, monotonicNow: 101)
            #expect(immediateEngine.appActivated(safari, monotonicNow: 102) == [.hide(notes)])
            _ = try requireChallenge(in: immediateEngine.appActivated(notes, monotonicNow: 103), for: notes)
        }
    }

    @Test("Handles out-of-order monotonic timestamps, mixed per-app policies, lockAll, and expiration delays")
    func mixedPoliciesLockAllAndExpirationDelay() throws {
        var orderEngine = AppLockEngine(ownBundleID: glanceOwn)
        _ = orderEngine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(5)])
        let orderChallenge = try requireChallenge(in: orderEngine.appActivated(notes, monotonicNow: 100), for: notes)
        _ = orderEngine.passed(challengeID: orderChallenge.id, monotonicNow: 100)
        #expect(orderEngine.appActivated(safari, monotonicNow: 100).isEmpty)
        #expect(orderEngine.appActivated(notes, monotonicNow: 99).isEmpty)

        // Mixed policies across three apps + deadline scheduling.
        var engine = AppLockEngine(ownBundleID: glanceOwn)
        _ = engine.configure(
            isEnabled: true,
            policies: [
                notes.bundleID: .everyTime,
                mail.bundleID: .afterMinutes(5),
                messages.bundleID: .afterFocusLossMinutes(2)
            ])

        let cNotes = try requireChallenge(in: engine.appActivated(notes, monotonicNow: 100), for: notes)
        _ = engine.passed(challengeID: cNotes.id, monotonicNow: 101)
        #expect(engine.nextExpirationDelay(at: 102) == nil)

        let toMail = engine.appActivated(mail, monotonicNow: 110)
        #expect(toMail.contains(.hide(notes)))
        let cMail = try requireChallenge(in: toMail, for: mail)
        _ = engine.passed(challengeID: cMail.id, monotonicNow: 112)
        #expect(engine.nextExpirationDelay(at: 112) == 300.0)

        let toMessages = engine.appActivated(messages, monotonicNow: 120)
        #expect(!toMessages.contains(.hide(mail)))
        let cMessages = try requireChallenge(in: toMessages, for: messages)
        _ = engine.passed(challengeID: cMessages.id, monotonicNow: 122)

        // Switching to Safari at 200 starts Messages 120s focus-loss timer (expires at 320 < Mail's 412).
        #expect(engine.appActivated(safari, monotonicNow: 200).isEmpty)
        #expect(engine.nextExpirationDelay(at: 210) == 110.0)
        #expect(engine.appActivated(mail, monotonicNow: 250).isEmpty)

        // Switch to Safari at 330 -> Messages focus loss 200..330 (130s >= 120s) hides Messages; Mail still valid.
        let toSafari = engine.appActivated(safari, monotonicNow: 330)
        #expect(toSafari == [.hide(messages)])
        #expect(engine.appActivated(mail, monotonicNow: 411).isEmpty)
        #expect(engine.nextExpirationDelay(at: 500) == 0.05)
        let cMailAgain = try requireChallenge(in: engine.appActivated(mail, monotonicNow: 412), for: mail)

        // lockAll() immediately revokes all policy variants (e.g., on screen lock or sleep).
        _ = engine.passed(challengeID: cMailAgain.id, monotonicNow: 501)
        let cMsgAgain = try requireChallenge(in: engine.appActivated(messages, monotonicNow: 502), for: messages)
        _ = engine.passed(challengeID: cMsgAgain.id, monotonicNow: 503)
        let cNotesAgain = try requireChallenge(in: engine.appActivated(notes, monotonicNow: 504), for: notes)
        _ = engine.passed(challengeID: cNotesAgain.id, monotonicNow: 505)

        let lockEffects = engine.lockAll()
        #expect(lockEffects.contains(.hide(notes)))
        #expect(lockEffects.contains(.hide(mail)))
        #expect(lockEffects.contains(.hide(messages)))
        #expect(engine.nextExpirationDelay(at: 506) == nil)
        _ = try requireChallenge(in: engine.appActivated(mail, monotonicNow: 507), for: mail)
        _ = engine.appActivated(safari, monotonicNow: 508)
        _ = try requireChallenge(in: engine.appActivated(messages, monotonicNow: 509), for: messages)
        _ = engine.appActivated(safari, monotonicNow: 510)
        _ = try requireChallenge(in: engine.appActivated(notes, monotonicNow: 511), for: notes)
    }
}
