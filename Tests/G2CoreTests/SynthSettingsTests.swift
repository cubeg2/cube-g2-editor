// SynthSettingsTests.swift
// Ustawienia urządzenia (`0x02` → `0x03`). Wzorzec odpowiedzi złożony z układu bajtów
// Synth Map (ReadStream) (oryginalny edytor Clavii) i ustawiony tak, żeby odpowiadał
// ZDJĘCIU oryginalnego okna „Synth Settings – Port 1" (2026-09-11): Nord nazywa się
// „NORD MODULAR G2", sloty A–D mają kanały 1–4 i wszystkie są aktywne, kanał globalny 1,
// SysEx ID 1, strojenie 440.00 Hz, pedał „Open", wzmocnienie x1.00, Memory Protect
// zaznaczone → [[Docs/usb/synth-settings]].

@testable import G2Core
import XCTest

final class SynthSettingsTests: XCTestCase {
    /// Bajty za nazwą — dokładnie te, które składają się na stan ze zdjęcia.
    private static let bodyFromPhoto: [UInt8] = [
        0x00, // +0  tryb: Patch (bit 7 = 0)
        0x00, // +1  nieznane
        0x00, // +2  bank bieżącego performance'u
        0x00, // +3  numer bieżącego performance'u
        0x80, // +4  Memory Protect
        0x00, 0x01, 0x02, 0x03, // +5…+8 kanały slotów A–D (pokazywane jako 1–4)
        0x00, // +9  kanał globalny (pokazywany jako 1)
        0x00, // +10 SysEx ID (pokazywany jako 1)
        0x80, // +11 Local On
        0x03, // +12 Program Change: Receive + Send
        0x03, // +13 Controllers: Receive + Send
        0x00, // +14 Send Clock / Ignore External Clock — oba wyłączone
        0x00, // +15 centy
        0x00, // +16 Global Octave Shift wyłączony
        0x00, // +17 przesunięcie oktawy
        0x00, // +18 półtony
        0x00, // +19 wypełniacz
        0x40, // +20 polaryzacja pedału „Open" (bit 7 = 0); bit 6 stoi na 1 w oryginale
        0x00, // +21 Control Pedal Gain → x1.00
    ] + [UInt8](repeating: 0, count: 16) // ogon wypełniacza

    private static let payloadFromPhoto = Array("NORD MODULAR G2".utf8) + [0x00] + bodyFromPhoto

    // MARK: - Odczyt

    func testDecodesTheStateShownInTheOriginalWindow() throws {
        let settings = try XCTUnwrap(G2UsbProtocol.decodeSynthSettings(Self.payloadFromPhoto))

        XCTAssertEqual(settings.name, "NORD MODULAR G2")
        XCTAssertEqual(settings.slots.map(\.channel), [1, 2, 3, 4])
        XCTAssertEqual(settings.slots.map(\.active), [true, true, true, true])
        XCTAssertEqual(settings.globalChannel, 1)
        XCTAssertEqual(settings.sysExID, 1)
        XCTAssertTrue(settings.localOn)
        XCTAssertTrue(settings.memoryProtect)
        XCTAssertTrue(settings.programChangeReceive)
        XCTAssertTrue(settings.programChangeSend)
        XCTAssertTrue(settings.controllersReceive)
        XCTAssertTrue(settings.controllersSend)
        XCTAssertFalse(settings.sendClock)
        XCTAssertFalse(settings.ignoreExternalClock)
        XCTAssertFalse(settings.globalOctaveShiftEnabled)
        XCTAssertFalse(settings.pedalPolarityClosed)
        XCTAssertFalse(settings.performanceMode)
        XCTAssertEqual(settings.masterTuneHz, 440, accuracy: 0.001)
        XCTAssertEqual(settings.controlPedalGainLabel, "x1.00")
    }

    /// Kanał 0x10 to „ten slot nie słucha MIDI", a nie kanał numer 17.
    func testChannelSixteenMeansTheSlotIsNotListening() throws {
        var payload = Self.payloadFromPhoto
        let start = G2UsbProtocol.synthSettingsBodyStart(payload)
        payload[start + 6] = 0x10 // slot B
        payload[start + 9] = 0x10 // kanał globalny → „Off"
        payload[start + 10] = 0x10 // SysEx ID → „All"

        let settings = try XCTUnwrap(G2UsbProtocol.decodeSynthSettings(payload))
        XCTAssertEqual(settings.slots.map(\.active), [true, false, true, true])
        XCTAssertNil(settings.globalChannel)
        XCTAssertNil(settings.sysExID)
    }

    /// Strojenie jest ze znakiem — bajt 0xFF to −1 centa, nie 255.
    func testTuneIsSigned() throws {
        var payload = Self.payloadFromPhoto
        let start = G2UsbProtocol.synthSettingsBodyStart(payload)
        payload[start + 15] = UInt8(bitPattern: -50) // centy
        payload[start + 18] = UInt8(bitPattern: -2) // półtony
        payload[start + 17] = UInt8(bitPattern: -1) // przesunięcie oktawy

        let settings = try XCTUnwrap(G2UsbProtocol.decodeSynthSettings(payload))
        XCTAssertEqual(settings.tuneCent, -50)
        XCTAssertEqual(settings.tuneSemi, -2)
        XCTAssertEqual(settings.globalOctaveShift, -1)
        XCTAssertLessThan(settings.masterTuneHz, 440)
    }

    /// Bity zegara siedzą tam, gdzie mówi [[Docs/ui/master-clock]] §6.4 — `0x40` i `0x20`.
    func testClockBitsMatchTheDocumentedPositions() throws {
        var payload = Self.payloadFromPhoto
        let start = G2UsbProtocol.synthSettingsBodyStart(payload)
        payload[start + 14] = 0x60

        let settings = try XCTUnwrap(G2UsbProtocol.decodeSynthSettings(payload))
        XCTAssertTrue(settings.sendClock)
        XCTAssertTrue(settings.ignoreExternalClock)
    }

    /// Nazwa ma zmienną długość: pełne 16 znaków idzie bez terminatora.
    func testFullLengthNameHasNoTerminator() throws {
        let name = "ABCDEFGHIJKLMNOP" // dokładnie 16 znaków
        let payload = Array(name.utf8) + Self.bodyFromPhoto
        let settings = try XCTUnwrap(G2UsbProtocol.decodeSynthSettings(payload))
        XCTAssertEqual(settings.name, name)
        XCTAssertEqual(settings.globalChannel, 1) // reszta pól nie przesunęła się o bajt
    }

    func testTooShortPayloadIsRejected() {
        XCTAssertNil(G2UsbProtocol.decodeSynthSettings(Array("NORD".utf8) + [0x00, 0x00]))
    }

    /// Bit trybu czytany starą drogą (`decodePerformanceMode`, używaną przy łączeniu)
    /// i nową muszą mówić to samo — obie znajdują koniec nazwy tak samo.
    func testPerformanceModeAgreesWithTheFullDecoder() throws {
        var payload = Self.payloadFromPhoto
        let start = G2UsbProtocol.synthSettingsBodyStart(payload)
        payload[start] = 0x80

        let settings = try XCTUnwrap(G2UsbProtocol.decodeSynthSettings(payload))
        XCTAssertTrue(settings.performanceMode)
        XCTAssertEqual(G2UsbProtocol.decodePerformanceMode(payload), settings.performanceMode)
    }

    // MARK: - Zapis

    /// Zapis bez zmian musi oddać bajt w bajt to, co przyszło — inaczej wysyłalibyśmy
    /// Nordowi coś innego, niż on sam o sobie powiedział.
    func testWritingBackUnchangedSettingsReproducesThePayload() throws {
        let settings = try XCTUnwrap(G2UsbProtocol.decodeSynthSettings(Self.payloadFromPhoto))
        let written = G2UsbProtocol.synthSettingsPayload(applying: settings,
                                                         to: Self.payloadFromPhoto)
        XCTAssertEqual(written, Self.payloadFromPhoto)
    }

    func testChangedFieldsSurviveTheRoundTrip() throws {
        var settings = try XCTUnwrap(G2UsbProtocol.decodeSynthSettings(Self.payloadFromPhoto))
        settings.name = "Studio G2"
        settings.slots[1].active = false
        settings.slots[2].channel = 11
        settings.globalChannel = nil
        settings.sysExID = 4
        settings.localOn = false
        settings.controllersSend = false
        settings.programChangeReceive = false
        settings.sendClock = true
        settings.tuneSemi = -3
        settings.tuneCent = 25
        settings.globalOctaveShiftEnabled = true
        settings.globalOctaveShift = 2
        settings.controlPedalGain = 64
        settings.pedalPolarityClosed = true
        settings.memoryProtect = false

        let written = try XCTUnwrap(G2UsbProtocol.synthSettingsPayload(applying: settings,
                                                                       to: Self.payloadFromPhoto))
        XCTAssertEqual(G2UsbProtocol.decodeSynthSettings(written), settings)
        XCTAssertEqual(G2UsbProtocol.decodeSynthSettings(written)?.controlPedalGainLabel, "x2.00")
    }

    /// Pola, których nie rozumiemy, mają zostać nietknięte — po to zapis przepisuje
    /// odpowiedź urządzenia zamiast budować komunikat od zera.
    func testUnknownBytesArePreserved() throws {
        var original = Self.payloadFromPhoto
        let start = G2UsbProtocol.synthSettingsBodyStart(original)
        original[start + 1] = 0x5A // nieznany bajt
        original[start + 2] = 0x07 // bank bieżącego performance'u
        original[start + 3] = 0x1F // numer bieżącego performance'u
        original[start + 19] = 0x33 // wypełniacz
        original[original.count - 1] = 0x77 // ogon

        var settings = try XCTUnwrap(G2UsbProtocol.decodeSynthSettings(original))
        settings.tuneCent = 10
        let written = try XCTUnwrap(G2UsbProtocol.synthSettingsPayload(applying: settings,
                                                                       to: original))

        XCTAssertEqual(written.count, original.count)
        XCTAssertEqual(written[start + 1], 0x5A)
        XCTAssertEqual(written[start + 2], 0x07)
        XCTAssertEqual(written[start + 3], 0x1F)
        XCTAssertEqual(written[start + 19], 0x33)
        XCTAssertEqual(written.last, 0x77)
        // Bit 6 bajtu polaryzacji (stała 1 u BVerhue i Clavii) przeżywa zapis.
        XCTAssertEqual(written[start + 20] & 0x40, 0x40)
    }

    /// Krótsza nazwa skraca komunikat o tyle znaków, ile ubyło — pole jest zmiennej długości.
    func testShorterNameShortensThePayload() throws {
        var settings = try XCTUnwrap(G2UsbProtocol.decodeSynthSettings(Self.payloadFromPhoto))
        settings.name = "G2"
        let written = try XCTUnwrap(G2UsbProtocol.synthSettingsPayload(applying: settings,
                                                                       to: Self.payloadFromPhoto))
        XCTAssertEqual(written.count, Self.payloadFromPhoto.count - "NORD MODULAR G2".count + 2)
        XCTAssertEqual(G2UsbProtocol.decodeSynthSettings(written)?.name, "G2")
    }

    /// Cała ramka: nagłówek komendy systemowej, bajt typu `0x03`, potem treść.
    func testFramePutsTheSectionByteBeforeTheBody() {
        let payload = G2UsbProtocol.setSynthSettingsPayload(body: Self.payloadFromPhoto)
        XCTAssertEqual(Array(payload.prefix(4)), [0x01, 0x2C, 0x41, 0x03])
        XCTAssertEqual(Array(payload.dropFirst(4)), Self.payloadFromPhoto)
    }
}
