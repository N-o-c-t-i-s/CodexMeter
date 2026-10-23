import XCTest
@testable import CodexMeterCore

final class UsageWindowStartStoreTests: XCTestCase {
    private let now = WindowStartFixtures.base
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowStartStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        super.tearDown()
    }

    func testMissingFileReadsAsAnEmptyDocument() throws {
        let store = UsageWindowStartStore(directoryURL: directory)

        let document = try store.snapshot()

        XCTAssertTrue(document.accounts.isEmpty)
        XCTAssertEqual(
            document.schemaVersion,
            UsageWindowStartPersistedState.currentSchemaVersion
        )
    }

    func testTransactionPersistsTheReservationForTheNextLaunch() throws {
        let store = UsageWindowStartStore(directoryURL: directory)
        let deadline = now.addingTimeInterval(90)

        try store.transaction { document in
            var record = document.record(for: WindowStartFixtures.chatgptKey)
            record.state.phase = .awaitingConfirmation
            record.state.episodeOpen = true
            record.state.reservedAt = now
            record.state.lastSentAt = now
            record.state.confirmationDeadline = deadline
            record.updatedAt = now
            document.accounts[WindowStartFixtures.chatgptKey] = record
        }

        // A brand-new store instance stands in for a relaunch.
        let reopened = UsageWindowStartStore(directoryURL: directory)
        let record = try reopened.snapshot().record(for: WindowStartFixtures.chatgptKey)

        XCTAssertEqual(record.state.phase, .awaitingConfirmation)
        XCTAssertTrue(record.state.episodeOpen)
        XCTAssertEqual(record.state.confirmationDeadline, deadline)
    }

    func testPerAccountRecordsStayIsolated() throws {
        let store = UsageWindowStartStore(directoryURL: directory)

        try store.transaction { document in
            var first = document.record(for: "chatgpt:a")
            first.settings.autoStartEnabled = true
            first.updatedAt = now
            document.accounts["chatgpt:a"] = first

            var second = document.record(for: "chatgpt:b")
            second.settings.autoStartEnabled = false
            second.updatedAt = now
            document.accounts["chatgpt:b"] = second
        }

        let document = try store.snapshot()
        XCTAssertTrue(document.record(for: "chatgpt:a").settings.autoStartEnabled)
        XCTAssertFalse(document.record(for: "chatgpt:b").settings.autoStartEnabled)
        XCTAssertEqual(
            document.record(for: "chatgpt:c").settings,
            .defaultValue,
            "an unseen account must default to automatic sending off"
        )
    }

    func testCorruptFileSurfacesInsteadOfBeingSilentlyReplaced() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("totally not json".utf8).write(
            to: directory.appendingPathComponent("state.json")
        )

        let store = UsageWindowStartStore(directoryURL: directory)

        XCTAssertThrowsError(try store.snapshot()) { error in
            XCTAssertEqual(error as? UsageWindowStartStoreError, .corrupt)
        }
        // The unreadable bytes must survive so the user can still recover data.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("state.json").path
        ))
    }

    func testFutureSchemaSurfacesInsteadOfBeingCleared() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = ["schemaVersion": 99, "accounts": [:]] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: directory.appendingPathComponent("state.json"))

        XCTAssertThrowsError(try UsageWindowStartStore(directoryURL: directory).snapshot()) { error in
            XCTAssertEqual(error as? UsageWindowStartStoreError, .unsupportedSchema(99))
        }
    }

    func testOversizedFileIsRejectedWithoutReadingItAll() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let padding = Data(repeating: 0x20, count: UsageWindowStartStore.maximumFileBytes + 1)
        try padding.write(to: directory.appendingPathComponent("state.json"))

        XCTAssertThrowsError(try UsageWindowStartStore(directoryURL: directory).snapshot()) { error in
            XCTAssertEqual(error as? UsageWindowStartStoreError, .oversized)
        }
    }

    func testSecondInstanceCannotEnterTheTransaction() throws {
        let first = UsageWindowStartStore(directoryURL: directory)
        let second = UsageWindowStartStore(directoryURL: directory)

        try first.transaction { _ in
            XCTAssertThrowsError(try second.transaction { _ in }) { error in
                XCTAssertEqual(error as? UsageWindowStartStoreError, .lockUnavailable)
            }
            // A plain read is also serialized, so it cannot observe a half-written
            // state from another instance.
            XCTAssertThrowsError(try second.snapshot()) { error in
                XCTAssertEqual(error as? UsageWindowStartStoreError, .lockUnavailable)
            }
        }

        // Once the first transaction finishes the lock is released.
        XCTAssertNoThrow(try second.snapshot())
    }

    func testFailedBodyDoesNotWriteAnything() throws {
        let store = UsageWindowStartStore(directoryURL: directory)
        struct Expected: Error {}

        XCTAssertThrowsError(
            try store.transaction { document in
                document.accounts["chatgpt:x"] = .empty(at: now)
                throw Expected()
            }
        ) { error in
            XCTAssertTrue(error is Expected)
        }

        XCTAssertTrue(try store.snapshot().accounts.isEmpty)
    }

    func testWrittenFileIsPrivateAndSyntacticallyValid() throws {
        let store = UsageWindowStartStore(directoryURL: directory)
        try store.transaction { document in
            document.accounts[WindowStartFixtures.chatgptKey] = .empty(at: now)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: store.stateFileURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)

        let data = try Data(contentsOf: store.stateFileURL)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testPingDirectoryIsCreatedOnDemand() throws {
        let store = UsageWindowStartStore(directoryURL: directory)
        try store.prepareDirectories()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.pingDirectoryURL.path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
    }
}
