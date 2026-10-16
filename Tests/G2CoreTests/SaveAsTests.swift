// SaveAsTests.swift
// „Save As", „Save From ▸ Slot X" i szkielety pustych plików — polecenia menu File
// z instrukcji Clavii (str. 116). Do 2026-09-10 patcha bez pliku źródłowego (nowego
// albo odczytanego z Norda) nie dało się zapisać wcale.

import G2Core
@testable import G2EditorCore
import XCTest

final class EmptyFileSkeletonTests: XCTestCase {
    func testEmptyPatchSkeletonParses() throws {
        let patches = try PatchParser.parse(data: PatchParser.emptyPatchFile)
        XCTAssertEqual(patches.count, 1)
        XCTAssertTrue(patches[0].voiceModules.isEmpty)
        XCTAssertTrue(patches[0].fxModules.isEmpty)
    }

    /// Szkielet `.prf2` powstaje z tego samego bloku co pusty patch, powtórzonego
    /// cztery razy — musi się czytać jak każdy inny performance.
    func testEmptyPerformanceSkeletonParsesAsFourSlots() throws {
        let parsed = try PatchParser.parseFile(data: PatchParser.emptyPerformanceFile)
        XCTAssertEqual(parsed.patches.count, 4)
        XCTAssertNotNil(parsed.performance, "sekcja 0x11 musi być w szkielecie")
        XCTAssertEqual(parsed.performance?.slots.count, 4)
    }

    /// Zapis czterech patchy do szkieletu ma je odtworzyć slot po slocie.
    func testWritingFourSlotsIntoTheSkeletonRoundTrips() throws {
        var patches: [G2Patch] = []
        for slot in 0 ..< 4 {
            var patch = G2Patch()
            var module = G2Module(id: slot + 1, typeID: 4, area: .voice)
            module.parameters = ModuleDefaultsDatabase.defaults(forTypeID: 4)
            module.parameterVariations = Array(repeating: module.parameters,
                                               count: G2Patch.runtimeVariationCount)
            module.hasParameterEntry = true
            patch.voiceModules = [module]
            patches.append(patch)
        }

        let data = try PatchParser.saveAll(originalData: PatchParser.emptyPerformanceFile,
                                           patches: patches,
                                           performance: G2PerformanceSettings())
        let reloaded = try PatchParser.parse(data: data)

        XCTAssertEqual(reloaded.count, 4)
        XCTAssertEqual(reloaded.map { $0.voiceModules.map(\.id) }, [[1], [2], [3], [4]])
    }

    /// Każdy `.prf2` Clavii kończy sekcja `0x5F` (gałki globalne), a `0x1A` niesie ją
    /// na końcu zrzutu. Bez niej w szkielecie Nord nie potwierdzał przywrócenia
    /// performance'u po Download Banks (2026-10-14), a zapisany plik był niepełny.
    func testEmptyPerformanceSkeletonHasGlobalKnobSection() throws {
        let data = try PatchParser.saveAll(originalData: PatchParser.emptyPerformanceFile,
                                           patches: Array(repeating: G2Patch(), count: 4),
                                           performance: G2PerformanceSettings())
        let section = try PatchParser.performanceKnobMapStream(fileData: data)

        XCTAssertEqual(section.first, 0x5F)
        // 16 bitów liczby gałek + 120 pustych bitów = 17 bajtów.
        XCTAssertEqual(section.count, 3 + 17)
    }
}

@MainActor
final class SaveAsStateTests: XCTestCase {
    private func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("g2-save-as-\(UUID().uuidString).\(ext)")
    }

    private func makePatchState() -> PatchState {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        state.newPatch()
        return state
    }

    /// „Zapisać zmiany?" ma sens tylko, gdy edytor wie, że coś się zmieniło: edycja brudzi,
    /// undo czyści, redo brudzi z powrotem, zapis czyści — i wczytanie nowej zawartości też.
    func testUnsavedChangesFollowEditsUndoRedoAndSave() {
        let state = makePatchState()
        XCTAssertFalse(state.hasUnsavedChanges)

        state.undoManager.beginUndoGrouping()
        state.setPatchName("Dirty")
        state.undoManager.endUndoGrouping()
        XCTAssertTrue(state.hasUnsavedChanges)

        state.undoManager.undo()
        XCTAssertFalse(state.hasUnsavedChanges, "cofnięcie jedynej zmiany = stan z dysku")
        state.undoManager.redo()
        XCTAssertTrue(state.hasUnsavedChanges)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g2-dirty-\(UUID().uuidString).pch2")
        defer { try? FileManager.default.removeItem(at: url) }
        state.save(as: url)
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.hasUnsavedChanges)

        state.undoManager.undo()
        XCTAssertTrue(state.hasUnsavedChanges, "cofnięcie za punkt zapisu = znów inne niż plik")

        state.newPatch()
        XCTAssertFalse(state.hasUnsavedChanges)
    }

    /// Nowy patch nie ma pliku źródłowego — „Save As" musi mimo to zapisać go
    /// na dysk, korzystając ze szkieletu.
    func testSaveAsWritesANewPatchThatHasNoSourceFile() throws {
        let state = makePatchState()
        state.undoManager.beginUndoGrouping()
        state.addModule(typeID: 4, area: .voice)
        state.undoManager.endUndoGrouping()

        let url = temporaryURL("pch2")
        defer { try? FileManager.default.removeItem(at: url) }
        state.save(as: url)

        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let reloaded = try PatchParser.parse(data: Data(contentsOf: url))
        XCTAssertEqual(reloaded.first?.voiceModules.count, 1)
    }

    /// Po „Save As" slot należy do nowego pliku — kolejne ⌘S ma pisać właśnie tam.
    func testSaveAsAdoptsTheNewFile() {
        let state = makePatchState()
        let url = temporaryURL("pch2")
        defer { try? FileManager.default.removeItem(at: url) }
        state.save(as: url)

        XCTAssertEqual(state.fileURL, url)
        XCTAssertEqual(state.slotFileURLs[state.selectedSlot], url)
        XCTAssertTrue(state.canSave)
        XCTAssertEqual(state.title, url.lastPathComponent)
    }

    /// Performance odczytany z Norda nie ma pliku — Save Performance musi go mimo to zapisać,
    /// a `.prf2` staje się plikiem performance'u i daje mu nazwę.
    func testSavePerformanceAsWritesAPerformanceReadFromTheDevice() throws {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        state.loadFromDevice(patches: Array(repeating: G2Patch(), count: 4),
                             performanceName: "From G2")

        let url = temporaryURL("prf2")
        defer { try? FileManager.default.removeItem(at: url) }
        state.savePerformance(as: url)

        XCTAssertNil(state.errorMessage)
        let parsed = try PatchParser.parseFile(data: Data(contentsOf: url))
        XCTAssertEqual(parsed.patches.count, 4)
        XCTAssertEqual(state.performanceFileURL, url)
        XCTAssertTrue(state.canSavePerformance)
        XCTAssertEqual(state.performanceName, String(url.deletingPathExtension().lastPathComponent.prefix(16)))
    }

    /// Ustawienia performance'u z Norda (nagłówek + gałki globalne) trafiają do zapisu,
    /// a nie wartości domyślne — dawniej Save Performance gubił m.in. gałki globalne.
    func testSavePerformanceKeepsTheDevicePerformanceSettings() throws {
        var device = G2PerformanceSettings()
        device.globalKnobAssignments[5] = G2GlobalKnobAssignment(slot: 1, location: 1, moduleID: 3, paramIndex: 2)
        device.slots[2].enabled = true
        let state = PatchState()
        state.loadFromDevice(patches: Array(repeating: G2Patch(), count: 4),
                             performanceName: "From G2", performance: device)

        let url = temporaryURL("prf2")
        defer { try? FileManager.default.removeItem(at: url) }
        state.savePerformance(as: url)

        let parsed = try XCTUnwrap(PatchParser.parseFile(data: Data(contentsOf: url)).performance)
        XCTAssertEqual(parsed.globalKnobAssignments, device.globalKnobAssignments)
        XCTAssertTrue(parsed.slots[2].enabled)
    }

    /// „Save From ▸ Slot X" wyjmuje jeden slot jako osobny `.pch2` i **nie rusza**
    /// pliku dokumentu — instrukcja: „leaving any original Patch intact on the disk".
    func testSaveFromSlotWritesOneSlotAndLeavesTheDocumentAlone() throws {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        state.newPerformance()
        state.selectedSlot = 2
        state.undoManager.beginUndoGrouping()
        state.addModule(typeID: 4, area: .voice)
        state.undoManager.endUndoGrouping()

        let url = temporaryURL("pch2")
        defer { try? FileManager.default.removeItem(at: url) }
        state.saveSlot(2, to: url)

        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.fileURL, "dokument zostaje bez pliku — zapisaliśmy tylko slot")
        let reloaded = try PatchParser.parse(data: Data(contentsOf: url))
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.voiceModules.count, 1)
    }

    func testSuggestedFileNameUsesThePatchName() {
        let state = makePatchState()
        state.undoManager.beginUndoGrouping()
        state.setPatchName("Fat Bass")
        state.undoManager.endUndoGrouping()
        XCTAssertEqual(state.suggestedFileName, "Fat Bass")
    }
}

final class RecentFilesTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RecentFiles.clear()
    }

    override func tearDown() {
        RecentFiles.clear()
        super.tearDown()
    }

    /// Lista pomija pliki, których nie ma na dysku — menu nie pokazuje martwych pozycji.
    func testMissingFilesDropOutOfTheList() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g2-recent-\(UUID().uuidString).pch2")
        try Data([0]).write(to: url)
        RecentFiles.remember(url)
        XCTAssertEqual(RecentFiles.urls, [url])

        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(RecentFiles.urls.isEmpty)
    }

    func testTheSameFileMovesToTheTopInsteadOfRepeating() throws {
        let directory = FileManager.default.temporaryDirectory
        var urls: [URL] = []
        for index in 0 ..< 3 {
            let url = directory.appendingPathComponent("g2-recent-\(UUID().uuidString)-\(index).pch2")
            try Data([0]).write(to: url)
            urls.append(url)
            RecentFiles.remember(url)
        }
        defer { for url in urls {
            try? FileManager.default.removeItem(at: url)
        } }

        RecentFiles.remember(urls[0])
        XCTAssertEqual(RecentFiles.urls.first, urls[0])
        XCTAssertEqual(RecentFiles.urls.count, 3)
    }
}
