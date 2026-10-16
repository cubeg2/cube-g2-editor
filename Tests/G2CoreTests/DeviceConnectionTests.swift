import G2Core
@testable import G2EditorCore
import XCTest

/// Most edytor ↔ urządzenie bez podłączonego Norda. Testujemy to, co da się sprawdzić
/// bez sprzętu: kontrakty „bez połączenia nic nie robimy, ale zapamiętujemy wybór".
/// Sama wysyłka bajtów jest sprawdzana na żywym G2 (`USBProbe`) → [[Docs/usb/actor]].
@MainActor
final class DeviceConnectionTests: XCTestCase {
    func testSelectedSlotIsRememberedWhileDisconnected() async {
        let device = DeviceConnection()
        XCTAssertEqual(device.activeSlot, 0)

        await device.selectTargetSlot(2)

        // Bez połączenia komenda nie ma dokąd pójść, ale wybór musi zostać zapamiętany —
        // `attemptConnect` wysyła `SelectSlot(activeSlot)` zaraz po handshake.
        XCTAssertEqual(device.activeSlot, 2)
        XCTAssertEqual(device.status, .searching)
    }

    func testUploadDoesNothingWithoutDevice() async {
        let device = DeviceConnection()

        await device.upload(patches: [G2Patch()], activeSlot: 0)

        // Otwieranie plików bez Norda to normalna praca — wysyłka ma cicho odmówić,
        // a nie zostawić po sobie statusu błędu ani wiszącego komunikatu o postępie.
        XCTAssertNil(device.sendProgress)
        XCTAssertFalse(device.isSending)
        XCTAssertEqual(device.status, .searching)
    }
}
