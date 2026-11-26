// EmptyPatchSettingsTests.swift
// #198: a new patch (start, New Patch, New Performance) had only zeros in its patch settings —
// Octave Shift 0 is two octaves down (neutral is 2), Sustain off, Bend off, no vibrato depth.
// It gets the settings every factory patch has, and keeps them when saved.

import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class EmptyPatchSettingsTests: XCTestCase {
    private func assertFactory(_ patch: G2Patch, _ context: String, line: UInt = #line) {
        XCTAssertFalse(patch.variationSettings.isEmpty, context, line: line)
        for (variation, settings) in patch.variationSettings.enumerated() {
            XCTAssertEqual(settings.octaveShift, 2, "\(context): variation \(variation) Octave Shift 0", line: line)
            XCTAssertEqual(settings.sustain, 1, "\(context): variation \(variation) Sustain", line: line)
            XCTAssertEqual(settings.bend, 1, "\(context): variation \(variation) Bend", line: line)
            XCTAssertEqual(settings.patchVolume, 100, "\(context): variation \(variation) volume", line: line)
            XCTAssertEqual(settings.activeMuted, 1, "\(context): variation \(variation) On", line: line)
        }
    }

    func testNewPatchesHaveFactorySettings() {
        let state = PatchState()
        state.startEmpty()
        assertFactory(state.slots[0], "start")
        state.newPatch(inSlot: 1)
        assertFactory(state.slots[1], "New Patch")
        state.newPerformance()
        for slot in 0 ..< 4 { assertFactory(state.slots[slot], "New Performance slot \(slot)") }
    }

    func testFactorySettingsSurviveSaving() throws {
        let state = PatchState()
        state.startEmpty()
        let data = try PatchParser.saveAll(originalData: PatchParser.emptyPatchFile, patches: [state.slots[0]])
        let back = try XCTUnwrap(PatchParser.parseFile(data: data).patches.first)
        // The file holds the eight variations plus Init; the mutator buffer after them is not saved.
        let saved = back.variationSettings.prefix(G2Patch.mutatorVariation)
        XCTAssertEqual(saved.count, G2Patch.mutatorVariation)
        XCTAssertEqual(saved.map(\.octaveShift), Array(repeating: 2, count: saved.count))
        XCTAssertEqual(saved.map(\.sustain), Array(repeating: 1, count: saved.count))
        XCTAssertEqual(saved.map(\.patchVolume), Array(repeating: 100, count: saved.count))
    }
}
