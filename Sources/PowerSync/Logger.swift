import Foundation
import Logging
import OSLog

/// A `LogHandler` that forwards messages to `os.Logger` on Apple platforms with
/// modern OS availability, and falls back to `print` otherwise.
///
/// The handler's `metadata` is rendered as `key=value` pairs appended to the message.
/// A `tag` key, if present, is rendered as a `[tag]` prefix to match the legacy log
/// format produced by previous versions of this SDK.
public struct OSLogHandler: Logging.LogHandler {
    public var metadata: Logging.Logger.Metadata = [:]
    public var logLevel: Logging.Logger.Level
    private let subsystem: String
    private let label: String
    private let osLogger: Sendable?

    public init(
        label: String,
        subsystem: String = Bundle.main.bundleIdentifier ?? "com.powersync.logger",
        logLevel: Logging.Logger.Level = .debug
    ) {
        self.label = label
        self.subsystem = subsystem
        self.logLevel = logLevel

        if #available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *) {
            osLogger = os.Logger(subsystem: subsystem, category: label)
        } else {
            osLogger = nil
        }
    }

    public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: Logging.LogEvent) {
        let merged = self.metadata.merging(event.metadata ?? [:]) { _, new in new }
        let tagPrefix: String
        var remaining = merged
        if let tag = remaining.removeValue(forKey: "tag"), case let .string(value) = tag, !value.isEmpty {
            tagPrefix = "[\(value)] "
        } else {
            tagPrefix = ""
        }
        let suffix = remaining.isEmpty
            ? ""
            : " " + remaining
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
        let formatted = "\(tagPrefix)\(event.message.description)\(suffix)"

        if #available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *) {
            guard let osLogger = osLogger as? os.Logger else { return }
            switch event.level {
            case .trace, .debug:
                osLogger.debug("\(formatted, privacy: .public)")
            case .info, .notice:
                osLogger.info("\(formatted, privacy: .public)")
            case .warning:
                osLogger.warning("\(formatted, privacy: .public)")
            case .error:
                osLogger.error("\(formatted, privacy: .public)")
            case .critical:
                osLogger.fault("\(formatted, privacy: .public)")
            }
        } else {
            print("\(event.level): \(formatted)")
        }
    }
}

/// Creates a `Logger` that uses `OSLogHandler` and is the default logger used when no
/// custom logger is supplied to PowerSync APIs.
public func defaultPowerSyncLogger(label: String = "PowerSync") -> Logging.Logger {
    var logger = Logging.Logger(label: label, factory: { OSLogHandler(label: $0) })
    logger.logLevel = .debug
    return logger
}

// MARK: - LogSeverity / Logger.Level bridging

extension LogSeverity {
    /// Maps a swift-log `Logger.Level` to the closest legacy `LogSeverity`.
    public init(_ level: Logging.Logger.Level) {
        switch level {
        case .trace, .debug: self = .debug
        case .info, .notice: self = .info
        case .warning: self = .warning
        case .error: self = .error
        case .critical: self = .fault
        }
    }

    /// The swift-log `Logger.Level` corresponding to this severity.
    public var asSwiftLogLevel: Logging.Logger.Level {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        case .fault: return .critical
        }
    }
}

// MARK: - Legacy: PrintLogWriter

/// A log writer which prints to the standard output.
///
/// This writer uses `os.Logger` on iOS/macOS/tvOS/watchOS 14+ and falls back to
/// `print` for earlier versions. It is a legacy API; new code should configure
/// a swift-log `LogHandler` such as `OSLogHandler` instead.
public final class PrintLogWriter: LogWriterProtocol {
    private let subsystem: String
    private let category: String
    private let osLogger: Sendable?

    /// Creates a new `PrintLogWriter`.
    /// - Parameters:
    ///   - subsystem: The subsystem identifier (typically reverse DNS notation of your app).
    ///   - category: The category within your subsystem.
    public init(
        subsystem: String = Bundle.main.bundleIdentifier ?? "com.powersync.logger",
        category: String = "default"
    ) {
        self.subsystem = subsystem
        self.category = category

        if #available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *) {
            osLogger = os.Logger(subsystem: subsystem, category: category)
        } else {
            osLogger = nil
        }
    }

    public func log(severity: LogSeverity, message: String, tag: String?) {
        let tagPrefix = tag.map { !$0.isEmpty ? "[\($0)] " : "" } ?? ""
        let formatted = "\(tagPrefix)\(message)"

        if #available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *) {
            guard let osLogger = osLogger as? os.Logger else { return }
            switch severity {
            case .info:
                osLogger.info("\(formatted, privacy: .public)")
            case .error:
                osLogger.error("\(formatted, privacy: .public)")
            case .debug:
                osLogger.debug("\(formatted, privacy: .public)")
            case .warning:
                osLogger.warning("\(formatted, privacy: .public)")
            case .fault:
                osLogger.fault("\(formatted, privacy: .public)")
            }
        } else {
            print("\(severity.stringValue): \(formatted)")
        }
    }
}

// MARK: - Legacy: DefaultLogger

/// A logger that conforms to `LoggerProtocol` and routes messages through a
/// swift-log `Logger` whose handlers dispatch to the configured
/// `LogWriterProtocol` writers.
///
/// This is a legacy adapter; new code should construct a `Logging.Logger`
/// directly (for example, via `defaultPowerSyncLogger()`).
public final class DefaultLogger: LoggerProtocol,
    // The shared state is guarded by the DispatchQueue.
    @unchecked Sendable
{
    private var minSeverity: LogSeverity
    private var writers: [any LogWriterProtocol]
    private let queue = DispatchQueue(label: "DefaultLogger.queue")
    private var swiftLogger: Logging.Logger

    /// Initializes the default logger with an optional minimum severity level.
    ///
    /// - Parameters:
    ///   - minSeverity: The minimum severity level to log. Defaults to `.debug`.
    ///   - writers: Optional writers to which logs are written. Defaults to a single `PrintLogWriter`.
    public init(minSeverity: LogSeverity = .debug, writers: [any LogWriterProtocol]? = nil) {
        let initialWriters = writers ?? [PrintLogWriter()]
        self.writers = initialWriters
        self.minSeverity = minSeverity
        self.swiftLogger = Self.makeLogger(writers: initialWriters, minSeverity: minSeverity)
    }

    public func setWriters(_ writers: [any LogWriterProtocol]) {
        queue.sync {
            self.writers = writers
            self.swiftLogger = Self.makeLogger(writers: writers, minSeverity: self.minSeverity)
        }
    }

    public func setMinSeverity(_ severity: LogSeverity) {
        queue.sync {
            self.minSeverity = severity
            self.swiftLogger.logLevel = severity.asSwiftLogLevel
        }
    }

    public func debug(_ message: String, tag: String? = nil) { emit(.debug, message, tag) }
    public func info(_ message: String, tag: String? = nil) { emit(.info, message, tag) }
    public func warning(_ message: String, tag: String? = nil) { emit(.warning, message, tag) }
    public func error(_ message: String, tag: String? = nil) { emit(.error, message, tag) }
    public func fault(_ message: String, tag: String? = nil) { emit(.critical, message, tag) }

    /// The internal swift-log `Logger`. Used by `asSwiftLogger()` to avoid an
    /// extra adapter layer when a `DefaultLogger` is bridged to swift-log.
    var underlyingSwiftLogger: Logging.Logger {
        queue.sync { swiftLogger }
    }

    private func emit(_ level: Logging.Logger.Level, _ message: String, _ tag: String?) {
        let logger = queue.sync { swiftLogger }
        let metadata: Logging.Logger.Metadata? = tag.map { ["tag": .string($0)] }
        logger.log(level: level, "\(message)", metadata: metadata)
    }

    private static func makeLogger(
        writers: [any LogWriterProtocol],
        minSeverity: LogSeverity
    ) -> Logging.Logger {
        let handlers: [any Logging.LogHandler] = writers.map { LogWriterHandler(writer: $0) }
        var logger = Logging.Logger(label: "PowerSync.DefaultLogger") { _ in
            if handlers.count == 1 {
                return handlers[0]
            } else {
                return MultiplexLogHandler(handlers)
            }
        }
        logger.logLevel = minSeverity.asSwiftLogLevel
        return logger
    }
}

// MARK: - Internal bridges

/// A `LogHandler` that forwards events to a `LogWriterProtocol`.
struct LogWriterHandler: Logging.LogHandler {
    let writer: any LogWriterProtocol
    var metadata: Logging.Logger.Metadata = [:]
    /// Always `.trace` — filtering happens at the outer `Logger`.
    var logLevel: Logging.Logger.Level = .trace

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: Logging.LogEvent) {
        let merged = metadata.merging(event.metadata ?? [:]) { _, new in new }
        let tag: String?
        if case let .some(.string(value)) = merged["tag"] {
            tag = value
        } else {
            tag = nil
        }
        writer.log(severity: LogSeverity(event.level), message: "\(event.message)", tag: tag)
    }
}

/// A `LogHandler` that forwards events to a `LoggerProtocol`.
struct LoggerProtocolHandler: Logging.LogHandler {
    let legacy: any LoggerProtocol
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .trace

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: Logging.LogEvent) {
        let merged = metadata.merging(event.metadata ?? [:]) { _, new in new }
        let tag: String?
        if case let .some(.string(value)) = merged["tag"] {
            tag = value
        } else {
            tag = nil
        }
        let message = "\(event.message)"
        switch event.level {
        case .trace, .debug: legacy.debug(message, tag: tag)
        case .info, .notice: legacy.info(message, tag: tag)
        case .warning: legacy.warning(message, tag: tag)
        case .error: legacy.error(message, tag: tag)
        case .critical: legacy.fault(message, tag: tag)
        }
    }
}

/// A `LoggerProtocol` view over a swift-log `Logger`.
struct SwiftLogBridge: LoggerProtocol, @unchecked Sendable {
    let logger: Logging.Logger

    func info(_ message: String, tag: String?) { emit(.info, message, tag) }
    func error(_ message: String, tag: String?) { emit(.error, message, tag) }
    func debug(_ message: String, tag: String?) { emit(.debug, message, tag) }
    func warning(_ message: String, tag: String?) { emit(.warning, message, tag) }
    func fault(_ message: String, tag: String?) { emit(.critical, message, tag) }

    private func emit(_ level: Logging.Logger.Level, _ message: String, _ tag: String?) {
        let metadata: Logging.Logger.Metadata? = tag.map { ["tag": .string($0)] }
        logger.log(level: level, "\(message)", metadata: metadata)
    }
}

extension LoggerProtocol {
    /// Returns a swift-log `Logger` that routes log events to this
    /// `LoggerProtocol`.
    ///
    /// If `self` is a `DefaultLogger`, the underlying swift-log `Logger` is
    /// returned directly to avoid an extra adapter layer.
    public func asSwiftLogger(label: String = "PowerSync") -> Logging.Logger {
        if let defaultLogger = self as? DefaultLogger {
            return defaultLogger.underlyingSwiftLogger
        }
        var logger = Logging.Logger(label: label) { _ in
            LoggerProtocolHandler(legacy: self)
        }
        logger.logLevel = .trace
        return logger
    }
}
