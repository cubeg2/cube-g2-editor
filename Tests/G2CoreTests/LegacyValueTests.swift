// LegacyValueTests.swift
// Pliki w formacie 18–21 niosą wartości w skalach sprzed firmware'u 1.62 (Pad wyjść, opóźnienia,
// FilterHP, LfoA, Glide, morfy 5 i 6). Oryginalny edytor przelicza je przy otwarciu; robimy to samo.
// Oczekiwane liczby są sprawdzone na plikach 18/19→23 zapisanych przez oryginalny edytor 1.62:
// po konwersji wartości, zakresy morfów, diale i źródła zgadzają się co do jednej sztuki
// → [[Docs/parser/file-conversion]].

@testable import G2Core
import XCTest

final class LegacyValueTests: XCTestCase {
    private func module(typeID: Int, id: Int, parameters: [Int], modes: [Int] = [], area: PatchArea = .voice) -> G2Module {
        var module = G2Module(id: id, typeID: typeID, area: area)
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

    // MARK: 18 → 19

    /// Pad wyjścia (typ 4, parametr 2) ma najwyżej 1, a zakres jego morfu najwyżej ±1.
    func testOutputPadAboveOneIsLimitedWithItsMorphRange() {
        var upgraded = patch(version: 18, voice: [module(typeID: 4, id: 2, parameters: [0, 0, 3])])
        upgraded.morphAssignments[1] = [
            G2MorphAssignment(area: .voice, moduleID: 2, paramIndex: 2, morph: 0, range: 5),
            G2MorphAssignment(area: .voice, moduleID: 2, paramIndex: 2, morph: 1, range: -9),
            G2MorphAssignment(area: .voice, moduleID: 2, paramIndex: 2, morph: 2, range: 1),
        ]

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[1][2], 1)
        XCTAssertEqual(upgraded.morphAssignments[1].map(\.range), [1, -1, 1])
    }

    /// Zakres morfu tniemy tylko tam, gdzie przycięliśmy wartość — tak robi oryginał.
    func testPadWithinTheLimitKeepsItsMorphRange() {
        var upgraded = patch(version: 18, voice: [module(typeID: 3, id: 2, parameters: [0, 0, 1])])
        upgraded.morphAssignments[0] = [G2MorphAssignment(area: .voice, moduleID: 2, paramIndex: 2, morph: 0, range: 5)]

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.morphAssignments[0][0].range, 5)
    }

    func testDelayClockParameterIsZeroedInEveryVariation() {
        var upgraded = patch(version: 18, voice: [
            module(typeID: 177, id: 1, parameters: Array(repeating: 40, count: 9)),
            module(typeID: 175, id: 2, parameters: Array(repeating: 40, count: 9)),
        ])

        upgraded.convertLegacyValues()

        for variation in 0 ..< 9 {
            XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[variation][4], 0)
            XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[variation][3], 40, "inne parametry stoją")
            XCTAssertEqual(upgraded.voiceModules[1].parameterVariations[variation][8], 0)
        }
    }

    /// Plik w wersji 18 przechodzi też kolejne kroki: FilterHP z 19→20.
    func testVersion18AlsoRunsTheLaterSteps() {
        var upgraded = patch(version: 18, voice: [module(typeID: 134, id: 1, parameters: [50, 0, 0])])

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[0][0], 45)
        XCTAssertEqual(upgraded.sourceFormatVersion, 23)
    }

    // MARK: 19 → 20

    func testHighPassFrequencyIsShiftedDown() {
        let values = [0, 3, 100, 101, 110, 111, 127]
        var upgraded = patch(version: 19, voice: values.enumerated().map {
            module(typeID: 134, id: $0.offset + 1, parameters: [$0.element, 0, 0])
        })

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules.map { $0.parameterVariations[4][0] }, [0, 0, 95, 98, 107, 111, 127])
        XCTAssertEqual(upgraded.sourceFormatVersion, 23)
    }

    // MARK: 20 → 21

    func testMorphGroups5And6SwapEverywhere() {
        var upgraded = patch(version: 20, voice: [module(typeID: 1, id: 1, parameters: [1, 2])])
        upgraded.morphAssignments[2] = [
            G2MorphAssignment(area: .voice, moduleID: 1, paramIndex: 0, morph: 4, range: 5),
            G2MorphAssignment(area: .voice, moduleID: 1, paramIndex: 1, morph: 5, range: -7),
            G2MorphAssignment(area: .voice, moduleID: 1, paramIndex: 1, morph: 3, range: 9),
        ]
        upgraded.variationSettings[2].morphDials = [0, 1, 2, 3, 40, 50, 6, 7]
        upgraded.variationSettings[2].morphModes = [1, 1, 1, 1, 0, 2, 1, 1]
        upgraded.knobAssignments[3] = G2KnobAssignment(location: 2, moduleID: 1, paramIndex: 4)
        upgraded.knobAssignments[4] = G2KnobAssignment(location: 2, moduleID: 1, paramIndex: 13)
        upgraded.knobAssignments[5] = G2KnobAssignment(location: 1, moduleID: 1, paramIndex: 4)
        upgraded.midiControllerAssignments[21] = G2MidiControllerAssignment(location: 2, moduleID: 1, paramIndex: 5)

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.morphAssignments[2].map(\.morph), [5, 4, 3])
        XCTAssertEqual(upgraded.variationSettings[2].morphDials, [0, 1, 2, 3, 50, 40, 6, 7])
        XCTAssertEqual(upgraded.variationSettings[2].morphModes, [1, 1, 1, 1, 2, 0, 1, 1])
        XCTAssertEqual(upgraded.knobAssignments[3]?.paramIndex, 5)
        XCTAssertEqual(upgraded.knobAssignments[4]?.paramIndex, 12)
        XCTAssertEqual(upgraded.knobAssignments[5]?.paramIndex, 4, "gałka na module z obszaru Voice zostaje")
        XCTAssertEqual(upgraded.midiControllerAssignments[21]?.paramIndex, 4)
    }

    /// Const (typ 43) nie przyjmuje już morfu na parametrze 1 — parametr zostaje, przypisanie znika.
    func testMorphOnParameterThatNoLongerAcceptsItIsDropped() {
        var upgraded = patch(version: 20, voice: [module(typeID: 43, id: 7, parameters: [64, 3])])
        upgraded.morphAssignments[0] = [
            G2MorphAssignment(area: .voice, moduleID: 7, paramIndex: 1, morph: 0, range: 10),
            G2MorphAssignment(area: .voice, moduleID: 7, paramIndex: 0, morph: 0, range: 10),
        ]

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.morphAssignments[0].map(\.paramIndex), [0])
        XCTAssertEqual(upgraded.voiceModules[0].parameters, [64, 3])
    }

    // MARK: 21 → 22

    /// Zakres Lo (1): `v + 12`. Zakres morfu przeliczony tym samym wzorem na końcu zakresu.
    func testLfoARateMovesWithItsMorphRange() {
        var upgraded = patch(version: 21, voice: [module(typeID: 26, id: 3, parameters: [50, 0, 0, 0, 4, 0, 0, 1, 0])])
        upgraded.morphAssignments[0] = [G2MorphAssignment(area: .voice, moduleID: 3, paramIndex: 0, morph: 0, range: 20)]

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[0][0], 62)
        XCTAssertEqual(upgraded.morphAssignments[0][0].range, 20, "oba końce przesunięte o 12")
    }

    func testLfoAOutsideRateModesIsLeftAlone() {
        var upgraded = patch(version: 21, voice: [module(typeID: 26, id: 3, parameters: [50, 0, 0, 0, 0, 0, 0, 1, 0])])

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[0][0], 50)
    }

    /// Przy `v + 12` kończący się w 127 zakres się skraca; gdy wyszłoby zero, zostaje krok ±1.
    func testMorphRangeCollapsingToZeroKeepsOneStepInItsDirection() {
        var upgraded = patch(version: 21, voice: [module(typeID: 26, id: 3, parameters: [120, 0, 0, 0, 5, 0, 0, 2, 0])])
        upgraded.morphAssignments[0] = [
            G2MorphAssignment(area: .voice, moduleID: 3, paramIndex: 0, morph: 1, range: 6),
            G2MorphAssignment(area: .voice, moduleID: 3, paramIndex: 0, morph: 2, range: -3),
        ]

        upgraded.convertLegacyValues()

        // 120 → 127 (tablica ścina), więc koniec +6 też dochodzi do 127: zero → +1
        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[0][0], 127)
        XCTAssertEqual(upgraded.morphAssignments[0][0].range, 1)
        XCTAssertEqual(upgraded.morphAssignments[0][1].range, -1, "117 też ścięte do 127: zero → −1")
    }

    func testGlideTimeUsesTheTableOnlyInTimeMode() {
        var upgraded = patch(version: 21, voice: [
            module(typeID: 158, id: 5, parameters: [64, 0, 1]),
            module(typeID: 158, id: 6, parameters: [64, 0, 0]),
        ])
        upgraded.morphAssignments[0] = [G2MorphAssignment(area: .voice, moduleID: 5, paramIndex: 0, morph: 0, range: 10)]

        upgraded.convertLegacyValues()

        XCTAssertEqual(upgraded.voiceModules[0].parameterVariations[0][0], 38)
        XCTAssertEqual(upgraded.voiceModules[1].parameterVariations[0][0], 64)
        XCTAssertEqual(upgraded.morphAssignments[0][0].range, 7, "tablica(74) − tablica(64) = 45 − 38")
    }

    // MARK: Performance

    /// Globalne gałki na dialu i źródle morfu 5 / 6 zamieniają cele — tylko w slotach ze starego pliku.
    func testGlobalKnobsOnMorphGroups5And6FollowTheSwap() {
        var performance = G2PerformanceSettings()
        let targets: [(slot: Int, location: UInt8, module: Int, param: Int)] = [
            (0, 2, 1, 4), (0, 2, 1, 5), (0, 2, 1, 12), (0, 2, 1, 13), // zamieniane
            (0, 2, 1, 3), (0, 1, 1, 4), (0, 2, 2, 4), // inny parametr, obszar Voice, inny moduł
            (1, 2, 1, 4), // slot z pliku w wersji 22
        ]
        for (index, target) in targets.enumerated() {
            performance.globalKnobAssignments[index] = G2GlobalKnobAssignment(
                slot: target.slot, location: target.location, moduleID: target.module, paramIndex: target.param
            )
        }
        let old = patch(version: 19, voice: [])
        let current = patch(version: 22, voice: [])

        performance.swapMorphGlobalKnobs(original: [old, current])

        XCTAssertEqual((0 ..< targets.count).map { performance.globalKnobAssignments[$0]?.paramIndex },
                       [5, 4, 13, 12, 3, 4, 4, 4])
    }

    // MARK: Wersje, których nie ruszamy

    func testFilesOutsideTheKnownStepsStayUntouched() {
        for version in [12, 22, 23] {
            var untouched = patch(version: version, voice: [module(typeID: 134, id: 1, parameters: [50, 0, 0])])

            untouched.convertLegacyValues()

            XCTAssertEqual(untouched.voiceModules[0].parameters[0], 50, "wersja \(version)")
            XCTAssertEqual(untouched.sourceFormatVersion, version)
        }
    }

    /// Drugie wywołanie nie przelicza drugi raz — to z tego powodu pole z wersją w ogóle istnieje.
    func testConversionRunsOnlyOnce() {
        var upgraded = patch(version: 19, voice: [module(typeID: 134, id: 1, parameters: [50, 0, 0])])

        upgraded.convertLegacyValues()
        upgraded.convertLegacyValues()
        upgraded.upgradeLegacyModules()

        XCTAssertEqual(upgraded.voiceModules[0].parameters[0], 45)
    }

    // MARK: Plik

    private func fixtureData() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/EnvFx.pch2")
        return try Data(contentsOf: url)
    }

    /// Stary plik zapisany po konwersji ma w nagłówku 23 — inaczej następne otwarcie przeliczyłoby go znowu.
    func testSavingAConvertedPatchWritesTheNewVersion() throws {
        var bytes = try [UInt8](fixtureData())
        let versionIndex = try XCTUnwrap(bytes.firstIndex(of: 0)) + 1
        bytes[versionIndex] = 19

        var patches = try PatchParser.parse(data: Data(bytes))
        XCTAssertEqual(patches[0].sourceFormatVersion, 19)

        let unchanged = try PatchParser.saveAll(originalData: Data(bytes), patches: patches)
        XCTAssertEqual(unchanged[versionIndex], 19, "bez konwersji plik zostaje wierny")

        patches[0].convertLegacyValues()
        let saved = try PatchParser.saveAll(originalData: Data(bytes), patches: patches)
        XCTAssertEqual(saved[versionIndex], 23)
        XCTAssertEqual(try PatchParser.parse(data: saved)[0].sourceFormatVersion, 23)
    }
}
