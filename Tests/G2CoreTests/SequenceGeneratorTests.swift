// SequenceGeneratorTests.swift — Markov / Walk / Motif note generators of the Sequence Editor.

@testable import G2Core
import XCTest

/// Small deterministic generator, so the tests repeat exactly.
private struct SeededGenerator: RandomNumberGenerator {
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

final class SequenceGeneratorTests: XCTestCase {
    private let range = 48 ... 72

    private func generate(_ kind: SequenceGenerator, current: [Int] = Array(repeating: 64, count: 16),
                          scale: MusicalScale? = nil, seed: UInt64) -> [Int]
    {
        var rng = SeededGenerator(seed)
        return kind.notes(current: current, length: 16, range: range, scale: scale, root: 0, using: &rng)
    }

    func testEveryGeneratorGivesSixteenNotesInsideTheRange() {
        for kind in SequenceGenerator.allCases {
            for seed in 1 ... 20 as ClosedRange<UInt64> {
                let notes = generate(kind, current: [60, 62, 64, 67, 60, 62, 64, 67, 60, 62, 64, 67, 60, 62, 64, 67],
                                     seed: seed)
                XCTAssertEqual(notes.count, 16, "\(kind)")
                XCTAssertTrue(notes.allSatisfy { range.contains($0) || [60, 62, 64, 67].contains($0) }, "\(kind)")
            }
        }
    }

    func testWalkAndMotifStayInTheScale() {
        for kind in [SequenceGenerator.walk, .motif] {
            for seed in 1 ... 30 as ClosedRange<UInt64> {
                let notes = generate(kind, scale: .minorPentatonic, seed: seed)
                XCTAssertTrue(notes.allSatisfy { MusicalScale.minorPentatonic.contains($0, root: 0) && range.contains($0) },
                              "\(kind) seed \(seed)")
            }
        }
    }

    func testWalkMovesByAtMostTwoScaleDegrees() {
        let pool = SequenceGenerator.pool(range: range, scale: .major, root: 0)
        for seed in 1 ... 30 as ClosedRange<UInt64> {
            let notes = generate(.walk, scale: .major, seed: seed)
            for pair in zip(notes, notes.dropFirst()) {
                let distance = abs((pool.firstIndex(of: pair.0) ?? 0) - (pool.firstIndex(of: pair.1) ?? 0))
                XCTAssertLessThanOrEqual(distance, 2, "seed \(seed)")
            }
        }
    }

    func testMarkovOnlyUsesNotesOfTheSourceAndFollowsItsMoves() {
        let source = [60, 64, 67, 64, 60, 64, 67, 64, 60, 64, 67, 64, 60, 64, 67, 64]
        // In this source 60 is always followed by 64 and 67 by 64.
        for seed in 1 ... 30 as ClosedRange<UInt64> {
            let notes = generate(.markov, current: source, seed: seed)
            XCTAssertTrue(notes.allSatisfy { [60, 64, 67].contains($0) }, "seed \(seed)")
            for pair in zip(notes, notes.dropFirst()) where pair.0 == 60 || pair.0 == 67 {
                XCTAssertEqual(pair.1, 64, "seed \(seed)")
            }
        }
    }

    func testMarkovSnapsToTheScale() {
        let source = [60, 61, 63, 66, 60, 61, 63, 66, 60, 61, 63, 66, 60, 61, 63, 66]
        let notes = generate(.markov, current: source, scale: .majorPentatonic, seed: 3)
        XCTAssertTrue(notes.allSatisfy { MusicalScale.majorPentatonic.contains($0, root: 0) })
    }

    func testMarkovWithNothingToLearnFallsBackToWalk() {
        let notes = generate(.markov, current: Array(repeating: 64, count: 16), scale: .major, seed: 5)
        XCTAssertEqual(notes.count, 16)
        XCTAssertTrue(notes.allSatisfy { MusicalScale.major.contains($0, root: 0) && range.contains($0) })
    }

    func testMarkovOnlyLearnsFromTheStepsThePatternPlays() {
        // Steps 5–16 hold 99, but the pattern is 4 steps long, so 99 must never come out.
        let source = [60, 62, 64, 65] + Array(repeating: 99, count: 12)
        var rng = SeededGenerator(9)
        let notes = SequenceGenerator.markov.notes(current: source, length: 4, range: range, scale: nil,
                                                   root: 0, using: &rng)
        XCTAssertFalse(notes.contains(99))
    }

    func testMotifRepeatsItsFirstFigure() {
        var rng = SeededGenerator(11)
        let pool = SequenceGenerator.pool(range: range, scale: .minorPentatonic, root: 0)
        let notes = SequenceGenerator.motif(count: 16, pool: pool, variation: 0, using: &rng)
        XCTAssertEqual(Array(notes[0 ..< 4]), Array(notes[4 ..< 8]))
        XCTAssertEqual(Array(notes[0 ..< 4]), Array(notes[12 ..< 16]))
    }

    func testMotifVariationChangesLaterPassesButNotTheFirst() {
        var plain = SeededGenerator(13)
        var varied = SeededGenerator(13)
        let pool = SequenceGenerator.pool(range: range, scale: .major, root: 0)
        let straight = SequenceGenerator.motif(count: 16, pool: pool, variation: 0, using: &plain)
        let changed = SequenceGenerator.motif(count: 16, pool: pool, variation: 1, using: &varied)
        XCTAssertEqual(Array(changed[0 ..< 4]), Array(straight[0 ..< 4]))
        XCTAssertNotEqual(changed, straight)
    }

    func testBouncedReflectsAtBothEnds() {
        XCTAssertEqual(SequenceGenerator.bounced(-1, count: 5), 1)
        XCTAssertEqual(SequenceGenerator.bounced(5, count: 5), 3)
        XCTAssertEqual(SequenceGenerator.bounced(2, count: 5), 2)
        XCTAssertEqual(SequenceGenerator.bounced(3, count: 1), 0)
    }

    func testSameSeedGivesSamePattern() {
        XCTAssertEqual(generate(.walk, seed: 42), generate(.walk, seed: 42))
        XCTAssertNotEqual(generate(.walk, seed: 42), generate(.walk, seed: 43))
    }
}
