// G2UsbProtocolTests.swift
// CRC16 i ramkowanie zweryfikowane wobec skompilowanego reference/G2-Edit/src/utils.c
// (crc_iterator/calc_crc16) — wartości oczekiwane pochodzą z uruchomienia tego C, nie z Swift.

@testable import G2Core
import XCTest

final class G2UsbProtocolTests: XCTestCase {
    // MARK: - CRC16

    func testCrc16OfEmptyIsZero() {
        XCTAssertEqual(G2UsbProtocol.crc16([]), 0x0000)
    }

    func testCrc16MatchesStandardXModemCheckValue() {
        // Standardowa wartość kontrolna CRC-16/XMODEM dla "123456789" — potwierdza,
        // że crc_iterator z utils.c to zwykły CRC-CCITT/XMODEM (poly 0x1021, init 0).
        let bytes = Array("123456789".utf8)
        XCTAssertEqual(G2UsbProtocol.crc16(bytes), 0x31C3)
    }

    func testCrc16MatchesReferenceCForCommandPayloads() {
        XCTAssertEqual(G2UsbProtocol.crc16(G2UsbProtocol.initPingPayload()), 0x9188)
        XCTAssertEqual(G2UsbProtocol.crc16(G2UsbProtocol.getSynthSettingsPayload()), 0x9BAC)
        XCTAssertEqual(G2UsbProtocol.crc16(G2UsbProtocol.startPayload()), 0x86B5)
    }

    // MARK: - Ramki TX

    func testBuildFrameForInitPing() {
        XCTAssertEqual(G2UsbProtocol.buildFrame(payload: [0x80]), [0x00, 0x05, 0x80, 0x91, 0x88])
    }

    func testBuildFrameForGetSynthSettings() {
        XCTAssertEqual(
            G2UsbProtocol.buildFrame(payload: G2UsbProtocol.getSynthSettingsPayload()),
            [0x00, 0x08, 0x01, 0x2C, 0x41, 0x02, 0x9B, 0xAC]
        )
    }

    func testBuildFrameForStart() {
        XCTAssertEqual(
            G2UsbProtocol.buildFrame(payload: G2UsbProtocol.startPayload()),
            [0x00, 0x09, 0x01, 0x2C, 0x41, 0x7D, 0x00, 0x86, 0xB5]
        )
    }

    func testGetPatchSlotPayloadEncodesSlotAndVersion() {
        XCTAssertEqual(
            G2UsbProtocol.getPatchSlotPayload(slot: 2, version: 7),
            [0x01, 0x2A, 0x07, 0x3C]
        )
    }

    // MARK: - SUB_COMMAND_GET_PATCH_NAME (0x28) → SUB_RESPONSE_PATCH_NAME (0x27)

    func testGetPatchNamePayloadEncodesSlotAndVersion() {
        XCTAssertEqual(
            G2UsbProtocol.getPatchNamePayload(slot: 2, version: 7),
            [0x01, 0x2A, 0x07, 0x28]
        )
    }

    func testDecodePatchNameStopsAtTerminatorAndIgnoresPadding() {
        let payload = Array("Lead\0".utf8) + [UInt8](repeating: 0, count: 11)
        XCTAssertEqual(G2UsbProtocol.decodePatchName(payload), "Lead")
    }

    func testDecodePatchNameKeepsFullSixteenCharsWithoutTerminator() {
        let sixteen = String(repeating: "X", count: 16)
        XCTAssertEqual(G2UsbProtocol.decodePatchName(Array(sixteen.utf8) + [0x41]), sixteen,
                       "17. bajt nie należy już do nazwy")
    }

    func testDecodePatchNameOfEmptySlotIsEmptyString() {
        XCTAssertEqual(G2UsbProtocol.decodePatchName([0x00, 0x00]), "")
        XCTAssertEqual(G2UsbProtocol.decodePatchName([]), "")
    }

    /// Pełna ścieżka odbioru: ramka extended → CRC → rozbiór nagłówka → nazwa.
    /// `commandResponse` niesie numer slotu w dwóch młodszych bitach (usbComms.c:397).
    func testPatchNameResponseFrameDecodesToNameAndSlot() throws {
        let body: [UInt8] = [0x01, 0x2A, 0x07, 0x27] + Array("My Patch\0".utf8)
        let crc = G2UsbProtocol.crc16(body)
        let framed = body + [UInt8(crc >> 8), UInt8(crc & 0xFF)]

        let validated = try XCTUnwrap(G2UsbProtocol.validateExtendedFrame(framed))
        let decoded = try XCTUnwrap(G2UsbProtocol.decodeResponseBody(validated))
        XCTAssertEqual(decoded.subCommand, G2UsbProtocol.subPatchNameResponse)
        XCTAssertEqual(decoded.commandResponse.map { $0 & 0x03 }, 2)
        XCTAssertEqual(G2UsbProtocol.decodePatchName(decoded.payload), "My Patch")
    }

    // MARK: - SUB_COMMAND_SELECT_SLOT (0x09) — "aktywny" slot na urządzeniu, wymagany

    // przed strukturalnym zapisem do slotu innego niż aktualnie aktywny.

    func testSelectSlotPayloadEncodesArbitrarySlot() {
        // [tag][reqSys][0x00][0x09][slot] — reference/G2-Edit/src/usbComms.c eMsgCmdSelectSlot
        XCTAssertEqual(
            G2UsbProtocol.selectSlotPayload(slot: 3),
            [0x01, 0x2C, 0x00, 0x09, 0x03]
        )
    }

    // MARK: - 0x37 — cały patch w jednej komendzie

    func testSetPatchPayloadEncodesSlotVersionDestinationAndName() {
        let payload = G2UsbProtocol.setPatchPayload(slot: 1, version: 0x12, patchName: "Lead",
                                                    sectionBytes: [0xAA, 0xBB])
        // [tag][reqSlot(1)][wersja][0x37][cel: 0,0,0][name "Lead\0" 5B][sekcje]
        XCTAssertEqual(
            payload,
            [0x01, 0x29, 0x12, 0x37, 0x00, 0x00, 0x00] + Array("Lead\0".utf8) + [0xAA, 0xBB]
        )
    }

    func testSetPatchPayloadTruncatesNameAt16BytesWithoutTerminator() {
        let longName = String(repeating: "X", count: 20)
        let payload = G2UsbProtocol.setPatchPayload(slot: 0, version: 0, patchName: longName, sectionBytes: [])
        let nameBytes = Array(payload.dropFirst(7))
        XCTAssertEqual(nameBytes.count, 16, "16-char name has no room for a null terminator")
        XCTAssertEqual(nameBytes, Array(String(repeating: "X", count: 16).utf8))
    }

    // MARK: - SUB_COMMAND_ADD_MODULE (0x30) — framing only, unverified on hardware

    func testAddModulePayloadEncodesFieldsInConfirmedOrder() {
        var module = G2Module(id: 5, typeID: 41, area: .voice)
        module.column = 3
        module.row = 2
        module.color = 7
        module.uprate = true
        module.leds = false
        module.modes = [1, 2]
        module.label = "Osc"

        let payload = G2UsbProtocol.addModulePayload(slot: 1, version: 9, module: module)

        // [tag][reqSlot(1)][version][0x30][type][location=1(voice)][index][col][row][colour][upRate][isLed] + modes + name
        let expected: [UInt8] = [0x01, 0x29, 9, 0x30, 41, 1, 5, 3, 2, 7, 1, 0, 1, 2] + Array("Osc\0".utf8)
        XCTAssertEqual(payload, expected)
    }

    func testAddModulePayloadEncodesFxAreaAsZero() {
        let module = G2Module(id: 0, typeID: 1, area: .fx)
        let payload = G2UsbProtocol.addModulePayload(slot: 0, version: 0, module: module)
        XCTAssertEqual(payload[5], 0, "fx area must encode as 0")
    }

    func testAddModulePayloadTruncatesNameAt16BytesWithoutTerminator() {
        var module = G2Module(id: 0, typeID: 0, area: .fx)
        module.label = String(repeating: "Y", count: 20)
        let payload = G2UsbProtocol.addModulePayload(slot: 0, version: 0, module: module)
        // header(4) + type/location/index/col/row/colour/upRate/isLed(8) = 12 bytes before modes/name
        let nameBytes = Array(payload.suffix(16))
        XCTAssertEqual(nameBytes, Array(String(repeating: "Y", count: 16).utf8))
    }

    // MARK: - Module name (0x33) and colour (0x31) — live, sound keeps playing

    /// Layout confirmed twice: Clavia Module Name (WriteStream) and BVerhue
    /// `AddSetModuleLabelMessage` — `[0x33][location][index][clavia string]`.
    func testSetModuleNamePayloadEncodesLocationIndexAndName() {
        var module = G2Module(id: 5, typeID: 41, area: .voice)
        module.label = "Bass"

        let payload = G2UsbProtocol.setModuleNamePayload(slot: 1, version: 9, module: module)
        XCTAssertEqual(payload, [0x01, 0x29, 9, 0x33, 1, 5] + Array("Bass\0".utf8))
    }

    /// A 16-character name fills the field exactly and leaves no room for the terminator —
    /// same rule as `AddModule`.
    func testSetModuleNamePayloadTruncatesAt16BytesWithoutTerminator() {
        var module = G2Module(id: 0, typeID: 0, area: .fx)
        module.label = String(repeating: "Y", count: 20)

        let payload = G2UsbProtocol.setModuleNamePayload(slot: 0, version: 0, module: module)
        XCTAssertEqual(payload[4], 0, "fx area must encode as 0")
        XCTAssertEqual(Array(payload.suffix(16)), Array(String(repeating: "Y", count: 16).utf8))
        XCTAssertEqual(payload.count, 6 + 16)
    }

    /// `[0x34][location][index][column][row]` — Clavia Module Move (WriteStream)
    /// i BVerhue `AddMessModuleMove`.
    func testSetModulePositionPayloadEncodesLocationIndexAndGridCell() {
        var module = G2Module(id: 5, typeID: 41, area: .voice)
        module.column = 3
        module.row = 9

        XCTAssertEqual(G2UsbProtocol.setModulePositionPayload(slot: 1, version: 9, module: module),
                       [0x01, 0x29, 9, 0x34, 1, 5, 3, 9])
    }

    func testSetModuleColorPayloadEncodesLocationIndexAndColour() {
        var module = G2Module(id: 7, typeID: 41, area: .fx)
        module.color = 12

        let payload = G2UsbProtocol.setModuleColorPayload(slot: 2, version: 3, module: module)
        XCTAssertEqual(payload, [0x01, 0x2A, 3, 0x31, 0, 7, 12])
    }

    // MARK: - 0x21 Patch Header Dump — patch description sent live (Voices/Polyphony/Category).

    /// The molecule belongs to the "dump" family, so the body carries the same
    /// two-byte length as the section does inside a patch stream.
    func testSetPatchDescriptionPayloadCarriesSectionTypeLengthAndBody() {
        let body = [UInt8](repeating: 0xAB, count: 15)
        let payload = G2UsbProtocol.setPatchDescriptionPayload(slot: 1, version: 9, sectionBody: body)

        XCTAssertEqual(Array(payload.prefix(6)), [0x01, 0x29, 9, 0x21, 0x00, 0x0F])
        XCTAssertEqual(Array(payload.dropFirst(6)), body)
    }

    // MARK: - SUB_COMMAND_WRITE_CABLE (0x50) — one cable per message, mirrors AddModule.

    func testWriteCablePayloadEncodesVoiceAreaAndConnectorIndices() {
        let cable = G2Cable(fromModule: 3, fromConnector: 2, toModule: 5, toConnector: 1, color: .red, area: .voice)
        let payload = G2UsbProtocol.writeCablePayload(slot: 1, version: 9, cable: cable)
        // [tag][reqSlot(1)][version][0x50][0x10|location<<3][fromModule][linkType<<6|fromConnector][toModule][toConnector]
        XCTAssertEqual(payload, [0x01, 0x29, 9, 0x50, 0x18, 3, 0x42, 5, 1])
    }

    func testWriteCablePayloadEncodesFxAreaAsZero() {
        let cable = G2Cable(fromModule: 0, fromConnector: 0, toModule: 0, toConnector: 0, color: .red, area: .fx)
        let payload = G2UsbProtocol.writeCablePayload(slot: 0, version: 0, cable: cable)
        XCTAssertEqual(payload[4], 0x10, "fx area must encode location bits as 0")
    }

    /// The low three bits of the same byte carry the cable colour (`ECableColor`).
    /// Until 2026-09-06 they were always zero, so every live cable turned up red
    /// on the device no matter what the editor showed.
    func testWriteCablePayloadCarriesTheCableColour() {
        let cable = G2Cable(fromModule: 0, fromConnector: 0, toModule: 0, toConnector: 0, color: .green, area: .voice)
        let payload = G2UsbProtocol.writeCablePayload(slot: 0, version: 0, cable: cable)
        XCTAssertEqual(payload[4], 0x18 | 4, "voice + green (4)")
    }

    // MARK: - SUB_COMMAND_DELETE_CABLE/DELETE_MODULE (0x51/0x32) — czyszczenie slotu

    func testDeleteCablePayloadUsesOwnAreaEncoding() {
        let cable = G2Cable(fromModule: 3, fromConnector: 2, toModule: 5, toConnector: 1, color: .red, area: .voice)
        let payload = G2UsbProtocol.deleteCablePayload(slot: 1, version: 9, cable: cable)
        // Obszar koduje się tu jako 0x02|location, INACZEJ niż 0x10|location<<3 w writeCablePayload.
        XCTAssertEqual(payload, [0x01, 0x29, 9, 0x51, 0x03, 3, 0x42, 5, 1])
    }

    func testDeleteCablePayloadEncodesFxAreaAsTwo() {
        let cable = G2Cable(fromModule: 0, fromConnector: 0, toModule: 0, toConnector: 0, color: .red, area: .fx)
        XCTAssertEqual(G2UsbProtocol.deleteCablePayload(slot: 0, version: 0, cable: cable)[4], 0x02)
    }

    /// Bajt 6 to `(linkType << 6) | connectorFrom` (usbComms.c `eMsgCmdWriteCable`).
    /// Do 2026-09-03 `linkType` był tu na sztywno 1, więc kabel wejście-wejście
    /// wysyłaliśmy jako wyjście→wejście — i potem nie dawał się skasować, bo komenda
    /// kasowania podawała ten sam, błędny linkType.
    func testCablePayloadsEncodeLinkTypeZeroForInputToInputCable() {
        let inputToInput = G2Cable(fromModule: 3, fromConnector: 2, toModule: 5, toConnector: 1,
                                   color: .red, area: .voice, sourceIsOutput: false)
        XCTAssertEqual(G2UsbProtocol.writeCablePayload(slot: 1, version: 9, cable: inputToInput)[6], 0x02,
                       "linkType=0 → sam indeks konektora, bez bitu 6")
        XCTAssertEqual(G2UsbProtocol.deleteCablePayload(slot: 1, version: 9, cable: inputToInput)[6], 0x02,
                       "kasowanie musi podać ten sam linkType co zapis")

        let outputToInput = G2Cable(fromModule: 3, fromConnector: 2, toModule: 5, toConnector: 1,
                                    color: .red, area: .voice, sourceIsOutput: true)
        XCTAssertEqual(G2UsbProtocol.writeCablePayload(slot: 1, version: 9, cable: outputToInput)[6], 0x42,
                       "linkType=1 → bit 6 ustawiony")
        XCTAssertEqual(G2UsbProtocol.deleteCablePayload(slot: 1, version: 9, cable: outputToInput)[6], 0x42)
    }

    func testDeleteModulePayloadCarriesLocationAndIndex() {
        var module = G2Module(id: 7, typeID: 4, area: .voice)
        module.column = 1
        module.row = 2
        let payload = G2UsbProtocol.deleteModulePayload(slot: 2, version: 5, module: module)
        XCTAssertEqual(payload, [0x01, 0x2A, 5, 0x32, 1, 7])
    }

    // MARK: - SUB_COMMAND_SET_PARAM (0x40) — real-time, bez potwierdzenia (COMMAND_WRITE_NO_RESP)

    func testSetParameterPayloadEncodesFieldsInConfirmedOrder() {
        let payload = G2UsbProtocol.setParameterPayload(slot: 2, version: 9, area: .voice, moduleID: 5, paramIndex: 3, value: 42)
        // [tag][noRespSlot(2)=0x3A][version][0x40][location=1(voice)][module][param][value][variation=0]
        XCTAssertEqual(payload, [0x01, 0x3A, 9, 0x40, 1, 5, 3, 42, 0])
    }

    /// Paczka Patch Adjustera: jeden nagłówek bez potwierdzenia, potem molekuła za molekułą.
    func testSetParametersPayloadPacksSeveralMoleculesBehindOneHeader() {
        let changes = [
            G2ParameterChange(area: .voice, moduleID: 5, paramIndex: 3, value: 42),
            G2ParameterChange(area: .fx, moduleID: 2, paramIndex: 0, value: 7),
        ]
        let payload = G2UsbProtocol.setParametersPayload(slot: 2, version: 9, changes: changes, variation: 1)
        XCTAssertEqual(payload, [0x01, 0x3A, 9,
                                 0x40, 1, 5, 3, 42, 1,
                                 0x40, 0, 2, 0, 7, 1])
        XCTAssertEqual(G2UsbProtocol.setParametersPayload(slot: 2, version: 9, changes: [], variation: 1), [])
    }

    func testSetParameterPayloadEncodesFxAreaAsZero() {
        let payload = G2UsbProtocol.setParameterPayload(slot: 0, version: 0, area: .fx, moduleID: 0, paramIndex: 0, value: 0)
        XCTAssertEqual(payload[4], 0, "fx area must encode as 0")
    }

    // MARK: - SUB_COMMAND (0x4D/0x5A) — ParamDump/NameDump framing,

    // unverified on hardware. Leading type byte of combinedSectionBytes is dropped —
    // it's already carried by the header's subCommand byte, see G2UsbProtocol.paramDumpPayload.

    func testParamDumpPayloadDropsLeadingTypeByteAndKeepsRest() {
        let combined: [UInt8] = [0x4D, 0x00, 0x01, 0xCC]
        let payload = G2UsbProtocol.paramDumpPayload(slot: 2, version: 3, combinedSectionBytes: combined)
        XCTAssertEqual(payload, [0x01, 0x2A, 3, 0x4D, 0x00, 0x01, 0xCC])
    }

    func testModuleNameDumpPayloadDropsLeadingTypeByteAndKeepsRest() {
        let combined: [UInt8] = [0x5A, 0x00, 0x01, 0xDD]
        let payload = G2UsbProtocol.moduleNameDumpPayload(slot: 0, version: 0, combinedSectionBytes: combined)
        XCTAssertEqual(payload, [0x01, 0x28, 0, 0x5A, 0x00, 0x01, 0xDD])
    }

    // MARK: - Dekodowanie pakietu interrupt

    func testDecodeInterruptHeaderEmbedded() {
        // type=0x2 (embedded), dataLength=4 w górnym nibble
        let bytes: [UInt8] = [0x42, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        guard case let .embedded(length) = G2UsbProtocol.decodeInterruptHeader(bytes) else {
            return XCTFail("Expected embedded kind")
        }
        XCTAssertEqual(length, 4)
    }

    func testDecodeInterruptHeaderExtendedReadsBigEndianLength() {
        // type=0x1 (extended), długość = 0x0120 = 288, padding zerowy
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0x01
        bytes[1] = 0x01
        bytes[2] = 0x20
        guard case let .extended(length) = G2UsbProtocol.decodeInterruptHeader(bytes) else {
            return XCTFail("Expected extended kind")
        }
        XCTAssertEqual(length, 0x120)
    }

    func testDecodeInterruptHeaderExtendedRejectsNonZeroPadding() {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0x01
        bytes[1] = 0x01
        bytes[2] = 0x20
        bytes[5] = 0xFF // padding naruszony
        XCTAssertEqual(G2UsbProtocol.decodeInterruptHeader(bytes), .unknown)
    }

    // MARK: - Walidacja ramki extended + dekodowanie treści

    func testValidateExtendedFrameRoundTrip() throws {
        let payload: [UInt8] = [0x01, 0x00, 0x05, 0x36, 0x02, 0x07] // responseType, commandResponse, version, sub=0x36, slot=2, version=7
        let crc = G2UsbProtocol.crc16(payload)
        let framed = payload + [UInt8(crc >> 8), UInt8(crc & 0xFF)]

        let validated = try XCTUnwrap(G2UsbProtocol.validateExtendedFrame(framed))
        XCTAssertEqual(validated, payload)

        let decoded = try XCTUnwrap(G2UsbProtocol.decodeResponseBody(validated))
        XCTAssertEqual(decoded.subCommand, 0x36)
        let version = try XCTUnwrap(G2UsbProtocol.decodePatchVersion(decoded.payload))
        XCTAssertEqual(version.slot, 2)
        XCTAssertEqual(version.version, 7)
    }

    func testValidateExtendedFrameRejectsBadCrc() {
        let payload: [UInt8] = [0x01, 0x00, 0x05, 0x7F]
        let framed = payload + [0x00, 0x00] // zły CRC
        XCTAssertNil(G2UsbProtocol.validateExtendedFrame(framed))
    }

    func testDecodeResponseBodyForInit() throws {
        let decoded = try XCTUnwrap(G2UsbProtocol.decodeResponseBody([0x80]))
        XCTAssertEqual(decoded.responseType, 0x80)
        XCTAssertNil(decoded.subCommand)
    }

    /// Performance Release (0x1F) — pakiet złapany na żywym Nordzie po załadowaniu
    /// patcha z jego frontu (`USBProbe --listen`, 2026-09-04). Musi być rozpoznany jako
    /// powiadomienie: gdyby nim nie był, `awaitResponse` wziąłby go za potwierdzenie
    /// NASZEJ komendy i zapis „przeszedłby" bez ACK — dokładnie ten błąd kosztował
    /// sześć nieudanych prób `sendPatch` 2026-09-02/03.
    ///
    /// Bajty za pierwszym komunikatem to osobne `0x36` Session Number Dump upakowane
    /// w tej samej ramce — tu tylko po to, żeby test odbijał prawdziwy pakiet.
    func testPerformanceReleaseNotificationIsUnsolicited() throws {
        let body: [UInt8] = [0x01, 0x00, 0x00, G2UsbProtocol.subResponsePerformanceRelease,
                             0x12, 0x36, 0x00, 0x13, 0x36, 0x01, 0x12,
                             0x36, 0x02, 0x12, 0x36, 0x03, 0x12]
        let decoded = try XCTUnwrap(G2UsbProtocol.decodeResponseBody(body))
        XCTAssertEqual(decoded.subCommand, 0x1F)
        XCTAssertTrue(G2UsbProtocol.isUnsolicited(decoded))
    }

    // MARK: - Sloty: selekcja (0x07) osobno od focusu (0x09)

    /// Układ bajtu z Slot Selection Dump (WriteStream) w oryginalnym edytorze Clavii i z
    /// `g2ools/g2ctl.py` (`0x08 >> slot`): cztery bity zera, potem po jednym bicie na
    /// slot A…D, od najstarszego → [[Docs/usb/slots]].
    func testSlotBitsPackFromMostSignificantBit() {
        XCTAssertEqual(G2UsbProtocol.slotBits([true, false, false, false]), 0x08)
        XCTAssertEqual(G2UsbProtocol.slotBits([false, true, false, false]), 0x04)
        XCTAssertEqual(G2UsbProtocol.slotBits([false, false, true, false]), 0x02)
        XCTAssertEqual(G2UsbProtocol.slotBits([false, false, false, true]), 0x01)
        XCTAssertEqual(G2UsbProtocol.slotBits([true, true, false, false]), 0x0C)
        XCTAssertEqual(G2UsbProtocol.slotBits([false, false, false, false]), 0x00)
    }

    /// Selekcja i klawiatura jadą w JEDNEJ ramce jako dwa komunikaty (0x07 i 0x0F) —
    /// tak robi to `g2ctl.py cmd_slot`, jedyne znane działające narzędzie.
    func testSlotSelectionPayloadCarriesBothMolecules() {
        let payload = G2UsbProtocol.slotSelectionPayload(enabled: [false, true, false, false],
                                                         keyboard: [false, true, false, false],
                                                         version: 0x41)
        XCTAssertEqual(payload, [0x01, 0x2C, 0x41, 0x07, 0x04, 0x0F, 0x04])
    }

    /// Komunikat jest dwukierunkowy — urządzenie nadaje go, gdy sloty przełączy się na
    /// froncie. Kodowanie i odczyt muszą się schodzić, inaczej edytor pokazywałby na
    /// przyciskach slotów odwróconą kolejność A↔D.
    func testSlotSelectionRoundTrip() throws {
        for enabled in [[true, false, false, false], [false, true, true, false], [true, true, true, true]] {
            let bits = G2UsbProtocol.slotBits(enabled)
            let decoded = try XCTUnwrap(G2UsbProtocol.decodeSlotSelection([bits]))
            XCTAssertEqual(decoded, enabled)
        }
    }

    /// Selekcja slotów przychodzi też sama z siebie, więc musi być rozpoznawana jako
    /// powiadomienie — inaczej `awaitResponse` wziąłby ją za potwierdzenie cudzej komendy.
    func testSlotSelectionNotificationIsUnsolicited() throws {
        let body: [UInt8] = [0x01, 0x00, 0x00, G2UsbProtocol.subResponseSlotSelection, 0x08]
        let decoded = try XCTUnwrap(G2UsbProtocol.decodeResponseBody(body))
        XCTAssertTrue(G2UsbProtocol.isUnsolicited(decoded))
    }

    // MARK: - Paczki molekuł (jedna ramka, kilka komunikatów)

    /// Ramka z kilkoma komunikatami ma JEDEN nagłówek, a molekuły idą jedna za drugą —
    /// tak wysyła je oryginał (`CBubble`). Dowód, że urządzenie to przyjmuje, mamy
    /// z obu stron: nasz `0x07`+`0x0F` działa na sprzęcie, a Nord przysyła `0x1F`
    /// z czterema `0x36` → [[Docs/usb/actor]].
    func testBatchPayloadKeepsSingleHeaderAndConcatenatesMolecules() {
        var first = G2Module(id: 1, typeID: 4, area: .voice)
        first.label = "Out"
        var second = G2Module(id: 2, typeID: 12, area: .voice)
        second.label = "Rev"

        let single = G2UsbProtocol.addModulePayload(slot: 2, version: 0x11, module: first)
        let batch = G2UsbProtocol.batchPayload(
            slot: 2, version: 0x11,
            molecules: [G2UsbProtocol.addModuleMolecule(first), G2UsbProtocol.addModuleMolecule(second)]
        )

        // Paczka jednoelementowa musi być bajt w bajt tym samym, co dotychczasowa komenda —
        // inaczej powrót do wysyłki pojedynczej (bezpiecznik w `sendPatch`) zmieniałby bajty.
        XCTAssertEqual(G2UsbProtocol.batchPayload(slot: 2, version: 0x11,
                                                  molecules: [G2UsbProtocol.addModuleMolecule(first)]),
                       single)
        XCTAssertEqual(Array(batch.prefix(3)), Array(single.prefix(3)))
        XCTAssertEqual(batch.count, single.count + G2UsbProtocol.addModuleMolecule(second).count)
        XCTAssertEqual(Array(batch.prefix(single.count)), single)
    }

    /// To samo dla kabli — `writeCablePayload` musi zostać sumą nagłówka i molekuły.
    func testWriteCablePayloadIsHeaderPlusMolecule() {
        let cable = G2Cable(fromModule: 3, fromConnector: 0, toModule: 4, toConnector: 1,
                            color: .blue, area: .voice, sourceIsOutput: true)
        let payload = G2UsbProtocol.writeCablePayload(slot: 1, version: 0x22, cable: cable)
        XCTAssertEqual(payload, G2UsbProtocol.batchPayload(slot: 1, version: 0x22,
                                                           molecules: [G2UsbProtocol.writeCableMolecule(cable)]))
    }

    // MARK: - Kto mówi: odpowiedź czy sam Nord (bit 3 bajtu odpowiedzi)

    /// Bajty wzięte wprost z logów ze sprzętu (2026-09-05). Rozstrzyga bit 3
    /// `commandResponse`, dokładnie jak Synth Port USB (BuildHeaderAndData) w oryginale.
    func testSynthInitiatedIsReadFromTheResponseByte() {
        // Zawartość slotu A — odpowiedź na GetPatchSlot.
        let dump = G2UsbProtocol.decodeResponseBody([0x01, 0x08, 0x00, 0x21, 0x00, 0x0F])
        XCTAssertEqual(dump?.isSynthInitiated, false)
        XCTAssertEqual(dump?.slot, 0)

        // Numer sesji slotu D — odpowiedź na wgranie patcha (0x37).
        let session = G2UsbProtocol.decodeResponseBody([0x01, 0x0B, 0x40, 0x36, 0x03, 0x01])
        XCTAssertEqual(session?.isSynthInitiated, false)
        XCTAssertEqual(session?.slot, 3)

        // Strumień wskaźników — Nord nadaje go sam z siebie.
        let stream = G2UsbProtocol.decodeResponseBody([0x01, 0x01, 0x00, 0x72, 0x01, 0x04])
        XCTAssertEqual(stream?.isSynthInitiated, true)
        XCTAssertEqual(stream?.slot, 1)

        // Ustawienia synta — odpowiedź systemowa, numer slotu nic tu nie znaczy.
        let settings = G2UsbProtocol.decodeResponseBody([0x01, 0x0C, 0x00, 0x03, 0x4E])
        XCTAssertEqual(settings?.isSynthInitiated, false)
        XCTAssertNil(settings?.slot)
    }

    // MARK: - Zegar główny (0x3B / 0x3F / 0x5D)

    /// Pytanie o stan zegara ma nagłówek komendy systemowej, jak `TG2Synth.InitMsg`
    /// u BVerhue (`01 2C 41`) i jak wszystkie nasze pozostałe komendy systemowe.
    func testClockInfoRequestPayload() {
        XCTAssertEqual(G2UsbProtocol.clockInfoRequestPayload(), [0x01, 0x2C, 0x41, 0x3B])
    }

    /// Prawdziwa ramka złapana przez g2fx: `3f ff 01 79` = 121 BPM.
    func testSetMasterClockPayloadMatchesCapturedFrame() {
        let payload = G2UsbProtocol.setMasterClockPayload(bpm: 121, version: 0x41)
        XCTAssertEqual(payload, [0x01, 0x2C, 0x41, 0x3F, 0xFF, 0x01, 0x79])
    }

    /// Tempo poza 30…240 przycinamy przed wysyłką — tak samo robi `ChangeClockRate`
    /// w oryginale (`ClipValue(v, 0x1e, 0xf0)`).
    func testSetMasterClockPayloadClampsToDeviceRange() {
        XCTAssertEqual(G2UsbProtocol.setMasterClockPayload(bpm: 5, version: 0x41).last, 30)
        XCTAssertEqual(G2UsbProtocol.setMasterClockPayload(bpm: 900, version: 0x41).last, 240)
    }

    /// Run i tempo to ta sama komenda z innym indeksem — `$00` Run, `$01` BPM
    /// (`TG2Perf.AddMsgSetMasterClockRun` / `…BPM`).
    func testSetClockRunPayloadUsesIndexZero() {
        XCTAssertEqual(G2UsbProtocol.setClockRunPayload(running: true, version: 0x41),
                       [0x01, 0x2C, 0x41, 0x3F, 0xFF, 0x00, 0x01])
        XCTAssertEqual(G2UsbProtocol.setClockRunPayload(running: false, version: 0x41).last, 0x00)
    }

    func testDecodeMasterClockReadsBothFields() {
        XCTAssertEqual(G2UsbProtocol.decodeMasterClock([0xFF, 0x01, 0x79]), .bpm(121))
        XCTAssertEqual(G2UsbProtocol.decodeMasterClock([0xFF, 0x00, 0x01]), .running(true))
        XCTAssertEqual(G2UsbProtocol.decodeMasterClock([0xFF, 0x00, 0x00]), .running(false))
    }

    /// Tempo spoza zakresu urządzenia znaczy, że to nie jest ten komunikat — u BVerhue
    /// `SetMasterClock` rzuca wtedy wyjątkiem, a nie pokazuje wartości.
    func testDecodeMasterClockRejectsGarbage() {
        XCTAssertNil(G2UsbProtocol.decodeMasterClock([0xFF, 0x01, 0x0A]))
        XCTAssertNil(G2UsbProtocol.decodeMasterClock([0xFF, 0x07, 0x79]))
        XCTAssertNil(G2UsbProtocol.decodeMasterClock([0xFF, 0x01]))
        XCTAssertNil(G2UsbProtocol.decodeMasterClock([]))
    }

    /// `0x5D`: flaga ≠ 0 = zegar WEWNĘTRZNY, tempo 16-bitowe BE. Domyślne wartości
    /// obiektu `CSysClockInfo` w oryginale to `1` i `0x78` — „wewnętrzny, 120".
    func testDecodeSysClockInfoFlagAndTempo() {
        let internalClock = G2UsbProtocol.decodeSysClockInfo([0x01, 0x00, 0x78])
        XCTAssertEqual(internalClock?.external, false)
        XCTAssertEqual(internalClock?.bpm, 120)

        let externalClock = G2UsbProtocol.decodeSysClockInfo([0x00, 0x01, 0x2C])
        XCTAssertEqual(externalClock?.external, true)
        XCTAssertEqual(externalClock?.bpm, 300)

        XCTAssertNil(G2UsbProtocol.decodeSysClockInfo([0x00, 0x01]))
    }

    // MARK: - Strona parametrów (0x2D / 0x1E / 0x58 / 0x59)

    /// Parameter Page Focus (WriteStream) → `Initialize(0x2d, 0, 1)` i jeden bajt strony.
    /// Typ 0 = zapis z potwierdzeniem, kontekst patcha → `COMMAND_REQ | COMMAND_SLOT`.
    func testParameterPageFocusPayloadCarriesSlotAndPage() {
        XCTAssertEqual(G2UsbProtocol.parameterPageFocusPayload(slot: 2, version: 0x12, page: 7),
                       [0x01, 0x2A, 0x12, 0x2D, 0x07])
    }

    /// Wersja globalna należy do performance'u (`CMolecule::CMolecule(this, 3)`), więc
    /// idzie jako komenda systemowa — tak samo jak zegar główny.
    func testGlobalParameterPageFocusPayloadIsSystemCommand() {
        XCTAssertEqual(G2UsbProtocol.globalParameterPageFocusPayload(version: 0x41, page: 14),
                       [0x01, 0x2C, 0x41, 0x1E, 0x0E])
    }

    func testParameterPageFocusRequestPayloads() {
        XCTAssertEqual(G2UsbProtocol.parameterPageFocusRequestPayload(slot: 1, version: 0x12),
                       [0x01, 0x29, 0x12, 0x58])
        XCTAssertEqual(G2UsbProtocol.globalParameterPageFocusRequestPayload(),
                       [0x01, 0x2C, 0x00, 0x59])
    }

    /// Piętnaście stron to twarda granica — `SetFocusedParameterPage` sprawdza
    /// `strona / 3 < 5` i wyższego numeru nie przyjmuje.
    func testDecodeParameterPageFocusRejectsPagesAboveFourteen() {
        XCTAssertEqual(G2UsbProtocol.decodeParameterPageFocus([0x00]), 0)
        XCTAssertEqual(G2UsbProtocol.decodeParameterPageFocus([0x0E]), 14)
        XCTAssertNil(G2UsbProtocol.decodeParameterPageFocus([0x0F]))
        XCTAssertNil(G2UsbProtocol.decodeParameterPageFocus([]))
    }

    /// Global Pages to trzecie pole tej samej komendy `0x3F` co tempo i Run
    /// (Performance Header Param(2, …)), więc dekodery muszą się rozchodzić po indeksie.
    func testGlobalPagesSharesTheMasterClockCommand() {
        XCTAssertEqual(G2UsbProtocol.setGlobalPagesPayload(enabled: true, version: 0x41),
                       [0x01, 0x2C, 0x41, 0x3F, 0xFF, 0x02, 0x01])
        XCTAssertEqual(G2UsbProtocol.decodeGlobalPages([0xFF, 0x02, 0x01]), true)
        XCTAssertEqual(G2UsbProtocol.decodeGlobalPages([0xFF, 0x02, 0x00]), false)
        XCTAssertNil(G2UsbProtocol.decodeGlobalPages([0xFF, 0x01, 0x79]))
        XCTAssertNil(G2UsbProtocol.decodeMasterClock([0xFF, 0x02, 0x01]))
    }

    /// Ani `0x2D`, ani `0x1E` nie mogą trafić na listę powiadomień — urządzenie odpowiada
    /// nimi na pytania `0x58`/`0x59`, a lista przykrywa bit odpowiedzi z nagłówka (ten sam
    /// błąd co przy `0x5D`). Zgłoszenia z własnej inicjatywy i tak przechodzą, bo
    /// rozstrzyga je `isSynthInitiated`.
    func testParameterPageFocusIsNotTreatedAsUnsolicited() {
        XCTAssertFalse(G2UsbProtocol.unsolicitedSubCommands
            .contains(G2UsbProtocol.subResponseParameterPageFocus))
        XCTAssertFalse(G2UsbProtocol.unsolicitedSubCommands
            .contains(G2UsbProtocol.subResponseGlobalParameterPageFocus))
    }

    /// `0x5D` NIE moze byc na liscie powiadomien: urzadzenie odpowiada nim na pytanie
    /// `0x3B`, a lista przykrywa bit odpowiedzi z naglowka — wpis kasowal cala odpowiedz
    /// i stan zegara nigdy nie docieral. Zmierzone na zywym G2 2026-09-05.
    func testSysClockInfoIsNotTreatedAsUnsolicited() {
        XCTAssertFalse(G2UsbProtocol.unsolicitedSubCommands.contains(G2UsbProtocol.subSysClockInfoResponse))
    }

    /// Prawdziwa odpowiedz z Norda na `01 2C 41 3B`, zlapana sonda 2026-09-05:
    /// bit odpowiedzi ustawiony (`0x0C & 0x08`), payload `01 00 78` = zegar wewnetrzny,
    /// 120 BPM. Rozklada sie dokladnie tak, jak przewidywal oryginalny edytor.
    func testSysClockInfoResponseFromRealDevice() {
        let decoded = G2UsbProtocol.decodeResponseBody([0x01, 0x0C, 0x00, 0x5D, 0x01, 0x00, 0x78])
        XCTAssertEqual(decoded?.subCommand, G2UsbProtocol.subSysClockInfoResponse)
        XCTAssertEqual(decoded?.isSynthInitiated, false)
        let info = G2UsbProtocol.decodeSysClockInfo(decoded?.payload ?? [])
        XCTAssertEqual(info?.external, false)
        XCTAssertEqual(info?.bpm, 120)
    }

    // MARK: - Numer sesji slotu (0x36)

    func testPatchVersionDecodesSlotAndSession() {
        let decoded = G2UsbProtocol.decodePatchVersion([0x03, 0x01])
        XCTAssertEqual(decoded?.slot, 3)
        XCTAssertEqual(decoded?.version, 1)
        let session = G2UsbProtocol.decodePatchVersion([0x00, 0x13])
        XCTAssertEqual(session?.slot, 0)
        XCTAssertEqual(session?.version, 0x13)
    }

    /// Payload, który numerem sesji NIE jest, musi zostać odrzucony — inaczej jego pierwszy
    /// bajt szedł prosto w `slotVersions[…]`. Tak padła aplikacja przy zmianie patcha na
    /// froncie Norda: w oczekiwanie na 0x36 wpadła odpowiedź 0x27 z nazwą patcha
    /// („WTabXShapeSynM1"), czyli „slot 0x57" → `Index out of range`.
    func testPatchVersionRejectsPayloadThatIsNotASlotNumber() {
        XCTAssertNil(G2UsbProtocol.decodePatchVersion(Array("WT".utf8)))
        XCTAssertNil(G2UsbProtocol.decodePatchVersion([0x04, 0x00]))
        XCTAssertNil(G2UsbProtocol.decodePatchVersion([0x02]))
        XCTAssertNil(G2UsbProtocol.decodePatchVersion([]))
    }

    // MARK: - Pakiet „embedded" niesie CRC w zapowiedzianej długości

    /// Surowe bajty ze sprzętu (2026-09-05): potwierdzenie komendy zegara. Nagłówek `0x62`
    /// zapowiada 6 bajtów, a treść to cztery bajty (`01 0C 00 7F`) plus suma kontrolna —
    /// przed poprawką te dwa bajty sumy udawały payload odpowiedzi `OK`.
    func testEmbeddedOkResponseHasCrcStripped() throws {
        let interrupt: [UInt8] = [0x62, 0x01, 0x0C, 0x00, 0x7F, 0x8C, 0xAD] + [UInt8](repeating: 0, count: 9)
        let body = G2UsbProtocol.embeddedBody(interrupt, dataLength: 6)
        XCTAssertEqual(body, [0x01, 0x0C, 0x00, 0x7F])
        let decoded = try G2UsbProtocol.decodeResponseBody(XCTUnwrap(body))
        XCTAssertEqual(decoded?.subCommand, G2UsbProtocol.subResponseOK)
        XCTAssertEqual(decoded?.payload, [], "payload OK musi być pusty — 8C AD to CRC, nie dane")
    }

    /// Ta sama zasada na powiadomieniu o zegarze: trzy bajty danych, dziewięć bajtów ciała.
    func testEmbeddedSysClockInfoHasCrcStripped() throws {
        let interrupt: [UInt8] = [0x92, 0x01, 0x04, 0x00, 0x5D, 0x01, 0x00, 0x78, 0x3A, 0xD2] + [UInt8](repeating: 0, count: 6)
        let body = G2UsbProtocol.embeddedBody(interrupt, dataLength: 9)
        let decoded = try G2UsbProtocol.decodeResponseBody(XCTUnwrap(body))
        XCTAssertEqual(decoded?.subCommand, G2UsbProtocol.subSysClockInfoResponse)
        XCTAssertEqual(decoded?.payload, [0x01, 0x00, 0x78])
        XCTAssertTrue(try XCTUnwrap(decoded?.isSynthInitiated), "bajt 0x04 = Nord odezwał się sam")
        let info = try G2UsbProtocol.decodeSysClockInfo(XCTUnwrap(decoded?.payload))
        XCTAssertEqual(info?.external, false)
        XCTAssertEqual(info?.bpm, 120)
    }

    func testEmbeddedBodyRejectsBadCrc() {
        let interrupt: [UInt8] = [0x62, 0x01, 0x0C, 0x00, 0x7F, 0x8C, 0xAE] + [UInt8](repeating: 0, count: 9)
        XCTAssertNil(G2UsbProtocol.embeddedBody(interrupt, dataLength: 6))
    }

    // MARK: - Przedstawienie się urządzenia (odpowiedź na 0x80)

    /// Kolejność pól za Synth Port (CheckVersionMessage): znacznik `0x0A`, potem numer
    /// modelu. Numery są te same, które oryginał mapuje na `ESynthModel`.
    func testInitResponseCarriesModelAndFirmware() throws {
        // [0x80][0x0A][model=3 → Engine][tryb][2 bajty][firmware 0x0078 = 120 = V1.20]
        let body: [UInt8] = [0x80, 0x0A, 0x03, 0x00, 0x00, 0x00, 0x00, 0x78, 0x00, 0x12]
        let decoded = try XCTUnwrap(G2UsbProtocol.decodeResponseBody(body))
        XCTAssertEqual(decoded.responseType, G2UsbProtocol.responseTypeInit)
        let identity = try XCTUnwrap(G2UsbProtocol.decodeDeviceIdentity(decoded.payload))
        XCTAssertEqual(identity.model, .modularG2Engine)
        XCTAssertEqual(identity.displayName, "Modular G2 Engine")
        XCTAssertEqual(identity.firmware, 120)
        XCTAssertEqual(identity.firmwareText, "V1.20")
    }

    /// Bez znacznika `0x0A` to nie jest przedstawienie się — oryginał też wtedy odpuszcza,
    /// zamiast wziąć kolejny bajt za numer modelu.
    func testInitResponseWithoutMarkerIsNotAnIdentity() {
        XCTAssertNil(G2UsbProtocol.decodeDeviceIdentity([0x00, 0x03]))
        XCTAssertNil(G2UsbProtocol.decodeDeviceIdentity([]))
    }

    /// Krótsza odpowiedź nadal daje model — firmware jest wtedy nieznany, ale to model
    /// decyduje o zachowaniu edytora.
    func testShortInitResponseStillYieldsTheModel() throws {
        let identity = try XCTUnwrap(G2UsbProtocol.decodeDeviceIdentity([0x0A, 0x01]))
        XCTAssertEqual(identity.model, .modularG2X)
        XCTAssertNil(identity.firmware)
        XCTAssertNil(identity.firmwareText)
    }

    /// Koła globalne ma wyłącznie G2X — na tym oryginał opiera źródło morfu w nowym patchu
    /// (`CSynth::HasGlobalModulationWheels`, przesłonięte tylko w Modular G2V).
    func testOnlyTheSixtyOneKeyModelHasGlobalWheels() {
        let withWheels = G2UsbProtocol.DeviceModel.allCases.filter(\.hasGlobalModulationWheels)
        XCTAssertEqual(withWheels, [.modularG2X])
    }

    /// Nieznany numer modelu nie może wywrócić połączenia — zostaje „Unknown model".
    func testUnknownModelNumberIsTolerated() throws {
        let identity = try XCTUnwrap(G2UsbProtocol.decodeDeviceIdentity([0x0A, 0x7F]))
        XCTAssertNil(identity.model)
        XCTAssertEqual(identity.displayName, "Unknown model")
    }

    /// Odpowiedź na zrzut całego performance'u — **bajty zmierzone na G2 37, firmware 1.62,
    /// 2026-09-10**. Nord oddaje numery sesji pięciu rzeczy naraz: czterech slotów
    /// i performance'u (numer 4). Cztery późniejsze zapytania `0x35` dały te same numery.
    func testPerformanceDumpAnswerCarriesFiveSessionNumbers() {
        let payload: [UInt8] = [0x00, 0x0E, 0x36, 0x01, 0x09, 0x36, 0x02, 0x09,
                                0x36, 0x03, 0x09, 0x36, 0x04, 0x01]
        let versions = G2UsbProtocol.decodePatchVersions(payload)
        XCTAssertEqual(versions.map(\.slot), [0, 1, 2, 3, 4])
        XCTAssertEqual(versions.map(\.version), [0x0E, 0x09, 0x09, 0x09, 0x01])
    }

    /// Ta sama liczba `0x36` bywa odpowiedzią na jeden slot — wtedy rekord jest jeden
    /// i nic po nim nie leci.
    func testSingleSlotVersionAnswerDecodesAsOneRecord() {
        XCTAssertEqual(G2UsbProtocol.decodePatchVersions([0x02, 0x11]).count, 1)
        XCTAssertTrue(G2UsbProtocol.decodePatchVersions([0x02]).isEmpty)
    }

    /// `0x29` przychodzi z dwóch stron: jako odpowiedź na `0x10` i jako komunikat, który
    /// Nord wysyła SAM po każdej zmianie w nagłówku performance'u. Wpisanie go na listę
    /// „samorzutnych" zabrałoby odpowiedź temu, kto o nią poprosił — dokładnie ten sam
    /// błąd, który skasował kiedyś odczyt zegara `0x5D`.
    func testPerformanceHeaderIsNotTreatedAsUnsolicited() {
        XCTAssertFalse(G2UsbProtocol.unsolicitedSubCommands
            .contains(G2UsbProtocol.subPerformanceNameResponse))
    }

    // MARK: - Gałki globalne (0x5E → 0x5F)

    func testGlobalKnobMapRequestMatchesOriginal() {
        XCTAssertEqual(G2UsbProtocol.globalKnobMapRequestPayload(), [0x01, 0x2C, 0x41, 0x5E])
    }

    /// Odpowiedź niesie sekcję w układzie pliku `.prf2`: to, co Nord przyśle, ma po
    /// rozbiorze dać te same przypisania, które zapis pliku zamieni z powrotem w bajty.
    func testGlobalKnobMapResponseRoundTripsThroughTheFileSection() throws {
        var settings = G2PerformanceSettings()
        settings.globalKnobAssignments[0] = G2GlobalKnobAssignment(slot: 2, location: 1, moduleID: 7, paramIndex: 3)
        settings.globalKnobAssignments[119] = G2GlobalKnobAssignment(slot: 0, location: 0, moduleID: 1, paramIndex: 0)
        let file = try PatchParser.saveAll(originalData: PatchParser.emptyPerformanceFile,
                                           patches: Array(repeating: G2Patch(), count: 4),
                                           performance: settings)
        let section = try PatchParser.performanceKnobMapStream(fileData: file)

        let payload = Array(section.dropFirst()) + [0x00, 0x00] // ogon ramki za sekcją
        let received = try XCTUnwrap(G2UsbProtocol.globalKnobMapSection(payload: payload))
        XCTAssertEqual(received, section)

        var parsed = G2PerformanceSettings()
        try PatchParser.parseUsbGlobalKnobMap(section: received, into: &parsed)
        XCTAssertEqual(parsed.globalKnobAssignments, settings.globalKnobAssignments)
        XCTAssertFalse(G2UsbProtocol.unsolicitedSubCommands.contains(G2UsbProtocol.subGlobalKnobMap))
    }

    func testTruncatedGlobalKnobMapIsRejected() {
        XCTAssertNil(G2UsbProtocol.globalKnobMapSection(payload: [0x00, 0x11, 0x00]))
    }
}
