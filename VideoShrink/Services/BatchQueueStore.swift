import Foundation
import OSLog

@MainActor protocol BatchQueueStoring {
    func load() -> BatchQueueRecord?
    func save(_ record: BatchQueueRecord) throws
    func clear()
}

/// Keeps the queue in the app's own Application Support directory, outside the backup, behind
/// file protection. Best effort: a queue that cannot be written only costs the ability to
/// resume, so the caller is told and the run carries on.
@MainActor final class FileBatchQueueStore: BatchQueueStoring {
    private let log = Logger(subsystem: "VideoShrink", category: "Queue")
    private let url: URL

    /// - Parameter directory: overridden by tests; production uses Application Support.
    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        url = base.appendingPathComponent("VideoShrink", isDirectory: true)
            .appendingPathComponent("queue.json")
    }

    func load() -> BatchQueueRecord? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let data = text.data(using: .utf8),
              let record = try? JSONDecoder().decode(BatchQueueRecord.self, from: data),
              record.version == BatchQueueRecord.currentVersion,
              !record.items.isEmpty
        else { return nil }
        return record
    }

    func save(_ record: BatchQueueRecord) throws {
        try ensureDirectory()
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }

    /// Writes an empty queue rather than deleting anything. An empty record reads as no queue.
    func clear() {
        let empty = BatchQueueRecord(settings: .init(resolution: "", frameRate: ""), items: [])
        do { try save(empty) }
        catch { log.error("Clearing the stored queue failed") }
    }

    private func ensureDirectory() throws {
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }
}
