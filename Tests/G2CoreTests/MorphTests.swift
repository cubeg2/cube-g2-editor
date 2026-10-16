// MorphTests.swift
// Morfy: model przypisań, sekcje 0x65 i 0x4d (grupa 1) oraz komenda 0x43.
// Reguły i pomiary na kolekcji referencyjnej → [[Docs/ui/morphs]].

import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class MorphTests: XCTestCase {
    private func fixtureData(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .standardized
        return try Data(contentsOf: url)
    }

    private func makePatch() -> G2Patch {
        var patch = G2Patch()
        var module = G2Module(id: 2, typeID: 1, area: .voice)
        module.parameterVariations = (0 ... 8).map { [$0 * 10, 0] }
        module.parameters = module.parameterVariations[0]
        patch.voiceModules = [module]
        return patch
    }

    private func makeState(_ patch: G2Patch) -> PatchState {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        state.slots = [patch]
        return state
    }

    private func undoStep(on state: PatchState, _ action: () -> Void) {
        state.undoManager.beginUndoGrouping()
        action()
        state.undoManager.endUndoGrouping()
    }

    // MARK: - Odczyt z pliku

    /// Fixture ma dokładnie jedno przypisanie: wariacja 1, obszar Voice, moduł 2,
    /// parametr 1, morf 1, zakres 127 (odczytane niezależnym skryptem wg g2ools).
    func testMorphAssignmentIsReadFromFile() throws {
        let patch = try XCTUnwrap(PatchParser.parse(data: fixtureData("simplesynth001-20240802.pch2")).first)
        XCTAssertEqual(patch.morphAssignments.count, G2Patch.runtimeVariationCount,
                       "9 zestawów z pliku + bufor mutatora")
        XCTAssertTrue(patch.morphs(in: 0).isEmpty)

        let entry = try XCTUnwrap(patch.morphs(in: 1).first)
        XCTAssertEqual(patch.morphs(in: 1).count, 1)
        XCTAssertEqual(entry.location, 1, "obszar Voice")
        XCTAssertEqual(entry.area, .voice)
        XCTAssertEqual(entry.moduleID, 2)
        XCTAssertEqual(entry.paramIndex, 1)
        XCTAssertEqual(entry.morph, 1, "numeracja morfów w pliku jest od zera")
        XCTAssertEqual(entry.range, 127)
    }

    /// Gałki i źródła morfów siedzą w grupie 1 sekcji ustawień. Fixture ma jedną
    /// gałkę wykręconą — morf 3 (indeks 2) w wariacji 2 (indeks 1) stoi na 25 —
    /// więc widać i że gałki są czytane, i że nie sklejają się między wariacjami.
    func testMorphDialsAndSourcesAreReadFromFile() throws {
        let patch = try XCTUnwrap(PatchParser.parse(data: fixtureData("simplesynth001-20240802.pch2")).first)
        XCTAssertEqual(patch.morphDial(2, in: 1), 25)
        XCTAssertEqual(patch.morphDial(2, in: 0), 0)
        for variation in 0 ... 8 where variation != 1 {
            XCTAssertEqual(patch.variationSettings[variation].morphDials, Array(repeating: 0, count: 8))
        }
        // Źródło 1 = nazwane (Wheel, Vel, …); tak wychodzi init patch.
        for variation in 0 ... 8 {
            XCTAssertEqual(patch.variationSettings[variation].morphModes, Array(repeating: 1, count: 8))
        }
    }

    // MARK: - Zapis

    func testEditedMorphsSurviveSave() throws {
        let data = try fixtureData("simplesynth001-20240802.pch2")
        var patches = try PatchParser.parse(data: data)

        patches[0].setMorphRange(variation: 0, location: 1, moduleID: 2,
                                 paramIndex: 0, morph: 3, range: 64)
        // Zakres ujemny — w pliku bajt w uzupełnieniu do dwóch.
        patches[0].setMorphRange(variation: 2, location: 0, moduleID: 1,
                                 paramIndex: 4, morph: 7, range: -40)
        patches[0].variationSettings[0].morphDials[2] = 99
        patches[0].variationSettings[0].morphModes[4] = 2

        let saved = try PatchParser.saveAll(originalData: data, patches: patches)
        let reloaded = try XCTUnwrap(PatchParser.parse(data: saved).first)

        XCTAssertEqual(reloaded.morphRange(variation: 0, location: 1, moduleID: 2,
                                           paramIndex: 0, morph: 3), 64)
        XCTAssertEqual(reloaded.morphRange(variation: 2, location: 0, moduleID: 1,
                                           paramIndex: 4, morph: 7), -40)
        // Przypisanie z pliku zostaje nietknięte.
        XCTAssertEqual(reloaded.morphRange(variation: 1, location: 1, moduleID: 2,
                                           paramIndex: 1, morph: 1), 127)
        XCTAssertEqual(reloaded.variationSettings[0].morphDials[2], 99)
        XCTAssertEqual(reloaded.variationSettings[0].morphModes[4], 2)
    }

    /// Plik, którego nikt nie ruszył, ma wyjść z zapisu bajt w bajt — sekcja morfów
    /// buduje się od zera, więc to ona jest tu dowodem, że układ bitów się zgadza.
    func testUntouchedFileKeepsItsMorphSection() throws {
        let data = try fixtureData("simplesynth001-20240802.pch2")
        let patches = try PatchParser.parse(data: data)
        let saved = try PatchParser.saveAll(originalData: data, patches: patches)
        XCTAssertEqual(saved, data)
    }

    // MARK: - Model

    func testSettingRangeToZeroRemovesTheAssignment() {
        var patch = makePatch()
        patch.setMorphRange(variation: 0, location: 1, moduleID: 2, paramIndex: 0, morph: 0, range: 30)
        XCTAssertEqual(patch.morphs(in: 0).count, 1)

        patch.setMorphRange(variation: 0, location: 1, moduleID: 2, paramIndex: 0, morph: 0, range: 0)
        XCTAssertTrue(patch.morphs(in: 0).isEmpty, "zakres 0 = brak przypisania, tak jak w urządzeniu")
    }

    /// Wpisy trzymamy w kolejności pliku — (obszar, moduł, parametr, morf) —
    /// żeby sekcja zapisała się tak, jak zapisałby ją Nord.
    func testNewAssignmentsLandInFileOrder() {
        var patch = makePatch()
        patch.setMorphRange(variation: 0, location: 1, moduleID: 5, paramIndex: 0, morph: 0, range: 10)
        patch.setMorphRange(variation: 0, location: 0, moduleID: 9, paramIndex: 0, morph: 0, range: 10)
        patch.setMorphRange(variation: 0, location: 1, moduleID: 2, paramIndex: 3, morph: 1, range: 10)
        patch.setMorphRange(variation: 0, location: 1, moduleID: 2, paramIndex: 3, morph: 0, range: 10)

        let keys = patch.morphs(in: 0).map { [Int($0.location), $0.moduleID, $0.paramIndex, $0.morph] }
        XCTAssertEqual(keys, [[0, 9, 0, 0], [1, 2, 3, 0], [1, 2, 3, 1], [1, 5, 0, 0]])
    }

    /// Clavia odmawia przypisania, gdy wariacja ma już 25 parametrów pod morfami
    /// (`GetNumberOfMorphedParams(…) < 0x19`).
    func testVariationTakesNoMoreThanTwentyFiveAssignments() {
        var patch = makePatch()
        for i in 0 ..< G2Morph.maxAssignmentsPerVariation {
            XCTAssertTrue(patch.setMorphRange(variation: 0, location: 1, moduleID: i,
                                              paramIndex: 0, morph: 0, range: 10))
        }
        XCTAssertFalse(patch.setMorphRange(variation: 0, location: 1, moduleID: 99,
                                           paramIndex: 0, morph: 0, range: 10),
                       "26. przypisanie odrzucone")
        // Zmiana już istniejącego wpisu przechodzi mimo kompletu.
        XCTAssertTrue(patch.setMorphRange(variation: 0, location: 1, moduleID: 0,
                                          paramIndex: 0, morph: 0, range: 20))
        XCTAssertEqual(patch.morphs(in: 0).count, 25)
    }

    func testClearAndCopyMoveWholeGroups() {
        var patch = makePatch()
        patch.setMorphRange(variation: 0, location: 1, moduleID: 2, paramIndex: 0, morph: 2, range: 30)
        patch.setMorphRange(variation: 0, location: 1, moduleID: 2, paramIndex: 1, morph: 2, range: -20)
        patch.setMorphRange(variation: 0, location: 1, moduleID: 3, paramIndex: 0, morph: 5, range: 40)

        let moved = patch.copyMorph(from: 2, to: 6, in: 0)
        XCTAssertEqual(moved.count, 2)
        XCTAssertEqual(patch.morphs(in: 0).filter { $0.morph == 6 }.map(\.range), [30, -20],
                       "zakresy jadą razem z przypisaniem")
        XCTAssertTrue(patch.morphs(in: 0).filter { $0.morph == 2 }.isEmpty)

        let removed = patch.clearMorph(6, in: 0)
        XCTAssertEqual(removed.count, 2)
        XCTAssertEqual(patch.morphs(in: 0).count, 1, "morf 5 zostaje nietknięty")
    }

    /// Kopia wariacji zabiera morfy — u Clavii robi to Morph Map (CopyParamSetting).
    func testCopyVariationTakesMorphsAlong() {
        var patch = makePatch()
        patch.setMorphRange(variation: 3, location: 1, moduleID: 2, paramIndex: 0, morph: 1, range: 50)
        patch.variationSettings[3].morphDials[1] = 77

        patch.copyVariation(from: 3, to: 5)

        XCTAssertEqual(patch.morphRange(variation: 5, location: 1, moduleID: 2,
                                        paramIndex: 0, morph: 1), 50)
        XCTAssertEqual(patch.variationSettings[5].morphDials[1], 77)
    }

    // MARK: - Stan edytora

    func testStateChangesMorphAndTellsTheDevice() {
        let state = makeState(makePatch())
        var reported: [(morph: Int, range: Int, variation: Int)] = []
        state.onMorphRangeChange = { _, _, _, _, morph, range, variation in
            reported.append((morph, range, variation))
        }

        undoStep(on: state) {
            state.setMorphRange(location: 1, moduleID: 2, paramIndex: 0, morph: 4, range: 25)
        }

        XCTAssertEqual(state.patch.morphRange(variation: 0, location: 1, moduleID: 2,
                                              paramIndex: 0, morph: 4), 25)
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.morph, 4)
        XCTAssertEqual(reported.first?.range, 25)

        state.undoManager.undo()
        XCTAssertEqual(state.patch.morphRange(variation: 0, location: 1, moduleID: 2,
                                              paramIndex: 0, morph: 4), 0,
                       "cofnięcie kasuje przypisanie, bo zakres wraca na zero")
        XCTAssertEqual(reported.last?.range, 0, "urządzenie dostaje kasowanie tą samą komendą")
    }

    func testStateSendsEveryClearedAssignmentToTheDevice() {
        var patch = makePatch()
        patch.setMorphRange(variation: 0, location: 1, moduleID: 2, paramIndex: 0, morph: 1, range: 30)
        patch.setMorphRange(variation: 0, location: 1, moduleID: 2, paramIndex: 1, morph: 1, range: 40)
        let state = makeState(patch)
        var zeroed = 0
        state.onMorphRangeChange = { _, _, _, _, _, range, _ in
            if range == 0 { zeroed += 1 }
        }

        undoStep(on: state) { state.clearMorph(1) }

        XCTAssertTrue(state.patch.morphs(in: 0).isEmpty)
        XCTAssertEqual(zeroed, 2, "zbiorczej komendy nie ma — każde przypisanie osobno")
    }

    func testMorphDialGoesToThePatchSettingsArea() {
        let state = makeState(makePatch())
        var reported: [(moduleID: Int, paramIndex: Int, value: Int)] = []
        state.onPatchSettingChange = { _, moduleID, paramIndex, value, _ in
            reported.append((moduleID, paramIndex, value))
        }

        undoStep(on: state) {
            state.setMorphDial(3, value: 100)
            state.setMorphMode(3, value: 0)
        }

        XCTAssertEqual(state.patch.morphDial(3, in: 0), 100)
        XCTAssertEqual(state.patch.morphMode(3, in: 0), 0)
        // Moduł 1 obszaru ustawień: parametry 0–7 to gałki, 8–15 źródła.
        XCTAssertEqual(reported.map(\.moduleID), [1, 1])
        XCTAssertEqual(reported.map(\.paramIndex), [3, 11])
        XCTAssertEqual(reported.map(\.value), [100, 0])
    }

    /// Trzecia pozycja („G Wh 1") istnieje wyłącznie przy morfie Sust.Pd.
    func testOnlySustainPedalMorphHasThirdSource() {
        XCTAssertEqual(G2Morph.sourceOptions(morph: 4), ["Knob", "Sust.Pd", "G Wh 1"])
        XCTAssertEqual(G2Morph.sourceOptions(morph: 0), ["Knob", "Wheel"])

        var patch = makePatch()
        patch.setMorphMode(0, in: 0, value: 2)
        XCTAssertEqual(patch.morphMode(0, in: 0), 1, "morf bez trzeciej pozycji przycięty")
        patch.setMorphMode(4, in: 0, value: 2)
        XCTAssertEqual(patch.morphMode(4, in: 0), 2)
    }

    // MARK: - Bajty komendy

    func testMorphRangePayloadMatchesTheOriginal() {
        // `[0x01][CMD_NO_RESP|CMD_SLOT|slot][wersja][0x43][obszar][moduł][parametr]
        //  [morf][|zakres|][znak][wariacja]` — kolejność z `AddMessMorphSet`
        // i Morph Change (WriteStream).
        XCTAssertEqual(
            G2UsbProtocol.setMorphRangePayload(slot: 1, version: 0x0C, location: 1,
                                               moduleID: 7, paramIndex: 3,
                                               morph: 2, range: 40, variation: 5),
            [0x01, 0x39, 0x0C, 0x43, 0x01, 0x07, 0x03, 0x02, 0x28, 0x00, 0x05]
        )
        // Zakres ujemny: wartość bezwzględna plus bajt znaku.
        XCTAssertEqual(
            G2UsbProtocol.setMorphRangePayload(slot: 0, version: 0x11, location: 2,
                                               moduleID: 1, paramIndex: 0,
                                               morph: 7, range: -40, variation: 0),
            [0x01, 0x38, 0x11, 0x43, 0x02, 0x01, 0x00, 0x07, 0x28, 0x01, 0x00]
        )
    }

    /// Gałka strony parametrów może wskazywać morf w INNYM slocie performance'u
    /// (Global Pages), więc zapis musi przyjmować slot — jak `setParameter(slot:…)`.
    /// U Clavii wychodzi to samo z `GetActualControl`, które sięga po patch ze slotu
    /// zapisanego w przypisaniu → [[Docs/ui/parameter-pages]].
    func testMorphDialCanBeSetInAnotherSlot() {
        let state = makeState(makePatch())
        state.slots.append(makePatch())
        state.selectedSlot = 0
        let variation = state.slots[1].activeVariation

        undoStep(on: state) { state.setMorphDial(2, value: 77, slot: 1) }
        XCTAssertEqual(state.slots[1].morphDial(2, in: variation), 77)
        XCTAssertEqual(state.slots[0].morphDial(2, in: variation), 0, "obcy slot nietknięty")

        state.undoManager.undo()
        XCTAssertEqual(state.slots[1].morphDial(2, in: variation), 0, "cofnięcie wraca do tego slotu")
    }

    /// Droga POWROTNA: to samo powiadomienie przyjęte z urządzenia ma trafić w gałkę
    /// morfu, a nie w moduł FX o numerze 1 (obszar 2 nie mieści się w `PatchArea`).
    func testSettingFromTheDeviceLandsOnTheMorphDial() {
        let state = makeState(makePatch())
        let variation = state.patch.activeVariation
        state.applyDeviceSetting(slot: 0, moduleID: 1, paramIndex: 3, value: 99, variation: variation)
        XCTAssertEqual(state.patch.morphDial(3, in: variation), 99)
        // Parametry 8–15 tego modułu to źródła morfów.
        state.applyDeviceSetting(slot: 0, moduleID: 1, paramIndex: 8 + 1, value: 1, variation: variation)
        XCTAssertEqual(state.patch.morphMode(1, in: variation), 1)
        // Reszta obszaru to arkusz Patch Settings — moduł 3 pozycja 1 to czas glide'u.
        state.applyDeviceSetting(slot: 0, moduleID: 3, paramIndex: 1, value: 42, variation: variation)
        XCTAssertEqual(state.patchSetting(.glideTime), 42)
    }

    /// Gałka morfu jedzie zwykłym `SET_PARAM`, tyle że w obszarze 2 — tą samą drogą
    /// oryginał przestawia morf „G Wh 1" w nowym patchu na G2X.
    func testPatchSettingPayloadUsesArea2() {
        XCTAssertEqual(
            G2UsbProtocol.setParameterPayload(slot: 0, version: 0x08, location: 2,
                                              moduleID: 1, paramIndex: 12, value: 2, variation: 127),
            [0x01, 0x38, 0x08, 0x40, 0x02, 0x01, 0x0C, 0x02, 0x7F]
        )
    }
}
