import Foundation

struct CollectorDrain {
    let deltas: [TrafficDelta]
    let failure: String?
}

final class TrafficCollector: @unchecked Sendable {
    private let nettop: Nettop
    private let queue = DispatchQueue(label: "traffic-ctrl.traffic-collector")
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var pending: [TrafficDelta] = []
    private var failure: String?
    private var stopping = false

    init(interval: TimeInterval, publicOnly: Bool) throws {
        nettop = try Nettop(interval: interval, publicOnly: publicOnly)
    }

    func start() {
        group.enter()
        queue.async { [self] in
            defer { group.leave() }
            while isStopping == false {
                do {
                    let delta = try nettop.nextDelta()
                    lock.lock()
                    pending.append(delta)
                    lock.unlock()
                } catch {
                    lock.lock()
                    if stopping == false { failure = error.localizedDescription }
                    lock.unlock()
                    return
                }
            }
        }
    }

    func drain() -> CollectorDrain {
        lock.lock()
        defer { lock.unlock() }
        let result = CollectorDrain(deltas: pending, failure: failure)
        pending.removeAll(keepingCapacity: true)
        return result
    }

    func stop() {
        lock.lock()
        let alreadyStopping = stopping
        stopping = true
        lock.unlock()
        guard alreadyStopping == false else { return }
        nettop.stop()
        _ = group.wait(timeout: .now() + 2)
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }
}
