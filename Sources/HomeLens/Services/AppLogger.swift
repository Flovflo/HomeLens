import Foundation
import OSLog

@MainActor
final class AppLogger: ObservableObject {
    @Published private(set) var events: [LogEvent] = []

    private let osLog = Logger(subsystem: "com.homelens.app", category: "app")
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func debug(_ subsystem: String, _ message: String) {
        append(.debug, subsystem, message)
    }

    func info(_ subsystem: String, _ message: String) {
        append(.info, subsystem, message)
    }

    func warning(_ subsystem: String, _ message: String) {
        append(.warning, subsystem, message)
    }

    func error(_ subsystem: String, _ message: String) {
        append(.error, subsystem, message)
    }

    func exportText() -> String {
        events.map { event in
            "\(dateFormatter.string(from: event.timestamp)) [\(event.level.title)] [\(event.subsystem)] \(event.message)"
        }
        .joined(separator: "\n")
    }

    private func append(_ level: LogLevel, _ subsystem: String, _ message: String) {
        let sanitized = message.redactingSecrets
        events.append(LogEvent(level: level, subsystem: subsystem, message: sanitized))
        if events.count > 600 {
            events.removeFirst(events.count - 600)
        }

        switch level {
        case .debug:
            osLog.debug("[\(subsystem, privacy: .public)] \(sanitized, privacy: .public)")
        case .info:
            osLog.info("[\(subsystem, privacy: .public)] \(sanitized, privacy: .public)")
        case .warning:
            osLog.warning("[\(subsystem, privacy: .public)] \(sanitized, privacy: .public)")
        case .error:
            osLog.error("[\(subsystem, privacy: .public)] \(sanitized, privacy: .public)")
        }
    }
}

private extension String {
    var redactingSecrets: String {
        var value = self
        value = value.replacingOccurrences(
            of: #"(?i)(password|passwd|pwd)=([^&\s]+)"#,
            with: "$1=***",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)(rtsp://)([^:@/\s]+):([^@\s]+)@"#,
            with: "$1$2:***@",
            options: .regularExpression
        )
        return value
    }
}
