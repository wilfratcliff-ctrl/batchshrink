import Foundation
import AVFoundation

@MainActor protocol PhotoLibraryServing {
    func requestAccess() async throws -> Bool // true means limited access
    func retrieve(identifier: String, progress: @escaping @MainActor (Double) -> Void) async throws -> RetrievedVideo
    func cancelRetrieval()
    /// Saves a copy and returns the local identifier of the new asset when Photos reports one.
    func save(videoAt url: URL, identity: AssetIdentity) async throws -> String?
    /// A locally available file for an asset this app just created, without any network access.
    func localFileURL(identifier: String) async -> URL?
    /// A player item for looking at an original before deciding. Playback may stream or fetch from
    /// iCloud, which is the point: you cannot judge a video you cannot see.
    func playerItem(identifier: String) async throws -> AVPlayerItem
    /// Deletes originals in a single Photos transaction, because that is what Photos confirms
    /// once. Returns the identifiers it found and included; anything else was already gone.
    /// Only ever called behind `DeletionPolicy`.
    func deleteOriginals(identifiers: [String]) async throws -> [String]
    /// The receipt to store next to a copy Photos just handed back, or nil unless both the copy
    /// and the original can be looked up right now. A receipt is only ever written from a real
    /// read-back, and it is the only thing that can later justify a delete.
    func deletionEvidence(originalIdentifier: String, copyIdentifier: String) -> DeletionEvidence?
    /// Looks the copy and the original up again and says whether the stored receipt still holds.
    func revalidateForDeletion(_ evidence: DeletionEvidence) -> CopyRevalidation
    /// The one deletion path new code should use: every candidate is looked up again first, and
    /// anything missing, changed or unreadable is left alone. Still one Photos transaction, so
    /// Photos still asks once.
    func deleteOriginals(afterRevalidating evidence: [String: DeletionEvidence]) async throws -> DeletionResult
}

@MainActor protocol VideoTranscoding {
    /// Returns the file it wrote, which is always inside this app's temporary workspace.
    func transcode(_ source: RetrievedVideo, metadata: VideoMetadata, settings: TranscodeSettings,
                   progress: @escaping @MainActor (Double) -> Void) async throws -> URL
    func cancel()
}

protocol VideoVerifying {
    func inspect(_ url: URL) async throws -> VideoMetadata
    func verify(_ url: URL, source: VideoMetadata, expecting codec: VideoCodec?) async throws -> VideoMetadata
    /// Checks a copy Photos handed back against the properties this run measured and approved
    /// before saving it, so the read-back path cannot settle for a weaker rule set than the
    /// export check that came before it.
    func verifyImportedCopy(_ url: URL, matching expected: VideoMetadata) async throws -> VideoMetadata
}

@MainActor protocol TemporaryFileManaging {
    func ensureWorkspace() throws
    func outputURL() throws -> URL
    func remove(_ url: URL) throws
    func requireCapacity(for bytes: Int64) throws
    func cleanup() throws
}

@MainActor protocol LibraryScanning {
    func scan(progress: @escaping @MainActor (LibraryScanProgress) -> Void) async throws -> LibraryScanResult
    func cancel()
}

/// On-device memory of what this iPhone has already shrunk, plus the copy bitrates those
/// runs measured. Nothing here leaves the device and no media, name or location is stored.
@MainActor protocol ShrinkHistoryStoring {
    func completedIdentifiers() -> Set<String>
    func copyMeasurements() -> [CopyMeasurement]
    func record(identifier: String, measurement: CopyMeasurement?)
}
