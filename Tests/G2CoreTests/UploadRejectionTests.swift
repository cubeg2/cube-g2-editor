// UploadRejectionTests.swift
// Nord nie przyjął wysłanego patcha (#143): odmowa ma być rozpoznana od razu, pokazana
// użytkownikowi, a slot nie może zostać po cichu niemy — następna zmiana wysyła go od nowa.

import CLibUsb
@testable import G2Core
@testable import G2EditorCore
import XCTest

/// Transport w pamięci, który odpowiada jak urządzenie: pakiety z `answers` trafiają na
/// endpoint przerwań dopiero po wysłaniu kolejnej ramki. Wystawione z góry zjadałaby je
/// pętla nasłuchu, która między komendami czyta ten sam endpoint.
private final class AnsweringTransport: G2Transport {
    var queues: [UInt8: [[UInt8]]] = [:]
    var answers: [[[UInt8]]] = []
    var written: [[UInt8]] = []

    func open() throws {}
    func close() {}

    func write(_ frame: inout [UInt8], endpoint _: UInt8, timeout _: UInt32) -> (code: Int32, length: Int32) {
        written.append(frame)
        if !answers.isEmpty {
            queues[G2UsbProtocol.endpointInterrupt, default: []] += answers.removeFirst()
        }
        return (0, Int32(frame.count))
    }

    func read(_ buffer: inout [UInt8], endpoint: UInt8, timeout _: UInt32) -> (code: Int32, length: Int32) {
        guard var pending = queues[endpoint], !pending.isEmpty else {
            return (LIBUSB_ERROR_TIMEOUT.rawValue, 0)
        }
        let packet = pending.removeFirst()
        queues[endpoint] = pending
        for (index, byte) in packet.enumerated() {
            buffer[index] = byte
        }
        return (0, Int32(packet.count))
    }

    func clearHalt(endpoint _: UInt8) -> Int32 {
        0
    }

    func describeEndpoints() -> String {
        "scripted"
    }
}

@MainActor
final class UploadRejectionTests: XCTestCase {
    private func padded(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [UInt8](repeating: 0, count: 16 - bytes.count)
    }

    /// Pakiet „embedded" z treścią i jej CRC — tak, jak nadaje go urządzenie.
    private func embedded(_ body: [UInt8]) -> [UInt8] {
        let crc = G2UsbProtocol.crc16(body)
        let data = body + [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        return padded([UInt8(data.count << 4) | 0x02] + data)
    }

    /// Pakiety z ~/Library/Logs/G2Editor/usb.log, 2026-10-20 16:10:09–10 (Virtual G2).
    private var okFrame: [UInt8] {
        padded([0x62, 0x01, 0x0C, 0x00, 0x7F, 0x8C, 0xAD])
    }

    /// Odmowa BEZ flagi odpowiedzi (bajt 0x00), slot 0, kod 03.
    private var rejection: [UInt8] {
        padded([0x72, 0x01, 0x00, 0x01, 0x7E, 0x03, 0x86, 0x54])
    }

    /// Mimo odmowy Nord podbija numer sesji slotu A: 0 → 2.
    private var versionChange: [UInt8] {
        padded([0x82, 0x01, 0x04, 0x40, 0x38, 0x00, 0x02, 0xEE, 0x7C])
    }

    private func patch(moduleCount: Int) -> G2Patch {
        var patch = G2Patch()
        patch.voiceModules = (1 ... moduleCount).map { G2Module(id: $0, typeID: 4, area: .voice) }
        return patch
    }

    func testRejectedUploadIsShownAndTheNextChangeResendsTheWholePatch() async {
        let transport = AnsweringTransport()
        // Numer sesji przed odmową, nie za nią jak w logu — inaczej to, czy dotrze przed
        // następną komendą, zależy od pętli nasłuchu, a nie od edytora.
        transport.answers = [[okFrame], [versionChange, rejection]]
        let manager = G2MidiManager()
        await manager.attachTransportForTesting(transport)
        let device = DeviceConnection(connectedTo: manager)

        let started = Date()
        await device.upload(patches: [patch(moduleCount: 1)], activeSlot: 0)

        // Odmowa rozpoznana od razu, a nie po 10 s czekania na potwierdzenie.
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
        XCTAssertNotNil(device.uploadFailure, "użytkownik ma zobaczyć, że Nord nie przyjął patcha")
        XCTAssertTrue(device.uploadFailure?.contains("did not accept") == true,
                      "odmowa dostaje tekst o odmowie, nie radę o zawieszonym Nordzie")
        XCTAssertFalse(device.isSlotConfirmed(0))
        XCTAssertEqual(device.status, .connected, "odrzucony patch to nie zerwane połączenie")
        XCTAssertEqual(transport.written.count, 2, "SelectSlot + SetPatch — bez włączania niepotwierdzonego slotu")

        // Gałka do niepotwierdzonego slotu nie idzie — pojedzie z całym patchem.
        device.sendParameterLive(slot: 0, area: .voice, moduleID: 1, paramIndex: 0, value: 64, variation: 0)
        XCTAssertEqual(transport.written.count, 2)

        // Poprawiony patch: zamiast różnicy leci cały slot (0x37), tym razem przyjęty.
        let sessionReply = embedded([0x01, 0x08, 0x40, 0x36, 0x00, 0x03])
        transport.answers = [[okFrame], [sessionReply], [okFrame], [okFrame]]
        device.syncStructure(slot: 0, patch: patch(moduleCount: 2))
        await device.awaitStructureSyncForTesting()

        let resend = transport.written[3]
        XCTAssertEqual(resend[5], 0x37, "zmiana na niepotwierdzonym slocie wysyła cały patch")
        XCTAssertEqual(resend[4], 0x02, "z numerem sesji, który Nord ogłosił po odmowie")
        XCTAssertEqual(transport.written.count, 6, "SelectSlot, SetPatch, selekcja slotów, SelectSlot")
        XCTAssertNil(device.uploadFailure)
        XCTAssertTrue(device.isSlotConfirmed(0))
    }

    /// #167: Nord nie nadaje `0x72` dla slotu, który nie gra, więc po wgraniu nowego patcha
    /// do takiego slotu okno DSP Load pokazywało koszt POPRZEDNIEGO patcha. Wysyłka kasuje
    /// odczyt slotu, do którego idzie — do nowego raportu wraca szacunek. Inne sloty zostają.
    func testUploadDropsTheOldDeviceReadingOfTheReplacedSlot() async {
        let transport = AnsweringTransport()
        transport.answers = Array(repeating: [okFrame], count: 6)
        let manager = G2MidiManager()
        await manager.attachTransportForTesting(transport)
        let device = DeviceConnection(connectedTo: manager)
        let old = G2PatchLoad.estimate(area: .voice, modules: patch(moduleCount: 3).voiceModules)
        device.setPatchLoadForTesting(old, slot: 0)
        device.setPatchLoadForTesting(old, slot: 1)

        await device.upload(patches: [patch(moduleCount: 1)], activeSlot: 0)

        XCTAssertTrue(device.isSlotConfirmed(0))
        XCTAssertNil(device.patchLoad(slot: 0, area: .voice), "odczyt starego patcha nie może zostać przy nowym")
        XCTAssertEqual(device.patchLoad(slot: 1, area: .voice), old, "slot, do którego nic nie szło, zachowuje raport")
    }

    /// #165: odrzucony zrzut całego performance'u (`0x1A`) i tak podbija numery sesji czterech
    /// slotów. Po błędzie rusza wysyłka slot po slocie — ma mieć nowe numery, inaczej Nord
    /// zapisałby slotom same nazwy (#136). Odmowa to bajty z logu emulatora fw 1.62, 2026-10-28.
    func testRejectedPerformanceDumpRefreshesSlotSessionNumbers() async {
        let transport = AnsweringTransport()
        let dumpRejected = padded([0x72, 0x01, 0x00, 0x03, 0x7E, 0x03, 0xE8, 0x34])
        let sessions = (UInt8(0) ..< 4).map { [embedded([0x01, 0x0C, 0x40, 0x36, $0, 0x04])] }
        transport.answers = [[okFrame], [dumpRejected]] + sessions + [[okFrame]]
        let manager = G2MidiManager()
        await manager.attachTransportForTesting(transport)

        do {
            try await manager.sendCompletePerformanceDump(
                name: "Test", headerSection: [0x11, 0x00, 0x00], slotStreams: [[], [], [], []],
                knobMapSection: [], patches: []
            )
            XCTFail("odmowa zrzutu ma się skończyć błędem — to on włącza drogę slot po slocie")
        } catch {}

        for slot in 0 ..< 4 {
            let version = await manager.slotVersionForTesting(slot)
            XCTAssertEqual(version, 0x04, "slot \(slot): numer sesji ogłoszony przez Norda po odmowie")
        }
    }

    /// #157: Nord zamilkł przy `0x37` (bez odmowy) i trzeba go było wyłączyć — a pasek
    /// radził skrócić notatkę, której patch nie miał. Milczenie dostaje radę o restarcie.
    /// Sama wiadomość, bez transportu: prawdziwe milczenie kosztowałoby 10 s czekania.
    func testSilentDeviceGetsRestartAdviceInsteadOfTheTextpadHint() {
        let silent = DeviceConnection.uploadFailureMessage(
            slot: 0, error: G2UsbError.badResponse("the device did not acknowledge the patch upload to slot 0")
        )
        XCTAssertTrue(silent.hasPrefix("Slot A:"))
        XCTAssertTrue(silent.contains("switch the G2 off and on"))
        XCTAssertFalse(silent.contains("Textpad"))

        let refused = DeviceConnection.uploadFailureMessage(
            slot: 1, error: G2UsbError.rejected("the patch upload to slot 1")
        )
        XCTAssertTrue(refused.hasPrefix("Slot B:"))
        XCTAssertTrue(refused.contains("Textpad"))
    }
}
