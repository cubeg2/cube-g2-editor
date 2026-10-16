import G2Core
import XCTest

/// Tekst wartości parametru — ten sam, który pokazuje moduł na kanwie.
final class G2ParameterTextTests: XCTestCase {
    private func module(_ typeID: Int) -> G2Module {
        var module = G2Module(id: 1, typeID: typeID, area: .voice)
        module.parameters = ModuleDefaultsDatabase.defaults(forTypeID: typeID)
        return module
    }

    func testNamePrefersPanelLabelAndFallsBackToCodeName() {
        XCTAssertEqual(G2ParameterText.name(moduleTypeID: 4, paramIndex: 0), "Dest") // 2-Out
        XCTAssertEqual(G2ParameterText.name(moduleTypeID: 9999, paramIndex: 2), "Param 2")
    }

    func testOscillatorFrequencyReadsLikeTheModuleDisplay() {
        let osc = module(7) // OscB, FreqCoarse=64 w trybie Semi → E4 / 0 półtonów
        let text = G2ParameterText.value(paramIndex: 0, value: 64, module: osc)
        XCTAssertFalse(text.isEmpty)
        XCTAssertNotEqual(text, "64", "częstotliwość ma funkcję tekstu, nie gołą liczbę")
    }

    func testEnvelopeTimeHasUnits() {
        let env = module(20) // EnvADSR
        let attack = G2ParameterText.value(paramIndex: 1, value: 64, module: env)
        XCTAssertTrue(attack.hasSuffix("m") || attack.hasSuffix("s"), attack) // „0.5m" jak na wyświetlaczu modułu
    }

    func testActiveButtonHasTwoStates() throws {
        let options = try XCTUnwrap(G2ParameterText.buttonOptions(moduleTypeID: 92, paramIndex: 5)) // FltClassic.Active
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual([options.text(for: 0), options.text(for: 1)], ["Off", "On"])
    }

    func testKnobParameterIsNotAButton() {
        XCTAssertNil(G2ParameterText.buttonOptions(moduleTypeID: 92, paramIndex: 0)) // FltClassic.Freq
    }
}
