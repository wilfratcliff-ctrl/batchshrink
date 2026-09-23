import Foundation

@MainActor final class TemporaryFileManager: TemporaryFileManaging {
    private let root: URL
    private let files: FileManager

    init(files: FileManager = .default) {
        self.files = files
        // Only this app-owned directory may be removed. Never accept a source URL for cleanup.
        root = files.temporaryDirectory.appendingPathComponent("VideoShrink-Phase0", isDirectory: true)
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

    func requireCapacity(for bytes: Int64) throws {
        let values = try files.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        // Absence of an estimate is not evidence of zero capacity. Actual writes still report errors.
        if let available = values.volumeAvailableCapacityForImportantUsage, available < bytes {
            throw PipelineError.insufficientStorage
        }
    }

    func cleanup() throws {
        if files.fileExists(atPath: root.path) { try files.removeItem(at: root) }
    }
}
