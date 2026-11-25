//
//  onboarding_flow_selftest.swift
//  glance (tools)
//
//  Offline self-test harness for idempotent onboarding enrollment commit,
//  password-failure retry, in-place rename, and orphan-classification safety:
//    1. `testFinishRetryAfterTransientPasswordFailureKeepsSingleIdentity`
//    2. `testEditNameBeforeRetryUpdatesCommittedIdentityInPlace`
//    3. `testPasswordOnlyFlowDoesNotMutateEnrollments`
//    4. `testUnrelatedExistingIdentityWithSameNameIsRejected`
//    5. `testEmptyCommitResultThrowsExplicitError`
//    6. `testOrphanClassificationBranchesDuringFinish`
//    7. `testResetEnrollmentStateClearsCommittedIdentityID`
//    8. `testEnrollmentOnlyRecaptureAndTeardownCancelsDismiss`
//
//  Compile and run from repo root:
//      swiftc -default-isolation MainActor -enable-upcoming-feature MemberImportVisibility -O \
//        -o /tmp/onboarding_flow_selftest \
//        glance/Core/GlobalHotKey.swift \
//        glance/Core/NotificationObserverBox.swift \
//        glance/AppLock/AppLockBlacklist.swift \
//        glance/AppLock/LockedApp.swift \
//        glance/AppLock/RelockPolicy.swift \
//        glance/Settings/SettingsModels.swift \
//        glance/Settings/GlanceSettings.swift \
//        glance/Camera/SharedCoreImageContext.swift \
//        glance/Camera/CameraFrame.swift \
//        glance/Camera/CameraCaptureSession.swift \
//        glance/Camera/CameraDeviceCatalog.swift \
//        glance/Camera/CameraManager.swift \
//        glance/Camera/CameraPreviewView.swift \
//        glance/Liveness/LandmarkGeometry.swift \
//        glance/Liveness/DeviceBezelDetector.swift \
//        glance/Liveness/GlareFaceRegion.swift \
//        glance/Liveness/GlareCue.swift \
//        glance/Liveness/GlareCueExtractor.swift \
//        glance/Liveness/LivenessFeatures.swift \
//        glance/Liveness/GeometryLiveness.swift \
//        glance/Liveness/LivenessScoring.swift \
//        glance/Liveness/LivenessCues.swift \
//        glance/Recognition/FaceEmbedder.swift \
//        glance/Recognition/FaceDetector.swift \
//        glance/Recognition/FaceAligner.swift \
//        glance/Recognition/ArcFaceEmbedder.swift \
//        glance/Recognition/FaceRecognitionPipeline.swift \
//        glance/Recognition/FaceEnrollmentStore.swift \
//        glance/Security/KeychainManager.swift \
//        glance/Security/SecureFaceStore.swift \
//        glance/Security/SecureCredentialManager.swift \
//        glance/Unlock/LockMonitor.swift \
//        glance/Unlock/KeystrokeInjector.swift \
//        glance/NotchOverlay/NotchPanelStyle.swift \
//        glance/NotchOverlay/DisplayContext.swift \
//        glance/NotchOverlay/NotchGeometry.swift \
//        glance/NotchOverlay/NotchGeometry+Screen.swift \
//        glance/NotchOverlay/NotchShape.swift \
//        glance/NotchOverlay/NotchSkyLight.swift \
//        glance/NotchOverlay/NotchWindow.swift \
//        glance/NotchOverlay/NotchWindowController.swift \
//        glance/NotchOverlay/AnimationTint.swift \
//        glance/NotchOverlay/ScanAnimationView.swift \
//        glance/NotchOverlay/MinimalUnlockView.swift \
//        glance/NotchOverlay/NotchOverlayView.swift \
//        glance/NotchOverlay/NotchOverlayController.swift \
//        glance/Onboarding/OnboardingStep.swift \
//        glance/Onboarding/GlanceTheme.swift \
//        glance/Onboarding/OnboardingMetrics.swift \
//        glance/Onboarding/EnrollmentPoseEvaluator.swift \
//        glance/Onboarding/EnrollmentRingAnimationState.swift \
//        glance/Onboarding/EnrollmentRingView.swift \
//        glance/Onboarding/EnrollmentDirectionSweep.swift \
//        glance/Onboarding/EnrollmentSweepWindowController.swift \
//        glance/Onboarding/LoopingVideoView.swift \
//        glance/Onboarding/AnimatedCheckmark.swift \
//        glance/Onboarding/OnboardingControls.swift \
//        glance/Onboarding/OnboardingStepViews.swift \
//        glance/Onboarding/OnboardingEnrollmentStepViews.swift \
//        glance/Onboarding/OnboardingNotchView.swift \
//        glance/Onboarding/OnboardingController.swift \
//        glance/Onboarding/OnboardingController+Flow.swift \
//        glance/Onboarding/OnboardingController+Enrollment.swift \
//        tools/onboarding_flow_selftest.swift \
//      && /tmp/onboarding_flow_selftest
//

import CoreGraphics
import Foundation
import Security

private var passed = 0
private var failed = 0

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "Assertion failed",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if condition() {
        passed += 1
    } else {
        failed += 1
        fputs("FAIL (\(file):\(line)): \(message)\n", stderr)
    }
}

private nonisolated struct MockEmbedder: FaceEmbedder {
    let name = "Mock ArcFace"
    let modelIdentifier = "mock-arcface-v1"
    let embeddingDimension = 2
    let requiresAlignment = true
    let isUnlockCapable = true

    func embedding(for face: CGImage) throws -> [Float] { [1, 0] }
}

private nonisolated final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    var events: [String] {
        lock.withLock { _events }
    }

    func record(_ event: String) {
        lock.withLock { _events.append(event) }
    }
}

private nonisolated final class InMemoryStorageSpy: @unchecked Sendable {
    private let lock = NSLock()
    private let recorder: EventRecorder
    private var _isUnlocked: Bool
    private var _identities: [FaceIdentity]
    private var _loadError: Error?
    private var _saveError: Error?
    private var _deleteAllError: Error?
    private var _clearLoadErrorOnDeleteAll: Bool
    private var _saveCount = 0
    private var _deleteAllCount = 0

    init(
        recorder: EventRecorder = EventRecorder(),
        initialIdentities: [FaceIdentity] = [],
        isUnlocked: Bool = false,
        loadError: Error? = nil,
        clearLoadErrorOnDeleteAll: Bool = true
    ) {
        self.recorder = recorder
        self._identities = initialIdentities
        self._isUnlocked = isUnlocked
        self._loadError = loadError
        self._clearLoadErrorOnDeleteAll = clearLoadErrorOnDeleteAll
    }

    var isUnlocked: Bool {
        get { lock.withLock { _isUnlocked } }
        set { lock.withLock { _isUnlocked = newValue } }
    }

    var storedIdentities: [FaceIdentity] {
        get { lock.withLock { _identities } }
        set { lock.withLock { _identities = newValue } }
    }

    var saveCount: Int {
        lock.withLock { _saveCount }
    }

    var deleteAllCount: Int {
        lock.withLock { _deleteAllCount }
    }

    var saveError: Error? {
        get { lock.withLock { _saveError } }
        set { lock.withLock { _saveError = newValue } }
    }

    var deleteAllError: Error? {
        get { lock.withLock { _deleteAllError } }
        set { lock.withLock { _deleteAllError = newValue } }
    }

    var storage: FaceEnrollmentStore.Storage {
        FaceEnrollmentStore.Storage(
            isSessionUnlocked: { self.isUnlocked },
            load: {
                try self.lock.withLock {
                    self.recorder.record("store.load")
                    if let error = self._loadError {
                        throw error
                    }
                    return self._identities
                }
            },
            save: { identities in
                try self.lock.withLock {
                    self.recorder.record("store.save")
                    self._saveCount += 1
                    if let error = self._saveError {
                        throw error
                    }
                    self._identities = identities
                }
            },
            deleteAll: {
                try self.lock.withLock {
                    self.recorder.record("store.deleteAll")
                    self._deleteAllCount += 1
                    if let error = self._deleteAllError {
                        throw error
                    }
                    self._identities.removeAll()
                    if self._clearLoadErrorOnDeleteAll {
                        self._loadError = nil
                    }
                }
            }
        )
    }
}

private nonisolated final class CredentialSpy: @unchecked Sendable {
    private let lock = NSLock()
    private let recorder: EventRecorder
    private let storageSpy: InMemoryStorageSpy
    private let classificationProvider: @Sendable () -> OrphanedDataClassification
    private var _savePasswordOutcomes: [Error?]
    private var _deletePasswordCount = 0
    private var _unlockSessionCount = 0
    private var _savePasswordCount = 0
    private var _savedPasswords: [String] = []

    init(
        recorder: EventRecorder,
        storageSpy: InMemoryStorageSpy,
        classificationProvider: @escaping @Sendable () -> OrphanedDataClassification,
        savePasswordOutcomes: [Error?] = [nil]
    ) {
        self.recorder = recorder
        self.storageSpy = storageSpy
        self.classificationProvider = classificationProvider
        self._savePasswordOutcomes = savePasswordOutcomes
    }

    var deletePasswordCount: Int {
        lock.withLock { _deletePasswordCount }
    }

    var unlockSessionCount: Int {
        lock.withLock { _unlockSessionCount }
    }

    var savePasswordCount: Int {
        lock.withLock { _savePasswordCount }
    }

    var savedPasswords: [String] {
        lock.withLock { _savedPasswords }
    }

    var service: OnboardingCredentialService {
        OnboardingCredentialService(
            orphanedDataClassification: {
                self.recorder.record("orphanedDataClassification")
                return self.classificationProvider()
            },
            deletePassword: {
                self.lock.withLock {
                    self.recorder.record("deletePassword")
                    self._deletePasswordCount += 1
                }
                self.storageSpy.isUnlocked = false
            },
            unlockSession: { _ in
                self.lock.withLock {
                    self.recorder.record("unlockSession")
                    self._unlockSessionCount += 1
                }
                self.storageSpy.isUnlocked = true
            },
            savePassword: { plaintext in
                let outcome: Error? = self.lock.withLock {
                    self.recorder.record("savePassword")
                    self._savePasswordCount += 1
                    if self._savePasswordOutcomes.isEmpty {
                        return nil
                    }
                    return self._savePasswordOutcomes.removeFirst()
                }
                if let outcome {
                    throw outcome
                }
                self.lock.withLock {
                    self._savedPasswords.append(plaintext)
                }
            }
        )
    }
}

@main
struct OnboardingFlowSelfTest {
    static func main() async {
        await testFinishRetryAfterTransientPasswordFailureKeepsSingleIdentity()
        await testEditNameBeforeRetryUpdatesCommittedIdentityInPlace()
        await testPasswordOnlyFlowDoesNotMutateEnrollments()
        await testUnrelatedExistingIdentityWithSameNameIsRejected()
        await testEmptyCommitResultThrowsExplicitError()
        await testOrphanClassificationBranchesDuringFinish()
        await testResetEnrollmentStateClearsCommittedIdentityID()
        await testEnrollmentOnlyRecaptureAndTeardownCancelsDismiss()
        print("Passed \(passed) assertions, \(failed) failed.")
        if failed > 0 {
            exit(1)
        }
    }

    private static func makePipeline() -> FaceRecognitionPipeline {
        FaceRecognitionPipeline(embedder: MockEmbedder(), usingFallbackEmbedder: false, fallbackReason: nil)
    }

    private static func makeSamples(embedding: [Float] = [1, 0]) -> [OnboardingController.CollectedSample] {
        [
            OnboardingController.CollectedSample(
                embedding: embedding,
                pose: .center,
                quality: 0.9,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ]
    }

    private static func makeIdentity(name: String, embedding: [Float] = [0, 1]) -> FaceIdentity {
        let sample = FaceSample(
            embedding: embedding,
            pose: "center",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            quality: 0.9
        )
        return FaceIdentity(
            id: UUID(),
            name: name,
            samples: [sample],
            modelIdentifier: MockEmbedder().modelIdentifier,
            embeddingDimension: 2,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isEnabled: true
        )
    }

    private static func makeController(
        pipeline: FaceRecognitionPipeline?,
        store: FaceEnrollmentStore,
        credentialService: OnboardingCredentialService,
        isEnrollmentOnly: Bool = false,
        isPasswordOnly: Bool = false,
        isPostUpdateNotice: Bool = false,
        enrollmentTarget: OnboardingController.EnrollmentTarget = .newIdentity,
        onDismiss: @escaping @MainActor () -> Void = {}
    ) -> OnboardingController {
        OnboardingController(
            pipeline: pipeline,
            store: store,
            credentialService: credentialService,
            onDismissOnboarding: onDismiss,
            completionDismissDelay: .zero,
            isEnrollmentOnly: isEnrollmentOnly,
            isPasswordOnly: isPasswordOnly,
            isPostUpdateNotice: isPostUpdateNotice,
            enrollmentTarget: enrollmentTarget
        )
    }

    // 1. Transient savePassword failure followed by retry keeps a single identity with the same UUID
    private static func testFinishRetryAfterTransientPasswordFailureKeepsSingleIdentity() async {
        let recorder = EventRecorder()
        let storageSpy = InMemoryStorageSpy(recorder: recorder)
        let store = FaceEnrollmentStore(storage: storageSpy.storage, observeSessionNotifications: false)
        let credSpy = CredentialSpy(
            recorder: recorder,
            storageSpy: storageSpy,
            classificationProvider: {
                storageSpy.isUnlocked || !storageSpy.storedIdentities.isEmpty ? .keyPresent : .noEncryptedData
            },
            savePasswordOutcomes: [KeychainError.osStatus(errSecIO), nil]
        )
        var dismissCount = 0
        let controller = makeController(
            pipeline: makePipeline(),
            store: store,
            credentialService: credSpy.service,
            onDismiss: { dismissCount += 1 }
        )
        defer { controller.teardown() }

        controller.collectedSamples = makeSamples()
        controller.pendingName = "Alice"
        controller.step = .password

        let firstResult = await controller.finish(password: "secret")
        expect(firstResult == false, "First finish() should fail when savePassword throws")
        expect(controller.step == .password, "Step should stay .password after password save failure")
        expect(controller.passwordError != nil, "passwordError should be populated on failure")
        expect(store.identities.count == 1, "Store should contain 1 committed identity after step 1")
        let firstID = store.identities[0].id
        expect(controller.committedIdentityID == firstID, "committedIdentityID must track firstID")
        expect(dismissCount == 0, "Dismiss should not fire on failed finish()")

        let secondResult = await controller.finish(password: "secret")
        expect(secondResult == true, "Retry finish() should succeed")
        expect(controller.step == .complete, "Step should advance to .complete on retry success")
        expect(controller.passwordError == nil, "passwordError should clear on retry success")
        expect(store.identities.count == 1, "Retry must keep a single identity instead of duplicating")
        expect(store.identities[0].id == firstID, "Retry must preserve firstID")
        expect(store.identities[0].name == "Alice", "Identity name should remain Alice")
        expect(credSpy.savedPasswords == ["secret"], "Password should be saved on retry")

        try? await Task.sleep(for: .milliseconds(20))
        expect(dismissCount == 1, "Injected onDismissOnboarding should be called once after completion")
    }

    // 2. Going back to .name, renaming, and retrying updates committed identity in place
    private static func testEditNameBeforeRetryUpdatesCommittedIdentityInPlace() async {
        let recorder = EventRecorder()
        let storageSpy = InMemoryStorageSpy(recorder: recorder)
        let store = FaceEnrollmentStore(storage: storageSpy.storage, observeSessionNotifications: false)
        let credSpy = CredentialSpy(
            recorder: recorder,
            storageSpy: storageSpy,
            classificationProvider: {
                storageSpy.isUnlocked || !storageSpy.storedIdentities.isEmpty ? .keyPresent : .noEncryptedData
            },
            savePasswordOutcomes: [KeychainError.osStatus(errSecIO), nil]
        )
        let controller = makeController(
            pipeline: makePipeline(),
            store: store,
            credentialService: credSpy.service
        )
        defer { controller.teardown() }

        let samples = makeSamples(embedding: [0.6, 0.8])
        controller.collectedSamples = samples
        controller.pendingName = "Alice"
        controller.step = .password

        let firstResult = await controller.finish(password: "secret")
        expect(firstResult == false, "First finish() should fail on savePassword")
        expect(store.identities.count == 1)
        let firstID = store.identities[0].id
        expect(controller.committedIdentityID == firstID)

        controller.back()
        expect(controller.step == .name, "back() from .password should return to .name")
        expect(controller.collectedSamples.count == samples.count, "back() must preserve collectedSamples")
        expect(controller.nameError == nil)

        // Confirming with the same committed name must also be allowed (excluding activeEnrollmentIdentityID)
        controller.confirmName()
        expect(controller.step == .password, "Keeping committed name should advance back to .password")
        expect(controller.nameError == nil)

        controller.back()
        expect(controller.step == .name)
        controller.pendingName = "  Alice Chen  "
        controller.confirmName()
        expect(controller.step == .password, "Renaming after failure should advance to .password")
        expect(controller.nameError == nil, "nameError should remain nil when renaming committed identity")

        let retryResult = await controller.finish(password: "secret")
        expect(retryResult == true, "Retry after rename should succeed")
        expect(controller.step == .complete)
        expect(store.identities.count == 1, "Rename retry must update in place without creating a second identity")
        expect(store.identities[0].id == firstID, "Identity UUID must stay firstID")
        expect(store.identities[0].name == "Alice Chen", "Identity name must update to Alice Chen")
    }

    // 3. Password-only flow must not mutate existing enrollments or set committedIdentityID
    private static func testPasswordOnlyFlowDoesNotMutateEnrollments() async {
        let existing = makeIdentity(name: "Existing")
        let recorder = EventRecorder()
        let storageSpy = InMemoryStorageSpy(recorder: recorder, initialIdentities: [existing], isUnlocked: true)
        let store = FaceEnrollmentStore(storage: storageSpy.storage, observeSessionNotifications: false)
        let credSpy = CredentialSpy(
            recorder: recorder,
            storageSpy: storageSpy,
            classificationProvider: { .keyPresent }
        )
        let controller = makeController(
            pipeline: nil,
            store: store,
            credentialService: credSpy.service,
            isPasswordOnly: true
        )
        defer { controller.teardown() }

        expect(controller.step == .password, "Password-only flow should start on .password")
        expect(controller.collectedSamples.isEmpty)

        let result = await controller.finish(password: "new-secret")
        expect(result == true, "Password-only finish() should succeed")
        expect(controller.step == .complete, "Password-only finish() should advance to .complete")
        expect(store.identities == [existing], "Existing identity must remain completely untouched")
        expect(storageSpy.saveCount == 0, "Password-only flow must perform 0 enrollment saves")
        expect(controller.committedIdentityID == nil, "Password-only flow must leave committedIdentityID == nil")
    }

    // 4. An unrelated existing identity with the same name must be rejected rather than overwritten
    private static func testUnrelatedExistingIdentityWithSameNameIsRejected() async {
        let existing = makeIdentity(name: "Alice")
        let recorder = EventRecorder()
        let storageSpy = InMemoryStorageSpy(recorder: recorder, initialIdentities: [existing], isUnlocked: false)
        let store = FaceEnrollmentStore(storage: storageSpy.storage, observeSessionNotifications: false)
        let credSpy = CredentialSpy(
            recorder: recorder,
            storageSpy: storageSpy,
            classificationProvider: { .keyPresent }
        )
        let controller = makeController(
            pipeline: makePipeline(),
            store: store,
            credentialService: credSpy.service,
            enrollmentTarget: .newIdentity
        )
        defer { controller.teardown() }

        controller.collectedSamples = makeSamples()
        controller.pendingName = "Alice"
        controller.step = .password

        let result = await controller.finish(password: "secret")
        expect(result == false, "Duplicate name against unrelated identity must return false")
        expect(controller.step == .name, "Duplicate name must route back to .name")
        expect(controller.nameError != nil, "Duplicate name must populate nameError")
        expect(store.identities == [existing], "Existing identity must not be overwritten")
        expect(controller.committedIdentityID == nil, "Rejected commit must not set committedIdentityID")
        expect(credSpy.savePasswordCount == 0, "Password must not be saved when enrollment commit is rejected")
    }

    // 5. Non-empty samples with blank/whitespace name triggers explicit emptyEnrollmentResult error
    private static func testEmptyCommitResultThrowsExplicitError() async {
        let recorder = EventRecorder()
        let storageSpy = InMemoryStorageSpy(recorder: recorder)
        let store = FaceEnrollmentStore(storage: storageSpy.storage, observeSessionNotifications: false)
        let credSpy = CredentialSpy(
            recorder: recorder,
            storageSpy: storageSpy,
            classificationProvider: { .noEncryptedData }
        )
        let controller = makeController(
            pipeline: makePipeline(),
            store: store,
            credentialService: credSpy.service
        )
        defer { controller.teardown() }

        controller.collectedSamples = makeSamples()
        controller.pendingName = "   "
        controller.step = .password

        let result = await controller.finish(password: "secret")
        expect(result == false, "Whitespace-only name must fail finish()")
        expect(
            controller.passwordError == OnboardingEnrollmentError.emptyEnrollmentResult.localizedDescription,
            "passwordError should surface OnboardingEnrollmentError.emptyEnrollmentResult"
        )
        expect(controller.step == .password, "Step must not move to .complete when commit result is empty")
        expect(store.identities.isEmpty, "No identity should be saved for blank name")
        expect(credSpy.savePasswordCount == 0, "savePassword must not run after empty commit error")
    }

    // 6. Orphan classification branches during finish(): .indeterminate, .keyPresent, .confirmedOrphaned
    private static func testOrphanClassificationBranchesDuringFinish() async {
        // 6a. .indeterminate(errSecIO): 0 deletes, data intact, returns false
        do {
            let preserved = makeIdentity(name: "Preserved")
            let recorder = EventRecorder()
            let storageSpy = InMemoryStorageSpy(recorder: recorder, initialIdentities: [preserved], isUnlocked: false)
            let store = FaceEnrollmentStore(storage: storageSpy.storage, observeSessionNotifications: false)
            let credSpy = CredentialSpy(
                recorder: recorder,
                storageSpy: storageSpy,
                classificationProvider: { .indeterminate(errSecIO) }
            )
            let controller = makeController(
                pipeline: makePipeline(),
                store: store,
                credentialService: credSpy.service
            )
            defer { controller.teardown() }

            controller.collectedSamples = makeSamples()
            controller.pendingName = "Alice"
            controller.step = .password

            let result = await controller.finish(password: "secret")
            expect(result == false, ".indeterminate must fail finish()")
            expect(controller.passwordError != nil, ".indeterminate must set passwordError")
            expect(controller.step == .password, ".indeterminate must stay on .password")
            expect(credSpy.deletePasswordCount == 0, ".indeterminate must perform 0 deletePassword calls")
            expect(storageSpy.deleteAllCount == 0, ".indeterminate must perform 0 storage.deleteAll calls")
            expect(credSpy.unlockSessionCount == 0, ".indeterminate must not call unlockSession")
            expect(credSpy.savePasswordCount == 0, ".indeterminate must not call savePassword")
            expect(storageSpy.storedIdentities == [preserved], ".indeterminate must leave existing data intact")
        }

        // 6b. .keyPresent: 0 deletes, preserves existing data, proceeds to unlockSession
        do {
            let existing = makeIdentity(name: "Existing")
            let recorder = EventRecorder()
            let storageSpy = InMemoryStorageSpy(recorder: recorder, initialIdentities: [existing], isUnlocked: false)
            let store = FaceEnrollmentStore(storage: storageSpy.storage, observeSessionNotifications: false)
            let credSpy = CredentialSpy(
                recorder: recorder,
                storageSpy: storageSpy,
                classificationProvider: { .keyPresent }
            )
            let controller = makeController(
                pipeline: makePipeline(),
                store: store,
                credentialService: credSpy.service
            )
            defer { controller.teardown() }

            controller.collectedSamples = makeSamples()
            controller.pendingName = "Bob"
            controller.step = .password

            let result = await controller.finish(password: "secret")
            expect(result == true, ".keyPresent should succeed")
            expect(controller.step == .complete)
            expect(credSpy.deletePasswordCount == 0, ".keyPresent must perform 0 deletePassword calls")
            expect(storageSpy.deleteAllCount == 0, ".keyPresent must perform 0 storage.deleteAll calls")
            expect(credSpy.unlockSessionCount == 1, ".keyPresent must proceed to unlockSession")
            expect(store.identities.contains(existing), ".keyPresent must preserve existing identities")
            expect(store.identities.count == 2, ".keyPresent should keep existing and add Bob")
        }

        // 6c. .confirmedOrphaned: 1 deletePassword + 1 storage.deleteAll BEFORE unlockSession, then clean recovery
        do {
            let orphaned = makeIdentity(name: "Orphaned")
            let recorder = EventRecorder()
            let storageSpy = InMemoryStorageSpy(
                recorder: recorder,
                initialIdentities: [orphaned],
                isUnlocked: false,
                loadError: SecureCredentialError.decryptionFailed
            )
            let store = FaceEnrollmentStore(storage: storageSpy.storage, observeSessionNotifications: false)
            let credSpy = CredentialSpy(
                recorder: recorder,
                storageSpy: storageSpy,
                classificationProvider: { .confirmedOrphaned }
            )
            let controller = makeController(
                pipeline: makePipeline(),
                store: store,
                credentialService: credSpy.service
            )
            defer { controller.teardown() }

            controller.collectedSamples = makeSamples()
            controller.pendingName = "Recovered"
            controller.step = .password

            let result = await controller.finish(password: "secret")
            expect(result == true, ".confirmedOrphaned recovery should succeed")
            expect(controller.step == .complete)
            expect(credSpy.deletePasswordCount == 1, ".confirmedOrphaned must call deletePassword once")
            expect(storageSpy.deleteAllCount == 1, ".confirmedOrphaned must call storage.deleteAll once")
            expect(credSpy.unlockSessionCount == 1, ".confirmedOrphaned must call unlockSession once")
            expect(credSpy.savePasswordCount == 1, ".confirmedOrphaned must savePassword once")

            let events = recorder.events
            let deletePwdIndex = events.firstIndex(of: "deletePassword")
            let deleteAllIndex = events.firstIndex(of: "store.deleteAll")
            let unlockIndex = events.firstIndex(of: "unlockSession")
            expect(
                deletePwdIndex != nil && deleteAllIndex != nil && unlockIndex != nil
                    && deletePwdIndex! < unlockIndex! && deleteAllIndex! < unlockIndex!,
                "Both deletePassword and store.deleteAll must run before unlockSession (events: \(events))"
            )
            expect(store.identities.count == 1 && store.identities[0].name == "Recovered")
        }
    }

    // 7. resetEnrollmentState() clears committedIdentityID when starting a fresh enrollment
    private static func testResetEnrollmentStateClearsCommittedIdentityID() async {
        let recorder = EventRecorder()
        let storageSpy = InMemoryStorageSpy(recorder: recorder)
        let store = FaceEnrollmentStore(storage: storageSpy.storage, observeSessionNotifications: false)
        let credSpy = CredentialSpy(
            recorder: recorder,
            storageSpy: storageSpy,
            classificationProvider: { .noEncryptedData }
        )
        let controller = makeController(
            pipeline: makePipeline(),
            store: store,
            credentialService: credSpy.service
        )
        defer { controller.teardown() }

        controller.collectedSamples = makeSamples()
        controller.pendingName = "Alice"
        controller.step = .password

        let finished = await controller.finish(password: "secret")
        expect(finished == true)
        expect(controller.committedIdentityID != nil, "committedIdentityID must be set after commit")

        controller.resetEnrollmentState()
        expect(controller.committedIdentityID == nil, "resetEnrollmentState() must clear committedIdentityID")
        expect(controller.activeEnrollmentIdentityID == nil, "activeEnrollmentIdentityID should reset to target")
        expect(controller.collectedSamples.isEmpty)
    }

    // 8. Enrollment-only recapture updates target ID in place, and teardown() cancels scheduled dismiss
    private static func testEnrollmentOnlyRecaptureAndTeardownCancelsDismiss() async {
        // 8a. teardown() before completionDismissDelay fires must cancel dismissal
        do {
            let recorder = EventRecorder()
            let storageSpy = InMemoryStorageSpy(recorder: recorder)
            let store = FaceEnrollmentStore(storage: storageSpy.storage, observeSessionNotifications: false)
            let credSpy = CredentialSpy(
                recorder: recorder,
                storageSpy: storageSpy,
                classificationProvider: { .noEncryptedData }
            )
            var dismissCount = 0
            let controller = OnboardingController(
                pipeline: makePipeline(),
                store: store,
                credentialService: credSpy.service,
                onDismissOnboarding: { dismissCount += 1 },
                completionDismissDelay: .milliseconds(50)
            )
            controller.collectedSamples = makeSamples()
            controller.pendingName = "Alice"
            controller.step = .password

            let finished = await controller.finish(password: "secret")
            expect(finished == true)
            controller.teardown()
            try? await Task.sleep(for: .milliseconds(80))
            expect(dismissCount == 0, "teardown() must cancel pending scheduleCompletionDismiss() task")
        }

        // 8b. isEnrollmentOnly recapture updates existing target in place and avoids onFirstRunComplete
        do {
            let existing = makeIdentity(name: "Old Name")
            let recorder = EventRecorder()
            let storageSpy = InMemoryStorageSpy(recorder: recorder, initialIdentities: [existing], isUnlocked: true)
            let store = FaceEnrollmentStore(storage: storageSpy.storage, observeSessionNotifications: false)
            let credSpy = CredentialSpy(
                recorder: recorder,
                storageSpy: storageSpy,
                classificationProvider: { .keyPresent }
            )
            var dismissCount = 0
            var firstRunCompleteCount = 0
            let controller = makeController(
                pipeline: makePipeline(),
                store: store,
                credentialService: credSpy.service,
                isEnrollmentOnly: true,
                enrollmentTarget: .replacing(existing.id),
                onDismiss: { dismissCount += 1 }
            )
            defer { controller.teardown() }
            controller.onFirstRunComplete = { firstRunCompleteCount += 1 }
            // Move out of .enroll synchronously before the deferred beginEnrollment() task executes
            controller.step = .name
            controller.collectedSamples = makeSamples(embedding: [0.3, 0.7])
            controller.pendingName = "  New Name  "

            controller.confirmName()
            expect(controller.step == .complete, "Enrollment-only confirmName() should advance to .complete")
            expect(controller.nameError == nil)
            expect(controller.committedIdentityID == existing.id, "Recapture should record existing target ID")
            expect(store.identities.count == 1)
            expect(store.identities[0].id == existing.id)
            expect(store.identities[0].name == "New Name")

            try? await Task.sleep(for: .milliseconds(20))
            expect(dismissCount == 1, "Enrollment-only completion should fire injected onDismissOnboarding")
            expect(firstRunCompleteCount == 0, "Enrollment-only completion must not fire onFirstRunComplete")
        }
    }
}
