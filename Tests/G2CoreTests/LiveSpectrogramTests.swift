@testable import G2EditorCore
import XCTest

/// Podsłuch dźwięku emulatora i zamiana ramek na kolumnę spektrogramu.
///
/// Plik podsłuchu buduje tu test, więc emulator do niczego nie jest potrzebny — a
/// dzięki temu sprawdzamy to, co najłatwiej zepsuć po cichu: układ nagłówka uzgodniony
/// z `firmware/work/g2live.cpp` i to, że dźwięk ląduje w spektrogramie na właściwej
/// wysokości.
@MainActor
final class LiveSpectrogramTests: XCTestCase {
    private static let frames = 1 << 16
    private static let rate = 96000.0

    /// Plik dokładnie taki, jaki pisze emulator: nagłówek 64 bajty (wersja 2), potem
    /// pierścień ramek stereo int16.
    private func writeTap(hz: Double, amplitude: Float, filled: Int,
                          silentFrames: UInt64 = 0, backlog: UInt32 = 0) throws -> URL
    {
        var data = Data()
        for value in [UInt32(0x3247_5441), UInt32(2), UInt32(Self.rate), UInt32(Self.frames)] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        withUnsafeBytes(of: UInt64(filled).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: silentFrames.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(0).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: backlog.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: backlog.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: [UInt8](repeating: 0, count: 16))
        for frame in 0 ..< Self.frames {
            let phase = 2 * Double.pi * hz * Double(frame) / Self.rate
            let sample = Int16(amplitude * Float(sin(phase)) * 32767)
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tap-\(UUID().uuidString).bin")
        try data.write(to: url)
        return url
    }

    func testTapReadsTheNewestFramesAtTheirOriginalLevel() throws {
        let url = try writeTap(hz: 1000, amplitude: 0.5, filled: Self.frames)
        defer { try? FileManager.default.removeItem(at: url) }
        let tap = try XCTUnwrap(LiveAudioTap(url: url))
        XCTAssertTrue(tap.isPlaying)
        XCTAssertEqual(tap.sampleRate, Self.rate)

        let samples = try XCTUnwrap(tap.latest(frames: 4096))
        XCTAssertEqual(samples.count, 4096)
        // Sinus o szczycie 0,5 ma wartość skuteczną 0,354.
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        XCTAssertEqual(Double(rms), 0.354, accuracy: 0.02)
    }

    /// Wykres X-Y dostaje kanały osobno, w tej samej skali co widmo.
    func testTapReadsLeftAndRightSeparately() throws {
        let url = try writeTap(hz: 1000, amplitude: 0.5, filled: Self.frames)
        defer { try? FileManager.default.removeItem(at: url) }
        let tap = try XCTUnwrap(LiveAudioTap(url: url))
        let stereo = try XCTUnwrap(tap.latestStereo(frames: 3200))
        XCTAssertEqual(stereo.left.count, 3200)
        XCTAssertEqual(stereo.left, stereo.right, "the test tap writes the same sample to both channels")
        XCTAssertEqual(Double(stereo.left.map(abs).max() ?? 0), 0.5, accuracy: 0.01)
        XCTAssertNil(tap.latestStereo(frames: Self.frames * 2))
    }

    /// Miernik korelacji X-Y: te same kanały = +1, odwrócony = −1, niezależne ≈ 0, cisza = brak.
    func testStereoCorrelation() {
        let sine = (0 ..< 3200).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        let cosine = (0 ..< 3200).map { Float(cos(Double($0) * 0.05)) * 0.5 }
        XCTAssertEqual(LiveStereoScope.correlation(left: sine, right: sine) ?? 0, 1, accuracy: 1e-6)
        XCTAssertEqual(LiveStereoScope.correlation(left: sine, right: sine.map { -$0 }) ?? 0, -1, accuracy: 1e-6)
        XCTAssertEqual(LiveStereoScope.correlation(left: sine, right: cosine) ?? 1, 0, accuracy: 0.02)
        XCTAssertNil(LiveStereoScope.correlation(left: sine, right: [Float](repeating: 0, count: 3200)))
    }

    /// Miernik poziomu: szczyt 0,5 = −6 dB, cisza = dół skali.
    func testStereoPeakDecibels() {
        XCTAssertEqual(LiveStereoScope.peakDecibels([0.1, -0.5, 0.2]), -6.02, accuracy: 0.01)
        XCTAssertEqual(LiveStereoScope.peakDecibels([0, 0]), LiveStereoScope.meterFloorDB)
        XCTAssertEqual(LiveStereoScope.peakDecibels([1e-6]), LiveStereoScope.meterFloorDB)
    }

    /// Bez magicznej liczby plik jest dla nas niewidoczny — tak emulator mówi
    /// „już nie gram", zamiast zostawiać nam stary dźwięk na ekranie.
    func testTapWithoutTheMagicNumberDoesNotOpen() throws {
        let url = try writeTap(hz: 1000, amplitude: 0.5, filled: Self.frames)
        defer { try? FileManager.default.removeItem(at: url) }
        var data = try Data(contentsOf: url)
        data.replaceSubrange(0 ..< 4, with: [0, 0, 0, 0])
        try data.write(to: url)
        let tap = try XCTUnwrap(LiveAudioTap(url: url))
        XCTAssertFalse(tap.isPlaying)
        XCTAssertNil(tap.latest(frames: 4096))
    }

    /// 1 kHz ma wyjść w tym punkcie osi poziomej, w którym stoi 1 kHz na skali
    /// logarytmicznej analizy (20 Hz – 20 kHz), i ma być najjaśniejszy w plasterku.
    func testSlicePutsAToneAtItsOwnPlaceOnTheAxis() throws {
        let url = try writeTap(hz: 1000, amplitude: 0.5, filled: Self.frames)
        defer { try? FileManager.default.removeItem(at: url) }
        let tap = try XCTUnwrap(LiveAudioTap(url: url))
        let samples = try XCTUnwrap(tap.latest(frames: 4096))

        let slice = LiveSpectrogram.shared.slice(from: samples, rate: Self.rate)
        XCTAssertEqual(slice.count, LiveSpectrogram.bins)
        let brightest = try XCTUnwrap(slice.indices.max(by: { slice[$0] < slice[$1] }))
        let position = log(1000.0 / LiveSpectrogram.bottomHz)
            / log(LiveSpectrogram.topHz / LiveSpectrogram.bottomHz)
        let expected = Int(position * Double(LiveSpectrogram.bins - 1))
        XCTAssertEqual(brightest, expected, accuracy: 1)
        XCTAssertGreaterThan(slice[brightest], 180, "ton 0,5 skali ma świecić")

        // Ten sam punkt w decybelach: sinus o szczycie 0,5 to −6 dBFS, a odczyt daje
        // −6,9. Brakujący decybel to zafalowanie okna Hanna: 1 kHz wypada dokładnie
        // MIĘDZY prążkami (1000 / 23,4 = 42,7), a wtedy strata sięga 1,42 dB. To
        // własność FFT, nie usterka — stąd zapas 1,5 dB.
        let decibels = LiveSpectrogram.decibels(slice)
        XCTAssertEqual(decibels[brightest], -6, accuracy: 1.5)
    }

    /// Liczniki stanowiska: ramki ciszy i zaległość. Bez nich trzeszczenie jest
    /// niewidoczne, bo w samym dźwięku po naszej stronie pierścienia go nie ma.
    /// Oba liczą RAMKI — 4800 ramek przy 96 kHz to 50 ms, i tak trzeba je czytać.
    func testTapReportsSilentFramesAndBacklog() throws {
        let url = try writeTap(hz: 1000, amplitude: 0.5, filled: Self.frames,
                               silentFrames: 7, backlog: 4800)
        defer { try? FileManager.default.removeItem(at: url) }
        let tap = try XCTUnwrap(LiveAudioTap(url: url))
        XCTAssertEqual(tap.health.silentFrames, 7)
        XCTAssertEqual(tap.health.skippedFrames, 0)
        // 4800 ramek przy 96 kHz to 50 ms zaległości.
        XCTAssertEqual(tap.health.backlogFrames, 4800)
        XCTAssertEqual(tap.health.backlogMaxFrames, 4800)
        // Dźwięk musi się dalej czytać poprawnie — pierścień zaczyna się za nagłówkiem.
        let samples = try XCTUnwrap(tap.latest(frames: 4096))
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        XCTAssertEqual(Double(rms), 0.354, accuracy: 0.02)
    }

    /// Nagłówek starszej wersji (24 bajty) miał pierścień w innym miejscu — czytanie go
    /// dałoby szum zamiast dźwięku, więc taki plik ma się NIE otworzyć.
    func testOlderTapVersionIsRefused() throws {
        let url = try writeTap(hz: 1000, amplitude: 0.5, filled: Self.frames)
        defer { try? FileManager.default.removeItem(at: url) }
        var data = try Data(contentsOf: url)
        withUnsafeBytes(of: UInt32(1).littleEndian) { data.replaceSubrange(4 ..< 8, with: $0) }
        try data.write(to: url)
        XCTAssertNil(LiveAudioTap(url: url))
    }

    /// Cisza ma być czarna — inaczej tło kanwy świeciłoby zawsze.
    func testSilenceIsBlack() {
        let slice = LiveSpectrogram.shared.slice(from: [Float](repeating: 0, count: 4096),
                                                 rate: Self.rate)
        XCTAssertEqual(slice.max(), 0)
    }
}
