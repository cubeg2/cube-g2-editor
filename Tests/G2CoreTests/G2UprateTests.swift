// G2UprateTests.swift
// Uprate — moduł z dwukolorowym wejściem przechodzi na częstotliwość audio, gdy dostaje
// sygnał audio. Zgłoszenie z sąsiedniego edytora (2026-10-17): piła przez obwiednię
// w NOWYM patchu brzmiała z aliasingiem, bo flaga nie szła do Norda.

import G2Core
@testable import G2EditorCore
import XCTest

final class G2UprateTests: XCTestCase {
    private static let oscB = 7 // wyjście Out: audio
    private static let envADSR = 20 // wejście In: dwukolorowe, AM: sterowanie; wyjście Out: dwukolorowe
    private static let lfoC = 24 // wyjście Out: sterowanie
    private static let levAmp = 81 // In i Out: dwukolorowe
    private static let output = 4

    private func patch(_ types: [Int], cables: [G2Cable]) -> G2Patch {
        var patch = G2Patch()
        patch.voiceModules = types.enumerated().map { G2Module(id: $0 + 1, typeID: $1, area: .voice) }
        patch.voiceCables = cables
        return patch
    }

    private func cable(_ from: Int, _ fromConnector: Int = 0, to: Int, _ toConnector: Int = 0,
                       fromOutput: Bool = true) -> G2Cable
    {
        G2Cable(fromModule: from, fromConnector: fromConnector, toModule: to, toConnector: toConnector,
                color: .red, area: .voice, sourceIsOutput: fromOutput)
    }

    private func uprates(_ patch: G2Patch) -> [Bool] {
        patch.voiceModules.map(\.uprate)
    }

    func testAudioIntoEnvelopeUpratesIt() {
        var patch = patch([Self.oscB, Self.envADSR], cables: [cable(1, to: 2)])
        patch.recomputeUprates()
        XCTAssertEqual(uprates(patch), [false, true])
    }

    func testControlSourceLeavesModuleAtControlRate() {
        var patch = patch([Self.lfoC, Self.envADSR], cables: [cable(1, to: 2)])
        patch.recomputeUprates()
        XCTAssertEqual(uprates(patch), [false, false])
    }

    /// Wejście jednokolorowe (AM obwiedni) nie przełącza modułu, nawet gdy płynie nim audio.
    func testOnlyTwoColourInputsCount() {
        var patch = patch([Self.oscB, Self.envADSR], cables: [cable(1, to: 2, 2)])
        patch.recomputeUprates()
        XCTAssertEqual(uprates(patch), [false, false])
    }

    /// Dwukolorowe wyjście modułu z uprate jest czerwone — następny moduł też przechodzi.
    func testUprateTravelsDownTheChain() {
        var patch = patch([Self.oscB, Self.envADSR, Self.levAmp],
                          cables: [cable(1, to: 2), cable(2, 1, to: 3)])
        patch.recomputeUprates()
        XCTAssertEqual(uprates(patch), [false, true, true])
    }

    func testInputToInputChainCarriesAudio() {
        var patch = patch([Self.oscB, Self.envADSR, Self.levAmp],
                          cables: [cable(1, to: 2), cable(2, 0, to: 3, fromOutput: false)])
        patch.recomputeUprates()
        XCTAssertEqual(uprates(patch), [false, true, true])
    }

    func testRemovingTheAudioCableDropsUprate() {
        var patch = patch([Self.oscB, Self.envADSR, Self.levAmp], cables: [])
        patch.voiceModules[1].uprate = true
        patch.voiceModules[2].uprate = true
        patch.recomputeUprates()
        XCTAssertEqual(uprates(patch), [false, false, false])
    }

    /// Scenariusz ze zgłoszenia: nowy patch, piła → obwiednia → wyjście, kable z kanwy.
    /// Zarówno model, jak i stan wysłany do Norda mają mieć obwiednię z uprate.
    @MainActor
    func testCableDrawnInTheEditorUpratesTheEnvelope() {
        let state = PatchState()
        state.slots = [patch([Self.oscB, Self.envADSR, Self.output], cables: [])]
        var sent: G2Patch?
        state.onLiveStructureChange = { _, patch in sent = patch }

        state.addCable(cable(1, to: 2))
        state.addCable(cable(2, 1, to: 3))

        XCTAssertEqual(uprates(state.slots[0]), [false, true, false])
        XCTAssertEqual(sent.map(uprates), [false, true, false])

        state.removeCable(cable(1, to: 2))
        XCTAssertEqual(uprates(state.slots[0]), [false, false, false])
    }

    func testDiffSendsUprateOfSurvivingModuleAfterItsCable() {
        let before = patch([Self.oscB, Self.envADSR], cables: [])
        var after = patch([Self.oscB, Self.envADSR], cables: [cable(1, to: 2)])
        after.recomputeUprates()

        let diff = G2PatchDiff.between(before, after)
        XCTAssertEqual(diff.cablesToAdd.count, 1)
        XCTAssertEqual(diff.modulesToUprate.map(\.id), [2])
        XCTAssertTrue(G2PatchDiff.between(after, after).isEmpty)
    }

    // MARK: - Kolory kabli

    /// Dwukolorowe wyjście świeci tak, jak liczy moduł: niebiesko bez uprate,
    /// czerwono z nim. Jednokolorowe zawsze tak samo.
    func testCableColourOfOutputFollowsUprate() {
        var env = G2Module(id: 1, typeID: Self.envADSR, area: .voice)
        XCTAssertEqual(env.cableColor(forOutput: 1), .blue)
        env.uprate = true
        XCTAssertEqual(env.cableColor(forOutput: 1), .red)
        XCTAssertEqual(G2Module(id: 2, typeID: Self.oscB, area: .voice).cableColor(forOutput: 0), .red)
        XCTAssertEqual(G2Module(id: 3, typeID: Self.lfoC, area: .voice).cableColor(forOutput: 0), .blue)
    }

    /// Jak w oryginalnym edytorze: przy zmianie uprate przemalowuje się całe drzewo
    /// kabli z dwukolorowych wyjść — wszystkie gałęzie i dalsze ogniwa wejście→wejście.
    func testUprateRecoloursCablesFromTwoColourOutputs() {
        var cables = [cable(1, to: 2), cable(2, 1, to: 3), cable(2, 1, to: 4),
                      cable(4, 0, to: 5, fromOutput: false)]
        for index in 1 ..< cables.count {
            cables[index].color = .blue
        }
        var patch = patch([Self.oscB, Self.envADSR, Self.levAmp, Self.levAmp, Self.levAmp], cables: cables)
        patch.recomputeUprates()
        XCTAssertEqual(patch.voiceCables.map(\.color), [.red, .red, .red, .red])

        patch.remove(cable: patch.voiceCables[0])
        patch.recomputeUprates()
        XCTAssertEqual(patch.voiceCables.map(\.color), [.blue, .blue, .blue])
    }

    /// Kolor wybrany ręcznie zostaje, dopóki moduł nie zmieni częstotliwości.
    func testUserColourSurvivesWhenUprateDoesNotChange() {
        var envCable = cable(2, 1, to: 3)
        envCable.color = .green
        var patch = patch([Self.lfoC, Self.envADSR, Self.levAmp], cables: [cable(1, to: 2), envCable])
        patch.recomputeUprates()
        XCTAssertEqual(patch.voiceCables[1].color, .green)
    }

    /// Module AB Code w oryginale, `SUB_COMMAND_SET_MODULE_UPRATE` w G2-Edit,
    /// `S_SET_UPRATE` u BVerhue: numer 0x2A, obszar, numer modułu, wartość.
    func testUprateMoleculeLayout() {
        var module = G2Module(id: 5, typeID: Self.envADSR, area: .voice)
        module.uprate = true
        XCTAssertEqual(G2UsbProtocol.setModuleUprateMolecule(module), [0x2A, 1, 5, 1])
        module.area = .fx
        module.uprate = false
        XCTAssertEqual(G2UsbProtocol.setModuleUprateMolecule(module), [0x2A, 0, 5, 0])
    }
}
