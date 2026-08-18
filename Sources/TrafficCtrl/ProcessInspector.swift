import Foundation

struct OpenFile: Sendable {
    let path: String
    let displayPath: String
    let size: UInt64
}

struct ProcessDetails: Sendable {
    let connections: [String]
    let files: [OpenFile]
    let note: String?
}

final class AsyncProcessInspector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "traffic-ctrl.process-inspector")
    private let lock = NSLock()
    private let refreshInterval: TimeInterval
    private var snapshots: [ProcessID: (details: ProcessDetails, revision: Int)] = [:]
    private var lastRequested: [ProcessID: Date] = [:]
    private var inFlight: Set<ProcessID> = []
    private var revision = 0

    init(refreshInterval: TimeInterval = 2) {
        self.refreshInterval = refreshInterval
    }

    func request(_ id: ProcessID, now: Date) {
        lock.lock()
        let due = lastRequested[id].map { now.timeIntervalSince($0) >= refreshInterval } ?? true
        guard due, inFlight.contains(id) == false else {
            lock.unlock()
            return
        }
        lastRequested[id] = now
        inFlight.insert(id)
        lock.unlock()

        queue.async { [weak self] in
            let details = ProcessInspector.inspect(pid: id.pid)
            guard let self else { return }
            self.lock.lock()
            self.revision += 1
            self.snapshots[id] = (details, self.revision)
            self.inFlight.remove(id)
            self.lock.unlock()
        }
    }

    func snapshot(for id: ProcessID) -> (details: ProcessDetails, revision: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[id]
    }
}

enum ProcessInspector {
    static func inspect(pid: Int) -> ProcessDetails {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-p", String(pid)]
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return ProcessDetails(connections: [], files: [], note: error.localizedDescription)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return ProcessDetails(
                connections: [],
                files: [],
                note: "Open-file details are unavailable for this process."
            )
        }

        var connections: [String] = []
        var filesByPath: [String: OpenFile] = [:]
        let text = String(decoding: data, as: UTF8.self)

        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let fields = line.split(
                maxSplits: 8,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count >= 9 else { continue }
            let type = String(fields[4])
            let name = String(fields[8])

            if type == "IPv4" || type == "IPv6" {
                let connection = String(fields[7]) + " " + name
                if connection.hasPrefix("TCP ") || connection.hasPrefix("UDP ") {
                    connections.append(connection)
                }
                continue
            }

            guard type == "REG",
                  name.hasPrefix("/Users/") || name.hasPrefix("/private/var/"),
                  let size = UInt64(fields[6])
            else { continue }
            filesByPath[name] = OpenFile(path: name, displayPath: compactPath(name), size: size)
        }

        return ProcessDetails(
            connections: Array(Set(connections)).sorted(),
            files: filesByPath.values.sorted { $0.size > $1.size },
            note: nil
        )
    }

    private static func compactPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let abbreviated = path == home || path.hasPrefix(home + "/")
            ? "~" + path.dropFirst(home.count)
            : path
        if abbreviated.contains("/CloudKit/com.apple.bird/"),
           let mmcs = abbreviated.range(of: "/MMCS/") {
            return "~/Library/Caches/CloudKit/…/MMCS/" + abbreviated[mmcs.upperBound...]
        }
        return abbreviated
    }

    static func copyToClipboard(_ value: String) -> Bool {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        process.standardInput = input
        do {
            try process.run()
            input.fileHandleForWriting.write(Data(value.utf8))
            input.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
