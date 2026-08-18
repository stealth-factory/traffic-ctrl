import Darwin
import Foundation

struct HostnameSnapshot: Sendable {
    let names: [String: String]
    let revision: Int
}

final class HostnameResolver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "traffic-ctrl.hostname-resolver", qos: .utility)
    private let lock = NSLock()
    private var names: [String: String] = [:]
    private var requested: Set<String> = []
    private var revision = 0

    func request(_ addresses: [String]) {
        lock.lock()
        let unresolved = addresses.filter { requested.insert($0).inserted }
        lock.unlock()

        for address in unresolved {
            queue.async { [weak self] in
                guard let self, let name = Self.reverseDNS(address), name != address else { return }
                lock.lock()
                names[address] = name
                revision += 1
                lock.unlock()
            }
        }
    }

    func snapshot() -> HostnameSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return HostnameSnapshot(names: names, revision: revision)
    }

    private static func reverseDNS(_ address: String) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            var socketAddress = sockaddr_in()
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socketAddress.sin_family = sa_family_t(AF_INET)
            socketAddress.sin_addr = ipv4
            let status = withUnsafePointer(to: &socketAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo(
                        $0, socklen_t(MemoryLayout<sockaddr_in>.size),
                        &host, socklen_t(host.count), nil, 0, NI_NAMEREQD
                    )
                }
            }
            return status == 0 ? decoded(host) : nil
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, address, &ipv6) == 1 {
            var socketAddress = sockaddr_in6()
            socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            socketAddress.sin6_family = sa_family_t(AF_INET6)
            socketAddress.sin6_addr = ipv6
            let status = withUnsafePointer(to: &socketAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo(
                        $0, socklen_t(MemoryLayout<sockaddr_in6>.size),
                        &host, socklen_t(host.count), nil, 0, NI_NAMEREQD
                    )
                }
            }
            return status == 0 ? decoded(host) : nil
        }
        return nil
    }

    private static func decoded(_ host: [CChar]) -> String {
        String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
