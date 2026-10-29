// ModuleResourceCostTests.swift
// Czy obciążenie policzone z tabeli zgadza się z tym, co pokazał prawdziwy G2.

@testable import G2Core
import XCTest

final class ModuleResourceCostTests: XCTestCase {
    private func area(of typeID: Int, count: Int) -> G2PatchLoad {
        let modules = (0 ..< count).map { G2Module(id: $0 + 1, typeID: typeID, area: .voice) }
        return .estimate(area: .voice, modules: modules)
    }

    /// Punkt odniesienia ze sprzętu: 22 × `DlyClock` w jednym obszarze, 2026-09-08.
    /// Nord pokazał wtedy pamięć 2882/2992 i moc 75%. Te same liczby muszą wyjść
    /// z tabeli — to jedyny dowód, że wolno jej użyć zamiast raportu `0x72`.
    ///
    /// Moc wychodzi 75,42% i panel pisze „75%", bo zaokrągla do pełnych procentów.
    /// Zapisuję tu wartość dokładną: przy 75,0 test przechodziłby także dla tabeli
    /// zaniżonej o pół procent, a to już byłby inny koszt modułu.
    func testTwentyTwoDlyClocksMatchTheDeviceReading() {
        let load = area(of: 178, count: 22)

        XCTAssertEqual(load.yMemory, 2882)
        XCTAssertEqual(load.criticalResource.resource, .yMemory)
        XCTAssertEqual(load.criticalResource.limit, 2992)
        XCTAssertEqual(load.memoryPercent, 96.32, accuracy: 0.01)
        XCTAssertEqual(load.cyclesPercent, 75.42, accuracy: 0.01)
    }

    /// Wąskie gardło zależy od typu i nie zawsze jest nim strona zerowa (ta wygrywa
    /// dla 125 ze 168 typów). `DlyClock` rozbija się o pamięć Y, a `OscB` o pamięć
    /// programu — 186 jednostek z 6 498 na moduł to więcej niż 3 ze 128 strony zerowej.
    func testTheBottleneckDependsOnTheModuleType() {
        XCTAssertEqual(area(of: 7, count: 10).criticalResource.resource, .programMemory)
    }

    func testEmptyAreaIsZero() {
        let load = G2PatchLoad.estimate(area: .fx, modules: [])
        XCTAssertEqual(load.cyclesPercent, 0)
        XCTAssertEqual(load.memoryPercent, 0)
    }

    /// Patch potrafi żądać więcej, niż G2 ma — i tak samo musi to policzyć tabela,
    /// bo inaczej „mieści się" i „nie mieści się" przestałyby cokolwiek znaczyć.
    func testDemandAboveTheLimitIsNotClamped() {
        XCTAssertGreaterThan(area(of: 178, count: 40).memoryPercent, 100)
    }

    /// Wycenione są wszystkie typy z katalogu — inaczej patch z nieopisanym modułem
    /// pokazywałby zaniżone zużycie, nie mówiąc o tym ani słowem.
    func testEveryCatalogModuleHasACost() {
        let missing = ModuleDatabase.all.filter { ModuleResourceCostDatabase.cost(typeID: $0.id) == nil }
        XCTAssertEqual(missing.map(\.shortName), [], "typy bez zmierzonego kosztu")
        XCTAssertEqual(ModuleResourceCostDatabase.count, ModuleDatabase.all.count)
    }

    /// Uprate przenosi cały zegar „blue” na „red” — tak liczy firmware (`--dspcal` 2026-10-27:
    /// `OscB` 66/8 → 74/0). Bez tego Vermona PERfourMER pokazywał 69 % zamiast 117 %.
    func testUprateMovesBlueCyclesToRed() {
        var module = G2Module(id: 1, typeID: 7, area: .voice)
        module.uprate = true
        let load = G2PatchLoad.estimate(area: .voice, modules: [module])
        XCTAssertEqual(load.cyclesRed, 66 + 8)
        XCTAssertEqual(load.cyclesBlue, 0)
    }

    /// Podłączone wejście Pitch włącza w oscylatorze kod modulacji: +19 cykli „blue”
    /// (`--dspcal` 2026-10-27). Sam kabel i `Constant` kosztują tylko stronę zerową.
    func testConnectedPitchInputCostsCycles() {
        let osc = G2Module(id: 1, typeID: 7, area: .voice)
        let constant = G2Module(id: 2, typeID: 43, area: .voice)
        let cable = G2Cable(fromModule: 2, fromConnector: 0, toModule: 1, toConnector: 0, color: .blue, area: .voice)
        let bare = G2PatchLoad.estimate(area: .voice, modules: [osc, constant])
        let wired = G2PatchLoad.estimate(area: .voice, modules: [osc, constant], cables: [cable])
        XCTAssertEqual(wired.cyclesBlue - bare.cyclesBlue, 19)
        XCTAssertEqual(wired.cyclesRed, bare.cyclesRed)
    }

    /// Szacunek z całego patcha liczy uprate tak, jak ustawi go edytor przy wgraniu —
    /// także gdy plik zapisano bez flag (tak zapisywał MCP).
    func testPatchEstimateRecomputesUprateFromCables() {
        var patch = G2Patch()
        patch.add(module: G2Module(id: 1, typeID: 7, area: .voice))
        patch.add(module: G2Module(id: 2, typeID: 18, area: .voice))
        patch.add(cable: G2Cable(fromModule: 1, fromConnector: 0, toModule: 2, toConnector: 2,
                                 color: .red, area: .voice))
        let fromFlags = G2PatchLoad.estimate(area: .voice, modules: patch.modules(in: .voice),
                                             cables: patch.cables(in: .voice))
        let asSent = G2PatchLoad.estimate(area: .voice, patch: patch)
        // X-Fade (0/14) dostaje uprate od piły oscylatora: 14 cykli przechodzi na „red”.
        XCTAssertEqual(asSent.cyclesRed - fromFlags.cyclesRed, 14)
        XCTAssertEqual(fromFlags.cyclesBlue - asSent.cyclesBlue, 14)
    }

    /// Wgrany całym patchem obszar bierze stronę zerową na klawiaturę (Keyboard: 6 wyjść
    /// = 6 jednostek) i na wspólną pulę — raz, w wielkości najbardziej wymagającego typu:
    /// LfoA 9 > FltClassic 5 > OscB 2. Zmierzone 2026-10-28, voice i fx tak samo —
    /// Hell02 ma Keyboard i LfoB w fx: raport `0x72` 25, tabela bez puli 10.
    func testAreaAddsKeyboardAndTheLargestSharedPool() {
        let types = [1, 7, 7, 92, 26, 20]
        let own = types.compactMap { ModuleResourceCostDatabase.cost(typeID: $0)?.zeroPageMemory }.reduce(0, +)
        for area in PatchArea.allCases {
            let modules = types.enumerated().map { G2Module(id: $0.offset + 1, typeID: $0.element, area: area) }
            XCTAssertEqual(G2PatchLoad.estimate(area: area, modules: modules).zeroPageMemory, own + 6 + 9)
        }
    }

    /// Druga sztuka typu z pulą płaci tylko swój zwykły koszt: LfoB 11 → 13 jednostek.
    func testSecondLfoInVoiceCostsOnlyItsOwnZeroPage() {
        XCTAssertEqual(area(of: 190, count: 1).zeroPageMemory, 11)
        XCTAssertEqual(area(of: 190, count: 2).zeroPageMemory, 13)
    }

    func testUnknownTypeHasNoCost() {
        XCTAssertNil(ModuleResourceCostDatabase.cost(typeID: 999))
    }
}
