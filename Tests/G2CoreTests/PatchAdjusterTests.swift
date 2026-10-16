// PatchAdjusterTests.swift
// Patch Adjuster: wzór przeliczania z `CPatch::ApplyDistribution` i przypisanie
// parametrów do ośmiu kategorii z tabeli w instrukcji (str. 113) → [[Docs/ui/patch-adjuster]].

import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class PatchAdjusterTests: XCTestCase {
    private func fixturePatch(_ name: String) throws -> G2Patch {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .standardized
        return try XCTUnwrap(PatchParser.parse(data: Data(contentsOf: url)).first)
    }

    // MARK: - Wzór

    /// Środek gałki nie rusza niczego — to on decyduje o tym, że Adjustera da się
    /// wycofać bez undo.
    func testCentrePositionLeavesTheValueAlone() {
        XCTAssertEqual(G2PatchAdjuster.adjusted(base: 73, maxValue: 127, modifier: 0), 73)
    }

    /// Krańce: +50 wypycha na maksimum, −50 zbija do zera.
    func testEndsOfTheKnobReachBothEndsOfTheRange() {
        XCTAssertEqual(G2PatchAdjuster.adjusted(base: 40, maxValue: 127, modifier: 50), 127)
        XCTAssertEqual(G2PatchAdjuster.adjusted(base: 40, maxValue: 127, modifier: -50), 0)
    }

    /// Połowa drogi w prawo = połowa odległości do maksimum; połowa w lewo = połowa
    /// wartości. Oryginał obcina ułamek, nie zaokrągla (rzutowanie na `int`).
    func testHalfwayMatchesTheOriginalFormula() {
        // 40 + (127 − 40) · 25/50 = 83,5 → 83
        XCTAssertEqual(G2PatchAdjuster.adjusted(base: 40, maxValue: 127, modifier: 25), 83)
        // 41 · (−25 + 50)/50 = 20,5 → 20
        XCTAssertEqual(G2PatchAdjuster.adjusted(base: 41, maxValue: 127, modifier: -25), 20)
    }

    /// Parametr o krótkim zakresie nie wyjeżdża poza swoje maksimum.
    func testResultNeverLeavesTheParameterRange() {
        for modifier in G2PatchAdjuster.range {
            let value = G2PatchAdjuster.adjusted(base: 3, maxValue: 5, modifier: modifier)
            XCTAssertTrue((0 ... 5).contains(value), "modifier \(modifier) dał \(value)")
        }
    }

    // MARK: - Wzór wstecz (ręczna zmiana przy odkręconej gałce)

    /// Nowa baza ma dawać z powrotem ręcznie ustawioną wartość — dokładnie, gdy ułamek
    /// nie ginie (połowa drogi), i z tolerancją jednego kroku obcięcia poza tym,
    /// tak samo jak w oryginale.
    func testBaseRecomputedFromAManualValueReproducesIt() {
        XCTAssertEqual(G2PatchAdjuster.base(value: 100, maxValue: 127, modifier: 25), 73)
        XCTAssertEqual(G2PatchAdjuster.adjusted(base: 73, maxValue: 127, modifier: 25), 100)
        XCTAssertEqual(G2PatchAdjuster.base(value: 20, maxValue: 127, modifier: -25), 40)
        XCTAssertEqual(G2PatchAdjuster.base(value: 61, maxValue: 127, modifier: 0), 61)

        for modifier in -49 ... 49 where modifier != 0 {
            // Tylko wartości osiągalne z jakiejś bazy: gałka w prawo nie zejdzie poniżej
            // tego, co daje baza 0, w lewo nie wejdzie ponad to, co daje baza 127.
            let reachable = G2PatchAdjuster.adjusted(base: 0, maxValue: 127, modifier: modifier)
                ... G2PatchAdjuster.adjusted(base: 127, maxValue: 127, modifier: modifier)
            for value in stride(from: 0, through: 127, by: 7) where reachable.contains(value) {
                let base = G2PatchAdjuster.base(value: value, maxValue: 127, modifier: modifier)
                let back = G2PatchAdjuster.adjusted(base: base, maxValue: 127, modifier: modifier)
                XCTAssertLessThanOrEqual(abs(back - value), 1, "modifier \(modifier), value \(value) → baza \(base) → \(back)")
            }
        }
    }

    /// Na krańcach gałki każda baza daje to samo, więc bazą zostaje sama wartość —
    /// bez dzielenia przez zero i bez wyjazdu poza zakres.
    func testBaseAtTheEndsOfTheKnobStaysInRange() {
        XCTAssertEqual(G2PatchAdjuster.base(value: 90, maxValue: 127, modifier: 50), 90)
        XCTAssertEqual(G2PatchAdjuster.base(value: 90, maxValue: 127, modifier: -50), 90)
        // Wartość poniżej tego, co gałka dałaby od zera: baza obcięta do zera.
        XCTAssertEqual(G2PatchAdjuster.base(value: 10, maxValue: 127, modifier: 49), 0)
    }

    // MARK: - Przypisanie do gałek

    /// Parametr po nazwie z bazy modułów — w kodzie decyduje numer typu i indeks.
    private func knob(_ shortName: String, _ param: String) -> G2AdjusterKnob? {
        guard let def = ModuleDatabase.module(shortName: shortName),
              let index = def.paramNames.firstIndex(of: param)
        else {
            XCTFail("brak parametru \(shortName).\(param) w bazie modułów")
            return nil
        }
        return G2PatchAdjuster.knob(moduleTypeID: def.id, paramIndex: index)
    }

    /// Cztery czasy obwiedni i ich odpowiedniki w Compress / NoiseGate / EnvFollow —
    /// dokładnie to, co wymienia tabela z instrukcji.
    func testEnvelopeTimesLandUnderTheirOwnKnobs() {
        XCTAssertEqual(knob("EnvADSR", "Attack"), .attack)
        XCTAssertEqual(knob("EnvADSR", "Decay"), .decay)
        XCTAssertEqual(knob("EnvADSR", "Sustain"), .sustain)
        XCTAssertEqual(knob("EnvADSR", "Release"), .release)
        XCTAssertEqual(knob("Compress", "Attack"), .attack)
        XCTAssertEqual(knob("NoiseGate", "Release"), .release)
        XCTAssertEqual(knob("EnvFollow", "Attack"), .attack)
        // Klasa idzie za modułem, nie za nazwą: jednoodcinkowy EnvD gaśnie jak Release.
        XCTAssertEqual(knob("EnvD", "Decay"), .release)
        XCTAssertEqual(knob("OscPerc", "Decay"), .decay)
    }

    /// „…oraz część parametrów Time i Level w obwiedniach wieloodcinkowych".
    func testMultiStageEnvelopeSplitsIntoDecayAndSustain() {
        XCTAssertEqual(knob("EnvMulti", "Time3"), .decay)
        XCTAssertEqual(knob("EnvMulti", "Level2"), .sustain)
        XCTAssertEqual(knob("EnvADDSR", "Decay2"), .decay)
        XCTAssertEqual(knob("EnvADDSR", "Level1"), .sustain)
        XCTAssertEqual(knob("Operator", "L3"), .sustain)
    }

    /// Mod. Rate to LFO i Random oraz efekty z własnym LFO. Tempo patcha (ClkGen)
    /// zostaje nietknięte — ma własną kontrolkę w górnej belce.
    func testModRateTakesLfosAndRandomsButNotThePatchTempo() {
        XCTAssertEqual(knob("LfoA", "Rate"), .modRate)
        XCTAssertEqual(knob("RandomA", "Rate"), .modRate)
        XCTAssertEqual(knob("Flanger", "Rate"), .modRate)
        XCTAssertEqual(knob("Phaser", "Freq"), .modRate)
        XCTAssertNil(knob("ClkGen", "Rate"))
    }

    /// Rezonans filtrów i sprzężenie Phasera/Flangera pod jedną gałką; częstotliwości
    /// odcięcia, kształty fal i „barwa" efektów pod Timbre, dry/wet pod Effects.
    func testTimbreAndResonanceFollowTheOriginal() {
        XCTAssertEqual(knob("FltClassic", "Res"), .resonance)
        XCTAssertEqual(knob("Phaser", "FeedBack"), .resonance)
        XCTAssertNil(knob("FltPhase", "FB"), "sprzężenie filtra fazowego nie jest rezonansem")
        XCTAssertEqual(knob("FltClassic", "Freq"), .timbre)
        XCTAssertNil(knob("Eq2Band", "LoFreq"))
        XCTAssertEqual(knob("OscB", "FmAmount"), .timbre)
        XCTAssertEqual(knob("Noise", "Color"), .timbre)
        XCTAssertEqual(knob("StChorus", "Detune"), .timbre)
        XCTAssertEqual(knob("Saturate", "Amount"), .timbre)
        XCTAssertEqual(knob("Reverb", "DryWet"), .effects)
        XCTAssertEqual(knob("StChorus", "Amount"), .effects)
    }

    /// EnvADR jest raz obwiednią AD, raz AR — jego trzeci czas przechodzi między gałkami
    /// Decay i Release razem z przełącznikiem `DcyRel`, tak jak w oryginale.
    func testEnvADRReleaseFollowsTheDecayReleaseSwitch() throws {
        let def = try XCTUnwrap(ModuleDatabase.module(shortName: "EnvADR"))
        var module = G2Module(id: 1, typeID: def.id, area: .voice)
        module.parameters = [Int](repeating: 0, count: def.paramNames.count)
        let release = try XCTUnwrap(def.paramNames.firstIndex(of: "Release"))
        let mode = try XCTUnwrap(def.paramNames.firstIndex(of: "DcyRel"))

        XCTAssertEqual(G2PatchAdjuster.knob(module: module, paramIndex: release), .decay, "AD")
        module.parameters[mode] = 1
        XCTAssertEqual(G2PatchAdjuster.knob(module: module, paramIndex: release), .release, "AR")
        // Bez wartości modułu zostaje klasa z tabeli.
        XCTAssertEqual(G2PatchAdjuster.knob(moduleTypeID: def.id, paramIndex: release), .release)
        XCTAssertEqual(G2PatchAdjuster.knob(module: module, paramIndex: mode), nil)
    }

    /// Selektory, przełączniki i modulacje zostają poza Adjusterem — gałka ma ruszać
    /// wartościami, a nie trybami.
    func testSwitchesAndModulationDepthsStayOut() {
        XCTAssertNil(knob("EnvADSR", "OutputType"))
        XCTAssertNil(knob("ModADSR", "AttackMod"))
        XCTAssertNil(knob("OscA", "Waveform"))
        XCTAssertNil(knob("FltClassic", "Kbt"))
    }

    // MARK: - Gałka w stanie edytora

    /// Powrót gałki na środek przywraca patch co do bajtu — punkt odniesienia jest
    /// zdjęciem sprzed pierwszego ruchu, a nie wartością bieżącą.
    func testKnobBackAtTheCentreRestoresEveryValue() throws {
        let state = PatchState()
        state.slots = try [fixturePatch("EnvFx.pch2")]
        let before = snapshot(state)
        XCTAssertFalse(G2PatchAdjuster.targets(in: state.slots[0]).isEmpty)

        state.setAdjuster(.attack, to: 30)
        XCTAssertNotEqual(snapshot(state), before, "gałka nie ruszyła żadnego parametru")

        state.setAdjuster(.attack, to: 0)
        XCTAssertEqual(snapshot(state), before)
    }

    /// Gałki nie są parametrami patcha: zmiana wariacji utrwala to, co zrobiły,
    /// i odstawia je na środek (instrukcja, str. 113).
    func testChangingTheContextCommitsAndRecentresTheKnobs() throws {
        let state = PatchState()
        state.slots = try [fixturePatch("EnvFx.pch2")]
        state.setAdjuster(.attack, to: -40)
        XCTAssertEqual(state.adjusterValue(.attack), -40)

        state.commitAdjuster()
        XCTAssertEqual(state.adjusterValue(.attack), 0)

        // Po utrwaleniu punktem odniesienia jest to, co na ekranie — powrót na środek
        // nie odkręca już niczego.
        let afterCommit = snapshot(state)
        state.setAdjuster(.attack, to: 0)
        XCTAssertEqual(snapshot(state), afterCommit)
    }

    /// Ręczna zmiana parametru przy odkręconej gałce nie ginie przy następnym ruchu:
    /// zdjęcie dostaje nową bazę (wstecz z obecnego położenia), więc gałka liczy dalej
    /// od tego, co użytkownik ustawił, a powrót na środek zostawia jego zmianę.
    func testManualChangeWhileTheKnobIsTurnedRebasesTheSnapshot() throws {
        let state = PatchState()
        state.slots = try [fixturePatch("EnvFx.pch2")]
        let target = try XCTUnwrap(G2PatchAdjuster.targets(in: state.slots[0])
            .first { $0.knob == .attack && $0.maxValue == 127 })

        state.setAdjuster(.attack, to: 25)
        state.setParameter(moduleID: target.moduleID, paramIndex: target.paramIndex,
                           value: 100, area: target.area)

        // Gałka na środek: baza 73 (= 100 policzone wstecz z +25), nie stara wartość.
        state.setAdjuster(.attack, to: 0)
        XCTAssertEqual(value(state, target), 73)
        // I z powrotem na +25: dokładnie to, co użytkownik ustawił ręcznie.
        state.setAdjuster(.attack, to: 25)
        XCTAssertEqual(value(state, target), 100)
    }

    /// To samo, gdy parametr przestawi gałka na froncie Norda.
    func testChangeFromTheDeviceRebasesTheSnapshotToo() throws {
        let state = PatchState()
        state.slots = try [fixturePatch("EnvFx.pch2")]
        let target = try XCTUnwrap(G2PatchAdjuster.targets(in: state.slots[0])
            .first { $0.knob == .attack && $0.maxValue == 127 })

        state.setAdjuster(.attack, to: 25)
        state.applyDeviceParameter(slot: 0, area: target.area, moduleID: target.moduleID,
                                   paramIndex: target.paramIndex, value: 100,
                                   variation: state.slots[0].activeVariation)
        state.setAdjuster(.attack, to: 0)
        XCTAssertEqual(value(state, target), 73)
    }

    /// Gałka wysyła do Norda wszystkie swoje parametry jedną paczką — nie po jednym.
    func testKnobSendsAllItsChangesAsOneBatch() throws {
        let state = PatchState()
        state.slots = try [fixturePatch("EnvFx.pch2")]
        let expected = G2PatchAdjuster.targets(in: state.slots[0])
            .filter { $0.knob == .attack && value(state, $0) != $0.maxValue }.count
        var batches: [[G2ParameterChange]] = []
        var singles = 0
        state.onLiveParameterBatch = { _, changes, _ in batches.append(changes) }
        state.onLiveParameterChange = { _, _, _, _, _, _ in singles += 1 }

        state.setAdjuster(.attack, to: 50)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.count, expected, "+50 rusza każdy atak, który nie stał na maksimum")
        XCTAssertEqual(singles, 0)

        // Ten sam ruch drugi raz niczego nie zmienia, więc i nic nie leci.
        state.setAdjuster(.attack, to: 50)
        XCTAssertEqual(batches.count, 1)
    }

    private func value(_ state: PatchState, _ target: G2AdjusterTarget) -> Int? {
        state.slots[0].modules(in: target.area).first { $0.id == target.moduleID }?
            .parameters[target.paramIndex]
    }

    private func snapshot(_ state: PatchState) -> [Int] {
        var values: [Int] = []
        for area in [PatchArea.voice, PatchArea.fx] {
            for module in state.slots[0].modules(in: area).sorted(by: { $0.id < $1.id }) {
                values.append(contentsOf: module.parameters)
            }
        }
        return values
    }
}
