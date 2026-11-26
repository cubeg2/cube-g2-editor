// SequenceLaneSelectionTests.swift — Finder-style selection of the lanes in the All tab.

@testable import G2Core
import XCTest

final class SequenceLaneSelectionTests: XCTestCase {
    private let order = [10, 20, 30, 40, 50, 60, 70]

    private func click(_ selection: inout SequenceLaneSelection, _ id: Int, shift: Bool = false, command: Bool = false) {
        selection.click(id, order: order, shift: shift, command: command)
    }

    func testPlainClickSelectsOneAndClickingItAgainClears() {
        var selection = SequenceLaneSelection()
        click(&selection, 30)
        XCTAssertEqual(selection.selected, [30])
        XCTAssertEqual(selection.anchor, 30)
        click(&selection, 50)
        XCTAssertEqual(selection.selected, [50])
        click(&selection, 50)
        XCTAssertEqual(selection.selected, [])
        XCTAssertNil(selection.anchor)
    }

    func testCommandClickAddsAndRemovesSingleLanes() {
        var selection = SequenceLaneSelection()
        click(&selection, 10)
        click(&selection, 40, command: true)
        click(&selection, 60, command: true)
        XCTAssertEqual(selection.selected, [10, 40, 60])
        click(&selection, 40, command: true)
        XCTAssertEqual(selection.selected, [10, 60])
        XCTAssertEqual(selection.anchor, 40)
    }

    func testShiftClickSelectsEverythingBetweenTheAnchorAndTheClickedLane() {
        var selection = SequenceLaneSelection()
        click(&selection, 20)
        click(&selection, 50, shift: true)
        XCTAssertEqual(selection.selected, [20, 30, 40, 50])
        // The other way round, and the range replaces what was selected.
        click(&selection, 70)
        click(&selection, 40, shift: true)
        XCTAssertEqual(selection.selected, [40, 50, 60, 70])
    }

    func testShiftClickKeepsTheAnchorSoTheRangeCanBeMoved() {
        var selection = SequenceLaneSelection()
        click(&selection, 20)
        click(&selection, 60, shift: true)
        XCTAssertEqual(selection.selected, [20, 30, 40, 50, 60])
        click(&selection, 30, shift: true)
        XCTAssertEqual(selection.selected, [20, 30])
        XCTAssertEqual(selection.anchor, 20)
    }

    func testCommandShiftClickAddsTheRangeToTheSelection() {
        var selection = SequenceLaneSelection()
        click(&selection, 10)
        click(&selection, 40, command: true)
        click(&selection, 60, shift: true, command: true)
        XCTAssertEqual(selection.selected, [10, 40, 50, 60])
    }

    func testShiftClickWithoutAUsableAnchorActsLikeCommandClick() {
        var selection = SequenceLaneSelection()
        click(&selection, 30, shift: true)
        XCTAssertEqual(selection.selected, [30])
        XCTAssertEqual(selection.anchor, 30)
        // An anchor that is no longer in the list (the lane was removed).
        var stale = SequenceLaneSelection(selected: [99], anchor: 99)
        click(&stale, 40, shift: true)
        XCTAssertEqual(stale.selected, [99, 40])
    }

    func testSelectGroupSelectsExactlyThoseAndAnchorsOnTheFirst() {
        var selection = SequenceLaneSelection(selected: [70], anchor: 70)
        selection.select([20, 30, 40])
        XCTAssertEqual(selection.selected, [20, 30, 40])
        XCTAssertEqual(selection.anchor, 20)
        click(&selection, 60, shift: true)
        XCTAssertEqual(selection.selected, [20, 30, 40, 50, 60])
    }
}
