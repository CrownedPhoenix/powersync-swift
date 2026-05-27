import Logging

/// Level of logs to expose to a `SyncRequestLogger` handler.
///
/// Controls the verbosity of network logging for PowerSync HTTP requests.
/// The log level is configured once during initialization and determines
/// which network events will be logged throughout the session.
public enum SyncRequestLogLevel: Sendable {
    /// Log all network activity including headers, body, and info
    case all
    /// Log only request/response headers
    case headers
    /// Log only request/response body content
    case body
    /// Log basic informational messages about requests
    case info
    /// Disable all network logging
    case none
}

/// Configuration for PowerSync HTTP request logging.
///
/// This configuration is set once during initialization and used throughout
/// the PowerSync session. The `requestLevel` determines which network events
/// are logged.
///
/// - Note: The request level cannot be changed after initialization. A new call to `PowerSyncDatabase.connect` is required to change the level.
public struct SyncRequestLoggerConfiguration: Sendable {
    /// The request logging level that determines which network events are logged.
    /// Set once during initialization and used throughout the session.
    public let requestLevel: SyncRequestLogLevel

    private let logHandler: @Sendable (_ message: String) -> Void

    /// Creates a new network logger configuration.
    /// - Parameters:
    ///   - requestLevel: The `SyncRequestLogLevel` to use for filtering log messages
    ///   - logHandler: A closure which handles log messages
    public init(
        requestLevel: SyncRequestLogLevel,
        logHandler: @Sendable @escaping (_ message: String) -> Void
    ) {
        self.requestLevel = requestLevel
        self.logHandler = logHandler
    }

    public func log(_ message: String) {
        logHandler(message)
    }

    /// Creates a new network logger configuration that forwards messages to a swift-log
    /// `Logger`.
    ///
    /// All messages emitted by this configuration are logged at `level`. If `tag` is
    /// provided, it is attached as a `tag` metadata entry on every log message, which
    /// `OSLogHandler` renders as a `[tag]` prefix.
    ///
    /// - Parameters:
    ///   - requestLevel: The `SyncRequestLogLevel` to use for filtering which network events are logged.
    ///   - logger: A `Logger` that will receive log messages.
    ///   - level: The level to use for all log messages (defaults to `.debug`).
    ///   - tag: An optional tag attached as `tag` metadata on each log message.
    public init(
        requestLevel: SyncRequestLogLevel,
        logger: Logger,
        level: Logger.Level = .debug,
        tag: String? = nil
    ) {
        self.requestLevel = requestLevel
        let metadata: Logger.Metadata? = tag.map { ["tag": .string($0)] }
        logHandler = { message in
            logger.log(level: level, "\(message)", metadata: metadata)
        }
    }
}
