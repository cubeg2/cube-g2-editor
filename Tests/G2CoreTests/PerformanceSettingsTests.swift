// PerformanceSettingsTests.swift
// Sekcja 0x11 (.prf2): odczyt ustawień performance'u i zapis w miejscu.
// Testy budują plik od zera, więc nie zależą od żadnego cudzego performance'u.
// Układ sekcji → Docs/parser/sections.md „0x11 — PerformanceDescription".

@testable import G2Core
import XCTest

final class PerformanceSettingsTests: XCTestCase {
    private let header = Array("Version=Nord Modular G2 File Format 1\r\nType=Performance\r\n".utf8)
        + [0, 23, 1] as [UInt8]

    /// Nieznane pola dostają celowo niezerowe wartości — zapis ma je zostawić bajt w bajt.
    /// Nazwy slotów obejmują trzy przypadki: zwykłą, pustą i pełne 16 znaków (bez terminatora).
    private let slotNames = ["leo1", "", "SixteenCharsABCD", "Anthem"]

    private func performanceSection() -> [UInt8] {
        var body: [UInt8] = [
            0x5A, // unk1
            0xA9, // unk2 = 0xA, focus = 2, Global Pages = 1
            0x01, // keyboard range enabled
            138, // bpm
            0x33, // split (unk6 u BVerhue)
            0x01, // clock running
            0x44, // unk4
            0x55, // unk5
        ]
        for (index, name) in slotNames.enumerated() {
            body += Array(name.utf8)
            if name.count < 16 {
                body.append(0)
            }
            body += [
                index == 0 ? 1 : 0, // enabled
                index == 1 ? 1 : 0, // keyboard
                index == 2 ? 1 : 0, // hold
                UInt8(index), // bank
                UInt8(index * 3), // patch
                UInt8(index * 8), // key range low
                UInt8(120 + index), // key range high
                UInt8(index), // unk3 — na sprzęcie bywa numerem slotu
                0x66, // unk4
                0x77, // unk5
            ]
        }
        return [0x11, UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)] + body
    }

    private func moduleSection(slot: Int) throws -> [UInt8] {
        let module = G2Module(id: 10 * (slot + 1), typeID: 4, area: .voice)
        return try PatchParser.writeModuleList(modules: [module], area: .voice)
    }

    private func performanceFile() throws -> Data {
        var bytes = header + performanceSection()
        for slot in 0 ..< 4 {
            bytes += try moduleSection(slot: slot)
        }
        return Data(bytes + [0, 0]) // CRC — parse go nie weryfikuje
    }

    private func globalKnobSection() throws -> [UInt8] {
        var bits = BitStream(data: [])
        try bits.writeBits(16, value: 120)
        for index in 0 ..< 120 {
            let assigned = index == 9
            try bits.writeBits(1, value: assigned ? 1 : 0)
            if assigned {
                try bits.writeBits(2, value: 1) // Voice
                try bits.writeBits(8, value: 30) // module
                try bits.writeBits(2, value: 2) // isLed
                try bits.writeBits(7, value: 4) // parameter
                try bits.writeBits(2, value: 2) // slot C
            }
        }
        let body = bits.toBytes()
        return [0x5F, UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)] + body
    }

    private func performanceFileWithGlobalKnobs() throws -> Data {
        var bytes = try Array(performanceFile().dropLast(2))
        bytes += try globalKnobSection()
        return Data(bytes + [0, 0])
    }

    // MARK: - Cały performance jedną komendą (0x1A)

    /// Bloki slotów rozdziela w pliku sekcja `0x21` — bez niej `slotSectionStream` nie ma
    /// po czym liczyć wystąpień, więc plik dla tego testu ma po jednej na slot.
    private func patchDescriptionSection() -> [UInt8] {
        let body: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0x42, 0x32, 0x5F, 0xD0, 0, 0, 0, 0]
        return [0x21, UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)] + body
    }

    private func performanceFileWithPatchBlocks() throws -> Data {
        var bytes = header + performanceSection()
        for slot in 0 ..< 4 {
            bytes += try patchDescriptionSection() + moduleSection(slot: slot)
        }
        bytes += try globalKnobSection()
        return Data(bytes + [0, 0])
    }

    /// Complete Performance Dump ma nieść plik i nic poza plikiem. Test składa komunikat
    /// z tych samych kawałków, co wysyłka, i porównuje jego ogon **bajt w bajt** z całym
    /// obszarem sekcji `.prf2` — nagłówek `0x11`, cztery bloki slotów, mapa gałek `0x5F`.
    /// Gdyby któryś kawałek wypadł, przesunął się albo powtórzył, ta równość pęka.
    func testCompletePerformanceDumpCarriesTheWholeFileByteForByte() throws {
        let data = try performanceFileWithPatchBlocks()
        let payload = try G2UsbProtocol.completePerformanceDumpPayload(
            name: "Anthem",
            headerSection: PatchParser.performanceSectionStream(fileData: data),
            slotStreams: (0 ..< 4).map { try PatchParser.slotSectionStream(fileData: data, slot: $0) },
            knobMapSection: PatchParser.performanceKnobMapStream(fileData: data)
        )

        // Nagłówek ramki + molekuła „dokąd to trafia" + numer zrzutu + nazwa.
        let name: [UInt8] = Array("Anthem".utf8) + [0]
        let prefix: [UInt8] = [0x01, 0x2C, 0x41, 0x37, 0x00, 0x00, 0x00] + name
            + [0x1A, 0x29] + name
        XCTAssertEqual(Array(payload.prefix(prefix.count)), prefix)

        // Ogon to obszar sekcji pliku: od pierwszej sekcji do CRC.
        let bytes = [UInt8](data)
        let sectionsStart = header.count
        let fileSections = Array(bytes[sectionsStart ..< (bytes.count - 2)])
        XCTAssertEqual(Array(payload.dropFirst(prefix.count)), fileSections)
    }

    /// Bez ani jednej globalnej gałki sekcji `0x5F` w pliku nie ma — i zrzut też jej mieć
    /// nie może, bo doklejenie pustej byłoby wymyślaniem bajtów.
    func testCompletePerformanceDumpHasNoKnobMapWhenTheFileHasNone() throws {
        let data = try performanceFile()
        XCTAssertTrue(try PatchParser.performanceKnobMapStream(fileData: data).isEmpty)
    }

    // MARK: - Odczyt

    func testReadsPerformanceWideSettings() throws {
        let performance = try XCTUnwrap(PatchParser.parseFile(data: performanceFile()).performance)
        XCTAssertEqual(performance.masterClock, 138)
        XCTAssertTrue(performance.masterClockRunning)
        XCTAssertTrue(performance.keyboardRangeEnabled)
        XCTAssertEqual(performance.focusedSlot, 2, "focus to 2 bity w drugim bajcie sekcji")
        XCTAssertTrue(performance.globalPagesEnabled, "Global Pages to dwa najmłodsze bity")
    }

    /// `Global Pages` siedzi w tym samym bajcie co focus — zapis jednego nie może
    /// zjeść drugiego ani czterech starszych bitów, których nikt nie rozpoznał.
    func testGlobalPagesButtonSurvivesSaveNextToTheFocusSlot() throws {
        let data = try performanceFile()
        var performance = try XCTUnwrap(PatchParser.parseFile(data: data).performance)
        performance.globalPagesEnabled = false
        performance.focusedSlot = 1

        let saved = try PatchParser.saveAll(originalData: data,
                                            patches: PatchParser.parse(data: data),
                                            performance: performance)
        let reloaded = try XCTUnwrap(PatchParser.parseFile(data: saved).performance)
        XCTAssertFalse(reloaded.globalPagesEnabled)
        XCTAssertEqual(reloaded.focusedSlot, 1)
        XCTAssertEqual(saved[header.count + 3 + 1], 0xA4, "unk2 = 0xA, focus = 1, Global Pages = 0")
    }

    func testReadsAllFourSlots() throws {
        let performance = try XCTUnwrap(PatchParser.parseFile(data: performanceFile()).performance)
        XCTAssertEqual(performance.slots.map(\.name), slotNames)
        XCTAssertEqual(performance.slots.map(\.enabled), [true, false, false, false])
        XCTAssertEqual(performance.slots.map(\.keyboard), [false, true, false, false])
        XCTAssertEqual(performance.slots.map(\.hold), [false, false, true, false])
        XCTAssertEqual(performance.slots.map(\.bank), [0, 1, 2, 3])
        XCTAssertEqual(performance.slots.map(\.patch), [0, 3, 6, 9])
        XCTAssertEqual(performance.slots.map(\.keyRangeLow), [0, 8, 16, 24])
        XCTAssertEqual(performance.slots.map(\.keyRangeHigh), [120, 121, 122, 123])
    }

    func testSlotNamesReachThePatches() throws {
        // Nazwy patchy w .prf2 leżą wyłącznie w sekcji 0x11 — nigdzie indziej w pliku.
        let patches = try PatchParser.parse(data: performanceFile())
        XCTAssertEqual(patches.map(\.name), slotNames)
    }

    func testPatchFileHasNoPerformanceSettings() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/simplesynth001-20240802.pch2")
            .standardized
        XCTAssertNil(try PatchParser.parseFile(data: Data(contentsOf: url)).performance)
    }

    func testReadsPerformanceWideGlobalKnobAssignments() throws {
        let performance = try XCTUnwrap(
            PatchParser.parseFile(data: performanceFileWithGlobalKnobs()).performance
        )
        let assignment = try XCTUnwrap(performance.globalKnobAssignments[9])

        XCTAssertEqual(assignment.slot, 2)
        XCTAssertEqual(assignment.location, 1)
        XCTAssertEqual(assignment.moduleID, 30)
        XCTAssertEqual(assignment.paramIndex, 4)
        XCTAssertEqual(assignment.isLed, 2)
        XCTAssertEqual(performance.globalKnobAssignments.compactMap(\.self).count, 1)
    }

    // MARK: - Zapis

    func testSavedSettingsSurviveReload() throws {
        let data = try performanceFile()
        var performance = try XCTUnwrap(PatchParser.parseFile(data: data).performance)
        performance.masterClock = 90
        performance.masterClockRunning = false
        performance.keyboardRangeEnabled = false
        performance.slots[3].enabled = true
        performance.slots[3].keyRangeLow = 36
        performance.slots[3].keyRangeHigh = 96

        let saved = try PatchParser.saveAll(originalData: data,
                                            patches: PatchParser.parse(data: data),
                                            performance: performance)
        let reloaded = try XCTUnwrap(PatchParser.parseFile(data: saved).performance)

        XCTAssertEqual(reloaded.masterClock, 90)
        XCTAssertFalse(reloaded.masterClockRunning)
        XCTAssertFalse(reloaded.keyboardRangeEnabled)
        XCTAssertTrue(reloaded.slots[3].enabled)
        XCTAssertEqual(reloaded.slots[3].keyRangeLow, 36)
        XCTAssertEqual(reloaded.slots[3].keyRangeHigh, 96)
        XCTAssertEqual(reloaded.slots.map(\.name), slotNames, "nazwy slotów nie mogą się ruszyć")
    }

    /// Zapis nadpisuje sekcję w miejscu, więc plik bez zmian musi wyjść bajt w bajt —
    /// razem z pięcioma nieznanymi polami nagłówka i trzema w każdym slocie.
    func testUnchangedPerformanceIsRewrittenByteForByte() throws {
        let data = try performanceFile()
        let parsed = try PatchParser.parseFile(data: data)
        let saved = try PatchParser.saveAll(originalData: data,
                                            patches: parsed.patches,
                                            performance: parsed.performance)
        XCTAssertEqual(Array(saved.prefix(header.count + performanceSection().count)),
                       Array(data.prefix(header.count + performanceSection().count)))
    }

    func testSaveWithoutPerformanceLeavesTheSectionAlone() throws {
        let data = try performanceFile()
        let saved = try PatchParser.saveAll(originalData: data, patches: PatchParser.parse(data: data))
        let sectionRange = header.count ..< (header.count + performanceSection().count)
        XCTAssertEqual(Array(saved[sectionRange]), Array(data[sectionRange]))
    }

    func testEditedGlobalKnobAssignmentsSurviveSave() throws {
        let data = try performanceFileWithGlobalKnobs()
        let parsed = try PatchParser.parseFile(data: data)
        var performance = try XCTUnwrap(parsed.performance)
        performance.globalKnobAssignments[9] = nil
        performance.globalKnobAssignments[24] = G2GlobalKnobAssignment(
            slot: 3, location: 0, moduleID: 40, paramIndex: 2, isLed: 1
        )

        let saved = try PatchParser.saveAll(originalData: data,
                                            patches: parsed.patches,
                                            performance: performance)
        let reloaded = try XCTUnwrap(PatchParser.parseFile(data: saved).performance)

        XCTAssertNil(reloaded.globalKnobAssignments[9])
        XCTAssertEqual(reloaded.globalKnobAssignments[24], performance.globalKnobAssignments[24])
    }

    // MARK: - Ten sam nagłówek, ale odczytany Z URZĄDZENIA (0x10 → 0x29 + sekcja 0x11)

    /// Odpowiedź Norda na Performance Header Request niesie w jednej ramce nazwę
    /// performance'u (16 bajtów) i **tę samą sekcję 0x11 co plik `.prf2`** — zmierzone
    /// na żywym sprzęcie 2026-09-04. To jedyne źródło stanów „slot gra"/„klawiatura"
    /// → [[Docs/usb/slots]].
    func testUsbPerformanceHeaderReusesFileSectionLayout() throws {
        let name = "schmaltzmachine_" // pełne 16 znaków — jak w pakiecie ze sprzętu
        let payload = Array(name.utf8) + performanceSection()

        let parsed = try XCTUnwrap(PatchParser.parseUsbPerformanceHeader(payload: payload))

        XCTAssertEqual(parsed.name, name)
        XCTAssertEqual(parsed.settings.focusedSlot, 2)
        XCTAssertEqual(parsed.settings.masterClock, 138)
        XCTAssertEqual(parsed.settings.slots.map(\.enabled), [true, false, false, false])
        XCTAssertEqual(parsed.settings.slots.map(\.keyboard), [false, true, false, false])
        XCTAssertEqual(parsed.settings.slots.map(\.name), slotNames)
    }

    /// Nazwa krótsza niż 16 znaków ma terminator, ale pole i tak zajmuje pełne 16 bajtów —
    /// bez tego sekcja 0x11 zaczynałaby się o kilka bajtów za wcześnie i cała reszta
    /// odczytu rozjechałaby się o tyle samo.
    /// Nazwa krótsza niż 16 znaków kończy się terminatorem i **tyle właśnie zajmuje** —
    /// pole NIE jest dopychane do 16 bajtów (tak samo czyta to `g2ools.parse_name`).
    /// Odczyt stałych 16 bajtów przesuwałby początek sekcji 0x11 i cały odczyt slotów.
    func testUsbPerformanceHeaderNameFieldEndsAtTerminator() throws {
        let nameField = Array("pad1".utf8) + [0]
        let parsed = try XCTUnwrap(PatchParser.parseUsbPerformanceHeader(payload: nameField + performanceSection()))
        XCTAssertEqual(parsed.name, "pad1")
        XCTAssertEqual(parsed.settings.slots.map(\.name), slotNames)
        XCTAssertEqual(parsed.settings.slots.map(\.enabled), [true, false, false, false])
    }

    // MARK: - Nazwa performance'u DO urządzenia (0x29)

    /// Nazwa kończy się terminatorem i **tyle właśnie zajmuje**. Pole dopełnione zerami do
    /// 16 bajtów Nord ODRZUCIŁ (2026-09-07) i odpowiadał potem „Error" na wszystko: po
    /// terminatorze czytał dopełnienie jako początek następnego komunikatu. Nagłówek jak
    /// przy każdej komendzie systemowej: `01 2C 41`.
    func testSetPerformanceNamePayloadEndsAtTheTerminator() {
        let payload = G2UsbProtocol.setPerformanceNamePayload("Empty perf")

        XCTAssertEqual(Array(payload.prefix(4)), [0x01, 0x2C, 0x41, 0x29])
        XCTAssertEqual(Array(payload.dropFirst(4)), Array("Empty perf".utf8) + [0])
        XCTAssertEqual(payload.count, 4 + 11, "żadnego dopełnienia do 16 bajtów")
    }

    /// Pełne 16 znaków wypełnia pole co do bajtu — terminatora nie ma gdzie zmieścić,
    /// dokładnie tak, jak wygląda nazwa nadchodząca z urządzenia („schmaltzmachine_").
    /// Dłuższa nazwa jest przycinana, a nie odrzucana.
    func testSetPerformanceNamePayloadTruncatesAtSixteenBytesWithoutTerminator() {
        let payload = G2UsbProtocol.setPerformanceNamePayload(String(repeating: "Z", count: 20))

        XCTAssertEqual(payload.count, 4 + 16)
        XCTAssertEqual(Array(payload.dropFirst(4)), Array(String(repeating: "Z", count: 16).utf8))
    }

    /// Nazwa, którą wysyłamy, wraca z urządzenia tym samym polem — obie strony jednej
    /// molekuły muszą się zgadzać co do bajta, inaczej sekcja 0x11 zaczyna się gdzie indziej.
    /// To jest ten sam warunek, o który rozbiła się pierwsza próba na sprzęcie.
    func testSentPerformanceNameReadsBackThroughTheHeaderParser() throws {
        let payload = G2UsbProtocol.setPerformanceNamePayload("pad1")

        let parsed = try XCTUnwrap(PatchParser.parseUsbPerformanceHeader(
            payload: Array(payload.dropFirst(4)) + performanceSection()
        ))
        XCTAssertEqual(parsed.name, "pad1")
        XCTAssertEqual(parsed.settings.slots.map(\.name), slotNames,
                       "sekcja musi zacząć się dokładnie za terminatorem nazwy")
    }

    // MARK: - Nagłówek performance'u DO urządzenia (0x11)

    /// Sekcja do wysłania idzie z pliku w całości — **z bajtem typu i długością** — bo
    /// Performance Header Dump (WriteStream) pisze samą sekcję, bez własnego nagłówka.
    func testPerformanceSectionStreamReturnsTheWholeSectionWithItsHeader() throws {
        let stream = try PatchParser.performanceSectionStream(fileData: performanceFile())

        XCTAssertEqual(stream, performanceSection())
        XCTAssertEqual(stream.first, 0x11)
    }

    /// `.pch2` tej sekcji nie ma — wtedy nie ma czego wysłać i wołający ma o tym wiedzieć.
    func testPerformanceSectionStreamIsEmptyForAPatchFile() throws {
        let patchOnly = try Data(Array("Version=Nord Modular G2 File Format 1\r\n".utf8)
            + [0x00, 0x17, 0x01] + moduleSection(slot: 0) + [0, 0])

        XCTAssertTrue(try PatchParser.performanceSectionStream(fileData: patchOnly).isEmpty)
    }

    /// Zapis przepisuje rozumiane pola i **zostawia całą resztę bajt w bajt** — ten sam
    /// kod, co przy zapisie do pliku, więc nazwy slotów i nieznane bajty przeżywają.
    func testPerformanceHeaderSectionRewritesFieldsAndKeepsTheRest() throws {
        var settings = try XCTUnwrap(PatchParser.parseFile(data: performanceFile()).performance)
        settings.slots[0].hold = true
        settings.slots[0].keyRangeLow = 36
        settings.slots[0].keyRangeHigh = 96
        settings.masterClock = 90

        let section = try XCTUnwrap(PatchParser.performanceHeaderSection(
            originalSection: performanceSection(), performance: settings
        ))

        XCTAssertEqual(Array(section.prefix(3)), Array(performanceSection().prefix(3)),
                       "typ i długość sekcji bez zmian")
        // Nazwa jest w tej samej ramce co odpowiedź urządzenia, więc czyta się tym samym kodem.
        let reparsed = try XCTUnwrap(PatchParser.parseUsbPerformanceHeader(
            payload: Array("perf\0".utf8) + section
        ))
        XCTAssertEqual(reparsed.settings.slots.map(\.name), slotNames, "nazwy slotów nietknięte")
        XCTAssertTrue(reparsed.settings.slots[0].hold)
        XCTAssertEqual(reparsed.settings.slots[0].keyRangeLow, 36)
        XCTAssertEqual(reparsed.settings.slots[0].keyRangeHigh, 96)
        XCTAssertEqual(reparsed.settings.masterClock, 90)
        XCTAssertEqual(reparsed.section, section, "sekcja wraca w tej samej postaci")
    }

    /// Sekcja innego typu (albo obcięta) nie daje się przepisać — wtedy lepiej nie wysłać
    /// nic, niż wysłać do Norda zgadywane bajty.
    func testPerformanceHeaderSectionRefusesAnythingButSectionEleven() {
        XCTAssertNil(PatchParser.performanceHeaderSection(originalSection: [0x21, 0, 1, 0],
                                                          performance: G2PerformanceSettings()))
        XCTAssertNil(PatchParser.performanceHeaderSection(originalSection: [0x11, 0x00, 0x40, 0x01],
                                                          performance: G2PerformanceSettings()))
    }

    /// Payload komendy: nagłówek systemowy i **sekcja bez powtórzonego bajtu podkomendy** —
    /// `0x11` przychodzi razem z sekcją (`CPerformanceHeader_11::WriteStream`).
    func testSetPerformanceHeaderPayloadDoesNotRepeatTheSubCommandByte() {
        let section = performanceSection()
        let payload = G2UsbProtocol.setPerformanceHeaderPayload(section: section)

        XCTAssertEqual(Array(payload.prefix(4)), [0x01, 0x2C, 0x41, 0x11])
        XCTAssertEqual(Array(payload.dropFirst(3)), section)
        XCTAssertEqual(payload.count, 3 + section.count)
    }

    // MARK: - Tryb urządzenia (Performance / Patch)

    /// Performance Mode Change — układ bajtów za `g2ools/g2ctl.py cmd_mode`.
    func testPerformanceModePayload() {
        XCTAssertEqual(G2UsbProtocol.performanceModePayload(performance: true),
                       [0x01, 0x2C, 0x41, 0x3E, 0x01, 0x00])
        XCTAssertEqual(G2UsbProtocol.performanceModePayload(performance: false),
                       [0x01, 0x2C, 0x41, 0x3E, 0x00, 0x00])
    }

    /// Tryb siedzi w najstarszym bicie bajtu tuż za nazwą urządzenia — nazwa może być
    /// krótsza niż 16 znaków (wtedy kończy ją terminator) albo zająć pełne 16.
    func testPerformanceModeIsReadFromTheByteAfterTheName() {
        let shortName = Array("G2 Nord".utf8) + [0]
        XCTAssertEqual(G2UsbProtocol.decodePerformanceMode(shortName + [0x80]), true)
        XCTAssertEqual(G2UsbProtocol.decodePerformanceMode(shortName + [0x00]), false)
        let fullName = [UInt8](repeating: 0x41, count: 16)
        XCTAssertEqual(G2UsbProtocol.decodePerformanceMode(fullName + [0x80]), true)
        XCTAssertNil(G2UsbProtocol.decodePerformanceMode(shortName), "brak bajtu trybu")
    }

    // MARK: - Nazwy slotów (instrukcja, str. 97: „Renaming single patches in Performances")

    /// Sekcja składana jest od nowa, więc zapis bez zmian musi ją odtworzyć bajt w bajt —
    /// razem z nazwą pustą i taką, która zajmuje pełne 16 znaków bez terminatora.
    func testUnchangedPerformanceSectionSavesByteForByte() throws {
        let data = try performanceFile()
        let performance = try XCTUnwrap(PatchParser.parseFile(data: data).performance)
        let saved = try PatchParser.saveAll(originalData: data,
                                            patches: PatchParser.parse(data: data),
                                            performance: performance)

        let section = performanceSection()
        XCTAssertEqual(Array([UInt8](saved)[header.count ..< header.count + section.count]), section)
    }

    /// Przemianowanie slotu zmienia długość sekcji — nagłówek długości musi za tym nadążyć,
    /// a wszystkie cztery nazwy wrócić po ponownym odczycie.
    func testRenamingASlotSurvivesSaveAndReload() throws {
        let data = try performanceFile()
        var performance = try XCTUnwrap(PatchParser.parseFile(data: data).performance)
        performance.slots[0].name = "Much longer name"
        performance.slots[2].name = "Short"

        let saved = try PatchParser.saveAll(originalData: data,
                                            patches: PatchParser.parse(data: data),
                                            performance: performance)
        let reloaded = try XCTUnwrap(PatchParser.parseFile(data: saved).performance)

        XCTAssertEqual(reloaded.slots.map(\.name),
                       ["Much longer name", "", "Short", "Anthem"])
        XCTAssertEqual(reloaded.masterClock, 138, "reszta sekcji przeżywa zmianę długości")
        XCTAssertEqual(reloaded.slots.map(\.keyRangeHigh), [120, 121, 122, 123])
        XCTAssertEqual(try PatchParser.parse(data: saved).map(\.name),
                       ["Much longer name", "", "Short", "Anthem"])
    }
}
