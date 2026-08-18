import Darwin
import Foundation

private nonisolated(unsafe) var terminationRequested: sig_atomic_t = 0

private final class TerminalInput {
    private var original = termios()
    private var configured = false

    init() {
        guard isatty(STDIN_FILENO) == 1, tcgetattr(STDIN_FILENO, &original) == 0 else {
            return
        }
        var immediate = original
        immediate.c_lflag &= ~tcflag_t(ICANON | ECHO)
        configured = tcsetattr(STDIN_FILENO, TCSANOW, &immediate) == 0
    }

    func restore() {
        guard configured else { return }
        var settings = original
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &settings)
        configured = false
    }

    deinit {
        restore()
    }
}

struct Options {
    var interval: TimeInterval = 1
    var limit: Int?
    var publicOnly = true
    var plain = false
    var sort: SortMode = .total

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "-i", "--interval":
                index += 1
                guard index < arguments.count,
                      let value = Double(arguments[index]), value >= 0.2 else {
                    throw CLIError.usage("--interval requires a number of at least 0.2 seconds")
                }
                options.interval = value
            case "-n", "--limit":
                index += 1
                guard index < arguments.count,
                      let value = Int(arguments[index]), value > 0 else {
                    throw CLIError.usage("--limit requires a positive integer")
                }
                options.limit = value
            case "--external":
                // Kept as a backwards-compatible alias for the new default.
                options.publicOnly = true
            case "--all-external":
                options.publicOnly = false
            case "--plain":
                options.plain = true
            case "--sort":
                index += 1
                guard index < arguments.count,
                      let value = SortMode(rawValue: arguments[index]) else {
                    throw CLIError.usage("--sort requires either 'total' or 'live'")
                }
                options.sort = value
            case "-h", "--help":
                print(help)
                exit(0)
            default:
                throw CLIError.usage("Unknown option: \(arguments[index])")
            }
            index += 1
        }
        return options
    }

    static let help = """
    Usage: traffic-ctrl [options]

    Rank macOS processes by network traffic measured since Traffic Ctrl started.

      -i, --interval SECONDS  Sampling interval (default: 1, minimum: 0.2)
      -n, --limit COUNT       Maximum processes to show (default: auto-fit terminal)
          --external          Public Internet only (default; compatibility alias)
          --all-external      Include LAN, multicast and other non-loopback traffic
          --sort MODE         Initial sort: total or live (default: total)
          --plain             Do not clear the terminal between updates
      -h, --help              Show this help

    Columns:
      TOTAL  Download + upload since this invocation started
      RATE   Current combined transfer rate
      DOWN   Current receive rate
      UP     Current send rate

    Use Up/Down or j/k to select a process and Return or Right Arrow to inspect it. In the
    detail view, Tab switches between endpoints, connections and open files, and p/u
    pauses or resumes the selected process. Press Left Arrow or Esc to return, s to change sorting,
    r to reset statistics, or q to quit.
    """
}

enum CLIError: LocalizedError {
    case usage(String)
    case runtime(String)
    var errorDescription: String? {
        switch self {
        case .usage(let message), .runtime(let message): return message
        }
    }
}

private enum InputAction {
    case up
    case down
    case details
    case back
    case toggleSort
    case toggleDetailFocus
    case focusEndpoints
    case focusFiles
    case copy
    case pause
    case unpause
    case reset
    case quit
}

private func parseInput(_ bytes: inout [UInt8], flushStandaloneEscape: Bool) -> [InputAction] {
    var actions: [InputAction] = []
    while bytes.isEmpty == false {
        let byte = bytes[0]
        if byte == 0x1B {
            if bytes.count >= 3, bytes[1] == 0x5B || bytes[1] == 0x4F {
                switch bytes[2] {
                case 0x41: actions.append(.up)
                case 0x42: actions.append(.down)
                case 0x43: actions.append(.details)
                case 0x44: actions.append(.back)
                default: break
                }
                bytes.removeFirst(3)
                continue
            }
            if bytes.count < 3, flushStandaloneEscape == false {
                break
            }
            actions.append(.back)
            bytes.removeFirst()
        } else {
            switch Character(UnicodeScalar(byte)) {
            case "k", "K": actions.append(.up)
            case "j", "J": actions.append(.down)
            case "\r", "\n": actions.append(.details)
            case "\t": actions.append(.toggleDetailFocus)
            case "\u{7F}": actions.append(.back)
            case "s", "S", "t", "T": actions.append(.toggleSort)
            case "e", "E": actions.append(.focusEndpoints)
            case "f", "F": actions.append(.focusFiles)
            case "c", "C": actions.append(.copy)
            case "p", "P": actions.append(.pause)
            case "u", "U": actions.append(.unpause)
            case "r", "R": actions.append(.reset)
            case "q", "Q": actions.append(.quit)
            default: break
            }
            bytes.removeFirst()
        }
    }
    return actions
}

private func sortedEndpoints(for id: ProcessID?, in monitor: TrafficMonitor) -> [EndpointTraffic] {
    guard let id, let values = monitor.endpointTraffic[id]?.values else { return [] }
    return values.sorted {
        $0.total == $1.total ? $0.totalRate > $1.totalRate : $0.total > $1.total
    }
}

do {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    let collector = try TrafficCollector(interval: options.interval, publicOnly: options.publicOnly)
    let processInspector = AsyncProcessInspector()
    let hostnameResolver = HostnameResolver()
    let display = Display(
        limit: options.limit,
        plain: options.plain || isatty(STDOUT_FILENO) == 0,
        scope: options.publicOnly ? "public internet" : "all external"
    )
    var monitor = TrafficMonitor()
    var statisticsStarted = Date()
    var sort = options.sort
    var shouldQuit = false
    var selectedID: ProcessID?
    var detailID: ProcessID?
    var selectedFilePath: String?
    var selectedEndpointAddress: String?
    var selectedConnection: String?
    var detailFocus = DetailFocus.endpoints
    var detailFiles: [OpenFile] = []
    var detailNotice: String?
    var pendingPause: (id: ProcessID, expires: Date)?
    var pausedProcesses: [ProcessID: Date] = [:]
    var pendingInput: [UInt8] = []
    var details = ProcessDetails(
        connections: [], files: [], note: "Loading process details…"
    )
    var detailsRevision = -1
    var hostnameRevision = -1
    var lastPauseSecondsRemaining: Int?
    var needsRender = true
    var inputEnabled = true
    let terminalInput = TerminalInput()

    collector.start()
    signal(SIGINT) { _ in terminationRequested = 1 }
    signal(SIGTERM) { _ in terminationRequested = 1 }
    signal(SIGHUP) { _ in terminationRequested = 1 }
    signal(SIGQUIT) { _ in terminationRequested = 1 }
    signal(SIGTSTP) { _ in terminationRequested = 1 }
    defer {
        for id in pausedProcesses.keys {
            _ = ProcessController.resume(id)
        }
        terminalInput.restore()
        collector.stop()
        display.flush()
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
        signal(SIGHUP, SIG_DFL)
        signal(SIGQUIT, SIG_DFL)
        signal(SIGTSTP, SIG_DFL)
    }

    while terminationRequested == 0 && shouldQuit == false {
        var buffer = [UInt8](repeating: 0, count: 64)
        var count = 0
        if inputEnabled {
            var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&input, 1, 20)
            if pollResult > 0, (input.revents & Int16(POLLIN)) != 0 {
                count = read(STDIN_FILENO, &buffer, buffer.count)
            }
            if pollResult > 0,
               (input.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0,
               count <= 0 {
                inputEnabled = false
            }
        } else {
            usleep(20_000)
        }

        let now = Date()
        let collected = collector.drain()
        if let failure = collected.failure {
            throw CLIError.runtime("Traffic collector stopped: \(failure)")
        }
        if collected.deltas.isEmpty == false {
            for delta in collected.deltas {
                monitor.ingest(delta, elapsed: options.interval)
            }
            needsRender = true
        }

        let automaticallyResumed = pausedProcesses.compactMap { id, deadline in
            now >= deadline ? id : nil
        }
        for id in automaticallyResumed {
            let result = ProcessController.resume(id)
            pausedProcesses.removeValue(forKey: id)
            if detailID == id || (detailID == nil && selectedID == id) {
                detailNotice = result ?? "Automatically unpaused after 30 seconds"
            }
            needsRender = true
        }
        if let pauseConfirmation = pendingPause, now >= pauseConfirmation.expires {
            pendingPause = nil
            if detailID == pauseConfirmation.id
                || (detailID == nil && selectedID == pauseConfirmation.id) {
                detailNotice = "Pause confirmation expired"
            }
            needsRender = true
        }
        var ranked = display.sorted(Array(monitor.traffic.values), by: sort)
        var rankedEndpoints = sortedEndpoints(for: detailID, in: monitor)
        if detailID != nil {
            if let currentEndpointAddress = selectedEndpointAddress,
               rankedEndpoints.contains(where: { $0.address == currentEndpointAddress }) == false {
                selectedEndpointAddress = rankedEndpoints.first?.address
                needsRender = true
            } else if selectedEndpointAddress == nil, let first = rankedEndpoints.first {
                selectedEndpointAddress = first.address
                needsRender = true
            }
        }
        if let currentSelection = selectedID {
            if ranked.contains(where: { $0.id == currentSelection }) == false {
                selectedID = ranked.first?.id
                needsRender = true
            }
        } else if let first = ranked.first {
            selectedID = first.id
            needsRender = true
        }

        let hadStandaloneEscape = pendingInput == [0x1B]
        if count > 0 { pendingInput.append(contentsOf: buffer.prefix(count)) }
        let actions = parseInput(
            &pendingInput,
            flushStandaloneEscape: hadStandaloneEscape && pendingInput == [0x1B]
        )
        if actions.isEmpty == false {
            needsRender = true
            for action in actions {
                switch action {
                case .up where detailID == nil, .down where detailID == nil:
                    guard ranked.isEmpty == false else { continue }
                    let current = selectedID.flatMap { id in ranked.firstIndex { $0.id == id } } ?? 0
                    let next = action == .up
                        ? max(0, current - 1)
                        : min(ranked.count - 1, current + 1)
                    selectedID = ranked[next].id
                    detailNotice = nil
                case .up where detailID != nil:
                    switch detailFocus {
                    case .endpoints:
                        let current = selectedEndpointAddress.flatMap { address in
                            rankedEndpoints.firstIndex { $0.address == address }
                        } ?? 0
                        selectedEndpointAddress = rankedEndpoints.isEmpty
                            ? nil : rankedEndpoints[max(0, current - 1)].address
                    case .connections:
                        let current = selectedConnection.flatMap { connection in
                            details.connections.firstIndex(of: connection)
                        } ?? 0
                        selectedConnection = details.connections.isEmpty
                            ? nil : details.connections[max(0, current - 1)]
                    case .files:
                        let current = selectedFilePath.flatMap { path in
                            detailFiles.firstIndex { $0.path == path }
                        } ?? 0
                        selectedFilePath = detailFiles.isEmpty
                            ? nil : detailFiles[max(0, current - 1)].path
                    }
                    detailNotice = nil
                case .down where detailID != nil:
                    switch detailFocus {
                    case .endpoints:
                        let current = selectedEndpointAddress.flatMap { address in
                            rankedEndpoints.firstIndex { $0.address == address }
                        } ?? 0
                        selectedEndpointAddress = rankedEndpoints.isEmpty
                            ? nil : rankedEndpoints[min(rankedEndpoints.count - 1, current + 1)].address
                    case .connections:
                        let current = selectedConnection.flatMap { connection in
                            details.connections.firstIndex(of: connection)
                        } ?? 0
                        selectedConnection = details.connections.isEmpty
                            ? nil : details.connections[min(details.connections.count - 1, current + 1)]
                    case .files:
                        let current = selectedFilePath.flatMap { path in
                            detailFiles.firstIndex { $0.path == path }
                        } ?? 0
                        selectedFilePath = detailFiles.isEmpty
                            ? nil : detailFiles[min(detailFiles.count - 1, current + 1)].path
                    }
                    detailNotice = nil
                case .details where detailID == nil:
                    detailID = selectedID
                    selectedFilePath = nil
                    selectedEndpointAddress = sortedEndpoints(for: selectedID, in: monitor).first?.address
                    selectedConnection = nil
                    detailFocus = .endpoints
                    detailFiles = []
                    details = ProcessDetails(
                        connections: [], files: [], note: "Loading process details…"
                    )
                    detailsRevision = -1
                    hostnameRevision = -1
                    detailNotice = nil
                case .back:
                    detailID = nil
                    selectedFilePath = nil
                    selectedEndpointAddress = nil
                    selectedConnection = nil
                    detailFiles = []
                    detailsRevision = -1
                    hostnameRevision = -1
                    detailNotice = nil
                case .toggleSort:
                    sort = sort == .total ? .live : .total
                case .toggleDetailFocus where detailID != nil:
                    switch detailFocus {
                    case .endpoints: detailFocus = .connections
                    case .connections: detailFocus = .files
                    case .files: detailFocus = .endpoints
                    }
                    detailNotice = nil
                case .focusEndpoints where detailID != nil:
                    detailFocus = .endpoints
                case .focusFiles where detailID != nil:
                    detailFocus = .files
                case .reset:
                    for id in pausedProcesses.keys {
                        _ = ProcessController.resume(id)
                    }
                    pausedProcesses.removeAll()
                    pendingPause = nil
                    monitor.reset()
                    statisticsStarted = now
                    selectedID = nil
                    detailID = nil
                    selectedFilePath = nil
                    selectedEndpointAddress = nil
                    selectedConnection = nil
                    detailFocus = .endpoints
                    detailFiles = []
                    details = ProcessDetails(
                        connections: [], files: [], note: "Loading process details…"
                    )
                    detailsRevision = -1
                    hostnameRevision = -1
                    detailNotice = nil
                case .copy:
                    let copyValue: String?
                    switch detailFocus {
                    case .endpoints:
                        copyValue = selectedEndpointAddress.map {
                            hostnameResolver.snapshot().names[$0] ?? $0
                        }
                    case .connections:
                        copyValue = selectedConnection
                    case .files:
                        copyValue = selectedFilePath
                    }
                    guard let copyValue else { continue }
                    detailNotice = ProcessInspector.copyToClipboard(copyValue)
                        ? "Copied: \(copyValue)"
                        : "Could not copy the selected item"
                case .pause:
                    guard let id = detailID ?? selectedID else { continue }
                    if pausedProcesses[id] != nil {
                        detailNotice = "Process is already paused; press [u] to unpause"
                        pendingPause = nil
                    } else if pendingPause?.id == id,
                              let expiry = pendingPause?.expires,
                              now < expiry {
                        let result = ProcessController.pause(id)
                        if result == nil {
                            pausedProcesses[id] = now.addingTimeInterval(30)
                            detailNotice = "PAUSED: all process activity stopped; auto-unpause in 30 seconds"
                        } else {
                            detailNotice = result
                        }
                        pendingPause = nil
                    } else {
                        pendingPause = (id, now.addingTimeInterval(4))
                        detailNotice = "Press [p] again within 4s to pause ALL activity for up to 30s"
                    }
                case .unpause:
                    guard let id = detailID ?? selectedID else { continue }
                    guard pausedProcesses[id] != nil else {
                        detailNotice = "Process is not paused"
                        pendingPause = nil
                        continue
                    }
                    let result = ProcessController.resume(id)
                    if result == nil {
                        pausedProcesses.removeValue(forKey: id)
                        detailNotice = "Process unpaused"
                    } else {
                        detailNotice = result
                    }
                    pendingPause = nil
                case .quit:
                    shouldQuit = true
                default:
                    break
                }
            }
        }

        ranked = display.sorted(Array(monitor.traffic.values), by: sort)
        if let detailID, let item = monitor.traffic[detailID] {
            rankedEndpoints = sortedEndpoints(for: detailID, in: monitor)
            let endpoints = rankedEndpoints
            hostnameResolver.request(endpoints.map(\.address))
            let hostnameSnapshot = hostnameResolver.snapshot()
            if hostnameSnapshot.revision != hostnameRevision {
                hostnameRevision = hostnameSnapshot.revision
                needsRender = true
            }
            processInspector.request(detailID, now: now)
            if let snapshot = processInspector.snapshot(for: detailID),
               snapshot.revision != detailsRevision {
                details = snapshot.details
                detailsRevision = snapshot.revision
                detailFiles = details.files
                if let connection = selectedConnection,
                   details.connections.contains(connection) == false {
                    selectedConnection = details.connections.first
                } else if selectedConnection == nil {
                    selectedConnection = details.connections.first
                }
                if let path = selectedFilePath,
                   detailFiles.contains(where: { $0.path == path }) == false {
                    selectedFilePath = detailFiles.first?.path
                } else if selectedFilePath == nil {
                    selectedFilePath = detailFiles.first?.path
                }
                needsRender = true
            }

            let selectedFileIndex = selectedFilePath.flatMap { path in
                detailFiles.firstIndex { $0.path == path }
            } ?? 0
            let pauseSecondsRemaining = pausedProcesses[detailID].map {
                max(0, Int(ceil($0.timeIntervalSince(now))))
            }
            if pauseSecondsRemaining != lastPauseSecondsRemaining {
                lastPauseSecondsRemaining = pauseSecondsRemaining
                needsRender = true
            }
            if needsRender {
                display.renderDetail(
                    item,
                    details: details,
                    endpoints: endpoints,
                    hostnames: hostnameSnapshot.names,
                    selectedEndpointIndex: selectedEndpointAddress.flatMap { address in
                        endpoints.firstIndex { $0.address == address }
                    } ?? 0,
                    selectedEndpointHistory: selectedEndpointAddress.flatMap { address in
                        monitor.endpointHistory[detailID]?[address]
                    } ?? [],
                    selectedConnectionIndex: selectedConnection.flatMap {
                        details.connections.firstIndex(of: $0)
                    } ?? 0,
                    detailFocus: detailFocus,
                    history: monitor.processHistory[detailID] ?? [],
                    sampleInterval: options.interval,
                    elapsed: now.timeIntervalSince(statisticsStarted),
                    selectedFileIndex: selectedFileIndex,
                    pausedSecondsRemaining: pauseSecondsRemaining,
                    notice: detailNotice
                )
            }
        } else {
            detailID = nil
            lastPauseSecondsRemaining = nil
            if needsRender {
                display.renderList(
                    ranked,
                    history: monitor.aggregateHistory,
                    sampleInterval: options.interval,
                    elapsed: now.timeIntervalSince(statisticsStarted),
                    sort: sort,
                    selected: selectedID,
                    selectedIsPaused: selectedID.map { pausedProcesses[$0] != nil } ?? false,
                    notice: detailNotice
                )
            }
        }
        needsRender = false
    }
} catch {
    fputs("traffic-ctrl: \(error.localizedDescription)\n", stderr)
    if case CLIError.usage = error {
        fputs("Try 'traffic-ctrl --help'.\n", stderr)
    }
    exit(1)
}
