import Darwin
import Foundation

enum NettopError: LocalizedError {
    case launchFailed(String)
    case exited(Int32, String)
    case endedUnexpectedly

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "Could not start nettop: \(message)"
        case .exited(let status, let message):
            return "nettop exited with status \(status): \(message)"
        case .endedUnexpectedly:
            return "nettop stopped producing data unexpectedly"
        }
    }
}

/// Owns one continuous nettop process. Delta mode is essential: its first CSV
/// sample contains pre-launch counters, while every later sample contains only
/// traffic observed during that sampling interval.
final class Nettop {
    private let process = Process()
    private let outputHandle: FileHandle
    private let errors = Pipe()
    private let publicOnly: Bool
    private var buffer = Data()
    private var currentSample: [String]?
    private var discardedInitialSample = false

    init(interval: TimeInterval, publicOnly: Bool) throws {
        self.publicOnly = publicOnly
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw NettopError.launchFailed(String(cString: strerror(errno)))
        }
        outputHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let terminalOutput = FileHandle(fileDescriptor: slave, closeOnDealloc: true)

        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = [
            "-L", "0", "-d", "-x", "-n", "-s", String(interval),
            "-t", "external", "-J", "bytes_in,bytes_out"
        ]
        // nettop fully buffers CSV when stdout is a pipe. A private PTY makes
        // it flush each interval without affecting the user's terminal.
        // Its input must not inherit Traffic Ctrl's terminal or both processes
        // will race with Traffic Ctrl for interactive control keys.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = terminalOutput
        process.standardError = errors

        do {
            try process.run()
            terminalOutput.closeFile()
        } catch {
            terminalOutput.closeFile()
            throw NettopError.launchFailed(error.localizedDescription)
        }
    }

    deinit {
        stop()
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    func nextDelta() throws -> TrafficDelta {
        while true {
            let lines = try nextSampleLines()
            if discardedInitialSample == false {
                discardedInitialSample = true
                continue
            }
            return Self.parseSample(lines, publicOnly: publicOnly)
        }
    }

    private func nextSampleLines() throws -> [String] {
        while true {
            let line = try nextLine()
            if line.hasPrefix(",bytes_in,bytes_out") {
                let completed = currentSample
                currentSample = []
                if let completed { return completed }
            } else if currentSample != nil {
                currentSample?.append(line)
            }
        }
    }

    private func nextLine() throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newline]
                buffer.removeSubrange(...newline)
                return String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .newlines)
            }

            // availableData returns as soon as nettop flushes any bytes. Using
            // readData(ofLength:) here can wait for a full buffer and deliver
            // several one-second samples in a burst.
            let data = outputHandle.availableData
            guard data.isEmpty == false else {
                process.waitUntilExit()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus != 0 {
                    throw NettopError.exited(process.terminationStatus, message)
                }
                throw NettopError.endedUnexpectedly
            }
            buffer.append(data)
        }
    }

    static func parseSample(
        _ lines: [String],
        publicOnly: Bool
    ) -> TrafficDelta {
        var result: [ProcessID: NetworkCounters] = [:]
        var endpoints: [ProcessID: [String: NetworkCounters]] = [:]
        var processID: ProcessID?

        for line in lines {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let descriptor = String(fields[0])

            if isConnection(descriptor) {
                guard let processID,
                      let received = UInt64(fields[1]),
                      let sent = UInt64(fields[2]),
                      let remote = remoteAddress(from: descriptor),
                      publicOnly == false || isPublicAddress(remote)
                else { continue }
                let counters = NetworkCounters(received: received, sent: sent)
                add(counters, for: remote, to: processID, in: &endpoints)
                if publicOnly {
                    add(counters, to: processID, in: &result)
                }
            } else {
                processID = parseProcessID(descriptor)
                guard publicOnly == false,
                      let processID,
                      let received = UInt64(fields[1]),
                      let sent = UInt64(fields[2])
                else { continue }
                result[processID] = NetworkCounters(received: received, sent: sent)
            }
        }

        return TrafficDelta(processes: result, endpoints: endpoints)
    }

    private static func add(
        _ counters: NetworkCounters,
        to id: ProcessID,
        in result: inout [ProcessID: NetworkCounters]
    ) {
        let existing = result[id] ?? NetworkCounters(received: 0, sent: 0)
        result[id] = NetworkCounters(
            received: existing.received + counters.received,
            sent: existing.sent + counters.sent
        )
    }

    private static func add(
        _ counters: NetworkCounters,
        for address: String,
        to id: ProcessID,
        in result: inout [ProcessID: [String: NetworkCounters]]
    ) {
        let existing = result[id]?[address] ?? NetworkCounters(received: 0, sent: 0)
        result[id, default: [:]][address] = NetworkCounters(
            received: existing.received + counters.received,
            sent: existing.sent + counters.sent
        )
    }

    private static func parseProcessID(_ value: String) -> ProcessID? {
        guard let separator = value.lastIndex(of: "."),
              let pid = Int(value[value.index(after: separator)...])
        else { return nil }
        let name = String(value[..<separator])
        return name.isEmpty ? nil : ProcessID(name: name, pid: pid)
    }

    private static func isConnection(_ value: String) -> Bool {
        value.hasPrefix("tcp4 ") || value.hasPrefix("tcp6 ")
            || value.hasPrefix("udp4 ") || value.hasPrefix("udp6 ")
    }

    static func remoteAddress(from descriptor: String) -> String? {
        guard let arrow = descriptor.range(of: "<->") else { return nil }
        var endpoint = String(descriptor[arrow.upperBound...])

        if descriptor.hasPrefix("tcp4 ") || descriptor.hasPrefix("udp4 ") {
            guard let port = endpoint.lastIndex(of: ":") else { return nil }
            endpoint = String(endpoint[..<port])
        } else {
            guard let port = endpoint.lastIndex(of: ".") else { return nil }
            endpoint = String(endpoint[..<port])
        }

        if let interface = endpoint.lastIndex(of: "%") {
            endpoint = String(endpoint[..<interface])
        }
        guard endpoint.isEmpty == false, endpoint != "*" else { return nil }
        return endpoint
    }

    static func isPublicAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            let address = UInt32(bigEndian: ipv4.s_addr)
            func matches(_ network: UInt32, _ mask: UInt32) -> Bool {
                address & mask == network
            }

            return !matches(0x00000000, 0xFF000000)   // 0.0.0.0/8
                && !matches(0x0A000000, 0xFF000000)  // 10.0.0.0/8
                && !matches(0x64400000, 0xFFC00000)  // 100.64.0.0/10
                && !matches(0x7F000000, 0xFF000000)  // 127.0.0.0/8
                && !matches(0xA9FE0000, 0xFFFF0000)  // 169.254.0.0/16
                && !matches(0xAC100000, 0xFFF00000)  // 172.16.0.0/12
                && !matches(0xC0000000, 0xFFFFFF00)  // 192.0.0.0/24
                && !matches(0xC0000200, 0xFFFFFF00)  // documentation ranges
                && !matches(0xC0A80000, 0xFFFF0000)  // 192.168.0.0/16
                && !matches(0xC6120000, 0xFFFE0000)  // 198.18.0.0/15
                && !matches(0xC6336400, 0xFFFFFF00)
                && !matches(0xCB007100, 0xFFFFFF00)
                && !matches(0xE0000000, 0xF0000000)  // multicast
                && !matches(0xF0000000, 0xF0000000)  // reserved/broadcast
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, value, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            // Globally routed unicast space. This deliberately excludes ULA,
            // link-local, multicast, loopback and unspecified addresses.
            let globalUnicast = bytes[0] & 0xE0 == 0x20
            let nat64 = bytes[0...11].elementsEqual([
                0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0
            ])
            return globalUnicast || nat64
        }

        return false
    }
}
