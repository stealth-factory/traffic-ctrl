import Darwin
import Foundation
@preconcurrency import NetworkExtension
import TrafficCtrlFilterProtocol

/// The macOS enforcement engine. The containing host app writes validated
/// rules to the shared app-group container; this provider reloads them without
/// receiving process traffic or payload data outside its restricted sandbox.
final class FilterDataProvider: NEFilterDataProvider, @unchecked Sendable {
    private struct TrackedFlow {
        let flow: NEFilterSocketFlow
        let process: FilterProcessIdentity
        var blocked: Bool
    }

    private let stateQueue = DispatchQueue(label: "traffic-ctrl.filter.state")
    private let ruleStore = FilterRuleStore()
    private var flows: [UUID: TrackedFlow] = [:]
    private var ruleTimer: DispatchSourceTimer?

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        ruleStore.reload(force: true)
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.rulesMayHaveChanged() }
        timer.resume()
        ruleTimer = timer
        completionHandler(nil)
    }

    override func stopFilter(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        ruleTimer?.cancel()
        ruleTimer = nil
        stateQueue.sync { flows.removeAll() }
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socketFlow = flow as? NEFilterSocketFlow,
              PublicEndpoint.isPublic(socketFlow),
              let process = ProcessIdentity.from(flow: flow)
        else {
            return .allow()
        }

        ruleStore.reload(force: false)
        let blocked = ruleStore.blocks(process)
        let identifier = flow.identifier
        stateQueue.async { [weak self] in
            self?.flows[identifier] = TrackedFlow(
                flow: socketFlow,
                process: process,
                blocked: blocked
            )
        }

        let verdict: NEFilterNewFlowVerdict = blocked ? .drop() : .allow()
        verdict.shouldReport = true
        return verdict
    }

    override func handle(_ report: NEFilterReport) {
        guard report.event == .flowClosed, let identifier = report.flow?.identifier else { return }
        stateQueue.async { [weak self] in self?.flows.removeValue(forKey: identifier) }
    }

    private func rulesMayHaveChanged() {
        guard ruleStore.reload(force: false) else { return }
        for (identifier, var tracked) in flows {
            let shouldBlock = ruleStore.blocks(tracked.process)
            if shouldBlock && tracked.blocked == false {
                update(tracked.flow, using: .drop(), for: .any)
                tracked.blocked = true
                flows[identifier] = tracked
            } else if shouldBlock == false && tracked.blocked {
                // A dropped socket cannot reliably be resurrected. Removing
                // the rule allows the application's next reconnect attempt.
                flows.removeValue(forKey: identifier)
            }
        }
    }
}

private final class FilterRuleStore {
    private let lock = NSLock()
    private var rules: Set<FilterRule> = []
    private var generation: UInt64 = 0
    private var modificationDate: Date?
    private var validUntil = Date.distantPast

    @discardableResult
    func reload(force: Bool) -> Bool {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: TrafficCtrlFilterProtocol.appGroupIdentifier
        ) else { return false }
        let url = container.appendingPathComponent(TrafficCtrlFilterProtocol.rulesFilename)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let latestDate = attributes?[.modificationDate] as? Date
        if force == false, latestDate == modificationDate {
            lock.lock()
            let expired = validUntil <= Date() && rules.isEmpty == false
            if expired { rules.removeAll() }
            lock.unlock()
            return expired
        }

        let snapshot: FilterRuleSnapshot
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            snapshot = try FilterCoding.decoder().decode(FilterRuleSnapshot.self, from: data)
            guard snapshot.protocolVersion == TrafficCtrlFilterProtocol.version else { return false }
        } catch {
            snapshot = FilterRuleSnapshot(
                generation: 0,
                validUntil: .distantPast,
                rules: []
            )
        }

        lock.lock()
        let activeRules = snapshot.validUntil > Date() ? Set(snapshot.rules) : []
        let changed = snapshot.generation != generation
            || snapshot.validUntil != validUntil
            || activeRules != rules
        generation = snapshot.generation
        validUntil = snapshot.validUntil
        rules = activeRules
        modificationDate = latestDate
        lock.unlock()
        return changed
    }

    func blocks(_ process: FilterProcessIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard validUntil > Date() else { return false }
        return rules.contains { $0.process.matchesRuntimeIdentity(process) }
    }
}

private enum ProcessIdentity {
    static func from(flow: NEFilterFlow) -> FilterProcessIdentity? {
        guard let data = flow.sourceProcessAuditToken ?? flow.sourceAppAuditToken,
              data.count == MemoryLayout<audit_token_t>.size
        else { return nil }
        var token = audit_token_t()
        _ = withUnsafeMutableBytes(of: &token) { data.copyBytes(to: $0) }
        return from(pid: Int(audit_token_to_pid(token)))
    }

    static func from(pid: Int) -> FilterProcessIdentity? {
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
        let nameBytes = withUnsafeBytes(of: &info.pbi_name) { raw in
            raw.prefix { $0 != 0 }
        }
        return FilterProcessIdentity(
            pid: pid,
            name: String(decoding: nameBytes, as: UTF8.self),
            executablePath: String(decoding: pathBytes, as: UTF8.self),
            startTimeMicroseconds: UInt64(info.pbi_start_tvsec) * 1_000_000
                + UInt64(info.pbi_start_tvusec)
        )
    }
}

private enum PublicEndpoint {
    static func isPublic(_ flow: NEFilterSocketFlow) -> Bool {
        // remoteHostname contains an address for ordinary BSD sockets and the
        // requested host when Network.framework has one. It can briefly be
        // nil for a new socket; a selected blocked process must not leak
        // traffic during that gap, so an unknown endpoint is treated as public.
        guard let hostname = flow.remoteHostname else { return true }
        return isPublic(host: hostname)
    }

    static func isPublic(host: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let address = UInt32(bigEndian: ipv4.s_addr)
            func matches(_ network: UInt32, _ mask: UInt32) -> Bool {
                address & mask == network
            }
            return !matches(0x00000000, 0xFF000000)
                && !matches(0x0A000000, 0xFF000000)
                && !matches(0x64400000, 0xFFC00000)
                && !matches(0x7F000000, 0xFF000000)
                && !matches(0xA9FE0000, 0xFFFF0000)
                && !matches(0xAC100000, 0xFFF00000)
                && !matches(0xC0000000, 0xFFFFFF00)
                && !matches(0xC0000200, 0xFFFFFF00)
                && !matches(0xC0A80000, 0xFFFF0000)
                && !matches(0xC6120000, 0xFFFE0000)
                && !matches(0xC6336400, 0xFFFFFF00)
                && !matches(0xCB007100, 0xFFFFFF00)
                && !matches(0xE0000000, 0xF0000000)
                && !matches(0xF0000000, 0xF0000000)
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            let globalUnicast = bytes[0] & 0xE0 == 0x20
            let nat64 = bytes[0...11].elementsEqual([
                0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0
            ])
            return globalUnicast || nat64
        }

        let lowercased = host.lowercased()
        return lowercased != "localhost" && lowercased.hasSuffix(".local") == false
    }
}
