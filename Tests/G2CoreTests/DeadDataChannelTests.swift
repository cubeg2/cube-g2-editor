// DeadDataChannelTests.swift
// Nord zapowiada odpowiedź na 0x81, a kanał danych 0x82 nie oddaje już ani bajtu (#146).
// Od tej chwili żadna komenda nie przechodzi — edytor ma zerwać łącze i połączyć się od nowa
// (`tick` + reset USB), zamiast udawać, że patch dotarł do Norda.

import CLibUsb
@testable import G2Core
@testable import G2EditorCore
import XCTest

/// Transport w pamięci: na każdą wysłaną ramkę Nord „odpowiada" zapowiedzią 19 B na 0x81
/// (jak `0x3E` w usb.log testera, 2026-10-21 11:23:41), a 0x82 milczy.
private final class DeadDataChannelTransport: G2Transport {
    var queues: [UInt8: [[UInt8]]] = [:]
    var written: [[UInt8]] = []
    private(set) var closed = false
    private(set) var clearedEndpoints: [UInt8] = []
    /// Ile odpowiedzi zapowiadać — bez zapowiedzi zostaje gołe 0x82 (zgubiona zapowiedź).
    var announces = true
    /// Odpowiedź Norda na każdą ramkę zamiast gołej zapowiedzi: pakiet 0x81 i kawałki 0x82.
    var reply: (interrupt: [UInt8], extended: [[UInt8]])?
    /// Endpointy, z których libusb oddaje pakiet razem z TIMEOUT-em (macOS, #146).
    var timeoutEndpoints: Set<UInt8> = []

    func open() throws {}
    func close() {
        closed = true
    }

    func write(_ frame: inout [UInt8], endpoint _: UInt8, timeout _: UInt32) -> (code: Int32, length: Int32) {
        written.append(frame)
        guard announces else { return (0, Int32(frame.count)) }
        if let reply {
            queues[G2UsbProtocol.endpointInterrupt, default: []].append(reply.interrupt)
            queues[G2UsbProtocol.endpointExtended, default: []] += reply.extended
            return (0, Int32(frame.count))
        }
        var announcement = [UInt8](repeating: 0, count: 16)
        announcement[0] = 0x01
        announcement[2] = 0x13
        queues[G2UsbProtocol.endpointInterrupt, default: []].append(announcement)
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
        return (timeoutEndpoints.contains(endpoint) ? LIBUSB_ERROR_TIMEOUT.rawValue : 0, Int32(packet.count))
    }

    func clearHalt(endpoint: UInt8) -> Int32 {
        clearedEndpoints.append(endpoint)
        return 0
    }

    func describeEndpoints() -> String {
        "dead 0x82"
    }
}

/// Linie logu USB zebrane w teście (sink woła się z aktora).
private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func contains(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lines.contains { $0.contains(text) }
    }
}

@MainActor
final class DeadDataChannelTests: XCTestCase {
    private func isError(_ state: G2MidiManager.ConnectionState) -> Bool {
        if case .error = state { return true }
        return false
    }

    /// Do 2026-10-21 edytor pomijał pakiet i czekał dalej — łącze zostawało „żywe", a każda
    /// następna komenda kończyła się brakiem potwierdzenia, aż do odłączenia kabla.
    func testAnnouncementWithoutDataDropsTheLink() async {
        let transport = DeadDataChannelTransport()
        let manager = G2MidiManager()
        await manager.attachTransportForTesting(transport)

        let started = Date()
        do {
            try await manager.setPerformanceMode(false)
            XCTFail("komenda bez odpowiedzi nie może się udać")
        } catch {}

        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "nie czekamy pełnych 3 s na potwierdzenie")
        let state = await manager.state
        XCTAssertTrue(isError(state), "stan .error to sygnał dla `tick`, żeby połączyć się od nowa")
        XCTAssertTrue(transport.closed, "zamknięte urządzenie = następne `connect()` zaczyna od resetu USB")
    }

    /// Patch, który nie doszedł przez zerwane łącze, nie jest „odrzucony przez Norda" — komunikat
    /// o notatce Textpad byłby nieprawdą. Po ponownym połączeniu ekran jedzie do Norda sam.
    func testUploadOverADeadLinkIsNotReportedAsRejected() async {
        let transport = DeadDataChannelTransport()
        let manager = G2MidiManager()
        await manager.attachTransportForTesting(transport)
        let device = DeviceConnection(connectedTo: manager)

        var patch = G2Patch()
        patch.voiceModules = [G2Module(id: 1, typeID: 4, area: .voice)]
        await device.upload(patches: [patch], activeSlot: 0)

        XCTAssertNil(device.uploadFailure)
        XCTAssertNotEqual(device.status, .connected,
                          "bez tego `send` uznałby patch za wysłany i po połączeniu ekran dostałby stary patch Norda")
    }

    // MARK: - Diagnostyka: co log ma powiedzieć przy następnej awarii

    private func manager(with transport: DeadDataChannelTransport, log: LogLines) async -> G2MidiManager {
        let manager = G2MidiManager()
        await manager.attachTransportForTesting(transport)
        await manager.setLog { log.append($0) }
        return manager
    }

    /// Przed zerwaniem łącza: `clear_halt` na 0x82 i jeszcze jedna próba odbioru —
    /// rozstrzyga, czy kanał zablokował Mac (dane przyjdą), czy milczy sam Nord.
    func testSilentDataChannelIsProbedWithClearHalt() async {
        let transport = DeadDataChannelTransport()
        let log = LogLines()
        let manager = await manager(with: transport, log: log)

        try? await manager.setPerformanceMode(false)

        XCTAssertEqual(transport.clearedEndpoints, [G2UsbProtocol.endpointExtended])
        XCTAssertTrue(log.contains("after clear_halt 0x82 gave 0B of the announced 19B"))
    }

    /// Potwierdzenie, które libusb oddał z TIMEOUT-em, jest potwierdzeniem. Do 2026-10-21 ginęło —
    /// `USBProbe --stress` na G2 37 złapał tak dwa w 25 min (`82 01 0B 40 36 03 …`).
    func testAcknowledgementArrivingWithTimeoutIsKept() async throws {
        let transport = DeadDataChannelTransport()
        transport.reply = ([0x62, 0x01, 0x0C, 0x00, 0x7F, 0x8C, 0xAD, 0, 0, 0, 0, 0, 0, 0, 0, 0], [])
        transport.timeoutEndpoints = [G2UsbProtocol.endpointInterrupt]
        let log = LogLines()
        let manager = await manager(with: transport, log: log)

        let started = Date()
        try await manager.selectSlot(1)

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "bez czekania 3 s na potwierdzenie")
        XCTAssertFalse(log.contains("no acknowledgement"))
        XCTAssertTrue(log.contains("arrived with TIMEOUT — kept"))
    }

    /// Dane z 0x82 w dwóch kawałkach, pierwszy oddany z TIMEOUT-em — to jeden komunikat.
    func testExtendedDataInPiecesIsJoined() async throws {
        // Odpowiedź na `0x3E` z usb.log 2026-10-15 01:39:19 (G2 37, fw 1.62), razem z CRC.
        let release: [UInt8] = [0x01, 0x0C, 0x40, 0x1F, 0x05, 0x36, 0x00, 0x10, 0x36, 0x01,
                                0x18, 0x36, 0x02, 0x12, 0x36, 0x03, 0x0C, 0xCE, 0xC4]
        var announcement = [UInt8](repeating: 0, count: 16)
        announcement[0] = 0x01
        announcement[2] = UInt8(release.count)
        let transport = DeadDataChannelTransport()
        transport.reply = (announcement, [Array(release.prefix(10)), Array(release.dropFirst(10))])
        transport.timeoutEndpoints = [G2UsbProtocol.endpointExtended]
        let log = LogLines()
        let manager = await manager(with: transport, log: log)

        try await manager.setPerformanceMode(false)

        var versions: [UInt8] = []
        for slot in 0 ..< 4 {
            await versions.append(manager.slotVersionForTesting(slot))
        }
        XCTAssertEqual(versions, [0x10, 0x18, 0x12, 0x0C])
        XCTAssertFalse(log.contains("stream mismatch"))
    }

    /// Brak potwierdzenia: jeden odczyt 0x82 bez zapowiedzi. Leżący tam payload to sierota,
    /// która blokuje Norda — log ma to nazwać.
    func testMissingAcknowledgementLooksForAnOrphanOnTheDataChannel() async {
        let transport = DeadDataChannelTransport()
        transport.announces = false
        transport.queues[G2UsbProtocol.endpointExtended] = [[0xDE, 0xAD, 0xBE, 0xEF]]
        let log = LogLines()
        let manager = await manager(with: transport, log: log)

        try? await manager.selectSlot(1)

        XCTAssertTrue(log.contains("0x82 held 4B with no announcement"))
        let state = await manager.state
        XCTAssertFalse(isError(state), "sam brak potwierdzenia nie zrywa łącza")
    }
}
