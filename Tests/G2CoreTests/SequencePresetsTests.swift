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
}
