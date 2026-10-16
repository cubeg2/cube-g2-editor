// RoundTripTests.swift
// True round-trip tests: parse → saveAll → parse → compare models.
// Freezes the binary format correctness (sections 0x4a/0x52/0x4d/0x5a + CRC-16).

@testable import G2Core
import XCTest

final class RoundTripTests: XCTestCase {
    // MARK: - Helpers

    private let fixtures = [
        "EnvFx.pch2",
        "DelayLevel.pch2",
        "RndFilter.pch2",
        "LogicMidi.pch2",
        "ioosc.pch2",
        "SwitchSeqNote.pch2",
        "test_3osc.pch2",
        "test_all_modules_1.pch2",
        "test_all_modules_2.pch2",
        "manyOSCA.pch2",
        "simplesynth001-20240802.pch2",
    ]

    private func fixtureData(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .standardized
        return try Data(contentsOf: url)
    }

    /// Compare every field that saveAll serializes, module by module (matched by id).
    private func assertModulesEqual(_ lhs: [G2Module], _ rhs: [G2Module],
                                    area: String, file: String)
    {
        XCTAssertEqual(lhs.count, rhs.count, "\(file) [\(area)]: module count differs")
        let rhsByID = Dictionary(uniqueKeysWithValues: rhs.map { ($0.id, $0) })
        for m in lhs {
            guard let r = rhsByID[m.id] else {
                XCTFail("\(file) [\(area)]: module id \(m.id) lost in round-trip")
                continue
            }
            XCTAssertEqual(m.typeID, r.typeID, "\(file) [\(area)] id \(m.id): typeID")
            XCTAssertEqual(m.column, r.column, "\(file) [\(area)] id \(m.id): column")
            XCTAssertEqual(m.row, r.row, "\(file) [\(area)] id \(m.id): row")
            XCTAssertEqual(m.color, r.color, "\(file) [\(area)] id \(m.id): color")
            XCTAssertEqual(m.uprate, r.uprate, "\(file) [\(area)] id \(m.id): uprate")
            XCTAssertEqual(m.leds, r.leds, "\(file) [\(area)] id \(m.id): leds")
            XCTAssertEqual(m.modes, r.modes, "\(file) [\(area)] id \(m.id): modes")
            XCTAssertEqual(m.parameters, r.parameters, "\(file) [\(area)] id \(m.id): parameters")
            XCTAssertEqual(m.label, r.label, "\(file) [\(area)] id \(m.id): label")
        }
    }

    private func assertPatchEqual(_ lhs: G2Patch, _ rhs: G2Patch, file: String) {
        assertModulesEqual(lhs.voiceModules, rhs.voiceModules, area: "voice", file: file)
        assertModulesEqual(lhs.fxModules, rhs.fxModules, area: "fx", file: file)
        XCTAssertEqual(lhs.voiceCables, rhs.voiceCables, "\(file): voice cables differ")
        XCTAssertEqual(lhs.fxCables, rhs.fxCables, "\(file): fx cables differ")
    }

    private struct RawSection {
        let type: UInt8
        let areaBits: UInt8
        let body: [UInt8]
    }

    /// Rozkłada plik na surowe sekcje TLV — do porównań bajtowych niezależnych od modelu.
    private func rawSections(_ data: Data) throws -> [RawSection] {
        let bytes = [UInt8](data)
        let nullIdx = try XCTUnwrap(bytes.firstIndex(of: 0), "brak końca nagłówka")
        var offset = nullIdx + 1 + 2
        let end = bytes.count - 2 // bez CRC
        var result: [RawSection] = []
        while offset + 3 <= end {
            if bytes[offset] == 0x2D { offset += 2
                continue
            }
            let type = bytes[offset]
            let length = Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
            let start = offset + 3
            guard start + length <= end else { break }
            let body = Array(bytes[start ..< start + length])
            result.append(RawSection(type: type, areaBits: (body.first ?? 0) >> 6, body: body))
            offset = start + length
        }
        return result
    }

    /// Independent CRC-16/CCITT (poly 0x1021, seed 0) — deliberately reimplemented
    /// so the test does not trust PatchParser.calcCRC16.
    private func crc16(_ bytes: [UInt8], from: Int, length: Int) -> UInt16 {
        var crc: UInt32 = 0
        for i in from ..< (from + length) {
            crc ^= UInt32(bytes[i]) << 8
            for _ in 0 ..< 8 {
                crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1)
            }
            crc &= 0xFFFF
        }
        return UInt16(crc)
    }

    // MARK: - Round-trip: parse → saveAll → parse → compare

    func testRoundTripAllFixtures() throws {
        for name in fixtures {
            let data = try fixtureData(name)
            let original = try PatchParser.parse(data: data)
            let saved = try PatchParser.saveAll(originalData: data, patches: original)
            let reparsed = try PatchParser.parse(data: saved)

            XCTAssertEqual(original.count, reparsed.count, "\(name): patch count differs")
            for (o, r) in zip(original, reparsed) {
                assertPatchEqual(o, r, file: name)
            }
        }
    }

    // MARK: - CRC-16 written by saveAll is valid

    func testSaveAllWritesValidCRC() throws {
        for name in fixtures {
            let data = try fixtureData(name)
            let patches = try PatchParser.parse(data: data)
            let saved = try [UInt8](PatchParser.saveAll(originalData: data, patches: patches))

            guard let nullIdx = saved.firstIndex(of: 0) else {
                XCTFail("\(name): no header terminator in saved data")
                continue
            }
            let crcStart = nullIdx + 1
            let crcLen = saved.count - 2 - crcStart
            XCTAssertGreaterThan(crcLen, 0, "\(name): saved file too short")

            let expected = crc16(saved, from: crcStart, length: crcLen)
            let stored = UInt16(saved[saved.count - 2]) << 8 | UInt16(saved[saved.count - 1])
            XCTAssertEqual(stored, expected, "\(name): CRC-16 in saved file is invalid")
        }
    }

    // MARK: - Patch z uszkodzoną sumą kontrolną: otwieramy go i naprawiamy

    /// Oryginalny edytor Clavii odmawia otwarcia patcha z błędnym CRC — użytkownik
    /// zgłasza, że w ten sposób tracił patche. Nasz parser CRC **świadomie nie
    /// weryfikuje** (lepiej otworzyć uszkodzony plik niż go stracić), a `saveAll`
    /// liczy sumę od nowa. Czyli „otwórz u nas i zapisz" jest już pełną naprawą
    /// pliku uszkodzonego wyłącznie na sumie kontrolnej.
    func testFileWithBrokenCRCOpensAndSaveAllRepairsChecksum() throws {
        for name in fixtures {
            var bytes = try [UInt8](fixtureData(name))
            bytes[bytes.count - 2] ^= 0xFF // psujemy oba bajty CRC-16
            bytes[bytes.count - 1] ^= 0xFF
            let broken = Data(bytes)

            let patches = try PatchParser.parse(data: broken)
            XCTAssertFalse(patches.isEmpty, "\(name): parser nie otworzył pliku z błędnym CRC")

            let repaired = try [UInt8](PatchParser.saveAll(originalData: broken, patches: patches))
            let nullIdx = try XCTUnwrap(repaired.firstIndex(of: 0), "\(name): brak końca nagłówka")
            let crcStart = nullIdx + 1
            let crcLen = repaired.count - 2 - crcStart
            let expected = crc16(repaired, from: crcStart, length: crcLen)
            let stored = UInt16(repaired[repaired.count - 2]) << 8 | UInt16(repaired[repaired.count - 1])
            XCTAssertEqual(stored, expected, "\(name): zapis nie odtworzył poprawnego CRC")

            // …i zawartość jest ta sama, co w nieuszkodzonym oryginale.
            let fromOriginal = try PatchParser.parse(data: fixtureData(name))
            for (o, r) in try zip(fromOriginal, PatchParser.parse(data: Data(repaired))) {
                assertPatchEqual(o, r, file: "\(name) (po naprawie CRC)")
            }
        }
    }

    // MARK: - Obszar FX i sekcje spoza modelu przeżywają wczytanie i zapis

    /// Regresja znaleziona 2026-09-03 przez `PatchCheck`: klucz slotu zwijał obszar 2
    /// (Patch Settings) do 0, więc sekcja parametrów FX wypadała jako *drugie*
    /// wystąpienie tego samego klucza i trafiała do pustego slotu. Skutek: komplet
    /// parametrów obszaru FX ginął po cichu przy każdym wczytaniu pliku.
    func testFxAreaParametersAreLoaded() throws {
        var checked = 0
        for name in fixtures {
            for patch in try PatchParser.parse(data: fixtureData(name)) {
                for module in patch.fxModules {
                    guard let def = ModuleDatabase.module(id: module.typeID),
                          !def.paramNames.isEmpty else { continue }
                    XCTAssertEqual(module.parameters.count, def.paramNames.count,
                                   "\(name): moduł FX \(module.id) (\(def.shortName)) nie dostał parametrów z sekcji 0x4d")
                    // `parameters` to widok na wariację AKTYWNĄ patcha (od 2026-09-04),
                    // nie zawsze zerową — patrz `G2Patch.syncParametersToActiveVariation`.
                    XCTAssertEqual(module.parameterVariations[patch.activeVariation], module.parameters,
                                   "\(name): moduł FX \(module.id) — aktywna wariacja rozjechała się z parameters")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "żaden fixture nie ma modułów FX z parametrami — test nic nie sprawdza")
    }

    /// Ta sama regresja od strony zapisu: sekcja obszaru 2 (Patch Settings) była
    /// nadpisywana parametrami obszaru FX, czyli kasowana. Nie mamy jej w modelu,
    /// więc zapis ma ją zostawić bajt w bajt — a plik nie ma prawa się skurczyć.
    func testSaveAllPreservesSectionsOutsideTheModel() throws {
        for name in fixtures {
            let data = try fixtureData(name)
            let patches = try PatchParser.parse(data: data)
            let saved = try PatchParser.saveAll(originalData: data, patches: patches)

            XCTAssertGreaterThanOrEqual(saved.count, data.count,
                                        "\(name): plik skurczył się o \(data.count - saved.count) B — zapis coś skasował")

            let before = try rawSections(data)
            let after = try rawSections(saved)
            XCTAssertEqual(before.count, after.count, "\(name): zmieniła się liczba sekcji")
            for (o, r) in zip(before, after) {
                let tag = "0x" + String(o.type, radix: 16)
                XCTAssertEqual(o.type, r.type, "\(name): zmienił się typ/kolejność sekcji")
                XCTAssertEqual(o.areaBits, r.areaBits, "\(name): sekcja \(tag) zmieniła obszar")
                if o.areaBits > 1 {
                    XCTAssertEqual(o.body, r.body,
                                   "\(name): sekcja \(tag) obszaru \(o.areaBits) nie jest modelowana, a zapis ją zmienił")
                }
            }
        }
    }

    // MARK: - A real model change survives the round-trip

    func testModifiedPositionSurvivesRoundTrip() throws {
        let name = "simplesynth001-20240802.pch2"
        let data = try fixtureData(name)
        var patches = try PatchParser.parse(data: data)
        let module = try XCTUnwrap(patches[0].voiceModules.first, "fixture has no voice modules")

        let newColumn = module.column == 127 ? 0 : module.column + 1
        patches[0].voiceModules[0].column = newColumn

        let saved = try PatchParser.saveAll(originalData: data, patches: patches)
        let reparsed = try PatchParser.parse(data: saved)
        let found = try XCTUnwrap(
            reparsed[0].voiceModules.first(where: { $0.id == module.id }),
            "modified module lost in round-trip"
        )
        XCTAssertEqual(found.column, newColumn, "column change did not survive save→parse")
    }

    // MARK: - Kabel wejście-wejście (linkType = 0) przeżywa zapis do pliku

    /// Regresja znaleziona 2026-09-03: `G2Cable` nie miał pola kierunku, parser gubił
    /// bit `linkType`, a serializer wpisywał na sztywno 1 („wyjście→wejście"). Nord
    /// pozwala wpiąć kabel z jednego wejścia w drugie, więc taki kabel po zapisie
    /// zmieniał znaczenie i przestawał dawać się skasować.
    func testInputToInputCableSurvivesRoundTrip() throws {
        let name = "simplesynth001-20240802.pch2"
        let data = try fixtureData(name)
        var patches = try PatchParser.parse(data: data)
        let module = try XCTUnwrap(patches[0].voiceModules.first, "fixture has no voice modules")

        let inputToInput = G2Cable(fromModule: module.id, fromConnector: 0,
                                   toModule: module.id, toConnector: 1,
                                   color: .blue, area: .voice, sourceIsOutput: false)
        patches[0].add(cable: inputToInput)

        let saved = try PatchParser.saveAll(originalData: data, patches: patches)
        let reparsed = try PatchParser.parse(data: saved)

        let found = try XCTUnwrap(
            reparsed[0].voiceCables.first {
                $0.fromModule == inputToInput.fromModule &&
                    $0.fromConnector == inputToInput.fromConnector &&
                    $0.toModule == inputToInput.toModule &&
                    $0.toConnector == inputToInput.toConnector
            },
            "kabel wejście-wejście zniknął przy zapisie"
        )
        XCTAssertFalse(found.sourceIsOutput,
                       "linkType nie przeżył zapisu — kabel wejście-wejście zapisał się jako wyjście→wejście")
    }

    /// Nagłówek sekcji 0x52 to area(2) + unknown(12) + nCables(10), a nie 6 + 16, jak
    /// mieliśmy do 2026-09-03. Przy zerowym `unknown` oba podziały dają tę samą liczbę,
    /// więc błąd był niewidoczny — plik z niezerowym `unknown` psuł odczyt całego patcha.
    /// Źródła: BVerhue g2_file.pas:341 i g2_mess.pas:4805, G2-Edit protocol.c.
    func testCableListHeaderReadsCountAfterTwelveBitUnknown() throws {
        var bs = BitStream(data: [])
        try bs.writeBits(2, value: 1) // area = voice
        try bs.writeBits(12, value: 0xABC) // unknown — celowo niezerowe
        try bs.writeBits(10, value: 2) // nCables
        for (from, to, linkType) in [(3, 5, UInt32(1)), (7, 9, UInt32(0))] {
            try bs.writeBits(3, value: 0) // color
            try bs.writeBits(8, value: UInt32(from))
            try bs.writeBits(6, value: 1) // fromConnector
            try bs.writeBits(1, value: linkType)
            try bs.writeBits(8, value: UInt32(to))
            try bs.writeBits(6, value: 2) // toConnector
        }
        let body = bs.toBytes()
        let section: [UInt8] = [0x52, UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)] + body

        let patch = try PatchParser.parseUsbPatchSlot(sectionBytes: section)
        let cables = patch.voiceCables
        XCTAssertEqual(cables.count, 2,
                       "liczba kabli odczytana z niewłaściwych bitów nagłówka")
        XCTAssertTrue(cables[0].sourceIsOutput, "linkType=1 ma dać kabel wyjście→wejście")
        XCTAssertFalse(cables[1].sourceIsOutput, "linkType=0 ma dać kabel wejście-wejście")
    }
}
