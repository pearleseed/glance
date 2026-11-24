//
//  applock_selftest.swift
//  glance (tools)
//
//  Offline, AppKit-free unit test suite for AppLockEngine v2, RelockPolicy, and AppLockBlacklist.
//
//  Compile and run from repo root:
//      swiftc -O -o /tmp/applock_selftest \
//        glance/AppLock/RelockPolicy.swift \
//        glance/AppLock/AppLockBlacklist.swift \
//        glance/AppLock/AppLockEngine.swift \
//        tools/applock_selftest.swift \
//      && /tmp/applock_selftest
//

import Foundation

private let notes = AppLockEngine.App(pid: 101, bundleID: "com.apple.Notes", isRegular: true)
private let safari = AppLockEngine.App(pid: 102, bundleID: "com.apple.Safari", isRegular: true)
private let mail = AppLockEngine.App(pid: 104, bundleID: "com.apple.mail", isRegular: true)
private let messages = AppLockEngine.App(pid: 105, bundleID: "com.apple.MobileSMS", isRegular: true)
private let helper = AppLockEngine.App(pid: 103, bundleID: "com.apple.SecurityAgent", isRegular: false)
private let glanceOwn = "com.pearleseed.glance"

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError("FAIL: \(message)")
    }
}

private func expectChallenge(
    in effects: [AppLockEngine.Effect],
    for app: AppLockEngine.App? = nil,
    _ message: String = "expected raiseCurtain"
) -> AppLockEngine.Challenge {
    for effect in effects {
        if case .raiseCurtain(let challenge) = effect {
            if let app, challenge.app != app {
                fatalError("FAIL: \(message) (got app \(challenge.app.bundleID), expected \(app.bundleID))")
            }
            return challenge
        }
    }
    fatalError("FAIL: \(message) (effects: \(effects))")
}

private func expectLowerCurtain(
    in effects: [AppLockEngine.Effect],
    challengeID: UUID? = nil,
    _ message: String = "expected lowerCurtain"
) -> AppLockEngine.Challenge {
    for effect in effects {
        if case .lowerCurtain(let challenge) = effect {
            if let challengeID, challenge.id != challengeID {
                continue
            }
            return challenge
        }
    }
    fatalError("FAIL: \(message) (effects: \(effects))")
}

private struct TestRunner {
    private(set) var passedCount = 0

    mutating func test(_ name: String, _ body: () -> Void) {
        body()
        passedCount += 1
    }
}

@main
struct AppLockSelfTest {
    static func main() {
        var runner = TestRunner()

        runBriefScenarios(&runner)
        runRelockPolicyTests(&runner)
        runBlacklistTests(&runner)
        runConfigureTests(&runner)
        runActivationTests(&runner)
        runMonotonicPolicyBoundaryTests(&runner)
        runChallengeLifecycleTests(&runner)
        runHideTerminateLockAndReconcileTests(&runner)
        runExpirationDelayTests(&runner)

        expect(runner.passedCount >= 72, "Expected at least 72 tests, ran \(runner.passedCount)")
        print(
            "PASS: AppLockEngine v2 (RelockPolicy monotonic + Blacklist + Touch ID fallback) — \(runner.passedCount) tests passed."
        )
    }

    // MARK: - Brief Core Scenarios (1..6)

    private static func runBriefScenarios(_ r: inout TestRunner) {
        r.test("brief-1: blacklist protects critical recovery/system apps while allowing Xcode with caution") {
            expect(AppLockBlacklist.isProtected("com.apple.finder", ownBundleID: glanceOwn), "Finder must be protected")
            expect(
                AppLockBlacklist.isProtected("com.apple.Terminal", ownBundleID: glanceOwn), "Terminal must be protected"
            )
            expect(
                AppLockBlacklist.isProtected("com.apple.SystemSettings", ownBundleID: glanceOwn),
                "SystemSettings must be protected")
            expect(AppLockBlacklist.isProtected(glanceOwn, ownBundleID: glanceOwn), "own bundle ID must be protected")
            expect(
                !AppLockBlacklist.isProtected("com.apple.dt.Xcode", ownBundleID: glanceOwn),
                "Xcode must not be hard-blocked")
            expect(AppLockBlacklist.isCautionApp("com.apple.dt.Xcode"), "Xcode must be caution app")
        }

        r.test("brief-2: .everyTime unlocks, ignores non-regular helper, hides on Safari, challenges on return") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let e1 = engine.appActivated(notes, monotonicNow: 100)
            guard case .raiseCurtain(let c1) = e1.first else { fatalError("FAIL: expected curtain on Notes") }
            _ = engine.passed(challengeID: c1.id, monotonicNow: 101)
            expect(engine.appActivated(helper, monotonicNow: 102).isEmpty, "non-regular app relocked Notes")
            let eLeave = engine.appActivated(safari, monotonicNow: 103)
            expect(eLeave.contains(.hide(notes)), "leaving .everyTime app must hide it")
            let eReturn = engine.appActivated(notes, monotonicNow: 104)
            guard case .raiseCurtain = eReturn.first else {
                fatalError("FAIL: returning to .everyTime app must challenge")
            }
        }

        r.test("brief-3: .afterMinutes(5) skips challenge within 5m and challenges after >5m") {
            var timed = AppLockEngine(ownBundleID: glanceOwn)
            _ = timed.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(5)])
            guard case .raiseCurtain(let c2) = timed.appActivated(notes, monotonicNow: 1000).first else {
                fatalError("FAIL")
            }
            _ = timed.passed(challengeID: c2.id, monotonicNow: 1001)
            _ = timed.appActivated(safari, monotonicNow: 1100)
            expect(timed.appActivated(notes, monotonicNow: 1200).isEmpty, "challenged before 5 min elapsed")
            _ = timed.appActivated(safari, monotonicNow: 1302)
            guard case .raiseCurtain = timed.appActivated(notes, monotonicNow: 1303).first else {
                fatalError("FAIL: did not challenge after 5 min expired")
            }
        }

        r.test("brief-4: .afterFocusLossMinutes(2) stays unlocked after 60s away, challenges after 125s away") {
            var idle = AppLockEngine(ownBundleID: glanceOwn)
            _ = idle.configure(isEnabled: true, policies: [notes.bundleID: .afterFocusLossMinutes(2)])
            guard case .raiseCurtain(let c3) = idle.appActivated(notes, monotonicNow: 2000).first else {
                fatalError("FAIL")
            }
            _ = idle.passed(challengeID: c3.id, monotonicNow: 2001)
            _ = idle.appActivated(safari, monotonicNow: 2010)
            expect(idle.appActivated(notes, monotonicNow: 2070).isEmpty, "relocked before 2 min focus loss")
            _ = idle.appActivated(safari, monotonicNow: 2100)
            guard case .raiseCurtain = idle.appActivated(notes, monotonicNow: 2225).first else {
                fatalError("FAIL: did not relock after > 2 min focus loss")
            }
        }

        r.test("brief-5: lockAll() revokes timed & focus-loss sessions immediately") {
            var timed = AppLockEngine(ownBundleID: glanceOwn)
            _ = timed.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(60)])
            guard case .raiseCurtain(let c4) = timed.appActivated(notes, monotonicNow: 3000).first else {
                fatalError("FAIL")
            }
            _ = timed.passed(challengeID: c4.id, monotonicNow: 3001)
            _ = timed.lockAll()
            guard case .raiseCurtain = timed.appActivated(notes, monotonicNow: 3005).first else {
                fatalError("FAIL: lockAll() did not revoke timed session")
            }
        }

        r.test("brief-6: Touch ID system prompt fallback grants temporary reopen ticket and redeems cleanly") {
            var fallback = AppLockEngine(ownBundleID: glanceOwn)
            _ = fallback.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            guard case .raiseCurtain(let c5) = fallback.appActivated(notes, monotonicNow: 4000).first else {
                fatalError("FAIL")
            }
            let promptEffects = fallback.systemPromptRequested(challengeID: c5.id)
            expect(
                promptEffects.contains(
                    .presentSystemPrompt(AppLockEngine.Challenge(id: c5.id, app: notes, phase: .systemPrompt))),
                "system prompt not emitted"
            )
            let successEffects = fallback.systemPromptFinished(challengeID: c5.id, success: true, monotonicNow: 4002)
            expect(successEffects.contains(.reopen(notes)), "reopen not emitted after Touch ID success")
            expect(fallback.appActivated(notes, monotonicNow: 4003).isEmpty, "reopen grant was not redeemed")
        }
    }

    // MARK: - Group A: RelockPolicy (7..14)

    private static func runRelockPolicyTests(_ r: inout TestRunner) {
        r.test("policy-1: .everyTime titles and equality") {
            let p = RelockPolicy.everyTime
            expect(!p.title.isEmpty && !p.shortTitle.isEmpty, "titles must be non-empty")
            expect(p.title == "Every time", "unexpected title: \(p.title)")
            expect(p.shortTitle == "Every time", "unexpected shortTitle: \(p.shortTitle)")
        }

        r.test("policy-2: .afterMinutes(1) singular formatting") {
            let p = RelockPolicy.afterMinutes(1)
            expect(p.title == "After 1 minute", "unexpected singular title: \(p.title)")
            expect(p.shortTitle == "1m", "unexpected shortTitle: \(p.shortTitle)")
        }

        r.test("policy-3: .afterMinutes(5) plural formatting") {
            let p = RelockPolicy.afterMinutes(5)
            expect(p.title == "After 5 minutes", "unexpected plural title: \(p.title)")
            expect(p.shortTitle == "5m", "unexpected shortTitle: \(p.shortTitle)")
        }

        r.test("policy-4: .afterFocusLossMinutes(1) singular formatting") {
            let p = RelockPolicy.afterFocusLossMinutes(1)
            expect(p.title == "1 minute after leaving", "unexpected title: \(p.title)")
            expect(p.shortTitle == "1m away", "unexpected shortTitle: \(p.shortTitle)")
        }

        r.test("policy-5: .afterFocusLossMinutes(15) plural formatting") {
            let p = RelockPolicy.afterFocusLossMinutes(15)
            expect(p.title == "15 minutes after leaving", "unexpected title: \(p.title)")
            expect(p.shortTitle == "15m away", "unexpected shortTitle: \(p.shortTitle)")
        }

        r.test("policy-6: zero and negative minutes clamp safely in display strings") {
            expect(RelockPolicy.afterMinutes(0).title == "After 0 minutes", "0m title mismatch")
            expect(RelockPolicy.afterMinutes(-5).shortTitle == "0m", "negative clamp shortTitle mismatch")
            expect(RelockPolicy.afterFocusLossMinutes(-3).shortTitle == "0m away", "negative focus clamp mismatch")
        }

        r.test("policy-7: Codable JSON round-trip preserves all variants") {
            let cases: [RelockPolicy] = [.everyTime, .afterMinutes(5), .afterFocusLossMinutes(15)]
            let data = try! JSONEncoder().encode(cases)
            let decoded = try! JSONDecoder().decode([RelockPolicy].self, from: data)
            expect(decoded == cases, "Codable round-trip mismatch: \(decoded)")
        }

        r.test("policy-8: Identifiable IDs and Hashable set uniqueness") {
            let set: Set<RelockPolicy> = [.everyTime, .everyTime, .afterMinutes(5), .afterFocusLossMinutes(5)]
            expect(set.count == 3, "Set deduplication mismatch")
            let ids = Set(set.map(\.id))
            expect(ids.count == 3, "Identifiable IDs must be distinct across variants")
        }
    }

    // MARK: - Group B: AppLockBlacklist (15..24)

    private static func runBlacklistTests(_ r: inout TestRunner) {
        r.test("blacklist-1: protects Activity Monitor") {
            expect(
                AppLockBlacklist.isProtected("com.apple.ActivityMonitor", ownBundleID: glanceOwn),
                "Activity Monitor must be protected")
        }

        r.test("blacklist-2: protects both SystemSettings and legacy systempreferences") {
            expect(
                AppLockBlacklist.isProtected("com.apple.SystemSettings", ownBundleID: glanceOwn),
                "SystemSettings must be protected")
            expect(
                AppLockBlacklist.isProtected("com.apple.systempreferences", ownBundleID: glanceOwn),
                "systempreferences must be protected")
        }

        r.test("blacklist-3: protects ownBundleID and handles nil or empty ownBundleID safely") {
            expect(
                AppLockBlacklist.isProtected("com.example.glance", ownBundleID: "com.example.glance"),
                "own bundle ID must be protected")
            expect(
                !AppLockBlacklist.isProtected("", ownBundleID: ""), "empty bundle ID must not match empty ownBundleID")
            expect(
                !AppLockBlacklist.isProtected("com.apple.Notes", ownBundleID: nil),
                "nil ownBundleID must allow normal apps")
        }

        r.test("blacklist-4: protection check is case-insensitive and trims whitespace") {
            expect(AppLockBlacklist.isProtected("COM.APPLE.FINDER", ownBundleID: glanceOwn), "case-insensitive Finder")
            expect(
                AppLockBlacklist.isProtected(" com.apple.terminal ", ownBundleID: glanceOwn),
                "trimmed lowercase Terminal")
            expect(
                AppLockBlacklist.isProtected("COM.PEARLESEED.GLANCE", ownBundleID: "com.pearleseed.glance"),
                "case-insensitive own bundle")
        }

        r.test("blacklist-5: allows normal apps and all 5 caution apps without hard-blocking") {
            let allowed = [
                "com.apple.Notes",
                "com.apple.Safari",
                "com.googlecode.iterm2",
                "com.mitchellh.ghostty",
                "dev.warp.Warp-Stable",
                "com.apple.dt.Xcode",
                "com.microsoft.VSCode"
            ]
            for id in allowed {
                expect(!AppLockBlacklist.isProtected(id, ownBundleID: glanceOwn), "\(id) must not be protected")
            }
        }

        r.test("blacklist-6: all 5 caution bundle IDs return true for isCautionApp") {
            let expectedCaution = [
                "com.googlecode.iterm2",
                "com.mitchellh.ghostty",
                "dev.warp.Warp-Stable",
                "com.apple.dt.Xcode",
                "com.microsoft.VSCode"
            ]
            for id in expectedCaution {
                expect(AppLockBlacklist.isCautionApp(id), "\(id) must be flagged as caution app")
            }
            expect(AppLockBlacklist.cautionBundleIDs.count >= 5, "cautionBundleIDs must include all 5 IDs")
        }

        r.test("blacklist-7: caution check is case-insensitive and false for protected/ordinary apps") {
            expect(AppLockBlacklist.isCautionApp("COM.MICROSOFT.VSCODE"), "VSCode case-insensitive caution")
            expect(!AppLockBlacklist.isCautionApp("com.apple.Notes"), "Notes must not be caution")
            expect(!AppLockBlacklist.isCautionApp("com.apple.Terminal"), "Apple Terminal is protected, not caution")
            expect(!AppLockBlacklist.isCautionApp(""), "empty ID must not be caution")
        }

        r.test("blacklist-8: 1-argument default ownBundleID overload compiles and works") {
            expect(AppLockBlacklist.isProtected("com.apple.finder"), "1-arg isProtected Finder failed")
            expect(!AppLockBlacklist.isProtected("com.apple.Notes"), "1-arg isProtected Notes failed")
        }
    }

    // MARK: - Group C: configure & Filtering (25..33)

    private static func runConfigureTests(_ r: inout TestRunner) {
        r.test("configure-1: disabled engine ignores locked apps") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: false, policies: [notes.bundleID: .everyTime])
            expect(engine.appActivated(notes, monotonicNow: 10).isEmpty, "disabled engine must not challenge")
        }

        r.test("configure-2: filters out protected system apps and ownBundleID") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(
                isEnabled: true,
                policies: [
                    "com.apple.finder": .everyTime,
                    "com.apple.Terminal": .everyTime,
                    "com.apple.SystemSettings": .everyTime,
                    "com.apple.systempreferences": .everyTime,
                    "com.apple.ActivityMonitor": .everyTime,
                    glanceOwn: .everyTime,
                    notes.bundleID: .everyTime
                ])
            expect(
                engine.policies.keys.sorted() == [notes.bundleID],
                "protected apps leaked into policies: \(engine.policies)")
            let finder = AppLockEngine.App(pid: 201, bundleID: "com.apple.finder", isRegular: true)
            let ownApp = AppLockEngine.App(pid: 202, bundleID: glanceOwn, isRegular: true)
            expect(engine.appActivated(finder, monotonicNow: 10).isEmpty, "Finder must never be challenged")
            expect(engine.appActivated(ownApp, monotonicNow: 11).isEmpty, "Own bundle must never be challenged")
        }

        r.test("configure-3: filters out empty bundle IDs") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: ["": .everyTime, notes.bundleID: .everyTime])
            expect(engine.policies.count == 1, "empty bundleID must be ignored")
        }

        r.test("configure-4: disabling mid-challenge lowers curtain without hiding app") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 10))
            let effects = engine.configure(isEnabled: false, policies: [notes.bundleID: .everyTime])
            expect(effects == [.lowerCurtain(c)], "disabling must lower curtain only, got \(effects)")
            expect(engine.activeChallenge == nil, "activeChallenge must be cleared")
        }

        r.test("configure-5: disabling clears unlocked sessions so re-enabling challenges") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(30)])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 10))
            _ = engine.passed(challengeID: c.id, monotonicNow: 11)
            _ = engine.configure(isEnabled: false, policies: [notes.bundleID: .afterMinutes(30)])
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(30)])
            _ = expectChallenge(
                in: engine.appActivated(notes, monotonicNow: 12), for: notes, "re-enabling must require fresh unlock")
        }

        r.test("configure-6: disabling clears pending reopenGrant") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 10))
            _ = engine.systemPromptRequested(challengeID: c.id)
            _ = engine.systemPromptFinished(challengeID: c.id, success: true, monotonicNow: 11)
            _ = engine.configure(isEnabled: false, policies: [notes.bundleID: .everyTime])
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            _ = expectChallenge(
                in: engine.appActivated(notes, monotonicNow: 12), for: notes,
                "reopenGrant must be invalidated after disable")
        }

        r.test("configure-7: removing locked app mid-challenge lowers active curtain") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime, mail.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 10), for: notes)
            let effects = engine.configure(isEnabled: true, policies: [mail.bundleID: .everyTime])
            expect(effects == [.lowerCurtain(c)], "removing challenged app must lower curtain")
            expect(engine.appActivated(notes, monotonicNow: 11).isEmpty, "removed app must no longer challenge")
        }

        r.test("configure-8: removing unlocked app clears its session if re-added later") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(60)])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 10))
            _ = engine.passed(challengeID: c.id, monotonicNow: 11)
            _ = engine.appActivated(safari, monotonicNow: 12)
            _ = engine.configure(isEnabled: true, policies: [:])
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(60)])
            _ = expectChallenge(
                in: engine.appActivated(notes, monotonicNow: 13), for: notes,
                "removed then re-added app must re-challenge")
        }

        r.test("configure-9: tightening background unlocked app policy to .everyTime revokes and hides it") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(30)])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 10))
            _ = engine.passed(challengeID: c.id, monotonicNow: 11)
            _ = engine.appActivated(safari, monotonicNow: 12)
            let effects = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            expect(effects.contains(.hide(notes)), "tightening background session to .everyTime must hide it")
            _ = expectChallenge(in: engine.appActivated(notes, monotonicNow: 13), for: notes)
        }
    }

    // MARK: - Group D: appActivated Core Flows (34..44)

    private static func runActivationTests(_ r: inout TestRunner) {
        r.test("activate-1: unlocked regular app emits empty effects") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            expect(engine.appActivated(safari, monotonicNow: 10).isEmpty, "unlocked app must not emit effects")
        }

        r.test("activate-2: locked regular app raises scanning curtain") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 10), for: notes)
            expect(c.phase == .scanning, "initial challenge phase must be .scanning")
        }

        r.test("activate-3: duplicate appActivated for challenged app does not emit duplicate curtain") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 10), for: notes)
            expect(
                engine.appActivated(notes, monotonicNow: 11).isEmpty,
                "duplicate activation must not raise a second curtain")
            expect(engine.activeChallenge == c, "original challenge must remain intact")
        }

        r.test("activate-4: duplicate appActivated for already-unlocked .everyTime frontmost app stays unlocked") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 10))
            _ = engine.passed(challengeID: c.id, monotonicNow: 11)
            expect(
                engine.appActivated(notes, monotonicNow: 12).isEmpty,
                "re-activating frontmost unlocked app must not relock")
        }

        r.test("activate-5: non-regular helper does not interrupt an active .scanning challenge") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 10))
            expect(engine.appActivated(helper, monotonicNow: 11).isEmpty, "helper must not cancel active challenge")
            expect(engine.activeChallenge == c, "active challenge must remain")
        }

        r.test("activate-6: non-regular helper is never challenged even if bundleID listed in policies") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [helper.bundleID: .everyTime])
            expect(engine.appActivated(helper, monotonicNow: 10).isEmpty, "non-regular helper must never be challenged")
        }

        r.test("activate-7: regular app with empty bundleID hides previous .everyTime app without self-challenge") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 10))
            _ = engine.passed(challengeID: c.id, monotonicNow: 11)
            let anonymous = AppLockEngine.App(pid: 999, bundleID: "", isRegular: true)
            let leaveEffects = engine.appActivated(anonymous, monotonicNow: 12)
            expect(leaveEffects == [.hide(notes)], "leaving Notes for regular anonymous app must hide Notes only")
        }

        r.test("activate-8: switching to another regular app mid-challenge lowers curtain and hides challenged app") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 10))
            let switchEffects = engine.appActivated(safari, monotonicNow: 11)
            expect(switchEffects.contains(.lowerCurtain(c)), "switching away mid-challenge must lower curtain")
            expect(switchEffects.contains(.hide(notes)), "switching away mid-challenge must hide challenged app")
            expect(engine.activeChallenge == nil, "activeChallenge must clear on switch away")
        }

        r.test(
            "activate-9: switching from unlocked .everyTime app directly to another locked app hides first and challenges second"
        ) {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime, mail.bundleID: .everyTime])
            let cNotes = expectChallenge(in: engine.appActivated(notes, monotonicNow: 10), for: notes)
            _ = engine.passed(challengeID: cNotes.id, monotonicNow: 11)
            let switchEffects = engine.appActivated(mail, monotonicNow: 12)
            expect(switchEffects.contains(.hide(notes)), "must hide first .everyTime app")
            _ = expectChallenge(in: switchEffects, for: mail, "must raise curtain for second locked app")
        }

        r.test(
            "activate-10: switching mid-challenge from one locked app directly to another lowers+hides first and challenges second"
        ) {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime, mail.bundleID: .everyTime])
            let c1 = expectChallenge(in: engine.appActivated(notes, monotonicNow: 10), for: notes)
            let effects = engine.appActivated(mail, monotonicNow: 11)
            expect(effects.contains(.lowerCurtain(c1)), "must lower first curtain")
            expect(effects.contains(.hide(notes)), "must hide first app")
            _ = expectChallenge(in: effects, for: mail, "must raise curtain for Mail")
        }

        r.test("activate-11: new PID for same bundleID does not inherit previous PID unlocked session") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(10)])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            _ = engine.passed(challengeID: c.id, monotonicNow: 101)
            _ = engine.appActivated(safari, monotonicNow: 110)
            let notesRelaunched = AppLockEngine.App(pid: 888, bundleID: notes.bundleID, isRegular: true)
            _ = expectChallenge(in: engine.appActivated(notesRelaunched, monotonicNow: 120), for: notesRelaunched)
        }
    }

    // MARK: - Group E: Monotonic RelockPolicy Boundaries (45..55)

    private static func runMonotonicPolicyBoundaryTests(_ r: inout TestRunner) {
        r.test("timer-1: .afterMinutes(5) stays unlocked at 299.999s after unlock") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(5)])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 1000.0))
            _ = engine.passed(challengeID: c.id, monotonicNow: 1000.0)
            expect(engine.appActivated(safari, monotonicNow: 1100.0).isEmpty, "leaving within 5m must not hide")
            expect(engine.appActivated(notes, monotonicNow: 1299.999).isEmpty, "299.999s must still be unlocked")
        }

        r.test("timer-2: .afterMinutes(5) challenges at exact 300.0s boundary") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(5)])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 1000.0))
            _ = engine.passed(challengeID: c.id, monotonicNow: 1000.0)
            let leaveEffects = engine.appActivated(safari, monotonicNow: 1300.0)
            expect(leaveEffects == [.hide(notes)], "leaving at exact expiry must hide expired app")
            _ = expectChallenge(in: engine.appActivated(notes, monotonicNow: 1300.0), for: notes)
        }

        r.test("timer-3: .afterMinutes(5) challenges on direct return at exact 300.0s without intermediate switch") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(5)])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 1000.0))
            _ = engine.passed(challengeID: c.id, monotonicNow: 1000.0)
            _ = engine.appActivated(safari, monotonicNow: 1100.0)
            _ = expectChallenge(in: engine.appActivated(notes, monotonicNow: 1300.0), for: notes)
        }

        r.test("timer-4: .afterMinutes(5) expires on re-activation even if user never switched away") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(5)])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 1000.0))
            _ = engine.passed(challengeID: c.id, monotonicNow: 1000.0)
            expect(
                engine.appActivated(notes, monotonicNow: 1200.0).isEmpty, "before 5m duplicate activate stays unlocked")
            _ = expectChallenge(
                in: engine.appActivated(notes, monotonicNow: 1300.0), for: notes, "past 5m must challenge")
        }

        r.test("timer-5: .afterMinutes(0) and negative minutes expire immediately on leaving or re-activation") {
            for badMinutes in [0, -1] {
                var engine = AppLockEngine(ownBundleID: glanceOwn)
                _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(badMinutes)])
                let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
                _ = engine.passed(challengeID: c.id, monotonicNow: 100)
                let leave = engine.appActivated(safari, monotonicNow: 100.1)
                expect(leave == [.hide(notes)], "0/negative afterMinutes must hide on leave")
                _ = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100.2), for: notes)
            }
        }

        r.test("timer-6: .afterFocusLossMinutes(2) stays unlocked indefinitely while remaining focused") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterFocusLossMinutes(2)])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            _ = engine.passed(challengeID: c.id, monotonicNow: 101)
            expect(
                engine.appActivated(notes, monotonicNow: 5000).isEmpty,
                "staying focused must not expire focus-loss timer")
            expect(engine.appActivated(helper, monotonicNow: 6000).isEmpty, "helper must not start focus-loss timer")
            expect(engine.appActivated(notes, monotonicNow: 7000).isEmpty, "still unlocked after helper")
        }

        r.test("timer-7: .afterFocusLossMinutes(2) resets timer each time focus returns before expiry") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterFocusLossMinutes(2)])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 1000))
            _ = engine.passed(challengeID: c.id, monotonicNow: 1000)

            _ = engine.appActivated(safari, monotonicNow: 1010)
            expect(engine.appActivated(notes, monotonicNow: 1120).isEmpty, "110s away < 120s")
            _ = engine.appActivated(safari, monotonicNow: 1130)
            expect(
                engine.appActivated(notes, monotonicNow: 1240).isEmpty,
                "second 110s away < 120s even though total > 240s")
            _ = engine.appActivated(safari, monotonicNow: 1250)
            _ = expectChallenge(in: engine.appActivated(notes, monotonicNow: 1370), for: notes, "120s away must expire")
        }

        r.test("timer-8: .afterFocusLossMinutes(2) stays unlocked at 119.999s away and expires at 120.0s") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterFocusLossMinutes(2)])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 2000))
            _ = engine.passed(challengeID: c.id, monotonicNow: 2000)
            _ = engine.appActivated(safari, monotonicNow: 2010.0)
            expect(engine.appActivated(notes, monotonicNow: 2129.999).isEmpty, "119.999s must stay unlocked")
            _ = engine.appActivated(safari, monotonicNow: 2200.0)
            _ = expectChallenge(in: engine.appActivated(notes, monotonicNow: 2320.0), for: notes, "120.0s must expire")
        }

        r.test("timer-9: .afterFocusLossMinutes(0) and negative expire immediately on focus loss") {
            for badMinutes in [0, -2] {
                var engine = AppLockEngine(ownBundleID: glanceOwn)
                _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterFocusLossMinutes(badMinutes)])
                let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
                _ = engine.passed(challengeID: c.id, monotonicNow: 101)
                let leave = engine.appActivated(safari, monotonicNow: 102)
                expect(leave == [.hide(notes)], "0/negative focus-loss must hide immediately on leaving")
                _ = expectChallenge(in: engine.appActivated(notes, monotonicNow: 103), for: notes)
            }
        }

        r.test(
            "timer-10: non-advancing or slightly out-of-order timestamps do not crash or falsely expire positive timers"
        ) {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(5)])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            _ = engine.passed(challengeID: c.id, monotonicNow: 100)
            expect(engine.appActivated(safari, monotonicNow: 100).isEmpty, "zero elapsed must not expire")
            expect(
                engine.appActivated(notes, monotonicNow: 99).isEmpty, "negative delta must not expire positive timer")
        }

        r.test(
            "timer-11: multi-app mixed policies track independent monotonic timers and prune expired background sessions"
        ) {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(
                isEnabled: true,
                policies: [
                    notes.bundleID: .everyTime,
                    mail.bundleID: .afterMinutes(5),
                    messages.bundleID: .afterFocusLossMinutes(2)
                ])
            let cNotes = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100), for: notes)
            _ = engine.passed(challengeID: cNotes.id, monotonicNow: 101)

            // Switching from Notes (.everyTime) to Mail (.afterMinutes(5)) hides Notes and challenges Mail
            let toMail = engine.appActivated(mail, monotonicNow: 110)
            expect(toMail.contains(.hide(notes)), "Notes must hide")
            let cMail = expectChallenge(in: toMail, for: mail)
            _ = engine.passed(challengeID: cMail.id, monotonicNow: 112)

            // Switching from Mail to Messages (.afterFocusLossMinutes(2)) leaves Mail unlocked
            let toMessages = engine.appActivated(messages, monotonicNow: 120)
            expect(!toMessages.contains(.hide(mail)), "Mail must not hide within 5m")
            let cMsg = expectChallenge(in: toMessages, for: messages)
            _ = engine.passed(challengeID: cMsg.id, monotonicNow: 122)

            // Switching to Safari at 200 starts Messages focus loss at 200; Mail still unlocked
            expect(engine.appActivated(safari, monotonicNow: 200).isEmpty, "neither Mail nor Messages expired at 200")
            // Return to Mail at 250 (< 300s since 112) -> unlocked
            expect(engine.appActivated(mail, monotonicNow: 250).isEmpty, "Mail must stay unlocked at 250")
            // Switch to Safari at 330 -> Messages focus loss was 200..330 (130s >= 120s) -> hides Messages!
            let toSafari = engine.appActivated(safari, monotonicNow: 330)
            expect(
                toSafari == [.hide(messages)],
                "expired background Messages must hide, Mail stays unlocked; got \(toSafari)")
            // Return to Mail at 411 (< 300s since 112: 299s) -> unlocked; at 412 (>= 300s) -> challenges
            expect(engine.appActivated(mail, monotonicNow: 411).isEmpty, "Mail unlocked at 299s")
            _ = expectChallenge(in: engine.appActivated(mail, monotonicNow: 412), for: mail, "Mail expired at 300s")
        }
    }

    // MARK: - Group F: Challenge Lifecycle (56..66)

    private static func runChallengeLifecycleTests(_ r: inout TestRunner) {
        r.test("challenge-1: passed emits lowerCurtain and clears activeChallenge") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            let effects = engine.passed(challengeID: c.id, monotonicNow: 101)
            expect(effects == [.lowerCurtain(c)], "passed must lower curtain")
            expect(engine.activeChallenge == nil, "activeChallenge must be nil after pass")
        }

        r.test("challenge-2: passed ignores wrong UUID or duplicate call") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            expect(engine.passed(challengeID: UUID(), monotonicNow: 101).isEmpty, "wrong challengeID must be ignored")
            expect(engine.activeChallenge == c, "challenge must remain active")
            _ = engine.passed(challengeID: c.id, monotonicNow: 102)
            expect(engine.passed(challengeID: c.id, monotonicNow: 103).isEmpty, "duplicate pass must be no-op")
        }

        r.test("challenge-3: passed is ignored once challenge enters .systemPrompt phase") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            _ = engine.systemPromptRequested(challengeID: c.id)
            expect(
                engine.passed(challengeID: c.id, monotonicNow: 101).isEmpty,
                "face pass must be ignored during systemPrompt")
            expect(engine.activeChallenge?.phase == .systemPrompt, "challenge must stay in systemPrompt")
        }

        r.test("challenge-4: cancel during .scanning lowers curtain, hides app, and does not unlock") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(10)])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            let cancelEffects = engine.cancel(challengeID: c.id)
            expect(cancelEffects.contains(.lowerCurtain(c)), "cancel must lower curtain")
            expect(cancelEffects.contains(.hide(notes)), "cancel must hide locked app")
            expect(engine.activeChallenge == nil, "activeChallenge must clear on cancel")
            _ = expectChallenge(
                in: engine.appActivated(notes, monotonicNow: 101), for: notes, "cancelled challenge must not unlock")
        }

        r.test("challenge-5: cancel ignores unknown or stale challengeID") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            expect(engine.cancel(challengeID: UUID()).isEmpty, "unknown ID must be ignored")
            expect(engine.activeChallenge == c, "challenge must stay active")
        }

        r.test("challenge-6: systemPromptRequested lowers curtain, hides app, and emits presentSystemPrompt") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            let effects = engine.systemPromptRequested(challengeID: c.id)
            let expectedPrompt = AppLockEngine.Challenge(id: c.id, app: notes, phase: .systemPrompt)
            expect(effects.contains(.lowerCurtain(c)), "systemPromptRequested must lower curtain")
            expect(effects.contains(.hide(notes)), "systemPromptRequested must hide app")
            expect(effects.contains(.presentSystemPrompt(expectedPrompt)), "must emit presentSystemPrompt")
            expect(engine.activeChallenge == expectedPrompt, "phase must update to .systemPrompt")
        }

        r.test("challenge-7: systemPromptRequested ignores wrong ID or duplicate call") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            expect(engine.systemPromptRequested(challengeID: UUID()).isEmpty, "wrong ID ignored")
            _ = engine.systemPromptRequested(challengeID: c.id)
            expect(engine.systemPromptRequested(challengeID: c.id).isEmpty, "duplicate systemPromptRequested ignored")
        }

        r.test("challenge-8: reopen grant is single-use; leaving .everyTime after redemption relocks") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 4000))
            _ = engine.systemPromptRequested(challengeID: c.id)
            let finishEffects = engine.systemPromptFinished(challengeID: c.id, success: true, monotonicNow: 4001)
            expect(finishEffects == [.reopen(notes)], "success must emit reopen")
            expect(engine.appActivated(notes, monotonicNow: 4002).isEmpty, "first activation redeems reopen grant")
            expect(
                engine.appActivated(safari, monotonicNow: 4002.5) == [.hide(notes)],
                "leaving after redemption must hide .everyTime app")
            _ = expectChallenge(
                in: engine.appActivated(notes, monotonicNow: 4003), for: notes, "reopen grant must not work twice")
        }

        r.test("challenge-9: unused reopen grant expires after reopenGrantTTL") {
            var engine = AppLockEngine(ownBundleID: glanceOwn, reopenGrantTTL: 5.0)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 4000))
            _ = engine.systemPromptRequested(challengeID: c.id)
            _ = engine.systemPromptFinished(challengeID: c.id, success: true, monotonicNow: 4002)
            _ = expectChallenge(
                in: engine.appActivated(notes, monotonicNow: 4007.1), for: notes, "expired reopen grant must challenge")
        }

        r.test("challenge-10: systemPromptFinished(success: false) clears challenge without reopen or unlock") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(10)])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 4000))
            _ = engine.systemPromptRequested(challengeID: c.id)
            let failEffects = engine.systemPromptFinished(challengeID: c.id, success: false, monotonicNow: 4002)
            expect(failEffects.isEmpty, "failed system prompt must emit no reopen effects")
            expect(engine.activeChallenge == nil, "challenge must clear after failure")
            _ = expectChallenge(
                in: engine.appActivated(notes, monotonicNow: 4003), for: notes, "failed prompt must not unlock")
        }

        r.test("challenge-11: underlying unlocked app surfacing after hide in systemPrompt does not abort Touch ID") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 4000))
            _ = engine.systemPromptRequested(challengeID: c.id)
            // Hiding Notes causes macOS to activate Safari underneath while Touch ID prompt is open
            expect(
                engine.appHidden(pid: notes.pid, monotonicNow: 4000.1).isEmpty,
                "hide notification must not cancel systemPrompt")
            expect(
                engine.appActivated(safari, monotonicNow: 4000.2).isEmpty,
                "Safari surfacing must not cancel systemPrompt")
            let okEffects = engine.systemPromptFinished(challengeID: c.id, success: true, monotonicNow: 4002)
            expect(okEffects == [.reopen(notes)], "Touch ID completion must still reopen Notes")
            expect(engine.appActivated(notes, monotonicNow: 4003).isEmpty, "reopen grant must still redeem cleanly")
        }

        r.test(
            "challenge-12: activating another locked app during .systemPrompt cancels old prompt and ignores late completion"
        ) {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime, mail.bundleID: .everyTime])
            let cNotes = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100), for: notes)
            _ = engine.systemPromptRequested(challengeID: cNotes.id)
            let mailEffects = engine.appActivated(mail, monotonicNow: 101)
            let cMail = expectChallenge(in: mailEffects, for: mail, "locked Mail must be challenged")
            expect(!mailEffects.contains(.lowerCurtain(cNotes)), "systemPrompt curtain was already lowered")
            expect(!mailEffects.contains(.hide(notes)), "systemPrompt app was already hidden")
            expect(
                engine.systemPromptFinished(challengeID: cNotes.id, success: true, monotonicNow: 102).isEmpty,
                "late completion for superseded prompt must be ignored")
            expect(engine.activeChallenge == cMail, "Mail challenge must remain active")
        }

        r.test("challenge-13: reopenGrant requires matching bundleID and PID") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 4000))
            _ = engine.systemPromptRequested(challengeID: c.id)
            _ = engine.systemPromptFinished(challengeID: c.id, success: true, monotonicNow: 4001)
            let otherNotesPID = AppLockEngine.App(pid: 909, bundleID: notes.bundleID, isRegular: true)
            _ = expectChallenge(
                in: engine.appActivated(otherNotesPID, monotonicNow: 4002), for: otherNotesPID,
                "different PID must not consume reopen grant")
        }

        r.test(
            "challenge-14: re-activating or reconciling challenged app during .systemPrompt re-hides it and prevents cancel bypass"
        ) {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 4000))
            _ = engine.systemPromptRequested(challengeID: c.id)

            let reactivateEffects = engine.appActivated(notes, monotonicNow: 4001)
            expect(
                reactivateEffects == [.hide(notes)],
                "re-activating challenged app during .systemPrompt must re-hide it, got \(reactivateEffects)")
            expect(engine.activeChallenge?.phase == .systemPrompt, "systemPrompt challenge must remain active")

            let reconcileEffects = engine.reconcile(frontmost: notes, running: [notes], monotonicNow: 4001.5)
            expect(
                reconcileEffects == [.hide(notes)],
                "reconcile with frontmost challenged app during .systemPrompt must re-hide it, got \(reconcileEffects)")
            expect(
                engine.activeChallenge?.phase == .systemPrompt,
                "systemPrompt challenge must remain active after reconcile")

            let cancelEffects = engine.systemPromptFinished(challengeID: c.id, success: false, monotonicNow: 4002)
            expect(cancelEffects.isEmpty, "cancelled systemPrompt must not reopen")
            _ = expectChallenge(
                in: engine.appActivated(notes, monotonicNow: 4003), for: notes,
                "cancelled prompt must require fresh challenge")
        }

        r.test(
            "challenge-15: Touch ID success still reopens and redeems after re-activating challenged app during .systemPrompt"
        ) {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 4000))
            _ = engine.systemPromptRequested(challengeID: c.id)
            expect(engine.appActivated(notes, monotonicNow: 4001) == [.hide(notes)], "must hide on stray re-activation")
            let okEffects = engine.systemPromptFinished(challengeID: c.id, success: true, monotonicNow: 4002)
            expect(okEffects == [.reopen(notes)], "valid Touch ID must still emit reopen")
            expect(engine.appActivated(notes, monotonicNow: 4003).isEmpty, "reopen grant must redeem after reopen")
        }
    }

    // MARK: - Group G: appHidden, appTerminated, lockAll, reconcile (67..79)

    private static func runHideTerminateLockAndReconcileTests(_ r: inout TestRunner) {
        r.test("hide-1: appHidden mid-.scanning-challenge lowers curtain without extra hide and does not unlock") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            let hideEffects = engine.appHidden(pid: notes.pid, monotonicNow: 101)
            expect(hideEffects == [.lowerCurtain(c)], "hiding challenged app must lower curtain only")
            expect(engine.activeChallenge == nil, "challenge must clear")
            _ = expectChallenge(in: engine.appActivated(notes, monotonicNow: 102), for: notes)
        }

        r.test("hide-2: appHidden revokes .everyTime unlocked session") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            _ = engine.passed(challengeID: c.id, monotonicNow: 101)
            expect(engine.appHidden(pid: notes.pid, monotonicNow: 102).isEmpty, "appHidden itself emits no hide")
            _ = expectChallenge(
                in: engine.appActivated(notes, monotonicNow: 103), for: notes,
                "hidden .everyTime app must challenge on return")
        }

        r.test(
            "hide-3: appHidden preserves valid .afterMinutes(5) session and avoids duplicate hide when expired later"
        ) {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(5)])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 1000))
            _ = engine.passed(challengeID: c.id, monotonicNow: 1000)
            _ = engine.appHidden(pid: notes.pid, monotonicNow: 1050)
            expect(engine.appActivated(notes, monotonicNow: 1200).isEmpty, "unhiding within 5m stays unlocked")
            _ = engine.appHidden(pid: notes.pid, monotonicNow: 1250)
            expect(
                engine.appActivated(safari, monotonicNow: 1350).isEmpty,
                "already-hidden expired session should not emit redundant hide")
            _ = expectChallenge(in: engine.appActivated(notes, monotonicNow: 1351), for: notes)
        }

        r.test("hide-4: appHidden starts .afterFocusLossMinutes(2) timer and expires after 2m hidden") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterFocusLossMinutes(2)])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 2000))
            _ = engine.passed(challengeID: c.id, monotonicNow: 2001)
            _ = engine.appHidden(pid: notes.pid, monotonicNow: 2010)
            expect(engine.appActivated(notes, monotonicNow: 2100).isEmpty, "90s hidden < 120s")
            _ = engine.appHidden(pid: notes.pid, monotonicNow: 2110)
            _ = expectChallenge(
                in: engine.appActivated(notes, monotonicNow: 2230), for: notes, "120s hidden must expire")
        }

        r.test("terminate-1: appTerminated mid-challenge lowers curtain without hide") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            let effects = engine.appTerminated(pid: notes.pid)
            expect(effects == [.lowerCurtain(c)], "terminating challenged app must lower curtain only")
            expect(engine.activeChallenge == nil, "challenge cleared")
        }

        r.test("terminate-2: appTerminated clears unlocked .afterMinutes session") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(30)])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            _ = engine.passed(challengeID: c.id, monotonicNow: 101)
            expect(engine.appTerminated(pid: notes.pid).isEmpty, "terminating unlocked app emits no curtain/hide")
            _ = expectChallenge(
                in: engine.appActivated(notes, monotonicNow: 105), for: notes,
                "relaunching terminated app must challenge")
        }

        r.test("terminate-3: appTerminated invalidates pending reopenGrant") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            _ = engine.systemPromptRequested(challengeID: c.id)
            _ = engine.systemPromptFinished(challengeID: c.id, success: true, monotonicNow: 101)
            _ = engine.appTerminated(pid: notes.pid)
            _ = expectChallenge(
                in: engine.appActivated(notes, monotonicNow: 102), for: notes,
                "terminated app must not reuse reopen grant")
        }

        r.test("lockAll-1: lockAll revokes all three policy kinds simultaneously and hides visible unlocked sessions") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(
                isEnabled: true,
                policies: [
                    notes.bundleID: .everyTime,
                    mail.bundleID: .afterMinutes(60),
                    messages.bundleID: .afterFocusLossMinutes(30)
                ])
            let cMail = expectChallenge(in: engine.appActivated(mail, monotonicNow: 100))
            _ = engine.passed(challengeID: cMail.id, monotonicNow: 101)
            let cMsg = expectChallenge(in: engine.appActivated(messages, monotonicNow: 102))
            _ = engine.passed(challengeID: cMsg.id, monotonicNow: 103)
            let cNotes = expectChallenge(in: engine.appActivated(notes, monotonicNow: 104))
            _ = engine.passed(challengeID: cNotes.id, monotonicNow: 105)

            let lockEffects = engine.lockAll()
            expect(lockEffects.contains(.hide(notes)), "lockAll must hide visible Notes")
            expect(lockEffects.contains(.hide(mail)), "lockAll must hide visible Mail")
            expect(lockEffects.contains(.hide(messages)), "lockAll must hide visible Messages")
            _ = expectChallenge(in: engine.appActivated(mail, monotonicNow: 106), for: mail)
            _ = engine.appActivated(safari, monotonicNow: 107)
            _ = expectChallenge(in: engine.appActivated(messages, monotonicNow: 108), for: messages)
        }

        r.test("lockAll-2: lockAll lowers active scanning curtain, hides challenged app, and clears reopenGrant") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c1 = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            let lockScanning = engine.lockAll()
            expect(lockScanning.contains(.lowerCurtain(c1)), "lockAll must lower active curtain")
            expect(lockScanning.contains(.hide(notes)), "lockAll must hide challenged app")
            expect(engine.activeChallenge == nil, "activeChallenge cleared")

            let c2 = expectChallenge(in: engine.appActivated(notes, monotonicNow: 200))
            _ = engine.systemPromptRequested(challengeID: c2.id)
            _ = engine.systemPromptFinished(challengeID: c2.id, success: true, monotonicNow: 201)
            _ = engine.lockAll()
            _ = expectChallenge(
                in: engine.appActivated(notes, monotonicNow: 202), for: notes, "lockAll must invalidate reopenGrant")
        }

        r.test("reconcile-1: raises curtain when locked app is already frontmost on enable") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let effects = engine.reconcile(frontmost: notes, running: [notes, safari], monotonicNow: 500)
            _ = expectChallenge(in: effects, for: notes, "reconcile must challenge frontmost locked app")
        }

        r.test("reconcile-2: is idempotent when locked app already has active challenge or valid unlocked session") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.reconcile(frontmost: notes, running: [notes], monotonicNow: 500))
            expect(
                engine.reconcile(frontmost: notes, running: [notes], monotonicNow: 501).isEmpty,
                "reconcile must not re-challenge")
            _ = engine.passed(challengeID: c.id, monotonicNow: 502)
            expect(
                engine.reconcile(frontmost: notes, running: [notes], monotonicNow: 503).isEmpty,
                "reconcile must keep unlocked frontmost")
            expect(
                engine.reconcile(frontmost: helper, running: [notes, helper], monotonicNow: 504).isEmpty,
                "reconcile must ignore non-regular frontmost helper")
        }

        r.test(
            "reconcile-3: cleans up dead PIDs without emitting hide and lowers curtain for terminated challenged app"
        ) {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(
                isEnabled: true, policies: [notes.bundleID: .everyTime, mail.bundleID: .afterMinutes(10)])
            let cMail = expectChallenge(in: engine.appActivated(mail, monotonicNow: 100))
            _ = engine.passed(challengeID: cMail.id, monotonicNow: 101)
            let cNotes = expectChallenge(in: engine.appActivated(notes, monotonicNow: 102))

            // Both Notes and Mail died without appTerminated; Safari is now frontmost
            let effects = engine.reconcile(frontmost: safari, running: [safari], monotonicNow: 110)
            expect(
                effects == [.lowerCurtain(cNotes)],
                "must lower dead challenge curtain without hiding dead apps, got \(effects)")
            _ = expectChallenge(
                in: engine.appActivated(mail, monotonicNow: 111), for: mail, "dead Mail session must be purged")
        }

        r.test("reconcile-4: catches missed focus switches and expires stale background sessions") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(
                isEnabled: true,
                policies: [
                    notes.bundleID: .everyTime,
                    mail.bundleID: .afterMinutes(5),
                    messages.bundleID: .afterFocusLossMinutes(2)
                ])
            let cNotes = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            _ = engine.passed(challengeID: cNotes.id, monotonicNow: 101)
            // Missed appActivated(safari): reconcile sees Safari is frontmost -> must hide Notes (.everyTime)
            let rec1 = engine.reconcile(frontmost: safari, running: [notes, safari], monotonicNow: 102)
            expect(rec1 == [.hide(notes)], "reconcile must hide background .everyTime app")
            _ = expectChallenge(in: engine.appActivated(notes, monotonicNow: 103), for: notes)

            // Unlock Mail (.afterMinutes(5)) and Messages (.afterFocusLossMinutes(2)), then Safari becomes frontmost via reconcile
            let cMail = expectChallenge(in: engine.appActivated(mail, monotonicNow: 200))
            _ = engine.passed(challengeID: cMail.id, monotonicNow: 200)
            let cMsg = expectChallenge(in: engine.appActivated(messages, monotonicNow: 205))
            _ = engine.passed(challengeID: cMsg.id, monotonicNow: 205)

            // At 210, Safari is frontmost -> starts Messages focus loss at 210; neither expired yet
            expect(
                engine.reconcile(frontmost: safari, running: [mail, messages, safari], monotonicNow: 210).isEmpty,
                "neither expired at 210")
            // At 330, Messages focus loss 330-210 = 120s (expired!); Mail 330-200 = 130s (still valid)
            let rec2 = engine.reconcile(frontmost: safari, running: [mail, messages, safari], monotonicNow: 330)
            expect(rec2 == [.hide(messages)], "reconcile must hide expired focus-loss session only, got \(rec2)")
            // At 500, Mail 500-200 = 300s (expired!)
            let rec3 = engine.reconcile(frontmost: safari, running: [mail, messages, safari], monotonicNow: 500)
            expect(rec3 == [.hide(mail)], "reconcile must hide expired timed session, got \(rec3)")
        }

        r.test("reconcile-5: nil frontmost lowers and hides active .scanning challenge") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100), for: notes)
            let effects = engine.reconcile(frontmost: nil, running: [notes], monotonicNow: 101)
            expect(effects.contains(.lowerCurtain(c)), "nil frontmost must lower active curtain")
            expect(effects.contains(.hide(notes)), "nil frontmost must hide challenged app")
            expect(engine.activeChallenge == nil, "activeChallenge cleared on nil frontmost")
        }

        r.test("reconcile-6: nil frontmost preserves active .systemPrompt challenge while app is still running") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 4000), for: notes)
            _ = engine.systemPromptRequested(challengeID: c.id)

            let recEffects = engine.reconcile(frontmost: nil, running: [notes], monotonicNow: 4001)
            expect(recEffects.isEmpty, "nil frontmost must not emit effects or cancel .systemPrompt, got \(recEffects)")
            expect(
                engine.activeChallenge == AppLockEngine.Challenge(id: c.id, app: notes, phase: .systemPrompt),
                "nil frontmost must preserve .systemPrompt challenge")

            let okEffects = engine.systemPromptFinished(challengeID: c.id, success: true, monotonicNow: 4002)
            expect(
                okEffects == [.reopen(notes)], "systemPromptFinished must still reopen after nil frontmost reconcile")
            expect(engine.appActivated(notes, monotonicNow: 4003).isEmpty, "reopen grant must still redeem")
        }

        r.test("reconcile-7: nil frontmost still clears .systemPrompt when challenged app is no longer running") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 4000), for: notes)
            _ = engine.systemPromptRequested(challengeID: c.id)

            let recEffects = engine.reconcile(frontmost: nil, running: [], monotonicNow: 4001)
            expect(recEffects.isEmpty, "dead .systemPrompt app emits no curtain/hide, got \(recEffects)")
            expect(engine.activeChallenge == nil, "dead .systemPrompt app must clear activeChallenge")
            expect(
                engine.systemPromptFinished(challengeID: c.id, success: true, monotonicNow: 4002).isEmpty,
                "stale Touch ID completion for terminated app must be ignored")
        }
    }

    // MARK: - Group H: Deadline-Driven Timer Scheduling (nextExpirationDelay & hasActiveChallenge)

    private static func runExpirationDelayTests(_ r: inout TestRunner) {
        r.test("delay-1: empty engine with no unlockedSessions and no reopenGrant returns nil") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(5)])
            expect(engine.nextExpirationDelay(at: 100) == nil, "idle engine must return nil delay")
            expect(!engine.hasActiveChallenge, "idle engine must have hasActiveChallenge == false")
        }

        r.test("delay-2: unlocked .everyTime app returns nil delay") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            _ = engine.passed(challengeID: c.id, monotonicNow: 101)
            expect(engine.nextExpirationDelay(at: 102) == nil, ".everyTime session must return nil delay")
        }

        r.test(
            "delay-3: .afterFocusLossMinutes returns nil while focused, then returns earliest deadline across mixed apps"
        ) {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(
                isEnabled: true,
                policies: [
                    notes.bundleID: .afterMinutes(5),
                    mail.bundleID: .afterFocusLossMinutes(1)
                ])
            // Unlock app A (.afterMinutes(5)) at t=100 (expires at t=400)
            let cNotes = expectChallenge(in: engine.appActivated(notes, monotonicNow: 99))
            _ = engine.passed(challengeID: cNotes.id, monotonicNow: 100)
            expect(engine.nextExpirationDelay(at: 100) == 300.0, "expected 300.0s for Notes")

            // Unlock app B (.afterFocusLossMinutes(1)) at t=110; still focused so its countdown hasn't started
            let cMail = expectChallenge(in: engine.appActivated(mail, monotonicNow: 109))
            _ = engine.passed(challengeID: cMail.id, monotonicNow: 110)
            expect(engine.nextExpirationDelay(at: 115) == 285.0, "focused Mail must not start focus-loss countdown")

            // App B loses focus at t=120 (expires at t=180, earlier than App A at t=400)
            _ = engine.appActivated(safari, monotonicNow: 120)
            let delay = engine.nextExpirationDelay(at: 130)
            expect(delay == 50.0, "expected earliest expiration delay 50.0 at t=130, got \(String(describing: delay))")
        }

        r.test(
            "delay-4: changing policy to .everyTime, calling lockAll(), or removing app from policies clears delay to nil"
        ) {
            // Case A: tighten policy to .everyTime
            var engineA = AppLockEngine(ownBundleID: glanceOwn)
            _ = engineA.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(5)])
            let cA = expectChallenge(in: engineA.appActivated(notes, monotonicNow: 100))
            _ = engineA.passed(challengeID: cA.id, monotonicNow: 101)
            expect(engineA.nextExpirationDelay(at: 102) != nil, "timed session must have delay")
            _ = engineA.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            expect(engineA.nextExpirationDelay(at: 102) == nil, "switching policy to .everyTime must return nil delay")

            // Case B: lockAll()
            var engineB = AppLockEngine(ownBundleID: glanceOwn)
            _ = engineB.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(5)])
            let cB = expectChallenge(in: engineB.appActivated(notes, monotonicNow: 100))
            _ = engineB.passed(challengeID: cB.id, monotonicNow: 101)
            _ = engineB.lockAll()
            expect(engineB.nextExpirationDelay(at: 102) == nil, "lockAll() must return nil delay")

            // Case C: removing app from policies
            var engineC = AppLockEngine(ownBundleID: glanceOwn)
            _ = engineC.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(5)])
            let cC = expectChallenge(in: engineC.appActivated(notes, monotonicNow: 100))
            _ = engineC.passed(challengeID: cC.id, monotonicNow: 101)
            _ = engineC.configure(isEnabled: true, policies: [:])
            expect(engineC.nextExpirationDelay(at: 102) == nil, "removing app from policies must return nil delay")
        }

        r.test("delay-5: expired-in-past deadline clamps to >= 0.05") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .afterMinutes(1)])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            _ = engine.passed(challengeID: c.id, monotonicNow: 100)
            let delay = engine.nextExpirationDelay(at: 200)
            expect(delay == 0.05, "past-due expiration must clamp to 0.05, got \(String(describing: delay))")
        }

        r.test("delay-6: reopenGrant contributes reopenGrantTTL deadline and clears after reconcile expiry") {
            var engine = AppLockEngine(ownBundleID: glanceOwn, reopenGrantTTL: 5.0)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            _ = engine.systemPromptRequested(challengeID: c.id)
            _ = engine.systemPromptFinished(challengeID: c.id, success: true, monotonicNow: 100)

            expect(engine.nextExpirationDelay(at: 102) == 3.0, "reopenGrant must report remaining TTL 3.0s")
            expect(
                engine.nextExpirationDelay(at: 106) == 0.05, "expired reopenGrant must clamp to 0.05 before reconcile")
            _ = engine.reconcile(frontmost: safari, running: [notes, safari], monotonicNow: 106)
            expect(
                engine.nextExpirationDelay(at: 106) == nil,
                "reconcile past reopenGrantTTL must prune grant so delay becomes nil")
        }

        r.test("delay-7: hasActiveChallenge tracks .scanning and .systemPrompt phases accurately") {
            var engine = AppLockEngine(ownBundleID: glanceOwn)
            _ = engine.configure(isEnabled: true, policies: [notes.bundleID: .everyTime])
            expect(!engine.hasActiveChallenge, "no active challenge initially")

            let c = expectChallenge(in: engine.appActivated(notes, monotonicNow: 100))
            expect(engine.hasActiveChallenge, "hasActiveChallenge must be true during .scanning")

            _ = engine.systemPromptRequested(challengeID: c.id)
            expect(engine.hasActiveChallenge, "hasActiveChallenge must remain true during .systemPrompt")

            _ = engine.systemPromptFinished(challengeID: c.id, success: false, monotonicNow: 101)
            expect(!engine.hasActiveChallenge, "hasActiveChallenge must be false after challenge finishes")
        }
    }
}
