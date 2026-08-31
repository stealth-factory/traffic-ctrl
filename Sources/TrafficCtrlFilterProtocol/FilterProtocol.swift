import Foundation

public enum TrafficCtrlFilterProtocol {
    public static let version = 1
    public static let appGroupIdentifier = "group.com.stealthfactory.trafficctrl"
    public static let rulesFilename = "filter-rules-v1.json"

    public static var socketPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Traffic Ctrl", isDirectory: true)
            .appendingPathComponent("filter.sock", isDirectory: false)
            .path
    }
}

public enum FilterAction: String, Codable, Sendable {
    case status
    case block
    case unblock
}

public enum FilterServiceState: String, Codable, Sendable {
    case ready
    case disabled
    case unavailable
    case error
}

/// A temporary process identity. The start time prevents a rule from being
/// applied to an unrelated process after macOS reuses a PID.
public struct FilterProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int
    public let name: String
    public let executablePath: String
    public let startTimeMicroseconds: UInt64

    public init(
        pid: Int,
        name: String,
        executablePath: String,
        startTimeMicroseconds: UInt64
    ) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.startTimeMicroseconds = startTimeMicroseconds
    }

    public func matchesRuntimeIdentity(_ other: FilterProcessIdentity) -> Bool {
        pid == other.pid
            && executablePath == other.executablePath
            && startTimeMicroseconds == other.startTimeMicroseconds
    }
}

public struct FilterRequest: Codable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let action: FilterAction
    public let process: FilterProcessIdentity?

    public init(action: FilterAction, process: FilterProcessIdentity? = nil) {
        protocolVersion = TrafficCtrlFilterProtocol.version
        requestID = UUID()
        self.action = action
        self.process = process
    }
}

public struct FilterResponse: Codable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let success: Bool
    public let state: FilterServiceState
    public let blockedProcesses: [FilterProcessIdentity]
    public let message: String?

    public init(
        requestID: UUID,
        success: Bool,
        state: FilterServiceState,
        blockedProcesses: [FilterProcessIdentity],
        message: String? = nil
    ) {
        protocolVersion = TrafficCtrlFilterProtocol.version
        self.requestID = requestID
        self.success = success
        self.state = state
        self.blockedProcesses = blockedProcesses
        self.message = message
    }
}

public struct FilterRule: Codable, Hashable, Sendable {
    public let process: FilterProcessIdentity
    public let createdAt: Date

    public init(process: FilterProcessIdentity, createdAt: Date = Date()) {
        self.process = process
        self.createdAt = createdAt
    }
}

public struct FilterRuleSnapshot: Codable, Sendable {
    public let protocolVersion: Int
    public let generation: UInt64
    public let validUntil: Date
    public let rules: [FilterRule]

    public init(generation: UInt64, validUntil: Date, rules: [FilterRule]) {
        protocolVersion = TrafficCtrlFilterProtocol.version
        self.generation = generation
        self.validUntil = validUntil
        self.rules = rules
    }
}

public enum FilterCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
