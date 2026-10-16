// USBPatchTests.swift
// Testy parsera bajtów GetPatchSlot (PatchParser.parseUsbPatchSlot) i budowniczych
// sekcji wychodzących writeParamList/writeModuleNames — bez sprzętu, na fixture'ach .pch2.
// Wire format GetPatchSlot jest bajt-w-bajt identyczny z sekcjami binarnymi pliku .pch2
// (patrz reference/G2-Edit/src/usbComms.c parse_patch() vs defs.h SUB_RESPONSE_* == SectionType).

@testable import G2Core
import XCTest

final class USBPatchTests: XCTestCase {
    // MARK: - Helpers

    private let fixtures = [
        "EnvFx.pch2",
        "DelayLevel.pch2",
        "RndFilter.pch2",
        "test_3osc.pch2",
        "test_all_modules_1.pch2",
        "manyOSCA.pch2",
        "simplesynth001-20240802.pch2",
    ]

    private func fixtureBytes(_ name: String) throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .standardized
        return try [UInt8](Data(contentsOf: url))
    }

    /// Bajty binarnych sekcji pliku (to samo co odbiera GetPatchSlot) — pomija nagłówek
    /// tekstowy + \0 + 2 bajty wersji binarnej. Mirror of PatchParser's private parseTextHeader.
    private func binarySections(_ bytes: [UInt8]) throws -> [UInt8] {
        let searchRange = min(4096, bytes.count)
        let nullIdx = try XCTUnwrap(bytes[..<searchRange].firstIndex(of: 0))
        let binaryStart = nullIdx + 1 + 2
        return Array(bytes[binaryStart...])
    }

    /// Wyszukuje pierwsze wystąpienie sekcji danego typu, którego bajt obszaru (górne 2 bity
    /// danych) zgadza się z `areaRaw` (0=fx, 1=voice) — a nie po kolejności wystąpienia w pliku,
    /// bo ta bywa voice-first (patrz np. EnvFx.pch2: idx1=voice, idx2=fx dla ModuleList).
    /// Zwraca surowe bajty `[typ][długość:2B][dane]`, gotowe do wklejenia do strumienia testowego.
    private func rawSection(_ sectionBytes: [UInt8], type: UInt8, areaRaw: UInt8) -> [UInt8]? {
        var offset = 0
        while offset + 3 <= sectionBytes.count {
            let t = sectionBytes[offset]
            let length = Int(sectionBytes[offset + 1]) << 8 | Int(sectionBytes[offset + 2])
            let dataStart = offset + 3
            let dataEnd = dataStart + length
            guard dataEnd <= sectionBytes.count else { break }
            if t == type, length > 0, sectionBytes[dataStart] >> 6 == areaRaw {
                return Array(sectionBytes[offset ..< dataEnd])
            }
            offset = dataEnd
        }
        return nil
    }

    private func assertModulesEqual(_ lhs: [G2Module], _ rhs: [G2Module], area: String, file: String) {
        XCTAssertEqual(lhs.count, rhs.count, "\(file) [\(area)]: module count differs")
        let rhsByID = Dictionary(uniqueKeysWithValues: rhs.map { ($0.id, $0) })
        for m in lhs {
            guard let r = rhsByID[m.id] else {
                XCTFail("\(file) [\(area)]: module id \(m.id) missing")
                continue
            }
            XCTAssertEqual(m.typeID, r.typeID, "\(file) [\(area)] id \(m.id): typeID")
            XCTAssertEqual(m.column, r.column, "\(file) [\(area)] id \(m.id): column")
            XCTAssertEqual(m.row, r.row, "\(file) [\(area)] id \(m.id): row")
            XCTAssertEqual(m.modes, r.modes, "\(file) [\(area)] id \(m.id): modes")
            // Porównujemy WSZYSTKIE wariacje, nie sam widok `parameters`: strumienie
            // budowane w tych testach z samych writerów nie niosą sekcji opisu patcha,
            // więc po drugiej stronie aktywna wariacja jest zerowa i widok wypada inny,
            // choć dane parametrów są identyczne. Sprawdzenie pełnej tablicy jest ostrzejsze.
            XCTAssertEqual(m.parameterVariations, r.parameterVariations, "\(file) [\(area)] id \(m.id): parametry wszystkich wariacji")
            XCTAssertEqual(m.label, r.label, "\(file) [\(area)] id \(m.id): label")
        }
    }

    // MARK: - parseUsbPatchSlot matches the file parser on the identical byte stream

    func testParseUsbPatchSlotMatchesFileParseOnAllFixtures() throws {
        for name in fixtures {
            let bytes = try fixtureBytes(name)
            let sections = try binarySections(bytes)

            let viaUsb = try PatchParser.parseUsbPatchSlot(sectionBytes: sections)
            let viaFile = try XCTUnwrap(PatchParser.parse(data: Data(bytes)).first)

            assertModulesEqual(viaUsb.voiceModules, viaFile.voiceModules, area: "voice", file: name)
            assertModulesEqual(viaUsb.fxModules, viaFile.fxModules, area: "fx", file: name)
            XCTAssertEqual(viaUsb.voiceCables, viaFile.voiceCables, "\(name): voice cables differ")
            XCTAssertEqual(viaUsb.fxCables, viaFile.fxCables, "\(name): fx cables differ")
        }
    }

    // MARK: - writeModuleList / writeCableList / writeParamList / writeModuleNames — header framing

    func testWriteModuleListHeaderMatchesBodyLength() throws {
        let patch = try XCTUnwrap(try PatchParser.parse(data: Data(fixtureBytes("simplesynth001-20240802.pch2"))).first)
        let section = try PatchParser.writeModuleList(modules: patch.voiceModules, area: .voice)

        XCTAssertEqual(section[0], 0x4A, "type byte should be ModuleList (0x4a)")
        let length = Int(section[1]) << 8 | Int(section[2])
        XCTAssertEqual(length, section.count - 3, "declared length must match body size")
    }

    func testWriteCableListHeaderMatchesBodyLength() throws {
        let patch = try XCTUnwrap(try PatchParser.parse(data: Data(fixtureBytes("simplesynth001-20240802.pch2"))).first)
        let section = try PatchParser.writeCableList(cables: patch.voiceCables, area: .voice)

        XCTAssertEqual(section[0], 0x52, "type byte should be CableList (0x52)")
        let length = Int(section[1]) << 8 | Int(section[2])
        XCTAssertEqual(length, section.count - 3, "declared length must match body size")
    }

    func testWriteParamListHeaderMatchesBodyLength() throws {
        let patch = try XCTUnwrap(try PatchParser.parse(data: Data(fixtureBytes("simplesynth001-20240802.pch2"))).first)
        let section = try PatchParser.writeParamList(modules: patch.voiceModules, area: .voice)

        XCTAssertEqual(section[0], 0x4D, "type byte should be Parameters (0x4d)")
        let length = Int(section[1]) << 8 | Int(section[2])
        XCTAssertEqual(length, section.count - 3, "declared length must match body size")
    }

    func testWriteModuleNamesHeaderMatchesBodyLength() throws {
        let patch = try XCTUnwrap(try PatchParser.parse(data: Data(fixtureBytes("simplesynth001-20240802.pch2"))).first)
        let section = try PatchParser.writeModuleNames(modules: patch.voiceModules, area: .voice)

        XCTAssertEqual(section[0], 0x5A, "type byte should be ModuleNames (0x5a)")
        let length = Int(section[1]) << 8 | Int(section[2])
        XCTAssertEqual(length, section.count - 3, "declared length must match body size")
    }

    // MARK: - writeParamList / writeModuleNames round-trip through parseUsbPatchSlot

    /// Builds a synthetic GetPatchSlot-shaped stream: real ModuleList sections straight from
    /// the fixture, followed by our own writeParamList/writeModuleNames output, then re-parses
    /// it — proving the two writers interoperate with the USB read path (parseUsbPatchSlot).
    /// Only exercises an area when the fixture actually has modules there *and* a ModuleList
    /// section for it — some single-area test fixtures (e.g. FX-only) omit the empty side.
    func testWriteParamListAndModuleNamesRoundTripThroughParseUsbPatchSlot() throws {
        for name in fixtures {
            let bytes = try fixtureBytes(name)
            let sections = try binarySections(bytes)
            let original = try XCTUnwrap(PatchParser.parse(data: Data(bytes)).first)

            let candidates: [(area: PatchArea, areaRaw: UInt8)] = [(.fx, 0), (.voice, 1)]
            let testableAreas = candidates.compactMap { candidate -> (area: PatchArea, raw: [UInt8])? in
                guard !original.modules(in: candidate.area).isEmpty,
                      let raw = rawSection(sections, type: 0x4A, areaRaw: candidate.areaRaw)
                else { return nil }
                return (candidate.area, raw)
            }
            guard !testableAreas.isEmpty else { continue }

            var stream: [UInt8] = testableAreas.flatMap(\.raw)
            for (area, _) in testableAreas {
                stream += try PatchParser.writeParamList(modules: original.modules(in: area), area: area)
            }
            for (area, _) in testableAreas {
                stream += try PatchParser.writeModuleNames(modules: original.modules(in: area), area: area)
            }

            let rebuilt = try PatchParser.parseUsbPatchSlot(sectionBytes: stream)

            for (area, _) in testableAreas {
                assertModulesEqual(rebuilt.modules(in: area), original.modules(in: area),
                                   area: "\(area)", file: name)
            }
        }
    }

    // MARK: - Full section stream (writeModuleList+writeCableList+writeParamList+writeModuleNames)

    /// Unlike the test above (real ModuleList bytes from the fixture + our param/name writers),
    /// this builds an *entire* GetPatchSlot-shaped stream purely from our own four writers —
    /// no bytes copied from the file. Proves the four writers are internally consistent with
    /// each other and with `parseUsbPatchSlot`, independent of what the real device would
    /// actually accept for `SUB_COMMAND_SET` (that part is unverified — see
    /// `G2UsbProtocol.setPatchPayload`).
    func testFullSectionStreamFromOwnWritersRoundTripsThroughParseUsbPatchSlot() throws {
        for name in fixtures {
            let bytes = try fixtureBytes(name)
            let original = try XCTUnwrap(PatchParser.parse(data: Data(bytes)).first)

            let areas: [PatchArea] = [.fx, .voice].filter { !original.modules(in: $0).isEmpty }
            guard !areas.isEmpty else { continue }

            var stream: [UInt8] = []
            for area in areas {
                stream += try PatchParser.writeModuleList(modules: original.modules(in: area), area: area)
                stream += try PatchParser.writeCableList(cables: original.cables(in: area), area: area)
                stream += try PatchParser.writeParamList(modules: original.modules(in: area), area: area)
                stream += try PatchParser.writeModuleNames(modules: original.modules(in: area), area: area)
            }

            let rebuilt = try PatchParser.parseUsbPatchSlot(sectionBytes: stream)

            for area in areas {
                assertModulesEqual(rebuilt.modules(in: area), original.modules(in: area),
                                   area: "\(area)", file: name)
                XCTAssertEqual(rebuilt.cables(in: area), original.cables(in: area),
                               "\(name) [\(area)]: cables differ")
            }
        }
    }

    // MARK: - slotSectionStream — treść komendy 0x37 (cały patch jedną wysyłką)

    /// Oryginał wysyła do slotu binarną część pliku bez dwóch bajtów wersji/typu i bez
    /// końcowego CRC (`CPatch::FileToBubble`; `g2ools/g2ctl.py cmd_loadslot` robi
    /// `data[3:-2]`). Dla `.pch2` `slotSectionStream` musi dać dokładnie to.
    func testSlotSectionStreamMatchesFileBodyWithoutCRC() throws {
        for name in fixtures {
            let bytes = try fixtureBytes(name)
            let expected = try Array(binarySections(bytes).dropLast(2))
            let stream = try PatchParser.slotSectionStream(fileData: Data(bytes), slot: 0)
            XCTAssertEqual(stream, expected, "\(name): strumień sekcji ≠ treść pliku bez CRC")
            XCTAssertEqual(stream.first, 0x21, "\(name): strumień musi zaczynać się sekcją 0x21")
        }
    }

    /// Strumień, który wysyłamy, urządzenie czyta tym samym parserem, co odpowiedź na
    /// `GetPatchSlot` — więc musi się rozczytać z powrotem do tego samego patcha.
    func testSlotSectionStreamReparsesToTheSamePatch() throws {
        for name in fixtures {
            let bytes = try fixtureBytes(name)
            let original = try XCTUnwrap(PatchParser.parse(data: Data(bytes)).first)
            let stream = try PatchParser.slotSectionStream(fileData: Data(bytes), slot: 0)
            let rebuilt = try PatchParser.parseUsbPatchSlot(sectionBytes: stream)

            for area in [PatchArea.fx, .voice] {
                assertModulesEqual(rebuilt.modules(in: area), original.modules(in: area),
                                   area: "\(area)", file: name)
                XCTAssertEqual(rebuilt.cables(in: area), original.cables(in: area),
                               "\(name) [\(area)]: cables differ")
            }
        }
    }

    /// Szkielet pustego patcha musi być pusty — wgrywa się nim New Patch, a wszystko, co
    /// w nim zostanie (moduł, kabel, przypisana gałka), wjechałoby do Norda.
    func testEmptyPatchFileIsActuallyEmpty() throws {
        let patch = try XCTUnwrap(PatchParser.parse(data: PatchParser.emptyPatchFile).first)
        XCTAssertTrue(patch.voiceModules.isEmpty)
        XCTAssertTrue(patch.fxModules.isEmpty)
        XCTAssertTrue(patch.voiceCables.isEmpty)
        XCTAssertTrue(patch.fxCables.isEmpty)
    }

    /// New Performance buduje CZTERY strumienie, po jednym na slot, i każdy powstaje na tym
    /// samym szkielecie — to ten sam kod, co dla jednego slotu, ale wykonany w pętli, więc
    /// pilnujemy, żeby żaden slot nie wyszedł pusty ani inny od pozostałych. Numer slotu
    /// nie jest częścią strumienia (niesie go nagłówek komendy), stąd cztery identyczne.
    func testFourEmptySlotsBuildFourIdenticalStreams() throws {
        let streams = try (0 ..< 4).map { _ -> [UInt8] in
            let file = try PatchParser.saveAll(originalData: PatchParser.emptyPatchFile,
                                               patches: [G2Patch()])
            return try PatchParser.slotSectionStream(fileData: file, slot: 0)
        }
        XCTAssertEqual(streams.count, 4)
        for (index, stream) in streams.enumerated() {
            XCTAssertFalse(stream.isEmpty, "slot \(index): pusty strumień")
            XCTAssertEqual(stream, streams[0], "slot \(index): strumień różny od slotu A")
            let patch = try PatchParser.parseUsbPatchSlot(sectionBytes: stream)
            XCTAssertTrue(patch.voiceModules.isEmpty && patch.fxModules.isEmpty,
                          "slot \(index): w pustym slocie zostały moduły")
            XCTAssertTrue(patch.voiceCables.isEmpty && patch.fxCables.isEmpty,
                          "slot \(index): w pustym slocie zostały kable")
        }
    }

    /// Patch bez pliku źródłowego (nowy, wczytany z Norda) też musi dać strumień 0x37 —
    /// inaczej wysyłka wraca do molekuł i kasuje slot moduł po module, po ~290 ms na sztukę.
    func testSectionStreamCanBeBuiltWithoutASourceFile() throws {
        for name in fixtures {
            let original = try XCTUnwrap(try PatchParser.parse(data: Data(fixtureBytes(name))).first)
            let file = try PatchParser.saveAll(originalData: PatchParser.emptyPatchFile,
                                               patches: [original])
            let stream = try PatchParser.slotSectionStream(fileData: file, slot: 0)
            XCTAssertFalse(stream.isEmpty, "\(name): pusty strumień sekcji")
            let rebuilt = try PatchParser.parseUsbPatchSlot(sectionBytes: stream)

            for area in [PatchArea.fx, .voice] {
                assertModulesEqual(rebuilt.modules(in: area), original.modules(in: area),
                                   area: "\(area)", file: name)
                XCTAssertEqual(rebuilt.cables(in: area), original.cables(in: area),
                               "\(name) [\(area)]: cables differ")
            }
        }
    }

    /// Slot spoza pliku (np. slot B w `.pch2`) daje pusty strumień, nie bajty slotu A —
    /// bez tego wysyłka performance'u z pliku jednopatchowego wgrałaby ten sam patch
    /// do czterech slotów.
    func testSlotSectionStreamOfMissingSlotIsEmpty() throws {
        let bytes = try fixtureBytes("EnvFx.pch2")
        XCTAssertTrue(try PatchParser.slotSectionStream(fileData: Data(bytes), slot: 1).isEmpty)
    }

    /// Układ `.prf2`: sekcja 0x11 (ustawienia performance'u), potem po jednym bloku na slot
    /// zaczynającym się sekcją 0x21, na końcu 0x5f (mapa gałek performance'u). Do slotu
    /// należy tylko jego blok — 0x11 i 0x5f nie należą do żadnego.
    func testSlotSectionStreamSplitsPerformanceBlocksOnPatchDescription() throws {
        func section(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
            [type, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
        }
        let slotA = section(0x21, [0x0A]) + section(0x4A, [0x0B]) + section(0x6F, [])
        let slotB = section(0x21, [0x0C]) + section(0x4A, [0x0D]) + section(0x6F, [])
        let body = section(0x11, [0x01]) + slotA + slotB + section(0x5F, [0x02])
        let file = Data(Array("Version=Nord Modular G2 File Format 1\r\n".utf8)
            + [0x00, 0x17, 0x01] + body + [0xDE, 0xAD])

        XCTAssertEqual(try PatchParser.slotSectionStream(fileData: file, slot: 0), slotA)
        XCTAssertEqual(try PatchParser.slotSectionStream(fileData: file, slot: 1), slotB)
        XCTAssertTrue(try PatchParser.slotSectionStream(fileData: file, slot: 2).isEmpty)
    }

    // MARK: - Zrzut odsłuchu Mutatora (0x4D ×3 + 0x65, jeden zestaw)

    /// Sekcje w kolejności molekuły oryginału, każda z własnym nagłówkiem i **jednym**
    /// zestawem parametrów o numerze 9 — Muta Param Dump (WriteStream)
    /// (`+0x08` obszar 2, `+0x4C` Voice, `+0x90` FX, `+0xD4` mapa morfów)
    /// → [[Docs/usb/mutator-dump]].
    func testMutatorParamDumpHasFourSectionsWithOneParameterSet() throws {
        let patch = try mutatorFixture()
        let dump = try PatchParser.writeMutatorParamDump(patch, variation: G2Patch.mutatorVariation)
        let sections = try splitSections(dump)

        XCTAssertEqual(sections.map(\.type), [0x4D, 0x4D, 0x4D, 0x65])
        for section in sections {
            XCTAssertEqual(section.declaredLength, section.body.count,
                           "sekcja \(String(section.type, radix: 16)) kłamie o długości")
        }

        // Obszary: 2 (ustawienia patcha), 1 (Voice), 0 (FX) — w tej kolejności.
        for (section, area) in zip(sections.prefix(3), [2, 1, 0] as [UInt32]) {
            var bs = BitStream(data: section.body)
            XCTAssertEqual(try bs.readBits(2), area)
            _ = try bs.readBits(8) // liczba modułów/grup
            XCTAssertEqual(try bs.readBits(8), 1, "jeden zestaw, nie dziewięć")
        }
    }

    /// Wartości w zrzucie to wartości bufora, pod numerem zestawu 9 — a nie pod 0,
    /// jak w pliku. Sprawdzone na obu obszarach, moduł po module.
    func testMutatorParamDumpCarriesTheBufferValuesUnderSetNine() throws {
        let patch = try mutatorFixture()
        let buffer = G2Patch.mutatorVariation
        let sections = try splitSections(PatchParser.writeMutatorParamDump(patch, variation: buffer))

        for (index, area) in [(1, PatchArea.voice), (2, PatchArea.fx)] {
            var bs = BitStream(data: sections[index].body)
            _ = try bs.readBits(2)
            let moduleCount = try Int(bs.readBits(8))
            _ = try bs.readBits(8)
            let expected = patch.modules(in: area)
                .filter { $0.hasParameterEntry || !$0.parameters.isEmpty }
                .sorted { $0.id < $1.id }
            XCTAssertEqual(moduleCount, expected.count, "\(area)")
            for module in expected {
                XCTAssertEqual(try Int(bs.readBits(8)), module.id)
                let paramCount = try Int(bs.readBits(7))
                XCTAssertEqual(paramCount, module.parameters.count)
                XCTAssertEqual(try Int(bs.readBits(8)), buffer, "numer zestawu")
                for index in 0 ..< paramCount {
                    XCTAssertEqual(try Int(bs.readBits(7)), module.parameterVariations[buffer][index],
                                   "moduł \(module.id) parametr \(index)")
                }
            }
        }
    }

    /// Obszar 2: siedem grup w kolejności zapisu, wpisy 16/2/2/2/3/4/2, wartości
    /// z `variationSettings[9]` — ten sam układ, co czyta `parseSettings`.
    func testMutatorParamDumpCarriesThePatchSettings() throws {
        let patch = try mutatorFixture()
        let buffer = G2Patch.mutatorVariation
        let settings = patch.variationSettings[buffer]
        var bs = try BitStream(data: splitSections(
            PatchParser.writeMutatorParamDump(patch, variation: buffer)
        )[0].body)

        XCTAssertEqual(try bs.readBits(2), 2)
        XCTAssertEqual(try bs.readBits(8), 7, "siedem grup")
        XCTAssertEqual(try bs.readBits(8), 1)

        var entryCounts: [Int] = []
        var glide: Int?
        for _ in 0 ..< 7 {
            let group = try Int(bs.readBits(8))
            let entries = try Int(bs.readBits(7))
            entryCounts.append(entries)
            XCTAssertEqual(try Int(bs.readBits(8)), buffer, "numer zestawu w grupie \(group)")
            for entry in 0 ..< entries {
                let value = try Int(bs.readBits(7))
                if group == 1, entry < G2Morph.count {
                    XCTAssertEqual(value, settings.morphDials[entry], "gałka morfu \(entry)")
                }
                if group == G2PatchSetting.glideTime.module, entry == G2PatchSetting.glideTime.param {
                    glide = value
                }
            }
        }
        XCTAssertEqual(entryCounts, [16, 2, 2, 2, 3, 4, 2])
        XCTAssertEqual(glide, settings.glideTime)
    }

    /// Sekcja 0x65 z jednym zestawem: numer zestawu zajmuje pełne 8 bitów, potem
    /// 56 bitów zer i przypisania bufora.
    func testMutatorParamDumpCarriesTheMorphAssignments() throws {
        let patch = try mutatorFixture()
        let buffer = G2Patch.mutatorVariation
        let entries = patch.morphs(in: buffer)
        XCTAssertFalse(entries.isEmpty, "fixture ma mieć czym testować")

        var bs = try BitStream(data: splitSections(
            PatchParser.writeMutatorParamDump(patch, variation: buffer)
        )[3].body)
        XCTAssertEqual(try bs.readBits(8), 1, "jeden zestaw")
        XCTAssertEqual(try bs.readBits(4), UInt32(G2Morph.count))
        XCTAssertEqual(try bs.readBits(16), 0, "tryby ośmiu morfów")
        XCTAssertEqual(try Int(bs.readBits(8)), buffer, "numer zestawu")
        bs.skip(56)
        XCTAssertEqual(try Int(bs.readBits(8)), entries.count)
        for entry in entries {
            XCTAssertEqual(try Int(bs.readBits(2)), Int(entry.location))
            XCTAssertEqual(try Int(bs.readBits(8)), entry.moduleID)
            XCTAssertEqual(try Int(bs.readBits(7)), entry.paramIndex)
            XCTAssertEqual(try Int(bs.readBits(4)), entry.morph)
            let raw = try Int(bs.readBits(8))
            XCTAssertEqual(raw > 127 ? raw - 256 : raw, entry.range)
        }
    }

    /// Patch z wypełnionym buforem odsłuchu: inne wartości niż wariacja 0, własne
    /// ustawienia obszaru 2 i własny morf.
    private func mutatorFixture() throws -> G2Patch {
        var patch = try XCTUnwrap(PatchParser.parse(data: Data(fixtureBytes("test_3osc.pch2"))).first)
        patch.ensureRuntimeVariations()
        let buffer = G2Patch.mutatorVariation
        let module = try XCTUnwrap(patch.voiceModules.first { $0.parameters.count > 1 })
        patch.setParameter(moduleID: module.id, paramIndex: 1, value: 77, in: .voice, variation: buffer)
        patch.variationSettings[buffer].glideTime = 42
        patch.variationSettings[buffer].morphDials[3] = 99
        patch.setMorphRange(variation: buffer, location: 1, moduleID: module.id,
                            paramIndex: 0, morph: 3, range: -25)
        return patch
    }

    private struct RawSection {
        var type: UInt8
        var declaredLength: Int
        var body: [UInt8]
    }

    // MARK: - Morfy i dane modułów z urządzenia (Download Banks, 2026-10-14)

    /// Sekcja `0x65` patcha BackTo72 (Patch Bank 1:2) tak, jak oddał ją Nord na `0x3C`
    /// i na `0x66`: **dziesięć** wariacji, plik ma dziewięć. Parser odrzucał całą sekcję,
    /// więc patch z urządzenia nie miał ani jednego przypisania morfu.
    func testMorphMapFromTheG2WithTenVariationsIsKept() throws {
        let hex = Array(Self.nordBackTo72MorphPayload.utf8)
        let payload = stride(from: 0, to: hex.count, by: 2).compactMap {
            UInt8(String(decoding: hex[$0 ..< $0 + 2], as: UTF8.self), radix: 16)
        }
        XCTAssertEqual(payload.count, 2 + 0x129)
        let patch = try PatchParser.parseUsbPatchSlot(sectionBytes: [0x65] + payload)

        for variation in 0 ..< 8 {
            XCTAssertEqual(patch.morphs(in: variation).count, 7, "wariacja \(variation + 1)")
        }
        XCTAssertEqual(patch.morphs(in: 8).count, 0)
    }

    /// Dane modułów (`0x5B`, trzy sekcje: obszar 2, Voice, FX) nie są modelowane. Zapis
    /// na pustym szkielecie — droga patcha bez pliku źródłowego, czyli każdej kopii
    /// z Norda — ma je oddać bajt w bajt, a nie zostawić puste sekcje szkieletu.
    func testModuleCustomDataSurvivesSaveOnTheEmptySkeleton() throws {
        for name in ["SwitchSeqNote.pch2", "simplesynth001-20240802.pch2", "LogicMidi.pch2"] {
            let original = try Data(fixtureBytes(name))
            let patch = try XCTUnwrap(PatchParser.parse(data: original).first)
            let saved = try PatchParser.saveAll(originalData: PatchParser.emptyPatchFile, patches: [patch])

            let customData: (Data) throws -> [[UInt8]] = { data in
                try self.splitSections(PatchParser.slotSectionStream(fileData: data, slot: 0))
                    .filter { $0.type == 0x5B }.map(\.body)
            }
            XCTAssertEqual(try customData(saved), try customData(original), name)
        }
    }

    /// Pusta sekcja parametrów z Norda ma licznik 10 wariacji (zmierzone 2026-10-14,
    /// skipsandtimesseq z Patch Bank 13). Plik Clavii ma tam 0 albo 9 — zapis nie wychodzi poza 9.
    func testEmptyParameterSectionFromTheG2IsSavedWithNineVariations() throws {
        var patch = G2Patch()
        patch.parameterVariationCount[.fx] = 10
        let saved = try PatchParser.saveAll(originalData: PatchParser.emptyPatchFile, patches: [patch])

        let fxParameters = try XCTUnwrap(
            splitSections(PatchParser.slotSectionStream(fileData: saved, slot: 0))
                .first { $0.type == 0x4D && $0.body.first.map { $0 >> 6 } == 0 }
        )
        let variationCount = (Int(fxParameters.body[1]) << 2 | Int(fxParameters.body[2]) >> 6) & 0xFF
        XCTAssertEqual(variationCount, 9)
    }

    private static let nordBackTo72MorphPayload = """
    01290a80000000000000000000007404198a204000c50208ec283817314280890218004c1130061e0200000000\
    0000000e80833144080018a0411d850702e628501120430009822600c3c08000000000000001d0106628810003\
    140823b0a0e05cc50a02240860013044c0187818000000000000003a020cc510200062810476141c0b98a14044\
    810c00260898030f040000000000000007404198a204000c50208ec283817314280890218004c1130061e0a000\
    000000000000e80833144080018a0411d850702e628501120430009822600c3c18000000000000001d01066288\
    10003140823b0a0e05cc50a02240860013044c0187838000000000000003a020cc510200062810476141c0b98a\
    14044810c00260898030f0800000000000000000900000000000000001
    """

    private func splitSections(_ bytes: [UInt8]) throws -> [RawSection] {
        var sections: [RawSection] = []
        var offset = 0
        while offset + 3 <= bytes.count {
            let length = Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
            let end = offset + 3 + length
            guard end <= bytes.count else {
                XCTFail("sekcja wystaje poza strumień")
                break
            }
            sections.append(RawSection(type: bytes[offset], declaredLength: length,
                                       body: Array(bytes[(offset + 3) ..< end])))
            offset = end
        }
        XCTAssertEqual(offset, bytes.count, "strumień ma zostać wyczerpany co do bajtu")
        return sections
    }
}
