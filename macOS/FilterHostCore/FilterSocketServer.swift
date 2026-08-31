import Darwin
import Foundation
import TrafficCtrlFilterProtocol

public final class FilterSocketServer: @unchecked Sendable {
    private let repository: FilterRuleRepository
    private let queue = DispatchQueue(label: "traffic-ctrl.filter.socket")
    private let leaseQueue = DispatchQueue(label: "traffic-ctrl.filter.lease")
    private var descriptor: Int32 = -1
    private var leaseTimer: DispatchSourceTimer?

    public init(repository: FilterRuleRepository) {
        self.repository = repository
    }

    public func start() throws {
        let path = TrafficCtrlFilterProtocol.socketPath
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = Darwin.unlink(path)

        let socketDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(socketDescriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            path.utf8CString.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.chmod(path, 0o600) == 0, Darwin.listen(socketDescriptor, 8) == 0 else {
            let savedError = errno
            Darwin.close(socketDescriptor)
            _ = Darwin.unlink(path)
            throw POSIXError(.init(rawValue: savedError) ?? .EIO)
        }
        descriptor = socketDescriptor
        repository.renewLease()
        let timer = DispatchSource.makeTimerSource(queue: leaseQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak repository] in repository?.renewLease() }
        timer.resume()
        leaseTimer = timer
        queue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        leaseTimer?.cancel()
        leaseTimer = nil
        repository.removeAllRules()
        let active = descriptor
        descriptor = -1
        if active >= 0 { Darwin.close(active) }
        _ = Darwin.unlink(TrafficCtrlFilterProtocol.socketPath)
    }

    deinit { stop() }

    private func acceptLoop() {
        while descriptor >= 0 {
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            handle(client)
            Darwin.close(client)
        }
    }

    private func handle(_ client: Int32) {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == geteuid() else { return }

        guard let requestData = readLine(client),
              let request = try? FilterCoding.decoder().decode(FilterRequest.self, from: requestData)
        else { return }
        let response = repository.response(to: request)
        guard var data = try? FilterCoding.encoder().encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(client, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count <= 0 { return }
                written += count
            }
        }
    }

    private func readLine(_ client: Int32) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 1_048_576 {
            let count = Darwin.read(client, &byte, 1)
            guard count > 0 else { return nil }
            if byte == 0x0A { return data }
            data.append(byte)
        }
        return nil
    }
}
