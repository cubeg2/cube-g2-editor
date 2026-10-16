// TransportTests.swift
// Szew transportowy: kto przenosi bajty do urządzenia (`G2Transport`).
//
// Testy bez sprzętu i bez emulatora — sprawdzają reguły, które dają się sprawdzić
// w pamięci. Rozmowa edytora z żywym emulatorem jest osobną, ręczną procedurą
// (`G2_FORCE_EMULATOR=1 swift run USBProbe`) → [[Docs/usb/emulator]].

import CLibUsb
@testable import G2Core
import XCTest

final class TransportTests: XCTestCase {
    /// Domyślna ścieżka gniazda musi być ta sama po obu stronach, inaczej edytor
    /// szuka emulatora tam, gdzie go nie ma. Zmienna środowiskowa ma pierwszeństwo —
    /// tym samym przełącznikiem posługuje się `G2Emulator --socket`.
    func testSocketPathFollowsTheEnvironmentOverride() {
        let previous = ProcessInfo.processInfo.environment["G2_EMULATOR_SOCKET"]
        defer {
            if let previous {
                setenv("G2_EMULATOR_SOCKET", previous, 1)
            } else {
                unsetenv("G2_EMULATOR_SOCKET")
            }
        }
        setenv("G2_EMULATOR_SOCKET", "/tmp/g2-test.sock", 1)
        XCTAssertEqual(EmulatorTransport.socketPath, "/tmp/g2-test.sock")

        unsetenv("G2_EMULATOR_SOCKET")
        XCTAssertTrue(EmulatorTransport.socketPath.hasSuffix("G2Editor/emulator.sock"),
                      "bez zmiennej środowiskowej obie strony umawiają się na Application Support")
    }

    /// Brak gniazda to „nie ma urządzenia", a nie błąd transferu — na tym rozróżnieniu
    /// stoi cała reguła awaryjnego przejścia na emulator w `openDevice`.
    func testMissingSocketReportsDeviceNotFound() {
        setenv("G2_EMULATOR_SOCKET", "/tmp/g2-nie-ma-takiego-gniazda-\(UUID().uuidString).sock", 1)
        defer { unsetenv("G2_EMULATOR_SOCKET") }

        XCTAssertThrowsError(try EmulatorTransport().open()) { error in
            guard case G2UsbError.deviceNotFound = error else {
                return XCTFail("oczekiwano deviceNotFound, dostałem \(error)")
            }
        }
    }

    /// Odczyt bez otwartego połączenia nie może wyglądać jak cisza urządzenia —
    /// `bulkRead` odróżnia te dwa przypadki po kodzie libusb i tylko przy `NO_DEVICE`
    /// zrywa sesję.
    func testTransportWithoutConnectionReportsNoDevice() {
        var buffer = [UInt8](repeating: 0, count: 16)
        let transport = EmulatorTransport()
        XCTAssertEqual(transport.read(&buffer, endpoint: 0x81, timeout: 10).code,
                       LIBUSB_ERROR_NO_DEVICE.rawValue)

        var frame: [UInt8] = [0x00, 0x05, 0x80]
        XCTAssertEqual(transport.write(&frame, endpoint: 0x03, timeout: 10).code,
                       LIBUSB_ERROR_NO_DEVICE.rawValue)
    }

    /// Emulator nie ma zatrzaskujących się endpointów, więc `clearHalt` musi zwracać
    /// sukces — inaczej `bulkRead` logowałby przy nim błąd bez powodu.
    func testEmulatorHasNothingToUnclog() {
        XCTAssertEqual(EmulatorTransport().clearHalt(endpoint: 0x81), 0)
    }
}
