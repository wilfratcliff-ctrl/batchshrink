import Foundation

/// The two directories this app owns inside its own temporary area, one for each flow.
///
/// They are separate because the two flows' work has different lifetimes, and one shared
/// directory could not express that. The batch flow's directory is scratch: it is swept when a
/// run starts and again when one ends, because nothing in it is wanted once the run is over. The
/// one-video flow's directory is not scratch in that sense: a finished, unsaved copy sits in it
/// while the user decides whether to save it, and that decision can easily outlive a batch run.
/// While both flows used one directory, finishing a batch deleted a copy whose owner was still
/// offering to save it - the screen promised a file that a different flow had already removed.
///
/// The names are the ones the documentation has always used, so the one-video directory keeps
/// the name the privacy and cleanup notes describe.
enum TemporaryWorkspace: String {
    case oneVideo = "VideoShrink-Phase0"
    case batch = "VideoShrink-Phase0-batch"
}

@MainActor final class TemporaryFileManager: TemporaryFileManaging {
    private let root: URL
    private let files: FileManager
    /// How the free space of the volume the workspace lives on is read. It is a parameter, with
    /// the real reading as its default, because the rule that matters here - a reading this
    /// device will not give up is not evidence of a full disk - is one a test has no other way to
    /// produce.
    private let capacity: (URL) throws -> Int64?

    /// `workspace` names the directory this manager owns and is allowed to remove. It is a value
    /// type with a nonisolated case, so it is safe as a default argument - which is evaluated
    /// outside the main actor, a trap this project has hit before with `ShrinkHistoryStoring`.
    init(workspace: TemporaryWorkspace = .oneVideo,
         files: FileManager = .default,
         capacity: @escaping (URL) throws -> Int64? = TemporaryFileManager.volumeCapacity) {
        self.files = files
        self.capacity = capacity
        // Only this app-owned directory may be removed. Never accept a source URL for cleanup.
        root = files.temporaryDirectory.appendingPathComponent(workspace.rawValue, isDirectory: true)
    }

    func ensureWorkspace() throws {
        guard !files.fileExists(atPath: root.path) else { return }
        try files.createDirectory(at: root, withIntermediateDirectories: true,
                                  attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var directory = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    func outputURL() throws -> URL {
        try ensureWorkspace()
        return root.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    }

    /// Removes one file, and only one inside this app's owned temporary directory.
    func remove(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path
        else { throw PipelineError.temporaryFiles }
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
    }

    /// The volume's free space for work like this, including the space the system would reclaim
    /// to make room for it. Nil when the volume reports no figure, which is left to mean
    /// "unknown" and never "full".
    ///
    /// `nonisolated` so that it can be the default for the reading above without becoming a
    /// main-actor-only function value: the reading is a plain question about a URL, and a caller
    /// is free to ask it from wherever the step it is sizing happens to run.
    nonisolated static func volumeCapacity(of url: URL) throws -> Int64? {
        try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    /// Refuses a step whose own figure is larger than the volume says it can spare.
    ///
    /// The figure belongs to the caller and is the caller's to justify: this only compares it
    /// with what the volume reports. A reading that is absent, and a reading that cannot be taken
    /// at all, both mean unknown rather than zero, so neither can refuse a step - a step must
    /// never be turned away with a message about storage that this reading cannot back up. The
    /// write itself remains the real report, and the callers still get its real failure.
    func requireCapacity(for bytes: Int64) throws {
        guard let available = reportedCapacity() else { return }
        if available < bytes { throw PipelineError.insufficientStorage }
    }

    /// The reading, with anything this device will not answer folded into "unknown".
    private func reportedCapacity() -> Int64? {
        do { return try capacity(files.temporaryDirectory) } catch { return nil }
    }

    func cleanup() throws {
        if files.fileExists(atPath: root.path) { try files.removeItem(at: root) }
    }
}
