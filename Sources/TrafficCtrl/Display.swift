import Darwin
import Foundation

private final class FrameWriter: @unchecked Sendable {
    private let condition = NSCondition()
    private let queue = DispatchQueue(label: "traffic-ctrl.display-writer", qos: .userInteractive)
    private var pending: Data?
    private var running = false

    func submit(_ frame: Data) {
        condition.lock()
        pending = frame
        if running == false {
            running = true
            queue.async { [weak self] in self?.drain() }
        }
        condition.unlock()
    }

    func flush() {
        condition.lock()
        while running || pending != nil {
            condition.wait()
        }
        condition.unlock()
    }

    private func drain() {
        while true {
            condition.lock()
            guard let frame = pending else {
                running = false
                condition.broadcast()
                condition.unlock()
                return
            }
            pending = nil
            condition.unlock()
            FileHandle.standardOutput.write(frame)
        }
    }
}

enum SortMode: String {
    case total
    case live
}

struct Display {
    let limit: Int
    let plain: Bool
    let scope: String
    private let writer = FrameWriter()

    func flush() {
        writer.flush()
    }

    func sorted(_ values: [ProcessTraffic], by sort: SortMode) -> [ProcessTraffic] {
        values
            .filter { $0.total > 0 || $0.totalRate > 0 }
            .sorted {
                switch sort {
                case .total:
                    if $0.total == $1.total { return $0.totalRate > $1.totalRate }
                    return $0.total > $1.total
                case .live:
                    if $0.totalRate == $1.totalRate { return $0.total > $1.total }
                    return $0.totalRate > $1.totalRate
                }
            }
    }

    func renderList(
        _ ranked: [ProcessTraffic],
        history: [RateSample],
        sampleInterval: TimeInterval,
        elapsed: TimeInterval,
        sort: SortMode,
        selected: ProcessID?
    ) {
        let rows = plain ? nil : terminalRows()
        let width = max(40, terminalColumns() ?? 100)
        let chart = chartLines(history, width: width, height: chartHeight(rows: rows))
        let visibleLimit = rows.map { max(1, min(limit, $0 - chart.count - 7)) } ?? limit
        let selectedIndex = selected.flatMap { id in ranked.firstIndex { $0.id == id } } ?? 0
        let start = selectedIndex < visibleLimit ? 0 : selectedIndex - visibleLimit + 1
        let visible = ranked.dropFirst(start).prefix(visibleLimit)

        var lines = header(elapsed: elapsed, sort: sort)
        lines.append(contentsOf: chartHeader(history, sampleInterval: sampleInterval, title: "All processes"))
        lines.append(contentsOf: chart)
        lines.append(tableHeader(width: width))
        lines.append(String(repeating: "─", count: width))

        for (offset, item) in visible.enumerated() {
            let index = start + offset
            let marker = item.id == selected ? "›" : " "
            lines.append(tableRow(item, index: "\(marker)\(index + 1)", width: width))
        }

        if ranked.isEmpty {
            lines.append("Waiting for public-Internet traffic…")
        }
        finish(
            &lines,
            rows: rows,
            footer: listFooter(width: width)
        )
    }

    func renderDetail(
        _ item: ProcessTraffic,
        details: ProcessDetails,
        endpoints: [EndpointTraffic],
        hostnames: [String: String],
        selectedEndpointIndex: Int,
        selectedEndpointHistory: [RateSample],
        detailFocus: DetailFocus,
        history: [RateSample],
        sampleInterval: TimeInterval,
        elapsed: TimeInterval,
        selectedFileIndex: Int,
        pausedSecondsRemaining: Int?,
        notice: String?
    ) {
        let rows = plain ? nil : terminalRows()
        let width = max(40, terminalColumns() ?? 100)
        let chart = chartLines(history, width: width, height: chartHeight(rows: rows))
        var lines: [String] = [
            "Traffic Ctrl  process details  \(duration(elapsed))",
            "\(item.id.name)  PID \(item.id.pid)",
            String(repeating: "─", count: width),
            "Public Internet: \(bytes(item.total)) total   \(rate(item.totalRate)) now   ↓ \(rate(item.receiveRate))   ↑ \(rate(item.sendRate))",
            ""
        ]

        if let pausedSecondsRemaining {
            lines.insert("STATUS: PAUSED — all activity stopped (auto-unpause in \(pausedSecondsRemaining)s)", at: 2)
        }

        lines.append(contentsOf: chartHeader(history, sampleInterval: sampleInterval, title: item.id.name))
        lines.append(contentsOf: chart)

        lines.append("Domains / remote endpoints (observed since launch)")
        if endpoints.isEmpty {
            lines.append("  No public remote endpoints observed")
        } else {
            let endpointLimit = rows.map { $0 >= 50 ? 8 : 4 } ?? 8
            let selected = min(max(0, selectedEndpointIndex), endpoints.count - 1)
            let start = selected < endpointLimit ? 0 : selected - endpointLimit + 1
            lines.append("  " + endpointHeader(width: width - 2))
            for (offset, endpoint) in endpoints.dropFirst(start).prefix(endpointLimit).enumerated() {
                let index = start + offset
                let marker = detailFocus == .endpoints && index == selected ? "›" : " "
                lines.append(marker + " " + endpointRow(
                    endpoint, hostname: hostnames[endpoint.address], width: width - 2
                ))
                if detailFocus == .endpoints && index == selected {
                    lines.append(contentsOf: compactEndpointChart(
                        selectedEndpointHistory, width: width - 2
                    ).map { "  " + $0 })
                }
            }
            if endpoints.count > endpointLimit {
                lines.append("  Endpoints \(start + 1)–\(min(endpoints.count, start + endpointLimit)) of \(endpoints.count)")
            }
        }

        lines.append("")
        lines.append("Network connections (current snapshot)")

        if details.connections.isEmpty {
            lines.append("  No visible network sockets")
        } else {
            for connection in details.connections.prefix(8) {
                lines.append("  " + truncate(connection, width: width - 2))
            }
        }

        lines.append("")
        lines.append("Relevant open files (correlation only; not proof of transfer)")
        if details.files.isEmpty {
            lines.append("  No accessible user or temporary files")
        } else {
            let available = max(1, (rows ?? 30) - lines.count - 5)
            let selected = min(max(0, selectedFileIndex), details.files.count - 1)
            let start = selected < available ? 0 : selected - available + 1
            for (offset, file) in details.files.dropFirst(start).prefix(available).enumerated() {
                let index = start + offset
                let marker = detailFocus == .files && index == selected ? "›" : " "
                let label = pad(bytes(file.size), to: 9, rightAligned: true) + "  " + file.displayPath
                lines.append(marker + " " + truncate(label, width: width - 2))
            }
        }
        if let note = details.note {
            lines.append("  " + truncate(note, width: width - 2))
        }
        if let notice {
            lines.append("")
            lines.append(truncate(notice, width: width))
        }

        let processControl = pausedSecondsRemaining == nil ? "[p]ause" : "[u]npause"
        finish(
            &lines,
            rows: rows,
            footer: detailFooter(processControl: processControl, focus: detailFocus, width: width)
        )
    }

    private func header(elapsed: TimeInterval, sort: SortMode) -> [String] {
        ["Traffic Ctrl  \(scope)  \(duration(elapsed))  sort: \(sort == .total ? "total data" : "live bandwidth")"]
    }

    private func chartHeight(rows: Int?) -> Int {
        guard let rows else { return 5 }
        if rows < 24 { return 3 }
        if rows < 38 { return 4 }
        return 6
    }

    private func chartHeader(
        _ history: [RateSample],
        sampleInterval: TimeInterval,
        title: String
    ) -> [String] {
        let latest = history.last ?? RateSample(received: 0, sent: 0)
        let window = Double(max(0, history.count - 1)) * sampleInterval
        let legend = plain
            ? "RX ↑ \(rate(latest.received))   TX ↓ \(rate(latest.sent))"
            : "\u{001B}[36mRX ↑ \(rate(latest.received))\u{001B}[0m   \u{001B}[35mTX ↓ \(rate(latest.sent))\u{001B}[0m"
        return ["", "Traffic — \(title)   \(legend)   last \(shortDuration(window))"]
    }

    private func chartLines(_ history: [RateSample], width: Int, height: Int) -> [String] {
        let labelWidth = 10
        let plotWidth = max(12, width - labelWidth - 3)
        let pixelWidth = plotWidth * 2
        let visible = Array(history.suffix(pixelWidth))
        let upperHeight = max(2, height / 2)
        let lowerHeight = max(2, height - upperHeight)
        let rxPeak = max(1, visible.reduce(0) { max($0, $1.received) })
        let txPeak = max(1, visible.reduce(0) { max($0, $1.sent) })
        var rx = Array(
            repeating: Array(repeating: UInt8(0), count: plotWidth),
            count: upperHeight
        )
        var tx = Array(
            repeating: Array(repeating: UInt8(0), count: plotWidth),
            count: lowerHeight
        )
        drawBrailleLine(
            visible.map(\.received), peak: rxPeak, pixelWidth: pixelWidth,
            pixelHeight: upperHeight * 4, inverted: false, canvas: &rx
        )
        drawBrailleLine(
            visible.map(\.sent), peak: txPeak, pixelWidth: pixelWidth,
            pixelHeight: lowerHeight * 4, inverted: true, canvas: &tx
        )

        let emptyLabel = String(repeating: " ", count: labelWidth)
        var result = [
            pad(rate(rxPeak), to: labelWidth, rightAligned: true)
                + " ┌" + String(repeating: "─", count: plotWidth) + "┐"
        ]
        for row in rx {
            result.append(emptyLabel + " │" + brailleRow(row, colourCode: 36) + "│")
        }
        result.append(
            pad("0 B/s", to: labelWidth, rightAligned: true)
                + " ├" + String(repeating: "─", count: plotWidth) + "┤"
        )
        for row in tx {
            result.append(emptyLabel + " │" + brailleRow(row, colourCode: 35) + "│")
        }
        result.append(
            pad("−" + rate(txPeak), to: labelWidth, rightAligned: true)
                + " └" + String(repeating: "─", count: plotWidth) + "┘"
        )
        return result
    }

    private func compactEndpointChart(_ history: [RateSample], width: Int) -> [String] {
        let labelWidth = 12
        let plotWidth = max(10, width - labelWidth - 3)
        let pixelWidth = plotWidth * 2
        let visible = Array(history.suffix(pixelWidth))
        let rxPeak = max(1, visible.reduce(0) { max($0, $1.received) })
        let txPeak = max(1, visible.reduce(0) { max($0, $1.sent) })
        var rx = [Array(repeating: UInt8(0), count: plotWidth)]
        var tx = [Array(repeating: UInt8(0), count: plotWidth)]
        drawBrailleLine(
            visible.map(\.received), peak: rxPeak, pixelWidth: pixelWidth,
            pixelHeight: 4, inverted: false, canvas: &rx
        )
        drawBrailleLine(
            visible.map(\.sent), peak: txPeak, pixelWidth: pixelWidth,
            pixelHeight: 4, inverted: true, canvas: &tx
        )
        let emptyLabel = String(repeating: " ", count: labelWidth)
        return [
            pad("RX " + rate(rxPeak), to: labelWidth, rightAligned: true)
                + " ┌" + String(repeating: "─", count: plotWidth) + "┐",
            emptyLabel + " │" + brailleRow(rx[0], colourCode: 36) + "│",
            pad("0 B/s", to: labelWidth, rightAligned: true)
                + " ├" + String(repeating: "─", count: plotWidth) + "┤",
            emptyLabel + " │" + brailleRow(tx[0], colourCode: 35) + "│",
            pad("TX " + rate(txPeak), to: labelWidth, rightAligned: true)
                + " └" + String(repeating: "─", count: plotWidth) + "┘"
        ]
    }

    private func brailleRow(_ masks: [UInt8], colourCode: Int) -> String {
        let row = masks.map { mask in mask == 0 ? " " : braille(mask) }.joined()
        return colour(row, code: colourCode)
    }

    private func drawBrailleLine(
        _ values: [Double],
        peak: Double,
        pixelWidth: Int,
        pixelHeight: Int,
        inverted: Bool,
        canvas: inout [[UInt8]]
    ) {
        guard values.isEmpty == false else { return }
        func point(at index: Int) -> (x: Int, y: Int) {
            let x = values.count == 1
                ? pixelWidth - 1
                : Int((Double(index) * Double(pixelWidth - 1) / Double(values.count - 1)).rounded())
            let scaled = min(1, max(0, values[index] / peak))
            let magnitude = Int((scaled * Double(pixelHeight - 1)).rounded())
            let y = inverted ? magnitude : pixelHeight - 1 - magnitude
            return (x, y)
        }

        if values.count == 1 {
            if values[0] > 0 { setBrailleDot(point(at: 0), canvas: &canvas) }
            return
        }
        for index in 1..<values.count {
            if values[index - 1] == 0, values[index] == 0 { continue }
            drawSegment(from: point(at: index - 1), to: point(at: index), canvas: &canvas)
        }
    }

    private func drawSegment(
        from start: (x: Int, y: Int),
        to end: (x: Int, y: Int),
        canvas: inout [[UInt8]]
    ) {
        var x = start.x
        var y = start.y
        let dx = abs(end.x - start.x)
        let sx = start.x < end.x ? 1 : -1
        let dy = -abs(end.y - start.y)
        let sy = start.y < end.y ? 1 : -1
        var error = dx + dy
        while true {
            setBrailleDot((x, y), canvas: &canvas)
            if x == end.x, y == end.y { break }
            let doubled = 2 * error
            if doubled >= dy { error += dy; x += sx }
            if doubled <= dx { error += dx; y += sy }
        }
    }

    private func setBrailleDot(_ point: (x: Int, y: Int), canvas: inout [[UInt8]]) {
        guard point.x >= 0, point.y >= 0,
              point.y / 4 < canvas.count,
              point.x / 2 < (canvas.first?.count ?? 0)
        else { return }
        let bits: [[UInt8]] = [
            [0x01, 0x08],
            [0x02, 0x10],
            [0x04, 0x20],
            [0x40, 0x80]
        ]
        canvas[point.y / 4][point.x / 2] |= bits[point.y % 4][point.x % 2]
    }

    private func braille(_ mask: UInt8) -> String {
        String(UnicodeScalar(0x2800 + Int(mask))!)
    }

    private func colour(_ value: String, code: Int) -> String {
        plain ? value : "\u{001B}[\(code)m\(value)\u{001B}[0m"
    }

    private func shortDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        return "\(total / 60)m \(total % 60)s"
    }

    private func finish(_ lines: inout [String], rows: Int?, footer: String) {
        if let rows {
            let blankRows = max(0, rows - 1 - lines.count - 2)
            lines.append(contentsOf: repeatElement("", count: blankRows))
            lines.append(String(repeating: "─", count: max(40, terminalColumns() ?? 76)))
        }
        lines.append(footer)

        if plain {
            print(lines.joined(separator: "\n"))
        } else {
            let content = lines.map { "\u{001B}[2K" + $0 }.joined(separator: "\n")
            let frame = "\u{001B}[?2026h\u{001B}[H" + content + "\u{001B}[J\u{001B}[?2026l"
            writer.submit(Data(frame.utf8))
        }
    }

    private func terminalRows() -> Int? {
        terminalSize().map { Int($0.ws_row) }
    }

    private func terminalColumns() -> Int? {
        terminalSize().map { Int($0.ws_col) }
    }

    private func terminalSize() -> winsize? {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0 else { return nil }
        return size
    }

    private func tableHeader(width: Int) -> String {
        if width >= 76 {
            return tableFields(
                ["#", "PROCESS", "PID", "TOTAL", "RATE", "DOWN", "UP"],
                widths: fullTableWidths(width: width)
            )
        }
        if width >= 55 {
            return tableFields(
                ["#", "PROCESS", "PID", "TOTAL", "RATE"],
                widths: compactTableWidths(width: width)
            )
        }
        return tableFields(["PROCESS", "PID", "RATE"], widths: narrowTableWidths(width: width))
    }

    private func endpointHeader(width: Int) -> String {
        if width >= 82 {
            return tableFields(
                ["DOMAIN / IP", "TOTAL", "RATE", "DOWN", "UP"],
                widths: endpointWidths(width: width)
            )
        }
        return tableFields(["DOMAIN / IP", "TOTAL", "RATE"], widths: endpointCompactWidths(width: width))
    }

    private func endpointRow(_ endpoint: EndpointTraffic, hostname: String?, width: Int) -> String {
        let identity = hostname.map { "\($0)  [\(endpoint.address)]" } ?? endpoint.address
        if width >= 82 {
            return tableFields(
                [identity, bytes(endpoint.total), rate(endpoint.totalRate),
                 rate(endpoint.receiveRate), rate(endpoint.sendRate)],
                widths: endpointWidths(width: width),
                rightAligned: [false, true, true, true, true]
            )
        }
        return tableFields(
            [identity, bytes(endpoint.total), rate(endpoint.totalRate)],
            widths: endpointCompactWidths(width: width),
            rightAligned: [false, true, true]
        )
    }

    private func endpointWidths(width: Int) -> [Int] {
        [max(20, width - 48), 10, 11, 11, 11]
    }

    private func endpointCompactWidths(width: Int) -> [Int] {
        [max(16, width - 24), 10, 11]
    }

    private func tableRow(_ item: ProcessTraffic, index: String, width: Int) -> String {
        if width >= 76 {
            return tableFields(
                [index, item.id.name, String(item.id.pid), bytes(item.total), rate(item.totalRate),
                 rate(item.receiveRate), rate(item.sendRate)],
                widths: fullTableWidths(width: width),
                rightAligned: [false, false, true, true, true, true, true]
            )
        }
        if width >= 55 {
            return tableFields(
                [index, item.id.name, String(item.id.pid), bytes(item.total), rate(item.totalRate)],
                widths: compactTableWidths(width: width),
                rightAligned: [false, false, true, true, true]
            )
        }
        return tableFields(
            [index.hasPrefix("›") ? "› " + item.id.name : "  " + item.id.name,
             String(item.id.pid), rate(item.totalRate)],
            widths: narrowTableWidths(width: width),
            rightAligned: [false, true, true]
        )
    }

    private func fullTableWidths(width: Int) -> [Int] {
        [4, max(16, width - 60), 7, 10, 11, 11, 11]
    }

    private func compactTableWidths(width: Int) -> [Int] {
        [4, max(12, width - 36), 7, 10, 11]
    }

    private func narrowTableWidths(width: Int) -> [Int] {
        [max(12, width - 20), 7, 11]
    }

    private func tableFields(
        _ fields: [String],
        widths: [Int],
        rightAligned: [Bool] = []
    ) -> String {
        zip(fields.indices, fields).map { index, value in
            pad(
                value,
                to: widths[index],
                rightAligned: index < rightAligned.count && rightAligned[index]
            )
        }.joined(separator: " ")
    }

    private func listFooter(width: Int) -> String {
        if width >= 72 {
            return "[↑/↓] select   [enter/→] details   [s]ort   [r]eset   [q]uit"
        }
        return "[j/k] select  [enter/→] details  [s]ort  [r]eset  [q]uit"
    }

    private func detailFooter(processControl: String, focus: DetailFocus, width: Int) -> String {
        if width >= 88 {
            let target = focus == .endpoints ? "endpoints" : "files"
            return "[↑/↓] \(target)  [e]ndpoints [f]iles  [c]opy  \(processControl)  [esc/←] back  [s]ort [r]eset [q]uit"
        }
        return "[j/k]  [e]ndpoints [f]iles  [c]opy  \(processControl)  [esc/←]back  [r]eset [q]uit"
    }

    private func pad(_ value: String, to width: Int, rightAligned: Bool = false) -> String {
        let clipped = truncate(value, width: width)
        let padding = String(repeating: " ", count: max(0, width - clipped.count))
        return rightAligned ? padding + clipped : clipped + padding
    }

    private func truncate(_ value: String, width: Int) -> String {
        guard value.count > width else { return value }
        return String(value.prefix(max(1, width - 1))) + "…"
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    private func bytes(_ value: UInt64) -> String { format(Double(value), suffix: "B") }
    private func rate(_ value: Double) -> String { format(value, suffix: "B/s") }

    private func format(_ value: Double, suffix: String) -> String {
        let units = ["", "K", "M", "G", "T"]
        var amount = value
        var index = 0
        while amount >= 1000, index < units.count - 1 {
            amount /= 1000
            index += 1
        }
        let number = amount >= 100 || index == 0
            ? String(format: "%.0f", amount)
            : String(format: "%.1f", amount)
        return number + " " + units[index] + suffix
    }
}
