// SlotPatchDragTests.swift
// The text a Patches panel row puts on the drag pasteboard for the slot buttons.

@testable import G2EditorCore
import XCTest

final class SlotPatchDragTests: XCTestCase {
    func testPayloadRoundTrip() {
        let file = SlotPatchDrag.file(URL(fileURLWithPath: "/Users/someone/Patches: new/Żuk bass.pch2"))
        XCTAssertEqual(SlotPatchDrag(payload: file.payload), file)
        let bank = SlotPatchDrag.bankEntry(id: "0-3-17")
        XCTAssertEqual(SlotPatchDrag(payload: bank.payload), bank)
    }

    /// Other drags use text too: a library module (its type number), a block, selected
    /// modules, a Mutator box. A slot button must ignore all of them.
    func testOtherTextDragsAreNotPatches() {
        for foreign in ["12", "g2-building-block:/tmp/a.pch2", "g2-module-selection:ABC", "0:3", ""] {
            XCTAssertNil(SlotPatchDrag(payload: foreign), foreign)
        }
    }
}
