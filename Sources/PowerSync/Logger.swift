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
