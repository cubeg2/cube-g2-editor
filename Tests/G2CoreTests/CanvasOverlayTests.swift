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
        let commands: [ShortcutCommand] = [.showValues, .showMorphGroups, .showKnobs, .showMidi]
        XCTAssertEqual(commands.map(\.defaultStroke?.display), ["F5", "F6", "F7", "F8"])
    }
}
