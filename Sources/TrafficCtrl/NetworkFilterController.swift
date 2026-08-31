import Darwin
import Foundation
import TrafficCtrlFilterProtocol

struct NetworkFilterSnapshot: Sendable {
    let revision: Int
    let state: FilterServiceState
    let blockedProcesses: Set<FilterProcessIdentity>
    let message: String?

    func isBlocked(_ id: ProcessID) -> Bool {
        blockedProcesses.contains { $0.pid == id.pid }
    }
}

final class AsyncNetworkFilterController: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "traffic-ctrl.network-filter", qos: .userInitiated)
    private var value = NetworkFilterSnapshot(
        revision: 0,
        state: .unavailable,
        blockedProcesses: [],
        message: "Network filter service is not installed"
    )
    private var requestInFlight = false
    private var lastRefresh = Date.distantPast

    func snapshot() -> NetworkFilterSnapshot {
        lock.withLock { value }
    }

    func refresh(now: Date, force: Bool = false) {
        lock.lock()
        guard requestInFlight == false,
              force || now.timeIntervalSince(lastRefresh) >= 2
        else {
            lock.unlock()
            return
        }
        requestInFlight = true
        lastRefresh = now
        lock.unlock()
        perform(FilterRequest(action: .status))
    }

    func setBlocked(_ blocked: Bool, process id: ProcessID) -> String? {
        guard let identity = Self.identity(for: id) else {
            return "Could not verify \(id.name) (PID \(id.pid)); no network rule was changed"
        }

        lock.lock()
        guard requestInFlight == false else {
            lock.unlock()
            return "Network filter is busy; try again"
        }
        requestInFlight = true
        lock.unlock()
        perform(FilterRequest(action: blocked ? .block : .unblock, process: identity))
        return nil
    }

    private func perform(_ request: FilterRequest) {
        queue.async { [weak self] in
            guard let self else { return }
            let next: NetworkFilterSnapshot
            do {
                let response = try FilterSocketClient.send(request)
                guard response.protocolVersion == TrafficCtrlFilterProtocol.version,
                      response.requestID == request.requestID
                else { throw FilterClientError.invalidResponse }
                next = NetworkFilterSnapshot(
                    revision: self.snapshot().revision + 1,
                    state: response.state,
                    blockedProcesses: Set(response.blockedProcesses),
                    message: response.message
                )
            } catch {
                next = NetworkFilterSnapshot(
                    revision: self.snapshot().revision + 1,
                    state: .unavailable,
                    blockedProcesses: [],
                    message: "Network block unavailable: \(error.localizedDescription)"
                )
            }
            self.lock.withLock {
                self.value = next
                self.requestInFlight = false
            }
        }
    }

    private static func identity(for id: ProcessID) -> FilterProcessIdentity? {
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(Int32(id.pid), PROC_PIDTBSDINFO, 0, &info, expected) == expected else {
            return nil
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = proc_pidpath(Int32(id.pid), &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        let pathBytes = pathBuffer.prefix(Int(pathLength)).prefix { $0 != 0 }
            .map { UInt8(bitPattern: $0) }
        let path = String(decoding: pathBytes, as: UTF8.self)
        let start = UInt64(info.pbi_start_tvsec) * 1_000_000
            + UInt64(info.pbi_start_tvusec)
        return FilterProcessIdentity(
            pid: id.pid,
            name: id.name,
            executablePath: path,
            startTimeMicroseconds: start
        )
    }
}

private enum FilterClientError: LocalizedError {
    case unavailable(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .invalidResponse: return "filter service returned an invalid response"
        }
    }
}

private enum FilterSocketClient {
    static func send(_ request: FilterRequest) throws -> FilterResponse {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw FilterClientError.unavailable(String(cString: strerror(errno)))
        }
        defer { Darwin.close(descriptor) }

        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = TrafficCtrlFilterProtocol.socketPath
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw FilterClientError.unavailable("filter socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            path.utf8CString.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED {
                throw FilterClientError.unavailable("filter service is not installed or running")
            }
            throw FilterClientError.unavailable(String(cString: strerror(errno)))
        }

        var payload = try FilterCoding.encoder().encode(request)
        payload.append(0x0A)
        try payload.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                guard count > 0 else {
                    throw FilterClientError.unavailable(String(cString: strerror(errno)))
                }
                sent += count
            }
        }

        var response = Data()
        var byte: UInt8 = 0
        while response.count < 1_048_576 {
            let count = Darwin.read(descriptor, &byte, 1)
            guard count > 0 else {
                throw FilterClientError.unavailable("filter service closed the connection")
            }
            if byte == 0x0A { break }
            response.append(byte)
        }
        guard response.isEmpty == false, response.count < 1_048_576 else {
            throw FilterClientError.invalidResponse
        }
        return try FilterCoding.decoder().decode(FilterResponse.self, from: response)
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
