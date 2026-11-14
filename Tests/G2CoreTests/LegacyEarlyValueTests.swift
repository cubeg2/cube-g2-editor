// LegacyEarlyValueTests.swift
// Kroki 13→14 … 17→18 przeliczania starych plików: wstawianie i usuwanie parametrów, Mute→Active,
// skala sześcienna, przycinanie zakresów. Pliki w wersjach 13–14 zapisane przez oryginalny edytor
// 1.62 po konwersji zgadzają się z naszym wynikiem co do jednej wartości (wariacje 1–8)
// → [[Docs/parser/file-conversion]].

@testable import G2Core
import XCTest

final class LegacyEarlyValueTests: XCTestCase {
    private func module(typeID: Int, id: Int, parameters: [Int], modes: [Int] = []) -> G2Module {
        var module = G2Module(id: id, typeID: typeID, area: .voice)
        module.parameters = parameters
        module.parameterVariations = Array(repeating: parameters, count: 9)
        module.modes = modes
        module.hasParameterEntry = true
        return module
    }

    private func patch(version: Int, voice: [G2Module]) -> G2Patch {
        var patch = G2Patch()
        patch.voiceModules = voice
        patch.sourceFormatVersion = version
        return patch
    }

    private func morph(_ id: Int, _ param: Int, _ group: Int = 0, range: Int = 10) -> G2MorphAssignment {
        G2MorphAssignment(area: .voice, moduleID: id, paramIndex: param, morph: group, range: range)
    }

    // MARK: 13 → 14

    func testAddedParametersArriveWithTheirDefaults() {
        var upgraded = patch(version: 13, voice: [module(typeID: 195, id: 1, parameters: [5, 6, 1])])

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[3], [5, 6, 1, 1])
    }

    /// Out ze starego pliku: Pad dochodzi (13→14), a Mute zamienia się w Active (14→15).
    func testOutputFromVersion13GetsPadAndActive() {
        var upgraded = patch(version: 13, voice: [module(typeID: 3, id: 1, parameters: [0, 0])])

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[0], [0, 1, 0])
    }

    // MARK: 14 → 15

    func testMuteBecomesActiveInModulesAndInPatchVolume() {
        var upgraded = patch(version: 14, voice: [
            module(typeID: 24, id: 1, parameters: [0, 0, 0, 0, 0]),
            module(typeID: 24, id: 2, parameters: [0, 0, 0, 0, 1]),
        ])
        upgraded.variationSettings[0].activeMuted = 1
        upgraded.variationSettings[1].activeMuted = 0

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules.map { $0.parameterVariations[0][4] }, [1, 0])
        XCTAssertEqual(upgraded.variationSettings[0].activeMuted, 0)
        XCTAssertEqual(upgraded.variationSettings[1].activeMuted, 1)
    }

    // MARK: 15 → 16

    /// Tablica sześcienna: 64 → 51, a zakres morfu +10 kończy się w T[74] = 63, czyli 63 − 51 = 12.
    func testCubicScaleMovesTheValueAndItsMorphRange() {
        var upgraded = patch(version: 15, voice: [module(typeID: 32, id: 1, parameters: [0, 0, 64])])
        upgraded.morphAssignments[0] = [morph(1, 2, range: 10)]

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[0][2], 51)
        XCTAssertEqual(upgraded.morphAssignments[0][0].range, 12)
    }

    func testPatchVolumeGetsTheCubicScaleToo() {
        var upgraded = patch(version: 15, voice: [])
        upgraded.variationSettings[3].patchVolume = 100
        upgraded.morphAssignments[3] = [G2MorphAssignment(location: 2, moduleID: 2, paramIndex: 0, morph: 1, range: -40)]

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.variationSettings[3].patchVolume, 94)
        XCTAssertEqual(upgraded.morphAssignments[3][0].range, -47, "T[60] − 94 = 47 − 94")
    }

    /// Typ 19: parametry 0–3 przeliczane tylko wtedy, gdy parametr 4 nie ma wartości 1.
    func testCubicScaleIsSkippedWhenTheSwitchIsOne() {
        var upgraded = patch(version: 15, voice: [
            module(typeID: 19, id: 1, parameters: [64, 64, 64, 64, 0]),
            module(typeID: 19, id: 2, parameters: [64, 64, 64, 64, 1]),
        ])

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[0], [51, 51, 51, 51, 0])
        XCTAssertEqual(upgraded.voiceModules[1].parameterVariations[0], [64, 64, 64, 64, 1])
    }

    func testFilterLowPassFrequencyIsShiftedLikeTheHighPass() {
        var upgraded = patch(version: 15, voice: [
            module(typeID: 87, id: 1, parameters: [50, 0, 0]),
            module(typeID: 87, id: 2, parameters: [105, 0, 0]),
        ])

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules.map { $0.parameterVariations[0][0] }, [45, 102])
    }

    // MARK: 16 → 17

    func testChorusAmountIsHalvedWithItsMorphRange() {
        var upgraded = patch(version: 16, voice: [module(typeID: 94, id: 1, parameters: [51])])
        upgraded.morphAssignments[0] = [morph(1, 0, 0, range: 5), morph(1, 0, 1, range: -5)]

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[0][0], 26)
        XCTAssertEqual(upgraded.morphAssignments[0].map(\.range), [3, -3])
    }

    func testGlideLosesItsThirdParameterAndOscillatorModesAreRenumbered() {
        var upgraded = patch(version: 16, voice: [
            module(typeID: 158, id: 1, parameters: [10, 20, 30]),
            module(typeID: 9, id: 2, parameters: [0], modes: [3]),
            module(typeID: 9, id: 3, parameters: [0], modes: [5]),
            module(typeID: 9, id: 4, parameters: [0], modes: [1]),
        ])

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[0], [10, 20])
        XCTAssertEqual(upgraded.voiceModules[1...].map(\.modes), [[4], [2], [1]])
    }

    func testRangesAreTruncatedToTheirLimit() {
        var upgraded = patch(version: 16, voice: [module(typeID: 26, id: 1, parameters: [0, 0, 0, 0, 0, 0, 0, 9])])

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[0][7], 3)
    }

    // MARK: 17 → 18

    /// Digitizer traci parametry 4 i 3; przypisania na nich znikają, a te wyżej przesuwają się w dół.
    func testRemovedParametersTakeTheirAssignmentsAndShiftTheRest() {
        var upgraded = patch(version: 17, voice: [
            module(typeID: 118, id: 4, parameters: [10, 11, 12, 13, 14, 15, 16, 17]),
            module(typeID: 198, id: 5, parameters: [1, 2, 3]),
        ])
        upgraded.morphAssignments[0] = [morph(4, 3, 0), morph(4, 4, 1), morph(4, 5, 2)]
        upgraded.knobAssignments[0] = G2KnobAssignment(location: 1, moduleID: 4, paramIndex: 6)
        upgraded.midiControllerAssignments[7] = G2MidiControllerAssignment(location: 1, moduleID: 4, paramIndex: 4)

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[0], [10, 11, 12, 15, 16, 17])
        XCTAssertEqual(upgraded.voiceModules[1].parameterVariations[0], [2, 3], "PitchTrack traci parametr 0")
        XCTAssertEqual(upgraded.morphAssignments[0].map(\.paramIndex), [3])
        XCTAssertEqual(upgraded.morphAssignments[0].map(\.morph), [2])
        XCTAssertEqual(upgraded.knobAssignments[0]?.paramIndex, 4)
        XCTAssertNil(upgraded.midiControllerAssignments[7])
    }

    // MARK: 20 → 21

    func testRandomClockModeIsCappedAtOne() {
        var upgraded = patch(version: 20, voice: [
            module(typeID: 206, id: 1, parameters: [0], modes: [3]),
            module(typeID: 206, id: 2, parameters: [0], modes: [0]),
        ])

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules.map(\.modes), [[1], [0]])
    }

    // MARK: Dziewiąta wariacja

    /// Pliki 13 i 14 mają osiem wariacji; dziewiątą (i kopię w buforze Mutatora) oryginał dopełnia
    /// domyślnymi wartościami modułów i domyślnymi ustawieniami patcha, bez morfów.
    func testMissingNinthVariationIsFilledWithDefaults() {
        var filter = module(typeID: 87, id: 1, parameters: [50, 1, 2, 1])
        filter.parameterVariations.append(filter.parameterVariations[8])
        var upgraded = patch(version: 14, voice: [filter])
        upgraded.variationSettings = Array(repeating: G2VariationSettings(), count: 10)
        upgraded.variationSettings[8].patchVolume = 5
        upgraded.variationSettings[7].patchVolume = 100
        upgraded.morphAssignments = Array(repeating: [morph(1, 0)], count: 10)

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[8], [75, 0, 0, 1])
        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[9], [75, 0, 0, 1])
        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[7], [45, 1, 2, 0], "wariacje 1–8 tylko przeliczone")
        XCTAssertEqual(upgraded.variationSettings[8].patchVolume, 100)
        XCTAssertEqual(upgraded.variationSettings[9].glideTime, 28)
        XCTAssertEqual(upgraded.variationSettings[7].patchVolume, 94, "głośność wariacji 8 przeliczona, nie dopełniona")
        XCTAssertTrue(upgraded.morphAssignments[8].isEmpty)
        XCTAssertFalse(upgraded.morphAssignments[7].isEmpty)
    }

    func testNinthVariationIsLeftAloneFromVersion15() {
        var upgraded = patch(version: 15, voice: [module(typeID: 87, id: 1, parameters: [50, 1, 2, 1])])

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[8], [45, 1, 2, 1])
    }

    // MARK: Granice

    func testVersion12AndOlderStayUntouched() {
        var untouched = patch(version: 12, voice: [module(typeID: 3, id: 1, parameters: [0, 0])])

        untouched.convertLegacyValues()

        XCTAssertEqual(untouched.voiceModules[0].parameterVariations[0], [0, 0])
        XCTAssertEqual(untouched.sourceFormatVersion, 12)
    }
}
