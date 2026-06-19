import Foundation

public enum LogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error

    var priority: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warning: 2
        case .error: 3
        }
    }
}

public struct ServiceTestResult: Equatable, Sendable {
    public let ok: Bool
    public let title: String
    public let detail: String

    public init(ok: Bool, title: String, detail: String) {
        self.ok = ok
        self.title = title
        self.detail = detail
    }
}

public enum DetectionKind: String, Codable, Sendable {
    case motion
    case person
}

public struct DetectionEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: DetectionKind
    public let active: Bool
    public let timestamp: Date

    public init(kind: DetectionKind, active: Bool, timestamp: Date = Date()) {
        self.id = UUID()
        self.kind = kind
        self.active = active
        self.timestamp = timestamp
    }
}

public protocol EventLogger: Sendable {
    func log(_ level: LogLevel, _ subsystem: String, _ message: String)
}

public struct ConsoleLogger: EventLogger {
    private let minLevel: LogLevel

    public init() {
        self.minLevel = ConsoleLogger.defaultLevel()
    }

    public init(minLevel: LogLevel) {
        self.minLevel = minLevel
    }

    public func log(_ level: LogLevel, _ subsystem: String, _ message: String) {
        guard level.priority >= minLevel.priority else {
            return
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(timestamp) [\(level.rawValue.uppercased())] [\(subsystem)] \(message.redactingSecrets)\n".utf8))
    }

    private static func defaultLevel() -> LogLevel {
        let raw = ProcessInfo.processInfo.environment["HOMELENS_LOG_LEVEL"]?.lowercased()
        return LogLevel(rawValue: raw ?? "") ?? .info
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
