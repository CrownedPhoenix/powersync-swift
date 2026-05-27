import Foundation
import Logging
@testable import PowerSync

/// A swift-log `LogHandler` that captures log messages for assertion in tests.
///
/// Recorded entries are formatted as `"<level>: <message> <tag>"` for backwards
/// compatibility with assertions that ran against the previous test log writer.
final class CapturingLogHandler: LogHandler, @unchecked Sendable {
    private let storage: LogStorage
    private let levelStorage: LevelStorage
    var metadata: Logger.Metadata = [:]

    init(level: Logger.Level = .debug) {
        storage = LogStorage()
        levelStorage = LevelStorage(level: level)
    }

    var logLevel: Logger.Level {
        get { levelStorage.get() }
        set { levelStorage.set(newValue) }
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
        storage.append("\(event.level): \(event.message) \(tag)")
    }

    func getLogs() -> [String] {
        storage.snapshot()
    }
}

private final class LogStorage: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CapturingLogHandler.logs")
    private var entries: [String] = []

    func append(_ entry: String) {
        queue.sync { entries.append(entry) }
    }

    func snapshot() -> [String] {
        queue.sync { entries }
    }
}

private final class LevelStorage: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CapturingLogHandler.level")
    private var level: Logger.Level

    init(level: Logger.Level) {
        self.level = level
    }

    func get() -> Logger.Level {
        queue.sync { level }
    }

    func set(_ newValue: Logger.Level) {
        queue.sync { level = newValue }
    }
}

/// Convenience for building a test `Logger` backed by a `CapturingLogHandler`.
func makeCapturingLogger(level: Logger.Level = .debug, label: String = "test") -> (Logger, CapturingLogHandler) {
    let handler = CapturingLogHandler(level: level)
    var logger = Logger(label: label, factory: { _ in handler })
    logger.logLevel = level
    return (logger, handler)
}
