import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class PatchStateTests: XCTestCase {
    // MARK: - Pomocniki

    private func makeState(patch: G2Patch = G2Patch()) -> PatchState {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        state.slots[0] = patch
        return state
    }

    @discardableResult
    private func performUndoStep<Result>(
        on state: PatchState,
        _ action: () -> Result
    ) -> Result {
        state.undoManager.beginUndoGrouping()
        defer { state.undoManager.endUndoGrouping() }
        return action()
    }

    private func makeModule(id: Int, parameter: Int = 10, mode: Int = 1) -> G2Module {
        var module = G2Module(id: id, typeID: 1, area: .voice)
        module.parameters = [parameter]
        module.parameterVariations = Array(repeating: [parameter], count: 9)
        module.modes = [mode]
        return module
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .standardized
    }

    // MARK: - Parametry i tryby

    func testFiveParameterChangesInOneGestureCreateOneUndoStep() {
        var patch = G2Patch()
        patch.voiceModules = [makeModule(id: 1)]
        let state = makeState(patch: patch)

        performUndoStep(on: state) {
            state.beginParameterGesture()
            for value in [20, 30, 40, 50, 60] {
                state.setParameter(moduleID: 1, paramIndex: 0, value: value, area: .voice)
            }
            state.endParameterGesture()
        }

        XCTAssertEqual(state.patch.voiceModules[0].parameters[0], 60)
        state.undoManager.undo()
        XCTAssertEqual(state.patch.voiceModules[0].parameters[0], 10)
        XCTAssertFalse(state.undoManager.canUndo)

        state.undoManager.redo()
        XCTAssertEqual(state.patch.voiceModules[0].parameters[0], 60)
    }

    func testSeparateParameterChangesRemainSeparateUndoSteps() {
        var patch = G2Patch()
        patch.voiceModules = [makeModule(id: 1)]
        let state = makeState(patch: patch)

        performUndoStep(on: state) {
            state.setParameter(moduleID: 1, paramIndex: 0, value: 20, area: .voice)
        }
        performUndoStep(on: state) {
            state.setParameter(moduleID: 1, paramIndex: 0, value: 30, area: .voice)
        }

        state.undoManager.undo()
        XCTAssertEqual(state.patch.voiceModules[0].parameters[0], 20)
        state.undoManager.undo()
        XCTAssertEqual(state.patch.voiceModules[0].parameters[0], 10)
    }

    func testModeIsUndoableAndMomentaryParameterIsNot() {
        var patch = G2Patch()
        patch.voiceModules = [makeModule(id: 1)]
        let state = makeState(patch: patch)

        state.setMomentaryParameter(moduleID: 1, paramIndex: 0, value: 1, area: .voice)
        state.setMomentaryParameter(moduleID: 1, paramIndex: 0, value: 10, area: .voice)
        XCTAssertFalse(state.undoManager.canUndo)

        performUndoStep(on: state) {
            state.setMode(moduleID: 1, modeIndex: 0, value: 7, area: .voice)
        }
        XCTAssertEqual(state.patch.voiceModules[0].modes[0], 7)
        state.undoManager.undo()
        XCTAssertEqual(state.patch.voiceModules[0].modes[0], 1)
    }

    // MARK: - Start bez ekranu powitalnego

    /// Pusty dokument ze startu oddaje miejsce Nordowi, dopóki nikt go nie ruszy —
    /// inaczej podłączenie kabla wgrałoby pustkę w grające sloty.
    func testUntouchedStartMayBeReplacedByTheDeviceUntilTheFirstEdit() {
        let state = PatchState()
        state.startEmpty()
        XCTAssertTrue(state.isLoaded)
        XCTAssertEqual(state.slots.count, 4)
        XCTAssertTrue(state.mayBeReplacedByDevice)

        state.addModule(typeID: 1, area: .voice, column: 0, row: 0)
        XCTAssertFalse(state.mayBeReplacedByDevice)
    }

    func testOpeningAFileEndsTheUntouchedStart() {
        let state = PatchState()
        state.startEmpty()
        state.markSentToDevice()
        XCTAssertFalse(state.isUntouchedStart)
        XCTAssertTrue(state.mayBeReplacedByDevice) // bo teraz to samo jest w urządzeniu
        state.newPerformance()
        XCTAssertFalse(state.mayBeReplacedByDevice)
    }

    /// Zmiana zrobiona przy odłączonym kablu do Norda nie doszła — ponowne podłączenie
    /// nie może jej po cichu zastąpić jego zawartością.
    func testEditAfterDeviceLossIsProtectedFromTheDevice() {
        let state = PatchState()
        state.startEmpty()
        state.markSentToDevice()
        state.deviceLost()
        XCTAssertTrue(state.mayBeReplacedByDevice, "bez zmian po odłączeniu Nord może przejąć widok")

        state.addModule(typeID: 1, area: .voice, column: 0, row: 0)
        XCTAssertFalse(state.mayBeReplacedByDevice)

        state.markSentToDevice()
        XCTAssertTrue(state.mayBeReplacedByDevice, "po wysyłce Nord znów ma to samo")
    }

    // MARK: - Moduły i kable

    func testAddingModuleCanBeUndoneAndRedone() {
        let state = makeState()

        performUndoStep(on: state) {
            state.addModule(typeID: 1, area: .voice, column: 3, row: 4)
        }
        XCTAssertEqual(state.patch.voiceModules.count, 1)
        XCTAssertEqual(state.patch.voiceModules[0].column, 3)
        XCTAssertEqual(state.patch.voiceModules[0].row, 4)

        state.undoManager.undo()
        XCTAssertTrue(state.patch.voiceModules.isEmpty)
        state.undoManager.redo()
        XCTAssertEqual(state.patch.voiceModules.count, 1)
    }

    /// Numer zwrócony przez `addModule` wskazuje dokładnie dodany moduł — także gdy dwa
    /// moduły mają ten sam typ, gdy etykieta zmieni się na powtarzającą się i gdy moduł
    /// trafi do obszaru FX. Na tym kluczu opiera się każde „dodaj, a potem połącz".
    func testAddModuleReturnsTheNumberOfTheModuleItAdded() throws {
        let state = makeState()
        let oscB = 7

        let first = try XCTUnwrap(performUndoStep(on: state) { state.addModule(typeID: oscB, area: .voice) })
        let second = try XCTUnwrap(performUndoStep(on: state) { state.addModule(typeID: oscB, area: .voice) })
        let inFX = try XCTUnwrap(performUndoStep(on: state) { state.addModule(typeID: oscB, area: .fx) })

        XCTAssertEqual(Set([first, second, inFX]).count, 3)
        XCTAssertEqual(state.patch.voiceModules.map(\.id), [first, second])
        XCTAssertEqual(state.patch.fxModules.map(\.id), [inFX])

        performUndoStep(on: state) {
            state.renameModule(moduleID: second, label: "Osc", area: .voice)
            state.renameModule(moduleID: first, label: "Osc", area: .voice)
        }
        let renamed = state.patch.voiceModules.first { $0.id == second }
        XCTAssertEqual(renamed?.typeID, oscB)
        XCTAssertEqual(renamed?.label, "Osc")
    }

    func testAddModuleOfUnknownTypeReturnsNilAndAddsNothing() {
        let state = makeState()

        XCTAssertNil(state.addModule(typeID: -1, area: .voice))
        XCTAssertTrue(state.patch.voiceModules.isEmpty)
        XCTAssertFalse(state.undoManager.canUndo)
    }

    func testDeletingModuleRemovesItsCablesAndUndoRestoresCompletePatch() {
        var patch = G2Patch()
        patch.voiceModules = [makeModule(id: 1), makeModule(id: 2), makeModule(id: 3)]
        patch.voiceCables = [
            G2Cable(
                fromModule: 1,
                fromConnector: 0,
                toModule: 2,
                toConnector: 0,
                color: .red,
                area: .voice
            ),
            G2Cable(
                fromModule: 2,
                fromConnector: 0,
                toModule: 3,
                toConnector: 0,
                color: .blue,
                area: .voice
            ),
        ]
        let state = makeState(patch: patch)

        performUndoStep(on: state) {
            state.deleteModule(moduleID: 2, area: .voice)
        }
        XCTAssertEqual(state.patch.voiceModules.map(\.id), [1, 3])
        XCTAssertTrue(state.patch.voiceCables.isEmpty)

        state.undoManager.undo()
        XCTAssertEqual(state.patch.voiceModules.map(\.id), [1, 2, 3])
        XCTAssertEqual(state.patch.voiceCables, patch.voiceCables)

        state.undoManager.redo()
        XCTAssertEqual(state.patch.voiceModules.map(\.id), [1, 3])
        XCTAssertTrue(state.patch.voiceCables.isEmpty)
    }

    func testAddingAndRemovingCableAreUndoable() {
        let cable = G2Cable(
            fromModule: 1,
            fromConnector: 0,
            toModule: 2,
            toConnector: 1,
            color: .red,
            area: .voice
        )
        let state = makeState()

        performUndoStep(on: state) {
            state.addCable(cable)
        }
        XCTAssertEqual(state.patch.voiceCables, [cable])
        state.undoManager.undo()
        XCTAssertTrue(state.patch.voiceCables.isEmpty)
        state.undoManager.redo()
        XCTAssertEqual(state.patch.voiceCables, [cable])

        state.undoManager.removeAllActions()
        performUndoStep(on: state) {
            state.removeCable(cable)
        }
        XCTAssertTrue(state.patch.voiceCables.isEmpty)
        state.undoManager.undo()
        XCTAssertEqual(state.patch.voiceCables, [cable])
    }

    /// Przepięcie kabla (Option + przeciągnięcie na canvasie) to wyrwanie i wpięcie,
    /// ale dla użytkownika jeden ruch: JEDNO ⌘Z ma wrócić do stanu sprzed przepięcia.
    /// Wcześniej cofało się tylko wpięcie i kabel zostawał wyrwany.
    func testRepatchingACableIsOneUndoStep() {
        let old = G2Cable(fromModule: 1, fromConnector: 0, toModule: 2, toConnector: 1,
                          color: .red, area: .voice)
        let new = G2Cable(fromModule: 1, fromConnector: 0, toModule: 2, toConnector: 2,
                          color: .red, area: .voice)
        let state = makeState()
        performUndoStep(on: state) { state.addCable(old) }
        state.undoManager.removeAllActions()

        performUndoStep(on: state) {
            state.beginStructureGesture("Repatch Cable")
            state.removeCable(old)
            state.addCable(new)
            state.endStructureGesture()
        }
        XCTAssertEqual(state.patch.voiceCables, [new])

        state.undoManager.undo()
        XCTAssertEqual(state.patch.voiceCables, [old], "jedno ⌘Z wraca do stanu sprzed gestu")
        state.undoManager.redo()
        XCTAssertEqual(state.patch.voiceCables, [new])
    }

    /// Wyrwanie kabla i upuszczenie go na puste miejsce też jest jednym wpisem —
    /// i też musi się cofać, choć nic nie zostało wpięte.
    func testRepatchDroppedOnEmptySpaceUndoesInOneStep() {
        let cable = G2Cable(fromModule: 1, fromConnector: 0, toModule: 2, toConnector: 1,
                            color: .red, area: .voice)
        let state = makeState()
        performUndoStep(on: state) { state.addCable(cable) }
        state.undoManager.removeAllActions()

        performUndoStep(on: state) {
            state.beginStructureGesture("Repatch Cable")
            state.removeCable(cable)
            state.endStructureGesture()
        }
        XCTAssertTrue(state.patch.voiceCables.isEmpty)
        state.undoManager.undo()
        XCTAssertEqual(state.patch.voiceCables, [cable])
    }

    /// Gest, który niczego nie zmienił, nie zostawia wpisu — inaczej ⌘Z „nie działa",
    /// bo cofa ruch bez żadnego widocznego skutku.
    func testRepatchWithoutChangeLeavesNoUndoStep() {
        let cable = G2Cable(fromModule: 1, fromConnector: 0, toModule: 2, toConnector: 1,
                            color: .red, area: .voice)
        let state = makeState()
        performUndoStep(on: state) { state.addCable(cable) }
        state.undoManager.removeAllActions()

        let before = state.patch
        performUndoStep(on: state) {
            state.beginStructureGesture("Repatch Cable")
            state.removeCable(cable)
            state.addCable(cable)
            state.endStructureGesture()
        }
        XCTAssertEqual(state.patch, before, "gest wrócił dokładnie tam, skąd wyszedł")
        // Pusta grupa undo zostaje po `performUndoStep`, ale nie ma w niej żadnej akcji:
        // nazwa jest pusta, a cofnięcie niczego nie rusza.
        XCTAssertEqual(state.undoManager.undoActionName, "")
        state.undoManager.undo()
        XCTAssertEqual(state.patch, before)
    }

    func testPasteRestoresModulesAndCablesOnRedo() {
        let content = G2ClipboardContent(
            modules: [
                .init(
                    typeID: 1,
                    column: 2,
                    row: 3,
                    parameters: [],
                    parameterVariations: [],
                    modes: [],
                    label: "Source",
                    color: 1,
                    originalID: 10
                ),
                .init(
                    typeID: 1,
                    column: 4,
                    row: 5,
                    parameters: [],
                    parameterVariations: [],
                    modes: [],
                    label: "Target",
                    color: 2,
                    originalID: 20
                ),
            ],
            cables: [
                .init(
                    fromModule: 10,
                    fromConnector: 0,
                    toModule: 20,
                    toConnector: 1,
                    cableColor: Int(CableColor.blue.rawValue)
                ),
            ]
        )
        let state = makeState()

        let pastedIDs = performUndoStep(on: state) {
            state.pasteModules(content, area: .voice)
        }
        XCTAssertEqual(pastedIDs, [1, 2])
        XCTAssertEqual(state.patch.voiceModules.count, 2)
        XCTAssertEqual(state.patch.voiceCables.count, 1)

        state.undoManager.undo()
        XCTAssertTrue(state.patch.voiceModules.isEmpty)
        XCTAssertTrue(state.patch.voiceCables.isEmpty)

        state.undoManager.redo()
        XCTAssertEqual(state.patch.voiceModules.count, 2)
        XCTAssertEqual(state.patch.voiceCables.count, 1)
    }

    func testMoveRenameAndColorCanBeUndoneInOrder() {
        var module = makeModule(id: 1)
        module.label = "Before"
        module.color = 2
        var patch = G2Patch()
        patch.voiceModules = [module]
        let state = makeState(patch: patch)

        performUndoStep(on: state) {
            state.moveModule(moduleID: 1, newColumn: 4, newRow: 6, area: .voice)
        }
        performUndoStep(on: state) {
            state.renameModule(moduleID: 1, label: "After", area: .voice)
        }
        performUndoStep(on: state) {
            state.setModuleColor(moduleID: 1, color: 9, area: .voice)
        }

        state.undoManager.undo()
        XCTAssertEqual(state.patch.voiceModules[0].color, 2)
        state.undoManager.undo()
        XCTAssertEqual(state.patch.voiceModules[0].label, "Before")
        state.undoManager.undo()
        XCTAssertEqual(state.patch.voiceModules[0].column, 0)
        XCTAssertEqual(state.patch.voiceModules[0].row, 0)
    }

    // MARK: - Undo wraca do slotu, w którym zmiana powstała

    /// Do 2026-09-11 zdjęcie stanu wracało do slotu Z FOCUSEM: dodanie modułu w A,
    /// przełączenie na B i ⌘Z podmieniało patch B na stary patch A. Przy czterech
    /// pasach i oknach slotów przełączanie jest ciągłe, więc każda operacja
    /// strukturalna niesie swój slot w zamknięciu undo.
    func testUndoAfterSwitchingSlotRestoresTheSlotTheChangeWasMadeIn() {
        let state = makeState()
        state.newPerformance()
        var other = G2Patch()
        other.voiceModules = [makeModule(id: 7)]
        state.slots[1] = other

        performUndoStep(on: state) {
            state.addModule(typeID: 1, area: .voice, column: 3, row: 4)
        }
        XCTAssertEqual(state.slots[0].voiceModules.count, 1)
        state.focusSlot(1)

        state.undoManager.undo()

        XCTAssertTrue(state.slots[0].voiceModules.isEmpty, "cofnięcie ma zdjąć moduł ze slotu A")
        XCTAssertEqual(state.slots[1].voiceModules.map(\.id), [7], "slot B ma zostać nietknięty")
        XCTAssertEqual(state.selectedSlot, 1, "undo nie przenosi focusu")

        state.undoManager.redo()
        XCTAssertEqual(state.slots[0].voiceModules.count, 1)
        XCTAssertEqual(state.slots[1].voiceModules.map(\.id), [7])
    }

    func testCableAndColorUndoFollowTheirSlotToo() {
        var module = makeModule(id: 1)
        module.color = 2
        var patch = G2Patch()
        patch.voiceModules = [module, makeModule(id: 2)]
        let state = makeState()
        state.newPerformance()
        state.slots[2] = patch
        state.focusSlot(2)

        let cable = G2Cable(fromModule: 1, fromConnector: 0, toModule: 2, toConnector: 0,
                            color: .red, area: .voice, sourceIsOutput: true)
        performUndoStep(on: state) { state.addCable(cable) }
        performUndoStep(on: state) { state.removeCable(cable) }
        performUndoStep(on: state) { state.setModuleColor(moduleID: 1, color: 9, area: .voice) }
        state.focusSlot(0)

        state.undoManager.undo()
        XCTAssertEqual(state.slots[2].voiceModules[0].color, 2)
        state.undoManager.undo()
        XCTAssertEqual(state.slots[2].voiceCables.count, 1, "kabel wraca do slotu C")
        state.undoManager.undo()
        XCTAssertTrue(state.slots[2].voiceCables.isEmpty)
        XCTAssertTrue(state.slots[0].voiceCables.isEmpty, "slot A nie dostał cudzego kabla")
        XCTAssertTrue(state.slots[0].voiceModules.isEmpty)
    }

    /// `focusSlot` nic nie robi poza zakresem i przy tym samym slocie — przełączenie ma
    /// skutki uboczne (komenda do Norda), więc nie wolno go powtarzać.
    func testFocusSlotIgnoresOutOfRangeAndSameSlot() {
        let state = makeState()
        state.newPerformance()
        state.focusSlot(9)
        XCTAssertEqual(state.selectedSlot, 0)
        state.focusSlot(3)
        XCTAssertEqual(state.selectedSlot, 3)
        XCTAssertEqual(state.voiceModeIndex(slot: 3), state.voiceModeIndex)
    }

    // MARK: - Cykl życia dokumentu

    func testSuccessfulLoadClearsUndoHistory() {
        var patch = G2Patch()
        patch.voiceModules = [makeModule(id: 1)]
        let state = makeState(patch: patch)
        performUndoStep(on: state) {
            state.setParameter(moduleID: 1, paramIndex: 0, value: 20, area: .voice)
        }
        XCTAssertTrue(state.undoManager.canUndo)

        state.load(url: fixtureURL("simplesynth001-20240802.pch2"))

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.fileName, "simplesynth001-20240802.pch2")
        XCTAssertFalse(state.undoManager.canUndo)
        XCTAssertFalse(state.undoManager.canRedo)
    }

    /// Opcja „jak oryginał”: `.pch2` do slotu A, B–D puste, cały komplet jedzie do Norda.
    func testLikeOriginalPutsThePatchIntoSlotAAndClearsTheRest() {
        let state = makeState()
        state.slots = (0 ..< 4).map { namedPatch("Old \($0)") }
        state.selectedSlot = 2

        let onlySlot = state.load(url: fixtureURL("simplesynth001-20240802.pch2"), patchOpenMode: .likeOriginal)

        XCTAssertFalse(onlySlot, "do Norda jadą wszystkie cztery sloty")
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.selectedSlot, 0)
        XCTAssertEqual(state.slots[0].name, "simplesynth001-2")
        XCTAssertEqual(state.slotFileURLs[0], fixtureURL("simplesynth001-20240802.pch2"))
        for slot in 1 ..< 4 {
            XCTAssertTrue(state.slots[slot].voiceModules.isEmpty && state.slots[slot].fxModules.isEmpty)
            XCTAssertNil(state.slotFileURLs[slot])
        }
        XCTAssertFalse(state.hasPerformanceSettings)
    }

    /// Plik, którego nie da się odczytać, nie może wyczyścić slotów.
    func testLikeOriginalKeepsSlotsWhenTheFileIsBroken() {
        let state = makeState()
        state.slots = (0 ..< 4).map { namedPatch("Old \($0)") }

        state.load(url: fixtureURL("missing-file.pch2"), patchOpenMode: .likeOriginal)

        XCTAssertNotNil(state.errorMessage)
        XCTAssertEqual(state.slots.map(\.name), ["Old 0", "Old 1", "Old 2", "Old 3"])
    }

    // MARK: - Most z urządzeniem (kto komu wolno podmienić zawartość)

    private func namedPatch(_ name: String) -> G2Patch {
        var patch = G2Patch()
        patch.name = name
        return patch
    }

    func testFreshlyOpenedFileIsNotReplacedByDevice() {
        let state = makeState()
        state.load(url: fixtureURL("simplesynth001-20240802.pch2"))
        XCTAssertFalse(state.mirrorsDevice)

        state.replaceSlotsFromDevice(patches: (0 ..< 4).map { namedPatch("Nord \($0)") })
        state.replaceSlotFromDevice(slot: 0, patch: namedPatch("Nord 0"))

        // Plik otwarty przy odłączonym Nordzie: podłączenie kabla ani ruch na froncie
        // urządzenia nie mogą skasować pracy użytkownika.
        XCTAssertEqual(state.slots[0].name, "simplesynth001-2")
        XCTAssertEqual(state.slotFileURLs[0], fixtureURL("simplesynth001-20240802.pch2"))
    }

    func testDeviceTakesOverAfterFileWentToTheNord() {
        let state = makeState()
        state.load(url: fixtureURL("simplesynth001-20240802.pch2"))
        state.markSentToDevice()

        state.replaceSlotsFromDevice(patches: (0 ..< 4).map { namedPatch("Nord \($0)") })

        // Plik jest już w Nordzie, więc patch załadowany na jego froncie ma wejść na ekran —
        // bez żadnego pliku, do którego Save mógłby wpisać cudzą zawartość.
        XCTAssertEqual(state.slots.map(\.name), ["Nord 0", "Nord 1", "Nord 2", "Nord 3"])
        XCTAssertEqual(state.fileName, "Nord G2")
        XCTAssertNil(state.fileURL)
        XCTAssertEqual(state.slotFileURLs, [nil, nil, nil, nil])
        XCTAssertFalse(state.hasUnsavedChanges)
    }

    func testDeviceReloadKeepsTheSlotUserIsLookingAt() {
        let state = makeState()
        state.loadFromDevice(patches: (0 ..< 4).map { namedPatch("old \($0)") })
        state.selectedSlot = 2

        state.replaceSlotsFromDevice(patches: (0 ..< 4).map { namedPatch("new \($0)") })

        XCTAssertEqual(state.selectedSlot, 2)
        XCTAssertEqual(state.patch.name, "new 2")
    }

    /// Nord podaje mniej slotów (albo więcej) — edytor ma zawsze cztery.
    func testDeviceContentAlwaysFillsFourSlots() {
        let state = makeState()
        state.loadFromDevice(patches: [namedPatch("Nord 0")])

        XCTAssertEqual(state.slots.map(\.name), ["Nord 0", "No name", "No name", "No name"])
    }

    // MARK: - New Patch / New Performance

    /// Clavia `HandleMenuFileNew(false)` z focusem na slocie robi `CreateEmptyDownloadPatch`
    /// dla TEGO slotu — reszta performance'u zostaje nietknięta.
    func testNewPatchClearsOnlyTheFocusedSlot() {
        let state = makeState()
        state.loadFromDevice(patches: (0 ..< 4).map { namedPatch("Nord \($0)") })
        state.slots[2].voiceModules = [makeModule(id: 1)]
        state.selectedSlot = 2

        state.newPatch()

        XCTAssertEqual(state.slots.count, 4)
        XCTAssertEqual(state.selectedSlot, 2)
        XCTAssertTrue(state.patch.voiceModules.isEmpty)
        XCTAssertEqual(state.patch.name, "No name")
        XCTAssertEqual(state.slots.map(\.name), ["Nord 0", "Nord 1", "No name", "Nord 3"])
    }

    /// New Patch odcina plik TYLKO swojego slotu — inaczej ⌘S zaraz po ⌘N nadpisałby czyjś
    /// patch pustką; plik sąsiedniego slotu zostaje.
    func testNewPatchDetachesOnlyThatSlotsFile() {
        let state = makeState()
        let url = fixtureURL("simplesynth001-20240802.pch2")
        state.load(url: url)
        state.load(url: url, intoSlot: 1)
        XCTAssertTrue(state.canSave)

        state.newPatch()

        XCTAssertEqual(state.slots.count, 4)
        XCTAssertTrue(state.slots[1].voiceModules.isEmpty)
        XCTAssertEqual(state.slotFileURLs, [url, nil, nil, nil])
        XCTAssertFalse(state.canSave)
        XCTAssertNil(state.fileURL)
        XCTAssertFalse(state.slots[0].voiceModules.isEmpty)
        // Pusty patch to wciąż otwarta zawartość — canvas, nie ekran powitalny.
        XCTAssertTrue(state.isLoaded)
    }

    /// ⌘Z po New wraca do patcha z chwili kliknięcia (prośba z FB 2026-09-25); edycje sprzed
    /// New przepadają, bo dotyczyły tamtej zawartości.
    func testNewPatchUndoesToThePatchItReplaced() {
        var patch = G2Patch()
        patch.voiceModules = [makeModule(id: 1)]
        let state = makeState(patch: patch)
        performUndoStep(on: state) {
            state.setParameter(moduleID: 1, paramIndex: 0, value: 20, area: .voice)
        }
        let edited = state.patch
        var restored: [Int] = []
        state.onSlotRestore = { restored.append($0) }

        state.newPatch()
        XCTAssertTrue(state.patch.voiceModules.isEmpty)
        XCTAssertEqual(state.undoManager.undoActionName, "New Patch")

        state.undoManager.undo()
        XCTAssertEqual(state.patch, edited)
        XCTAssertFalse(state.undoManager.canUndo, "historia sprzed New przepada")
        XCTAssertEqual(restored, [0])

        state.undoManager.redo()
        XCTAssertTrue(state.patch.voiceModules.isEmpty)
        XCTAssertEqual(restored, [0, 0])
    }

    /// Cofnięcie New oddaje slotowi plik i stan „zapisany" — ⌘S po ⌘Z pisze tam, gdzie przed New.
    func testUndoingNewPatchGivesTheSlotItsFileBack() {
        let state = makeState()
        let url = fixtureURL("simplesynth001-20240802.pch2")
        state.load(url: url)
        state.selectedSlot = 2

        state.newPatch(inSlot: 0)
        XCTAssertNil(state.slotFileURLs[0])

        state.undoManager.undo()
        XCTAssertEqual(state.slotFileURLs[0], url)
        XCTAssertEqual(state.selectedSlot, 0)
        XCTAssertFalse(state.slotHasUnsavedChanges(0))
        XCTAssertFalse(state.patch.voiceModules.isEmpty)
    }

    /// Clavia `CreateNewPerformance`: „Empty perf", cztery puste sloty, klawiatura i focus
    /// na `Slot::kOne`; BVerhue dokłada zegar 120 BPM stop. Gra tylko A — u Clavii wszystkie
    /// cztery, odstępstwo z decyzji użytkownika 2026-09-26.
    func testNewPerformanceOpensFourEmptySlotsWithOnlyAPlaying() {
        let state = makeState()
        state.load(url: fixtureURL("simplesynth001-20240802.pch2"))

        state.newPerformance()

        XCTAssertEqual(state.slots.count, 4)
        XCTAssertTrue(state.slots.allSatisfy { $0.voiceModules.isEmpty && $0.fxModules.isEmpty })
        XCTAssertEqual(state.selectedSlot, 0)
        XCTAssertEqual(state.fileName, "Empty perf")
        XCTAssertNil(state.fileURL)
        XCTAssertFalse(state.canSave)
        XCTAssertFalse(state.canSavePerformance)

        XCTAssertTrue(state.hasPerformanceSettings)
        XCTAssertEqual(state.performance.slots.map(\.enabled), [true, false, false, false])
        XCTAssertEqual(state.performance.slots.map(\.keyboard), [true, false, false, false])
        XCTAssertEqual(state.performance.focusedSlot, 0)
        XCTAssertEqual(state.performance.masterClock, 120)
        XCTAssertFalse(state.performance.masterClockRunning)
        XCTAssertEqual(state.performanceName, "Empty perf")
    }

    // MARK: - Nazwa performance'u

    /// Plik nie ma pola nazwy, więc nazwą jest nazwa pliku bez rozszerzenia — oryginał
    /// robi to samo (`CPerformance::LoadFromFile` → `MakePerformanceNameFromFileName`).
    /// `.pch2` wczytany do slotu nazwy performance'u nie rusza.
    func testPerformanceNameFollowsThePerformanceFile() throws {
        let state = makeState()
        let url = try temporaryPerformanceFile(named: "A long performance name")
        defer { try? FileManager.default.removeItem(at: url) }

        state.load(url: url)
        XCTAssertEqual(state.performanceName, "A long performan", "16 znaków, przycięte")

        state.load(url: fixtureURL("simplesynth001-20240802.pch2"))
        XCTAssertEqual(state.performanceName, "A long performan")
    }

    /// Urządzenie przyjmuje 16 znaków i tyle samo przyjmuje okno „Performance Name"
    /// oryginału — dłuższą nazwę przycinamy w miejscu, żeby ekran nie obiecywał czegoś,
    /// czego Nord nie pokaże.
    func testPerformanceNameIsClampedToSixteenCharacters() {
        let state = makeState()
        state.newPerformance()

        state.performanceName = "A performance with a very long name"

        XCTAssertEqual(state.performanceName, "A performance wi")
    }

    // MARK: - Sloty i ich pliki

    private func temporaryPerformanceFile(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("\(name).prf2")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try PatchParser.emptyPerformanceFile.write(to: url)
        return url
    }

    /// Plik jak z bety 0.1: ModADSR za filtrem z wyzerowanym uprate (oryginał ma tu 1).
    private func fileWithStaleUprate(performance: Bool) throws -> URL {
        let fixture = try Data(contentsOf: fixtureURL("simplesynth001-20240802.pch2"))
        var patch = try XCTUnwrap(try PatchParser.parse(data: fixture).first)
        XCTAssertTrue(patch.voiceModules[2].uprate, "w oryginale ModADSR ma uprate")
        patch.voiceModules[2].uprate = false
        let data = performance
            ? try PatchParser.saveAll(originalData: PatchParser.emptyPerformanceFile,
                                      patches: [patch, G2Patch(), G2Patch(), G2Patch()])
            : try PatchParser.saveAll(originalData: fixture, patches: [patch])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-uprate-\(UUID().uuidString).\(performance ? "prf2" : "pch2")")
        try data.write(to: url)
        return url
    }

    /// Patche zapisane przed naprawą #141 miały uprate 0. Przy otwieraniu pliku edytor
    /// po cichu przelicza flagi — bez pytania i bez gwiazdki „niezapisane zmiany".
    func testOpeningPatchFileSilentlyFixesStaleUprate() throws {
        let url = try fileWithStaleUprate(performance: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = makeState()

        state.load(url: url)

        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.slots[0].voiceModules[2].uprate)
        XCTAssertFalse(state.hasUnsavedChanges)
    }

    func testOpeningPerformanceFileSilentlyFixesStaleUprate() throws {
        let url = try fileWithStaleUprate(performance: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = makeState()

        state.load(url: url)

        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.slots[0].voiceModules[2].uprate)
        XCTAssertFalse(state.hasUnsavedChanges)
    }

    private func temporaryCopy(of name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g2-slot-\(UUID().uuidString).pch2")
        try Data(contentsOf: fixtureURL(name)).write(to: url)
        return url
    }

    /// Clavia `HandleMenuFileNewTo(slot)` → `CreateEmptyPerformancePatch(perf, slot)`:
    /// pusty patch ląduje w **wybranym** slocie, trzy pozostałe zostają nietknięte.
    func testNewToClearsTheChosenSlotAndFocusesIt() {
        let state = makeState()
        state.loadFromDevice(patches: (0 ..< 4).map { namedPatch("Nord \($0)") })
        state.slots[3].voiceModules = [makeModule(id: 1)]
        state.selectedSlot = 0

        state.newPatch(inSlot: 3)

        XCTAssertEqual(state.selectedSlot, 3)
        XCTAssertTrue(state.slots[3].voiceModules.isEmpty)
        XCTAssertEqual(state.slots.map(\.name), ["Nord 0", "Nord 1", "Nord 2", "No name"])
    }

    /// Open Patch: `.pch2` wchodzi do slotu z focusem i zostaje jego plikiem, pozostałe sloty
    /// grają dalej (życzenie użytkownika 2026-09-25 — cztery sloty zawsze, jak u Clavii).
    func testOpenPatchLoadsIntoFocusedSlotAndBecomesItsFile() {
        let state = makeState()
        let url = fixtureURL("simplesynth001-20240802.pch2")
        XCTAssertTrue(state.load(url: url))
        let modules = state.patch.voiceModules.count
        XCTAssertGreaterThan(modules, 0)
        XCTAssertEqual(state.fileName, "simplesynth001-20240802.pch2")

        state.selectedSlot = 1
        XCTAssertNil(state.fileURL, "slot B nie ma jeszcze pliku")
        let onlySlot = state.load(url: url)

        XCTAssertTrue(onlySlot)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.slots.count, 4)
        XCTAssertEqual(state.selectedSlot, 1)
        XCTAssertEqual(state.slots[0].voiceModules.count, modules)
        XCTAssertEqual(state.slots[1].voiceModules.count, modules)
        XCTAssertEqual(state.slotFileURLs, [url, url, nil, nil])
        XCTAssertEqual(state.fileURL, url)
        XCTAssertEqual(state.title, "simplesynth001-20240802.pch2")
        XCTAssertFalse(state.hasPerformanceSettings, "sloty z .pch2 to nie performance z pliku")
    }

    /// Błędny plik nie może ruszyć slotu ani jego pliku.
    func testOpenToWithBadFileLeavesTheSlotsAlone() throws {
        let state = makeState()
        state.load(url: fixtureURL("simplesynth001-20240802.pch2"))
        let broken = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("open-to-broken.pch2")
        try Data("not a patch".utf8).write(to: broken)
        defer { try? FileManager.default.removeItem(at: broken) }

        state.load(url: broken, intoSlot: 1)

        XCTAssertNotNil(state.errorMessage)
        XCTAssertTrue(state.slots[1].voiceModules.isEmpty)
        XCTAssertEqual(state.slotFileURLs[1], nil)
        XCTAssertEqual(state.fileURL, fixtureURL("simplesynth001-20240802.pch2"))
    }

    /// `CreatePerformancePatchFromFile(perf, slot, …)`: plik wchodzi do jednego slotu,
    /// performance zostaje. Nazwa slotu bierze się z nazwy pliku (sekcja 0x11,
    /// max 16 znaków) — `.pch2` nazwy patcha w sobie nie ma.
    func testOpenToLoadsPatchIntoChosenSlotAndKeepsThePerformance() {
        let state = makeState()
        state.newPerformance()

        state.load(url: fixtureURL("simplesynth001-20240802.pch2"), intoSlot: 2)

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.selectedSlot, 2)
        XCTAssertFalse(state.slots[2].voiceModules.isEmpty)
        XCTAssertEqual(state.slots[2].name, "simplesynth001-2")
        XCTAssertEqual(state.performance.slots[2].name, "simplesynth001-2")
        XCTAssertTrue(state.slots[1].voiceModules.isEmpty)
        XCTAssertEqual(state.fileName, "Empty perf")
        XCTAssertTrue(state.hasPerformanceSettings)
    }

    /// `.prf2` zastępuje wszystkie cztery sloty i zapomina ich pliki: Save Performance pisze
    /// do `.prf2`, a sloty nie mają własnych `.pch2`.
    func testOpeningPerformanceReplacesAllSlotsAndForgetsSlotFiles() throws {
        let state = makeState()
        state.load(url: fixtureURL("simplesynth001-20240802.pch2"))
        let url = try temporaryPerformanceFile(named: "Perf")
        defer { try? FileManager.default.removeItem(at: url) }

        let onlySlot = state.load(url: url)

        XCTAssertFalse(onlySlot)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.slotFileURLs, [nil, nil, nil, nil])
        XCTAssertTrue(state.slots.allSatisfy(\.voiceModules.isEmpty))
        XCTAssertEqual(state.performanceFileURL, url)
        XCTAssertEqual(state.fileURL, url)
        XCTAssertFalse(state.canSave)
        XCTAssertTrue(state.canSavePerformance)
        XCTAssertFalse(state.hasUnsavedChanges)
    }

    /// U Clavii `HandleMenuFileOpenTo` wpuszcza wyłącznie `GetFileType() == 1`, czyli patch.
    func testOpenToRefusesPerformanceFile() throws {
        let state = makeState()
        state.newPerformance()
        let disguised = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("open-to-test.prf2")
        try Data(contentsOf: fixtureURL("simplesynth001-20240802.pch2")).write(to: disguised)
        defer { try? FileManager.default.removeItem(at: disguised) }

        state.load(url: disguised, intoSlot: 1)

        XCTAssertNotNil(state.errorMessage)
        XCTAssertTrue(state.slots[1].voiceModules.isEmpty)
    }

    /// Save pisze patch slotu z focusem do JEGO pliku — jeden patch, nie cztery; sąsiedni
    /// slot i jego plik zostają nietknięte (`CPatch::SavePatch`).
    func testSaveWritesTheFocusedSlotIntoItsOwnFile() throws {
        let state = makeState()
        let first = try temporaryCopy(of: "simplesynth001-20240802.pch2")
        let second = try temporaryCopy(of: "test_3osc.pch2")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let secondBytes = try Data(contentsOf: second)
        state.load(url: first)
        state.load(url: second, intoSlot: 1)
        state.selectedSlot = 0
        let moduleID = try XCTUnwrap(state.slots[0].voiceModules.first?.id)

        performUndoStep(on: state) { state.deleteModule(moduleID: moduleID, area: .voice) }
        XCTAssertEqual(state.unsavedSlots(among: [0, 1, 2, 3]), [0])
        state.save()

        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.hasUnsavedChanges)
        let saved = try PatchParser.parse(data: Data(contentsOf: first))
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].voiceModules.count, state.slots[0].voiceModules.count)
        XCTAssertEqual(try Data(contentsOf: second), secondBytes, "plik slotu B nietknięty")
    }

    /// Zmiana z frontu Norda nie jest pracą użytkownika — czysty slot zostaje czysty.
    func testDeviceKnobDoesNotDirtyACleanSlot() throws {
        let state = makeState()
        state.load(url: fixtureURL("simplesynth001-20240802.pch2"))
        let module = try XCTUnwrap(state.patch.voiceModules.first { !$0.parameters.isEmpty })

        state.applyDeviceParameter(slot: 0, area: .voice, moduleID: module.id, paramIndex: 0,
                                   value: (module.parameters[0] + 1) % 128, variation: 0)

        XCTAssertFalse(state.hasUnsavedChanges)
    }

    /// Slot z otwartego `.prf2` nie ma własnego pliku — o jego zmiany pyta pytanie
    /// o performance, nie osobne okno zapisu `.pch2`.
    func testPerformanceSlotChangesCountAsPerformanceChanges() throws {
        let state = makeState()
        let url = try temporaryPerformanceFile(named: "Perf")
        defer { try? FileManager.default.removeItem(at: url) }
        state.load(url: url)
        state.selectedSlot = 1

        performUndoStep(on: state) { state.addModule(typeID: 4, area: .voice) }

        XCTAssertTrue(state.slotHasUnsavedChanges(1))
        XCTAssertEqual(state.unsavedSlots(among: [0, 1, 2, 3]), [])
        XCTAssertTrue(state.performanceHasUnsavedChanges)

        state.savePerformance()
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertEqual(try PatchParser.parse(data: Data(contentsOf: url))[1].voiceModules.count, 1)
    }

    // MARK: - Most do urządzenia

    /// Każda droga zmiany struktury ma zgłosić się do urządzenia — z cofnięciem włącznie.
    /// Do 2026-09-05 nie zgłaszała się żadna: skasowanie modułów zostawiało Norda grającego.
    func testEveryStructuralEditReportsTheWholeSlotToTheDevice() {
        var patch = G2Patch()
        patch.voiceModules = [makeModule(id: 1), makeModule(id: 2)]
        let state = makeState(patch: patch)

        var reported: [(slot: Int, moduleIDs: [Int])] = []
        state.onLiveStructureChange = { slot, patch in
            reported.append((slot, patch.voiceModules.map(\.id)))
        }

        performUndoStep(on: state) {
            state.deleteModules(moduleIDs: [1, 2], area: .voice)
        }
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.last?.slot, 0)
        XCTAssertEqual(reported.last?.moduleIDs, [])

        state.undoManager.undo()
        XCTAssertEqual(reported.count, 2)
        XCTAssertEqual(reported.last?.moduleIDs, [1, 2])

        performUndoStep(on: state) {
            state.addCable(G2Cable(fromModule: 1, fromConnector: 0, toModule: 2, toConnector: 0,
                                   color: .red, area: .voice))
        }
        XCTAssertEqual(reported.count, 3)

        performUndoStep(on: state) {
            state.addModule(typeID: 1, area: .voice)
        }
        XCTAssertEqual(reported.count, 4)
        XCTAssertEqual(reported.last?.moduleIDs, [1, 2, 3])
    }

    /// Zmiana wartości parametru nie jest zmianą struktury — idzie osobną, dużo szybszą
    /// drogą (`SET_PARAM`), więc nie ma jej po co liczyć jeszcze raz jako różnicy patcha.
    func testParameterChangeIsNotReportedAsStructuralEdit() {
        var patch = G2Patch()
        patch.voiceModules = [makeModule(id: 1)]
        let state = makeState(patch: patch)

        var reports = 0
        state.onLiveStructureChange = { _, _ in reports += 1 }
        performUndoStep(on: state) {
            state.setParameter(moduleID: 1, paramIndex: 0, value: 42, area: .voice)
        }

        XCTAssertEqual(reports, 0)
    }
}
