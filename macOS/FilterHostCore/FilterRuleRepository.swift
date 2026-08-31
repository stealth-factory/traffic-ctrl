import Darwin
import Foundation
import TrafficCtrlFilterProtocol

public enum FilterHostError: LocalizedError {
    case appGroupUnavailable
    case identityChanged
    case invalidRequest

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "shared filter container is unavailable; check signing and App Group entitlements"
        case .identityChanged:
            return "the selected process exited or its PID was reused; no rule was changed"
        case .invalidRequest:
            return "the filter request is incomplete or incompatible"
        }
    }
}

public final class FilterRuleRepository: @unchecked Sendable {
    private let lock = NSLock()
    private let rulesURL: URL
    private var generation: UInt64 = 0
    private var rules: Set<FilterRule> = []

    public init() throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: TrafficCtrlFilterProtocol.appGroupIdentifier
        ) else { throw FilterHostError.appGroupUnavailable }
        rulesURL = container.appendingPathComponent(TrafficCtrlFilterProtocol.rulesFilename)
        load()
    }

    public func response(to request: FilterRequest) -> FilterResponse {
        guard request.protocolVersion == TrafficCtrlFilterProtocol.version else {
            return failure(request, FilterHostError.invalidRequest)
        }
        do {
            switch request.action {
            case .status:
                pruneExitedProcesses()
            case .block:
                guard let requested = request.process,
                      let current = ProcessIdentity.current(pid: requested.pid),
                      requested.matchesRuntimeIdentity(current)
                else { throw FilterHostError.identityChanged }
                try lock.withLock {
                    let previousRules = rules
                    let previousGeneration = generation
                    rules = Set(rules.filter { $0.process.pid != requested.pid })
                    rules.insert(FilterRule(process: requested))
                    generation &+= 1
                    do {
                        try persistLocked()
                    } catch {
                        rules = previousRules
                        generation = previousGeneration
                        throw error
                    }
                }
            case .unblock:
                guard let requested = request.process else { throw FilterHostError.invalidRequest }
                try lock.withLock {
                    let previousCount = rules.count
                    let updatedRules = Set(rules.filter { rule in
                        rule.process.matchesRuntimeIdentity(requested) == false
                    })
                    if updatedRules.count != previousCount {
                        let previousRules = rules
                        let previousGeneration = generation
                        rules = updatedRules
                        generation &+= 1
                        do {
                            try persistLocked()
                        } catch {
                            rules = previousRules
                            generation = previousGeneration
                            throw error
                        }
                    }
                }
            }
            let blocked = lock.withLock { rules.map(\.process) }
            let message: String?
            switch request.action {
            case .status: message = nil
            case .block: message = request.process.map {
                "Network blocked for \($0.name) (PID \($0.pid)); the process is still running"
            }
            case .unblock: message = request.process.map {
                "Network unblocked for \($0.name) (PID \($0.pid)); new connections are allowed"
            }
            }
            return FilterResponse(
                requestID: request.requestID,
                success: true,
                state: .ready,
                blockedProcesses: blocked,
                message: message
            )
        } catch {
            return failure(request, error)
        }
    }

    public func removeAllRules() {
        lock.withLock {
            guard rules.isEmpty == false else { return }
            rules.removeAll()
            generation &+= 1
            try? persistLocked()
        }
    }

    public func renewLease() {
        lock.withLock { try? persistLocked() }
    }

    private func failure(_ request: FilterRequest, _ error: Error) -> FilterResponse {
        FilterResponse(
            requestID: request.requestID,
            success: false,
            state: .error,
            blockedProcesses: lock.withLock { rules.map(\.process) },
            message: error.localizedDescription
        )
    }

    private func load() {
        guard let data = try? Data(contentsOf: rulesURL),
              let snapshot = try? FilterCoding.decoder().decode(FilterRuleSnapshot.self, from: data),
              snapshot.protocolVersion == TrafficCtrlFilterProtocol.version
        else { return }
        generation = snapshot.generation
        rules = Set(snapshot.rules)
        pruneExitedProcesses()
    }

    private func pruneExitedProcesses() {
        lock.withLock {
            let active = rules.filter { rule in
                guard let current = ProcessIdentity.current(pid: rule.process.pid) else { return false }
                return rule.process.matchesRuntimeIdentity(current)
            }
            guard active.count != rules.count else { return }
            rules = Set(active)
            generation &+= 1
            try? persistLocked()
        }
    }

    private func persistLocked() throws {
        let snapshot = FilterRuleSnapshot(
            generation: generation,
            validUntil: Date().addingTimeInterval(3),
            rules: Array(rules)
        )
        let data = try FilterCoding.encoder().encode(snapshot)
        try data.write(to: rulesURL, options: [.atomic, .completeFileProtection])
    }
}

private enum ProcessIdentity {
    static func current(pid: Int) -> FilterProcessIdentity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, expected) == expected else {
            return nil
        }
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(Int32(pid), &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else { return nil }
        let pathBytes = pathBuffer.prefix(Int(length)).prefix { $0 != 0 }
            .map { UInt8(bitPattern: $0) }
        let nameBytes = withUnsafeBytes(of: &info.pbi_name) { $0.prefix { $0 != 0 } }
        return FilterProcessIdentity(
            pid: pid,
            name: String(decoding: nameBytes, as: UTF8.self),
            executablePath: String(decoding: pathBytes, as: UTF8.self),
            startTimeMicroseconds: UInt64(info.pbi_start_tvsec) * 1_000_000
                + UInt64(info.pbi_start_tvusec)
        )
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
