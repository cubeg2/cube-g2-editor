// EuclidGroupTests.swift — Interlock, Random group and meeting points of the Euclid tab.

@testable import G2Core
import XCTest

private struct GroupSeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class EuclidGroupTests: XCTestCase {
    private func hits(_ pattern: [Bool]) -> [Int] {
        pattern.enumerated().filter(\.element).map(\.offset)
    }

    // MARK: Interlock

    func testTwoLanesInterlockAsComplements() {
        let lanes = EuclidGroup.interlock(hits: 4, steps: 16, rotation: 0, lanes: 2)
        XCTAssertEqual(lanes.count, 2)
        XCTAssertEqual(hits(lanes[0]), [0, 4, 8, 12])
        XCTAssertEqual(lanes[1], lanes[0].map { !$0 })
    }

    func testMoreLanesDealOutTheRestsInTurn() {
        let lanes = EuclidGroup.interlock(hits: 4, steps: 16, rotation: 0, lanes: 3)
        XCTAssertEqual(lanes.count, 3)
        // Every step is played by exactly one lane.
        for step in 0 ..< 16 {
            XCTAssertEqual(lanes.filter { $0[step] }.count, 1, "step \(step)")
        }
        XCTAssertEqual(hits(lanes[1]), [1, 3, 6, 9, 11, 14]) // every other rest of lane 1: 1 2 3 5 6 7 …
        XCTAssertEqual(lanes[1].filter { $0 }.count + lanes[2].filter { $0 }.count, 12)
    }

    func testInterlockEdges() {
        XCTAssertEqual(EuclidGroup.interlock(hits: 3, steps: 8, rotation: 0, lanes: 1).count, 1)
        XCTAssertTrue(EuclidGroup.interlock(hits: 3, steps: 8, rotation: 0, lanes: 0).isEmpty)
        let rotated = EuclidGroup.interlock(hits: 4, steps: 16, rotation: 2, lanes: 2)
        XCTAssertEqual(hits(rotated[0]), [2, 6, 10, 14])
        XCTAssertEqual(EuclidGroup.interlock(hits: 4, steps: 99, rotation: 0, lanes: 2)[0].count, 16)
    }

    // MARK: Random group

    func testRandomLanesHaveTheRightLengthsAndRisingHits() {
        for seed in 1 ... 30 as ClosedRange<UInt64> {
            var rng = GroupSeededGenerator(seed)
            let lanes = EuclidGroup.randomLanes(steps: [16, 16, 16, 16], using: &rng)
            XCTAssertEqual(lanes.map(\.count), [16, 16, 16, 16])
            let counts = lanes.map { $0.filter { $0 }.count }
            XCTAssertEqual(counts, [3, 5, 7, 10], "seed \(seed)") // 20, 33, 47, 60 % of 16, rounded
        }
    }

    func testSecondLaneNeverMeetsTheFirstWhenItCanAvoidIt() {
        for seed in 1 ... 50 as ClosedRange<UInt64> {
            var rng = GroupSeededGenerator(seed)
            let lanes = EuclidGroup.randomLanes(steps: [16, 16, 16], using: &rng)
            let together = zip(lanes[0], lanes[1]).filter { $0 && $1 }.count
            XCTAssertEqual(together, 0, "seed \(seed)")
        }
    }

    func testRandomLanesCopeWithDifferentLengthsAndOneLane() {
        var rng = GroupSeededGenerator(7)
        let mixed = EuclidGroup.randomLanes(steps: [16, 5, 9], using: &rng)
        XCTAssertEqual(mixed.map(\.count), [16, 5, 9])
        XCTAssertTrue(mixed.allSatisfy { $0.contains(true) })
        let single = EuclidGroup.randomLanes(steps: [2], using: &rng)
        XCTAssertEqual(single[0].filter { $0 }.count, 1)
        XCTAssertTrue(EuclidGroup.randomLanes(steps: [], using: &rng).isEmpty)
    }

    func testSameSeedSamePattern() {
        var first = GroupSeededGenerator(11)
        var second = GroupSeededGenerator(11)
        XCTAssertEqual(EuclidGroup.randomLanes(steps: [16, 16], using: &first),
                       EuclidGroup.randomLanes(steps: [16, 16], using: &second))
    }

    // MARK: Meeting points

    func testSpanIsTheLeastCommonMultipleUpToThirtyTwo() {
        XCTAssertEqual(EuclidGroup.span(ofLengths: [16, 16]), 16)
        XCTAssertEqual(EuclidGroup.span(ofLengths: [8, 16, 4]), 16)
        XCTAssertEqual(EuclidGroup.span(ofLengths: [6, 4]), 12)
        XCTAssertEqual(EuclidGroup.span(ofLengths: [7, 5]), 32) // 35, capped
        XCTAssertEqual(EuclidGroup.span(ofLengths: []), 16)
    }

    func testMeetingCountsCountTheLanesThatHit() {
        let kick = [true, false, false, false, true, false, false, false]
        let hat = [true, false, true, false, true, false, true, false]
        let counts = EuclidGroup.meetingCounts(lanes: [kick, hat], span: 8)
        XCTAssertEqual(counts, [2, 0, 1, 0, 2, 0, 1, 0])
    }

    func testAShorterLaneRepeatsAcrossTheSpan() {
        let three = [true, false, false]
        let four = [true, false, false, false]
        let counts = EuclidGroup.meetingCounts(lanes: [three, four], span: 12)
        // Lane 3 plays 0, 3, 6, 9; lane 4 plays 0, 4, 8: they meet on step 1 and again after 12.
        XCTAssertEqual(counts, [2, 0, 0, 1, 1, 0, 1, 0, 1, 1, 0, 0])
        XCTAssertEqual(EuclidGroup.meetingCounts(lanes: [three, four], span: 24).enumerated()
            .filter { $0.element == 2 }.map(\.offset), [0, 12])
        XCTAssertEqual(EuclidGroup.meetingCounts(lanes: [], span: 3), [0, 0, 0])
        XCTAssertEqual(EuclidGroup.meetingCounts(lanes: [[]], span: 2), [0, 0])
    }
}
