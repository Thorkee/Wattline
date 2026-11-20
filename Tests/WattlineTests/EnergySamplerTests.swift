import XCTest
@testable import Wattline

final class EnergySamplerTests: XCTestCase {
    typealias Usage = EnergySampler.ProcessUsage

    private func usage(_ executable: String, energy: UInt64?, cpu: UInt64 = 0, start: UInt64 = 10,
                       parent: Int32 = 1) -> Usage {
        Usage(start: start, energy: energy, cpu: cpu, parent: parent, executable: executable,
              bundlePath: EnergySampler.outerBundle(in: executable))
    }

    func testNestedHelpersAndUnbundledChildrenRollUpToTheSameApp() {
        let main = "/Applications/Sample.app/Contents/MacOS/Sample"
        let helper = "/Applications/Sample.app/Contents/Helpers/Renderer.app/Contents/MacOS/Renderer"
        let first: [Int32: Usage] = [
            4: usage(main, energy: 100), 5: usage(helper, energy: 10),
            6: usage("/usr/bin/worker", energy: 20, parent: 4), 7: usage("/usr/bin/other", energy: 15)
        ]
        let last: [Int32: Usage] = [
            4: usage(main, energy: 130), 5: usage(helper, energy: 50),
            6: usage("/usr/bin/worker", energy: 100, parent: 4), 7: usage("/usr/bin/other", energy: 55)
        ]
        let result = EnergySampler.rank(previous: first, current: last, from: 100, to: 150, nanosecondsPerTick: 2)
        XCTAssertEqual(result.metric, .power)
        XCTAssertEqual(result.consumers.map(\.id), ["/Applications/Sample.app", "/usr/bin/other"])
        XCTAssertEqual(result.consumers.map(\.value), [1.5, 0.4])
    }

    func testReusedPIDNewProcessAndResetCounters() {
        let first: [Int32: Usage] = [2: usage("/old", energy: 500), 3: usage("/reset", energy: 500)]
        let last: [Int32: Usage] = [
            2: usage("/new", energy: 70, start: 120), 3: usage("/reset", energy: 10),
            4: usage("/already-running-without-baseline", energy: 900_000)
        ]
        let result = EnergySampler.rank(previous: first, current: last, from: 100, to: 200, nanosecondsPerTick: 1)
        XCTAssertEqual(result.consumers.map(\.id), ["/new"])
        XCTAssertEqual(result.consumers.first?.value, 0.7)
    }

    func testNoEnergyCountersRanksByCPUAndLimitsToThree() {
        let first: [Int32: Usage] = [
            2: usage("/one", energy: 0), 3: usage("/two", energy: nil),
            4: usage("/three", energy: 0), 5: usage("/four", energy: nil)
        ]
        let last: [Int32: Usage] = [
            2: usage("/one", energy: 0, cpu: 300), 3: usage("/two", energy: nil, cpu: 200),
            4: usage("/three", energy: 0, cpu: 100), 5: usage("/four", energy: nil, cpu: 90)
        ]
        let result = EnergySampler.rank(previous: first, current: last, from: 100, to: 300, nanosecondsPerTick: 20)
        XCTAssertEqual(result.metric, .cpu)
        XCTAssertEqual(result.consumers.map(\.value), [150, 100, 50])
        XCTAssertEqual(result.consumers.map(\.name), ["one", "two", "three"])
    }

    func testCPUViewKeepsOneCoreUnitsWhenEnergyWouldChangeTheRank() {
        let first: [Int32: Usage] = [2: usage("/one", energy: 10), 3: usage("/two", energy: 10)]
        let after: [Int32: Usage] = [2: usage("/one", energy: 90, cpu: 15),
                                     3: usage("/two", energy: 30, cpu: 200)]
        let cpu = EnergySampler.rank(previous: first, current: after, from: 100, to: 200,
                                     nanosecondsPerTick: 2, forceCPU: true)
        XCTAssertEqual(cpu.metric, .cpu)
        XCTAssertEqual(cpu.consumers.map(\.name), ["two", "one"])
        XCTAssertEqual(cpu.consumers.map(\.value), [200, 15])
        let power = EnergySampler.rank(previous: first, current: after, from: 100, to: 200, nanosecondsPerTick: 2)
        XCTAssertEqual(power.consumers.first?.name, "one")
    }

    func testMemoryRanksCurrentFootprintsByOwnerWithoutABaseline() throws {
        let app = "/Applications/Sample.app"
        var current: [Int32: Usage] = [
            2: usage(app + "/Contents/MacOS/Sample", energy: nil),
            3: usage(app + "/Contents/Helpers/Inner.app/Contents/MacOS/Inner", energy: nil),
            4: usage("/usr/bin/worker", energy: nil, parent: 2),
            5: usage("/other", energy: nil), 6: usage("/unreadable", energy: nil)
        ]
        current[2]?.footprint = 50
        current[3]?.footprint = 100
        current[4]?.footprint = 20
        current[5]?.footprint = 110
        let memory = try XCTUnwrap(EnergySampler.rankMemory(current))
        XCTAssertEqual(memory.map(\.id), [app, "/other"])
        XCTAssertEqual(memory.map(\.value), [170, 110])
        XCTAssertNil(EnergySampler.rankMemory([:]))
        XCTAssertNil(EnergySampler.rankMemory([6: current[6]!]))
    }

    func testNoReadableBaselineIsDistinguishedFromAQuietInterval() {
        let idle: [Int32: Usage] = [5: usage("/idle", energy: 29, cpu: 9)]
        let quiet = EnergySampler.rank(previous: idle, current: idle, from: 100, to: 200, nanosecondsPerTick: 1)
        XCTAssertTrue(quiet.isAvailable)
        XCTAssertTrue(quiet.consumers.isEmpty)
        XCTAssertEqual(quiet.metric, .power)
        let denied = EnergySampler.rank(previous: idle, current: [:], from: 100, to: 200, nanosecondsPerTick: 1)
        XCTAssertFalse(denied.isAvailable)
        let regained = EnergySampler.rank(previous: [:], current: idle, from: 100, to: 200, nanosecondsPerTick: 1)
        XCTAssertFalse(regained.isAvailable)
    }

    func testStalledAndMixedEnergyCountersFallBackToComparableCPUPercentages() {
        let first: [Int32: Usage] = [1: usage("/known", energy: 50, cpu: 10), 2: usage("/other", energy: nil, cpu: 10)]
        for endEnergy: UInt64 in [50, 90] {
            let end: [Int32: Usage] = [1: usage("/known", energy: endEnergy, cpu: 20), 2: usage("/other", energy: nil, cpu: 40)]
            let result = EnergySampler.rank(previous: first, current: end, from: 100, to: 200, nanosecondsPerTick: 41.667)
            XCTAssertEqual(result.metric, .cpu)
            XCTAssertEqual(result.consumers.map(\.value), [30, 10])
        }
        let stalled = EnergySampler.rank(previous: first, current: [1: usage("/known", energy: 50, cpu: 20)],
                                         from: 100, to: 200, nanosecondsPerTick: 1)
        XCTAssertEqual(stalled.metric, .cpu)
        XCTAssertEqual(stalled.consumers.first?.value, 10)
    }

    func testExecAndParentChangesDoNotTransferPreviousWorkToAnotherApp() {
        let appA = "/Applications/A.app/Contents/MacOS/A"
        let appB = "/Applications/B.app/Contents/MacOS/B"
        var first: [Int32: Usage] = [2: usage(appA, energy: 100), 3: usage(appB, energy: 100),
                                     4: usage("/worker", energy: 50, parent: 2), 5: usage("/replaced", energy: 50)]
        var last = first
        first[5]?.executableID = UUID()
        last[5] = usage("/replaced", energy: 250)
        last[5]?.executableID = UUID()
        last[4] = usage("/worker", energy: 250, parent: 3)
        last[2] = usage(appA, energy: 150)
        let result = EnergySampler.rank(previous: first, current: last, from: 100, to: 200, nanosecondsPerTick: 1)
        XCTAssertEqual(result.consumers.map(\.id), ["/Applications/A.app"])
        XCTAssertEqual(result.consumers.first?.value, 0.5)
    }

    func testZeroOrBackwardIntervalIsUnavailable() {
        let snapshot: [Int32: Usage] = [4: usage("/idle", energy: 20)]
        for end: UInt64 in [49, 50] {
            let result = EnergySampler.rank(previous: snapshot, current: snapshot, from: 50, to: end, nanosecondsPerTick: 1)
            XCTAssertFalse(result.isAvailable)
        }
    }
}
