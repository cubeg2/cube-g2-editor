// SequenceCurveTests.swift — the curve generator for SeqVal / SeqLev / SeqCtr.

@testable import G2Core
import XCTest

private struct CurveSeededGenerator: RandomNumberGenerator {
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

final class SequenceCurveTests: XCTestCase {
    private func make(_ shape: SequenceCurve, length: Int = 16, cycles: Int = 1, phase: Int = 0,
                      low: Int = 0, high: Int = 100, count: Int = 16, seed: UInt64 = 1) -> [Int]
    {
        var rng = CurveSeededGenerator(seed)
        return shape.values(count: count, length: length, cycles: cycles, phase: phase,
                            low: low, high: high, using: &rng)
    }

    func testEveryShapeGivesSixteenValuesInsideTheRange() {
        for shape in SequenceCurve.allCases {
            for seed in 1 ... 10 as ClosedRange<UInt64> {
                let values = make(shape, cycles: 2, phase: 3, low: 10, high: 90, seed: seed)
                XCTAssertEqual(values.count, 16, shape.title)
                let floor = Int((0.10 * 127).rounded()), ceiling = Int((0.90 * 127).rounded())
                XCTAssertTrue(values.allSatisfy { (floor ... ceiling).contains($0) }, "\(shape.title) \(values)")
            }
        }
    }

    func testSineStartsInTheMiddleAndPeaksAtAQuarter() {
        let sine = make(.sine)
        XCTAssertEqual(sine[0], 64) // 0.5 of 127
        XCTAssertEqual(sine[4], 127)
        XCTAssertEqual(sine[12], 0)
    }

    func testTriangleAndSaw() {
        let triangle = make(.triangle)
        XCTAssertEqual(triangle[0], 0)
        XCTAssertEqual(triangle[8], 127)
        XCTAssertEqual(triangle[4], triangle[12])
        let up = make(.sawUp)
        XCTAssertEqual(up, up.sorted())
        XCTAssertEqual(up[0], 0)
        let down = make(.sawDown)
        XCTAssertEqual(down, down.sorted(by: >))
        XCTAssertEqual(down[0], 127)
        XCTAssertGreaterThan(down[0], down[15])
    }

    func testSquareIsHighForHalfTheSteps() {
        let square = make(.square)
        XCTAssertEqual(Array(square[0 ..< 8]), Array(repeating: 127, count: 8))
        XCTAssertEqual(Array(square[8 ..< 16]), Array(repeating: 0, count: 8))
    }

    func testCyclesRepeatTheShape() {
        let two = make(.sawUp, cycles: 2)
        XCTAssertEqual(Array(two[0 ..< 8]), Array(two[8 ..< 16]))
        let four = make(.square, cycles: 4)
        XCTAssertEqual(four, [127, 127, 0, 0, 127, 127, 0, 0, 127, 127, 0, 0, 127, 127, 0, 0])
        XCTAssertEqual(make(.sawUp, cycles: 99), make(.sawUp, cycles: 4))
    }

    func testPhaseMovesTheShapeAlong() {
        let plain = make(.sawUp)
        let moved = make(.sawUp, phase: 4)
        XCTAssertEqual(moved[0], plain[4])
        XCTAssertEqual(moved[12], plain[0])
        XCTAssertEqual(make(.sawUp, phase: 16), plain)
        XCTAssertEqual(make(.sawUp, phase: -4)[4], plain[0])
    }

    func testLowAndHighSetTheEnds() {
        let square = make(.square, low: 25, high: 75)
        XCTAssertEqual(square[0], Int((0.75 * 127).rounded()))
        XCTAssertEqual(square[8], Int((0.25 * 127).rounded()))
        XCTAssertEqual(make(.square, low: 75, high: 25), square) // swapped
        XCTAssertEqual(Set(make(.square, low: 50, high: 50)).count, 1) // flat
    }

    func testStepsAfterTheLengthRepeatTheShape() {
        let values = make(.sawUp, length: 4)
        XCTAssertEqual(Array(values[0 ..< 4]), Array(values[4 ..< 8]))
        XCTAssertEqual(Array(values[0 ..< 4]), Array(values[12 ..< 16]))
        XCTAssertEqual(make(.sawUp, length: 99), make(.sawUp)) // up to 16
        XCTAssertEqual(make(.sawUp, length: 0).count, 16)
    }

    func testGrooveAccentsTheBeats() {
        let groove = make(.groove)
        XCTAssertEqual(groove[0], 127)
        XCTAssertEqual(groove[4], 127)
        XCTAssertEqual(groove[2], Int((0.7 * 127).rounded()))
        XCTAssertEqual(groove[1], Int((0.45 * 127).rounded()))
        XCTAssertEqual(make(.groove, cycles: 3), groove) // Cycles is ignored
    }

    func testSampleAndHoldHoldsForFourStepsPerCycle() {
        for seed in 1 ... 20 as ClosedRange<UInt64> {
            let values = make(.sampleAndHold, seed: seed)
            for block in 0 ..< 4 {
                XCTAssertEqual(Set(values[block * 4 ..< block * 4 + 4]).count, 1, "seed \(seed) block \(block)")
            }
        }
        let faster = make(.sampleAndHold, cycles: 4, seed: 3) // 16 segments of one step
        XCTAssertEqual(faster.count, 16)
    }

    func testRandomShapesRepeatForTheSameSeedAndDifferOtherwise() {
        for shape in [SequenceCurve.smoothRandom, .sampleAndHold] {
            XCTAssertEqual(make(shape, seed: 5), make(shape, seed: 5))
            XCTAssertNotEqual(make(shape, seed: 5), make(shape, seed: 6))
        }
    }

    func testSmoothRandomMovesGentlyBetweenNeighbours() {
        for seed in 1 ... 20 as ClosedRange<UInt64> {
            let values = make(.smoothRandom, seed: seed)
            for pair in zip(values, values.dropFirst()) {
                XCTAssertLessThanOrEqual(abs(pair.0 - pair.1), 127 * 6 / 10, "seed \(seed)")
            }
        }
    }
}
