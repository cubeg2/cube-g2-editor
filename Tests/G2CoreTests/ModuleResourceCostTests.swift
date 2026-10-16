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

    func testUnknownTypeHasNoCost() {
        XCTAssertNil(ModuleResourceCostDatabase.cost(typeID: 999))
    }
}
