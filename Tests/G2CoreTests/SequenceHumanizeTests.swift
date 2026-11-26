// SequenceHumanizeTests.swift — value jitter for SeqVal / SeqLev / SeqCtr.

@testable import G2Core
import XCTest

private struct HumanSeededGenerator: RandomNumberGenerator {
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

final class SequenceHumanizeTests: XCTestCase {
    private let values = Array(repeating: 64, count: 16)
    private let allPlaying = Array(repeating: true, count: 16)

    private func jitter(_ values: [Int]? = nil, playing: [Bool]? = nil, length: Int = 16, amount: Int,
                        seed: UInt64 = 1) -> [Int]
    {
        var rng = HumanSeededGenerator(seed)
        return SequenceHumanize.jittered(values ?? self.values, playing: playing ?? allPlaying, length: length,
                                         amount: amount, using: &rng)
    }

    func testSpreadIsAShareOfHalfTheRange() {
        XCTAssertEqual(SequenceHumanize.spread(amount: 0), 0)
        XCTAssertEqual(SequenceHumanize.spread(amount: 10), 6) // 6.35
        XCTAssertEqual(SequenceHumanize.spread(amount: 100), 64)
        XCTAssertEqual(SequenceHumanize.spread(amount: 500), 64)
        XCTAssertEqual(SequenceHumanize.spread(amount: -5), 0)
    }

    func testZeroAmountChangesNothing() {
        XCTAssertEqual(jitter(amount: 0), values)
    }

    func testEveryPlayingStepStaysWithinTheSpread() {
        let reach = SequenceHumanize.spread(amount: 20)
        for seed in 1 ... 30 as ClosedRange<UInt64> {
            let result = jitter(amount: 20, seed: seed)
            XCTAssertEqual(result.count, 16)
            XCTAssertTrue(result.allSatisfy { abs($0 - 64) <= reach }, "seed \(seed)")
        }
    }

    func testSomethingActuallyMoves() {
        let result = jitter(amount: 30)
        XCTAssertNotEqual(result, values)
        XCTAssertGreaterThan(Set(result).count, 3)
    }

    func testRestingStepsAndStepsAfterTheLengthStay() {
        var playing = allPlaying
        playing[2] = false
        playing[5] = false
        let result = jitter(playing: playing, length: 8, amount: 50)
        XCTAssertEqual(result[2], 64)
        XCTAssertEqual(result[5], 64)
        XCTAssertEqual(Array(result[8...]), Array(repeating: 64, count: 8))
    }

    func testValuesStayInsideZeroTo127() {
        for seed in 1 ... 30 as ClosedRange<UInt64> {
            let edges = [0, 127] + Array(repeating: 1, count: 14)
            let result = jitter(edges, amount: 100, seed: seed)
            XCTAssertTrue(result.allSatisfy { (0 ... 127).contains($0) }, "seed \(seed)")
        }
    }

    func testSmallNudgesAreLikelierThanBigOnes() {
        var small = 0, big = 0
        let reach = SequenceHumanize.spread(amount: 40)
        for seed in 1 ... 200 as ClosedRange<UInt64> {
            for value in jitter(amount: 40, seed: seed) {
                abs(value - 64) <= reach / 2 ? (small += 1) : (big += 1)
            }
        }
        XCTAssertGreaterThan(small, big * 2)
    }

    func testSameSeedSameResultAndShortLists() {
        XCTAssertEqual(jitter(amount: 25, seed: 4), jitter(amount: 25, seed: 4))
        XCTAssertNotEqual(jitter(amount: 25, seed: 4), jitter(amount: 25, seed: 5))
        // A flag list shorter than the values leaves the extra steps alone.
        let result = jitter(playing: [true, true], amount: 50)
        XCTAssertEqual(Array(result[2...]), Array(repeating: 64, count: 14))
    }
}
