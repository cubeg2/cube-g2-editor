import G2Core
import XCTest

/// Graf sygnału: kable → krawędzie moduł → moduł, dojście do wyjścia, powody ciszy.
final class G2SignalGraphTests: XCTestCase {
    private enum Kind {
        static let keyboard = 1, out = 4, oscB = 7, lfoA = 26, fltClassic = 92
    }

    private func module(_ id: Int, _ typeID: Int) -> G2Module {
        var module = G2Module(id: id, typeID: typeID, area: .voice)
        module.parameters = ModuleDefaultsDatabase.defaults(forTypeID: typeID)
        return module
    }

    private func cable(_ from: Int, _ output: Int, _ to: Int, _ input: Int,
                       sourceIsOutput: Bool = true) -> G2Cable
    {
        G2Cable(fromModule: from, fromConnector: output, toModule: to, toConnector: input,
                color: .red, area: .voice, sourceIsOutput: sourceIsOutput)
    }

    /// Kbd(1) → Osc(2) → Flt(3) → Out(4); LFO(5) bez kabla.
    private func basicPatch() -> G2Patch {
        var patch = G2Patch()
        patch.add(module: module(1, Kind.keyboard))
        patch.add(module: module(2, Kind.oscB))
        patch.add(module: module(3, Kind.fltClassic))
        patch.add(module: module(4, Kind.out))
        patch.add(module: module(5, Kind.lfoA))
        patch.add(cable: cable(1, 0, 2, 0)) // Kbd.Pitch -> Osc.Pitch
        patch.add(cable: cable(2, 0, 3, 0)) // Osc.Out -> Flt.In
        patch.add(cable: cable(3, 0, 4, 0)) // Flt.Out -> Out.InL
        return patch
    }

    func testEdgesFollowCablesAndChainReachesOutput() {
        let graph = G2SignalGraph(patch: basicPatch(), area: .voice)

        XCTAssertEqual(graph.upstream(of: 3), [2])
        XCTAssertEqual(graph.downstream(of: 2), [3])
        XCTAssertEqual(graph.sources, [1])
        XCTAssertEqual(graph.sinks, [4])
        XCTAssertEqual(graph.chains(), [[1, 2, 3, 4]])
        XCTAssertEqual(graph.depths(), [1: 0, 2: 1, 3: 2, 4: 3, 5: 0])
    }

    func testUnconnectedModuleIsSilentForLackOfRoute() {
        let graph = G2SignalGraph(patch: basicPatch(), area: .voice)

        XCTAssertTrue(graph.isAudible(2))
        XCTAssertFalse(graph.isAudible(5))
        XCTAssertEqual(graph.silenceReasons, [5: .noRouteToOutput])
    }

    func testSwitchedOffFilterSilencesEverythingBehindIt() throws {
        var patch = basicPatch()
        let active = try XCTUnwrap(ModuleDatabase.module(id: Kind.fltClassic)?.paramNames.firstIndex(of: "Active"))
        patch.setParameter(moduleID: 3, paramIndex: active, value: 0, in: .voice)
        let graph = G2SignalGraph(patch: patch, area: .voice)

        XCTAssertEqual(graph.silenceReasons[3], .inactive)
        XCTAssertEqual(graph.silenceReasons[2], .behindInactiveModule)
        XCTAssertEqual(graph.silenceReasons[1], .behindInactiveModule)
        XCTAssertTrue(graph.isAudible(4))
    }

    /// Kabel wejście-wejście nie jest źródłem, tylko rozgałęzieniem — i ma kierunek: w pliku
    /// `to` jest gniazdem zasilanym, a `from` z niego bierze. Wzorzec z patchy Clavii:
    /// sygnał wchodzi w InR, a InL bierze z InR.
    func testInputToInputCablePassesTheSourceAlongTheFileDirection() {
        var patch = G2Patch()
        for (id, type) in [(1, Kind.keyboard), (2, Kind.oscB), (3, Kind.fltClassic), (4, Kind.out)] {
            patch.add(module: module(id, type))
        }
        patch.add(cable: cable(1, 0, 2, 0))
        patch.add(cable: cable(2, 0, 3, 0))
        patch.add(cable: cable(3, 0, 4, 1)) // Flt.Out -> Out.InR
        patch.add(cable: cable(4, 0, 4, 1, sourceIsOutput: false)) // InL bierze z InR
        let graph = G2SignalGraph(patch: patch, area: .voice)

        let toLeft = graph.edges.filter { $0.toModule == 4 && $0.toInput == 0 }
        XCTAssertEqual(toLeft, [G2SignalGraph.Edge(fromModule: 3, fromOutput: 0, toModule: 4, toInput: 0)])
        XCTAssertEqual(graph.upstream(of: 4), [3])
        XCTAssertTrue(graph.silenceReasons.isEmpty)
    }

    /// Ten sam kabel wpięty odwrotnie do przepływu ucisza cały patch (usterka #100):
    /// InR nie ma źródła, a InL bierze właśnie z niego — wyjście nie dostaje nic.
    func testInputToInputCableAgainstTheFlowLeavesTheOutputWithoutSignal() {
        var patch = basicPatch()
        patch.add(cable: cable(4, 0, 4, 1, sourceIsOutput: false)) // InL bierze z pustego InR
        let graph = G2SignalGraph(patch: patch, area: .voice)

        XCTAssertTrue(graph.edges.filter { $0.toModule == 4 }.isEmpty)
        XCTAssertEqual(graph.upstream(of: 4), [])
        XCTAssertEqual(graph.silenceReasons[3], .noRouteToOutput)
        XCTAssertEqual(graph.silenceReasons[2], .noRouteToOutput)
    }

    func testFeedbackLoopDoesNotHangDepthsOrChains() {
        var patch = basicPatch()
        patch.add(cable: cable(3, 0, 2, 3)) // Flt.Out -> Osc.FmMod (sprzężenie)
        let graph = G2SignalGraph(patch: patch, area: .voice)

        XCTAssertEqual(graph.depths()[4], 3)
        XCTAssertEqual(graph.chains(), [[1, 2, 3, 4]])
        XCTAssertTrue(graph.isAudible(2))
    }
}
