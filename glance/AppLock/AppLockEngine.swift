//
//  AppLockEngine.swift
//  glance
//

import Foundation

/// Pure value-type state machine for App Lock v2.
/// Emits declarative `[Effect]` commands so all transitions can be tested offline without AppKit.
nonisolated struct AppLockEngine: Sendable {
    struct App: Equatable, Hashable, Sendable {
        let pid: Int32
        let bundleID: String
        let isRegular: Bool
    }

    enum ChallengePhase: Equatable, Hashable, Sendable {
        case scanning
        case systemPrompt
    }

    struct Challenge: Equatable, Hashable, Sendable {
        let id: UUID
        let app: App
        let phase: ChallengePhase

        init(id: UUID = UUID(), app: App, phase: ChallengePhase = .scanning) {
            self.id = id
            self.app = app
            self.phase = phase
        }
    }

    enum Effect: Equatable, Hashable, Sendable {
        case raiseCurtain(Challenge)
        case lowerCurtain(Challenge)
        case hide(App)
        case reopen(App)
        case presentSystemPrompt(Challenge)
    }

    private struct UnlockedSession: Equatable, Sendable {
        var app: App
        let unlockedAt: TimeInterval
        var lostFocusAt: TimeInterval?
        var isHidden: Bool
    }

    private struct ReopenGrant: Equatable, Sendable {
        let bundleID: String
        let pid: Int32
        let grantedAt: TimeInterval
    }

    static let defaultReopenGrantTTL: TimeInterval = 5.0

    private let ownBundleID: String?
    private let reopenGrantTTL: TimeInterval

    private(set) var isEnabled: Bool = false
    private(set) var policies: [String: RelockPolicy] = [:]
    private(set) var activeChallenge: Challenge?

    private var unlockedSessions: [String: UnlockedSession] = [:]
    private var reopenGrant: ReopenGrant?
    private var frontmostRegularApp: App?

    init(
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        reopenGrantTTL: TimeInterval = AppLockEngine.defaultReopenGrantTTL
    ) {
        self.ownBundleID = ownBundleID
        self.reopenGrantTTL = max(0, reopenGrantTTL)
    }

    /// Updates App Lock enablement and per-bundle relock policies, pruning protected or removed entries.
    mutating func configure(isEnabled: Bool, policies rawPolicies: [String: RelockPolicy]) -> [Effect] {
        var filtered: [String: RelockPolicy] = [:]
        for (bundleID, policy) in rawPolicies {
            guard !bundleID.isEmpty,
                !AppLockBlacklist.isProtected(bundleID, ownBundleID: ownBundleID)
            else { continue }
            filtered[bundleID] = policy
        }
        self.policies = filtered
        self.isEnabled = isEnabled

        var effects: [Effect] = []

        if !isEnabled {
            unlockedSessions.removeAll()
            reopenGrant = nil
            effects.append(contentsOf: clearActiveChallenge())
            return effects
        }

        if let challenge = activeChallenge, filtered[challenge.app.bundleID] == nil {
            effects.append(contentsOf: clearActiveChallenge())
        }

        if let grant = reopenGrant, filtered[grant.bundleID] == nil {
            reopenGrant = nil
        }

        for bundleID in unlockedSessions.keys.sorted() {
            guard let policy = filtered[bundleID] else {
                unlockedSessions.removeValue(forKey: bundleID)
                continue
            }
            if case .everyTime = policy,
                let session = unlockedSessions[bundleID],
                frontmostRegularApp?.bundleID != bundleID
            {
                unlockedSessions.removeValue(forKey: bundleID)
                if !session.isHidden {
                    effects.append(.hide(session.app))
                }
            }
        }

        return effects
    }

    /// Handles `NSWorkspace.didActivateApplicationNotification`.
    mutating func appActivated(_ app: App, monotonicNow: TimeInterval) -> [Effect] {
        guard app.isRegular else { return [] }
        return activateRegularApp(app, monotonicNow: monotonicNow)
    }

    /// Handles `NSWorkspace.didHideApplicationNotification`.
    mutating func appHidden(pid: Int32, monotonicNow: TimeInterval) -> [Effect] {
        if let challenge = activeChallenge, challenge.app.pid == pid {
            if frontmostRegularApp?.pid == pid {
                frontmostRegularApp = nil
            }
            // During `.systemPrompt`, hiding was initiated by `systemPromptRequested` so keep the prompt alive.
            return challenge.phase == .scanning ? clearActiveChallenge() : []
        }

        if frontmostRegularApp?.pid == pid {
            frontmostRegularApp = nil
        }

        for bundleID in unlockedSessions.keys.sorted() {
            guard var session = unlockedSessions[bundleID], session.app.pid == pid else { continue }
            guard let policy = policies[bundleID] else {
                unlockedSessions.removeValue(forKey: bundleID)
                continue
            }
            switch policy {
            case .everyTime:
                unlockedSessions.removeValue(forKey: bundleID)
            case .afterMinutes:
                if isExpired(session, policy: policy, at: monotonicNow) {
                    unlockedSessions.removeValue(forKey: bundleID)
                } else {
                    session.isHidden = true
                    unlockedSessions[bundleID] = session
                }
            case .afterFocusLossMinutes:
                if session.lostFocusAt == nil {
                    session.lostFocusAt = monotonicNow
                }
                if isExpired(session, policy: policy, at: monotonicNow) {
                    unlockedSessions.removeValue(forKey: bundleID)
                } else {
                    session.isHidden = true
                    unlockedSessions[bundleID] = session
                }
            }
        }

        return []
    }

    /// Handles `NSWorkspace.didTerminateApplicationNotification`.
    mutating func appTerminated(pid: Int32) -> [Effect] {
        var effects: [Effect] = []

        if activeChallenge?.app.pid == pid {
            effects.append(contentsOf: clearActiveChallenge())
        }

        if frontmostRegularApp?.pid == pid {
            frontmostRegularApp = nil
        }

        for bundleID in unlockedSessions.keys.sorted() where unlockedSessions[bundleID]?.app.pid == pid {
            unlockedSessions.removeValue(forKey: bundleID)
        }

        if let grant = reopenGrant, grant.pid == pid {
            reopenGrant = nil
        }

        return effects
    }

    /// Reconciles engine state against a live workspace snapshot (frontmost + running apps).
    mutating func reconcile(frontmost: App?, running: [App], monotonicNow: TimeInterval) -> [Effect] {
        let runningPIDs = Set(running.map(\.pid))
        var effects: [Effect] = []

        for bundleID in unlockedSessions.keys.sorted() {
            if let session = unlockedSessions[bundleID], !runningPIDs.contains(session.app.pid) {
                unlockedSessions.removeValue(forKey: bundleID)
            }
        }

        if let grant = reopenGrant, !runningPIDs.contains(grant.pid) {
            reopenGrant = nil
        }

        if let challenge = activeChallenge, !runningPIDs.contains(challenge.app.pid) {
            effects.append(contentsOf: clearActiveChallenge())
        }

        if let prev = frontmostRegularApp, !runningPIDs.contains(prev.pid) {
            frontmostRegularApp = nil
        }

        if !isEnabled {
            if let frontmost, frontmost.isRegular {
                frontmostRegularApp = frontmost
            }
            return effects
        }

        if let frontmost {
            if frontmost.isRegular {
                effects.append(contentsOf: activateRegularApp(frontmost, monotonicNow: monotonicNow))
            } else {
                effects.append(
                    contentsOf: pruneUnlockedSessions(excluding: nil, at: monotonicNow, onRegularSwitch: false))
            }
            return effects
        }

        frontmostRegularApp = nil
        if activeChallenge?.phase == .scanning {
            effects.append(contentsOf: clearActiveChallenge(hidingApp: true))
        }
        effects.append(contentsOf: pruneUnlockedSessions(excluding: nil, at: monotonicNow, onRegularSwitch: false))
        return effects
    }

    /// Immediately revokes all unlocked sessions (`.everyTime`, timed, and focus-loss) and active challenges.
    mutating func lockAll() -> [Effect] {
        var effects = clearActiveChallenge(hidingApp: true)

        for bundleID in unlockedSessions.keys.sorted() {
            if let session = unlockedSessions[bundleID], !session.isHidden {
                effects.append(.hide(session.app))
            }
        }

        unlockedSessions.removeAll()
        reopenGrant = nil
        frontmostRegularApp = nil

        return effects
    }

    /// Marks the active face-scan challenge as passed and creates an unlocked session.
    mutating func passed(challengeID: UUID, monotonicNow: TimeInterval) -> [Effect] {
        guard let challenge = activeChallenge,
            challenge.id == challengeID,
            challenge.phase == .scanning
        else { return [] }

        activeChallenge = nil
        frontmostRegularApp = challenge.app

        if isEnabled, policies[challenge.app.bundleID] != nil {
            unlockedSessions[challenge.app.bundleID] = UnlockedSession(
                app: challenge.app,
                unlockedAt: monotonicNow,
                lostFocusAt: nil,
                isHidden: false
            )
        }

        return [.lowerCurtain(challenge)]
    }

    /// Transitions an active `.scanning` challenge into system Touch ID / password authentication.
    mutating func systemPromptRequested(challengeID: UUID) -> [Effect] {
        guard let challenge = activeChallenge,
            challenge.id == challengeID,
            challenge.phase == .scanning
        else { return [] }

        let promptChallenge = Challenge(id: challenge.id, app: challenge.app, phase: .systemPrompt)
        activeChallenge = promptChallenge
        if frontmostRegularApp?.pid == challenge.app.pid {
            frontmostRegularApp = nil
        }

        return [.lowerCurtain(challenge), .hide(challenge.app), .presentSystemPrompt(promptChallenge)]
    }

    /// Completes the system authentication prompt; on success, emits `.reopen` and grants a one-time reopen ticket.
    mutating func systemPromptFinished(challengeID: UUID, success: Bool, monotonicNow: TimeInterval) -> [Effect] {
        guard let challenge = activeChallenge,
            challenge.id == challengeID,
            challenge.phase == .systemPrompt
        else { return [] }

        activeChallenge = nil
        guard success, isEnabled, policies[challenge.app.bundleID] != nil else {
            return []
        }

        reopenGrant = ReopenGrant(
            bundleID: challenge.app.bundleID,
            pid: challenge.app.pid,
            grantedAt: monotonicNow
        )

        return [.reopen(challenge.app)]
    }

    /// Cancels an active challenge, lowering any curtain and hiding the app without unlocking it.
    mutating func cancel(challengeID: UUID) -> [Effect] {
        guard let challenge = activeChallenge, challenge.id == challengeID else { return [] }
        if frontmostRegularApp?.pid == challenge.app.pid {
            frontmostRegularApp = nil
        }
        return clearActiveChallenge(hidingApp: true)
    }
}

// MARK: - Helpers

nonisolated extension AppLockEngine {
    private mutating func clearActiveChallenge(hidingApp: Bool = false) -> [Effect] {
        guard let challenge = activeChallenge else { return [] }
        activeChallenge = nil
        guard challenge.phase == .scanning else { return [] }
        return hidingApp ? [.lowerCurtain(challenge), .hide(challenge.app)] : [.lowerCurtain(challenge)]
    }

    private mutating func activateRegularApp(_ app: App, monotonicNow: TimeInterval) -> [Effect] {
        frontmostRegularApp = app
        guard isEnabled else { return [] }

        var effects: [Effect] = []
        let policyForApp = lockPolicy(for: app)

        if let challenge = activeChallenge {
            let isSameTarget = challenge.app.pid == app.pid && challenge.app.bundleID == app.bundleID
            if isSameTarget {
                effects.append(
                    contentsOf: pruneUnlockedSessions(excluding: app.bundleID, at: monotonicNow, onRegularSwitch: true))
                if challenge.phase == .systemPrompt {
                    // Re-hide the challenged app if the user clicks it in the Dock or Cmd+Tabs while Touch ID is open.
                    frontmostRegularApp = nil
                    effects.append(.hide(app))
                }
                return effects
            }

            switch challenge.phase {
            case .scanning:
                effects.append(contentsOf: clearActiveChallenge(hidingApp: true))
            case .systemPrompt:
                if let policyForApp, !hasValidSessionOrGrant(for: app, policy: policyForApp, at: monotonicNow) {
                    activeChallenge = nil
                } else {
                    effects.append(
                        contentsOf: pruneUnlockedSessions(
                            excluding: app.bundleID, at: monotonicNow, onRegularSwitch: true))
                    return effects
                }
            }
        }

        effects.append(
            contentsOf: pruneUnlockedSessions(excluding: app.bundleID, at: monotonicNow, onRegularSwitch: true))

        guard let policy = policyForApp else {
            return effects
        }

        if let grant = reopenGrant {
            if isReopenGrantValid(grant, for: app, at: monotonicNow) {
                reopenGrant = nil
                unlockedSessions[app.bundleID] = UnlockedSession(
                    app: app,
                    unlockedAt: monotonicNow,
                    lostFocusAt: nil,
                    isHidden: false
                )
                return effects
            } else if (monotonicNow - grant.grantedAt) > reopenGrantTTL || grant.bundleID == app.bundleID {
                reopenGrant = nil
            }
        }

        if var session = unlockedSessions[app.bundleID] {
            if session.app.pid == app.pid && !isExpired(session, policy: policy, at: monotonicNow) {
                session.app = app
                session.lostFocusAt = nil
                session.isHidden = false
                unlockedSessions[app.bundleID] = session
                return effects
            }
            unlockedSessions.removeValue(forKey: app.bundleID)
        }

        let challenge = Challenge(app: app, phase: .scanning)
        activeChallenge = challenge
        effects.append(.raiseCurtain(challenge))
        return effects
    }

    private mutating func pruneUnlockedSessions(
        excluding activeBundleID: String?,
        at monotonicNow: TimeInterval,
        onRegularSwitch: Bool
    ) -> [Effect] {
        var effects: [Effect] = []

        for bundleID in unlockedSessions.keys.sorted() {
            if bundleID == activeBundleID { continue }
            guard let policy = policies[bundleID], var session = unlockedSessions[bundleID] else {
                unlockedSessions.removeValue(forKey: bundleID)
                continue
            }

            switch policy {
            case .everyTime:
                guard onRegularSwitch else { continue }
                unlockedSessions.removeValue(forKey: bundleID)
                if !session.isHidden {
                    effects.append(.hide(session.app))
                }
            case .afterMinutes:
                if isExpired(session, policy: policy, at: monotonicNow) {
                    unlockedSessions.removeValue(forKey: bundleID)
                    if !session.isHidden {
                        effects.append(.hide(session.app))
                    }
                }
            case .afterFocusLossMinutes:
                if onRegularSwitch && session.lostFocusAt == nil {
                    session.lostFocusAt = monotonicNow
                }
                if isExpired(session, policy: policy, at: monotonicNow) {
                    unlockedSessions.removeValue(forKey: bundleID)
                    if !session.isHidden {
                        effects.append(.hide(session.app))
                    }
                } else {
                    unlockedSessions[bundleID] = session
                }
            }
        }

        return effects
    }

    private func lockPolicy(for app: App) -> RelockPolicy? {
        guard !app.bundleID.isEmpty,
            !AppLockBlacklist.isProtected(app.bundleID, ownBundleID: ownBundleID)
        else { return nil }
        return policies[app.bundleID]
    }

    private func hasValidSessionOrGrant(for app: App, policy: RelockPolicy, at monotonicNow: TimeInterval) -> Bool {
        if let grant = reopenGrant, isReopenGrantValid(grant, for: app, at: monotonicNow) {
            return true
        }
        guard let session = unlockedSessions[app.bundleID], session.app.pid == app.pid else {
            return false
        }
        return !isExpired(session, policy: policy, at: monotonicNow)
    }

    private func isReopenGrantValid(_ grant: ReopenGrant, for app: App, at monotonicNow: TimeInterval) -> Bool {
        guard grant.bundleID == app.bundleID, grant.pid == app.pid else { return false }
        let elapsed = monotonicNow - grant.grantedAt
        return elapsed >= 0 && elapsed <= reopenGrantTTL
    }

    private func isExpired(_ session: UnlockedSession, policy: RelockPolicy, at monotonicNow: TimeInterval) -> Bool {
        switch policy {
        case .everyTime:
            return false
        case .afterMinutes(let minutes):
            guard minutes > 0, let duration = policy.durationSeconds else { return true }
            return (monotonicNow - session.unlockedAt) >= duration
        case .afterFocusLossMinutes(let minutes):
            guard let lostFocusAt = session.lostFocusAt else { return false }
            guard minutes > 0, let duration = policy.durationSeconds else { return true }
            return (monotonicNow - lostFocusAt) >= duration
        }
    }
}
