// SlotPlayingTests.swift
// Which slots are lit: ⌘Z of a load that switched a silent slot on, and the empty slots
// of an opened `.prf2`.

import CLibUsb
@testable import G2Core
@testable import G2EditorCore
import XCTest

/// A G2 that answers every command with OK and a session number (what an upload waits for).
private final class AgreeingTransport: G2Transport {
    var queues: [UInt8: [[UInt8]]] = [:]
    private let okFrame: [UInt8] = [0x62, 0x01, 0x0C, 0x00, 0x7F, 0x8C, 0xAD] + [UInt8](repeating: 0, count: 9)

    private var sessionFrame: [UInt8] {
        let body: [UInt8] = [0x01, 0x08, 0x40, 0x36, 0x00, 0x03]
        let crc = G2UsbProtocol.crc16(body)
        let data = body + [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        let packet = [UInt8(data.count << 4) | 0x02] + data
        return packet + [UInt8](repeating: 0, count: 16 - packet.count)
    }

    func open() throws {}
    func close() {}

    func write(_ frame: inout [UInt8], endpoint _: UInt8, timeout _: UInt32) -> (code: Int32, length: Int32) {
        queues[G2UsbProtocol.endpointInterrupt, default: []] += [okFrame, sessionFrame]
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
        "agreeing"
    }
}

@MainActor
final class SlotPlayingTests: XCTestCase {
    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .standardized
    }

    /// Four slots, focus on A, only A playing on the connected G2.
    private func connectedState(_ playing: @escaping () -> [Bool]) -> PatchState {
        let state = PatchState()
        state.undoManager.groupsByEvent = false
        state.loadFromDevice(patches: Array(repeating: G2Patch(), count: 4))
        state.devicePlayingSlots = { (playing(), [true, false, false, false]) }
        return state
    }

    func testUndoOfALoadIntoASilentSlotSwitchesItOffAgain() {
        var playing = [true, false, false, false]
        let state = connectedState { playing }
        var restored: [(slot: Int, giveBack: PatchState.SlotPlayState?)] = []
        state.onSlotRestore = { restored.append(($0, $1)) }

        state.load(url: fixtureURL("test_3osc.pch2"), intoSlot: 1)
        playing = [true, true, false, false] // the load switched B on
        state.undoManager.undo()

        XCTAssertEqual(state.selectedSlot, 0, "the focus goes back")
        XCTAssertEqual(restored.last?.slot, 1)
        XCTAssertEqual(restored.last?.giveBack,
                       PatchState.SlotPlayState(playing: [true, false, false, false],
                                                keyboard: [true, false, false, false], focus: 0))

        playing = [true, false, false, false]
        state.undoManager.redo()
        XCTAssertEqual(state.selectedSlot, 1)
        XCTAssertEqual(restored.last?.slot, 1)
        XCTAssertNil(restored.last?.giveBack, "redo loads the patch, which switches B on by itself")
    }

    func testUndoOfALoadIntoAPlayingSlotLeavesTheSelectionAlone() {
        let state = connectedState { [true, true, false, false] }
        var restored: [PatchState.SlotPlayState?] = []
        state.onSlotRestore = { restored.append($1) }

        state.load(url: fixtureURL("test_3osc.pch2"), intoSlot: 1)
        state.undoManager.undo()

        XCTAssertEqual(state.selectedSlot, 1)
        XCTAssertEqual(restored, [nil])
    }

    /// A bank patch dropped on a silent slot: the G2 switches it on before the patch is
    /// read back, so the state is remembered when the load is asked for.
    func testUndoOfABankPatchInASilentSlotSwitchesItOffAgain() {
        var playing = [true, false, false, false]
        let state = connectedState { playing }
        var restored: [PatchState.SlotPlayState?] = []
        state.onSlotRestore = { restored.append($1) }
        var fromBank = G2Patch()
        fromBank.name = "Bank"

        state.expectBankLoad()
        state.focusSlot(2)
        playing = [true, false, true, false]
        state.replaceSlotFromDevice(slot: 2, patch: fromBank)
        state.endBankLoad()
        state.undoManager.undo()

        XCTAssertEqual(state.selectedSlot, 0)
        XCTAssertEqual(restored.last??.playing, [true, false, false, false])
    }

    /// A performance with patches in A and C, saved with all four slots playing and the
    /// keyboard and focus on the empty B.
    private func performanceFile(filling slots: [Int]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slot-playing-\(UUID().uuidString).prf2")
        let patch = try XCTUnwrap(PatchParser.parse(data: Data(contentsOf: fixtureURL("test_3osc.pch2"))).first)
        let state = PatchState()
        state.newPerformance()
        for slot in slots {
            state.slots[slot] = patch
        }
        for index in state.performance.slots.indices {
            state.performance.slots[index].enabled = true
            state.performance.slots[index].keyboard = index == 1
        }
        state.performance.focusedSlot = 1
        state.selectedSlot = 1
        state.savePerformance(as: url)
        XCTAssertNil(state.errorMessage)
        return url
    }

    func testEmptySlotsOfAnOpenedPerformanceAreSwitchedOff() throws {
        let url = try performanceFile(filling: [0, 2])
        defer { try? FileManager.default.removeItem(at: url) }
        let state = PatchState()

        state.load(url: url)

        XCTAssertEqual(state.performance.slots.map(\.enabled), [true, false, true, false])
        XCTAssertEqual(state.performance.slots.map(\.keyboard), [true, false, false, false],
                       "the keyboard moves off the empty slot")
        XCTAssertEqual(state.selectedSlot, 0, "a focus on an empty slot would switch it on again")
        XCTAssertEqual(state.performance.focusedSlot, 0)
        XCTAssertFalse(state.hasUnsavedChanges)
    }

    /// With a G2 connected the editor sends the opened performance and, at the same time,
    /// follows the new focus. A slot that was silent in the previous document must not get
    /// added to the playing ones: that wrote into the new document and asked to save it.
    func testOpeningAPerformanceWithAG2LeavesItClean() async throws {
        let url = try performanceFile(filling: [0, 2])
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = G2MidiManager()
        await manager.attachTransportForTesting(AgreeingTransport())
        let device = DeviceConnection(connectedTo: manager)
        await device.selectTargetSlot(1) // before: only B plays
        let state = PatchState()
        device.onSlotSelectionEdited = { state.applySlotSelection(enabled: $0, keyboard: $1) }

        state.load(url: url)
        // The same two tasks, in the same order, as the app starts after opening a file.
        let send = Task { await device.send(state, followDocument: true) }
        let focus = Task { await device.selectTargetSlot(state.selectedSlot) }
        await focus.value

        XCTAssertEqual(state.performance.slots.map(\.enabled), [true, false, true, false])
        XCTAssertFalse(state.hasUnsavedChanges)
        await send.value
        XCTAssertEqual(state.performance.slots.map(\.enabled), [true, false, true, false])
        XCTAssertFalse(state.hasUnsavedChanges)
    }

    func testAPerformanceWithNothingInItOpensAsSaved() throws {
        let url = try performanceFile(filling: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let state = PatchState()

        state.load(url: url)

        XCTAssertEqual(state.performance.slots.map(\.enabled), [true, true, true, true])
        XCTAssertEqual(state.selectedSlot, 1)
    }
}
