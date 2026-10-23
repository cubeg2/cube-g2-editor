@testable import G2Core
@testable import G2EditorCore
import XCTest

/// Wstawianie całego patcha z pliku (Building Block) → Docs/Plan projektu/08-building-blocks.md
@MainActor
final class BuildingBlockTests: XCTestCase {
    // MARK: - Pomocniki

    private func module(_ id: Int, typeID: Int = 1, column: Int, row: Int,
                        area: PatchArea = .voice) -> G2Module
    {
        var module = G2Module(id: id, typeID: typeID, area: area)
        module.column = column
        module.row = row
        module.parameters = [id]
        module.parameterVariations = Array(repeating: [id], count: 9)
        module.modes = [0]
        module.label = "M\(id)"
        return module
    }

    private func cable(_ from: Int, _ to: Int, area: PatchArea = .voice) -> G2Cable {
        G2Cable(fromModule: from, fromConnector: 0, toModule: to, toConnector: 1,
                color: .red, area: area)
    }

    private static func height(_ module: G2Module) -> Int {
        ModuleDatabase.module(id: module.typeID)?.height ?? 2
    }

    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/simplesynth001-20240802.pch2")

    /// Paczka Building Blocks z forum — leży w prywatnym repo z materiałami
    /// referencyjnymi obok kodu; bez niej test korpusu się pomija.
    private static let blocksFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("../reference/Ptches pch2 i prf2/NORDD G2 - OK/Bulding Blocks")
        .standardized

    // MARK: - Zachowanie

    /// Nowe numery, kable za modułami, układ bloku zachowany, a moduł, na który blok
    /// spada, zjeżdża pod niego razem z tym, co stało niżej.
    func testBlockKeepsItsLayoutAndPushesOverlappedModulesDown() {
        let height = Self.height(module(1, column: 0, row: 0))
        var patch = G2Patch()
        patch.voiceModules = [module(1, column: 0, row: 0), module(2, column: 0, row: height),
                              module(3, column: 1, row: 0)]
        var block = G2Patch()
        block.voiceModules = [module(1, column: 5, row: 4), module(7, column: 5, row: 4 + height)]
        block.voiceCables = [cable(1, 7)]

        let inserted = patch.insertBlock(block, dropArea: .voice, column: 0, row: 1).modules

        XCTAssertEqual(inserted, [.voice: [4, 5]])
        let rows = Dictionary(uniqueKeysWithValues: patch.voiceModules.map { ($0.id, $0.row) })
        XCTAssertEqual(rows[4], 1, "block corner lands on the drop point")
        XCTAssertEqual(rows[5], 1 + height, "block layout is kept")
        XCTAssertEqual(rows[1], 1 + 2 * height, "overlapped module goes under the block")
        XCTAssertEqual(rows[2], 1 + 3 * height, "and pushes the next one down")
        XCTAssertEqual(rows[3], 0, "other columns stay put")
        XCTAssertEqual(patch.voiceCables.last, cable(4, 5))
        XCTAssertEqual(patch.voiceModules.first { $0.id == 4 }?.label, "M1")
    }

    /// FX bloku idzie do FX, w tę samą kolumnę, pod wszystko, co już tam jest.
    func testOtherAreaGoesBelowExistingModules() {
        var patch = G2Patch()
        patch.fxModules = [module(1, column: 3, row: 0, area: .fx)]
        var block = G2Patch()
        block.voiceModules = [module(1, column: 0, row: 0)]
        block.fxModules = [module(1, column: 2, row: 5, area: .fx), module(2, column: 2, row: 7, area: .fx)]
        block.fxCables = [cable(1, 2, area: .fx)]

        let inserted = patch.insertBlock(block, dropArea: .voice, column: 4, row: 0).modules

        XCTAssertEqual(inserted, [.voice: [1], .fx: [2, 3]])
        let below = Self.height(patch.fxModules[0])
        let fx = Dictionary(uniqueKeysWithValues: patch.fxModules.map { ($0.id, ($0.column, $0.row)) })
        XCTAssertEqual(fx[1]?.1, 0)
        XCTAssertEqual(fx[2]?.0, 4)
        XCTAssertEqual(fx[2]?.1, below)
        XCTAssertEqual(fx[3]?.1, below + 2)
        XCTAssertEqual(patch.fxCables, [cable(2, 3, area: .fx)])
        XCTAssertTrue(patch.voiceCables.isEmpty)
    }

    /// File ▸ Insert Patch File… kładzie blok pod wszystkim (`bottomRow`) — nic nie zjeżdża.
    func testInsertBelowEverythingMovesNothing() {
        var patch = G2Patch()
        patch.voiceModules = [module(1, column: 0, row: 0), module(2, column: 0, row: 5), module(3, column: 2, row: 1)]
        let before = patch.voiceModules
        var block = G2Patch()
        block.voiceModules = [module(1, column: 3, row: 3), module(2, column: 4, row: 3)]

        let row = patch.bottomRow(in: .voice)
        patch.insertBlock(block, dropArea: .voice, column: 0, row: row)

        XCTAssertEqual(row, 5 + Self.height(before[1]))
        XCTAssertEqual(Array(patch.voiceModules.prefix(3)), before)
        XCTAssertEqual(patch.voiceModules.suffix(2).map { [$0.column, $0.row] }, [[0, row], [1, row]])
        XCTAssertEqual(G2Patch().bottomRow(in: .voice), 0, "an empty area starts at the top")
    }

    /// Moduł pokazuje wartości aktywnej wariacji patcha, nie bloku.
    func testParametersFollowTargetActiveVariation() {
        var patch = G2Patch()
        patch.setActiveVariation(3)
        var source = module(1, column: 0, row: 0)
        source.parameterVariations[3] = [42]
        var block = G2Patch()
        block.voiceModules = [source]

        patch.insertBlock(block, dropArea: .voice, column: 0, row: 0)

        XCTAssertEqual(patch.voiceModules.first?.parameters, [42])
    }

    func testInsertIsOneUndoStep() throws {
        let target = try XCTUnwrap(PatchParser.parse(data: Data(contentsOf: Self.fixture)).first)
        var block = G2Patch()
        block.voiceModules = [module(1, column: 0, row: 0), module(2, column: 0, row: 2)]
        block.voiceCables = [cable(1, 2)]
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        state.slots[0] = target
        let before = state.patch

        state.undoManager.beginUndoGrouping()
        let inserted = state.insertBlock(block, area: .voice, column: 0, row: 0)
        state.undoManager.endUndoGrouping()

        XCTAssertEqual(inserted[.voice]?.count, 2)
        XCTAssertEqual(state.undoManager.undoActionName, "Insert Block")
        state.undoManager.undo()
        XCTAssertEqual(state.patch.voiceModules, before.voiceModules)
        XCTAssertEqual(state.patch.voiceCables, before.voiceCables)
        state.undoManager.redo()
        XCTAssertEqual(state.patch.voiceModules.count, before.voiceModules.count + 2)
    }

    // MARK: - Morfy, gałki i CC bloku (okienko po upuszczeniu)

    /// Blok z gałką, CC i morfem; jego moduł 7 dostanie w patchu numer 2.
    private func blockWithAssignments() -> G2Patch {
        var block = G2Patch()
        block.voiceModules = [module(7, column: 0, row: 0)]
        block.knobAssignments[3] = G2KnobAssignment(location: 1, moduleID: 7, paramIndex: 0)
        block.knobAssignments[4] = G2KnobAssignment(location: 1, moduleID: 7, paramIndex: 1)
        block.midiControllerAssignments[20] = G2MidiControllerAssignment(location: 1, moduleID: 7, paramIndex: 0)
        block.morphAssignments[2] = [G2MorphAssignment(location: 1, moduleID: 7, paramIndex: 0, morph: 1, range: 40)]
        // Ustawienia patcha bloku (obszar 2) należą do bloku jako patcha — nie przechodzą.
        block.knobAssignments[5] = G2KnobAssignment(location: 2, moduleID: 1, paramIndex: 0)
        return block
    }

    func testChosenAssignmentsFollowTheNewModuleNumbers() {
        var patch = G2Patch()
        patch.voiceModules = [module(1, column: 3, row: 0)]
        patch.knobAssignments[4] = G2KnobAssignment(location: 1, moduleID: 1, paramIndex: 0)

        let result = patch.insertBlock(blockWithAssignments(), dropArea: .voice, column: 0, row: 0,
                                       carrying: [.morphs, .knobs, .midiControllers])

        XCTAssertEqual(result.modules, [.voice: [2]])
        XCTAssertEqual(patch.knobAssignment(at: 3), G2KnobAssignment(location: 1, moduleID: 2, paramIndex: 0))
        XCTAssertEqual(patch.knobAssignment(at: 4)?.moduleID, 1, "taken knob keeps its parameter")
        XCTAssertNil(patch.knobAssignment(at: 5), "patch-settings knob of the block stays behind")
        XCTAssertEqual(patch.midiControllerAssignments[20]?.moduleID, 2)
        XCTAssertEqual(patch.morphRange(variation: 2, location: 1, moduleID: 2, paramIndex: 0, morph: 1), 40)
        XCTAssertEqual(result.offered, [.knobs: 2, .midiControllers: 1, .morphs: 1, .patchSettings: 0, .morphKnobs: 0, .morphNames: 0])
        XCTAssertEqual(result.skipped, [.knobs: 1, .midiControllers: 0, .morphs: 0])
        XCTAssertEqual(Array(result.knobs.keys), [3])
        XCTAssertEqual(result.morphs.map(\.variation), [2])
    }

    /// Bez wyboru nic z przypisań nie przechodzi, ale liczby dla okienka są te same.
    func testUnchosenAssignmentsStayBehindButAreCounted() {
        var patch = G2Patch()
        let before = patch

        let result = patch.insertBlock(blockWithAssignments(), dropArea: .voice, column: 0, row: 0)

        XCTAssertEqual(patch.knobAssignments, before.knobAssignments)
        XCTAssertEqual(patch.midiControllerAssignments, before.midiControllerAssignments)
        XCTAssertEqual(patch.morphAssignments, before.morphAssignments)
        XCTAssertFalse(result.hasAssignments)
        XCTAssertEqual(result.offered, [.knobs: 2, .midiControllers: 1, .morphs: 1, .patchSettings: 0, .morphKnobs: 0, .morphNames: 0])
        XCTAssertEqual(patch.blockAssignmentPreview(blockWithAssignments()).offered, result.offered)
    }

    /// Wariacja z kompletem 25 morfowanych parametrów nie przyjmie nowego.
    func testMorphOverTheLimitIsSkipped() {
        var patch = G2Patch()
        patch.voiceModules = [module(1, column: 3, row: 0)]
        patch.morphAssignments[2] = (0 ..< G2Morph.maxAssignmentsPerVariation).map {
            G2MorphAssignment(location: 1, moduleID: 1, paramIndex: $0, morph: 0, range: 10)
        }

        let result = patch.insertBlock(blockWithAssignments(), dropArea: .voice, column: 0, row: 0,
                                       carrying: [.morphs])

        XCTAssertEqual(result.skipped[.morphs], 1)
        XCTAssertTrue(result.morphs.isEmpty)
        XCTAssertEqual(patch.morphAssignments[2].count, G2Morph.maxAssignmentsPerVariation)
    }

    func testInsertWithAssignmentsIsOneUndoStepAndReportsThem() {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        var reported: G2BlockInsertion?
        state.onBlockAssignmentsInsert = { _, insertion in reported = insertion }
        let before = state.patch

        state.undoManager.beginUndoGrouping()
        state.insertBlock(blockWithAssignments(), area: .voice, column: 0, row: 0, carrying: [.knobs])
        state.undoManager.endUndoGrouping()

        XCTAssertEqual(reported?.knobs.count, 2)
        XCTAssertTrue(reported?.morphs.isEmpty ?? false)
        state.undoManager.undo()
        XCTAssertEqual(state.patch.knobAssignments, before.knobAssignments)
        XCTAssertEqual(state.patch.voiceModules, before.voiceModules)
    }

    /// ⇧⌘Z wstawienia dosyła do Norda gałki, CC i morfy bloku; ⌘Z zwalnia gałki, CC i morfy
    /// modułów bloku, zanim te znikną.
    func testUndoAndRedoOfInsertReportAssignmentChanges() {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        var reported: [G2AssignmentChanges] = []
        state.onAssignmentChanges = { _, changes in reported.append(changes) }

        state.undoManager.beginUndoGrouping()
        state.insertBlock(blockWithAssignments(), area: .voice, column: 0, row: 0,
                          carrying: [.knobs, .midiControllers, .morphs])
        state.undoManager.endUndoGrouping()
        XCTAssertTrue(reported.isEmpty, "the insert itself goes through onBlockAssignmentsInsert")

        state.undoManager.undo()
        XCTAssertEqual(reported.last?.knobs.count, 2)
        XCTAssertTrue(reported.last?.knobs.values.allSatisfy { $0 == nil } ?? false)
        XCTAssertEqual(reported.last?.midiControllers.count, 1)
        XCTAssertEqual(reported.last?.morphs.map(\.assignment.range), [0], "its morph is cleared too")

        state.undoManager.redo()
        XCTAssertEqual(reported.last?.knobs.values.compactMap(\.self).count, 2)
        XCTAssertEqual(reported.last?.midiControllers.values.compactMap(\.self).first??.moduleID,
                       state.patch.voiceModules.first?.id)
        XCTAssertEqual(reported.last?.morphs.map(\.variation), [2])
        XCTAssertEqual(reported.last?.morphs.first?.assignment.range, 40)
    }

    /// Skasowany moduł zabiera swoje gałki, CC, morfy i podpisy; cudze zostają, a Nord
    /// dostaje zwolnienie gałki i CC. Następny moduł pod tym numerem nie dziedziczy niczego.
    func testDeletedModuleTakesItsAssignmentsAndLabelsAlong() throws {
        let state = PatchState()
        state.slots[0].voiceModules = [module(1, column: 0, row: 0), module(2, column: 1, row: 0)]
        state.slots[0].knobAssignments[3] = G2KnobAssignment(location: 1, moduleID: 1, paramIndex: 0)
        state.slots[0].knobAssignments[4] = G2KnobAssignment(location: 1, moduleID: 2, paramIndex: 0)
        state.slots[0].midiControllerAssignments[20] = G2MidiControllerAssignment(location: 1, moduleID: 1, paramIndex: 0)
        state.slots[0].morphAssignments[2] = [G2MorphAssignment(location: 1, moduleID: 1, paramIndex: 0, morph: 1, range: 40),
                                              G2MorphAssignment(location: 1, moduleID: 2, paramIndex: 0, morph: 1, range: 20)]
        state.slots[0].moduleCustomData[1] = labels([(1, [1]), (2, [2])])
        var reported: G2AssignmentChanges?
        state.onAssignmentChanges = { _, changes in reported = changes }

        state.deleteModules(moduleIDs: [1], area: .voice)

        let patch = state.patch
        XCTAssertNil(patch.knobAssignment(at: 3))
        XCTAssertEqual(patch.knobAssignment(at: 4)?.moduleID, 2)
        XCTAssertNil(patch.midiControllerAssignments[20])
        XCTAssertEqual(patch.morphAssignments[2].map(\.moduleID), [2])
        XCTAssertEqual(try XCTUnwrap(patch.moduleLabels(in: .voice)).entries.map(\.moduleID), [2])
        XCTAssertEqual(reported?.knobs.keys.sorted(), [3])
        XCTAssertEqual(reported?.midiControllers.keys.sorted(), [20])
        XCTAssertEqual(reported?.morphs.map(\.assignment.moduleID), [1])
        XCTAssertEqual(reported?.morphs.map(\.assignment.range), [0])

        state.undoManager.undo()
        XCTAssertEqual(state.patch.knobAssignment(at: 3)?.moduleID, 1, "undo brings them back")
        XCTAssertEqual(reported?.morphs.map(\.assignment.range), [40], "and sends them to the Nord again")
    }

    /// Jak w oryginalnym edytorze: zwolnienie gałek, CC i morfów kasowanych modułów idzie do Norda
    /// PRZED skasowaniem modułów, przywrócenie po ⌘Z — PO ich powrocie. Skasowania modułów z przypiętą
    /// gałką Nord nie potwierdził (2026-10-23).
    func testAssignmentClearsGoBeforeTheModulesAreDeleted() {
        let state = PatchState()
        state.slots[0].voiceModules = [module(1, column: 0, row: 0)]
        state.slots[0].knobAssignments[3] = G2KnobAssignment(location: 1, moduleID: 1, paramIndex: 0)
        state.slots[0].variationSettings[0].glide = 1
        var order: [String] = []
        state.onLiveStructureChange = { _, _ in order.append("structure") }
        state.onAssignmentChanges = { _, changes in
            order.append(changes.knobs.values.contains { $0 == nil } ? "clear" : "assign")
        }

        state.deleteModules(moduleIDs: [1], area: .voice)
        XCTAssertEqual(order, ["clear", "structure"])

        order = []
        state.undoManager.undo()
        XCTAssertEqual(order, ["structure", "assign"])

        let split = G2AssignmentChanges.split(state.patch, { var p = state.patch
            p.deleteModules(moduleIDs: [1], in: .voice)
            p.variationSettings[0].glide = 0
            return p }())
        XCTAssertEqual(split.beforeStructure.knobs.keys.sorted(), [3])
        XCTAssertTrue(split.afterStructure.knobs.isEmpty)
        XCTAssertEqual(split.afterStructure.settings.count, 1, "settings go after the structure")
    }

    /// Nord nie odświeża ekranu bieżącej strony po (od)pięciu gałki — zmiana na oglądanej
    /// stronie każe ją wybrać ponownie, zmiana na innej stronie nie.
    func testKnobChangesOnTheShownPageAskForAPageRefresh() {
        let state = PatchState()
        state.slots[0].voiceModules = [module(1, column: 0, row: 0), module(2, column: 1, row: 0)]
        state.slots[0].knobAssignments[3] = G2KnobAssignment(location: 1, moduleID: 1, paramIndex: 0)
        state.slots[0].knobAssignments[G2KnobPages.knobIndex(page: 5, slot: 0)] =
            G2KnobAssignment(location: 1, moduleID: 2, paramIndex: 0)
        var refresh: [Int?] = []
        state.onAssignmentChanges = { _, changes in refresh.append(changes.refreshPage) }
        var blockRefresh: Int??
        state.onBlockAssignmentsInsert = { _, insertion in blockRefresh = insertion.refreshPage }

        state.deleteModules(moduleIDs: [1], area: .voice)
        state.deleteModules(moduleIDs: [2], area: .voice)
        XCTAssertEqual(refresh, [0, nil], "page A1 is shown, page 5 is not")

        state.insertBlock(blockWithAssignments(), area: .voice, column: 0, row: 0, carrying: [.knobs])
        XCTAssertEqual(blockRefresh, .some(0), "the block's knobs 3 and 4 sit on the shown page")
    }

    /// Ustawienia patcha i gałka morfu z różnicą lecą z nową wartością; zniknięty morf
    /// istniejącego modułu dostaje zakres 0.
    func testAssignmentChangesCoverSettingsMorphKnobsAndRemovedMorphs() {
        var old = G2Patch()
        old.voiceModules = [module(1, column: 0, row: 0)]
        old.morphAssignments[0] = [G2MorphAssignment(location: 1, moduleID: 1, paramIndex: 0, morph: 3, range: 12)]
        var new = old
        new.morphAssignments[0] = []
        new.variationSettings[4].glide = 1
        new.variationSettings[4].morphDials[2] = 77

        let changes = G2AssignmentChanges.between(old, new)

        XCTAssertEqual(changes.morphs.map(\.assignment.range), [0])
        XCTAssertEqual(changes.settings, [
            G2BlockSetting(variation: 4, module: G2PatchSetting.glide.module, param: G2PatchSetting.glide.param, value: 1),
            G2BlockSetting(variation: 4, module: 1, param: 2, value: 77),
        ])
        XCTAssertTrue(G2AssignmentChanges.between(new, new).isEmpty)
    }

    /// Blok z Glide i Bend, gałką i morfem na Glide oraz przestawioną gałką morfu 1.
    private func blockWithSettings() -> G2Patch {
        var block = blockWithAssignments()
        let glide = G2PatchSetting.glide
        for variation in 0 ..< G2Patch.storedVariationCount {
            block.variationSettings[variation].glide = 1
            block.variationSettings[variation].patchVolume = 20
            block.variationSettings[variation].morphDials[1] = 90
            block.variationSettings[variation].morphDials[6] = 50
        }
        block.variationSettings[3].bend = 1
        block.knobAssignments[10] = G2KnobAssignment(location: 2, moduleID: glide.module, paramIndex: glide.param)
        block.morphAssignments[0].append(G2MorphAssignment(location: 2, moduleID: glide.module,
                                                           paramIndex: glide.param, morph: 1, range: 5))
        return block
    }

    /// Bez pól „Patch settings" i „Morph knobs" patch zachowuje swoje ustawienia,
    /// a gałka na Glide bloku zostaje w bloku — ale okienko zna liczby.
    func testSettingsStayUnlessChosen() {
        var patch = G2Patch()
        let before = patch.variationSettings

        let result = patch.insertBlock(blockWithSettings(), dropArea: .voice, column: 0, row: 0,
                                       carrying: [.knobs, .morphs])

        XCTAssertEqual(patch.variationSettings, before)
        XCTAssertNil(patch.knobAssignment(at: 10))
        XCTAssertEqual(patch.morphs(in: 0).count, 0)
        XCTAssertEqual(result.offered[.patchSettings], 2, "Glide and Bend Range, not the volume")
        XCTAssertEqual(result.offered[.morphKnobs], 1, "only morph 1 is used by the block")
        XCTAssertEqual(result.offered[.knobs], 2, "settings knobs are not counted as knobs")
        XCTAssertTrue(result.settings.isEmpty)
    }

    func testChosenSettingsReplaceThePatchButNeverTheVolume() {
        var patch = G2Patch()

        let result = patch.insertBlock(blockWithSettings(), dropArea: .voice, column: 0, row: 0,
                                       carrying: [.knobs, .morphs, .patchSettings, .morphKnobs])

        XCTAssertEqual(patch.variationSettings[0].glide, 1)
        XCTAssertEqual(patch.variationSettings[3].bend, 1)
        XCTAssertEqual(patch.variationSettings[0].patchVolume, G2VariationSettings().patchVolume)
        XCTAssertEqual(patch.variationSettings[0].morphDials[1], 90)
        XCTAssertEqual(patch.variationSettings[0].morphDials[6], 0, "morph 6 is not used by the block")
        XCTAssertEqual(patch.knobAssignment(at: 10)?.location, 2)
        XCTAssertEqual(patch.morphRange(variation: 0, location: 2, moduleID: G2PatchSetting.glide.module,
                                        paramIndex: G2PatchSetting.glide.param, morph: 1), 5)
        XCTAssertEqual(result.settingNames, ["Glide", "Bend Range"])
        XCTAssertEqual(result.morphKnobNames, ["Vel"])
        XCTAssertEqual(result.settings.filter { $0.module == 1 }.count, G2Patch.storedVariationCount)
        XCTAssertTrue(result.settings.allSatisfy { $0.variation < G2Patch.storedVariationCount })
    }

    // MARK: - Uprate

    /// Blok z błędnymi flagami uprate (np. przerobiony z G1 przez g2ools) dostaje je po
    /// wstawieniu policzone od nowa, jak przy otwarciu pliku (#141). OscB → EnvADSR:
    /// obwiednia z audio na dwukolorowym wejściu musi pracować z częstotliwością audio;
    /// LfoC → EnvADSR: sterowanie, bez uprate — choćby plik twierdził inaczej.
    func testInsertedBlockGetsItsUprateRecomputed() {
        let oscB = 7, envADSR = 20, lfoC = 24
        var block = G2Patch()
        block.voiceModules = [G2Module(id: 1, typeID: oscB, area: .voice),
                              G2Module(id: 2, typeID: envADSR, area: .voice),
                              G2Module(id: 3, typeID: lfoC, area: .voice),
                              G2Module(id: 4, typeID: envADSR, area: .voice)]
        block.voiceModules[3].uprate = true
        block.voiceCables = [G2Cable(fromModule: 1, fromConnector: 0, toModule: 2, toConnector: 0,
                                     color: .red, area: .voice),
                             G2Cable(fromModule: 3, fromConnector: 0, toModule: 4, toConnector: 0,
                                     color: .blue, area: .voice)]
        let state = PatchState()

        state.insertBlock(block, area: .voice, column: 0, row: 0)

        let uprate = Dictionary(uniqueKeysWithValues: state.patch.voiceModules.map { ($0.id, $0.uprate) })
        XCTAssertEqual(uprate[2], true, "audio into a two-colour input")
        XCTAssertEqual(uprate[4], false, "control into a two-colour input")
    }

    // MARK: - Dodatkowe dane modułów (0x5B)

    private func labels(_ entries: [(Int, [UInt8])], area: PatchArea = .voice) -> [UInt8] {
        G2ModuleLabelSection(area: area.rawValue,
                             entries: entries.map { G2ModuleLabelSection.Entry(moduleID: $0.0, content: $0.1) }).raw
    }

    /// Podpis modułu bloku idzie za nim pod nowy numer; podpis patcha zostaje, a wpis
    /// po skasowanym module pod numerem, który dostał moduł z bloku, znika.
    func testModuleLabelsFollowTheirModules() throws {
        var patch = G2Patch()
        patch.voiceModules = [module(1, column: 3, row: 0)]
        patch.moduleCustomData[1] = labels([(1, [1, 2, 3]), (2, [9, 9])])
        var block = G2Patch()
        block.voiceModules = [module(7, column: 0, row: 0), module(8, column: 0, row: 2)]
        block.moduleCustomData[1] = labels([(8, [4, 5])])

        let result = patch.insertBlock(block, dropArea: .voice, column: 0, row: 0)

        XCTAssertEqual(result.modules, [.voice: [2, 3]])
        let entries = try XCTUnwrap(patch.moduleLabels(in: .voice)).entries
        XCTAssertEqual(entries.map(\.moduleID), [1, 3])
        XCTAssertEqual(entries.last?.content, [4, 5])
    }

    /// Podpisy zaznaczonych modułów przeżywają zapis bloku na szablonie pustego patcha.
    func testSavedSelectionLabelsSurviveTheFile() throws {
        var patch = G2Patch()
        patch.voiceModules = [module(1, column: 0, row: 0)]
        patch.moduleCustomData[1] = labels([(1, [1, 3, 0, 79, 110, 0, 0, 0, 0, 0])])
        let block = try XCTUnwrap(patch.block(from: .voice, moduleIDs: [1]))

        let file = try PatchParser.saveAll(originalData: PatchParser.emptyPatchFile, patches: [block])
        let reread = try XCTUnwrap(PatchParser.parse(data: file).first)

        XCTAssertEqual(reread.moduleLabels(in: .voice), block.moduleLabels(in: .voice))
    }

    func testSavedSelectionKeepsOnlyItsModuleLabels() throws {
        var patch = G2Patch()
        patch.voiceModules = [module(1, column: 0, row: 0), module(2, column: 1, row: 0)]
        patch.moduleCustomData[1] = labels([(1, [1]), (2, [2])])

        let block = try XCTUnwrap(patch.block(from: .voice, moduleIDs: [2]))

        XCTAssertEqual(block.moduleLabels(in: .voice)?.entries,
                       [G2ModuleLabelSection.Entry(moduleID: 2, content: [2])])
        XCTAssertNil(try XCTUnwrap(patch.block(from: .voice, moduleIDs: [1])).moduleLabels(in: .fx))
    }

    // MARK: - Nazwy morfów

    /// Blok nazywa używany morf 1 („DL Cut") i nieużywany morf 6 (podpis autora).
    private func blockWithMorphNames() -> G2Patch {
        var block = blockWithAssignments()
        var names = G2MorphLabelSection.standard
        names.setName("DL Cut", morph: 1)
        names.setName("blue", morph: 6)
        block.moduleCustomData[2] = names.raw
        return block
    }

    func testMorphNamesComeOnlyWhenChosenAndOnlyForUsedMorphs() throws {
        var untouched = G2Patch()
        let skipped = untouched.insertBlock(blockWithMorphNames(), dropArea: .voice, column: 0, row: 0)
        XCTAssertEqual(skipped.morphNames, [1: "DL Cut"], "the unused morph 6 is not offered")
        XCTAssertEqual(skipped.offered[.morphNames], 1)
        XCTAssertNil(untouched.moduleCustomData[2], "unchosen names leave the patch alone")

        var patch = G2Patch()
        let result = patch.insertBlock(blockWithMorphNames(), dropArea: .voice, column: 0, row: 0,
                                       carrying: [.morphNames])
        let names = try XCTUnwrap(patch.morphLabels)
        XCTAssertTrue(result.carriesMorphNames)
        XCTAssertEqual(names.name(1), "DL Cut")
        XCTAssertEqual(names.name(6), "P.Stick", "unused morph keeps its name")
        XCTAssertEqual(names.name(0), "Wheel")
    }

    /// Zmiana nazwy w pasku: 7 znaków ASCII, pusta = domyślna, jeden krok ⌘Z, a różnica
    /// patcha niesie ją do Norda (`0x42`, obszar 2) — także przy cofaniu.
    func testRenameMorphTrimsUndoesAndReachesTheNord() {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        var sent: [G2Patch] = []
        state.onLiveStructureChange = { _, patch in sent.append(patch) }
        let original = state.patch

        state.undoManager.beginUndoGrouping()
        state.setMorphName(0, name: "  Cutoff Sweep ", slot: 0)
        state.undoManager.endUndoGrouping()

        XCTAssertEqual(state.patch.morphName(0), "Cutoff ")
        XCTAssertEqual(state.patch.morphName(1), "Vel")
        XCTAssertEqual(state.undoManager.undoActionName, "Rename Morph")
        XCTAssertEqual(G2PatchDiff.between(original, state.patch).labelsToWrite.map(\.location), [2])

        state.undoManager.undo()
        XCTAssertEqual(state.patch.morphName(0), "Wheel")
        XCTAssertEqual(G2PatchDiff.between(sent[0], state.patch).labelsToWrite.map(\.location), [2],
                       "undo sends the old name back")
        state.undoManager.redo()
        XCTAssertEqual(state.patch.morphName(0), "Cutoff ")

        state.undoManager.beginUndoGrouping()
        state.setMorphName(0, name: "", slot: 0)
        state.setMorphName(3, name: "Łódź", slot: 0)
        state.undoManager.endUndoGrouping()
        XCTAssertEqual(state.patch.morphName(0), "Wheel", "an empty name falls back to the default")
        XCTAssertEqual(state.patch.morphName(3), "Lodz", "Polish letters lose their marks — the Nord is ASCII only")
    }

    /// Pasek morfów pokazuje nazwy patcha; bez sekcji — domyślne Clavii.
    func testMorphNamesForDisplay() {
        var patch = G2Patch()
        XCTAssertEqual(patch.morphNames.first, "Wheel")
        XCTAssertEqual(patch.morphName(7), "G.Wh 2")
        var names = G2MorphLabelSection.standard
        names.setName("DL Cut", morph: 0)
        patch.moduleCustomData[2] = names.raw
        XCTAssertEqual(patch.morphName(0), "DL Cut")
        XCTAssertEqual(SlotHeader(patch: patch).morphNames[0], "DL Cut")
        XCTAssertEqual(patch.morphName(9), "Morph 10")
    }

    /// Nazwa domyślna z innej serii („Group 2") nie jest nazwą własną bloku.
    func testDefaultMorphNameSeriesAreNotOffered() {
        var block = blockWithAssignments()
        var names = G2MorphLabelSection.standard
        names.setName("Group 2", morph: 1)
        block.moduleCustomData[2] = names.raw

        XCTAssertTrue(G2Patch().blockAssignmentPreview(block).morphNames.isEmpty)
    }

    // MARK: - Podpisy modułów przy ⌘C/⌘V

    func testPastedModuleKeepsItsLabels() {
        let state = PatchState()
        state.slots[0].voiceModules = [module(1, column: 0, row: 0)]
        let clip = G2ClipboardContent.ClipModule(typeID: 1, column: 2, row: 0, parameters: [], parameterVariations: [],
                                                 modes: [], label: "Mix", color: 0, originalID: 5,
                                                 labelData: [1, 3, 0, 76, 101, 97, 100, 0, 0, 0])
        let content = G2ClipboardContent(modules: [clip], cables: [])

        let pasted = state.pasteModules(content, area: .voice)

        XCTAssertEqual(pasted, [2])
        XCTAssertEqual(state.patch.moduleLabels(in: .voice)?.entries,
                       [G2ModuleLabelSection.Entry(moduleID: 2, content: clip.labelData ?? [])])
    }

    /// Schowek zapisany przed dodaniem podpisów nadal się czyta.
    func testOldClipboardWithoutLabelsStillDecodes() throws {
        let json = #"{"modules":[{"typeID":1,"column":0,"row":0,"parameters":[],"parameterVariations":[],"#
            + #""modes":[],"label":"","color":0,"originalID":3}],"cables":[]}"#
        let content = try JSONDecoder().decode(G2ClipboardContent.self, from: Data(json.utf8))
        XCTAssertNil(content.modules.first?.labelData)
    }

    // MARK: - Save Selection as Block

    /// Blok z zaznaczenia: tylko wskazane moduły, tylko kable między nimi, róg w 0/0,
    /// wszystkie wariacje i nazwy zostają.
    func testSelectionBecomesBlockWithInnerCablesOnly() throws {
        var patch = G2Patch()
        var varied = module(2, column: 4, row: 6)
        varied.parameterVariations[5] = [77]
        patch.voiceModules = [module(1, column: 3, row: 2), varied, module(3, column: 8, row: 0)]
        patch.voiceCables = [cable(1, 2), cable(2, 3)]
        patch.fxModules = [module(1, column: 0, row: 0, area: .fx)]
        patch.knobAssignments[0] = G2KnobAssignment(location: 1, moduleID: 1, paramIndex: 0)

        let block = try XCTUnwrap(patch.block(from: .voice, moduleIDs: [1, 2, 99]))

        XCTAssertEqual(block.voiceModules.map(\.id), [1, 2])
        XCTAssertEqual(block.voiceModules.map { [$0.column, $0.row] }, [[0, 0], [1, 4]])
        XCTAssertEqual(block.voiceModules.map(\.label), ["M1", "M2"])
        XCTAssertEqual(block.voiceModules.last?.parameterVariations[5], [77])
        XCTAssertEqual(block.voiceCables, [cable(1, 2)])
        XCTAssertTrue(block.fxModules.isEmpty)
        XCTAssertNil(patch.block(from: .fx, moduleIDs: [2]), "number from the other area")
    }

    /// Zaznaczony moduł 1 (Voice) ma gałkę, CC i morf 1 z nazwą „DL Cut"; moduł 2 obok
    /// i moduł 1 w FX mają swoje — te zostają w patchu, tak jak ustawienia patcha.
    private func patchWithSelectionAssignments() -> G2Patch {
        var patch = G2Patch()
        patch.voiceModules = [module(1, column: 0, row: 0), module(2, column: 1, row: 0)]
        patch.fxModules = [module(1, column: 0, row: 0, area: .fx)]
        patch.knobAssignments[3] = G2KnobAssignment(location: 1, moduleID: 1, paramIndex: 0)
        patch.knobAssignments[4] = G2KnobAssignment(location: 1, moduleID: 2, paramIndex: 0)
        patch.knobAssignments[5] = G2KnobAssignment(location: 0, moduleID: 1, paramIndex: 0)
        patch.knobAssignments[6] = G2KnobAssignment(location: 2, moduleID: 1, paramIndex: 1)
        patch.knobAssignments[7] = G2KnobAssignment(location: 2, moduleID: 1, paramIndex: 3)
        let glide = G2PatchSetting.glide
        patch.knobAssignments[8] = G2KnobAssignment(location: 2, moduleID: glide.module, paramIndex: glide.param)
        patch.midiControllerAssignments[20] = G2MidiControllerAssignment(location: 1, moduleID: 1, paramIndex: 0)
        patch.midiControllerAssignments[21] = G2MidiControllerAssignment(location: 1, moduleID: 2, paramIndex: 0)
        patch.morphAssignments[2] = [
            G2MorphAssignment(location: 1, moduleID: 1, paramIndex: 0, morph: 1, range: 40),
            G2MorphAssignment(location: 1, moduleID: 2, paramIndex: 0, morph: 3, range: 20),
            G2MorphAssignment(location: 0, moduleID: 1, paramIndex: 0, morph: 3, range: 10),
        ]
        for variation in 0 ..< G2Patch.storedVariationCount {
            patch.variationSettings[variation].morphDials[1] = 90
            patch.variationSettings[variation].morphModes[1] = 0
            patch.variationSettings[variation].morphDials[3] = 50
            patch.variationSettings[variation].glide = 1
        }
        var names = G2MorphLabelSection.standard
        names.setName("DL Cut", morph: 1)
        names.setName("Other", morph: 3)
        patch.moduleCustomData[2] = names.raw
        return patch
    }

    func testSelectionCarriesItsKnobsMorphsAndMidiControllers() throws {
        let block = try XCTUnwrap(patchWithSelectionAssignments().block(from: .voice, moduleIDs: [1]))

        let knobs = block.knobAssignments.enumerated().compactMap { $0.element == nil ? nil : $0.offset }
        XCTAssertEqual(knobs, [3, 6], "the module's knob and the knob on its morph 1, same numbers")
        let ccs = block.midiControllerAssignments.enumerated().compactMap { $0.element == nil ? nil : $0.offset }
        XCTAssertEqual(ccs, [20])
        XCTAssertEqual(block.morphAssignments[2],
                       [G2MorphAssignment(location: 1, moduleID: 1, paramIndex: 0, morph: 1, range: 40)])
        XCTAssertEqual(block.variationSettings[4].morphDials[1], 90)
        XCTAssertEqual(block.variationSettings[4].morphModes[1], 0)
        XCTAssertEqual(block.variationSettings[4].morphDials[3], 0, "morph 3 is not used by the selection")
        XCTAssertEqual(block.variationSettings[4].glide, G2VariationSettings().glide, "patch settings stay")
        XCTAssertEqual(block.morphName(1), "DL Cut")
        XCTAssertEqual(block.morphName(3), "Aft.Tch", "unused morph keeps the default name")
    }

    /// Bez morfów z własną nazwą blok nie dostaje sekcji nazw — jak każdy pusty patch.
    func testSelectionWithoutNamedMorphsHasNoMorphNameSection() throws {
        var patch = patchWithSelectionAssignments()
        patch.moduleCustomData[2] = nil
        XCTAssertNil(try XCTUnwrap(patch.block(from: .voice, moduleIDs: [1])).moduleCustomData[2])
    }

    /// Gałki, CC, morfy i nazwy przeżywają zapis bloku i wracają przy wstawieniu.
    func testSavedSelectionAssignmentsSurviveTheFileAndInsertAgain() throws {
        let block = try XCTUnwrap(patchWithSelectionAssignments().block(from: .voice, moduleIDs: [1]))

        let file = try PatchParser.saveAll(originalData: PatchParser.emptyPatchFile, patches: [block])
        let reread = try XCTUnwrap(PatchParser.parse(data: file).first)

        XCTAssertEqual(reread.knobAssignments, block.knobAssignments)
        XCTAssertEqual(reread.midiControllerAssignments, block.midiControllerAssignments)
        XCTAssertEqual(Array(reread.morphAssignments.prefix(G2Patch.storedVariationCount)),
                       Array(block.morphAssignments.prefix(G2Patch.storedVariationCount)))
        XCTAssertEqual(reread.variationSettings[0].morphDials, block.variationSettings[0].morphDials)
        XCTAssertEqual(reread.morphNames, block.morphNames)

        var target = G2Patch()
        let result = target.insertBlock(reread, dropArea: .voice, column: 0, row: 0,
                                        carrying: [.knobs, .midiControllers, .morphs, .morphNames])
        XCTAssertEqual(result.offered[.knobs], 1)
        XCTAssertEqual(result.offered[.midiControllers], 1)
        XCTAssertEqual(result.offered[.morphs], 1)
        XCTAssertEqual(target.morphName(1), "DL Cut")
    }

    /// Zapisany blok to zwykły `.pch2`: czyta się z powrotem i wstawia jak każdy inny.
    func testSavedBlockReadsBackAndInsertsAgain() throws {
        let source = try XCTUnwrap(PatchParser.parse(data: Data(contentsOf: Self.fixture)).first)
        let ids = Set(source.voiceModules.prefix(3).map(\.id))
        let block = try XCTUnwrap(source.block(from: .voice, moduleIDs: ids))

        let file = try PatchParser.saveAll(originalData: PatchParser.emptyPatchFile, patches: [block])
        let reread = try XCTUnwrap(PatchParser.parse(data: file).first)

        XCTAssertEqual(reread.voiceModules.map(\.typeID), block.voiceModules.map(\.typeID))
        XCTAssertEqual(reread.voiceModules.map(\.parameterVariations), block.voiceModules.map(\.parameterVariations))
        XCTAssertEqual(reread.voiceCables, block.voiceCables)
        XCTAssertTrue(reread.fxModules.isEmpty)
        XCTAssertEqual(reread.moduleLabels(in: .voice)?.entries ?? [], block.moduleLabels(in: .voice)?.entries ?? [],
                       "0x5B on the skeleton")

        var target = source
        let inserted = target.insertBlock(reread, dropArea: .voice, column: 0, row: 0).modules
        XCTAssertEqual(inserted[.voice]?.count, ids.count)
        XCTAssertEqual(target.voiceCables.count, source.voiceCables.count + block.voiceCables.count)
    }

    // MARK: - Korpus: wszystkie bloki z paczki

    /// Każdy blok wstawiony do prawdziwego patcha: liczby modułów i kabli się sumują,
    /// żaden kabel nie wisi, numery są niepowtarzalne, układ bloku zachowany, blok nie
    /// nachodzi na stare moduły, a zapisany plik czyta się z powrotem bez strat.
    func testEveryBuildingBlockInsertsCleanly() throws {
        // Bez folderu (publiczne repo, CI) `contentsOfDirectory` rzuca — ma być pominięcie.
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: Self.blocksFolder, includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension.lowercased() == "pch2" }
        guard !files.isEmpty else { throw XCTSkip("Building Blocks folder not available") }
        let original = try Data(contentsOf: Self.fixture)
        let target = try XCTUnwrap(PatchParser.parse(data: original).first)
        var carried: [G2BlockAssignmentKind: Int] = [:]

        for file in files {
            let name = file.lastPathComponent
            let block = try XCTUnwrap(PatchParser.parse(data: Data(contentsOf: file)).first, name)
            var patch = target
            let result = patch.insertBlock(block, dropArea: .voice, column: 1, row: 2,
                                           carrying: Set(G2BlockAssignmentKind.allCases))
            let inserted = result.modules

            for area in PatchArea.allCases {
                if let raw = block.moduleCustomData[area.rawValue] {
                    let section = try XCTUnwrap(G2ModuleLabelSection(raw: raw), "\(name): 0x5B")
                    XCTAssertEqual(section.raw, raw, "\(name): 0x5B round trip")
                }
                let labelIDs = patch.moduleLabels(in: area)?.entries.map(\.moduleID) ?? []
                XCTAssertEqual(labelIDs.count,
                               (target.moduleLabels(in: area)?.entries.count ?? 0)
                                   + (block.moduleLabels(in: area)?.entries.count ?? 0), name)
                XCTAssertTrue(Set(labelIDs).isSubset(of: patch.modules(in: area).map(\.id)), "\(name): stray label")
                let blockModules = block.modules(in: area)
                let mods = patch.modules(in: area)
                let ids = mods.map(\.id)
                XCTAssertEqual(mods.count, target.modules(in: area).count + blockModules.count, name)
                XCTAssertEqual(patch.cables(in: area).count,
                               target.cables(in: area).count + block.cables(in: area).count, name)
                XCTAssertEqual(Set(ids).count, ids.count, "\(name): duplicate module numbers")
                XCTAssertTrue(ids.allSatisfy { (1 ... 255).contains($0) }, name)
                let idSet = Set(ids)
                for c in patch.cables(in: area) {
                    XCTAssertTrue(idSet.contains(c.fromModule) && idSet.contains(c.toModule),
                                  "\(name): dangling cable")
                }

                let newIDs = inserted[area] ?? []
                let added = mods.filter { newIDs.contains($0.id) }
                let old = mods.filter { !newIDs.contains($0.id) }
                if let first = added.first, let source = blockModules.first {
                    let dc = first.column - source.column
                    let dr = first.row - source.row
                    XCTAssertEqual(added.map { [$0.column - dc, $0.row - dr, $0.typeID] },
                                   blockModules.map { [$0.column, $0.row, $0.typeID] },
                                   "\(name): block layout changed")
                }
                for a in added {
                    for o in old where o.column == a.column {
                        let overlaps = (a.row ..< a.row + Self.height(a))
                            .overlaps(o.row ..< o.row + Self.height(o))
                        XCTAssertFalse(overlaps, "\(name): block covers \(o.label)")
                    }
                }
            }

            /// Przypisanie trafia na wstawiony moduł albo — dla ustawień patcha — na moduły 1–7.
            func lands(_ location: UInt8, _ moduleID: Int) -> Bool {
                guard let area = PatchArea(rawValue: location) else { return (1 ... 7).contains(moduleID) }
                return inserted[area]?.contains(moduleID) ?? false
            }
            for (index, knob) in result.knobs {
                XCTAssertTrue(lands(knob.location, knob.moduleID), "\(name): knob \(index)")
                XCTAssertEqual(patch.knobAssignment(at: index), knob, name)
            }
            for (cc, entry) in result.midiControllers {
                XCTAssertTrue(lands(entry.location, entry.moduleID), "\(name): CC \(cc)")
            }
            for morph in result.morphs {
                XCTAssertTrue(lands(morph.assignment.location, morph.assignment.moduleID), "\(name): morph")
                XCTAssertTrue(patch.morphs(in: morph.variation).contains(morph.assignment), name)
            }
            carried[.patchSettings, default: 0] += result.settings.filter { $0.module != 1 }.count
            carried[.morphKnobs, default: 0] += result.settings.filter { $0.module == 1 }.count
            carried[.knobs, default: 0] += result.knobs.count
            carried[.midiControllers, default: 0] += result.midiControllers.count
            carried[.morphs, default: 0] += result.morphs.count

            let saved = try PatchParser.saveAll(originalData: original, patches: [patch])
            let reread = try XCTUnwrap(PatchParser.parse(data: saved).first, name)
            for area in PatchArea.allCases {
                XCTAssertEqual(reread.modules(in: area).map(\.id), patch.modules(in: area).map(\.id), name)
                XCTAssertEqual(reread.modules(in: area).map(\.label), patch.modules(in: area).map(\.label), name)
                XCTAssertEqual(reread.cables(in: area), patch.cables(in: area), name)
            }
            XCTAssertEqual(reread.knobAssignments, patch.knobAssignments, name)
            XCTAssertNotNil(block.morphLabels, "\(name): morph names section")
            XCTAssertEqual(reread.morphLabels, patch.morphLabels, "\(name): morph names saved")
            for area in PatchArea.allCases {
                XCTAssertEqual(reread.moduleLabels(in: area), patch.moduleLabels(in: area), "\(name): 0x5B saved")
            }
            XCTAssertEqual(reread.midiControllerAssignments, patch.midiControllerAssignments, name)
            XCTAssertEqual(Array(reread.variationSettings.prefix(G2Patch.storedVariationCount)),
                           Array(patch.variationSettings.prefix(G2Patch.storedVariationCount)), name)
        }
        print("Building Blocks carried: \(carried)")
    }

    /// Każdy blok z paczki zapisany ponownie z zaznaczenia całego obszaru: gałki, CC i morfy
    /// modułów tego obszaru wychodzą takie same jak w oryginale i przeżywają plik.
    func testEveryBuildingBlockSavedFromFullSelectionKeepsItsAssignments() throws {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: Self.blocksFolder, includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension.lowercased() == "pch2" }
        guard !files.isEmpty else { throw XCTSkip("Building Blocks folder not available") }
        var kept = (knobs: 0, ccs: 0, morphs: 0)

        for file in files {
            let name = file.lastPathComponent
            let source = try XCTUnwrap(PatchParser.parse(data: Data(contentsOf: file)).first, name)
            for area in PatchArea.allCases where !source.modules(in: area).isEmpty {
                let ids = Set(source.modules(in: area).map(\.id))
                let block = try XCTUnwrap(source.block(from: area, moduleIDs: ids), name)
                let saved = try PatchParser.saveAll(originalData: PatchParser.emptyPatchFile, patches: [block])
                let reread = try XCTUnwrap(PatchParser.parse(data: saved).first, name)

                let knobs = source.knobAssignments.map { $0?.location == area.rawValue ? $0 : nil }
                XCTAssertEqual(reread.knobAssignments.map { $0?.location == area.rawValue ? $0 : nil },
                               knobs, "\(name): knobs")
                let ccs = source.midiControllerAssignments.map { $0?.location == area.rawValue ? $0 : nil }
                XCTAssertEqual(reread.midiControllerAssignments.map { $0?.location == area.rawValue ? $0 : nil },
                               ccs, "\(name): CC")
                for variation in 0 ..< G2Patch.storedVariationCount {
                    let theirs = source.morphAssignments[variation].filter {
                        $0.location == area.rawValue && $0.range != 0
                    }
                    XCTAssertEqual(reread.morphAssignments[variation].filter { $0.location == area.rawValue },
                                   theirs, "\(name): morphs in variation \(variation)")
                    kept.morphs += theirs.count
                }
                kept.knobs += knobs.compactMap(\.self).count
                kept.ccs += ccs.compactMap(\.self).count
            }
        }
        print("Building Blocks saved again with: \(kept)")
    }
}
