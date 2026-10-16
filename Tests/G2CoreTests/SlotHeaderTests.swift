import G2Core
@testable import G2EditorCore
import Observation
import XCTest

/// Nagłówek slotu ma budzić pasy TYLKO wtedy, gdy zmieni się coś, co pokazują —
/// ruch gałki w module nie może ich dotykać (zmierzone 2026-09-21: to była jedna
/// z przyczyn „gałka nie kręci się płynnie").
@MainActor
final class SlotHeaderTests: XCTestCase {
    private func makeState() -> PatchState {
        var module = G2Module(id: 1, typeID: 1, area: .voice)
        module.parameters = [10]
        module.parameterVariations = Array(repeating: [10], count: 9)
        var patch = G2Patch()
        patch.name = "Init"
        patch.voiceModules = [module]
        let state = PatchState()
        state.slots = [patch]
        return state
    }

    /// Czy odczyt `slotHeaders` został unieważniony przez `mutate`.
    private func headersInvalidated(on state: PatchState, by mutate: () -> Void) -> Bool {
        // `onChange` jest `@Sendable`, a tu wszystko dzieje się synchronicznie na głównym wątku.
        nonisolated(unsafe) var fired = false
        withObservationTracking {
            _ = state.slotHeaders
        } onChange: {
            fired = true
        }
        mutate()
        return fired
    }

    func testHeaderFollowsSlotsAlsoWhenMutatedInPlace() {
        let state = makeState()
        XCTAssertEqual(state.header(slot: 0).name, "Init")
        state.slots[0].name = "Bass"
        XCTAssertEqual(state.header(slot: 0).name, "Bass")
        state.slots = [G2Patch(), G2Patch()]
        XCTAssertEqual(state.slotCount, 2)
        XCTAssertEqual(state.slotHeaders.count, 2)
        XCTAssertEqual(state.header(slot: 7), .empty)
    }

    func testKnobMoveDoesNotWakeTheHeaderButNameChangeDoes() {
        let state = makeState()
        XCTAssertFalse(headersInvalidated(on: state) {
            state.setParameter(moduleID: 1, paramIndex: 0, value: 42, area: .voice)
        })
        XCTAssertEqual(state.patch.voiceModules[0].parameters[0], 42)
        XCTAssertTrue(headersInvalidated(on: state) {
            state.setPatchName("Lead", slot: 0)
        })
        XCTAssertEqual(state.header(slot: 0).name, "Lead")
    }

    func testHeaderCarriesWhatTheSlotBarShows() {
        let state = makeState()
        state.setPatchSetting(.patchVolume, value: 99, slot: 0)
        state.setMorphDial(2, value: 64, slot: 0)
        state.selectVariation(3, slot: 0)
        let header = state.header(slot: 0)
        XCTAssertEqual(header.activeVariation, 3)
        XCTAssertEqual(header.morphDials.count, G2Morph.count)
        XCTAssertEqual(header.knobPageUsed.count, G2KnobPages.pageCount)
        // Ustawienia są per wariacja — po przełączeniu na 3 głośność i morf wracają do wartości tej wariacji.
        XCTAssertEqual(header.patchVolume, state.patchSetting(.patchVolume, slot: 0))
        XCTAssertEqual(header.morphDials[2], state.patch.morphDial(2, in: 3))
    }
}
