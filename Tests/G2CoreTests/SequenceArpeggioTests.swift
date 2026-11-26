// SequenceArpeggioTests.swift — chord types, scale chords and the arpeggio order of the Sequence Editor.

@testable import G2Core
import XCTest

private struct ArpSeededGenerator: RandomNumberGenerator {
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

final class SequenceArpeggioTests: XCTestCase {
    private func steps(_ chord: [Int], _ direction: ArpeggioDirection, octaves: Int = 1,
                       count: Int = 16, seed: UInt64 = 1) -> [Int]
    {
        var rng = ArpSeededGenerator(seed)
        return SequenceArpeggio.steps(chord: chord, direction: direction, octaves: octaves,
                                      count: count, using: &rng)
    }

    func testChordTypesBuildOnTheRoot() {
        XCTAssertEqual(SequenceArpeggio.notes(of: .major, root: 60), [60, 64, 67])
        XCTAssertEqual(SequenceArpeggio.notes(of: .minor7, root: 57), [57, 60, 64, 67])
        XCTAssertEqual(SequenceArpeggio.notes(of: .major, root: 126), [126]) // 130 and 133 are out of range
    }

    func testEveryChordTypeIsRecognisedFromItsOwnIntervals() {
        for type in ChordType.allCases {
            XCTAssertEqual(ChordType.recognize(type.intervals), type)
        }
        XCTAssertNil(ChordType.recognize([0, 1, 2]))
    }

    func testUpAndDownRepeatTheChord() {
        XCTAssertEqual(steps([60, 64, 67], .up, count: 7), [60, 64, 67, 60, 64, 67, 60])
        XCTAssertEqual(steps([60, 64, 67], .down, count: 7), [67, 64, 60, 67, 64, 60, 67])
    }

    func testUpDownPlaysTheTurningPointsOnce() {
        XCTAssertEqual(steps([60, 64, 67], .upDown, count: 8), [60, 64, 67, 64, 60, 64, 67, 64])
        XCTAssertEqual(steps([60, 64, 67], .downUp, count: 8), [67, 64, 60, 64, 67, 64, 60, 64])
        XCTAssertEqual(steps([60, 67], .upDown, count: 5), [60, 67, 60, 67, 60])
    }

    func testOctavesStackTheChordUpwards() {
        XCTAssertEqual(steps([60, 64, 67], .up, octaves: 2, count: 7), [60, 64, 67, 72, 76, 79, 60])
        XCTAssertEqual(steps([60, 64, 67], .up, octaves: 9, count: 10).max(), 91) // three at most
    }

    func testNotesAbove127AreLeftOut() {
        let result = steps([120, 124, 127], .up, octaves: 3, count: 16)
        XCTAssertTrue(result.allSatisfy { $0 <= 127 })
        XCTAssertEqual(Set(result), [120, 124, 127])
    }

    func testRandomStaysInTheChordAndNeverRepeatsANote() {
        for seed in 1 ... 30 as ClosedRange<UInt64> {
            let result = steps([60, 64, 67], .random, octaves: 2, seed: seed)
            XCTAssertEqual(result.count, 16)
            XCTAssertTrue(result.allSatisfy { [60, 64, 67, 72, 76, 79].contains($0) })
            for pair in zip(result, result.dropFirst()) {
                XCTAssertNotEqual(pair.0, pair.1, "seed \(seed)")
            }
        }
    }

    func testSingleNoteAndEmptyChord() {
        XCTAssertEqual(steps([62], .upDown, count: 3), [62, 62, 62])
        XCTAssertEqual(steps([62], .random, count: 3), [62, 62, 62])
        XCTAssertEqual(steps([], .up), [])
    }

    func testScaleChordsInCMajor() {
        func chord(_ degree: Int, seventh: Bool = false) -> [Int] {
            SequenceArpeggio.scaleChord(degree: degree, seventh: seventh, scale: .major, root: 0, base: 48)
        }
        XCTAssertEqual(chord(0), [48, 52, 55]) // C
        XCTAssertEqual(chord(1), [50, 53, 57]) // Dm
        XCTAssertEqual(chord(4), [55, 59, 62]) // G
        XCTAssertEqual(chord(6), [59, 62, 65]) // Bdim
        XCTAssertEqual(chord(4, seventh: true), [55, 59, 62, 65]) // G7
        XCTAssertEqual(chord(0, seventh: true), [48, 52, 55, 59]) // Cmaj7
    }

    func testScaleChordsFollowRootAndScale() {
        // A natural minor: first degree is A (57), the chord is A C E.
        XCTAssertEqual(SequenceArpeggio.scaleChord(degree: 0, seventh: false, scale: .naturalMinor, root: 9, base: 57),
                       [57, 60, 64])
        // Chromatic has no degrees and reads as major.
        XCTAssertEqual(SequenceArpeggio.scaleChord(degree: 1, seventh: false, scale: .chromatic, root: 0, base: 48),
                       [50, 53, 57])
    }

    func testScaleChordRunningOutOfNotesIsEmpty() {
        XCTAssertEqual(SequenceArpeggio.scaleChord(degree: 0, seventh: true, scale: .major, root: 0, base: 125), [])
    }

    func testScaleChordNames() {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        func name(_ degree: Int, seventh: Bool = false) -> String {
            SequenceArpeggio.scaleChordName(degree: degree, seventh: seventh, scale: .major, root: 0) { names[$0] }
        }
        XCTAssertEqual(name(0), "C")
        XCTAssertEqual(name(1), "Dm")
        XCTAssertEqual(name(6), "Bdim")
        XCTAssertEqual(name(4, seventh: true), "G7")
        XCTAssertEqual(name(0, seventh: true), "Cmaj7")
        XCTAssertEqual(name(1, seventh: true), "Dm7")
        XCTAssertEqual(name(6, seventh: true), "Bm7♭5")
    }

    func testDegreeCount() {
        XCTAssertEqual(SequenceArpeggio.degreeCount(of: .major), 7)
        XCTAssertEqual(SequenceArpeggio.degreeCount(of: .minorPentatonic), 5)
        XCTAssertEqual(SequenceArpeggio.degreeCount(of: .chromatic), 7)
    }
}
