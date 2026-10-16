@testable import G2EditorCore
import XCTest

/// Próg alarmowy paska DSP. Testy stoją tu, bo w panelu siedziały dwa błędy naraz
/// i żaden nie był widoczny w kodzie widoku (2026-09-07, [[Docs/context/bug-history]] #73).
final class DSPLoadLevelTests: XCTestCase {
    /// Sedno usterki zgłoszonej z ekranu: pasek pokazywał „100%" na pomarańczowo.
    /// Etykieta zaokrągla, więc próg też musi — inaczej 99,6% ma dwa różne oblicza.
    func testRoundedHundredIsCriticalEvenWhenRawValueIsBelowIt() {
        XCTAssertEqual(DSPLoadLevel(percent: 99.6), .critical)
        XCTAssertEqual(DSPLoadLevel(percent: 100), .critical)
    }

    /// Czerwony musi być osiągalny: G2 nie dopuszcza modułu, który przekroczyłby limit,
    /// więc raport zatrzymuje się pod setką. Próg `>= 100` nie zapaliłby się nigdy.
    func testCriticalStartsBelowTheHundredSoTheDeviceCanReachIt() {
        XCTAssertEqual(DSPLoadLevel(percent: 98), .critical)
        XCTAssertEqual(DSPLoadLevel(percent: 97.4), .warning)
    }

    func testWarningBand() {
        XCTAssertEqual(DSPLoadLevel(percent: 89.4), .safe)
        XCTAssertEqual(DSPLoadLevel(percent: 89.5), .warning)
        XCTAssertEqual(DSPLoadLevel(percent: 95), .warning)
    }

    /// Pusty slot na żywym G2 — zmierzone 2026-09-07.
    func testEmptySlotIsSafe() {
        XCTAssertEqual(DSPLoadLevel(percent: 0), .safe)
    }
}
