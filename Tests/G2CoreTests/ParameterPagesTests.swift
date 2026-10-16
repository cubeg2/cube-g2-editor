// ParameterPagesTests.swift
// Strony parametrów: sekcja 0x62, model 120 gałek i komendy 0x25/0x26.
// Reguły i pomiary → [[Docs/ui/parameter-pages]].

import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class ParameterPagesTests: XCTestCase {
    private func fixtureData(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .standardized
        return try Data(contentsOf: url)
    }

    private func makeState(_ patch: G2Patch = G2Patch()) -> PatchState {
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

    // MARK: - Strony

    /// Pięć grup po trzy strony, etykiety jak w oknie przeglądu oryginału.
    func testPageLabelsFollowTheOriginalGrid() {
        XCTAssertEqual(G2KnobPages.pageCount, 15)
        XCTAssertEqual(G2KnobPages.knobCount, 120)
        XCTAssertEqual(G2KnobPages.pageLabel(0), "A1")
        XCTAssertEqual(G2KnobPages.pageLabel(2), "A3")
        XCTAssertEqual(G2KnobPages.pageLabel(3), "B1")
        XCTAssertEqual(G2KnobPages.pageLabel(14), "E3")
        XCTAssertEqual(G2KnobPages.groupName(ofPage: 0), "Osc")
        XCTAssertEqual(G2KnobPages.groupName(ofPage: 14), "Effect")
        XCTAssertEqual(G2KnobPages.knobIndex(page: 2, slot: 3), 19)
    }

    /// `ButtonParam` z ModuleDef.xml: gałka FM Amount OscA pokazuje pod sobą
    /// przełącznik FM Lin/FM Trk, a Fine — przełącznik KBT.
    func testClaviaKnobToButtonLinksAreAvailableToThePanel() {
        XCTAssertEqual(ModuleParameterLinks.buttonParameter(moduleTypeID: 7, knobParameter: 5), 10)
        XCTAssertEqual(ModuleParameterLinks.buttonParameter(moduleTypeID: 7, knobParameter: 1), 2)
        XCTAssertNil(ModuleParameterLinks.buttonParameter(moduleTypeID: 7, knobParameter: 3))
    }

    /// „Assign ▸ Page B ▸ Column 1" z menu gałki morfu: cel siedzi w obszarze USTAWIEŃ
    /// patcha (2), moduł 1, parametr = numer morfu — i ma wylądować na pierwszej wolnej
    /// gałce wskazanego wiersza, nie tej z focusem.
    func testMorphCanBeAssignedToAChosenPage() {
        let state = makeState()
        state.focusedParameterPage = 0
        undoStep(on: state) { state.assignKnob(toPage: 3, location: 2, moduleID: 1, paramIndex: 0) }

        let assignment = state.patch.knobAssignment(page: 3, slot: 0)
        XCTAssertEqual(assignment?.location, 2)
        XCTAssertEqual(assignment?.moduleID, 1)
        XCTAssertEqual(assignment?.paramIndex, 0)
        XCTAssertNil(state.patch.knobAssignment(page: 0, slot: 0), "strona z focusem nietknięta")

        // Drugie wywołanie na tej samej stronie nie zajmuje kolejnej gałki.
        undoStep(on: state) { state.assignKnob(toPage: 3, location: 2, moduleID: 1, paramIndex: 0) }
        XCTAssertNil(state.patch.knobAssignment(page: 3, slot: 1))
    }

    // MARK: - Plik

    /// Fixture ma jedno przypisanie: gałka 0 (strona A1), obszar Voice, moduł 1,
    /// parametr 0 — odczytane niezależnym skryptem wg układu z g2ools.
    func testKnobAssignmentIsReadFromFile() throws {
        let patch = try XCTUnwrap(PatchParser.parse(data: fixtureData("simplesynth001-20240802.pch2")).first)
        XCTAssertEqual(patch.knobAssignments.count, 120)
        let knob = try XCTUnwrap(patch.knobAssignment(at: 0))
        XCTAssertEqual(knob.location, 1)
        XCTAssertEqual(knob.moduleID, 1)
        XCTAssertEqual(knob.paramIndex, 0)
        XCTAssertEqual(knob.isLed, 0)
        XCTAssertNil(patch.knobAssignment(at: 1))
        XCTAssertEqual(patch.knobIndex(location: 1, moduleID: 1, paramIndex: 0), 0)
    }

    func testLoadingPatchFocusesTheFirstPageThatContainsAssignments() throws {
        let original = try fixtureData("simplesynth001-20240802.pch2")
        var patches = try PatchParser.parse(data: original)
        let assignment = try XCTUnwrap(patches[0].clearKnob(index: 0))
        patches[0].assignKnob(index: G2KnobPages.knobIndex(page: 4, slot: 3),
                              location: assignment.location,
                              moduleID: assignment.moduleID,
                              paramIndex: assignment.paramIndex,
                              isLed: assignment.isLed)
        let moved = try PatchParser.saveAll(originalData: original, patches: patches)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parameter-page-focus-\(UUID().uuidString).pch2")
        try moved.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let state = makeState()
        state.load(url: url)

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.focusedParameterPage, 4)
    }

    func testEditedKnobAssignmentsSurviveSave() throws {
        let data = try fixtureData("simplesynth001-20240802.pch2")
        var patches = try PatchParser.parse(data: data)

        patches[0].assignKnob(index: G2KnobPages.knobIndex(page: 4, slot: 2),
                              location: 0, moduleID: 7, paramIndex: 5)
        patches[0].clearKnob(index: 0)

        let saved = try PatchParser.saveAll(originalData: data, patches: patches)
        let reloaded = try XCTUnwrap(PatchParser.parse(data: saved).first)

        let knob = try XCTUnwrap(reloaded.knobAssignment(page: 4, slot: 2))
        XCTAssertEqual(knob.location, 0)
        XCTAssertEqual(knob.moduleID, 7)
        XCTAssertEqual(knob.paramIndex, 5)
        XCTAssertNil(reloaded.knobAssignment(at: 0), "zwolniona gałka zostaje zwolniona")
    }

    func testEditedMidiControllerAssignmentsSurviveSave() throws {
        let data = try fixtureData("simplesynth001-20240802.pch2")
        var patches = try PatchParser.parse(data: data)
        patches[0].assignMidiController(cc: 74, location: 1, moduleID: 1, paramIndex: 0)

        let saved = try PatchParser.saveAll(originalData: data, patches: patches)
        let reloaded = try XCTUnwrap(PatchParser.parse(data: saved).first)

        XCTAssertEqual(reloaded.midiControllerAssignments[74]?.location, 1)
        XCTAssertEqual(reloaded.midiControllerAssignments[74]?.moduleID, 1)
        XCTAssertEqual(reloaded.midiControllerAssignments[74]?.paramIndex, 0)
    }

    // MARK: - Model

    /// Jeden parametr wisi tylko na jednej gałce — przypisanie go gdzie indziej
    /// zwalnia poprzednią. Tak samo pilnuje tego oryginał.
    func testAssigningTheSameParameterTwiceMovesIt() {
        var patch = G2Patch()
        patch.assignKnob(index: 3, location: 1, moduleID: 2, paramIndex: 1)
        let freed = patch.assignKnob(index: 40, location: 1, moduleID: 2, paramIndex: 1)

        XCTAssertEqual(freed, [3])
        XCTAssertNil(patch.knobAssignment(at: 3))
        XCTAssertEqual(patch.knobAssignment(at: 40)?.moduleID, 2)
    }

    func testFirstFreeKnobSkipsTakenSlots() {
        var patch = G2Patch()
        patch.assignKnob(index: G2KnobPages.knobIndex(page: 1, slot: 0),
                         location: 1, moduleID: 1, paramIndex: 0)
        patch.assignKnob(index: G2KnobPages.knobIndex(page: 1, slot: 1),
                         location: 1, moduleID: 1, paramIndex: 1)
        XCTAssertEqual(patch.firstFreeKnob(onPage: 1), G2KnobPages.knobIndex(page: 1, slot: 2))
        XCTAssertEqual(patch.firstFreeKnob(onPage: 0), 0)
    }

    func testFullPageTakesNothingMore() {
        var patch = G2Patch()
        for slot in 0 ..< G2KnobPages.knobsPerPage {
            patch.assignKnob(index: G2KnobPages.knobIndex(page: 0, slot: slot),
                             location: 1, moduleID: slot, paramIndex: 0)
        }
        XCTAssertNil(patch.firstFreeKnob(onPage: 0))
    }

    // MARK: - Stan edytora

    func testCommandClickFillsTheFocusedPageAndTellsTheDevice() {
        let state = makeState()
        var reported: [(knob: Int, assigned: Bool)] = []
        state.onKnobAssignmentChange = { _, knob, assignment in
            reported.append((knob, assignment != nil))
        }
        state.focusedParameterPage = 2

        undoStep(on: state) {
            state.assignKnobToFocusedPage(location: 1, moduleID: 5, paramIndex: 3)
        }

        let index = G2KnobPages.knobIndex(page: 2, slot: 0)
        XCTAssertEqual(state.patch.knobAssignment(at: index)?.moduleID, 5)
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.knob, index)

        state.undoManager.undo()
        XCTAssertNil(state.patch.knobAssignment(at: index))
        XCTAssertEqual(reported.last?.assigned, false, "urządzenie dostaje zwolnienie gałki")
    }

    /// Drugi ⌘-klik w ten sam parametr nie ma zajmować kolejnej gałki tej strony.
    func testSecondClickOnTheSameParameterChangesNothing() {
        let state = makeState()
        undoStep(on: state) {
            state.assignKnobToFocusedPage(location: 1, moduleID: 5, paramIndex: 3)
            state.assignKnobToFocusedPage(location: 1, moduleID: 5, paramIndex: 3)
        }
        XCTAssertEqual(state.patch.knobAssignments.compactMap(\.self).count, 1)
    }

    func testClearingAKnobIsUndoable() {
        var patch = G2Patch()
        patch.assignKnob(index: 6, location: 1, moduleID: 9, paramIndex: 2)
        let state = makeState(patch)

        undoStep(on: state) { state.clearKnob(index: 6) }
        XCTAssertNil(state.patch.knobAssignment(at: 6))

        state.undoManager.undo()
        XCTAssertEqual(state.patch.knobAssignment(at: 6)?.moduleID, 9)
    }

    func testDraggingAnOverviewAssignmentMovesItToAnotherDisplay() {
        var patch = G2Patch()
        patch.assignKnob(index: 3, location: 1, moduleID: 9, paramIndex: 2)
        let state = makeState(patch)

        undoStep(on: state) { state.moveParameterPageKnob(from: 3, to: 40) }

        XCTAssertNil(state.patch.knobAssignment(at: 3))
        XCTAssertEqual(state.patch.knobAssignment(at: 40)?.moduleID, 9)
        state.undoManager.undo()
        XCTAssertEqual(state.patch.knobAssignment(at: 3)?.moduleID, 9)
        XCTAssertNil(state.patch.knobAssignment(at: 40))
    }

    func testGlobalOverviewDropStoresTheSourceSlot() {
        var patch = G2Patch()
        var module = G2Module(id: 4, typeID: 7, area: .voice)
        module.parameters = Array(repeating: 0, count: 12)
        patch.voiceModules = [module]
        let state = makeState(patch)
        state.showsGlobalParameterPages = true

        undoStep(on: state) {
            state.assignParameterPageKnob(index: 5, location: 1, moduleID: 4, paramIndex: 3)
        }

        let assignment = state.performance.globalKnobAssignments[5]
        XCTAssertEqual(assignment?.slot, 0)
        XCTAssertEqual(assignment?.moduleID, 4)
        state.undoManager.undo()
        XCTAssertNil(state.performance.globalKnobAssignments[5])
    }

    // MARK: - MIDI controller map

    func testAutoAssignMidiUsesClaviaAvailabilityRulesAndIncludesLinkedButtons() {
        var patch = G2Patch()
        var module = G2Module(id: 4, typeID: 7, area: .voice)
        module.parameters = Array(repeating: 0, count: 12)
        patch.voiceModules = [module]
        patch.assignKnob(index: 0, location: 1, moduleID: 4, paramIndex: 5)
        patch.assignMidiController(cc: 42, location: 1, moduleID: 4, paramIndex: 5)
        let state = makeState(patch)

        undoStep(on: state) { state.autoAssignMidiControllersFromParameterPages() }

        XCTAssertEqual(state.patch.midiController(for: 1, moduleID: 4, paramIndex: 5), 42)
        XCTAssertEqual(state.patch.midiController(for: 1, moduleID: 4, paramIndex: 10), 2,
                       "the linked button receives the next free controller")
        XCTAssertFalse(G2MidiControllers.isAutoAssignable(0))
        XCTAssertFalse(G2MidiControllers.isAutoAssignable(1))
        XCTAssertFalse(G2MidiControllers.isAutoAssignable(7))
        XCTAssertTrue(G2MidiControllers.isAutoAssignable(2))
    }

    func testClearMidiRemovesMappedControllersButKeepsPreassignedOnes() {
        var patch = G2Patch()
        var module = G2Module(id: 4, typeID: 7, area: .voice)
        module.parameters = Array(repeating: 0, count: 12)
        patch.voiceModules = [module]
        patch.assignKnob(index: 0, location: 1, moduleID: 4, paramIndex: 5)
        patch.assignMidiController(cc: 42, location: 1, moduleID: 4, paramIndex: 5)
        patch.assignMidiController(cc: 7, location: 1, moduleID: 4, paramIndex: 10)
        let state = makeState(patch)

        undoStep(on: state) { state.clearMidiControllersFromParameterPages() }

        XCTAssertNil(state.patch.midiControllerAssignments[42])
        XCTAssertNotNil(state.patch.midiControllerAssignments[7])
        state.undoManager.undo()
        XCTAssertNotNil(state.patch.midiControllerAssignments[42])
    }

    // MARK: - Bajty komend

    func testKnobPayloadsMatchTheOriginal() {
        // `[0x01][REQ|SLOT|slot][wersja][0x25][moduł][parametr]
        //  [obszar<<6 | isLed<<4][gałka:16]`
        XCTAssertEqual(
            G2UsbProtocol.assignKnobPayload(slot: 0, version: 0x0A, location: 1,
                                            moduleID: 9, paramIndex: 3, knob: 17),
            [0x01, 0x28, 0x0A, 0x25, 0x09, 0x03, 0x40, 0x00, 0x11]
        )
        // Obszar 2 i `isLed` = 1 → bajt 0b10_01_0000.
        XCTAssertEqual(
            G2UsbProtocol.assignKnobPayload(slot: 3, version: 0x02, location: 2,
                                            moduleID: 1, paramIndex: 0, knob: 119, isLed: 1),
            [0x01, 0x2B, 0x02, 0x25, 0x01, 0x00, 0x90, 0x00, 0x77]
        )
        // Zwolnienie: sam numer gałki jako słowo.
        XCTAssertEqual(
            G2UsbProtocol.deassignKnobPayload(slot: 1, version: 0x05, knob: 8),
            [0x01, 0x29, 0x05, 0x26, 0x00, 0x08]
        )

        XCTAssertEqual(
            G2UsbProtocol.assignMidiControllerPayload(
                slot: 2, version: 0x03, cc: 74,
                location: 1, moduleID: 9, paramIndex: 3
            ),
            [0x01, 0x2A, 0x03, 0x22, 0x01, 0x09, 0x03, 0x4A]
        )
        XCTAssertEqual(
            G2UsbProtocol.deassignMidiControllerPayload(slot: 2, version: 0x03, cc: 74),
            [0x01, 0x2A, 0x03, 0x23, 0x4A]
        )
    }

    // MARK: - Wybór strony w obie strony (0x2D / 0x1E)

    /// Kliknięcie A…E albo 1…3 w oknie ma przestawić panel Norda — tak samo jak
    /// oryginał, który przy każdym kliknięciu wysyła Parameter Page Focus.
    func testChoosingAPageTellsTheDevice() {
        let state = makeState()
        var sent: [(slot: Int, page: Int, global: Bool)] = []
        state.onParameterPageChange = { sent.append(($0, $1, $2)) }

        state.focusedParameterPage = 7
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.page, 7)
        XCTAssertEqual(sent.first?.slot, 0)
        XCTAssertEqual(sent.first?.global, false)

        // Ta sama strona po raz drugi to nie jest zmiana — urządzenie ma o niej wiedzieć raz.
        state.focusedParameterPage = 7
        XCTAssertEqual(sent.count, 1)
    }

    /// W trybie Global Pages ta sama zmiana idzie molekułą performance'u (`0x1E`),
    /// a sam przełącznik — polem 2 nagłówka performance'u.
    func testGlobalPagesSwitchAndPageBothReachTheDevice() {
        let state = makeState()
        var pages: [(page: Int, global: Bool)] = []
        var toggles: [Bool] = []
        state.onParameterPageChange = { pages.append(($1, $2)) }
        state.onGlobalParameterPagesChange = { toggles.append($0) }

        state.showsGlobalParameterPages = true
        state.focusedParameterPage = 4

        XCTAssertEqual(toggles, [true])
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.global, true)
        XCTAssertEqual(pages.first?.page, 4)
    }

    /// Przycisk naciśnięty NA FRONCIE Norda przestawia okno — i nie wraca do urządzenia,
    /// bo to ono jest źródłem tej zmiany.
    func testPageChosenOnTheDeviceMovesTheWindowWithoutEchoingBack() {
        let state = makeState()
        var sent = 0
        state.onParameterPageChange = { _, _, _ in sent += 1 }

        state.applyDeviceParameterPage(11, slot: 0, global: false)
        XCTAssertEqual(state.focusedParameterPage, 11)
        XCTAssertEqual(sent, 0)

        state.applyDeviceGlobalParameterPages(true)
        XCTAssertTrue(state.showsGlobalParameterPages)
    }

    /// Strona globalna i strona slotu to dwie osobne rzeczy — okno pokazuje jedną,
    /// ale odczyt tej drugiej nie ma prawa nią ruszyć. Strona innego slotu i numer spoza
    /// zakresu nie znaczą tu nic.
    func testDeviceReportsForAnotherModeOrSlotDoNotMoveTheVisiblePage() {
        let state = makeState()
        state.slots = [G2Patch(), G2Patch()]
        state.focusedParameterPage = 3

        state.applyDeviceParameterPage(9, slot: nil, global: true)
        XCTAssertEqual(state.focusedParameterPage, 3, "strona globalna przy wyłączonym Global Pages")

        state.applyDeviceParameterPage(9, slot: 1, global: false)
        XCTAssertEqual(state.focusedParameterPage, 3, "strona innego slotu niż oglądany")

        state.applyDeviceParameterPage(20, slot: 0, global: false)
        XCTAssertEqual(state.focusedParameterPage, 3, "numer strony poza 0…14")

        // …a globalna czekała odłożona i pokazuje się dopiero po wciśnięciu Global Pages.
        state.applyDeviceGlobalParameterPages(true)
        XCTAssertEqual(state.focusedParameterPage, 9)
    }

    /// Oryginał trzyma stronę osobno dla patcha (`CPatch`) i osobno dla performance'u
    /// (`CPerformance`), więc przełącznik Global Pages przerzuca widok między dwiema
    /// zapamiętanymi stronami, a nie przenosi jednej z trybu do trybu.
    func testEachModeKeepsItsOwnPage() {
        let state = makeState()
        var sent: [(page: Int, global: Bool)] = []
        state.onParameterPageChange = { _, page, global in sent.append((page, global)) }

        state.focusedParameterPage = 4
        state.showsGlobalParameterPages = true
        XCTAssertEqual(state.focusedParameterPage, 0, "strona globalna jeszcze nietknięta")

        state.focusedParameterPage = 11
        state.showsGlobalParameterPages = false
        XCTAssertEqual(state.focusedParameterPage, 4, "strona patcha wróciła nienaruszona")

        state.showsGlobalParameterPages = true
        XCTAssertEqual(state.focusedParameterPage, 11)
        XCTAssertEqual(sent.map(\.page), [4, 11])
        XCTAssertEqual(sent.map(\.global), [false, true])
    }

    /// Wciśnięty `Global Pages` należy do performance'u, nie do patcha — wczytanie
    /// zawartości nie ma prawa go zgasić, tak jak `CPatch::LoadFromFile` nie dotyka
    /// `CPerformance`. To była usterka zgłoszona po teście na sprzęcie.
    func testGlobalPagesSurvivesNewContent() {
        let state = makeState()
        state.showsGlobalParameterPages = true
        state.focusedParameterPage = 7

        var patch = G2Patch()
        patch.knobAssignments[24] = G2KnobAssignment(location: 1, moduleID: 4, paramIndex: 0)
        state.loadFromDevice(patches: [patch])

        XCTAssertTrue(state.showsGlobalParameterPages, "przycisk Global Pages")
        XCTAssertEqual(state.focusedParameterPage, 7, "strona globalna")
        state.showsGlobalParameterPages = false
        XCTAssertEqual(state.focusedParameterPage, 3, "strona patcha — pierwsza z przypisaniem")
    }

    /// Zawartość przepisana z Norda ustawia stronę na pierwszą z przypisaniem — i też
    /// nie ma z czym wracać do urządzenia, bo cała ta zmiana pochodzi od niego.
    func testContentTakenFromTheDeviceDoesNotEchoThePage() {
        let state = makeState()
        state.markSentToDevice()
        var sent = 0
        state.onParameterPageChange = { _, _, _ in sent += 1 }
        state.onGlobalParameterPagesChange = { _ in sent += 1 }

        var patch = G2Patch()
        patch.knobAssignments[24] = G2KnobAssignment(location: 1, moduleID: 4, paramIndex: 0)
        state.replaceSlotsFromDevice(patches: [patch])

        XCTAssertEqual(state.focusedParameterPage, 3)
        XCTAssertEqual(sent, 0)
    }
}
