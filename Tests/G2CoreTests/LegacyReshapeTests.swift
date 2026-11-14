// LegacyReshapeTests.swift
// Krok 20→21 starych plików: FreqShift, RndLfoB i RndClkC tracą parametry ze środka, a moduł 140 dostaje
// nowy. Oryginał usuwa parametr razem z przypisaniami na nim i przesuwa numery wyższych; samo przycięcie
// końca modułu dawało inne wartości → [[Docs/parser/file-conversion]].

@testable import G2Core
import XCTest

final class LegacyReshapeTests: XCTestCase {
    private func module(typeID: Int, id: Int, parameters: [Int], modes: [Int] = []) -> G2Module {
        var module = G2Module(id: id, typeID: typeID, area: .voice)
        module.parameters = parameters
        module.parameterVariations = Array(repeating: parameters, count: 9)
        module.modes = modes
        module.hasParameterEntry = true
        return module
    }

    private func patch(version: Int = 19, voice: [G2Module]) -> G2Patch {
        var patch = G2Patch()
        patch.voiceModules = voice
        patch.sourceFormatVersion = version
        return patch
    }

    /// Stary FreqShift ma pięć parametrów: odpadają 3 i 1, na końcu dochodzi nowy z wartością 1.
    func testFreqShiftLosesTwoMiddleParametersAndGainsOne() {
        var upgraded = patch(voice: [module(typeID: 98, id: 5, parameters: [10, 11, 12, 13, 14])])
        upgraded.morphAssignments[0] = [
            G2MorphAssignment(area: .voice, moduleID: 5, paramIndex: 0, morph: 0, range: 1),
            G2MorphAssignment(area: .voice, moduleID: 5, paramIndex: 1, morph: 1, range: 2),
            G2MorphAssignment(area: .voice, moduleID: 5, paramIndex: 2, morph: 2, range: 3),
            G2MorphAssignment(area: .voice, moduleID: 5, paramIndex: 4, morph: 3, range: 4),
        ]
        upgraded.knobAssignments[0] = G2KnobAssignment(location: 1, moduleID: 5, paramIndex: 4)
        upgraded.knobAssignments[1] = G2KnobAssignment(location: 1, moduleID: 5, paramIndex: 3)
        upgraded.midiControllerAssignments[9] = G2MidiControllerAssignment(location: 1, moduleID: 5, paramIndex: 2)

        upgraded.upgradeLegacyModules()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[0], [10, 12, 14, 1])
        XCTAssertEqual(upgraded.morphAssignments[0].map(\.paramIndex), [0, 1, 2], "p1 znika, p2 → 1, p4 → 2")
        XCTAssertEqual(upgraded.morphAssignments[0].map(\.morph), [0, 2, 3])
        XCTAssertEqual(upgraded.knobAssignments[0]?.paramIndex, 2)
        XCTAssertNil(upgraded.knobAssignments[1], "gałka na usuniętym parametrze 3")
        XCTAssertEqual(upgraded.midiControllerAssignments[9]?.paramIndex, 1)
    }

    /// Moduł, który ma już nowy kształt, zostaje — zmiana dotyczy tylko starej liczby parametrów.
    func testModuleAlreadyInTheNewShapeIsLeftAlone() {
        var upgraded = patch(voice: [module(typeID: 98, id: 5, parameters: [10, 11, 12, 13])])

        upgraded.upgradeLegacyModules()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[0], [10, 11, 12, 13])
    }

    func testRandomModulesLoseTheirParameters() {
        var upgraded = patch(voice: [
            module(typeID: 202, id: 1, parameters: Array(0 ... 9)),
            module(typeID: 206, id: 2, parameters: Array(0 ... 6), modes: [0]),
        ])

        upgraded.upgradeLegacyModules()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[0], [0, 1, 2, 3, 4, 5, 6, 7, 9])
        XCTAssertEqual(upgraded.voiceModules[1].parameterVariations[0], [0, 2, 3, 4, 6])
    }

    func testModule140GainsExpLin() {
        var upgraded = patch(voice: [module(typeID: 140, id: 1, parameters: [1, 2, 3, 4, 5, 6, 7, 8])])

        upgraded.upgradeLegacyModules()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[0], [1, 2, 3, 4, 5, 6, 7, 8, 0])
    }

    func testPatchesFromVersion21AreNotReshaped() {
        var current = patch(version: 22, voice: [module(typeID: 202, id: 1, parameters: Array(0 ... 9))])

        current.convertLegacyValues()

        XCTAssertEqual(current.voiceModules[0].parameterVariations[0], Array(0 ... 9))
    }

    // MARK: Performance

    /// Globalne gałki idą za parametrami tak samo jak gałki patcha — tylko w slocie ze starego pliku.
    func testGlobalKnobsFollowTheRemovedParameters() {
        var performance = G2PerformanceSettings()
        let targets: [(slot: Int, param: Int)] = [(0, 4), (0, 3), (0, 0), (1, 4)]
        for (index, target) in targets.enumerated() {
            performance.globalKnobAssignments[index] = G2GlobalKnobAssignment(
                slot: target.slot, location: 1, moduleID: 5, paramIndex: target.param
            )
        }
        let old = patch(voice: [module(typeID: 98, id: 5, parameters: [10, 11, 12, 13, 14])])
        let current = patch(version: 22, voice: [module(typeID: 98, id: 5, parameters: [10, 11, 12, 13])])

        performance.shiftGlobalKnobsOfReshapedParameters(original: [old, current])

        XCTAssertEqual(performance.globalKnobAssignments[0]?.paramIndex, 2)
        XCTAssertNil(performance.globalKnobAssignments[1], "usunięty parametr 3")
        XCTAssertEqual(performance.globalKnobAssignments[2]?.paramIndex, 0)
        XCTAssertEqual(performance.globalKnobAssignments[3]?.paramIndex, 4, "slot z pliku w wersji 22")
    }
}
