//
//  FaceEnrollmentStore.swift
//  glance
//
//  Persisted encrypted under the same Touch-ID-gated session key as the stored Mac password (see SecureFaceStore);
//  `isLocked`/`reloadIfUnlocked()` let the UI distinguish "locked" from "nothing enrolled."
//

import Foundation
import Observation

nonisolated struct FaceSample: Codable, Equatable {
    let embedding: [Float]
    /// Which guided-enrollment pose this came from, or nil for untagged captures (e.g. Face Lab's manual capture).
    let pose: String?
    let capturedAt: Date
    /// Vision's capture-quality score (0...1), or nil if unavailable.
    let quality: Float?
}

extension FaceSample {
    /// Lives here rather than in a view so Face Lab's debug list and the settings tick strip can't drift apart.
    nonisolated enum QualityTier {
        /// No score recorded. Never counted as poor.
        case unrated
        case poor
        case fair
        case good
    }

    private nonisolated static let turnedPoorRatio: Float = 0.5
    private nonisolated static let turnedFairRatio: Float = 0.7

    /// Untagged manual captures (`pose == nil`) and `"center"` guided captures represent frontal views;
    /// angled enrollment poses naturally score lower in Vision's capture-quality model and are graded relative to frontal.
    nonisolated var isFrontal: Bool {
        pose == nil || pose == "center"
    }

    nonisolated func qualityTier(frontalReference: Float?) -> QualityTier {
        guard let quality else { return .unrated }
        if !isFrontal, let frontalReference, frontalReference > 0 {
            let ratio = quality / frontalReference
            if ratio < Self.turnedPoorRatio { return .poor }
            if ratio < Self.turnedFairRatio { return .fair }
            return .good
        }
        if quality < 0.4 { return .poor }
        if quality < 0.5 { return .fair }
        return .good
    }

    nonisolated var qualityTier: QualityTier {
        qualityTier(frontalReference: nil)
    }
}

struct FaceIdentity: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var samples: [FaceSample] {
        didSet {
            cachedTemplate = FaceEmbedding.average(samples.map(\.embedding))
        }
    }
    /// Which `FaceEmbedder.modelIdentifier` produced these samples — different models' embeddings live in unrelated
    /// vector spaces. See `isStale(comparedTo:)`.
    var modelIdentifier: String
    var embeddingDimension: Int
    var createdAt: Date
    /// Turning off keeps the enrollment intact but excludes it from `activeIdentities`, which unlock scores against.
    var isEnabled: Bool

    /// Derived cache of `FaceEmbedding.average(samples.map(\.embedding))`, kept out of JSON via `CodingKeys`.
    private var cachedTemplate: [Float]?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case samples
        case modelIdentifier
        case embeddingDimension
        case createdAt
        case isEnabled
    }

    init(
        id: UUID,
        name: String,
        samples: [FaceSample],
        modelIdentifier: String,
        embeddingDimension: Int,
        createdAt: Date,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.samples = samples
        self.modelIdentifier = modelIdentifier
        self.embeddingDimension = embeddingDimension
        self.createdAt = createdAt
        self.isEnabled = isEnabled
        self.cachedTemplate = FaceEmbedding.average(samples.map(\.embedding))
    }

    /// Hand-written so `isEnabled` defaults to `true` when absent — a synthesized decoder would throw on a missing
    /// key and, since the whole store decodes as one array, lose every identity in it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        samples = try container.decode([FaceSample].self, forKey: .samples)
        modelIdentifier = try container.decode(String.self, forKey: .modelIdentifier)
        embeddingDimension = try container.decode(Int.self, forKey: .embeddingDimension)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        cachedTemplate = FaceEmbedding.average(samples.map(\.embedding))
    }

    nonisolated static func == (lhs: FaceIdentity, rhs: FaceIdentity) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.samples == rhs.samples
            && lhs.modelIdentifier == rhs.modelIdentifier
            && lhs.embeddingDimension == rhs.embeddingDimension
            && lhs.createdAt == rhs.createdAt
            && lhs.isEnabled == rhs.isEnabled
    }

    /// The single vector actually compared against at recognition time.
    nonisolated var template: [Float]? {
        cachedTemplate
    }

    /// True if samples came from a different embedder than the one currently active — should prompt re-enrollment.
    nonisolated func isStale(comparedTo embedder: FaceEmbedder) -> Bool {
        modelIdentifier != embedder.modelIdentifier
    }

    /// Median capture quality across this identity's rated frontal samples, used as the baseline when grading
    /// angled enrollment poses so perspective penalties don't read as poor capture quality.
    nonisolated var frontalQualityReference: Float? {
        let frontalQualities = samples.filter(\.isFrontal).compactMap(\.quality).sorted()
        guard !frontalQualities.isEmpty else { return nil }
        let mid = frontalQualities.count / 2
        if frontalQualities.count.isMultiple(of: 2) {
            return (frontalQualities[mid - 1] + frontalQualities[mid]) / 2
        }
        return frontalQualities[mid]
    }

    nonisolated func qualityTier(of sample: FaceSample) -> FaceSample.QualityTier {
        sample.qualityTier(frontalReference: frontalQualityReference)
    }

    nonisolated var poorQualitySampleCount: Int {
        let reference = frontalQualityReference
        return samples.filter { $0.qualityTier(frontalReference: reference) == .poor }.count
    }
}

nonisolated enum FaceEnrollmentStoreError: LocalizedError, Equatable {
    case sessionLocked
    case storeUnreadable

    var errorDescription: String? {
        switch self {
        case .sessionLocked:
            return "Session is locked. Authenticate with Touch ID to modify enrolled faces."
        case .storeUnreadable:
            return "Your enrolled faces couldn't be read, so nothing was saved — writing now would overwrite them."
        }
    }
}

@Observable
@MainActor
final class FaceEnrollmentStore {
    nonisolated enum LoadState: Equatable, Sendable {
        case locked
        case ready
        case failed(String)
    }

    nonisolated struct Storage: Sendable {
        let isSessionUnlocked: @Sendable () -> Bool
        let load: @Sendable () throws -> [FaceIdentity]
        let save: @Sendable ([FaceIdentity]) throws -> Void
        let deleteAll: @Sendable () throws -> Void

        static let live = Storage(
            isSessionUnlocked: { SecureCredentialManager.isSessionUnlocked },
            load: { try SecureFaceStore.load() },
            save: { try SecureFaceStore.save($0) },
            deleteAll: { try SecureFaceStore.deleteAll() }
        )
    }

    /// Shared so the Face Lab tab and onboarding window observe and persist the same identities, not diverging copies.
    static let shared = FaceEnrollmentStore()

    private(set) var identities: [FaceIdentity] = []
    private(set) var loadState: LoadState = .locked

    /// True until a successful load — distinguishes "nothing enrolled yet" from "locked, needs Touch ID."
    var isLocked: Bool {
        loadState == .locked
    }

    /// Non-nil when unlocked but the encrypted store still couldn't be read (decrypt/decode failure, not a missing key) —
    /// unlike `isLocked`, unlocking again won't fix this.
    var loadFailure: String? {
        if case .failed(let message) = loadState {
            return message
        }
        return nil
    }

    private let storage: Storage
    @ObservationIgnored nonisolated(unsafe) private var sessionObserver: (any NSObjectProtocol)?

    /// Everyone the user hasn't switched off — what unlock actually scores against. `identities` stays the full list.
    var activeIdentities: [FaceIdentity] {
        identities.filter(\.isEnabled)
    }

    init(storage: Storage = .live, observeSessionNotifications: Bool = true) {
        self.storage = storage
        reloadIfUnlocked()
        if observeSessionNotifications {
            // Reload whenever the session key changes, regardless of call site, so this store can't go stale
            // relative to whichever UI changed the session.
            sessionObserver = NotificationCenter.default.addObserver(
                forName: .secureCredentialSessionDidChange,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reloadIfUnlocked()
                }
            }
        }
    }

    deinit {
        if let sessionObserver {
            NotificationCenter.default.removeObserver(sessionObserver)
        }
    }

    /// Re-attempts loading from encrypted storage. Transitions to `.locked` when the session isn't unlocked yet.
    func reloadIfUnlocked() {
        guard storage.isSessionUnlocked() else {
            loadState = .locked
            return
        }
        do {
            identities = try storage.load()
            loadState = .ready
        } catch {
            // Deliberately not `(try? load()) ?? []` — a store we couldn't read isn't an empty store, and the next
            // write must not persist an empty array over a file that still holds every sample.
            identities = []
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Adds one captured sample to `name`'s identity (creating it if new). Existing samples from a different embedder
    /// are discarded first, since mixing them would corrupt the template.
    @discardableResult
    func addSample(name: String, embedding: [Float], embedder: FaceEmbedder, pose: String? = nil, quality: Float? = nil)
        throws -> Bool
    {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var candidate = identities
        let sample = FaceSample(embedding: embedding, pose: pose, capturedAt: Date(), quality: quality)

        if let index = candidate.firstIndex(where: { $0.name == trimmed }) {
            if candidate[index].modelIdentifier != embedder.modelIdentifier {
                candidate[index].samples = [sample]
            } else {
                candidate[index].samples.append(sample)
            }
            candidate[index].modelIdentifier = embedder.modelIdentifier
            candidate[index].embeddingDimension = embedder.embeddingDimension
        } else {
            candidate.append(
                FaceIdentity(
                    id: UUID(),
                    name: trimmed,
                    samples: [sample],
                    modelIdentifier: embedder.modelIdentifier,
                    embeddingDimension: embedder.embeddingDimension,
                    createdAt: Date()
                ))
        }
        try saveTransaction(candidate)
        return true
    }

    /// Commits a whole guided enrollment in a single write. When `existingID` names a known identity, its samples are
    /// replaced wholesale (a recapture is a redo, not an append) and it can be renamed since matching is by id.
    @discardableResult
    func commitEnrollment(
        replacing existingID: UUID?,
        name: String,
        samples: [FaceSample],
        embedder: FaceEmbedder
    ) throws -> FaceIdentity? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !samples.isEmpty else { return nil }

        // Local copy, only assigned once the write succeeds — otherwise a locked or failed store would show an unsaved save.
        var candidate = identities
        let committed: FaceIdentity
        if let existingID, let index = candidate.firstIndex(where: { $0.id == existingID }) {
            candidate[index].name = trimmed
            candidate[index].samples = samples
            candidate[index].modelIdentifier = embedder.modelIdentifier
            candidate[index].embeddingDimension = embedder.embeddingDimension
            committed = candidate[index]
        } else {
            // Also the fallback if `existingID` no longer resolves (deleted mid-flow) — saving as new beats discarding.
            committed = FaceIdentity(
                id: UUID(),
                name: trimmed,
                samples: samples,
                modelIdentifier: embedder.modelIdentifier,
                embeddingDimension: embedder.embeddingDimension,
                createdAt: Date()
            )
            candidate.append(committed)
        }
        try saveTransaction(candidate)
        return committed
    }

    /// Case- and diacritic-insensitive, unlike `addSample`'s exact match: "alex"/"Alex"/"Álex" are one person to the
    /// user even though storage would treat them as separate identities. `excluding` lets a recapture keep its own name.
    func nameIsTaken(_ name: String, excluding id: UUID? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return identities.contains {
            $0.id != id
                && $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    /// Only updates the in-memory flag if the encrypted write succeeds, rather than showing a toggle state that isn't on disk.
    func setEnabled(_ isEnabled: Bool, for identityID: UUID) throws {
        try requireReadyForWrite()
        var candidate = identities
        guard let index = candidate.firstIndex(where: { $0.id == identityID }) else { return }
        guard candidate[index].isEnabled != isEnabled else { return }
        candidate[index].isEnabled = isEnabled
        try saveTransaction(candidate)
    }

    func delete(_ identity: FaceIdentity) throws {
        var candidate = identities
        candidate.removeAll { $0.id == identity.id }
        try saveTransaction(candidate)
    }

    /// Removes the file outright (rather than writing an empty array) — the teardown path when the session key
    /// itself is being removed, so no orphaned encrypted file is left behind for the next setup to trip over.
    func deleteAll() throws {
        try storage.deleteAll()
        identities.removeAll()
        loadState = storage.isSessionUnlocked() ? .ready : .locked
    }

    private func requireReadyForWrite() throws {
        switch loadState {
        case .locked:
            throw FaceEnrollmentStoreError.sessionLocked
        case .failed:
            throw FaceEnrollmentStoreError.storeUnreadable
        case .ready:
            break
        }
    }

    private func saveTransaction(_ candidate: [FaceIdentity]) throws {
        try requireReadyForWrite()
        try storage.save(candidate)
        identities = candidate
    }
}
