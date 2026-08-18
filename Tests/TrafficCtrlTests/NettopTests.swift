import XCTest
@testable import TrafficCtrl

final class NettopTests: XCTestCase {
    func testPublicAddressClassification() {
        XCTAssertTrue(Nettop.isPublicAddress("1.1.1.1"))
        XCTAssertTrue(Nettop.isPublicAddress("2606:4700:4700::1111"))
        XCTAssertFalse(Nettop.isPublicAddress("192.168.20.1"))
        XCTAssertFalse(Nettop.isPublicAddress("100.88.11.62"))
        XCTAssertFalse(Nettop.isPublicAddress("169.254.1.1"))
        XCTAssertFalse(Nettop.isPublicAddress("fe80::1"))
        XCTAssertFalse(Nettop.isPublicAddress("ff02::fb"))
    }

    func testParsesOnlyPublicConnectionDeltas() {
        let lines = [
            "Safari.123,999999,999999,",
            "tcp4 192.168.20.35:50000<->1.1.1.1:443,100,20,",
            "tcp4 192.168.20.35:50001<->192.168.20.1:80,500,200,",
            "mDNSResponder.430,999999,999999,",
            "udp4 *:5353<->*:*,900000,50000,"
        ]

        let delta = Nettop.parseSample(lines, publicOnly: true)
        XCTAssertEqual(
            delta.processes[ProcessID(name: "Safari", pid: 123)],
            NetworkCounters(received: 100, sent: 20)
        )
        XCTAssertEqual(
            delta.endpoints[ProcessID(name: "Safari", pid: 123)]?["1.1.1.1"],
            NetworkCounters(received: 100, sent: 20)
        )
        XCTAssertNil(delta.processes[ProcessID(name: "mDNSResponder", pid: 430)])
    }

    func testMonitorSumsDeltasWithoutLifetimeSubtraction() {
        var monitor = TrafficMonitor()
        let process = ProcessID(name: "Safari", pid: 123)

        monitor.ingest(
            TrafficDelta(
                processes: [process: NetworkCounters(received: 400, sent: 100)],
                endpoints: [:]
            ),
            elapsed: 2
        )
        monitor.ingest(
            TrafficDelta(
                processes: [process: NetworkCounters(received: 20, sent: 10)],
                endpoints: [:]
            ),
            elapsed: 1
        )

        XCTAssertEqual(monitor.traffic[process]?.received, 420)
        XCTAssertEqual(monitor.traffic[process]?.sent, 110)
        XCTAssertEqual(monitor.traffic[process]?.receiveRate, 20)
        XCTAssertEqual(monitor.traffic[process]?.sendRate, 10)
    }

    func testResetClearsAccumulatedDeltas() {
        var monitor = TrafficMonitor()
        let process = ProcessID(name: "curl", pid: 456)

        monitor.ingest(
            TrafficDelta(
                processes: [process: NetworkCounters(received: 100, sent: 50)],
                endpoints: [:]
            ),
            elapsed: 1
        )
        monitor.reset()

        XCTAssertTrue(monitor.traffic.isEmpty)
        XCTAssertTrue(monitor.endpointHistory.isEmpty)
    }

    func testEndpointHistoryTracksIndependentRates() {
        var monitor = TrafficMonitor()
        let process = ProcessID(name: "curl", pid: 456)
        monitor.ingest(
            TrafficDelta(
                processes: [process: NetworkCounters(received: 100, sent: 50)],
                endpoints: [
                    process: ["1.1.1.1": NetworkCounters(received: 80, sent: 20)]
                ]
            ),
            elapsed: 2
        )

        let sample = monitor.endpointHistory[process]?["1.1.1.1"]?.last
        XCTAssertEqual(sample?.received, 40)
        XCTAssertEqual(sample?.sent, 10)
    }
}
