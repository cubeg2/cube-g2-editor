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

    // MARK: Duży patch — pytanie przed wysyłką

    func testOnlyMessagesAboveTheThresholdAskForConfirmation() {
        XCTAssertFalse(DeviceConnection.isLargeUpload(sectionBytes: 15093), "największy potwierdzony performance")
        XCTAssertFalse(DeviceConnection.isLargeUpload(sectionBytes: DeviceConnection.largeUploadThreshold))
        XCTAssertTrue(DeviceConnection.isLargeUpload(sectionBytes: DeviceConnection.largeUploadThreshold + 1))
    }

    func testLargeUploadWaitsForTheAnswerAndReturnsIt() async {
        let device = DeviceConnection()

        async let answer = device.confirmLargeUpload(subject: "Slot B", noun: "patch", bytes: 36 * 1024)
        while device.largeUploadPrompt == nil { await Task.yield() }

        XCTAssertEqual(device.largeUploadPrompt?.subject, "Slot B")
        XCTAssertEqual(device.largeUploadPrompt?.title, "Large Patch")
        XCTAssertEqual(device.largeUploadPrompt?.bytes, 36 * 1024)
        XCTAssertEqual(device.largeUploadPrompt?.message.contains("36 KB"), true)
        XCTAssertEqual(device.largeUploadPrompt?.message.contains("63 KB"), true)
        device.answerLargeUpload(send: true)
        let sent = await answer

        XCTAssertTrue(sent)
        XCTAssertNil(device.largeUploadPrompt)
    }

    func testDecliningALargeUploadIsAnswerFalse() async {
        let device = DeviceConnection()

        async let answer = device.confirmLargeUpload(subject: "Slot A", noun: "patch", bytes: 40 * 1024)
        while device.largeUploadPrompt == nil { await Task.yield() }
        device.answerLargeUpload(send: false)

        let sent = await answer
        XCTAssertFalse(sent)
    }

    /// Pytanie nie może wisieć na urządzeniu, którego już nie ma.
    func testDisconnectingAnswersAPendingLargeUploadWithNo() async {
        let device = DeviceConnection()

        async let answer = device.confirmLargeUpload(subject: "Slot C", noun: "patch", bytes: 40 * 1024)
        while device.largeUploadPrompt == nil { await Task.yield() }
        await device.disconnect()

        let sent = await answer
        XCTAssertFalse(sent)
        XCTAssertNil(device.largeUploadPrompt)
    }

    func testAnsweringWithoutAQuestionDoesNothing() {
        let device = DeviceConnection()

        device.answerLargeUpload(send: true)

        XCTAssertNil(device.largeUploadPrompt)
    }

    /// Cały performance idzie jednym komunikatem, więc pytanie ma własne słowa — „performance”, nie „patch”.
    func testPerformancePromptTalksAboutThePerformance() async {
        let device = DeviceConnection()

        async let answer = device.confirmLargeUpload(subject: "Performance", noun: "performance", bytes: 36 * 1024)
        while device.largeUploadPrompt == nil { await Task.yield() }

        XCTAssertEqual(device.largeUploadPrompt?.message.hasPrefix("Performance: this performance is 36 KB."), true)
        XCTAssertEqual(device.largeUploadPrompt?.title, "Large Performance")
        device.answerLargeUpload(send: false)
        _ = await answer
    }

    func testDeclinedPerformanceSaysTheG2KeptItsPreviousOne() {
        let message = DeviceConnection.declinedPerformanceMessage(bytes: 40 * 1024)

        XCTAssertTrue(message.hasPrefix("Performance not sent"))
        XCTAssertTrue(message.contains("40 KB"))
        XCTAssertTrue(message.contains("previous performance"))
    }

    func testDeclinedLargeUploadExplainsWhyTheSlotWasNotSent() {
        let message = DeviceConnection.uploadFailureMessage(
            slot: 3, error: DeviceConnection.LargeUploadDeclined(bytes: 36 * 1024)
        )

        XCTAssertTrue(message.hasPrefix("Slot D: not sent"))
        XCTAssertTrue(message.contains("36 KB"))
        XCTAssertTrue(message.contains("Send to G2 Slot"), "mówi, jak wysłać mimo to")
    }
}
