import Foundation

enum UsageWindowStartStoreError: Error, Equatable {
    case lockUnavailable
    case unreadable
    case corrupt
    case unsupportedSchema(Int)
    case writeFailed
    case oversized
}

/// Resolves the on-disk locations used by the window starter.
enum UsageWindowStartPaths {
    static func baseDirectory(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("CodexMeter", isDirectory: true)
            .appendingPathComponent("WindowStarter", isDirectory: true)
    }
}

/// Versioned, atomically written duplicate-protection state with a
/// cross-instance file lock.
///
/// The lock is an application-owned `flock` on a sibling file rather than an
/// in-memory flag, so two running CodexMeter copies cannot both decide to send.
/// Every read-modify-write happens inside the lock, which keeps one instance
/// from overwriting another's reservation.
final class UsageWindowStartStore {
    static let maximumFileBytes = 1_024 * 1_024

    let directoryURL: URL
    private let fileManager: FileManager

    init(
        directoryURL: URL = UsageWindowStartPaths.baseDirectory(),
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    var stateFileURL: URL {
        directoryURL.appendingPathComponent("state.json", isDirectory: false)
    }

    var lockFileURL: URL {
        directoryURL.appendingPathComponent("state.lock", isDirectory: false)
    }

    /// An application-owned empty working directory for the start request, so
    /// no project context or repository instructions are picked up.
    var pingDirectoryURL: URL {
        directoryURL.appendingPathComponent("Ping", isDirectory: true)
    }

    func prepareDirectories() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: pingDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Transactions

    /// Runs `body` with the cross-instance lock held, loading and saving the
    /// document around it. Returns the body's value; writes only when the body
    /// succeeds.
    func transaction<T>(
        _ body: (inout UsageWindowStartPersistedState) throws -> T
    ) throws -> T {
        let descriptor = try acquireLock()
        defer { releaseLock(descriptor) }

        let original = try loadUnlocked()
        var document = original
        let result = try body(&document)
        // A read-only decision should not rewrite the file once a minute.
        if document != original {
            try saveUnlocked(document)
        }
        return result
    }

    /// Reads the document under the lock without writing it.
    func snapshot() throws -> UsageWindowStartPersistedState {
        let descriptor = try acquireLock()
        defer { releaseLock(descriptor) }
        return try loadUnlocked()
    }

    /// Parses bytes without touching the file system. Exposed for corruption and
    /// schema-migration tests.
    static func decode(_ data: Data) throws -> UsageWindowStartPersistedState {
        let decoder = JSONDecoder()
        // Dates are stored as Unix seconds so the file stays readable across
        // Foundation strategy defaults.
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let document = try? decoder.decode(
            UsageWindowStartPersistedState.self,
            from: data
        ) else {
            throw UsageWindowStartStoreError.corrupt
        }

        // A future schema cannot be downgraded safely; refusing to load is the
        // difference between pausing sends and silently forgetting a reservation.
        guard document.schemaVersion == UsageWindowStartPersistedState.currentSchemaVersion else {
            throw UsageWindowStartStoreError.unsupportedSchema(document.schemaVersion)
        }
        return document
    }

    static func encode(_ document: UsageWindowStartPersistedState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(document) else {
            throw UsageWindowStartStoreError.writeFailed
        }
        return data
    }

    // MARK: - File primitives

    private func loadUnlocked() throws -> UsageWindowStartPersistedState {
        guard fileManager.fileExists(atPath: stateFileURL.path) else {
            return .empty
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: stateFileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= Self.maximumFileBytes else {
            throw UsageWindowStartStoreError.oversized
        }
        guard let data = try? Data(contentsOf: stateFileURL) else {
            throw UsageWindowStartStoreError.unreadable
        }

        var document = try Self.decode(data)
        // Normalize forward so a document written by an older build with a
        // different cap still loads.
        if document.schemaVersion != UsageWindowStartPersistedState.currentSchemaVersion {
            document.schemaVersion = UsageWindowStartPersistedState.currentSchemaVersion
        }
        return document
    }

    private func saveUnlocked(_ document: UsageWindowStartPersistedState) throws {
        var normalized = document
        normalized.schemaVersion = UsageWindowStartPersistedState.currentSchemaVersion
        normalized.pruneAccounts()

        let data = try Self.encode(normalized)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        do {
            try data.write(to: stateFileURL, options: [.atomic])
        } catch {
            throw UsageWindowStartStoreError.writeFailed
        }
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: stateFileURL.path
        )
    }

    private func acquireLock() throws -> Int32 {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let descriptor = open(lockFileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw UsageWindowStartStoreError.lockUnavailable
        }
        // Non-blocking so a second instance reports "busy" instead of stalling
        // the menu bar on another process's send.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw UsageWindowStartStoreError.lockUnavailable
        }
        return descriptor
    }

    private func releaseLock(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
