// LegacyModuleTests.swift
// #168: pliki ze starych OS-ów niosą moduły, których Nord 1.62 nie zna (ClkDivFix — slot
// odrzucony) albo zna w innej postaci (ClkDiv bez trybu, FreqShift z 5 parametrami).
// Oryginalny edytor przerabia je przy otwarciu pliku; robimy to samo.

@testable import G2Core
import XCTest

final class LegacyModuleTests: XCTestCase {
    private func module(typeID: Int, id: Int, values: Int, modes: Int = 0) -> G2Module {
        var module = G2Module(id: id, typeID: typeID, area: .voice)
        module.parameters = Array(repeating: 64, count: values)
        module.parameterVariations = Array(repeating: module.parameters, count: 9)
        module.modes = Array(repeating: 1, count: modes)
        module.hasParameterEntry = values > 0
        return module
    }

    private func cable(from: Int, _ out: Int, to: Int, _ input: Int) -> G2Cable {
        G2Cable(fromModule: from, fromConnector: out, toModule: to, toConnector: input,
                color: .red, area: .voice)
    }

    func testRetiredClkDivFixIsRemovedWithItsCables() {
        var patch = G2Patch()
        patch.voiceModules = [module(typeID: 77, id: 11, values: 0), module(typeID: 69, id: 17, values: 1, modes: 1)]
        patch.voiceCables = [cable(from: 11, 0, to: 17, 0), cable(from: 17, 0, to: 11, 1)]

        patch.upgradeLegacyModules()

        XCTAssertEqual(patch.voiceModules.map(\.id), [17])
        XCTAssertTrue(patch.voiceCables.isEmpty)
    }

    /// Oryginał dopisuje ClkDiv brakujący tryb z wartością 0 (konwersja 21→22).
    func testClkDivWithoutModeGetsModeZero() {
        var patch = G2Patch()
        patch.voiceModules = [module(typeID: 69, id: 22, values: 1)]

        patch.upgradeLegacyModules()

        XCTAssertEqual(patch.voiceModules[0].modes, [0])
    }

    /// Piąty parametr znika razem z gałką, CC i morfem, które na nim siedziały.
    func testExtraParameterIsRemovedWithItsAssignments() {
        var patch = G2Patch()
        patch.voiceModules = [module(typeID: 98, id: 13, values: 5)]
        patch.knobAssignments[0] = G2KnobAssignment(location: 1, moduleID: 13, paramIndex: 4)
        patch.knobAssignments[1] = G2KnobAssignment(location: 1, moduleID: 13, paramIndex: 0)
        patch.midiControllerAssignments[20] = G2MidiControllerAssignment(location: 1, moduleID: 13, paramIndex: 4)
        patch.morphAssignments[0] = [
            G2MorphAssignment(area: .voice, moduleID: 13, paramIndex: 4, morph: 0, range: 10),
            G2MorphAssignment(area: .voice, moduleID: 13, paramIndex: 1, morph: 0, range: 10),
        ]

        patch.upgradeLegacyModules()

        XCTAssertEqual(patch.voiceModules[0].parameters.count, 4)
        XCTAssertNil(patch.knobAssignments[0])
        XCTAssertNotNil(patch.knobAssignments[1])
        XCTAssertNil(patch.midiControllerAssignments[20])
        XCTAssertEqual(patch.morphAssignments[0].map(\.paramIndex), [1])
    }

    /// Kable w gniazdach, których moduł już nie ma (stary FreqShift miał wejście 2).
    func testCablesToMissingConnectorsAreRemoved() {
        var patch = G2Patch()
        patch.voiceModules = [module(typeID: 98, id: 13, values: 4), module(typeID: 98, id: 14, values: 4)]
        patch.voiceCables = [cable(from: 14, 0, to: 13, 2), cable(from: 14, 1, to: 13, 0)]

        patch.upgradeLegacyModules()

        XCTAssertEqual(patch.voiceCables, [cable(from: 14, 1, to: 13, 0)])
    }

    func testCurrentPatchIsLeftAlone() {
        var patch = G2Patch()
        patch.voiceModules = [module(typeID: 98, id: 1, values: 4), module(typeID: 69, id: 2, values: 1, modes: 1)]
        patch.voiceCables = [cable(from: 2, 0, to: 1, 0)]
        let before = patch

        patch.upgradeLegacyModules()

        XCTAssertEqual(patch, before)
    }
}
