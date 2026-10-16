// ExtendedStreamTests.swift
// Pary zapowiedź (0x81) / dane (0x82): komenda nie może zabierać danych, których
// zapowiedź czeka jeszcze w kolejce — a prawdziwie osierocone dane nadal ma usuwać.
// Zgłoszenie: 135 „rozjazdów strumienia" na przebiegu emulatora → [[Docs/context/bug-history]] #91.

import CLibUsb
@testable import G2Core
import XCTest

/// Transport w pamięci: kolejka pakietów na endpoint, odczyt pustej kolejki = timeout od razu.
private final class ScriptedTransport: G2Transport {
    var queues: [UInt8: [[UInt8]]] = [:]
    var written: [[UInt8]] = []

    func open() throws {}
    func close() {}

    func write(_ frame: inout [UInt8], endpoint _: UInt8, timeout _: UInt32) -> (code: Int32, length: Int32) {
        written.append(frame)
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

final class ExtendedStreamTests: XCTestCase {
    /// `SUB_RESPONSE_OK` z CRC — ramka zmierzona na sprzęcie 2026-09-05.
    private let okFrame: [UInt8] = [0x01, 0x0C, 0x00, 0x7F, 0x8C, 0xAD]

    private func announcement(length: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0x01
        bytes[1] = UInt8(length >> 8)
        bytes[2] = UInt8(length & 0xFF)
        return bytes
    }

    private func embedded(_ body: [UInt8]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = UInt8(body.count << 4) | 0x02
        for (index, byte) in body.enumerated() {
            bytes[1 + index] = byte
        }
        return bytes
    }

    /// Zapowiedź i jej dane leżą już w kolejkach, zanim komenda wystartuje (odpowiedź przyszła
    /// szybciej, niż edytor zdążył ją odczytać). Do 2026-09-14 czyszczenie 0x82 przed komendą
    /// zabierało te dane, zapowiedź zostawała bez pary i potwierdzenie ginęło.
    func testCommandDoesNotStealDataOfAQueuedAnnouncement() async throws {
        let transport = ScriptedTransport()
        transport.queues[G2UsbProtocol.endpointInterrupt] = [announcement(length: okFrame.count)]
        transport.queues[G2UsbProtocol.endpointExtended] = [okFrame]

        let manager = G2MidiManager()
        await manager.attachTransportForTesting(transport)

        try await manager.selectSlot(1)
        XCTAssertEqual(transport.queues[G2UsbProtocol.endpointExtended]?.count ?? 0, 0)
    }

    /// Od 2026-09-18 prawdziwy Nord chodzi na **tej samej** regule co emulator — odruchowe
    /// sprzątanie 0x82 przy każdej komendzie zniknęło, bo na sprzęcie okazało się gorsze
    /// (rozjazdy w 5 z 7 przebiegów wobec 0 z 4) → [[Docs/context/bug-history]] #91.
    /// Dane bez podejrzenia o osierocenie mają więc PRZETRWAĆ komendę.
    func testHardwareNowDrainsOnlyWhenOrphaned() async throws {
        let transport = ScriptedTransport()
        transport.queues[G2UsbProtocol.endpointInterrupt] = [embedded(okFrame)]
        transport.queues[G2UsbProtocol.endpointExtended] = [[0xDE, 0xAD, 0xBE, 0xEF]]

        let manager = G2MidiManager()
        await manager.attachTransportForTesting(transport, emulatorRules: true)

        try await manager.selectSlot(1)
        XCTAssertEqual(transport.queues[G2UsbProtocol.endpointExtended]?.count ?? 0, 1,
                       "bez podejrzenia o sierotę 0x82 zostaje nietknięte — to jest cała poprawka #91")
    }

    /// Prawdziwy rozjazd (dane krótsze niż zapowiedź) nadal kończy się opróżnieniem 0x82 —
    /// inaczej zostawiony payload blokowałby urządzenie (#53).
    func testMismatchStillDrainsLeftoverExtendedData() async throws {
        let transport = ScriptedTransport()
        let orphan: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        transport.queues[G2UsbProtocol.endpointInterrupt] = [announcement(length: 8), embedded(okFrame)]
        transport.queues[G2UsbProtocol.endpointExtended] = [okFrame, orphan]

        let manager = G2MidiManager()
        await manager.attachTransportForTesting(transport)

        try await manager.selectSlot(1)
        XCTAssertEqual(transport.queues[G2UsbProtocol.endpointExtended]?.count ?? 0, 0,
                       "po rozjeździe resynchronizacja ma zabrać zaległe dane z 0x82")
    }

    /// `0x3E` → `0x1F` z wersjami slotów. `0x1F` jest też na liście powiadomień, więc do
    /// 2026-10-15 trafiało do rozdania i przełączenie trybu kończyło się „brakiem
    /// potwierdzenia" po 3 s, choć Nord odpowiedział po 0,65 s.
    func testPerformanceModeAcceptsItsReleaseReply() async throws {
        // Ramka z usb.log 2026-10-15 01:39:19 (G2 37, fw 1.62), razem z CRC.
        let release: [UInt8] = [0x01, 0x0C, 0x40, 0x1F, 0x05, 0x36, 0x00, 0x10, 0x36, 0x01,
                                0x18, 0x36, 0x02, 0x12, 0x36, 0x03, 0x0C, 0xCE, 0xC4]
        let transport = ScriptedTransport()
        transport.queues[G2UsbProtocol.endpointInterrupt] = [announcement(length: release.count)]
        transport.queues[G2UsbProtocol.endpointExtended] = [release]

        let manager = G2MidiManager()
        await manager.attachTransportForTesting(transport)

        try await manager.setPerformanceMode(false)
        // #136: patch wysłany ze starą wersją Nord przyjmuje bez zawartości.
        var versions: [UInt8] = []
        for slot in 0 ..< 4 {
            await versions.append(manager.slotVersionForTesting(slot))
        }
        XCTAssertEqual(versions, [0x10, 0x18, 0x12, 0x0C])
    }
}

/// #129: po wgraniu performance'u lustro `patches[]` zostawało przy poprzedniej zawartości,
/// więc pierwsza zmiana „na żywo" kasowała cały slot i dodawała go od nowa.
final class PerformanceMirrorTests: XCTestCase {
    /// Ramki z logu emulatora 2026-09-28: `OK` dla Stop/Start i `0x36` z numerami sesji.
    private let okFrame: [UInt8] = [0x01, 0x0C, 0x00, 0x7F, 0x8C, 0xAD]
    private let versionsFrame: [UInt8] = [0x01, 0x0C, 0x40, 0x36, 0x00, 0x02, 0x36, 0x01, 0x01,
                                          0x36, 0x02, 0x01, 0x36, 0x03, 0x01, 0x36, 0x04, 0x01, 0xDA, 0xD6]

    private func embedded(_ body: [UInt8]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = UInt8(body.count << 4) | 0x02
        for (index, byte) in body.enumerated() {
            bytes[1 + index] = byte
        }
        return bytes
    }

    private func announcement(length: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0x01
        bytes[1] = UInt8(length >> 8)
        bytes[2] = UInt8(length & 0xFF)
        return bytes
    }

    func testPerformanceDumpUpdatesTheSlotMirror() async throws {
        let transport = ScriptedTransport()
        transport.queues[G2UsbProtocol.endpointInterrupt] = [
            embedded(okFrame), announcement(length: versionsFrame.count), embedded(okFrame),
        ]
        transport.queues[G2UsbProtocol.endpointExtended] = [versionsFrame]
        let manager = G2MidiManager()
        await manager.attachTransportForTesting(transport, emulatorRules: true)

        var slotA = G2Patch()
        slotA.voiceModules = [G2Module(id: 1, typeID: 1, area: .voice)]
        let slots = [slotA, G2Patch(), G2Patch(), G2Patch()]
        try await manager.sendCompletePerformanceDump(
            name: "Test", headerSection: [0x11, 0x00, 0x00],
            slotStreams: Array(repeating: [0x21, 0x00, 0x00], count: 4),
            knobMapSection: [0x5F, 0x00, 0x00], patches: slots
        )
        let writesAfterDump = transport.written.count

        let frames = try await manager.syncPatch(slotA, toSlot: 0)
        XCTAssertEqual(frames, 0, "urządzenie ma już ten patch — nie ma czego wysyłać")
        XCTAssertEqual(transport.written.count, writesAfterDump)
    }
}
