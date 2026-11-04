@testable import G2Core
import XCTest

/// Przydział głosów na procesory — liczby ułożone tak, żeby wynik dało się policzyć na kartce.
/// Jeden DSP mieści 1371 cykli i 128 jednostek strony zerowej.
final class DSPVoiceAllocationTests: XCTestCase {
    private func load(_ area: PatchArea, red: Int = 0, zeroPage: Int = 0) -> G2PatchLoad {
        G2PatchLoad(area: area, cyclesRed: red, cyclesBlue: 0, zeroPageMemory: zeroPage,
                    xMemory: 0, yMemory: 0, programMemory: 0, ram: 0, qMemory: 0, rMemory: 0)
    }

    private func request(_ voices: Int, voiceRed: Int, fxRed: Int = 0) -> DSPVoiceAllocation.Request {
        .init(voices: voices, voice: load(.voice, red: voiceRed), fx: load(.fx, red: fxRed))
    }

    func testLightPerformanceGetsEveryVoice() {
        let requests = [request(8, voiceRed: 100, fxRed: 200), request(1, voiceRed: 300),
                        request(4, voiceRed: 150), request(1, voiceRed: 50)]
        let result = DSPVoiceAllocation(requests: requests, dspCount: 4)
        XCTAssertEqual(result.voices, [8, 1, 4, 1])
        XCTAssertEqual(result.dsps.flatMap { $0 }.count, 8 + 1 + 4 + 1 + 4)
    }

    /// Głos zjada ponad połowę procesora, więc na każdym mieści się jeden.
    func testVoicesAreCutToWhatTheProcessorsHold() {
        let requests = [request(6, voiceRed: 700)]
        XCTAssertEqual(DSPVoiceAllocation(requests: requests, dspCount: 4).voices, [4])
        XCTAssertEqual(DSPVoiceAllocation(requests: requests, dspCount: 8).voices, [6])
    }

    /// Nord zabiera głosy temu, kto ma ich najwięcej: 6 + 4 przy miejscu na 8 daje 4 + 4.
    func testTheSlotWithMostVoicesLosesFirst() {
        let requests = [request(6, voiceRed: 500), request(4, voiceRed: 500)]
        XCTAssertEqual(DSPVoiceAllocation(requests: requests, dspCount: 4).voices, [4, 4])
    }

    /// Kopia, która sama nie mieści się w jednym procesorze, nie gra wcale.
    func testAreaLargerThanOneProcessorIsSilent() {
        let result = DSPVoiceAllocation(requests: [request(6, voiceRed: 1400), request(2, voiceRed: 100)],
                                        dspCount: 8)
        XCTAssertEqual(result.requested, [6, 2])
        XCTAssertEqual(result.voices, [0, 2])
        XCTAssertFalse(result.dsps.flatMap { $0 }.contains { $0.slot == 0 })
    }

    func testSlotThatIsNotPlayingTakesNothing() {
        let result = DSPVoiceAllocation(requests: [request(0, voiceRed: 100, fxRed: 100)], dspCount: 4)
        XCTAssertEqual(result.voices, [0])
        XCTAssertTrue(result.dsps.allSatisfy(\.isEmpty))
    }

    /// Wspólną pulę strony zerowej płaci tylko pierwszy głos na procesorze: 40 + 8 × 10 = 120,
    /// czyli dziewięć głosów na DSP, 27 na trzech.
    func testSharedZeroPageIsPaidOncePerProcessor() {
        let voice = DSPVoiceAllocation.Request(voices: 32, voice: load(.voice, red: 10, zeroPage: 40),
                                               fx: load(.fx), voiceSharedZeroPage: 30)
        let result = DSPVoiceAllocation(requests: [voice], dspCount: 3)
        XCTAssertEqual(result.voices, [27])
        XCTAssertEqual(result.dsps.map { $0.filter { $0.area == .voice }.count }, [9, 9, 9])
        XCTAssertEqual(result.loads[0].memory, 120.0 / 128 * 100, accuracy: 0.01)
    }
}

/// Prawdziwe performance'y z wynikiem emulatora firmware'u 1.62 (`+0x202` po `--loadperf`,
/// 2026-10-30). Pliki leżą w prywatnym repo referencyjnym — bez niego test się pomija.
final class DSPVoiceAllocationFirmwareTests: XCTestCase {
    private func voices(_ file: String, dspCount: Int) throws -> [Int] {
        let path = NSHomeDirectory() + "/Developer/G2-reference/Ptches pch2 i prf2/" + file
        guard let data = FileManager.default.contents(atPath: path) else { throw XCTSkip("brak \(file)") }
        let parsed = try PatchParser.parseFile(data: data)
        let enabled = parsed.performance?.slots.map(\.enabled) ?? []
        let requests = parsed.patches.enumerated().map { slot, patch in
            DSPVoiceAllocation.Request(patch: patch, playing: slot < enabled.count && enabled[slot])
        }
        return DSPVoiceAllocation(requests: requests, dspCount: dspCount).voices
    }

    /// Bez karty slot A traci trzy z dziewięciu głosów, a slot D milczy.
    func testRadiolarianMatchesTheFirmware() throws {
        XCTAssertEqual(try voices("NORD Wybrane/Ambient/Radiolarian.prf2", dspCount: 4), [6, 1, 1, 0])
        XCTAssertEqual(try voices("NORD Wybrane/Ambient/Radiolarian.prf2", dspCount: 8), [9, 1, 1, 1])
    }

    func testWavetablePadMatchesTheFirmware() throws {
        XCTAssertEqual(try voices("NORDD G2 - OK/Synth/WTabXShapeSyn_TK.prf2", dspCount: 4), [3, 0, 0, 0])
        XCTAssertEqual(try voices("NORDD G2 - OK/Synth/WTabXShapeSyn_TK.prf2", dspCount: 8), [7, 0, 0, 0])
    }

    func testFactoryPerformanceMatchesTheFirmware() throws {
        XCTAssertEqual(try voices("NORDD G2 - OK/Performances/04-013-001.prf2", dspCount: 4), [1, 1, 0, 0])
        XCTAssertEqual(try voices("NORDD G2 - OK/Performances/05-004-001.prf2", dspCount: 4), [1, 1, 0, 1])
    }
}
