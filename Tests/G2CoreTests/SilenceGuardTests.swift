// SilenceGuardTests.swift
// Przycisk „Not silent" w oknie Patch Mutator: rozpoznanie dziecka, którego nic nie zagra.

import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class SilenceGuardTests: XCTestCase {
    private enum ModuleID {
        static let osc = 1, mixer = 2, out = 3, filter = 4, lfo = 5
    }

    private func module(_ id: Int, _ name: String) throws -> G2Module {
        let def = try XCTUnwrap(ModuleDatabase.module(shortName: name))
        var module = G2Module(id: id, typeID: def.id, area: .voice)
        module.parameters = def.paramNames.map { _ in 100 }
        return module
    }

    private func input(_ name: String, of module: String) throws -> Int {
        try XCTUnwrap(ModuleDatabase.module(shortName: module)?.inputs.firstIndex { $0.name == name })
    }

    /// OscA → Mix4-1B (In1) → FltLP → 2-Out (InL).
    private func patch(filterInput: Bool = true) throws -> G2Patch {
        var patch = G2Patch()
        patch.voiceModules = try [module(ModuleID.osc, "OscA"), module(ModuleID.mixer, "Mix4-1B"),
                                  module(ModuleID.filter, "FltLP"), module(ModuleID.out, "2-Out"), module(ModuleID.lfo, "LfoA")]
        patch.voiceCables = try [
            G2Cable(fromModule: ModuleID.osc, fromConnector: 0, toModule: ModuleID.mixer,
                    toConnector: input("In1", of: "Mix4-1B"), color: .red, area: .voice),
            G2Cable(fromModule: ModuleID.mixer, fromConnector: 0, toModule: ModuleID.filter,
                    toConnector: input(filterInput ? "In" : "Pitch", of: "FltLP"), color: .red, area: .voice),
            G2Cable(fromModule: ModuleID.filter, fromConnector: 0, toModule: ModuleID.out,
                    toConnector: input("InL", of: "2-Out"), color: .red, area: .voice),
            // LFO na wejście sterujące filtra — nie prowadzi dźwięku do wyjścia.
            G2Cable(fromModule: ModuleID.lfo, fromConnector: 0, toModule: ModuleID.filter,
                    toConnector: input("Pitch", of: "FltLP"), color: .blue, area: .voice),
        ]
        return patch
    }

    private func sound(_ patch: G2Patch) -> G2Individual {
        G2Mutator.individual(from: patch, variation: 0, genome: G2MutatorGenome(patch: patch))
    }

    private func lev1Key() throws -> G2Individual.Key {
        try G2Individual.Key(area: .voice, moduleID: ModuleID.mixer,
                             paramIndex: XCTUnwrap(ModuleDatabase.module(shortName: "Mix4-1B")?.paramNames.firstIndex(of: "Lev1")))
    }

    /// Prawdziwe patche z testów grają wg reguł — inaczej strażnik byłby w nich wyłączony.
    func testRealPatchesPlay() throws {
        for name in ["test_3osc.pch2", "simplesynth001-20240802.pch2"] {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures").appendingPathComponent(name)
            let patch = try XCTUnwrap(PatchParser.parse(data: Data(contentsOf: url)).first)
            XCTAssertFalse(G2SilenceGuard(patch: patch).isSilent(sound(patch)), name)
        }
        // Zbiór modułów bez wyjścia i kabli naprawdę nic nie gra — tam strażnik się wyłącza.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("EnvFx.pch2")
        let gallery = try XCTUnwrap(PatchParser.parse(data: Data(contentsOf: url)).first)
        XCTAssertTrue(G2SilenceGuard(patch: gallery).isSilent(sound(gallery)))
    }

    func testOpenPathPlays() throws {
        let patch = try patch()
        XCTAssertFalse(G2SilenceGuard(patch: patch).isSilent(sound(patch)))
    }

    /// Mikser skręcony do zera na jedynej drodze — cisza, mimo LFO na filtrze.
    func testClosedMixerOnTheOnlyPathIsSilent() throws {
        let patch = try patch()
        var child = sound(patch)
        try child[lev1Key()] = 0.2 // po zaokrągleniu 0
        XCTAssertTrue(G2SilenceGuard(patch: patch).isSilent(child))
        try child[lev1Key()] = 1
        XCTAssertFalse(G2SilenceGuard(patch: patch).isSilent(child))
    }

    /// Mikser wpięty tylko w wejście sterujące filtra: do wyjścia nic nie płynie.
    func testControlInputDoesNotCarrySound() throws {
        let patch = try patch(filterInput: false)
        XCTAssertTrue(G2SilenceGuard(patch: patch).isSilent(sound(patch)))
    }

    func testPatchVolumeZeroIsSilent() throws {
        let patch = try patch()
        var child = sound(patch)
        child[.setting(module: G2PatchSetting.patchVolume.module, param: G2PatchSetting.patchVolume.param)] = 0
        XCTAssertTrue(G2SilenceGuard(patch: patch).isSilent(child))
    }

    /// Kabel wejście→wejście: drugi mikser dostaje ten sam sygnał co pierwszy.
    func testInputToInputCableCarriesTheSameSignal() throws {
        var patch = try patch()
        try patch.voiceModules.append(module(9, "Mix1-1A"))
        patch.voiceCables[2] = try G2Cable(fromModule: 9, fromConnector: 0, toModule: ModuleID.out,
                                           toConnector: input("InL", of: "2-Out"), color: .red, area: .voice)
        try patch.voiceCables.append(G2Cable(fromModule: ModuleID.filter, fromConnector: 0, toModule: ModuleID.out,
                                             toConnector: input("InR", of: "2-Out"), color: .red, area: .voice))
        try patch.voiceCables.append(G2Cable(fromModule: ModuleID.out, fromConnector: input("InR", of: "2-Out"),
                                             toModule: 9, toConnector: input("In", of: "Mix1-1A"),
                                             color: .red, area: .voice, sourceIsOutput: false))
        var child = sound(patch)
        try child[lev1Key()] = 0
        XCTAssertTrue(G2SilenceGuard(patch: patch).isSilent(child))
        try child[lev1Key()] = 50
        XCTAssertFalse(G2SilenceGuard(patch: patch).isSilent(child))
    }

    // MARK: - Gałka czułości i reguły poza mikserem

    private func key(_ moduleID: Int, _ module: String, _ param: String) throws -> G2Individual.Key {
        try G2Individual.Key(area: .voice, moduleID: moduleID,
                             paramIndex: XCTUnwrap(ModuleDatabase.module(shortName: module)?
                                 .paramNames.firstIndex(of: param)))
    }

    /// Ten sam patch bez LFO na wejściu sterującym filtra — o domkniętym filtrze
    /// orzekamy tylko wtedy, gdy nic nie może podnieść mu cutoffu.
    private func patchWithoutFilterModulation() throws -> G2Patch {
        var patch = try patch()
        patch.voiceCables.removeLast()
        return patch
    }

    /// `Freq` dolnoprzepustu przy samym dole = cisza; kabel na wejściu sterującym
    /// wyłącza tę regułę, bo modulacja może filtr otworzyć.
    func testClosedLowPassIsSilent() throws {
        let patch = try patchWithoutFilterModulation()
        var child = sound(patch)
        try child[key(ModuleID.filter, "FltLP", "Freq")] = 0
        XCTAssertTrue(G2SilenceGuard(patch: patch).isSilent(child))

        let modulated = try self.patch()
        XCTAssertFalse(G2SilenceGuard(patch: modulated).isSilent(child), "kabel na Pitch wyłącza regułę")
    }

    /// Wzmacniacz ze strony Level — `Gain` na zerze zamyka drogę tak samo jak mikser.
    func testAmplifierGainZeroIsSilent() throws {
        var patch = try patchWithoutFilterModulation()
        try patch.voiceModules.append(module(9, "LevAmp"))
        patch.voiceCables[2] = try G2Cable(fromModule: ModuleID.filter, fromConnector: 0, toModule: 9,
                                           toConnector: input("In", of: "LevAmp"), color: .red, area: .voice)
        try patch.voiceCables.append(G2Cable(fromModule: 9, fromConnector: 0, toModule: ModuleID.out,
                                             toConnector: input("InL", of: "2-Out"), color: .red, area: .voice))
        XCTAssertFalse(G2SilenceGuard(patch: patch).isSilent(sound(patch)))

        var child = sound(patch)
        try child[key(9, "LevAmp", "Gain")] = 0
        XCTAssertTrue(G2SilenceGuard(patch: patch).isSilent(child))
    }

    /// Gałka czułości: poziom tuż nad zerem gra przy zerowej czułości, a na maksimum
    /// liczy się już jako cisza.
    func testSensitivityWidensTheThreshold() throws {
        let patch = try patch()
        var child = sound(patch)
        try child[lev1Key()] = 5
        XCTAssertFalse(G2SilenceGuard(patch: patch).isSilent(child))
        XCTAssertTrue(G2SilenceGuard(patch: patch, strictness: .init(sensitivity: 1)).isSilent(child))
        XCTAssertFalse(G2SilenceGuard(patch: patch, strictness: .init(sensitivity: 0.1)).isSilent(child))
    }

    /// Przełącznik `On` zna tylko zero — przy maksymalnej czułości zapalony (1) nie może
    /// wyjść jako zamknięty, bo wyciszyłby każdy patch z takim mikserem.
    func testSwitchIsNotAffectedBySensitivity() throws {
        var patch = G2Patch()
        patch.voiceModules = try [module(ModuleID.osc, "OscA"), module(9, "Mix1-1A"), module(ModuleID.out, "2-Out")]
        patch.voiceCables = try [
            G2Cable(fromModule: ModuleID.osc, fromConnector: 0, toModule: 9,
                    toConnector: input("In", of: "Mix1-1A"), color: .red, area: .voice),
            G2Cable(fromModule: 9, fromConnector: 0, toModule: ModuleID.out,
                    toConnector: input("InL", of: "2-Out"), color: .red, area: .voice),
        ]
        var child = sound(patch)
        try child[key(9, "Mix1-1A", "On")] = 1
        let strict = G2SilenceGuard(patch: patch, strictness: .init(sensitivity: 1))
        XCTAssertFalse(strict.isSilent(child))

        try child[key(9, "Mix1-1A", "On")] = 0
        XCTAssertTrue(strict.isSilent(child))
    }

    /// W oknie: przy włączonym „Not silent" ciche dziecko jest losowane od nowa, przy
    /// wyłączonym — zostaje; cichy rodzic wyłącza strażnika (reguły nie rozumieją patcha).
    func testNotSilentRerollsSilentChildren() throws {
        let patch = try patch()
        let state = PatchState()
        state.slots = [patch]
        let audible = sound(patch)
        var silent = audible
        try silent[lev1Key()] = 0
        let children = [audible, silent, silent]
        var retries = 0
        let retry = { () -> G2Individual in
            retries += 1
            return retries % 2 == 0 ? audible : silent
        }
        let silence = G2SilenceGuard(patch: patch)

        XCTAssertEqual(state.keepAudible(children, parents: [audible], retry: retry), children)
        XCTAssertEqual(retries, 0, "wyłączony przycisk niczego nie losuje")

        state.mutatorSettings.notSilent = true
        let kept = state.keepAudible(children, parents: [audible], retry: retry)
        XCTAssertEqual(kept.count, 3)
        XCTAssertFalse(kept.contains(where: silence.isSilent))
        XCTAssertEqual(kept[0], audible, "grające dziecko zostaje bez losowania")

        retries = 0
        XCTAssertEqual(state.keepAudible(children, parents: [silent], retry: retry), children)
        XCTAssertEqual(retries, 0)

        let hopeless = state.keepAudible([silent], parents: [audible]) {
            retries += 1
            return silent
        }
        XCTAssertEqual(hopeless, [silent])
        XCTAssertEqual(retries, PatchState.silentRetries, "limit prób — przycisk się nie zawiesza")
    }

    // MARK: - Zawory głośności (gałka powyżej zera)

    /// Na drodze OscA → Mix4-1B → FltLP → 2-Out zaworami są poziomy miksera, cutoff
    /// dolnoprzepustu i głośność patcha; LFO na Pitch filtra nim nie jest.
    func testLoudnessValvesFollowTheSignalPath() throws {
        let patch = try patch()
        let valves = G2SilenceGuard(patch: patch).loudnessValves
        XCTAssertEqual(try valves[lev1Key()], 1)
        XCTAssertEqual(try valves[key(ModuleID.mixer, "Mix4-1B", "Lev4")], 1)
        XCTAssertEqual(try valves[key(ModuleID.filter, "FltLP", "Freq")], 1)
        XCTAssertEqual(valves[.setting(module: G2PatchSetting.patchVolume.module,
                                       param: G2PatchSetting.patchVolume.param)], 1)
        XCTAssertNil(try valves[key(ModuleID.lfo, "LfoA", "Rate")])
        XCTAssertNil(try valves[key(ModuleID.osc, "OscA", "FreqCoarse")])
    }

    /// Krok w stronę ciszy skrócony o gałkę, krok w stronę „głośniej" i inne parametry bez zmian.
    func testProtectShortensOnlyStepsTowardSilence() throws {
        let patch = try patch()
        let parent = sound(patch)
        let silence = G2SilenceGuard(patch: patch)
        var child = parent
        try child[lev1Key()] = 20
        try child[key(ModuleID.filter, "FltLP", "Freq")] = 120
        try child[key(ModuleID.osc, "OscA", "FreqCoarse")] = 10

        let half = silence.protect(child, parent: parent, amount: 0.5)
        XCTAssertEqual(try half[lev1Key()], 60, "100 → 20 skrócone do połowy drogi")
        XCTAssertEqual(try half[key(ModuleID.filter, "FltLP", "Freq")], 120, "głośniej — bez zmian")
        XCTAssertEqual(try half[key(ModuleID.osc, "OscA", "FreqCoarse")], 10, "to nie zawór")

        XCTAssertEqual(try silence.protect(child, parent: parent, amount: 1)[lev1Key()], 100)
        XCTAssertEqual(silence.protect(child, parent: parent, amount: 0), child)
    }

    /// Obwiednia sterująca amplitudą (LevMult.Mod): atak w dół = głośniej, sustain w górę.
    /// Obwiednia na wejściu Pitch filtra chroni tylko atak.
    func testEnvelopesOnTheAmplitudeAreValves() throws {
        var patch = G2Patch()
        patch.voiceModules = try [module(1, "OscA"), module(2, "LevMult"), module(3, "2-Out"),
                                  module(4, "EnvADSR"), module(5, "FltLP"), module(6, "EnvADSR")]
        patch.voiceCables = try [
            G2Cable(fromModule: 1, fromConnector: 0, toModule: 5, toConnector: input("In", of: "FltLP"),
                    color: .red, area: .voice),
            G2Cable(fromModule: 5, fromConnector: 0, toModule: 2, toConnector: input("In", of: "LevMult"),
                    color: .red, area: .voice),
            G2Cable(fromModule: 2, fromConnector: 0, toModule: 3, toConnector: input("InL", of: "2-Out"),
                    color: .red, area: .voice),
            G2Cable(fromModule: 4, fromConnector: 0, toModule: 2, toConnector: input("Mod", of: "LevMult"),
                    color: .blue, area: .voice),
            G2Cable(fromModule: 6, fromConnector: 0, toModule: 5, toConnector: input("Pitch", of: "FltLP"),
                    color: .blue, area: .voice),
        ]
        let valves = G2SilenceGuard(patch: patch).loudnessValves
        XCTAssertEqual(try valves[key(4, "EnvADSR", "Attack")], -1)
        XCTAssertEqual(try valves[key(4, "EnvADSR", "Sustain")], 1)
        XCTAssertEqual(try valves[key(6, "EnvADSR", "Attack")], -1)
        XCTAssertNil(try valves[key(6, "EnvADSR", "Sustain")], "obwiednia filtra kształtu nie chroni")
    }

    /// Sam przycisk daje połowę ochrony, gałka dokłada resztę; zgaszony przycisk nic nie zmienia.
    func testButtonAloneGivesHalfTheProtection() throws {
        let patch = try patch()
        let state = PatchState()
        state.slots = [patch]
        let mother = sound(patch)
        var child = mother
        try child[lev1Key()] = 20

        XCTAssertEqual(try state.loudnessProtection(mother: mother)(child)[lev1Key()], 20, "przycisk zgaszony")
        state.mutatorSettings.notSilent = true
        XCTAssertEqual(try state.loudnessProtection(mother: mother)(child)[lev1Key()], 60, "gałka na zerze")
        state.mutatorSettings.silenceSensitivity = 1
        XCTAssertEqual(try state.loudnessProtection(mother: mother)(child)[lev1Key()], 100, "gałka na maksimum")
    }

    /// Przełącznik na drodze do wyjścia: od połowy ochrony zostaje na wejściu wybranym w rodzicu.
    func testSwitchOnThePathKeepsTheParentsChoice() throws {
        var patch = G2Patch()
        patch.voiceModules = try [module(1, "OscA"), module(2, "Sw2-1"), module(3, "2-Out")]
        patch.voiceCables = try [
            G2Cable(fromModule: 1, fromConnector: 0, toModule: 2, toConnector: input("In1", of: "Sw2-1"),
                    color: .red, area: .voice),
            G2Cable(fromModule: 2, fromConnector: 0, toModule: 3, toConnector: input("InL", of: "2-Out"),
                    color: .red, area: .voice),
        ]
        let silence = G2SilenceGuard(patch: patch)
        let select = try key(2, "Sw2-1", "Sel")
        XCTAssertEqual(silence.loudnessValves[select], 0)
        var parent = sound(patch)
        parent[select] = 0
        var child = parent
        child[select] = 1
        XCTAssertEqual(silence.protect(child, parent: parent, amount: 0.5)[select], 0)
        XCTAssertEqual(silence.protect(child, parent: parent, amount: 0.25)[select], 1, "poniżej połowy wolno")
    }
}
