// PatchSettingsTests.swift
// Sekcja 0x21 (opis patcha) i sekcja 0x4d obszaru 2 (ustawienia per wariacja):
// odczyt z pliku i trwałość zapisu. Wartości oczekiwane pochodzą z fixture'a,
// odczytanego niezależnym skryptem wg układu z g2ools (Parameters.parse_settings).

@testable import G2Core
import XCTest

final class PatchSettingsTests: XCTestCase {
    private func fixtureData(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .standardized
        return try Data(contentsOf: url)
    }

    // MARK: - Odczyt

    func testVariationSettingsAreReadFromFile() throws {
        let patch = try XCTUnwrap(PatchParser.parse(data: fixtureData("simplesynth001-20240802.pch2")).first)
        XCTAssertEqual(patch.variationSettings.count, G2Patch.runtimeVariationCount,
                       "8 wariacji użytkownika + Init z pliku, plus bufor mutatora")

        let v0 = patch.variationSettings[0]
        XCTAssertEqual(v0.patchVolume, 100)
        XCTAssertEqual(v0.activeMuted, 1)
        XCTAssertEqual(v0.glide, 0)
        XCTAssertEqual(v0.glideTime, 28)
        XCTAssertEqual(v0.bend, 1)
        XCTAssertEqual(v0.semitone, 5)
        XCTAssertEqual(v0.vibrato, 0)
        XCTAssertEqual(v0.vibratoCents, 50)
        XCTAssertEqual(v0.vibratoRate, 64)
        XCTAssertEqual(v0.arpeggiator, 0)
        XCTAssertEqual(v0.arpTime, 3)
        XCTAssertEqual(v0.arpType, 0)
        XCTAssertEqual(v0.arpOctaves, 0)
        XCTAssertEqual(v0.octaveShift, 1)
        XCTAssertEqual(v0.sustain, 1)

        // Wariacja Init różni się od wariacji 1 — dowód, że wariacje nie są sklejone.
        XCTAssertEqual(patch.variationSettings[8].semitone, 1)
        XCTAssertEqual(patch.variationSettings[8].octaveShift, 2)
    }

    // MARK: - Zapis

    func testEditedVariationSettingsSurviveSave() throws {
        let data = try fixtureData("simplesynth001-20240802.pch2")
        var patches = try PatchParser.parse(data: data)

        // Każde pole inną wartością i w dwóch różnych wariacjach — pomylone
        // przesunięcie o jedno pole albo o jedną wariację od razu wyjdzie.
        patches[0].variationSettings[0].patchVolume = 11
        patches[0].variationSettings[0].activeMuted = 0
        patches[0].variationSettings[0].glide = 1
        patches[0].variationSettings[0].glideTime = 22
        patches[0].variationSettings[0].bend = 0
        patches[0].variationSettings[0].semitone = 33
        patches[0].variationSettings[0].vibrato = 2
        patches[0].variationSettings[0].vibratoCents = 44
        patches[0].variationSettings[0].vibratoRate = 55
        patches[0].variationSettings[0].arpeggiator = 1
        patches[0].variationSettings[0].arpTime = 66
        patches[0].variationSettings[0].arpType = 2
        patches[0].variationSettings[0].arpOctaves = 3
        patches[0].variationSettings[0].octaveShift = 4
        patches[0].variationSettings[0].sustain = 0
        patches[0].variationSettings[7].patchVolume = 77
        patches[0].variationSettings[8].octaveShift = 5

        let saved = try PatchParser.saveAll(originalData: data, patches: patches)
        XCTAssertEqual(saved.count, data.count, "zapis ustawień nie ma prawa zmienić długości pliku")

        let reparsed = try XCTUnwrap(PatchParser.parse(data: saved).first)
        let v0 = reparsed.variationSettings[0]
        XCTAssertEqual(v0.patchVolume, 11)
        XCTAssertEqual(v0.activeMuted, 0)
        XCTAssertEqual(v0.glide, 1)
        XCTAssertEqual(v0.glideTime, 22)
        XCTAssertEqual(v0.bend, 0)
        XCTAssertEqual(v0.semitone, 33)
        XCTAssertEqual(v0.vibrato, 2)
        XCTAssertEqual(v0.vibratoCents, 44)
        XCTAssertEqual(v0.vibratoRate, 55)
        XCTAssertEqual(v0.arpeggiator, 1)
        XCTAssertEqual(v0.arpTime, 66)
        XCTAssertEqual(v0.arpType, 2)
        XCTAssertEqual(v0.arpOctaves, 3)
        XCTAssertEqual(v0.octaveShift, 4)
        XCTAssertEqual(v0.sustain, 0)
        XCTAssertEqual(reparsed.variationSettings[7].patchVolume, 77)
        XCTAssertEqual(reparsed.variationSettings[8].octaveShift, 5)
        // Wariacja nietknięta zostaje jak była.
        XCTAssertEqual(reparsed.variationSettings[1].glideTime, 28)
    }

    func testEditedPatchDescriptionSurvivesSave() throws {
        for name in ["simplesynth001-20240802.pch2", "test_3osc.pch2", "EnvFx.pch2"] {
            let data = try fixtureData(name)
            var patches = try PatchParser.parse(data: data)

            patches[0].description.voices = 7
            patches[0].description.monopoly = 2
            patches[0].description.category = 9
            patches[0].description.variation = 3
            patches[0].description.blueVisible = false
            patches[0].description.whiteVisible = false

            let saved = try PatchParser.saveAll(originalData: data, patches: patches)
            XCTAssertEqual(saved.count, data.count, "\(name): opis patcha zmienił długość pliku")

            let d = try XCTUnwrap(PatchParser.parse(data: saved).first).description
            XCTAssertEqual(d.voices, 7, "\(name): voices")
            XCTAssertEqual(d.monopoly, 2, "\(name): monopoly")
            XCTAssertEqual(d.category, 9, "\(name): category")
            XCTAssertEqual(d.variation, 3, "\(name): variation")
            XCTAssertFalse(d.blueVisible, "\(name): blueVisible")
            XCTAssertFalse(d.whiteVisible, "\(name): whiteVisible")
            XCTAssertTrue(d.redVisible, "\(name): redVisible nie miał się zmienić")
            XCTAssertTrue(d.greenVisible, "\(name): greenVisible nie miał się zmienić")
        }
    }

    /// Ciało sekcji `0x21` wysyłane na żywo (Patch Header Dump) — rozpisane bit po bicie.
    /// Podkładem jest 15 zer, więc każdy zapalony bit pochodzi z modelu:
    ///   bity 56–60 reserved · 61–65 voices · 66–79 height · 80–82 unk2
    ///   83–89 widoczność kolorów · 90–91 monopoly · 92–99 variation · 100–107 category
    ///   108–119 dwanaście bitów, których nie modelujemy
    func testLiveDescriptionBodyHasTheBitsOfTheFileSection() throws {
        var description = G2PatchDescription()
        description.voices = 17 // 10001
        description.height = 10
        description.monopoly = 1
        description.variation = 3
        description.category = 5 // widoczność kolorów zostaje domyślna: wszystkie włączone

        let body = try PatchParser.descriptionSectionBody(description)
        XCTAssertEqual(body, [0, 0, 0, 0, 0, 0, 0, 0x04, 0x40, 0x0A, 0x1F, 0xD0, 0x30, 0x50, 0x00])
        XCTAssertEqual(body.count, PatchParser.descriptionSectionBytes,
                       "G2-Edit `write_patch_descr` wpisuje długość 15 na sztywno")
    }

    /// Podkład zachowuje pola spoza modelu — tak samo jak zapis do pliku.
    func testLiveDescriptionBodyKeepsUnmodelledBitsOfTheOriginal() throws {
        var original = [UInt8](repeating: 0, count: 15)
        original[0] = 0x79 // 7 bajtów nieznanych danych: wariant z kolekcji (`79 fc 00 00 01 00 00`)
        original[1] = 0xFC
        original[4] = 0x01
        original[14] = 0xFF // dwanaście bitów na końcu

        let body = try PatchParser.descriptionSectionBody(G2PatchDescription(), original: original)
        XCTAssertEqual(Array(body[0 ..< 7]), [0x79, 0xFC, 0x00, 0x00, 0x01, 0x00, 0x00])
        XCTAssertEqual(body[14], 0xFF)
    }

    /// Zapis bez żadnej zmiany modelu ma zostawić obie sekcje bajt w bajt —
    /// to jest gwarancja, że nadpisywanie w miejscu nie gubi pól spoza modelu
    /// (morfy w grupie 1, `unk2`, bity wyrównania na końcu sekcji).
    func testUntouchedSettingsAndDescriptionAreByteIdentical() throws {
        for name in ["simplesynth001-20240802.pch2", "test_3osc.pch2", "manyOSCA.pch2", "EnvFx.pch2"] {
            let data = try fixtureData(name)
            let patches = try PatchParser.parse(data: data)
            let saved = try PatchParser.saveAll(originalData: data, patches: patches)

            let before = rewrittenInPlaceSections(data)
            let after = rewrittenInPlaceSections(saved)
            XCTAssertFalse(before.isEmpty, "\(name): fixture nie ma sekcji 0x21/0x4d obszaru 2")
            XCTAssertEqual(before.count, after.count, "\(name): zmieniła się liczba sekcji")
            for (o, r) in zip(before, after) {
                XCTAssertEqual(o.body, r.body,
                               "\(name): sekcja 0x\(String(o.type, radix: 16)) zmieniła się mimo braku zmian w modelu")
            }
        }
    }

    private struct RawSection {
        let type: UInt8
        let body: [UInt8]
    }

    /// Sekcje nadpisywane w miejscu: 0x21 (opis patcha) i 0x4d obszaru 2 (ustawienia).
    private func rewrittenInPlaceSections(_ data: Data) -> [RawSection] {
        let bytes = [UInt8](data)
        guard let nullIdx = bytes.firstIndex(of: 0) else { return [] }
        var offset = nullIdx + 1 + 2
        let end = bytes.count - 2 // bez CRC
        var result: [RawSection] = []
        while offset + 3 <= end {
            let type = bytes[offset]
            let length = Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
            let start = offset + 3
            guard start + length <= end else { break }
            let body = Array(bytes[start ..< start + length])
            if type == 0x21 || (type == 0x4D && (body.first ?? 0) >> 6 == 2) {
                result.append(RawSection(type: type, body: body))
            }
            offset = start + length
        }
        return result
    }
}
