// MultiSlotTests.swift
// Mapowanie slotów w plikach wieloslotowych (.prf2): pusty slot musi zostać na
// swoim miejscu w tablicy, a sekcja 0x21 nie ma bitów obszaru. Testy budują
// własny plik od zera, więc nie zależą od żadnego cudzego patcha.

@testable import G2Core
import XCTest

final class MultiSlotTests: XCTestCase {
    /// Nagłówek tekstowy + \0 + 2 bajty wersji binarnej — minimum, które przechodzi parseTextHeader.
    private let header = Array("Version=Nord Modular G2 File Format 1\r\nType=Performance\r\n".utf8)
        + [0, 23, 0] as [UInt8]

    /// Sekcja 0x21 (PatchDescription), 15 B jak w prawdziwych plikach. `firstByte`
    /// to pierwszy z 7 bajtów nieznanych danych — celowo parametryzowany, bo
    /// w kolekcji referencyjnej bywa ≥ 0x40 i to on rozjeżdżał mapowanie slotów.
    private func descriptionSection(category: Int, firstByte: UInt8 = 0) throws -> [UInt8] {
        var bs = BitStream(data: [UInt8](repeating: 0, count: 15), startBit: 7 * 8)
        try bs.writeBits(5, value: 0) // reserved
        try bs.writeBits(5, value: 8) // voices
        try bs.writeBits(14, value: 0) // height
        try bs.writeBits(3, value: 0) // unk2
        try bs.writeBits(7, value: 0x7F) // 7 flag widoczności kolorów kabli
        try bs.writeBits(2, value: 1) // monopoly
        try bs.writeBits(8, value: 2) // variation
        try bs.writeBits(8, value: UInt32(category))
        var body = bs.toBytes()
        body[0] = firstByte
        return [0x21, UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)] + body
    }

    private func moduleSection(slot: Int, moduleCount: Int) throws -> [UInt8] {
        let modules: [G2Module] = (0 ..< moduleCount).map { i in
            var m = G2Module(id: 10 * (slot + 1) + i, typeID: 4, area: .voice)
            m.column = slot
            m.row = i
            return m
        }
        return try PatchParser.writeModuleList(modules: modules, area: .voice)
    }

    /// Plik z czterema kompletami sekcji, w którym slot B jest pusty — dokładnie
    /// kształt 70 plików .prf2 z kolekcji referencyjnej (pusty slot PRZED używanym).
    private func performanceFile(moduleCounts: [Int] = [1, 0, 1, 2]) throws -> Data {
        var bytes = header
        for (slot, count) in moduleCounts.enumerated() {
            bytes += try moduleSection(slot: slot, moduleCount: count)
            // Ostatni opis dostaje pierwszy bajt 0x79 — tak wygląda m.in. Burn.prf2.
            bytes += try descriptionSection(category: 5 + slot, firstByte: slot == 3 ? 0x79 : 0)
        }
        bytes += [0, 0] // CRC — parse go nie weryfikuje
        return Data(bytes)
    }

    func testEmptySlotKeepsItsPlaceInTheSlotList() throws {
        let patches = try PatchParser.parse(data: performanceFile())
        XCTAssertEqual(patches.count, 4, "plik ma 4 komplety sekcji — muszą wyjść 4 sloty")
        XCTAssertEqual(patches[0].voiceModules.count, 1)
        XCTAssertTrue(patches[1].voiceModules.isEmpty, "slot B jest pusty i taki ma zostać")
        XCTAssertEqual(patches[2].voiceModules.map(\.id), [30], "moduły slotu C trafiły do złego slotu")
        XCTAssertEqual(patches[3].voiceModules.map(\.id), [40, 41], "moduły slotu D trafiły do złego slotu")
    }

    func testDescriptionOfEachSlotLandsInItsOwnSlot() throws {
        let patches = try PatchParser.parse(data: performanceFile())
        XCTAssertEqual(patches.map(\.description.category), [5, 6, 7, 8],
                       "opis patcha rozjechał się między slotami")
        XCTAssertEqual(patches[3].description.voices, 8)
        XCTAssertEqual(patches[3].description.monopoly, 1)
    }

    func testSaveDoesNotMoveModulesBetweenSlots() throws {
        let data = try performanceFile()
        var patches = try PatchParser.parse(data: data)
        patches[3].voiceModules[0].column = 42
        let saved = try PatchParser.saveAll(originalData: data, patches: patches)
        let reparsed = try PatchParser.parse(data: saved)

        XCTAssertEqual(reparsed.count, 4)
        XCTAssertEqual(reparsed[3].voiceModules.first?.column, 42, "zmiana nie dojechała do slotu D")
        XCTAssertTrue(reparsed[1].voiceModules.isEmpty, "pusty slot B dostał cudze moduły")
        XCTAssertEqual(reparsed[2].voiceModules.map(\.id), [30], "slot C dostał moduły innego slotu")
    }
}
