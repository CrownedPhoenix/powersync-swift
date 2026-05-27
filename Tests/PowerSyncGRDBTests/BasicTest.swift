@testable import GRDB
import Logging
@testable import PowerSync
@testable import PowerSyncGRDB

import XCTest

struct User: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: String
    var name: String

    static let databaseTableName = "users"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
    }
}

struct Pet: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: String
    var name: String
    var ownerId: String

    static let databaseTableName = "pets"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case ownerId = "owner_id"
    }

    enum Columns {
        static let ownerId = Column(CodingKeys.ownerId)
    }

    static let user = belongsTo(
        User.self,
        key: "user",
        using: ForeignKey([Columns.ownerId], to: [User.Columns.id])
    )
}

final class GRDBTests: XCTestCase {
    private var database: PowerSyncDatabaseProtocol!
    private var schema: Schema!
    private var pool: DatabasePool!
    private var logs: CapturingLogHandler!

    override func setUp() async throws {
        try await super.setUp()

        // Use a unique identifier per test instance to avoid conflicts during parallel test execution
        let dbIdentifier = "test-\(UUID().uuidString).sqlite"

        schema = Schema(tables: [
            Table(name: "users", columns: [
                .text("name")
            ]),
            Table(name: "pets", columns: [
                .text("name"),
                .text("owner_id")
            ])
        ])

        var config = Configuration()

        try config.configurePowerSync(
            schema: schema
        )

        guard let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw XCTestError(
                .failureWhileWaiting,
                userInfo: [NSLocalizedDescriptionKey: "Could not access documents directory"]
            )
        }

        // Ensure the documents directory exists
        try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true, attributes: nil)

        let dbURL = documentsDir.appendingPathComponent(dbIdentifier)
        pool = try DatabasePool(
            path: dbURL.path,
            configuration: config
        )

        logs = CapturingLogHandler(level: .debug)
        let capturedHandler = logs!
        var logger = Logger(label: "PowerSyncGRDBTests", factory: { _ in capturedHandler })
        logger.logLevel = .debug
        database = openPowerSyncWithGRDB(
            pool: pool,
            schema: schema,
            identifier: dbIdentifier,
            logger: logger
        )

        try await database.disconnectAndClear()
    }

    override func tearDown() async throws {
        try? await database?.disconnectAndClear()
        try? await database.close(deleteDatabase: true)
        database = nil
        try? pool?.close()
        pool = nil
        try await super.tearDown()
    }

    func testBasicOperations() async throws {
        // Create users with the PowerSync SDK
        let initialUserName = "Bob"

        try await database.execute(
            sql: "INSERT INTO users(id, name) VALUES(uuid(), ?)",
            parameters: [initialUserName]
        )

        // Fetch those users
        let initialUserNames = try await database.getAll(
            "SELECT * FROM users"
        ) { cursor in
            try cursor.getString(name: "name")
        }

        XCTAssertTrue(initialUserNames.first == initialUserName)

        // Now define a GRDB struct for query purposes
        // Query the Users with GRDB, this should have the same result as with PowerSync
        let grdbUserNames = try await pool.read { database in
            try User.fetchAll(database)
        }

        XCTAssertTrue(grdbUserNames.first?.name == initialUserName)

        // Insert a user with GRDB
        try await pool.write { database in
            try User(
                id: UUID().uuidString,
                name: "another",
            ).insert(database)
        }

        let grdbUserNames2 = try await pool.read { database in
            try User.order(User.Columns.name.asc).fetchAll(database)
        }
        XCTAssert(grdbUserNames2.count == 2)
        XCTAssert(grdbUserNames2[1].name == "another")
    }

    func testJoins() async throws {
        // Create users with the PowerSync SDK
        try await pool.write { database in
            let userId = UUID().uuidString
            try User(
                id: userId,
                name: "Bob"
            ).insert(database)

            try Pet(
                id: UUID().uuidString,
                name: "Fido",
                ownerId: userId
            ).insert(database)
        }

        struct PetWithUser: Decodable, FetchableRecord {
            struct PartialUser: Decodable {
                var name: String
            }

            var pet: Pet // The base record
            var user: PartialUser // The partial associated record
        }

        let petsWithUsers = try await pool.read { db in
            try Pet
                .including(required: Pet.user)
                .asRequest(of: PetWithUser.self)
                .fetchAll(db)
        }

        XCTAssert(petsWithUsers.count == 1)
        XCTAssert(petsWithUsers[0].pet.name == "Fido")
        XCTAssert(petsWithUsers[0].user.name == "Bob")
    }

    func testPowerSyncUpdates() async throws {
        let expectation = XCTestExpectation(description: "Watch changes")

        // Create an actor to handle concurrent mutations
        actor ResultsStore {
            private var results: Set<String> = []

            func append(_ names: [String]) {
                results.formUnion(names)
            }

            func getResults() -> Set<String> {
                results
            }

            func count() -> Int {
                results.count
            }
        }

        let resultsStore = ResultsStore()

        let watchTask = Task { [database] in
            guard let database = database else {
                XCTFail("Database is nil")
                return
            }

            let stream = try database.watch(
                options: WatchOptions(
                    sql: "SELECT name FROM users ORDER BY id",
                    mapper: { cursor in
                        try cursor.getString(index: 0)
                    }
                ))
            for try await names in stream {
                await resultsStore.append(names)
                if await resultsStore.count() == 2 {
                    expectation.fulfill()
                }
            }
        }

        try await database.execute(
            sql: "INSERT INTO users(id, name) VALUES(uuid(), ?)",
            parameters: ["one"]
        )

        try await database.execute(
            sql: "INSERT INTO users(id, name) VALUES(uuid(), ?)",
            parameters: ["two"]
        )
        await fulfillment(of: [expectation], timeout: 5)
        watchTask.cancel()
    }

    func testPowerSyncUpdatesFromGRDB() async throws {
        let expectation = XCTestExpectation(description: "Watch changes")

        // Create an actor to handle concurrent mutations
        actor ResultsStore {
            private var results: Set<String> = []

            func append(_ names: [String]) {
                results.formUnion(names)
            }

            func getResults() -> Set<String> {
                results
            }

            func count() -> Int {
                results.count
            }
        }

        let resultsStore = ResultsStore()

        let watchTask = Task { [database] in
            guard let database = database else {
                XCTFail("Database is nil")
                return
            }
            let stream = try database.watch(
                options: WatchOptions(
                    sql: "SELECT name FROM users ORDER BY id",
                    mapper: { cursor in
                        try cursor.getString(index: 0)
                    }
                ))
            for try await names in stream {
                await resultsStore.append(names)
                if await resultsStore.count() == 2 {
                    expectation.fulfill()
                }
            }
        }

        try await pool.write { database in
            try User(
                id: UUID().uuidString,
                name: "one",
            ).insert(database)
        }

        try await pool.write { database in
            try User(
                id: UUID().uuidString,
                name: "two",
            ).insert(database)
        }

        await fulfillment(of: [expectation], timeout: 5)
        watchTask.cancel()
    }

    func testGRDBUpdatesFromPowerSync() async throws {
        let expectation = XCTestExpectation(description: "Watch changes")

        // Create an actor to handle concurrent mutations
        actor ResultsStore {
            private var results: Set<String> = []

            func append(_ names: [String]) {
                results.formUnion(names)
            }

            func getResults() -> Set<String> {
                results
            }

            func count() -> Int {
                results.count
            }
        }

        let resultsStore = ResultsStore()

        let watchTask = Task { [pool] in
            guard let pool = pool else {
                XCTFail("Database pool is nil")
                return
            }
            let observation = ValueObservation.tracking {
                try User.order(User.Columns.name.asc).fetchAll($0)
            }

            for try await users in observation.values(in: pool) {
                await resultsStore.append(users.map { $0.name })
                if await resultsStore.count() == 2 {
                    expectation.fulfill()
                }
            }
        }

        try await database.execute(
            sql: "INSERT INTO users(id, name) VALUES(uuid(), ?)",
            parameters: ["one"]
        )

        try await database.execute(
            sql: "INSERT INTO users(id, name) VALUES(uuid(), ?)",
            parameters: ["two"]
        )

        await fulfillment(of: [expectation], timeout: 5)
        watchTask.cancel()
    }

    func testGRDBUpdatesFromIndirectPowerSyncFunction() async throws {
        try await database.execute(
            sql: "INSERT INTO users(id, name) VALUES(uuid(), ?)",
            parameters: ["a user"]
        )

        var events = ValueObservation.tracking {
            try User.order(User.Columns.name.asc).fetchAll($0)
        }.values(in: pool).makeAsyncIterator()
        let first = try await events.next()
        XCTAssertEqual(first?.count, 1)

        // We want to assert that internal statements from the core extension still
        // update GRDB value observations.
        try await database.disconnectAndClear()
        let second = try await events.next()
        XCTAssertEqual(second?.count, 0)
    }

    func testShouldThrowErrorsFromPowerSync() async throws {
        do {
            try await database.execute(
                sql: "INSERT INTO non_existent_table(id, name) VALUES(uuid(), ?)",
                parameters: ["one"]
            )
            XCTFail("Should throw error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("non_existent_table")) // Expected
        }
    }

    func testGRDBUpdatesFromGRDB() async throws {
        let expectation = XCTestExpectation(description: "Watch changes")

        // Create an actor to handle concurrent mutations
        actor ResultsStore {
            private var results: Set<String> = []

            func append(_ names: [String]) {
                results.formUnion(names)
            }

            func getResults() -> Set<String> {
                results
            }

            func count() -> Int {
                results.count
            }
        }

        let resultsStore = ResultsStore()

        let watchTask = Task { [pool] in
            guard let pool = pool else {
                XCTFail("Database pool is nil")
                return
            }

            let observation = ValueObservation.tracking {
                try User.order(User.Columns.name.asc).fetchAll($0)
            }

            for try await users in observation.values(in: pool) {
                await resultsStore.append(users.map { $0.name })
                if await resultsStore.count() == 2 {
                    expectation.fulfill()
                }
            }
        }

        try await pool.write { database in
            try User(
                id: UUID().uuidString,
                name: "one",
            ).insert(database)
        }

        try await pool.write { database in
            try User(
                id: UUID().uuidString,
                name: "two",
            ).insert(database)
        }

        await fulfillment(of: [expectation], timeout: 5)
        watchTask.cancel()
    }
    
    func testCustomLogger() async throws {
        try await database.get("SELECT 1", mapper: { row in })

        let warningIndex = logs.getLogs().firstIndex(
            where: { value in
                value.contains("debug: Opened connection. SQLite version")
            }
        )

        XCTAssert(warningIndex! >= 0)
    }
}

final class CapturingLogHandler: LogHandler, @unchecked Sendable {
    private let queue = DispatchQueue(label: "CapturingLogHandler")
    private var logs: [String] = []
    private var levelValue: Logger.Level
    var metadata: Logger.Metadata = [:]

    init(level: Logger.Level = .debug) {
        levelValue = level
    }

    var logLevel: Logger.Level {
        get { queue.sync { levelValue } }
        set { queue.sync { levelValue = newValue } }
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let merged = self.metadata.merging(event.metadata ?? [:]) { _, new in new }
        let tag: String
        if case let .some(.string(value)) = merged["tag"] {
            tag = value
        } else {
            tag = ""
        }
        queue.sync {
            logs.append("\(event.level): \(event.message) \(tag)")
        }
    }

    func getLogs() -> [String] {
        queue.sync { logs }
    }
}
