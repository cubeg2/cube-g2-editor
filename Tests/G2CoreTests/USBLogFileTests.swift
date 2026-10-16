// USBLogFileTests.swift
// Nagłówek logu USB ma odpowiadać na pytanie „na czym to padło" — z pełną ścieżką pliku,
// żeby dało się przebieg powtórzyć → [[Docs/usb/emulator]].

@testable import G2EditorCore
import XCTest

final class USBLogFileTests: XCTestCase {
    private var file: URL!

    override func setUpWithError() throws {
        file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usb-log-\(UUID().uuidString)")
            .appendingPathComponent("usb.log")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    /// Log włącza się zwykle PO otwarciu pliku, więc sam nagłówek musi pamiętać patcha —
    /// inaczej pierwsza sesja diagnostyczna zaczyna się od „a co było wczytane?".
    func testHeaderNamesThePatchOpenedBeforeLoggingStarted() throws {
        let log = USBLogFile(file: file)
        log.setPatch(name: "Noise Sweep", path: "/Users/x/Patches/Noise Sweep.pch2")
        log.start()
        log.stop()
        let text = try String(contentsOf: file, encoding: .utf8)
        let header = text.split(separator: "\n").prefix(2).joined(separator: "\n")
        XCTAssertTrue(header.contains("Noise Sweep"), header)
        XCTAssertTrue(header.contains("/Users/x/Patches/Noise Sweep.pch2"), header)
    }

    /// Patch zmieniony w trakcie sesji też musi zostawić ślad — zawieszka bywa dopiero
    /// przy trzecim otwartym pliku.
    func testSwitchingDocumentWritesAnotherHeaderLine() throws {
        let log = USBLogFile(file: file)
        log.start()
        log.append("TX 0x03 …")
        log.setPatch(name: "Dark Forest", path: "/Users/x/Patches/Dark Forest.pch2")
        log.stop()
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("=== PATCH: Dark Forest — /Users/x/Patches/Dark Forest.pch2 ==="), text)
    }

    /// Testerzy wysyłają log obcym ludziom — ścieżka z katalogu domowego zdradzałaby nazwę
    /// użytkownika macOS. Skrót `~` wystarcza, żeby otworzyć ten sam plik ponownie.
    func testPathInTheHomeFolderHidesTheUserName() throws {
        let log = USBLogFile(file: file)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        log.setPatch(name: "Pad", path: home + "/Patches/Pad.pch2")
        log.start()
        log.stop()
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("=== PATCH: Pad — ~/Patches/Pad.pch2 ==="), text)
        XCTAssertFalse(text.contains(home + "/"), text)
    }

    /// Patch z urządzenia albo świeżo utworzony nie ma pliku — log ma to powiedzieć
    /// wprost, a nie zostawić puste miejsce po ścieżce.
    func testDocumentWithoutAFileSaysSoInsteadOfLeavingTheLineEmpty() throws {
        let log = USBLogFile(file: file)
        log.start()
        log.setPatch(name: "Nord G2", path: nil)
        log.stop()
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("PATCH: Nord G2 — no file on disk"), text)
    }

    /// Sedno zmiany z 2026-09-19: przełącznik włącza się PO awarii, więc plik musi zawierać
    /// także to, co poszło po kablu wcześniej — z oryginalnymi godzinami.
    func testTurningTheLogOnWritesWhatHappenedBeforeIt() throws {
        let log = USBLogFile(file: file)
        log.setPatch(name: "Dark Forest", path: "/Users/x/Dark Forest.pch2")
        log.append("TX 0x03 przed włączeniem")
        log.start()
        log.append("TX 0x03 po włączeniu")
        log.stop()
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("TX 0x03 przed włączeniem"), text)
        XCTAssertTrue(text.contains("TX 0x03 po włączeniu"), text)
        XCTAssertTrue(text.contains("lines from before the log was switched on"), text)
    }

    /// Pierścień ma stały rozmiar — długa sesja nie może rosnąć bez końca, a to, co zostaje,
    /// to zawsze OSTATNIE linie (awaria jest na końcu, nie na początku).
    func testRingKeepsTheNewestLinesAndDropsTheOldest() {
        let log = USBLogFile(file: file, capacity: 3)
        for index in 1 ... 5 { log.append("linia \(index)") }
        let lines = log.lines()
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("linia 3"), lines[0])
        XCTAssertTrue(lines[2].hasSuffix("linia 5"), lines[2])
    }

    /// Zgłoszenie 2026-09-23: po rozjeździe strumienia edytor nadawał jedną i tę samą skargę
    /// kilkadziesiąt razy na sekundę — 8644 z 13 709 linii. Pierścień zjadały powtórzenia,
    /// więc chwili PRZED awarią, po którą on w ogóle jest, już w nim nie było.
    func testRepeatedLineIsCountedInsteadOfFloodingTheRing() {
        let log = USBLogFile(file: file, capacity: 100)
        log.append("TX 0x03 start")
        for _ in 0 ..< 500 { log.append("! bad CRC in extended data (87B)") }
        log.append("RX 0x81 16B")
        let lines = log.lines()
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].hasSuffix("TX 0x03 start"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("! bad CRC in extended data (87B)"), lines[1])
        XCTAssertTrue(lines[2].hasSuffix("repeated 499 more times"), lines[2])
        XCTAssertTrue(lines[3].hasSuffix("RX 0x81 16B"), lines[3])
    }

    /// Seria, która trwa w chwili zbierania logu, nie może przepaść — licznik domyka się
    /// także przy odczycie, nie dopiero przy następnej innej linii.
    func testOngoingRepeatIsClosedWhenTheLogIsRead() {
        let log = USBLogFile(file: file, capacity: 100)
        for _ in 0 ..< 3 { log.append("! stream mismatch") }
        let lines = log.lines()
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasSuffix("repeated 2 more times"), lines[1])
    }

    /// Ponowna próba połączenia woła `start()` raz na dwie sekundy — plik ma to przeżyć.
    func testStartingTwiceDoesNotThrowAwayWhatIsAlreadyInTheFile() throws {
        let log = USBLogFile(file: file)
        log.start()
        log.append("TX 0x03 pierwsza")
        log.start()
        log.append("TX 0x03 druga")
        log.stop()
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("TX 0x03 pierwsza"), text)
        XCTAssertTrue(text.contains("TX 0x03 druga"), text)
    }
}
