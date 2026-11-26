// SlotLevelTests.swift
// The level under a slot button: which meters of a `0x3A` packet make it up.

@testable import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class SlotLevelTests: XCTestCase {
    /// `parameters` of an output module: Destination, Active, Pad.
    private func output(id: Int, area: PatchArea, destination: Int = 0, active: Int = 1) -> G2Module {
        var module = G2Module(id: id, typeID: 4, area: area) // 2-Out, two meters
        module.parameters = [destination, active, 0]
        return module
    }

    private func reading(_ module: G2Module, _ left: Int, _ right: Int) -> G2MeterReading {
        G2MeterReading(area: module.area, moduleID: module.id, values: [left, right])
    }

    private func level(_ patch: G2Patch, _ meters: [G2MeterReading]) -> Int? {
        var readings = G2VisualReadings()
        readings.meters = meters
        return G2VisualStream.slotLevel(readings, patch: patch)
    }

    func testTheLoudestChannelOfTheOutputsThatLeaveTheSlot() {
        let send = output(id: 1, area: .voice, destination: 2) // Fx 1/2
        let main = output(id: 1, area: .fx)
        var patch = G2Patch()
        patch.voiceModules = [send]
        patch.fxModules = [main]

        XCTAssertEqual(level(patch, [reading(send, 11, 11), reading(main, 3, 5)]), 5,
                       "the send into the FX area is not what leaves the slot")
        XCTAssertEqual(level(patch, [reading(send, 7, 2)]), 7,
                       "main output beyond the reported entries: the send is all there is")
        XCTAssertNil(level(patch, []), "nothing about the outputs: the previous level stands")
    }

    func testSilentWithoutAWayOutOrWhenMuted() {
        let off = output(id: 1, area: .voice, active: 0)
        var patch = G2Patch()
        patch.voiceModules = [off]
        XCTAssertEqual(level(patch, [reading(off, 9, 9)]), 0, "switched off")

        patch.voiceModules = [output(id: 1, area: .voice, destination: 3)]
        XCTAssertEqual(level(patch, [reading(patch.voiceModules[0], 9, 9)]), 0, "only an FX send")

        patch.voiceModules = [output(id: 1, area: .voice)]
        patch.variationSettings = [G2VariationSettings.factory]
        patch.variationSettings[0].activeMuted = 0
        XCTAssertEqual(level(patch, [reading(patch.voiceModules[0], 9, 9)]), 0, "Vol: Off")
    }

    /// Every slot gets its own level, not only the one on screen.
    func testLevelsOfAllSlotsComeFromTheirOwnPackets() {
        var patch = G2Patch()
        patch.voiceModules = [output(id: 1, area: .voice)]
        let device = DeviceConnection()
        device.patchForSlot = { _ in patch }
        // First meter index 0, then 40 entries of two bytes: left 4, right 8.
        var payload = [UInt8](repeating: 0, count: 81)
        payload[1] = 4
        payload[3] = 8

        device.handle(G2Notification(slot: 2, subCommand: G2UsbProtocol.subResponseVolumeData, payload: payload))

        XCTAssertEqual(device.slotLevels, [0, 0, 8, 0])
        XCTAssertTrue(device.meters.isEmpty, "the canvas shows only the slot on screen")
    }
}
