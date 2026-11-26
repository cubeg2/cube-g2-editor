@testable import G2Core
import XCTest

final class SequencePresetsTests: XCTestCase {
    func testEveryPresetFillsSixteenSteps() {
        for preset in SequencePresets.curves {
            XCTAssertEqual(preset.steps.count, 16, preset.name)
            XCTAssertTrue(preset.steps.allSatisfy { (0 ... 127).contains($0) }, preset.name)
        }
        for preset in SequencePresets.rhythms {
            XCTAssertEqual(preset.steps.count, 16, preset.name)
            XCTAssertEqual(preset.second.count, 16, preset.name)
        }
    }

    func testRampsRunTheWholeRange() throws {
        let up = try XCTUnwrap(SequencePresets.curves.first { $0.name == "Ramp up" })
        XCTAssertEqual(up.steps.first, 0)
        XCTAssertEqual(up.steps.last, 127)
    }

    func testNoteFigureRepeatsAboveBaseAndStaysInRange() throws {
        let major = try XCTUnwrap(SequencePresets.figures.first { $0.name == "Major arpeggio" })
        let notes = SequencePresets.notes(of: major, base: 60)
        XCTAssertEqual(Array(notes.prefix(5)), [60, 64, 67, 72, 60])
        XCTAssertEqual(SequencePresets.notes(of: major, base: 125).max(), 127)
    }

    func testEveryScaleIsAValidSetOfNotesAndEveryPresetNameIsUnique() {
        for scale in MusicalScale.allCases {
            let intervals = scale.intervals
            XCTAssertEqual(intervals.first, 0, "\(scale.title) starts on the root")
            XCTAssertEqual(intervals, intervals.sorted(), "\(scale.title) ascends")
            XCTAssertEqual(Set(intervals).count, intervals.count, "\(scale.title) has no repeated note")
            XCTAssertTrue(intervals.allSatisfy { (0 ... 11).contains($0) }, "\(scale.title) stays inside the octave")
            XCTAssertGreaterThanOrEqual(intervals.count, 5, "\(scale.title)")
        }
        XCTAssertEqual(Set(MusicalScale.allCases.map(\.title)).count, MusicalScale.allCases.count, "titles are unique")
        XCTAssertGreaterThan(MusicalScale.allCases.count, 25)
        for list in [SequencePresets.figures, SequencePresets.curves, SequencePresets.rhythms] {
            XCTAssertEqual(Set(list.map(\.name)).count, list.count, "preset names are unique (they are the menu ids)")
        }
        XCTAssertGreaterThan(SequencePresets.figures.count, 60)
        // Styles come after the main list, and every figure fits one bar and the MIDI range from a low root.
        let firstGrouped = SequencePresets.figures.firstIndex { $0.group != nil } ?? 0
        XCTAssertTrue(SequencePresets.figures[firstGrouped...].allSatisfy { $0.group != nil }, "styles are one block")
        for figure in SequencePresets.figures {
            XCTAssertFalse(figure.steps.isEmpty, figure.name)
            XCTAssertLessThanOrEqual(figure.steps.count, 16, figure.name)
            XCTAssertTrue(figure.steps.allSatisfy { (0 ... 36).contains($0) }, "\(figure.name) stays within three octaves")
        }
    }
}
