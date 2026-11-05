@testable import G2Core
import XCTest

/// Zawartość banków Norda — kursorowa rozmowa `0x14` → `0x16` (patrz `G2BankList`).
final class G2BankListTests: XCTestCase {
    /// Nagłówek: bajt „po liście" + typ pliku.
    private func body(kind: UInt8, _ rest: [UInt8]) -> [UInt8] {
        [0x01, kind] + rest
    }

    private func name(_ text: String, category: UInt8) -> [UInt8] {
        Array(text.utf8) + [0x00, category]
    }

    func testReadsNamesAndCountsPlacesUpwards() throws {
        let payload = body(kind: 0, name("Bass", category: 3) + name("Lead", category: 5) + [0x05])
        let page = try XCTUnwrap(G2UsbProtocol.decodeBankNames(payload))

        XCTAssertEqual(page.entries.map(\.name), ["Bass", "Lead"])
        XCTAssertEqual(page.entries.map(\.patch), [0, 1], "numer miejsca rośnie po każdej nazwie")
        XCTAssertEqual(page.entries.map(\.category), [3, 5])
        XCTAssertEqual(page.entries[0].kind, .patch)
    }

    /// `0x03` przestawia kursor na inny bank — bez tego wszystko wylądowałoby w banku 0.
    func testBankControlByteMovesTheCursor() throws {
        let payload = body(kind: 0, [0x03, 2, 7] + name("Pad", category: 0) + [0x05])
        let page = try XCTUnwrap(G2UsbProtocol.decodeBankNames(payload))

        XCTAssertEqual(page.entries.map(\.bank), [2])
        XCTAssertEqual(page.entries.map(\.patch), [7])
        XCTAssertEqual(page.entries[0].displayLocation, "3:8", "front Norda liczy od jedynki")
    }

    /// Nazwa o pełnych 16 znakach nie ma zera na końcu — kategoria idzie zaraz po niej.
    func testSixteenCharacterNameIsClosedWithoutATerminator() throws {
        let full = String(repeating: "X", count: 16)
        let payload = body(kind: 0, Array(full.utf8) + [9] + [0x05])
        let page = try XCTUnwrap(G2UsbProtocol.decodeBankNames(payload))

        XCTAssertEqual(page.entries.map(\.name), [full])
        XCTAssertEqual(page.entries[0].category, 9)
    }

    /// `0x04` kończy patche i przestawia na performance'y, zerując bank i miejsce.
    func testNextModeSwitchesToPerformancesAndRewinds() throws {
        let payload = body(kind: 0, [0x03, 1, 4] + name("Old", category: 0) + [0x04])
        let page = try XCTUnwrap(G2UsbProtocol.decodeBankNames(payload))

        XCTAssertEqual(page.next.kind, 1)
        XCTAssertEqual(page.next.bank, 0)
        XCTAssertEqual(page.next.patch, 0)
        XCTAssertFalse(page.next.isFinished)
    }

    /// Typ pliku 2 znaczy „przejrzane wszystko" — na tym kończy się pętla odczytu.
    func testCursorAfterPerformancesIsFinished() throws {
        let page = try XCTUnwrap(G2UsbProtocol.decodeBankNames(body(kind: 1, [0x04])))
        XCTAssertTrue(page.next.isFinished)
    }

    /// Urządzenie potrafi wcisnąć `0x13` i `0x16` w jedną ramkę; nasz dekoder ramki
    /// rozpoznaje tylko pierwszy komunikat, więc drugi trzeba znaleźć samemu.
    func testFindsTheNameRecordBehindTheListHeader() throws {
        let names = body(kind: 0, name("Bass", category: 1) + [0x05])
        let payload: [UInt8] = [0x30, 0x02, G2UsbProtocol.subResponseBankNames] + names

        let found = try XCTUnwrap(G2UsbProtocol.bankNamesBody(
            payload: payload, subCommand: G2UsbProtocol.subResponseBankListInfo
        ))
        XCTAssertEqual(try XCTUnwrap(G2UsbProtocol.decodeBankNames(found)).entries.map(\.name), ["Bass"])
    }

    func testTooShortPayloadIsRejectedRatherThanGuessed() {
        XCTAssertNil(G2UsbProtocol.decodeBankNames([0x01]))
        XCTAssertNil(G2UsbProtocol.bankNamesBody(payload: [0x30], subCommand: 0x13))
    }

    // MARK: - Komendy

    func testListRequestCarriesTheCursor() {
        XCTAssertEqual(
            G2UsbProtocol.listBankNamesPayload(cursor: G2BankCursor(kind: 1, bank: 2, patch: 3)),
            [0x01, 0x2C, 0x41, 0x14, 1, 2, 3]
        )
    }

    /// `[0x0A][slot][bank][patch]` — Clavia Flash Load Command, BVerhue `S_RETREIVE`.
    func testLoadFromBankPayloadEncodesSlotBankAndPatch() {
        XCTAssertEqual(G2UsbProtocol.loadFromBankPayload(slot: 2, bank: 1, patch: 5),
                       [0x01, 0x2C, 0x41, 0x0A, 2, 1, 5])
    }

    /// `[0x0B][slot][bank][patch]` — Clavia Flash Store Command, BVerhue `S_STORE`.
    func testStoreToBankPayloadEncodesSlotBankAndPatch() {
        XCTAssertEqual(G2UsbProtocol.storeToBankPayload(slot: 4, bank: 0, patch: 1),
                       [0x01, 0x2C, 0x41, 0x0B, 4, 0, 1])
    }

    /// Ramka zmierzona na wirtualnym G2 2026-09-26: nowy wpis listy nazw (`0x13` … `0x16`),
    /// a na końcu `R_STORE` z wynikiem 2 = zapisane.
    func testStoreResultIsReadFromTheTailOfTheNamesFrame() {
        let payload: [UInt8] = [0x00, 0x00, 0x16, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x08, 0x05,
                                0x0D, 0x00, 0x00, 0x00, 0x00, 0x02]
        let result = G2UsbProtocol.storeResult(payload: payload, subCommand: 0x13)
        XCTAssertEqual(result, 2)
        XCTAssertTrue(G2UsbProtocol.storeSucceeded(2))
    }

    /// Sam `R_STORE` bez listy nazw — tak przyszła odmowa „Flash memory full" (wynik 3).
    func testStoreResultStandingAloneReportsFlashFull() {
        let result = G2UsbProtocol.storeResult(payload: [0x00, 0x00, 0x00, 0x00, 0x03], subCommand: 0x0D)
        XCTAssertEqual(result, 3)
        XCTAssertFalse(G2UsbProtocol.storeSucceeded(3))
    }

    // MARK: - Banki w panelu

    private let sample = [
        G2BankEntry(kind: .performance, bank: 0, patch: 0, name: "Early Autumn", category: 0),
        G2BankEntry(kind: .patch, bank: 1, patch: 0, name: "Zither", category: 3),
        G2BankEntry(kind: .patch, bank: 0, patch: 1, name: "BackTo72", category: 8),
        G2BankEntry(kind: .patch, bank: 0, patch: 0, name: "-- Welcome G2 --", category: 12),
        G2BankEntry(kind: .patch, bank: 0, patch: 2, name: "Accordion", category: 3),
    ]

    /// Banki po kolei — najpierw patche, potem performance'y — a w banku miejsca rosnąco.
    func testGroupsFollowTheFrontPanelOrder() {
        let groups = G2BankGroup.grouped(sample)
        XCTAssertEqual(groups.map(\.title), ["Patch Bank 1", "Patch Bank 2", "Performance Bank 1"])
        XCTAssertEqual(groups[0].entries.map(\.patch), [0, 1, 2])
    }

    /// Puste banki: 32 patchy + 8 performance'ów minus te, które mają choć jedną pozycję.
    func testEmptyBanksAreTheOnesTheDeviceListLeavesOut() {
        let empty = G2BankGroup.emptyBanks(sample)
        XCTAssertEqual(empty.count, 30 + 7)
        XCTAssertEqual(empty.first?.kind, .patch)
        XCTAssertEqual(empty.first?.bank, 2, "banki 1 i 2 mają patche")
        XCTAssertEqual(empty.last?.kind, .performance)
        XCTAssertEqual(empty.last?.bank, 7)
        XCTAssertFalse(empty.contains { $0.kind == .performance && $0.bank == 0 })
        XCTAssertEqual(G2BankGroup.emptyBanks(sample, kinds: [.performance]).count, 7)
        XCTAssertEqual(G2BankGroup.emptyBanks([]).count, 40)
    }

    /// Bajty zmierzone na wirtualnym G2 2026-11-04 (`USBProbe --send`).
    func testDeletePayloadsMatchTheMeasuredCommands() {
        XCTAssertEqual(G2UsbProtocol.deleteFromBankPayload(kind: .patch, bank: 0, location: 2),
                       [0x01, 0x2C, 0x41, 0x0C, 0x00, 0x00, 0x02, 0x00])
        XCTAssertEqual(G2UsbProtocol.deleteBankRangePayload(kind: .patch, bank: 1, from: 0, to: 127),
                       [0x01, 0x2C, 0x41, 0x0E, 0x00, 0x01, 0x00, 0x01, 0x7F, 0x00])
        XCTAssertEqual(G2UsbProtocol.deleteFromBankPayload(kind: .performance, bank: 7, location: 127)[4], 0x01)
        // Odpowiedzi z pomiaru: wynik flasha 0x0D na końcu, 5 = OK.
        XCTAssertEqual(G2UsbProtocol.storeResult(
            payload: [0x00, 0x00, 0x02, 0x13, 0x1E, 0x02, 0x0D, 0x00, 0x00, 0x02, 0x00, 0x05], subCommand: 0x15
        ), 5)
        XCTAssertEqual(G2UsbProtocol.storeResult(
            payload: [0x00, 0x01, 0x00, 0x01, 0x7F, 0x13, 0x50, 0x01, 0x0D, 0x00, 0x01, 0x00, 0x00, 0x05],
            subCommand: 0x12
        ), 5)
    }

    func testSortingByNameAndCategoryStaysInsideTheBank() {
        let byName = G2BankGroup.grouped(sample, sort: .name)
        XCTAssertEqual(byName[0].entries.map(\.name), ["-- Welcome G2 --", "Accordion", "BackTo72"])
        let byCategory = G2BankGroup.grouped(sample, sort: .category, reversed: true)
        XCTAssertEqual(byCategory[0].entries.map(\.category), [12, 8, 3])
        XCTAssertEqual(byCategory[1].entries.map(\.name), ["Zither"])
    }

    /// Szukanie i kategoria chowają banki bez trafień; performance'y nie mają kategorii.
    func testFiltersDropBanksWithoutMatches() {
        XCTAssertEqual(G2BankGroup.grouped(sample, query: "zith").map(\.title), ["Patch Bank 2"])
        let bass = G2BankGroup.grouped(sample, category: 3)
        XCTAssertEqual(bass.map(\.title), ["Patch Bank 1", "Patch Bank 2"])
        XCTAssertEqual(bass[0].entries.map(\.name), ["Accordion"])
    }

    // MARK: - Bank Upload — układ Clavii (`.pchList` + pliki)

    private func entry(_ name: String, _ kind: G2BankEntry.Kind = .patch,
                       bank: Int = 1, patch: Int) -> G2BankEntry
    {
        G2BankEntry(kind: kind, bank: bank, patch: patch, name: name, category: 0)
    }

    /// Lista bajt w bajt jak w banku fabrycznym (`PatchBank2.pchList`): nagłówek,
    /// numeracja od 1, CRLF także po ostatniej linii.
    func testBankDumpListMatchesClaviaLayout() {
        let entries = [entry("CryMe", patch: 0), entry("BraBrassNL1", patch: 1)]
        let list = G2BankDump.listFile(entries: entries, fileNames: G2BankDump.fileNames(for: entries))

        XCTAssertEqual(String(decoding: list, as: UTF8.self),
                       "Version=Nord Modular G2 Bank Dump\r\n2:1: CryMe.pch2\r\n2:2: BraBrassNL1.pch2\r\n")
        XCTAssertEqual(G2BankDump.bankName(kind: .patch, bank: 1), "PatchBank2")
        XCTAssertEqual(G2BankDump.bankName(kind: .performance, bank: 0), "PerfBank1")
    }

    /// Powtórzone nazwy dostają przyrostek (dysk Maca nie rozróżnia wielkości liter),
    /// a znaki, których nazwa pliku albo lista nie zniesie, znikają.
    func testBankDumpFileNamesAreUniqueAndSafe() {
        let entries = [
            entry("Pad", patch: 0), entry("pad", patch: 1), entry("Pad", patch: 2),
            entry("A/B:C", patch: 3), entry(".hidden", patch: 4), entry("FATBass  NL2", patch: 5),
            entry("Arp", .performance, bank: 0, patch: 0),
        ]
        XCTAssertEqual(G2BankDump.fileNames(for: entries), [
            "Pad.pch2", "pad 2.pch2", "Pad 3.pch2", "A-B-C.pch2", "_hidden.pch2",
            "FATBass  NL2.pch2", "Arp.prf2",
        ])
    }

    // MARK: - Upload Banks to G2 — folder do jednego banku (2026-11-04)

    private func folder(_ files: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bankplan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, text) in files {
            try Data(text.utf8).write(to: url.appendingPathComponent(name))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Bez listy: kolejność Findera („2” przed „10”), od miejsca 1; nazwa w banku z nazwy
    /// pliku, najwyżej 16 znaków; `.prf2` liczone osobno, ukryte pliki pomijane.
    func testUploadPlanWithoutListFillsTheBankInFinderOrder() throws {
        let url = try folder(["Pad 10.pch2": "", "Pad 2.pch2": "", "Sound FX & textures FM4.pch2": "",
                              "Techno machine.prf2": "", "._Pad 2.pch2": "", "notes.txt": ""])
        let plan = try G2BankDump.uploadPlan(folder: url, kind: .patch)

        XCTAssertFalse(plan.fromList)
        XCTAssertEqual(plan.items.map(\.name), ["Pad 2", "Pad 10", "Sound FX & textu"])
        XCTAssertEqual(plan.items.map(\.location), [0, 1, 2])
        XCTAssertEqual(plan.otherKindCount, 1)
        XCTAssertTrue(plan.leftOut.isEmpty)

        let performances = try G2BankDump.uploadPlan(folder: url, kind: .performance)
        XCTAssertEqual(performances.items.map(\.name), ["Techno machine"])
        XCTAssertEqual(performances.otherKindCount, 3)
    }

    func testUploadPlanLeavesOutWhatDoesNotFitInABank() throws {
        let files = Dictionary(uniqueKeysWithValues: (1 ... 130).map { ("P\($0).pch2", "") })
        let plan = try G2BankDump.uploadPlan(folder: folder(files), kind: .patch)

        XCTAssertEqual(plan.items.count, 128)
        XCTAssertEqual(plan.items.last?.location, 127)
        XCTAssertEqual(plan.leftOut, ["P129.pch2", "P130.pch2"])
    }

    /// Z listą `.pchList` miejsca są z listy (bank z listy się pomija), linie bez pliku
    /// albo z zajętym miejscem trafiają do pominiętych.
    func testUploadPlanWithListKeepsTheListedLocations() throws {
        let list = "Version=Nord Modular G2 Bank Dump\r\n3:5: FATBass  NL2.pch2\r\n3:1: CryMe.pch2\r\n"
            + "3:1: Again.pch2\r\n3:9: Missing.pch2\r\n"
        let url = try folder(["PatchBank3.pchList": list, "FATBass  NL2.pch2": "", "CryMe.pch2": "",
                              "Again.pch2": "", "Extra.pch2": ""])
        let plan = try G2BankDump.uploadPlan(folder: url, kind: .patch)

        XCTAssertTrue(plan.fromList)
        XCTAssertEqual(plan.items.map(\.location), [0, 4])
        XCTAssertEqual(plan.items.map(\.name), ["CryMe", "FATBass  NL2"])
        XCTAssertEqual(plan.leftOut, ["Again.pch2", "Missing.pch2"])
    }

    func testParsedListIsTheWrittenListBackwards() {
        let entries = [entry("CryMe", patch: 0), entry("FATBass  NL2", patch: 6)]
        let list = G2BankDump.listFile(entries: entries, fileNames: G2BankDump.fileNames(for: entries))
        let parsed = G2BankDump.parseList(list)

        XCTAssertEqual(parsed.map(\.bank), [1, 1])
        XCTAssertEqual(parsed.map(\.location), [0, 6])
        XCTAssertEqual(parsed.map(\.file), ["CryMe.pch2", "FATBass  NL2.pch2"])
    }
}
