import Foundation

enum LogLevel: String, Codable, CaseIterable {
    case debug
    case info
    case warning
    case error

    var title: String { rawValue.uppercased() }
}

struct LogEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let subsystem: String
    let message: String

    init(level: LogLevel, subsystem: String, message: String, timestamp: Date = Date()) {
        self.id = UUID()
        self.timestamp = timestamp
        self.level = level
        self.subsystem = subsystem
        self.message = message
    }
}

struct ServiceTestResult: Equatable {
    let ok: Bool
    let title: String
    let detail: String
}

enum DetectionKind: String, Codable {
    case motion
    case person
}

struct DetectionEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let kind: DetectionKind
    let active: Bool
    let timestamp: Date

    init(kind: DetectionKind, active: Bool, timestamp: Date = Date()) {
        self.id = UUID()
        self.kind = kind
        self.active = active
        self.timestamp = timestamp
    }
}
