// DiskBankLibraryTests.swift
// Chodzenie po folderach w przeglądarce patchy z dysku. Drzewa nie trzymamy osobno —
// odtwarzamy je z `relativeFolder` każdego pliku, więc warto pilnować, że wychodzi
// dokładnie to, co na dysku → [[Docs/ui/side-panels]].

import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class DiskBankLibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g2-disk-\(UUID().uuidString)", isDirectory: true)
        for path in ["Bass/Acid", "Bass/Sub", "Leads", "Empty"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(path), withIntermediateDirectories: true
            )
        }
        try write("root.pch2")
        try write("Bass/warm.pch2")
        try write("Bass/Acid/303.pch2")
        try write("Bass/Acid/303b.pch2")
        try write("Bass/Sub/deep.prf2")
        try write("Leads/saw.pch2")
        // „Empty" nie dostaje pliku — folder bez patchy nie ma się po co pokazywać.
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// Folder patchy i folder Building Blocks pamiętają się osobno — wskazanie jednego
    /// nie może przestawić drugiego → Docs/Plan projektu/08-building-blocks.md
    func testKeyPrefixKeepsLibrariesApart() throws {
        let suite = "g2-disk-prefix-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let patches = DiskBankLibrary(defaults: defaults)
        let blocks = DiskBankLibrary(defaults: defaults, keyPrefix: "g2_blocks")

        blocks.setFolder(root.appendingPathComponent("Bass"))
        blocks.currentPath = "Acid"
        patches.setFolder(root)

        XCTAssertEqual(DiskBankLibrary(defaults: defaults).folder?.lastPathComponent, root.lastPathComponent)
        let reopened = DiskBankLibrary(defaults: defaults, keyPrefix: "g2_blocks")
        XCTAssertEqual(reopened.folder?.lastPathComponent, "Bass")
        XCTAssertEqual(reopened.currentPath, "Acid")
        XCTAssertEqual(DiskBankLibrary.savedFolderPath(defaults: defaults), root.path,
                       "the DAW plug-in browser keeps reading the patch folder")
    }

    private func write(_ relative: String, bytes: Int = 1) throws {
        try Data(repeating: 0, count: bytes).write(to: root.appendingPathComponent(relative))
    }

    /// Nadaje plikowi tagi dokładnie tak, jak robi to Finder: lista `Nazwa\nKolor`
    /// w atrybucie rozszerzonym, plist binarny.
    private func tag(_ relative: String, _ tags: [String]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
        let path = root.appendingPathComponent(relative).path
        let result = data.withUnsafeBytes {
            setxattr(path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, data.count, 0, 0)
        }
        XCTAssertEqual(result, 0, "setxattr failed for \(relative)")
    }

    private func library() async -> DiskBankLibrary {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let library = DiskBankLibrary(defaults: defaults)
        library.setFolder(root)
        await library.scan()
        return library
    }

    /// Katalog główny pokazuje swoje podfoldery i swoje pliki — i nic z głębszych pięter.
    func testRootListsItsOwnFoldersAndFiles() async {
        let library = await library()
        XCTAssertEqual(library.subfolders(of: ""), ["Bass", "Leads"])
        XCTAssertEqual(library.files(in: "").map(\.name), ["root"])
    }

    /// Folder bez ani jednego patcha (na żadnym piętrze) w ogóle się nie pokazuje —
    /// nie ma po co do niego wchodzić.
    func testFolderWithoutPatchesIsNotListed() async {
        let library = await library()
        XCTAssertFalse(library.subfolders(of: "").contains("Empty"))
    }

    /// Wejście piętro niżej: własne podfoldery, własne pliki.
    func testSubfolderListsItsOwnContent() async {
        let library = await library()
        XCTAssertEqual(library.subfolders(of: "Bass"), ["Acid", "Sub"])
        XCTAssertEqual(library.files(in: "Bass").map(\.name), ["warm"])
        XCTAssertEqual(library.files(in: "Bass/Acid").map(\.name), ["303", "303b"])
    }

    /// Liczba przy nazwie folderu obejmuje wszystko pod nim — po to, żeby było widać,
    /// czy warto tam wchodzić.
    func testFileCountCountsTheWholeSubtree() async {
        let library = await library()
        XCTAssertEqual(library.fileCount(under: ""), 6)
        XCTAssertEqual(library.fileCount(under: "Bass"), 4)
        XCTAssertEqual(library.fileCount(under: "Bass/Acid"), 2)
    }

    /// „Piętro wyżej" kończy się w katalogu głównym, a z niego nie ma dokąd wyjść.
    func testParentWalksUpAndStopsAtTheRoot() {
        XCTAssertEqual(DiskBankLibrary.parent(of: "Bass/Acid"), "Bass")
        XCTAssertEqual(DiskBankLibrary.parent(of: "Bass"), "")
        XCTAssertNil(DiskBankLibrary.parent(of: ""))
    }

    /// Tagi Findera przychodzą z nazwą (w języku systemu) i numerem koloru; plik bez
    /// atrybutu ma pustą listę.
    func testFinderTagsAreReadWithTheirColours() async throws {
        try tag("Leads/saw.pch2", ["Czerwony\n6", "Niebieski\n4", "Custom"])
        let library = await library()
        let saw = library.files(in: "Leads")[0]
        XCTAssertEqual(saw.tags, [
            FinderTag(name: "Czerwony", color: 6),
            FinderTag(name: "Niebieski", color: 4),
            FinderTag(name: "Custom", color: 0),
        ])
        XCTAssertEqual(library.files(in: "").first?.tags, [])
    }

    /// Stara etykieta z `FinderInfo` (bity 1–3 bajtu 9) — jedyne, co zostaje po iCloud —
    /// daje jeden tag o tym samym numerze koloru.
    func testLegacyFinderLabelBecomesATag() async {
        var info = Data(count: 32)
        info[9] = 0x0E // orange = 7, w bitach 1–3
        let path = root.appendingPathComponent("Bass/warm.pch2").path
        let result = info.withUnsafeBytes { setxattr(path, "com.apple.FinderInfo", $0.baseAddress, 32, 0, 0) }
        XCTAssertEqual(result, 0)
        let library = await library()
        XCTAssertEqual(library.files(in: "Bass")[0].tags, [FinderTag(name: "Orange", color: 7)])
    }

    /// Zapis tagów idzie w oba miejsca: lista Findera i stara etykieta — i wraca tą samą drogą.
    func testWrittenTagsComeBackAndSetTheLegacyLabel() async throws {
        let library = await library()
        let saw = library.files(in: "Leads")[0]
        try library.setTags([FinderTag(name: "Czerwony", color: 6), FinderTag(name: "Custom", color: 0)], of: saw)
        XCTAssertEqual(library.files(in: "Leads")[0].tags.map(\.color), [6, 0])
        XCTAssertEqual(DiskBankLibrary.finderTags(at: saw.url).map(\.name), ["Czerwony", "Custom"])
        var info = [UInt8](repeating: 0, count: 32)
        let read = getxattr(saw.url.path, "com.apple.FinderInfo", &info, 32, 0, 0)
        XCTAssertEqual(read, 32)
        XCTAssertEqual(info[9], 0x0C) // czerwony = 6 w bitach 1–3

        try library.setTags([], of: saw)
        XCTAssertEqual(DiskBankLibrary.finderTags(at: saw.url), [])
        XCTAssertEqual(getxattr(saw.url.path, "com.apple.FinderInfo", nil, 0, 0, 0), -1)
    }

    /// Zmiana nazwy zostawia rozszerzenie, folder i tagi; lista poprawiona bez skanu.
    func testRenameKeepsExtensionFolderAndTags() async throws {
        try tag("Leads/saw.pch2", ["Zielony\n2"])
        let library = await library()
        let saw = library.files(in: "Leads")[0]
        try library.rename(saw, to: "  super/saw ")
        let renamed = library.files(in: "Leads")[0]
        XCTAssertEqual(renamed.name, "super-saw")
        XCTAssertEqual(renamed.url.lastPathComponent, "super-saw.pch2")
        XCTAssertEqual(renamed.tags.map(\.color), [2])
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: saw.url.path))
    }

    /// Szukanie znajduje też po nazwie tagu.
    func testSearchMatchesTagNames() async throws {
        try tag("Leads/saw.pch2", ["Czerwony\n6"])
        let library = await library()
        XCTAssertEqual(library.items(matching: "czerw").map(\.name), ["saw"])
        XCTAssertEqual(library.items(matching: "red").map(\.name), ["saw"], "English colour name shown in the menu")
    }

    /// Cztery kolejności jak w Finderze: nazwa rosnąco, data i rozmiar od największych,
    /// tagi w kolejności tęczy z menu Findera (czerwony przed niebieskim), bez tagu na końcu.
    func testSortOrders() {
        func item(_ name: String, days: Double, size: Int, tags: [FinderTag] = []) -> DiskBankItem {
            DiskBankItem(
                url: URL(fileURLWithPath: "/x/\(name).pch2"), name: name, isPerformance: false,
                modified: Date(timeIntervalSince1970: days * 86400), size: size,
                relativeFolder: "", tags: tags
            )
        }
        let items = [
            item("b", days: 3, size: 10, tags: [FinderTag(name: "Niebieski", color: 4)]),
            item("a", days: 1, size: 30),
            item("c", days: 2, size: 20, tags: [FinderTag(name: "Czerwony", color: 6)]),
            item("a2", days: 2, size: 20),
        ]
        XCTAssertEqual(DiskBankLibrary.sorted(items, by: .name).map(\.name), ["a", "a2", "b", "c"])
        XCTAssertEqual(DiskBankLibrary.sorted(items, by: .date).map(\.name), ["b", "a2", "c", "a"])
        XCTAssertEqual(DiskBankLibrary.sorted(items, by: .size).map(\.name), ["a", "a2", "c", "b"])
        XCTAssertEqual(DiskBankLibrary.sorted(items, by: .tags).map(\.name), ["c", "b", "a", "a2"])
    }

    /// Rodzaj: patche przed performance'ami; kategoria alfabetycznie (Bass przed Lead),
    /// pliki bez kategorii na końcu w obu kierunkach. Remis zawsze po nazwie.
    func testKindAndCategorySortOrders() {
        func item(_ name: String, perf: Bool = false, category: Int = 0) -> DiskBankItem {
            DiskBankItem(url: URL(fileURLWithPath: "/x/\(name).\(perf ? "prf2" : "pch2")"), name: name,
                         isPerformance: perf, modified: Date(), relativeFolder: "", category: category)
        }
        let items = [item("p1", perf: true), item("lead", category: 8), item("none"),
                     item("bass", category: 3), item("bass2", category: 3)]
        func names(_ order: DiskBankSort, reversed: Bool = false) -> [String] {
            DiskBankLibrary.sorted(items, by: order, reversed: reversed).map(\.name)
        }
        XCTAssertEqual(names(.kind), ["bass", "bass2", "lead", "none", "p1"])
        XCTAssertEqual(names(.kind, reversed: true), ["p1", "bass", "bass2", "lead", "none"])
        XCTAssertEqual(names(.category), ["bass", "bass2", "lead", "none", "p1"])
        XCTAssertEqual(names(.category, reversed: true), ["lead", "bass", "bass2", "none", "p1"])
    }

    /// Kategoria z pliku na dysku trafia do listy i do szukania.
    func testScanReadsPatchCategory() async throws {
        let original = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/simplesynth001-20240802.pch2"))
        var patch = try XCTUnwrap(PatchParser.parse(data: original).first)
        patch.description.category = 1
        let data = try PatchParser.saveAll(originalData: original, patches: [patch])
        XCTAssertEqual(PatchParser.category(ofPatchFileHead: data.prefix(4096)), 1)
        try data.write(to: root.appendingPathComponent("Leads/bassy.pch2"))
        let library = await library()
        XCTAssertEqual(library.items(matching: "bassy").first?.category, 1)
        XCTAssertEqual(library.items(matching: "acoustic").map(\.name), ["bassy"], "search finds the category name")
    }

    /// Prawdziwy patch z kategorią `category`, zapisany pod `relative`.
    private func writePatch(_ relative: String, category: Int) throws {
        let original = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/simplesynth001-20240802.pch2"))
        var patch = try XCTUnwrap(PatchParser.parse(data: original).first)
        patch.description.category = category
        try PatchParser.saveAll(originalData: original, patches: [patch])
            .write(to: root.appendingPathComponent(relative))
    }

    /// Filtr kategorii zwęża folder, liczby przy folderach i szukanie; foldery bez
    /// pasującego pliku znikają, a menu zna tylko kategorie obecne w bibliotece.
    func testCategoryFilterNarrowsFoldersAndSearch() async throws {
        try writePatch("Leads/lead.pch2", category: 8)
        try writePatch("Bass/Acid/acid.pch2", category: 3)
        let library = await library()
        XCTAssertEqual(library.availableCategories, [3, 8], "Bass before Lead, by name")

        library.categoryFilter = 8
        XCTAssertEqual(library.subfolders(of: ""), ["Leads"])
        XCTAssertEqual(library.files(in: "Leads").map(\.name), ["lead"])
        XCTAssertEqual(library.fileCount(under: ""), 1)
        XCTAssertEqual(library.items(matching: "a").map(\.name), ["lead"])

        library.categoryFilter = nil
        XCTAssertEqual(library.fileCount(under: ""), 8)
    }

    /// Przełączniki pch2/prf2: chowają rodzaj w drzewie i w szukaniu i nie dają wyłączyć
    /// obu naraz.
    func testKindToggles() async {
        let library = await library()
        XCTAssertEqual(library.fileCount(under: ""), 6)

        library.toggleKind(performances: true)
        XCTAssertEqual(library.fileCount(under: ""), 5)
        XCTAssertEqual(library.subfolders(of: "Bass"), ["Acid"], "Sub held only the .prf2")
        XCTAssertTrue(library.items(matching: "deep").isEmpty)

        library.toggleKind(performances: false)
        XCTAssertTrue(library.showsPatches, "the last shown kind cannot be switched off")

        library.toggleKind(performances: true)
        library.toggleKind(performances: false)
        XCTAssertEqual(library.items(matching: "").map(\.name), ["deep"])
    }

    /// Po starcie zawsze oba rodzaje — filtr nie jest zapamiętywany.
    func testKindTogglesStartWithBoth() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        DiskBankLibrary(defaults: defaults).toggleKind(performances: true)
        let reopened = DiskBankLibrary(defaults: defaults)
        XCTAssertTrue(reopened.showsPatches)
        XCTAssertTrue(reopened.showsPerformances)
    }

    /// Tagi i zmiana nazwy nie gubią kategorii przeczytanej przy skanie.
    func testEditsKeepTheCategory() async throws {
        try writePatch("Leads/lead.pch2", category: 8)
        let library = await library()
        let lead = try XCTUnwrap(library.items(matching: "lead").first)
        try library.setTags([FinderTag(name: "Red", color: 6)], of: lead)
        try library.rename(XCTUnwrap(library.items(matching: "lead").first), to: "lead2")
        XCTAssertEqual(library.items(matching: "lead2").first?.category, 8)
    }

    /// Dymek: liczba modułów i obciążenie DSP policzone z pliku — te same liczby co
    /// szacunek obciążenia w panelu DSP.
    func testSummaryCountsModulesAndLoad() throws {
        try writePatch("Leads/lead.pch2", category: 8)
        let url = root.appendingPathComponent("Leads/lead.pch2")
        let patch = try XCTUnwrap(PatchParser.parse(url: url).first)
        let summary = try XCTUnwrap(DiskBankLibrary.summary(of: url))
        XCTAssertEqual(summary.slots.count, 1)
        let slot = summary.slots[0]
        XCTAssertEqual(slot.modules, patch.voiceModules.count + patch.fxModules.count)
        XCTAssertGreaterThan(slot.modules, 0)
        let voice = G2PatchLoad.estimate(area: .voice, patch: patch)
        XCTAssertEqual(slot.voiceLoad, max(voice.cyclesPercent, voice.memoryPercent), accuracy: 0.001)
        XCTAssertTrue(slot.line.hasPrefix("\(slot.modules) modules · DSP Voice "))
        XCTAssertNil(DiskBankLibrary.summary(of: root.appendingPathComponent("root.pch2")), "not a patch")
    }

    /// Kolejność jest zapamiętana między uruchomieniami, jak folder.
    func testSortOrderIsRemembered() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        DiskBankLibrary(defaults: defaults).sortOrder = .date
        XCTAssertEqual(DiskBankLibrary(defaults: defaults).sortOrder, .date)
    }

    /// Każda kolejność działa w obie strony; remis nadal po nazwie rosnąco, a pliki bez
    /// tagu zostają na końcu także przy odwróconej tęczy.
    func testReversedSortOrders() {
        func item(_ name: String, days: Double, size: Int, tags: [FinderTag] = []) -> DiskBankItem {
            DiskBankItem(
                url: URL(fileURLWithPath: "/x/\(name).pch2"), name: name, isPerformance: false,
                modified: Date(timeIntervalSince1970: days * 86400), size: size,
                relativeFolder: "", tags: tags
            )
        }
        let items = [
            item("b", days: 3, size: 10, tags: [FinderTag(name: "Niebieski", color: 4)]),
            item("a", days: 1, size: 30),
            item("c", days: 2, size: 20, tags: [FinderTag(name: "Czerwony", color: 6)]),
            item("a2", days: 2, size: 20),
        ]
        func names(_ order: DiskBankSort) -> [String] {
            DiskBankLibrary.sorted(items, by: order, reversed: true).map(\.name)
        }
        XCTAssertEqual(names(.name), ["c", "b", "a2", "a"])
        XCTAssertEqual(names(.date), ["a", "a2", "c", "b"])
        XCTAssertEqual(names(.size), ["b", "a2", "c", "a"])
        XCTAssertEqual(names(.tags), ["b", "c", "a", "a2"])
    }

    /// Kierunek jest zapamiętany, a zmiana klucza wraca do jego domyślnego kierunku —
    /// jak nowa kolumna w Finderze.
    func testSortDirectionIsRememberedAndResetsWithNewKey() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let library = DiskBankLibrary(defaults: defaults)
        library.sortOrder = .size
        library.sortReversed = true
        XCTAssertTrue(DiskBankLibrary(defaults: defaults).sortReversed)

        library.sortOrder = .date
        XCTAssertFalse(library.sortReversed)
        XCTAssertFalse(DiskBankLibrary(defaults: defaults).sortReversed)
    }

    /// Odwrócenie przelicza listę folderu, nie tylko wyniki szukania.
    func testReversingReordersFolderListing() async {
        let library = await library()
        library.sortReversed = true
        XCTAssertEqual(library.files(in: "Bass/Acid").map(\.name), ["303b", "303"])
    }

    /// Przeglądarka wraca do podfolderu, w którym skończyła się poprzednia sesja.
    func testCurrentFolderIsRemembered() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let first = DiskBankLibrary(defaults: defaults)
        first.setFolder(root)
        first.currentPath = "Bass/Acid"

        let next = DiskBankLibrary(defaults: defaults)
        await next.scan()
        XCTAssertEqual(next.folder?.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(next.currentPath, "Bass/Acid")
    }

    /// Nowy folder główny zaczyna od szczytu; podfolder, który zniknął z dysku, też.
    func testCurrentFolderResetsWhenItNoLongerApplies() async throws {
        let library = await library()
        library.currentPath = "Leads"
        library.setFolder(root.appendingPathComponent("Bass"))
        XCTAssertEqual(library.currentPath, "")

        library.setFolder(root)
        await library.scan()
        library.currentPath = "Leads"
        try FileManager.default.removeItem(at: root.appendingPathComponent("Leads"))
        await library.scan()
        XCTAssertEqual(library.currentPath, "")
    }

    /// Szukanie idzie po CAŁEJ bibliotece, nie po otwartym folderze.
    func testSearchLooksThroughEveryFolder() async {
        let library = await library()
        XCTAssertEqual(library.items(matching: "303").map(\.name), ["303", "303b"])
        XCTAssertEqual(library.items(matching: "Acid").count, 2)
    }

    /// Skan urwany limitem MÓWI o tym wprost. Cicho ucięta lista wygląda jak kompletna,
    /// a znika z niej wszystko, co enumerator odwiedził później — u użytkownika zniknął
    /// w ten sposób cały świeżo kupiony folder (2026-09-19, biblioteka 45 043 plików
    /// przy limicie 5 000) → [[Docs/context/bug-history]] #102.
    func testTruncatedScanSaysSo() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let library = DiskBankLibrary(defaults: defaults, scanLimit: 3)
        library.setFolder(root)
        await library.scan()
        XCTAssertEqual(library.items.count, 3)
        XCTAssertEqual(library.message, "Showing the first 3 files — this folder holds more.")
    }

    /// Limit domyślny ma mieścić prawdziwą bibliotekę patchy z sieci, nie tylko własny
    /// folder roboczy: sam pakiet „Nord Modular G1 G2" to ponad 35 000 plików.
    func testDefaultScanLimitFitsARealLibrary() {
        XCTAssertGreaterThanOrEqual(DiskBankLibrary.scanLimit, 100_000)
    }

    /// Drzewo folderów liczone jest raz po skanie (#103), więc każda zmiana listy musi je
    /// przeliczyć — inaczej panel pokazywałby stan sprzed przeniesienia pliku do Kosza.
    func testTrashUpdatesFolderCountsAndListing() async throws {
        let library = await library()
        let item = try XCTUnwrap(library.files(in: "Bass/Acid").first { $0.name == "303" })
        XCTAssertEqual(library.fileCount(under: "Bass"), 4)

        try library.trash(item)

        XCTAssertEqual(library.fileCount(under: "Bass"), 3)
        XCTAssertEqual(library.fileCount(under: "Bass/Acid"), 1)
        XCTAssertEqual(library.files(in: "Bass/Acid").map(\.name), ["303b"])
    }

    /// Ta sama pułapka przy zmianie kolejności: pliki w folderze są posortowane w drzewie,
    /// więc menu ⇅ musi je przeliczyć.
    func testSortOrderChangeReordersFolderListing() async throws {
        let library = await library()
        XCTAssertEqual(library.files(in: "Bass/Acid").map(\.name), ["303", "303b"])

        let older = try XCTUnwrap(library.files(in: "Bass/Acid").first { $0.name == "303" })
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: older.url.path
        )
        await library.scan()
        library.sortOrder = .date

        XCTAssertEqual(library.files(in: "Bass/Acid").map(\.name), ["303b", "303"])
    }
}
