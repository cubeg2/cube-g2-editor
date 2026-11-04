// VariationTests.swift
// Wariacje: przełączanie (0x6A) i przepisywanie jednej na drugą (0x44).
// Reguły pochodzą z oryginału Clavii — patrz [[Docs/ui/variations]].

import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class VariationTests: XCTestCase {
    /// Moduł z rozróżnialną wartością w każdej z dziewięciu wariacji: w wariacji `v`
    /// parametr ma wartość `v * 10`, więc widać, skąd dokąd kopia poszła.
    private func makeModule(id: Int, area: PatchArea) -> G2Module {
        var module = G2Module(id: id, typeID: 1, area: area)
        module.parameterVariations = (0 ... 8).map { [$0 * 10] }
        module.parameters = module.parameterVariations[0]
        return module
    }

    private func makePatch() -> G2Patch {
        var patch = G2Patch()
        patch.voiceModules = [makeModule(id: 1, area: .voice)]
        patch.fxModules = [makeModule(id: 2, area: .fx)]
        for variation in 0 ... 8 {
            patch.variationSettings[variation].glideTime = variation
        }
        return patch
    }

    private func makeState(_ patch: G2Patch) -> PatchState {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        state.slots = [patch]
        return state
    }

    /// `groupsByEvent = false` znaczy, że grupy trzeba otworzyć ręcznie — inaczej
    /// `registerUndo` rzuca wyjątkiem (tak samo w `PatchStateTests`).
    private func undoStep(on state: PatchState, _ action: () -> Void) {
        state.undoManager.beginUndoGrouping()
        action()
        state.undoManager.endUndoGrouping()
    }

    // MARK: - Kopiowanie (0x44)

    func testCopyVariationCopiesBothAreasAndPatchSettings() {
        var patch = makePatch()
        patch.copyVariation(from: 3, to: 5)

        XCTAssertEqual(patch.voiceModules[0].parameterVariations[5], [30])
        XCTAssertEqual(patch.fxModules[0].parameterVariations[5], [30])
        XCTAssertEqual(patch.variationSettings[5].glideTime, 3)
        // Źródło zostaje nietknięte, sąsiednie wariacje też.
        XCTAssertEqual(patch.voiceModules[0].parameterVariations[3], [30])
        XCTAssertEqual(patch.voiceModules[0].parameterVariations[4], [40])
    }

    /// „Init" w oryginale przywołuje zestaw init (wariacja 8) do bieżącej wariacji —
    /// Param Setting Copy(8, focused). Gałki muszą od razu pokazać nowe wartości.
    func testInitCopyRefreshesVisibleValues() {
        var patch = makePatch()
        patch.setActiveVariation(2)
        XCTAssertEqual(patch.voiceModules[0].parameters, [20])

        patch.copyVariation(from: 8, to: patch.activeVariation)

        XCTAssertEqual(patch.voiceModules[0].parameterVariations[2], [80])
        XCTAssertEqual(patch.voiceModules[0].parameters, [80], "widok gałek ma pokazać skopiowaną wariację")
    }

    /// Kopia do wariacji, której nie widać, nie może ruszyć tego, co pokazują gałki.
    func testCopyIntoHiddenVariationLeavesVisibleValuesAlone() {
        var patch = makePatch()
        patch.setActiveVariation(1)

        patch.copyVariation(from: 0, to: 7)

        XCTAssertEqual(patch.voiceModules[0].parameters, [10])
        XCTAssertEqual(patch.voiceModules[0].parameterVariations[7], [0])
    }

    func testCopyVariationIgnoresNonsenseArguments() {
        var patch = makePatch()
        patch.copyVariation(from: 2, to: 2)
        patch.copyVariation(from: 0, to: 9)
        patch.copyVariation(from: -1, to: 3)

        for variation in 0 ... 8 {
            XCTAssertEqual(patch.voiceModules[0].parameterVariations[variation], [variation * 10])
        }
    }

    // MARK: - Przełączanie (0x6A)

    func testSelectVariationChangesTheViewAndTellsTheDevice() {
        let state = makeState(makePatch())
        var reported: [(slot: Int, variation: Int)] = []
        state.onVariationChange = { slot, variation in reported.append((slot, variation)) }

        undoStep(on: state) { state.selectVariation(4) }

        XCTAssertEqual(state.patch.activeVariation, 4)
        XCTAssertEqual(state.patch.voiceModules[0].parameters, [40])
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.slot, 0)
        XCTAssertEqual(reported.first?.variation, 4)
    }

    /// Oryginał zapisuje przełączenie wariacji jako parę undo/redo
    /// (`CPatch::InternalSetFocusedParamSetting`) — u nas tak samo.
    func testSelectVariationIsUndoable() {
        let state = makeState(makePatch())
        undoStep(on: state) { state.selectVariation(6) }
        XCTAssertEqual(state.patch.activeVariation, 6)

        state.undoManager.undo()
        XCTAssertEqual(state.patch.activeVariation, 0)

        state.undoManager.redo()
        XCTAssertEqual(state.patch.activeVariation, 6)
    }

    /// Wariacja init jest dziewiąta i nie da się na niej grać — wybrać można 1…8.
    func testSelectVariationRefusesInitAndOutOfRange() {
        let state = makeState(makePatch())
        var reported = 0
        state.onVariationChange = { _, _ in reported += 1 }

        undoStep(on: state) {
            state.selectVariation(8)
            state.selectVariation(-1)
        }

        XCTAssertEqual(state.patch.activeVariation, 0)
        XCTAssertEqual(reported, 0)
    }

    func testStateCopyVariationAppliesLocallyAndTellsTheDevice() {
        let state = makeState(makePatch())
        var reported: [(slot: Int, from: Int, to: Int)] = []
        state.onVariationCopy = { slot, from, to in reported.append((slot, from, to)) }

        undoStep(on: state) { state.copyVariation(from: 8, to: 0) }

        XCTAssertEqual(state.patch.voiceModules[0].parameters, [80])
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.from, 8)
        XCTAssertEqual(reported.first?.to, 0)
    }

    /// Init wariacji da się cofnąć (oryginał nie umie): ⌘Z przywraca wartości sprzed kopii
    /// i odsyła cały slot do Norda, bo protokół nie ma komendy odwrotnej do `0x44`.
    func testVariationInitIsUndoableAndResendsTheSlot() {
        let state = makeState(makePatch())
        let before = state.patch
        var restored: [Int] = []
        state.onSlotRestore = { restored.append($0) }

        undoStep(on: state) { state.copyVariation(from: 8, to: 0) }
        XCTAssertEqual(state.undoManager.undoActionName, "Init Variation")

        state.undoManager.undo()
        XCTAssertEqual(state.patch, before)
        XCTAssertEqual(restored, [0])

        state.undoManager.redo()
        XCTAssertEqual(state.patch.voiceModules[0].parameters, [80])
    }

    // MARK: - Edit all (BVerhue `EditAllVariations`)

    /// Włączony „Edit all": ruch gałki trafia do wariacji 1–8, Init zostaje nietknięty,
    /// a do urządzenia idzie `SET_PARAM` z numerem każdej wariacji.
    func testEditAllWritesEveryPlayableVariationAndTellsTheDevice() {
        let state = makeState(makePatch())
        var sent: [Int] = []
        state.onLiveParameterChange = { _, _, _, _, value, variation in
            XCTAssertEqual(value, 55)
            sent.append(variation)
        }
        state.toggleEditAllVariations(slot: 0)

        undoStep(on: state) { state.setParameter(moduleID: 1, paramIndex: 0, value: 55, area: .voice) }

        for variation in 0 ... 7 {
            XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[variation], [55])
        }
        XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[8], [80], "Init zostaje")
        XCTAssertEqual(state.patch.voiceModules[0].parameters, [55])
        XCTAssertEqual(sent.sorted(), Array(0 ... 7))
    }

    /// Jedno ⌘Z po całym ruchu gałki przywraca każdej wariacji JEJ wartość sprzed ruchu.
    func testEditAllGestureUndoesToEachVariationsOwnValue() {
        let state = makeState(makePatch())
        state.toggleEditAllVariations(slot: 0)

        undoStep(on: state) {
            state.beginParameterGesture()
            state.setParameter(moduleID: 1, paramIndex: 0, value: 50, area: .voice)
            state.setParameter(moduleID: 1, paramIndex: 0, value: 60, area: .voice)
            state.endParameterGesture()
        }
        XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[3], [60])

        state.undoManager.undo()
        for variation in 0 ... 8 {
            XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[variation], [variation * 10])
        }
        XCTAssertEqual(state.patch.voiceModules[0].parameters, [0])

        state.undoManager.redo()
        XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[5], [60])
    }

    /// Wyłączony — jak dotąd: zmienia się tylko grająca wariacja.
    func testWithoutEditAllOnlyTheActiveVariationChanges() {
        let state = makeState(makePatch())
        state.toggleEditAllVariations(slot: 0)
        state.toggleEditAllVariations(slot: 0)

        undoStep(on: state) { state.setParameter(moduleID: 1, paramIndex: 0, value: 55, area: .voice) }

        XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[0], [55])
        XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[1], [10])
    }

    // MARK: - Lock Across Variations (forum, wątek 8995)

    /// Założenie blokady przepisuje wartość z grającej wariacji do pozostałych siedmiu
    /// (Init zostaje), a jedno ⌘Z oddaje każdej wariacji jej własną wartość.
    func testLockCopiesPlayingValueToEveryVariationAndUndoRestoresThem() {
        var patch = makePatch()
        patch.setActiveVariation(2)
        let state = makeState(patch)
        var sent: [Int] = []
        state.onLiveParameterChange = { _, _, _, _, value, variation in
            XCTAssertEqual(value, 20)
            sent.append(variation)
        }

        undoStep(on: state) { state.setVariationLock([(1, 0)], area: .voice, locked: true) }

        for variation in 0 ... 7 {
            XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[variation], [20])
        }
        XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[8], [80], "Init zostaje")
        XCTAssertEqual(sent.sorted(), [0, 1, 3, 4, 5, 6, 7], "grająca wariacja już ma tę wartość")
        XCTAssertTrue(state.isParameterVariationLocked(slot: 0, moduleID: 1, paramIndex: 0, area: .voice))
        XCTAssertEqual(state.undoManager.undoActionName, "Lock Across Variations")

        state.onLiveParameterChange = nil
        state.undoManager.undo()
        for variation in 0 ... 8 {
            XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[variation], [variation * 10])
        }
        XCTAssertFalse(state.isParameterVariationLocked(slot: 0, moduleID: 1, paramIndex: 0, area: .voice))

        state.undoManager.redo()
        XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[6], [20])
        XCTAssertTrue(state.isParameterVariationLocked(slot: 0, moduleID: 1, paramIndex: 0, area: .voice))
    }

    /// Zdjęcie blokady zostawia wartości, jakie są — od teraz każda wariacja może iść swoją drogą.
    func testUnlockKeepsValuesAndLetsVariationsDiffer() {
        let state = makeState(makePatch())
        undoStep(on: state) { state.setVariationLock([(1, 0)], area: .voice, locked: true) }
        undoStep(on: state) { state.setVariationLock([(1, 0)], area: .voice, locked: false) }

        XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[5], [0])
        undoStep(on: state) { state.setParameter(moduleID: 1, paramIndex: 0, value: 55, area: .voice) }
        XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[0], [55])
        XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[5], [0])
    }

    /// Gałka z blokadą chodzi we wszystkich wariacjach naraz, także bez „Edit all".
    func testLockedKnobMovesInEveryVariation() {
        let state = makeState(makePatch())
        undoStep(on: state) { state.setVariationLock([(1, 0)], area: .voice, locked: true) }

        undoStep(on: state) { state.setParameter(moduleID: 1, paramIndex: 0, value: 55, area: .voice) }

        for variation in 0 ... 7 {
            XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[variation], [55])
        }
        XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[8], [80])
        XCTAssertEqual(state.patch.fxModules[0].parameterVariations[3], [30], "inne moduły bez zmian")
    }

    /// „Init" przepisuje wariację, ale gałka z blokadą zostaje przy swojej wartości
    /// i Nord dostaje ją z powrotem.
    func testInitLeavesLockedKnobAlone() {
        let state = makeState(makePatch())
        undoStep(on: state) { state.setVariationLock([(1, 0)], area: .voice, locked: true) }
        var sent: [(variation: Int, value: Int)] = []
        state.onLiveParameterChange = { _, _, _, _, value, variation in sent.append((variation, value)) }

        undoStep(on: state) { state.copyVariation(from: 8, to: 0) }

        XCTAssertEqual(state.patch.voiceModules[0].parameters, [0])
        XCTAssertEqual(state.patch.fxModules[0].parameters, [80], "bez blokady Init działa jak zawsze")
        XCTAssertEqual(sent.map(\.variation), [0])
        XCTAssertEqual(sent.map(\.value), [0])
    }

    /// Gałka z blokadą przekręcona na Nordzie: Nord zmienił grającą wariację, resztę
    /// dosyłamy sami.
    func testLockedKnobTurnedOnTheDeviceSpreadsToOtherVariations() {
        let state = makeState(makePatch())
        undoStep(on: state) { state.setVariationLock([(1, 0)], area: .voice, locked: true) }
        var sent: [Int] = []
        state.onLiveParameterChange = { _, _, _, _, _, variation in sent.append(variation) }

        state.applyDeviceParameter(slot: 0, area: .voice, moduleID: 1, paramIndex: 0, value: 70, variation: 0)

        for variation in 0 ... 7 {
            XCTAssertEqual(state.patch.voiceModules[0].parameterVariations[variation], [70])
        }
        XCTAssertEqual(sent.sorted(), Array(1 ... 7), "grającej wariacji nie odsyłamy — echo")
    }

    /// Mutator nie rusza parametru z blokadą — inaczej rozjechałby go między wariacjami.
    func testMutatorSkipsLockedParameter() {
        var patch = makePatch()
        patch.voiceModules[0].variationLockedParameters = [0]
        let gene = G2MutatorGenome(patch: patch).genes.first { $0.moduleID == 1 && $0.area == .voice }

        XCTAssertEqual(gene?.variationLocked, true)
        XCTAssertFalse(gene.map { G2Mutator.isEnabled($0, locks: G2MutatorLocks(enabled: 0xFF)) } ?? true)
    }

    // MARK: - Kłódki pamiętane przez edytor

    private func lockMemory() -> VariationLockMemory {
        VariationLockMemory(defaults: UserDefaults(suiteName: "VariationTests-\(UUID())")!)
    }

    /// Patch z prawdziwym oscylatorem (OscB): moduł testowy typu 1 nie ma parametrów,
    /// więc po zapisie do pliku nie byłoby czego blokować.
    private func makeSavablePatch() -> G2Patch {
        var module = G2Module(id: 1, typeID: 7, area: .voice)
        let defaults = ModuleDefaultsDatabase.defaults(forTypeID: 7)
        module.parameterVariations = (0 ... 8).map { variation in
            var values = defaults
            values[0] = variation * 10
            return values
        }
        module.parameters = module.parameterVariations[0]
        var patch = G2Patch()
        patch.voiceModules = [module]
        return patch
    }

    private func temporaryPatchURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID()).pch2")
    }

    /// Zapis patcha zapamiętuje kłódki, otwarcie tego samego pliku je przywraca —
    /// a plik dla Norda nie ma w sobie nic nowego.
    func testLocksComeBackWhenTheSameFileIsOpenedAgain() {
        let memory = lockMemory()
        let url = temporaryPatchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let state = makeState(makeSavablePatch())
        state.variationLockMemory = memory
        undoStep(on: state) { state.setVariationLock([(1, 0)], area: .voice, locked: true) }
        state.save(slot: 0, as: url)
        XCTAssertNil(state.errorMessage)

        let reopened = makeState(G2Patch())
        reopened.variationLockMemory = memory
        reopened.load(url: url, intoSlot: 0)

        XCTAssertNil(reopened.errorMessage)
        XCTAssertTrue(reopened.isParameterVariationLocked(slot: 0, moduleID: 1, paramIndex: 0, area: .voice))
        XCTAssertFalse(reopened.isParameterVariationLocked(slot: 0, moduleID: 1, paramIndex: 1, area: .voice))
        XCTAssertFalse(reopened.slotHasUnsavedChanges(0), "przywrócona kłódka nie jest zmianą do zapisania")
    }

    /// Kłódki idą za nazwą pliku, nie za folderem — plik przeniesiony gdzie indziej je zachowuje.
    func testLocksFollowTheFileToAnotherFolder() throws {
        let memory = lockMemory()
        let url = temporaryPatchURL()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("moved-\(UUID())")
        let moved = folder.appendingPathComponent(url.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = makeState(makeSavablePatch())
        state.variationLockMemory = memory
        undoStep(on: state) { state.setVariationLock([(1, 0)], area: .voice, locked: true) }
        state.save(slot: 0, as: url)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: moved)

        let reopened = makeState(G2Patch())
        reopened.variationLockMemory = memory
        reopened.load(url: moved, intoSlot: 0)

        XCTAssertTrue(reopened.isParameterVariationLocked(slot: 0, moduleID: 1, paramIndex: 0, area: .voice))
    }

    /// Plik zmieniony bez kłódki (inny Mac, oryginalny edytor): wartości w wariacjach się
    /// rozjechały, więc stara kłódka nie wraca.
    func testLockDoesNotComeBackWhenTheFileChangedElsewhere() {
        let memory = lockMemory()
        let url = temporaryPatchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let state = makeState(makeSavablePatch())
        state.variationLockMemory = memory
        undoStep(on: state) { state.setVariationLock([(1, 0)], area: .voice, locked: true) }
        state.save(slot: 0, as: url)

        let elsewhere = makeState(G2Patch())
        elsewhere.variationLockMemory = lockMemory()
        elsewhere.load(url: url, intoSlot: 0)
        undoStep(on: elsewhere) { elsewhere.setParameter(moduleID: 1, paramIndex: 0, value: 99, area: .voice) }
        elsewhere.save(slot: 0)

        let reopened = makeState(G2Patch())
        reopened.variationLockMemory = memory
        reopened.load(url: url, intoSlot: 0)

        XCTAssertFalse(reopened.isParameterVariationLocked(slot: 0, moduleID: 1, paramIndex: 0, area: .voice))
    }

    // MARK: - Bajty komend

    func testVariationPayloadsMatchTheOriginal() {
        // `[0x01][COMMAND_REQ|COMMAND_SLOT|slot][wersja][0x6A][wariacja]`
        XCTAssertEqual(
            G2UsbProtocol.selectVariationPayload(slot: 2, version: 0x12, variation: 3),
            [0x01, 0x2A, 0x12, 0x6A, 0x03]
        )
        // `[…][0x44][źródło][cel]` — kolejność jak w `AddMsgCopyVariation` i Param Setting Copy.
        XCTAssertEqual(
            G2UsbProtocol.copyVariationPayload(slot: 0, version: 0x08, from: 8, to: 1),
            [0x01, 0x28, 0x08, 0x44, 0x08, 0x01]
        )
    }

    // MARK: - Porównanie dwóch wariacji

    func testComparisonListsOnlyParametersThatDiffer() {
        var module = G2Module(id: 1, typeID: 7, area: .voice)
        module.parameterVariations = (0 ... 8).map { [$0 == 4 ? 50 : 10, 20, $0] }
        module.parameters = module.parameterVariations[0]

        XCTAssertEqual(module.parametersDiffering(fromVariation: 4), [0, 2])
        XCTAssertEqual(module.parametersDiffering(fromVariation: 0), [])
        XCTAssertEqual(module.parameterValues(inVariation: 4), [50, 20, 4])
    }

    func testShiftClickTogglesComparisonWithoutChangingTheSound() {
        let state = makeState(makePatch())
        state.toggleCompare(with: 4, slot: 0)
        XCTAssertEqual(state.comparedVariation(slot: 0), 4)
        XCTAssertEqual(state.slots[0].activeVariation, 0)

        state.toggleCompare(with: 4, slot: 0)
        XCTAssertNil(state.comparedVariation(slot: 0))
        // Grająca wariacja nie porównuje się sama ze sobą.
        state.toggleCompare(with: 0, slot: 0)
        XCTAssertNil(state.comparedVariation(slot: 0))
    }

    func testPlayingTheComparedVariationEndsTheComparison() {
        let state = makeState(makePatch())
        state.toggleCompare(with: 4, slot: 0)
        undoStep(on: state) { state.selectVariation(2) }
        XCTAssertEqual(state.comparedVariation(slot: 0), 4)

        undoStep(on: state) { state.selectVariation(4) }
        XCTAssertNil(state.comparedVariation(slot: 0))
        undoStep(on: state) { state.selectVariation(2) }
        XCTAssertNil(state.comparedVariation(slot: 0))
    }
}
