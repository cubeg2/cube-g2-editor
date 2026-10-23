import G2Core
import XCTest

/// Wpisanie wartości z klawiatury — najbliższa pozycja gałki wg tekstu z kanwy.
final class G2ValueEntryTests: XCTestCase {
    private func module(_ typeID: Int) -> G2Module {
        var module = G2Module(id: 1, typeID: typeID, area: .voice)
        module.parameters = ModuleDefaultsDatabase.defaults(forTypeID: typeID)
        return module
    }

    private func entry(_ input: String, typeID: Int, param: Int, current: Int = 64) -> Int? {
        let module = module(typeID)
        return G2ValueEntry.value(for: input, current: current, in: 0 ... 127) {
            G2ParameterText.value(paramIndex: param, value: $0, module: module)
        }
    }

    private func text(_ value: Int?, typeID: Int, param: Int) -> String? {
        value.map { G2ParameterText.value(paramIndex: param, value: $0, module: module(typeID)) }
    }

    func testSecondsAndMillisecondsMeetOnTheSameScale() {
        // EnvADSR Attack: wyświetlacz pisze „947m" i „1.85s"
        let half = entry("0.5 s", typeID: 20, param: 1)
        XCTAssertEqual(half, entry("500ms", typeID: 20, param: 1))
        XCTAssertEqual(text(entry("1.85s", typeID: 20, param: 1), typeID: 20, param: 1), "1.85s")
    }

    func testKilohertzAsKOrKHz() {
        // FltClassic Freq
        let value = entry("880Hz", typeID: 92, param: 0)
        XCTAssertEqual(text(value, typeID: 92, param: 0), "880Hz")
        XCTAssertEqual(entry("2.49k", typeID: 92, param: 0), entry("2.49 kHz", typeID: 92, param: 0))
    }

    func testBareNumberUsesTheUnitShownNow() {
        // Gałka stoi na „523Hz" (63) — „880" to herce; na „1.48kHz" (81) — „2.49" to kiloherce.
        XCTAssertEqual(text(entry("880", typeID: 92, param: 0, current: 63), typeID: 92, param: 0), "880Hz")
        XCTAssertEqual(text(entry("2.49", typeID: 92, param: 0, current: 81), typeID: 92, param: 0), "2.49kHz")
    }

    func testLfoRateKeepsSecondsAndHertzApart() {
        // LfoB (24) Rate: wolny koniec w sekundach okresu, szybki w hercach
        let value = entry("1Hz", typeID: 24, param: 0)
        XCTAssertTrue(text(value, typeID: 24, param: 0)?.hasSuffix("Hz") == true)
    }

    func testRawPositionInParentheses() {
        XCTAssertEqual(entry("(70)", typeID: 92, param: 0), 70)
        XCTAssertEqual(entry("(200)", typeID: 92, param: 0), 127)
    }

    func testExactLabelWinsOverNumbers() {
        // OscB Coarse: „-64  +0" — porównanie bez spacji
        XCTAssertEqual(entry("-55 +0", typeID: 7, param: 0), 9)
    }

    func testNonsenseGivesNil() {
        XCTAssertNil(entry("abc", typeID: 92, param: 0))
        XCTAssertNil(entry("5 BPM", typeID: 92, param: 0))
    }
}
