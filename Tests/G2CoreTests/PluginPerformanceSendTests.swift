// PluginPerformanceSendTests.swift
// `put_performance` z wtyczki ma dojść do Norda: nazwa i sekcja 0x11 (zegar, zakresy klawiszy, Hold),
// w kolejce za patchami slotów — nie tylko do stanu edytora.

import CLibUsb
@testable import G2Core
@testable import G2EditorCore
import XCTest

private final class RecordingTransport: G2Transport {
    var queues: [UInt8: [[UInt8]]] = [:]
    var written: [[UInt8]] = []
    private let okFrame: [UInt8] = [0x62, 0x01, 0x0C, 0x00, 0x7F, 0x8C, 0xAD] + [UInt8](repeating: 0, count: 9)

    func open() throws {}
    func close() {}

    /// Każda wysłana ramka dostaje odpowiedź OK na endpoincie przerwań.
    func write(_ frame: inout [UInt8], endpoint _: UInt8, timeout _: UInt32) -> (code: Int32, length: Int32) {
        written.append(frame)
        queues[G2UsbProtocol.endpointInterrupt, default: []].append(okFrame)
        return (0, Int32(frame.count))
    }

    func read(_ buffer: inout [UInt8], endpoint: UInt8, timeout _: UInt32) -> (code: Int32, length: Int32) {
        guard var pending = queues[endpoint], !pending.isEmpty else { return (LIBUSB_ERROR_TIMEOUT.rawValue, 0) }
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
        "recording"
    }
}

@MainActor
final class PluginPerformanceSendTests: XCTestCase {
    func testPerformanceSettingsFromThePluginGoToTheDevice() async throws {
        var settings = G2PerformanceSettings()
        settings.masterClock = 93
        let state = PatchState()
        state.applyPerformanceSettings(settings, name: "Song Perf", actionName: "Test")
        let message = try XCTUnwrap(PluginBridge.performanceMessage(state))
        let data = try XCTUnwrap(try Data(base64Encoded: XCTUnwrap(message["data"] as? String)))

        let transport = RecordingTransport()
        let manager = G2MidiManager()
        await manager.attachTransportForTesting(transport)
        let device = DeviceConnection(connectedTo: manager)

        device.queuePerformanceSettings(name: "Song Perf", performance: settings, fileData: data)
        await device.awaitStructureSyncForTesting()

        let name = Array("Song Perf".utf8)
        XCTAssertTrue(transport.written.contains { frame in
            frame.indices.contains { index in Array(frame[index...].prefix(name.count)) == name }
        }, "nazwa performance'u idzie do Norda")
        XCTAssertGreaterThanOrEqual(transport.written.count, 2, "nazwa i sekcja 0x11 to dwie komendy")
    }

    func testNothingIsQueuedWithoutADevice() async {
        let device = DeviceConnection()
        device.queuePerformanceSettings(name: "X", performance: G2PerformanceSettings(), fileData: nil)
        await device.awaitStructureSyncForTesting()
        XCTAssertNotEqual(device.status, .connected)
    }
}
