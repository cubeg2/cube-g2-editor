// CanvasOverlayTests.swift
// Nakładki F5–F8 („View Parameter Values", „View Morph Groups", „View Knob
// Assignments", „View MIDI CC# Assignments" — instrukcja Clavii, str. 132).

@testable import G2EditorCore
import XCTest

@MainActor
final class CanvasOverlayTests: XCTestCase {
    func testTheSameKeyTurnsAnOverlayOnAndOff() {
        let view = CanvasViewState()
        XCTAssertEqual(view.overlayMode, .none)

        view.toggleOverlay(.values)
        XCTAssertEqual(view.overlayMode, .values)

        view.toggleOverlay(.values)
        XCTAssertEqual(view.overlayMode, .none)
    }

    func testAnotherKeySwapsTheOverlayInsteadOfStacking() {
        let view = CanvasViewState()
        view.toggleOverlay(.morphGroups)
        view.toggleOverlay(.midiControllers)
        XCTAssertEqual(view.overlayMode, .midiControllers)
    }

    /// Numery klawiszy muszą się zgadzać z tabelą na str. 132.
    func testFunctionKeysMatchTheManual() {
        XCTAssertEqual(CanvasOverlayMode.values.functionKey, 5)
        XCTAssertEqual(CanvasOverlayMode.morphGroups.functionKey, 6)
        XCTAssertEqual(CanvasOverlayMode.knobAssignments.functionKey, 7)
        XCTAssertEqual(CanvasOverlayMode.midiControllers.functionKey, 8)
        XCTAssertNil(CanvasOverlayMode.none.functionKey)
    }
}
