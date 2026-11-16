import G2Core
import XCTest

final class SequencePatternTests: XCTestCase {
    // MARK: - Layout

    func testLayoutMatchesModuleParameterLists() {
        // Parameter order from the module definitions (Seq1Step1…16, Seq2Step1…16, Loop, Length…).
        let note = SequencerLayout(typeID: 121)
        XCTAssertEqual(note?.kind, .note)
        XCTAssertEqual(note?.lengthIndex, 33)
        XCTAssertNil(note?.bipUniIndex)

        XCTAssertEqual(SequencerLayout(typeID: 144)?.kind, .event)
        XCTAssertEqual(SequencerLayout(typeID: 145)?.bipUniIndex, 34)
        XCTAssertEqual(SequencerLayout(typeID: 146)?.loopIndex, 32)

        let ctr = SequencerLayout(typeID: 154)
        XCTAssertEqual(ctr?.kind, .controlled)
        XCTAssertNil(ctr?.lengthIndex, "SeqCtr has no Length")
        XCTAssertEqual(ctr?.bipUniIndex, 33)

        XCTAssertNil(SequencerLayout(typeID: 92))
    }

    func testRowsAndLengthAreReadFromParameters() throws {
        let layout = try XCTUnwrap(SequencerLayout(typeID: 146))
        var parameters = Array(0 ..< 38)
        parameters[33] = 6 // Length 7
        XCTAssertEqual(layout.row(0, in: parameters), Array(0 ..< 16))
        XCTAssertEqual(layout.row(1, in: parameters), Array(16 ..< 32))
        XCTAssertEqual(layout.length(in: parameters), 7)
        XCTAssertTrue(layout.isGateRow(1))
        XCTAssertFalse(layout.isGateRow(0))
        XCTAssertTrue(try XCTUnwrap(SequencerLayout(typeID: 144)).isGateRow(0))
    }

    // MARK: - Operations

    func testRotateWrapsInsidePlayedLength() {
        XCTAssertEqual(SequencePattern.rotated([1, 2, 3, 4], by: 1), [4, 1, 2, 3])
        XCTAssertEqual(SequencePattern.rotated([1, 2, 3, 4], by: -1), [2, 3, 4, 1])
        // Steps beyond Length are not played, so they must not wander into the pattern.
        XCTAssertEqual(SequencePattern.rotated([1, 2, 3, 9], by: 1, length: 3), [3, 1, 2, 9])
    }

    func testReverseInvertTransposeDouble() {
        XCTAssertEqual(SequencePattern.reversed([1, 2, 3, 9], length: 3), [3, 2, 1, 9])
        XCTAssertEqual(SequencePattern.inverted([0, 64, 127]), [127, 63, 0])
        XCTAssertEqual(SequencePattern.invertedGates([0, 1, 1]), [1, 0, 0])
        XCTAssertEqual(SequencePattern.transposed([0, 60, 127], by: 12), [12, 72, 127])
        XCTAssertEqual(SequencePattern.doubledFirstHalf([1, 2, 3, 4]), [1, 2, 1, 2])
    }

    func testLockedStepsKeepOldValues() {
        XCTAssertEqual(SequencePattern.respectingLocks([9, 9, 9], old: [1, 2, 3], locked: [1]), [9, 2, 9])
    }

    func testClearMatchesOriginalEditor() {
        XCTAssertEqual(SequencePattern.clearedValue(kind: .note, bipolar: false), 64)
        XCTAssertEqual(SequencePattern.clearedValue(kind: .value, bipolar: true), 64)
        XCTAssertEqual(SequencePattern.clearedValue(kind: .value, bipolar: false), 0)
    }

    func testRandomStaysInRange() {
        var generator = SystemRandomNumberGenerator()
        let values = SequencePattern.randomValues(in: 48 ... 71, using: &generator)
        XCTAssertEqual(values.count, 16)
        XCTAssertTrue(values.allSatisfy { (48 ... 71).contains($0) })
    }

    func testRandomGatesFollowDensity() {
        var generator = SystemRandomNumberGenerator()
        XCTAssertEqual(SequencePattern.randomGates(density: 1, using: &generator), Array(repeating: 1, count: 16))
        XCTAssertEqual(SequencePattern.randomGates(density: 0, using: &generator), Array(repeating: 0, count: 16))
        let many = SequencePattern.randomGates(count: 4000, density: 0.25, using: &generator).reduce(0, +)
        XCTAssertTrue((800 ... 1200).contains(many), "25 % density gave \(many) of 4000")
    }

    func testMutationStepsShareLengthAndLocks() {
        var generator = SystemRandomNumberGenerator()
        XCTAssertTrue(SequencePattern.mutationSteps(length: 16, percent: 0, using: &generator).isEmpty)
        XCTAssertEqual(SequencePattern.mutationSteps(length: 16, percent: 25, using: &generator).count, 4)
        XCTAssertEqual(SequencePattern.mutationSteps(length: 16, percent: 1, using: &generator).count, 1)
        let all = SequencePattern.mutationSteps(length: 8, percent: 100, locked: [0, 3], using: &generator)
        XCTAssertEqual(all, [1, 2, 4, 5, 6, 7]) // only inside the played length, never a locked step
    }

    func testFlipAndReplaceTouchOnlyChosenSteps() {
        XCTAssertEqual(SequencePattern.flippedGates([1, 0, 1, 0], at: [0, 1]), [0, 1, 1, 0])
        XCTAssertEqual(SequencePattern.replaced([5, 6, 7], at: [1]) { 99 }, [5, 99, 7])
    }

    func testDisplayedValuesMatchTheModules() throws {
        let val = try XCTUnwrap(SequencerLayout(typeID: 145))
        let lev = try XCTUnwrap(SequencerLayout(typeID: 146))
        XCTAssertEqual(val.displayValue(73, bipolar: true), "+9")
        XCTAssertEqual(val.displayValue(0, bipolar: true), "-64")
        XCTAssertEqual(val.displayValue(64, bipolar: true), "0")
        XCTAssertEqual(val.displayValue(127, bipolar: false), "127")
        XCTAssertEqual(lev.displayValue(127, bipolar: false), "100")
        XCTAssertEqual(lev.displayValue(64, bipolar: false), "50")
        XCTAssertEqual(lev.displayValue(0, bipolar: false), "0")
    }

    func testClockGenTempoAndSwingTexts() {
        XCTAssertEqual(ClockGenSettings.bpm(forRate: 0), 24)
        XCTAssertEqual(ClockGenSettings.bpm(forRate: 32), 88)
        XCTAssertEqual(ClockGenSettings.bpm(forRate: 33), 89)
        XCTAssertEqual(ClockGenSettings.bpm(forRate: 64), 120) // default Tempo
        XCTAssertEqual(ClockGenSettings.bpm(forRate: 96), 152)
        XCTAssertEqual(ClockGenSettings.bpm(forRate: 127), 214)
        XCTAssertEqual(ClockGenSettings.swingText(0), "50.0%")
        XCTAssertEqual(ClockGenSettings.swingText(127), "75.0%")
    }

    // MARK: - Scales

    func testScaleSnapPicksNearestLowerOnTie() {
        let minor = MusicalScale.naturalMinor
        XCTAssertTrue(minor.contains(57, root: 9)) // A3 in A minor
        XCTAssertFalse(minor.contains(58, root: 9)) // A#3
        XCTAssertEqual(minor.snapped(58, root: 9), 57) // between A and B → A
        XCTAssertEqual(MusicalScale.major.snapped(61, root: 0), 60) // C# → C
        XCTAssertEqual(MusicalScale.majorPentatonic.notes(in: 60 ... 72, root: 0), [60, 62, 64, 67, 69, 72])
    }

    // MARK: - Euclid

    func testEuclideanPatterns() {
        func text(_ pattern: [Bool]) -> String {
            String(pattern.map { $0 ? "x" : "." })
        }
        XCTAssertEqual(text(EuclideanRhythm.pattern(hits: 3, steps: 8)), "x..x..x.") // tresillo
        XCTAssertEqual(text(EuclideanRhythm.pattern(hits: 4, steps: 16)), "x...x...x...x...")
        XCTAssertEqual(text(EuclideanRhythm.pattern(hits: 2, steps: 16, rotation: 4)), "....x.......x...")
        XCTAssertEqual(text(EuclideanRhythm.pattern(hits: 0, steps: 4)), "....")
        XCTAssertEqual(text(EuclideanRhythm.pattern(hits: 9, steps: 4)), "xxxx")
        XCTAssertEqual(EuclideanRhythm.pattern(hits: 5, steps: 16).filter { $0 }.count, 5)
    }

    func testRecognizeReadsBackEveryEuclideanRhythm() throws {
        for steps in 1 ... 16 {
            for hits in 0 ... steps {
                for rotation in 0 ..< steps {
                    let gates = EuclideanRhythm.pattern(hits: hits, steps: steps, rotation: rotation)
                    let found = try XCTUnwrap(EuclideanRhythm.recognize(gates), "E(\(hits),\(steps)) r\(rotation)")
                    XCTAssertEqual(found.hits, hits)
                    // The smallest equivalent rotation: E(4,16) r4 is the same rhythm as r0.
                    XCTAssertEqual(EuclideanRhythm.pattern(hits: found.hits, steps: steps, rotation: found.rotation), gates)
                    XCTAssertLessThanOrEqual(found.rotation, rotation)
                }
            }
        }
    }

    func testRecognizeRejectsHandMadeRhythms() {
        let clustered = [true, true, true, false, false, false, false, false] // 3 hits in a row
        XCTAssertNil(EuclideanRhythm.recognize(clustered))
        var tresillo = EuclideanRhythm.pattern(hits: 3, steps: 8)
        tresillo[1].toggle() // one step toggled by hand
        XCTAssertNil(EuclideanRhythm.recognize(tresillo))
        XCTAssertNil(EuclideanRhythm.recognize([]))
    }
}

final class SequencerClockGroupTests: XCTestCase {
    private func module(_ id: Int, _ typeID: Int) -> G2Module {
        var module = G2Module(id: id, typeID: typeID, area: .voice)
        module.parameters = Array(repeating: 0, count: 40)
        return module
    }

    func testSequencersAreGroupedByTheClockBehindTheirClkInput() throws {
        let clkGen = try XCTUnwrap(ModuleDatabase.all.first { $0.shortName == "ClkGen" }).id
        var patch = G2Patch()
        // 1 = ClkGen, 2 and 3 = SeqEvent (3 takes Clk from 2's input), 4 = SeqCtr, 5 = SeqLev unplugged.
        patch.voiceModules = [module(1, clkGen), module(2, 144), module(3, 144), module(4, 154), module(5, 146)]
        patch.voiceCables = [
            G2Cable(fromModule: 1, fromConnector: 0, toModule: 2, toConnector: 0, color: .yellow, area: .voice),
            // Input-to-input: stored the other way round — `from` takes the signal of `to`.
            G2Cable(fromModule: 3, fromConnector: 0, toModule: 2, toConnector: 0, color: .yellow, area: .voice,
                    sourceIsOutput: false),
        ]

        let groups = SequencerClockGroup.groups(in: patch, area: .voice)

        XCTAssertEqual(groups, [
            SequencerClockGroup(clockModuleID: 1, sequencerIDs: [2, 3]),
            SequencerClockGroup(clockModuleID: nil, sequencerIDs: [4, 5]),
        ])
    }
}
