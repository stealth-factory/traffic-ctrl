import Foundation

struct TrafficMonitor {
    private(set) var traffic: [ProcessID: ProcessTraffic] = [:]
    private(set) var aggregateHistory: [RateSample] = []
    private(set) var processHistory: [ProcessID: [RateSample]] = [:]
    private(set) var endpointTraffic: [ProcessID: [String: EndpointTraffic]] = [:]
    private(set) var endpointHistory: [ProcessID: [String: [RateSample]]] = [:]
    private let historyLimit = 240

    mutating func reset() {
        traffic.removeAll(keepingCapacity: true)
        aggregateHistory.removeAll(keepingCapacity: true)
        processHistory.removeAll(keepingCapacity: true)
        endpointTraffic.removeAll(keepingCapacity: true)
        endpointHistory.removeAll(keepingCapacity: true)
    }

    /// The collector supplies interval deltas, never lifetime counters.
    mutating func ingest(_ delta: TrafficDelta, elapsed: TimeInterval) {
        for key in traffic.keys {
            traffic[key]?.receiveRate = 0
            traffic[key]?.sendRate = 0
        }

        for (id, counters) in delta.processes {
            var item = traffic[id] ?? ProcessTraffic(id: id)
            item.received += counters.received
            item.sent += counters.sent
            item.receiveRate = elapsed > 0 ? Double(counters.received) / elapsed : 0
            item.sendRate = elapsed > 0 ? Double(counters.sent) / elapsed : 0
            traffic[id] = item
        }

        for processID in Array(endpointTraffic.keys) {
            guard let addresses = endpointTraffic[processID]?.keys else { continue }
            for address in Array(addresses) {
                endpointTraffic[processID]?[address]?.receiveRate = 0
                endpointTraffic[processID]?[address]?.sendRate = 0
            }
        }
        for (processID, endpointDelta) in delta.endpoints {
            for (address, counters) in endpointDelta {
                var endpoint = endpointTraffic[processID]?[address]
                    ?? EndpointTraffic(address: address)
                endpoint.received += counters.received
                endpoint.sent += counters.sent
                endpoint.receiveRate = elapsed > 0 ? Double(counters.received) / elapsed : 0
                endpoint.sendRate = elapsed > 0 ? Double(counters.sent) / elapsed : 0
                endpointTraffic[processID, default: [:]][address] = endpoint
            }
        }

        let aggregate = delta.processes.values.reduce((received: 0.0, sent: 0.0)) { total, counters in
            (
                total.received + (elapsed > 0 ? Double(counters.received) / elapsed : 0),
                total.sent + (elapsed > 0 ? Double(counters.sent) / elapsed : 0)
            )
        }
        append(
            RateSample(received: aggregate.received, sent: aggregate.sent),
            to: &aggregateHistory
        )

        for (id, item) in traffic {
            var history = processHistory[id] ?? []
            append(RateSample(received: item.receiveRate, sent: item.sendRate), to: &history)
            processHistory[id] = history
        }
        for (processID, endpoints) in endpointTraffic {
            for (address, endpoint) in endpoints {
                var history = endpointHistory[processID]?[address] ?? []
                append(
                    RateSample(received: endpoint.receiveRate, sent: endpoint.sendRate),
                    to: &history
                )
                endpointHistory[processID, default: [:]][address] = history
            }
        }
    }

    private func append(_ sample: RateSample, to history: inout [RateSample]) {
        history.append(sample)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }
}
