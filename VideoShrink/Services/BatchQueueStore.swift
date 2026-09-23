import Foundation
import OSLog

@MainActor protocol BatchQueueStoring {
    func load() -> BatchQueueRecord?
    func save(_ record: BatchQueueRecord) throws
    func clear()
    /// Whether a saved queue is there that this build cannot read back.
    ///
    /// A launch that has already failed to read a record has no way to tell "there was never a run"
    /// from "there was one this build cannot read" unless the store says so, and the difference
    /// matters: a record can name a video whose copy Photos may already hold, and a launch that
    /// reads nothing has no way to keep that video out of an automatic selection. A store that
    /// cannot tell says no rather than guessing.
    @MainActor func hasUnreadableRecord() -> Bool
}

extension BatchQueueStoring {
    @MainActor func hasUnreadableRecord() -> Bool { false }
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
              !record.isEmpty
        else { return nil }
        return record
    }

    /// Whether the file on disk is a queue this build cannot read, rather than no queue at all.
    ///
    /// The three shapes are told apart deliberately. A file that is not there, and a queue with
    /// nothing in it - which is what the app writes to mean "no run" - are both no queue. A file
    /// that is there and cannot be decoded at all, or holds a version this build does not read with
    /// something in it, is a record that has to be set aside, and the launch is the only place the
    /// user can be told.
    func hasUnreadableRecord() -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let data = text.data(using: .utf8) else {
            // Either there is no file, or it cannot be read as text at all - which is the file
            // protection class refusing, or a write that never finished. Only a file that is
            // actually there is a record this build set aside.
            return FileManager.default.fileExists(atPath: url.path)
        }
        guard let record = try? JSONDecoder().decode(BatchQueueRecord.self, from: data) else {
            // Present, and not a queue: a write that did not finish, or a shape from a build this
            // one does not know. There is nothing to restore and nothing that can say what it held.
            return true
        }
        // An empty queue is the app's own way of writing "no run", and an older version's empty
        // queue holds nothing either. A version this build does not read, *with* something in it, is
        // the record being set aside.
        return !record.isEmpty && record.version != BatchQueueRecord.currentVersion
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
