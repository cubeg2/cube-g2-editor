// SequenceRhythmBankTests.swift — the 16-step rhythm bank of the Presets menu.

@testable import G2Core
import XCTest

final class SequenceRhythmBankTests: XCTestCase {
    func testBankHasAHundredAndTwentyTwoPatternsOfSixteenSteps() {
        XCTAssertEqual(SequenceRhythmBank.patterns.count, 122)
        for (index, pattern) in SequenceRhythmBank.patterns.enumerated() {
            XCTAssertEqual(pattern.count, SequencerLayout.steps, "pattern \(index + 1)")
            XCTAssertTrue(pattern.allSatisfy { $0 == "x" || $0 == "-" }, "pattern \(index + 1)")
        }
    }

    func testEveryPatternStartsOnTheFirstStepAndHasRests() {
        for (index, pattern) in SequenceRhythmBank.patterns.enumerated() {
            XCTAssertEqual(pattern.first, "x", "pattern \(index + 1)")
            XCTAssertTrue(pattern.contains("-"), "pattern \(index + 1)")
        }
    }

    func testNoPatternIsListedTwice() {
        let patterns = SequenceRhythmBank.patterns
        XCTAssertEqual(Set(patterns).count, patterns.count)
    }

    func testFlagsFollowThePattern() {
        XCTAssertEqual(SequenceRhythmBank.flags(at: 0), [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0])
        XCTAssertEqual(SequenceRhythmBank.flags(at: 2), [1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0])
        XCTAssertEqual(SequenceRhythmBank.flags(at: 999), [])
        XCTAssertEqual(SequenceRhythmBank.flags(at: -1), [])
    }

    func testLabelShowsNumberAndBeats() {
        XCTAssertEqual(SequenceRhythmBank.label(at: 0), "1   ■··· ■··· ■··· ■···")
        XCTAssertEqual(SequenceRhythmBank.label(at: 1), "2   ■··■ ··■· ·■·· ■··■")
        XCTAssertEqual(SequenceRhythmBank.label(at: 500), "")
    }

    func testPagesSplitTheListsByTwenty() {
        let pages = SequenceRhythmBank.pages(of: Array(0 ..< 122))
        XCTAssertEqual(pages.first, Array(0 ..< 20))
        XCTAssertEqual(pages.last, [120, 121])
        XCTAssertEqual(pages.reduce(0) { $0 + $1.count }, 122)
        XCTAssertEqual(SequenceRhythmBank.pages(of: []), [])
    }

    func testEveryPatternHasExactlyOneRole() {
        var seen: [Int] = []
        for role in SequenceRhythmBank.Role.allCases {
            let indices = SequenceRhythmBank.indices(of: role)
            XCTAssertFalse(indices.isEmpty, "\(role)")
            seen += indices
        }
        XCTAssertEqual(seen.sorted(), Array(0 ..< SequenceRhythmBank.patterns.count))
        XCTAssertNil(SequenceRhythmBank.role(at: 999))
    }

    func testRolesFollowTheRules() {
        func role(_ pattern: String) -> SequenceRhythmBank.Role? {
            SequenceRhythmBank.patterns.firstIndex(of: pattern).flatMap { SequenceRhythmBank.role(at: $0) }
        }
        XCTAssertEqual(role("x---x---x---x---"), .kick) // four on the floor
        XCTAssertEqual(role("x---x--x-x--x---"), .snare) // backbeat 5 and 13, no 9
        XCTAssertEqual(role("x-x-x-x-x-x-x-x-"), .hat) // straight eighths, 8 hits
        XCTAssertEqual(role("x--x--x--x--x--x"), .hat) // syncopated
        XCTAssertEqual(role("x---x--x---x--x-"), .percussion) // anchored on 1 and 5, 12 is off
    }
}
