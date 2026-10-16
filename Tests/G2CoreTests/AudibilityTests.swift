// AudibilityTests.swift
// „Only audible" w panelu Mutation settings: które moduły i gałki nic nie robią, że Mutate
// i Randomize ich nie ruszają, i że zwinięty panel daje dokładnie Standard.

import G2Core
@testable import G2EditorCore
import MutatorCore
import XCTest

@MainActor
final class AudibilityTests: XCTestCase {
    private enum ModuleID {
        static let osc = 1, filter = 2, out = 3, lfo = 4, loose = 5
    }

    private func module(_ id: Int, _ name: String) throws -> G2Module {
        let def = try XCTUnwrap(ModuleDatabase.module(shortName: name))
        var module = G2Module(id: id, typeID: def.id, area: .voice)
        module.parameters = def.paramNames.map { _ in 60 }
        return module
    }

    private func input(_ name: String, of module: String) throws -> Int {
        try XCTUnwrap(ModuleDatabase.module(shortName: module)?.inputs.firstIndex { $0.name == name })
    }

    private func param(_ name: String, of module: String) throws -> Int {
        try XCTUnwrap(ModuleDatabase.module(shortName: module)?.paramNames.firstIndex(of: name))
    }

    private func cable(_ from: Int, _ to: Int, _ connector: Int) -> G2Cable {
        G2Cable(fromModule: from, fromConnector: 0, toModule: to, toConnector: connector, color: .red, area: .voice)
    }

    /// OscB → FltLP → 2-Out, LfoA na Pitch filtra; drugi OscB bez kabli.
    private func patch() throws -> G2Patch {
        var patch = G2Patch()
        patch.voiceModules = try [module(ModuleID.osc, "OscB"), module(ModuleID.filter, "FltLP"),
                                  module(ModuleID.out, "2-Out"), module(ModuleID.lfo, "LfoA"),
                                  module(ModuleID.loose, "OscB")]
        patch.voiceCables = try [
            cable(ModuleID.osc, ModuleID.filter, input("In", of: "FltLP")),
            cable(ModuleID.filter, ModuleID.out, input("InL", of: "2-Out")),
            cable(ModuleID.lfo, ModuleID.filter, input("Pitch", of: "FltLP")),
        ]
        return patch
    }

    private func key(_ module: Int, _ param: Int) -> G2Individual.Key {
        G2Individual.Key(area: .voice, moduleID: module, paramIndex: param)
    }

    // MARK: - Mapa

    /// Kontrakt kroku 4.2: moduł odcięty od wyjścia ⇒ waga 0; sterujący (LFO) słychać.
    func testCutOffModuleWeighsZero() throws {
        let map = try G2AudibilityMap(patch: patch())
        XCTAssertEqual(map.silentModules, [G2AudibilityMap.ModuleRef(area: .voice, id: ModuleID.loose)])
        let fine = try param("FreqFine", of: "OscB")
        XCTAssertEqual(try map.weight(XCTUnwrap(ParameterAddress(key(ModuleID.loose, fine)))), 0)
        XCTAssertEqual(try map.weight(XCTUnwrap(ParameterAddress(key(ModuleID.osc, fine)))), 1)
        XCTAssertFalse(map.isSilent(area: .voice, module: ModuleID.lfo), "LFO steruje filtrem, który gra")
        XCTAssertTrue(map.isAudible(.setting(module: 2, param: 0)), "ustawienia patcha zawsze słychać")
    }

    func testModulationKnobWithoutCableDoesNothing() throws {
        var patch = try patch()
        let fm = try param("FmAmount", of: "OscB")
        let freqMod = try param("FreqMod", of: "FltLP")
        var map = G2AudibilityMap(patch: patch)
        XCTAssertTrue(map.deadParameters.contains(key(ModuleID.osc, fm)))
        XCTAssertFalse(map.deadParameters.contains(key(ModuleID.filter, freqMod)), "Pitch filtra ma kabel z LFO")

        try patch.voiceCables.append(cable(ModuleID.lfo, ModuleID.osc, input("FmMod", of: "OscB")))
        map = G2AudibilityMap(patch: patch)
        XCTAssertFalse(map.deadParameters.contains(key(ModuleID.osc, fm)))
    }

    /// `Active` = 0 gasi moduł i wszystko, co słychać tylko przez niego.
    func testInactiveModuleIsSilentWithItsSources() throws {
        let patch = try patch()
        let active = try key(ModuleID.filter, param("Active", of: "FltLP"))
        var sound = G2Mutator.individual(from: patch, variation: 0, genome: G2MutatorGenome(patch: patch))
        XCTAssertTrue(G2AudibilityMap(patch: patch, sound: sound).silentModules.count == 1)
        sound[active] = 0
        let map = G2AudibilityMap(patch: patch, sound: sound)
        for id in [ModuleID.osc, ModuleID.filter, ModuleID.lfo, ModuleID.loose] {
            XCTAssertTrue(map.isSilent(area: .voice, module: id), "moduł \(id)")
        }
        XCTAssertFalse(map.isSilent(area: .voice, module: ModuleID.out))
    }

    /// Grające patche nie wychodzą całe „głuche"; RndFilter i SwitchSeqNote to katalogi
    /// modułów bez kabli, więc tam wszystko słusznie nic nie robi.
    func testRealPatchesStillHaveAudibleModules() throws {
        for name in ["test_3osc.pch2", "simplesynth001-20240802.pch2"] {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures").appendingPathComponent(name)
            let patch = try XCTUnwrap(PatchParser.parse(data: Data(contentsOf: url)).first)
            let map = G2AudibilityMap(patch: patch)
            let all = patch.voiceModules.count + patch.fxModules.count
            XCTAssertLessThan(map.silentModules.count, all, name)
        }
    }

    // MARK: - Operacje

    func testOnlyAudibleMutateAndRandomizeSkipSilentParameters() throws {
        let patch = try patch()
        let genome = G2MutatorGenome(patch: patch)
        let mother = G2Mutator.individual(from: patch, variation: 0, genome: genome)
        let map = G2AudibilityMap(patch: patch, sound: mother)
        let settings = G2MutatorSettings(probability: 1, range: 0.5, link: false)
        let locks = G2MutatorLocks(enabled: 0xFF)
        var rng = SplitMix64(seed: 11)
        var movedWithoutMap = false

        for _ in 0 ..< 10 {
            let children = G2Mutator.mutate(parent: mother, genome: genome, settings: settings, locks: locks,
                                            audibility: map, using: &rng)
                + G2Mutator.randomize(base: mother, genome: genome, locks: locks, audibility: map, using: &rng)
            for child in children {
                for gene in genome.genes where !map.isAudible(gene.key) {
                    XCTAssertEqual(child[gene.key], mother[gene.key], "\(gene.key) ruszony, choć go nie słychać")
                }
            }
            let plain = G2Mutator.mutate(parent: mother, genome: genome, settings: settings, locks: locks,
                                         using: &rng)
            movedWithoutMap = movedWithoutMap || plain.contains { child in
                genome.genes.contains { !map.isAudible($0.key) && child[$0.key] != mother[$0.key] }
            }
        }
        XCTAssertTrue(movedWithoutMap, "bez „Only audible” niesłyszalne parametry się ruszają")
    }

    /// Silnik widzi „nic nie robi" jako osobny powód — nie jako blokadę; blokada wygrywa.
    func testEngineMarksInaudibleSeparatelyFromLocks() throws {
        let patch = try patch()
        let genome = G2MutatorGenome(patch: patch)
        let space = G2EngineSpace(patch: patch, genome: genome)
        let map = G2AudibilityMap(patch: patch)
        let fine = try XCTUnwrap(ParameterAddress(key(ModuleID.loose, param("FreqFine", of: "OscB"))))

        XCTAssertNil(space.mutability(locks: G2MutatorLocks(enabled: 0xFF)).parameterLocks[fine])
        XCTAssertEqual(space.mutability(locks: G2MutatorLocks(enabled: 0xFF), audibility: map)
            .mutability(fine).reason, .inaudible)
        let gene = try XCTUnwrap(genome.genes.first { $0.key == fine.key })
        var locks = G2MutatorLocks(enabled: 0xFF)
        try locks.toggleLock(XCTUnwrap(gene.category))
        XCTAssertEqual(space.mutability(locks: locks, audibility: map).mutability(fine).reason, .explicit)
    }

    // MARK: - Reguła A: zwinięty panel = Standard

    func testCollapsedPanelIsAlwaysStandard() {
        for onlyAudible in [false, true] {
            let settings = G2MutatorPanelSettings(onlyAudible: onlyAudible)
            XCTAssertEqual(settings.effective(panelOpen: false), .standard)
            XCTAssertEqual(settings.effective(panelOpen: true), settings)
        }
        XCTAssertFalse(G2MutatorPanelSettings.standard.onlyAudible)
    }

    func testPanelControllerRemembersOnlyAudibleAndDefaultsToOn() throws {
        let suite = "AudibilityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let panels = PanelController(defaults: defaults)
        XCTAssertTrue(panels.mutatorPanelSettings.onlyAudible)
        XCTAssertEqual(panels.effectiveMutatorSettings, .standard, "zwinięty panel")
        panels.mutatorSettingsOpen = true
        XCTAssertTrue(panels.effectiveMutatorSettings.onlyAudible)

        panels.mutatorPanelSettings.onlyAudible = false
        XCTAssertFalse(PanelController(defaults: defaults).mutatorPanelSettings.onlyAudible)
    }

    func testStandardStateBreedsWithoutAudibilityMap() throws {
        let state = PatchState()
        state.slots = try [patch()]
        let mother = state.currentIndividual()
        XCTAssertNil(state.mutatorAudibility(of: mother), "Standard — mapa nie obowiązuje")
        state.mutatorPanel = G2MutatorPanelSettings(onlyAudible: true)
        XCTAssertNotNil(state.mutatorAudibility(of: mother))
    }
}
