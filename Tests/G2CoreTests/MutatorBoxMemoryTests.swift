// MutatorBoxMemoryTests.swift
// Zmiana zrobiona przy słuchanym dziecku albo kratce Temporary Storage zostaje w tej
// kratce — ustawienia patcha (Octave Shift…), morfy i gałki modułów, z edytora i z Norda.
// Tak robi oryginał (`SetParamValue`, `SetMorphDelta`; instrukcja Mutatora: „You can
// manually modify any sound (child, parent or in the storage) at any time").

import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class MutatorBoxMemoryTests: XCTestCase {
    private let octaveKey = G2Individual.Key.setting(module: G2PatchSetting.octaveShift.module,
                                                     param: G2PatchSetting.octaveShift.param)
    private let lengthKey = G2Individual.Key(area: .voice, moduleID: 1, paramIndex: 33)
    private let childA = G2MutatorBox.child(0)
    private let childB = G2MutatorBox.child(1)
    private let storageBox = G2MutatorBox(.storage, 0)

    /// SeqNote (parametr 33 = Length, nie jest losowany) z ośmioma wariacjami i buforami.
    private func makeState() -> PatchState {
        var patch = G2Patch()
        var sequencer = G2Module(id: 1, typeID: 121, area: .voice)
        sequencer.parameters = Array(repeating: 64, count: 37)
        sequencer.parameters[33] = 15
        sequencer.parameterVariations = Array(repeating: sequencer.parameters,
                                              count: G2Patch.runtimeVariationCount)
        sequencer.hasParameterEntry = true
        patch.add(module: sequencer)
        patch.variationSettings = Array(repeating: G2VariationSettings.factory,
                                        count: G2Patch.runtimeVariationCount)
        patch.morphAssignments = Array(repeating: [], count: G2Patch.runtimeVariationCount)
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        state.slots = [patch]
        return state
    }

    private func step(_ state: PatchState, _ action: () -> Void) {
        state.undoManager.beginUndoGrouping()
        action()
        state.undoManager.endUndoGrouping()
    }

    /// Sześcioro dzieci i pierwsze z nich w magazynie; gra dziecko A.
    private func breed() -> PatchState {
        let state = makeState()
        step(state) { state.mutatorMutate() }
        step(state) { state.mutatorStore(childA) }
        return state
    }

    private func focus(_ state: PatchState, _ box: G2MutatorBox) {
        step(state) { state.mutatorSetFocus(box) }
    }

    private func value(_ state: PatchState, _ box: G2MutatorBox, _ key: G2Individual.Key) -> Double? {
        state.mutatorIndividual(at: box)?[key]
    }

    func testOctaveShiftStaysInTheChild() {
        let state = breed()
        step(state) { state.setPatchSetting(.octaveShift, value: 4) }

        focus(state, childB)
        XCTAssertEqual(state.patchSetting(.octaveShift), 2, "drugie dziecko ma swoją oktawę")
        focus(state, childA)
        XCTAssertEqual(state.patchSetting(.octaveShift), 4, "pierwsze pamięta zmienioną")
        XCTAssertEqual(value(state, storageBox, octaveKey), 2, "kopia w magazynie nietknięta")
    }

    func testOctaveShiftStaysInTheStorageBox() {
        let state = breed()
        focus(state, storageBox)
        step(state) { state.setPatchSetting(.octaveShift, value: 0) }

        focus(state, childB)
        focus(state, storageBox)
        XCTAssertEqual(state.patchSetting(.octaveShift), 0)
        XCTAssertEqual(value(state, childA, octaveKey), 2)
    }

    func testOctaveShiftFromTheNordStaysInTheBox() {
        let state = breed()
        state.applyDeviceSetting(slot: 0, moduleID: G2PatchSetting.octaveShift.module,
                                 paramIndex: G2PatchSetting.octaveShift.param,
                                 value: 3, variation: G2Patch.mutatorVariation)

        focus(state, childB)
        focus(state, childA)
        XCTAssertEqual(state.patchSetting(.octaveShift), 3)
    }

    func testModuleKnobStaysInTheStorageBox() {
        let state = breed()
        focus(state, storageBox)
        step(state) { state.setParameter(moduleID: 1, paramIndex: 33, value: 7, area: .voice) }
        focus(state, childB)
        focus(state, storageBox)
        XCTAssertEqual(state.patch.voiceModules[0].parameters[33], 7)

        state.applyDeviceParameter(slot: 0, area: .voice, moduleID: 1, paramIndex: 33,
                                   value: 5, variation: G2Patch.mutatorVariation)
        focus(state, childB)
        focus(state, storageBox)
        XCTAssertEqual(state.patch.voiceModules[0].parameters[33], 5)
    }

    func testMorphKnobAndSourceStayInTheBox() {
        let state = breed()
        step(state) { state.setMorphDial(0, value: 90) }
        step(state) { state.setMorphMode(1, value: 0) }
        let mode = state.patch.morphMode(1, in: G2Patch.mutatorVariation)
        state.applyDeviceSetting(slot: 0, moduleID: 1, paramIndex: 2, value: 55,
                                 variation: G2Patch.mutatorVariation)

        focus(state, childB)
        XCTAssertEqual(state.patch.morphDial(0, in: G2Patch.mutatorVariation), 0)
        focus(state, childA)
        XCTAssertEqual(state.patch.morphDial(0, in: G2Patch.mutatorVariation), 90)
        XCTAssertEqual(state.patch.morphDial(2, in: G2Patch.mutatorVariation), 55)
        XCTAssertEqual(state.patch.morphMode(1, in: G2Patch.mutatorVariation), mode)
        XCTAssertEqual(value(state, childA, .setting(module: 1, param: 1 + G2Morph.count)), Double(mode))
    }

    func testMorphRangeStaysInTheBox() {
        let state = breed()
        let buffer = G2Patch.mutatorVariation
        func range() -> Int {
            state.patch.morphRange(variation: buffer, location: 1, moduleID: 1, paramIndex: 0, morph: 0)
        }
        step(state) { state.setMorphRange(location: 1, moduleID: 1, paramIndex: 0, morph: 0, range: 40) }

        focus(state, childB)
        XCTAssertEqual(range(), 0)
        focus(state, childA)
        XCTAssertEqual(range(), 40)

        step(state) { state.clearMorph(0) }
        focus(state, childB)
        focus(state, childA)
        XCTAssertEqual(range(), 0, "zdjęte przypisanie nie wraca")
    }

    /// ⌘Z cofa najpierw przejście do drugiej kratki, potem zmianę — w tej kratce,
    /// w której powstała.
    func testUndoAfterSwitchingBoxesRevertsTheRightBox() {
        let state = breed()
        let octaveB = value(state, childB, octaveKey)
        let lengthB = value(state, childB, lengthKey)
        step(state) { state.setPatchSetting(.octaveShift, value: 4) }
        step(state) { state.setParameter(moduleID: 1, paramIndex: 33, value: 7, area: .voice) }
        focus(state, childB)

        state.undoManager.undo() // przejście do B
        XCTAssertEqual(state.mutatorHighlight, childA)
        state.undoManager.undo() // Length
        state.undoManager.undo() // Octave Shift

        XCTAssertEqual(value(state, childA, lengthKey), 15)
        XCTAssertEqual(value(state, childA, octaveKey), 2)
        XCTAssertEqual(value(state, childB, lengthKey), lengthB)
        XCTAssertEqual(value(state, childB, octaveKey), octaveB)
        XCTAssertEqual(state.patch.voiceModules[0].parameters[33], 15)
        XCTAssertEqual(state.patchSetting(.octaveShift), 2)

        state.undoManager.redo() // Octave Shift
        XCTAssertEqual(value(state, childA, octaveKey), 4)
    }

    /// Wybór wariacji nie ma własnego kroku undo, gdy wychodzi się z kratki (#135), więc
    /// ⌘Z na zmianie sprzed wyboru wraca do kratki, a nie pisze w tę wariację.
    func testUndoAfterPickingAVariationDoesNotTouchTheVariation() {
        let state = breed()
        step(state) { state.setPatchSetting(.octaveShift, value: 4) }
        step(state) { state.setParameter(moduleID: 1, paramIndex: 33, value: 7, area: .voice) }
        step(state) { state.setMorphDial(0, value: 90) }
        state.selectVariation(3)

        var sent: [Int] = []
        state.onLiveParameterChange = { _, _, _, _, _, variation in sent.append(variation) }
        state.onPatchSettingChange = { _, _, _, _, variation in sent.append(variation) }
        state.undoManager.undo() // morf
        state.undoManager.undo() // Length
        state.undoManager.undo() // Octave Shift

        XCTAssertEqual(sent, [9, 9, 9], "Nord dostaje cofnięcia do bufora odsłuchu")
        XCTAssertEqual(state.mutatorHighlight, childA, "cofanie wraca do kratki")
        XCTAssertEqual(value(state, childA, lengthKey), 15)
        XCTAssertEqual(value(state, childA, octaveKey), 2)
        state.selectVariation(3)
        XCTAssertEqual(state.patch.voiceModules[0].parameters[33], 15)
        XCTAssertEqual(state.patchSetting(.octaveShift), 2)
        XCTAssertEqual(state.patch.morphDial(0, in: 3), 0)
    }

    /// Dźwięk zmieniony w kratce idzie do wariacji — i tylko tam trafia do pliku.
    func testEditedBoxCopiedToAVariationCarriesTheChange() {
        let state = breed()
        step(state) { state.setPatchSetting(.octaveShift, value: 4) }
        focus(state, childB)
        step(state) { state.mutatorDrag(from: childA, to: G2MutatorBox(.variations, 2)) }

        XCTAssertEqual(state.patch.variationSettings[2].octaveShift, 4)
        XCTAssertEqual(state.patch.variationSettings[0].octaveShift, 2, "pozostałe wariacje bez zmian")
    }

    /// Gdy bufor gra coś spoza kratek (fader wariacji), zmiana nie wolno jej trafić do
    /// ostatnio klikniętej kratki.
    func testEditWhileTheVariationFaderPlaysLeavesTheBoxesAlone() {
        let state = breed()
        state.slots[0].setParameter(moduleID: 1, paramIndex: 0, value: 10, in: .voice, variation: 1)
        step(state) {
            state.moveVariationFader(to: 0.5, slot: 0)
            state.endVariationFaderGesture(slot: 0)
        }
        XCTAssertNotNil(state.activeVariationFader(slot: 0))
        step(state) { state.setPatchSetting(.octaveShift, value: 4) }
        XCTAssertEqual(value(state, childA, octaveKey), 2)
    }

    /// Gałka z `Lock Across Variations` ma tę samą wartość wszędzie — także w buforze,
    /// z którego właśnie słychać dziecko.
    func testLockedKnobMovesWhileAuditioning() {
        let state = makeState()
        step(state) { state.setVariationLock([(moduleID: 1, paramIndex: 33)], area: .voice, locked: true) }
        step(state) { state.mutatorMutate() }
        step(state) { state.setParameter(moduleID: 1, paramIndex: 33, value: 7, area: .voice) }

        XCTAssertEqual(state.patch.voiceModules[0].parameters[33], 7)
        focus(state, childB)
        XCTAssertEqual(state.patch.voiceModules[0].parameters[33], 7)

        state.undoManager.undo() // przejście do B
        state.undoManager.undo() // gałka
        XCTAssertEqual(state.patch.voiceModules[0].parameters[33], 15)
        XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[0][33], 15)

        state.applyDeviceParameter(slot: 0, area: .voice, moduleID: 1, paramIndex: 33,
                                   value: 3, variation: G2Patch.mutatorVariation)
        XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[5][33], 3)
    }
}
