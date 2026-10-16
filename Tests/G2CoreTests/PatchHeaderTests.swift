// PatchHeaderTests.swift
// Nazwa, kategoria i tryb głosów — trzy pola, które instrukcja Clavii trzyma
// w pasku narzędzi (str. 61–62).

import G2Core
@testable import G2EditorCore
import XCTest

final class VoiceModeTests: XCTestCase {
    /// Układ z BVerhue (`bidVoicesChangeValue` i odczyt `VoiceCount + 1 - MonoPoly`):
    /// 0 = Legato, 1 = Mono, 2…32 = polifonia (wartość − 1 głosów).
    func testIndexRoundTripsThroughTheHeaderFields() {
        for index in G2VoiceMode.minIndex ... G2VoiceMode.maxIndex {
            let fields = G2VoiceMode.fields(index: index)
            XCTAssertEqual(G2VoiceMode.index(voices: fields.voices, monopoly: fields.monopoly),
                           index, "pozycja \(index)")
        }
    }

    func testLegatoAndMonoMapToTheDocumentedFields() {
        XCTAssertEqual(G2VoiceMode.fields(index: 0).monopoly, 2)
        XCTAssertEqual(G2VoiceMode.fields(index: 0).voices, 1)
        XCTAssertEqual(G2VoiceMode.fields(index: 1).monopoly, 1)
        XCTAssertEqual(G2VoiceMode.fields(index: 1).voices, 1)
        XCTAssertEqual(G2VoiceMode.label(index: 0), "Legato")
        XCTAssertEqual(G2VoiceMode.label(index: 1), "Mono")
    }

    /// Pole `voices` ma pięć bitów, więc najwyższa polifonia to 31 głosów.
    func testHighestPolyphonyFitsTheFiveBitField() {
        let fields = G2VoiceMode.fields(index: G2VoiceMode.maxIndex)
        XCTAssertEqual(fields.voices, 31)
        XCTAssertEqual(fields.monopoly, 0)
        XCTAssertEqual(G2VoiceMode.label(index: G2VoiceMode.maxIndex), "31")
    }
}

final class PatchNameSanitizerTests: XCTestCase {
    /// Instrukcja: „Any 'illegal' characters that you may type will be substituted
    /// with empty spaces."
    func testIllegalCharactersBecomeSpaces() {
        XCTAssertEqual(G2PatchName.sanitized("Bąk\tPad"), "B k Pad")
    }

    func testNameIsCutToSixteenCharacters() {
        XCTAssertEqual(G2PatchName.sanitized("ABCDEFGHIJKLMNOPQRSTU").count, 16)
    }

    func testOrdinaryNamePassesThrough() {
        XCTAssertEqual(G2PatchName.sanitized("Fat Bass 2"), "Fat Bass 2")
    }
}

final class PatchCategoryTests: XCTestCase {
    /// Numeracja za g2ools `g2categories` i BVerhue `CATEGORIES` — oba zgodne.
    func testCategoryNumbersMatchTheReference() {
        XCTAssertEqual(G2PatchCategory.name(0), "None")
        XCTAssertEqual(G2PatchCategory.name(1), "Acoustic")
        XCTAssertEqual(G2PatchCategory.name(13), "Audio In")
        XCTAssertEqual(G2PatchCategory.name(15), "User2")
        XCTAssertEqual(G2PatchCategory.names.count, 16, "13 kategorii + 2 użytkownika + None")
    }
}

@MainActor
final class PatchHeaderStateTests: XCTestCase {
    private func makeState() -> PatchState {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        state.slots = [G2Patch()]
        return state
    }

    private func undoStep(on state: PatchState, _ action: () -> Void) {
        state.undoManager.beginUndoGrouping()
        action()
        state.undoManager.endUndoGrouping()
    }

    func testRenamingSanitizesAndIsUndoable() {
        let state = makeState()
        state.slots[0].name = "Old"
        undoStep(on: state) { state.setPatchName("New\u{00A0}Name") }
        XCTAssertEqual(state.patch.name, "New Name")

        state.undoManager.undo()
        XCTAssertEqual(state.patch.name, "Old")
    }

    /// W performance nazwa należy do slotu — instrukcja opisuje to jako
    /// „Renaming single patches in Performances" (str. 97).
    func testRenamingAlsoUpdatesThePerformanceSlot() {
        let state = makeState()
        state.slots = [G2Patch(), G2Patch()]
        state.selectedSlot = 1
        undoStep(on: state) { state.setPatchName("Slot B") }

        XCTAssertEqual(state.performance.slots[1].name, "Slot B")
        XCTAssertEqual(state.performance.slots[0].name, "")
    }

    func testVoiceModeWritesBothHeaderFields() {
        let state = makeState()
        undoStep(on: state) { state.setVoiceMode(index: 9) }
        XCTAssertEqual(state.patch.description.voices, 8)
        XCTAssertEqual(state.patch.description.monopoly, 0)

        undoStep(on: state) { state.setVoiceMode(index: 0) }
        XCTAssertEqual(state.patch.description.monopoly, 2)
        XCTAssertEqual(state.voiceModeIndex, 0)

        state.undoManager.undo()
        XCTAssertEqual(state.voiceModeIndex, 9)
    }

    func testCategoryRefusesNumbersOutsideTheTable() {
        let state = makeState()
        undoStep(on: state) { state.setCategory(99) }
        XCTAssertEqual(state.patch.description.category, 0)

        undoStep(on: state) { state.setCategory(3) }
        XCTAssertEqual(state.patch.description.category, 3)
    }
}
