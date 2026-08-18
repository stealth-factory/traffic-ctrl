import Foundation

struct ProcessID: Hashable, Sendable {
    let name: String
    let pid: Int
}

struct NetworkCounters: Equatable, Sendable {
    let received: UInt64
    let sent: UInt64

    var total: UInt64 { received + sent }
}

struct TrafficDelta: Sendable {
    let processes: [ProcessID: NetworkCounters]
    let endpoints: [ProcessID: [String: NetworkCounters]]
}

struct RateSample: Sendable {
    let received: Double
    let sent: Double
}

struct ProcessTraffic: Sendable {
    let id: ProcessID
    var received: UInt64 = 0
    var sent: UInt64 = 0
    var receiveRate: Double = 0
    var sendRate: Double = 0

    var total: UInt64 { received + sent }
    var totalRate: Double { receiveRate + sendRate }
}

struct EndpointTraffic: Sendable {
    let address: String
    var received: UInt64 = 0
    var sent: UInt64 = 0
    var receiveRate: Double = 0
    var sendRate: Double = 0

    var total: UInt64 { received + sent }
    var totalRate: Double { receiveRate + sendRate }
}

enum DetailFocus {
    case endpoints
    case connections
    case files
}
