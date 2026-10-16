// RoundTripFidelityTests.swift
// Wierność zapisu: plik wczytany i zapisany bez zmian ma wyjść bajt w bajt.
// Testy budują plik od zera, zgodnie z tym, co robi oryginał (oryginalny edytor Clavii,
// Module Data 11 / Module Param Data 11 / Module Name Data 11).
// Opis układu i dowody z kolekcji referencyjnej → Docs/parser/sections.md.

@testable import G2Core
import XCTest

final class RoundTripFidelityTests: XCTestCase {
    private let header = Array("Version=Nord Modular G2 File Format 1\r\nType=Patch\r\n".utf8)
        + [0, 23, 0] as [UInt8]

    // MARK: - Budowanie pliku

    private func section(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        [type, UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)] + body
    }

    /// Dwa moduły w kolejności malejącej po `id` — oryginał trzyma listę modułów
    /// w kolejności wstawiania, więc sekcja 0x4a sortowana **nie jest**.
    /// Cztery ostatnie bity ostatniego bajtu to dopełnienie: oryginał zostawia tam
    /// zawartość bufora, więc zapis ma je przepisać, a nie wyzerować.
    private func moduleListSection(tailBits: UInt32) throws -> [UInt8] {
        var bs = BitStream(data: [])
        try bs.writeBits(2, value: 1) // area = voice
        try bs.writeBits(8, value: 2) // liczba modułów
        for (id, typeID, color) in [(5, 4, 7), (2, 8, 3)] {
            try bs.writeBits(8, value: UInt32(typeID))
            try bs.writeBits(8, value: UInt32(id))
            try bs.writeBits(7, value: UInt32(id)) // column
            try bs.writeBits(7, value: UInt32(id * 2)) // row
            try bs.writeBits(8, value: UInt32(color))
            try bs.writeBits(1, value: 1) // uprate
            try bs.writeBits(1, value: 0) // leds
            try bs.writeBits(6, value: 0) // reserved — oryginał zapisuje tu zero
            try bs.writeBits(4, value: 0) // brak trybów
        }
        try bs.writeBits(2, value: tailBits) // dopełnienie do pełnego bajtu
        return section(0x4A, bs.toBytes())
    }

    /// Moduły rosnąco po `id` (oryginał iteruje posortowane drzewo), przy czym
    /// moduł 5 ma wpis z **zerem parametrów** — takie wpisy w plikach występują
    /// i muszą przetrwać zapis.
    private func parametersSection(tailBits: UInt32) throws -> [UInt8] {
        var bs = BitStream(data: [])
        try bs.writeBits(2, value: 1) // area = voice
        try bs.writeBits(8, value: 2) // moduły z wpisem
        try bs.writeBits(8, value: 9) // warianty
        try bs.writeBits(8, value: 2) // moduł 2
        try bs.writeBits(7, value: 2) // dwa parametry
        for variation in 0 ..< 9 {
            try bs.writeBits(8, value: UInt32(variation))
            try bs.writeBits(7, value: UInt32(variation * 3))
            try bs.writeBits(7, value: UInt32(100 - variation))
        }
        try bs.writeBits(8, value: 5) // moduł 5
        try bs.writeBits(7, value: 0) // zero parametrów
        for variation in 0 ..< 9 {
            try bs.writeBits(8, value: UInt32(variation))
        }
        try bs.writeBits(2, value: tailBits)
        return section(0x4D, bs.toBytes())
    }

    /// Pusta sekcja parametrów obszaru FX z licznikiem wariantów 9. Prawie wszystkie
    /// puste sekcje mają tam zero, ale nie wszystkie — wartości nie da się wyliczyć.
    private func emptyParametersSection(variationCount: UInt32) throws -> [UInt8] {
        var bs = BitStream(data: [])
        try bs.writeBits(2, value: 0) // area = fx
        try bs.writeBits(8, value: 0) // brak modułów
        try bs.writeBits(8, value: variationCount)
        try bs.writeBits(6, value: 0)
        return section(0x4D, bs.toBytes())
    }

    /// Nazwy rosnąco po `id`, jedna pusta. Sześć bitów za polem obszaru to
    /// dopełnienie, którego oryginał nie wypełnia (`Skip(6)`) — w plikach bywa
    /// niezerowe i zapis ma je przepisać.
    private func moduleNamesSection(padding: UInt32) throws -> [UInt8] {
        var bs = BitStream(data: [])
        try bs.writeBits(2, value: 1) // area = voice
        try bs.writeBits(6, value: padding)
        try bs.writeBits(8, value: 2)
        try bs.writeBits(8, value: 2) // moduł 2
        for byte in Array("Osc".utf8) + [0] {
            try bs.writeBits(8, value: UInt32(byte))
        }
        try bs.writeBits(8, value: 5) // moduł 5 — wpis z pustą nazwą
        try bs.writeBits(8, value: 0)
        return section(0x5A, bs.toBytes())
    }

    /// Notatki z bajtem spoza ASCII — plik jest ośmiobitowy, więc zapis w UTF-8
    /// wydłużyłby sekcję.
    private func textPadSection() -> [UInt8] {
        section(0x6F, Array("Prze".utf8) + [0xE9] + Array("cz".utf8))
    }

    private func patchFile(tailBits: UInt32 = 3,
                           namesPadding: UInt32 = 42,
                           emptyVariationCount: UInt32 = 9) throws -> Data
    {
        var bytes = header
        bytes += try moduleListSection(tailBits: tailBits)
        bytes += try parametersSection(tailBits: tailBits)
        bytes += try emptyParametersSection(variationCount: emptyVariationCount)
        bytes += try moduleNamesSection(padding: namesPadding)
        bytes += textPadSection()
        return Data(bytes + [0, 0]) // CRC dopisuje zapis
    }

    /// Zapis przelicza dwa ostatnie bajty (CRC), więc porównujemy resztę pliku.
    private func assertRoundTrips(_ data: Data,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) throws
    {
        let saved = try PatchParser.saveAll(originalData: data,
                                            patches: PatchParser.parse(data: data))
        XCTAssertEqual(Array(saved.dropLast(2)), Array(data.dropLast(2)), file: file, line: line)
    }

    // MARK: - Wierność

    func testFileWrittenLikeTheOriginalSurvivesSaveByteForByte() throws {
        try assertRoundTrips(patchFile())
    }

    func testEmptyParameterSectionKeepsItsVariationCount() throws {
        // 0 i 9 — obie wartości realnie występują w plikach.
        try assertRoundTrips(patchFile(emptyVariationCount: 0))
        try assertRoundTrips(patchFile(emptyVariationCount: 9))
    }

    func testModuleNamesPaddingAndSectionTailAreCopiedFromTheFile() throws {
        try assertRoundTrips(patchFile(tailBits: 0, namesPadding: 0))
        try assertRoundTrips(patchFile(tailBits: 3, namesPadding: 63))
    }

    func testModuleWithoutParametersKeepsItsEntry() throws {
        let data = try patchFile()
        let saved = try PatchParser.saveAll(originalData: data, patches: PatchParser.parse(data: data))
        let patch = try XCTUnwrap(PatchParser.parse(data: saved).first)
        let module = try XCTUnwrap(patch.voiceModules.first { $0.id == 5 })
        XCTAssertTrue(module.hasParameterEntry, "wpis z zerem parametrów nie może zniknąć")
        XCTAssertTrue(module.hasNameEntry, "wpis z pustą nazwą nie może zniknąć")
        XCTAssertEqual(module.label, "")
    }

    func testNotesWithNonAsciiByteKeepTheirLength() throws {
        let data = try patchFile()
        let patch = try XCTUnwrap(PatchParser.parse(data: data).first)
        XCTAssertEqual(patch.notes, "Przeécz")
        XCTAssertEqual(PatchParser.textPadBytes(patch.notes).count, 7)
    }

    // MARK: - Kolejność

    func testParametersAndNamesAreSortedByModuleIdEvenWhenTheFileIsNot() throws {
        // Sekcje 0x4d i 0x5a zapisane w kolejności malejącej — oryginał tak nie umie
        // (iteruje posortowane drzewo), więc zapis ma je uporządkować rosnąco.
        var bs = BitStream(data: [])
        try bs.writeBits(2, value: 1)
        try bs.writeBits(6, value: 0)
        try bs.writeBits(8, value: 2)
        try bs.writeBits(8, value: 5) // moduł 5 przed modułem 2
        try bs.writeBits(8, value: 0)
        try bs.writeBits(8, value: 2)
        for byte in Array("Osc".utf8) + [0] {
            try bs.writeBits(8, value: UInt32(byte))
        }
        var bytes = header
        bytes += try moduleListSection(tailBits: 0)
        bytes += section(0x5A, bs.toBytes())
        let data = Data(bytes + [0, 0])

        let saved = try PatchParser.saveAll(originalData: data, patches: PatchParser.parse(data: data))
        // Pierwszy wpis sekcji nazw zaczyna się 16 bitów za początkiem jej ciała.
        let sectionStart = try header.count + moduleListSection(tailBits: 0).count + 3
        XCTAssertEqual(saved[sectionStart + 2], 2, "zapis ma zaczynać od modułu o niższym id")
    }

    func testModuleListKeepsFileOrder() throws {
        // Odwrotnie niż 0x4d/0x5a: lista modułów zostaje w kolejności z pliku.
        let data = try patchFile()
        let patch = try XCTUnwrap(PatchParser.parse(data: data).first)
        XCTAssertEqual(patch.voiceModules.map(\.id), [5, 2])
    }
}
