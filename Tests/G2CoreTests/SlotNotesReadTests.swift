// SlotNotesReadTests.swift
// Slot przeczytany z Norda (zmiana patcha na froncie, Get Active Slot from G2, przejęcie przy
// połączeniu) ma przynieść notatki patcha. Zrzut slotu `0x3C` notatnika nie niesie — trzeba
// osobno zapytać `0x6E` → `0x6F`, inaczej Save zapisywał `.pch2`/`.prf2` bez notatek (#177).

import CLibUsb
@testable import G2Core
import XCTest

/// Transport w pamięci: na każdą wysłaną ramkę oddaje kolejną odpowiedź z `answers`
/// (pakiet 0x81 i ewentualne dane 0x82), jak urządzenie.
private final class ScriptedTransport: G2Transport {
    var queues: [UInt8: [[UInt8]]] = [:]
    var answers: [(interrupt: [UInt8], extended: [UInt8]?)] = []
    var written: [[UInt8]] = []

    func open() throws {}
    func close() {}

    func write(_ frame: inout [UInt8], endpoint _: UInt8, timeout _: UInt32) -> (code: Int32, length: Int32) {
        written.append(frame)
        if !answers.isEmpty {
            let answer = answers.removeFirst()
            queues[G2UsbProtocol.endpointInterrupt, default: []].append(answer.interrupt)
            if let extended = answer.extended {
                queues[G2UsbProtocol.endpointExtended, default: []].append(extended)
            }
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

final class SlotNotesReadTests: XCTestCase {
    /// Odpowiedź urządzenia z treścią `body` (`[0x01][bajt odpowiedzi][wersja][podkomenda]…`)
    /// i jej CRC: krótka w samym pakiecie 0x81, dłuższa zapowiedziana na 0x81 i wysłana 0x82.
    private func answer(_ body: [UInt8]) -> (interrupt: [UInt8], extended: [UInt8]?) {
        let crc = G2UsbProtocol.crc16(body)
        let data = body + [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        if data.count < 16 {
            let packet = [UInt8(data.count << 4) | 0x02] + data
            return (packet + [UInt8](repeating: 0, count: 16 - packet.count), nil)
        }
        var announcement = [UInt8](repeating: 0, count: 16)
        announcement[0] = 0x01
        announcement[1] = UInt8(data.count >> 8)
        announcement[2] = UInt8(data.count & 0xFF)
        return (announcement, data)
    }

    /// Sekcje binarne `.pch2` bez notatnika `0x6F` — tak jak oddaje je Nord w `0x3C`.
    private func slotDumpWithoutNotes() throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/EnvFx.pch2")
        let stream = try PatchParser.slotSectionStream(fileData: Data(contentsOf: url), slot: 0)
        var result: [UInt8] = []
        var offset = 0
        while offset + 3 <= stream.count {
            let end = offset + 3 + (Int(stream[offset + 1]) << 8 | Int(stream[offset + 2]))
            if stream[offset] != G2UsbProtocol.subTextpad { result += stream[offset ..< end] }
            offset = end
        }
        return result
    }

    func testReloadedSlotBringsItsNotes() async throws {
        let notes = "Mod wheel opens the filter"
        let slotA: UInt8 = 0x08 // flaga odpowiedzi | slot 0
        let transport = ScriptedTransport()
        transport.answers = try [
            answer([0x01, 0x0C, 0x00, 0x7F]), // Stop
            answer([0x01, slotA, 0x00, 0x36, 0x00, 0x05]), // numer sesji slotu A
            answer([0x01, slotA, 0x05] + slotDumpWithoutNotes()), // zawartość 0x3C
            answer([0x01, slotA, 0x05, 0x27] + Array("EnvFx".utf8) + [UInt8](repeating: 0, count: 11)),
            answer([0x01, slotA, 0x05, 0x6F, 0x00, UInt8(notes.utf8.count)] + Array(notes.utf8)),
            answer([0x01, 0x0C, 0x00, 0x7F]), // Start
        ]
        let manager = G2MidiManager()
        await manager.attachTransportForTesting(transport)

        let patch = try await manager.reloadPatch(slot: 0)

        XCTAssertEqual(patch.name, "EnvFx")
        XCTAssertFalse(patch.voiceModules.isEmpty && patch.fxModules.isEmpty, "zawartość slotu rozczytana")
        XCTAssertEqual(patch.notes, notes, "bez 0x6E Save Patch zapisywał plik bez notatek")
    }
}
