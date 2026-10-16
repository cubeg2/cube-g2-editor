@testable import G2Core
import XCTest

/// Strumień wskaźników (0x3A) nie niesie żadnej adresacji — przypisanie wartości do
/// modułów wynika wyłącznie z zawartości slotu, więc każda zmiana tabeli typów albo
/// kolejności obszarów cicho przesuwa WSZYSTKIE wskaźniki. Te testy pilnują układu,
/// który 2026-09-04 dopasował się co do bajtu do pakietów z żywego Norda
/// → [[Docs/usb/notifications]].
final class G2VisualStreamTests: XCTestCase {
    /// Slot z pakietu zaobserwowanego na sprzęcie: obszar voice zajmuje 18 wpisów,
    /// potem lecą moduły fx. Buduje tylko tyle patcha, ile widzi strumień.
    private func patch(voice: [(id: Int, typeID: Int)], fx: [(id: Int, typeID: Int)]) -> G2Patch {
        var patch = G2Patch()
        patch.voiceModules = voice.map { G2Module(id: $0.id, typeID: $0.typeID, area: .voice) }
        patch.fxModules = fx.map { G2Module(id: $0.id, typeID: $0.typeID, area: .fx) }
        return patch
    }

    /// 4-In (typ 171) ma 4 wskaźniki, 2-Out (typ 4) dwa, Mix4-1C (typ 123) jeden.
    func testVisualCountMatchesMiniVUTable() {
        XCTAssertEqual(G2VisualStream.visualCount(typeID: 171), 4)
        XCTAssertEqual(G2VisualStream.visualCount(typeID: 4), 2)
        XCTAssertEqual(G2VisualStream.visualCount(typeID: 123), 1)
        // SeqCtr nie ma wskaźnika VU, ale jego GRUPA diod zajmuje wpis w tym samym strumieniu.
        XCTAssertEqual(G2VisualStream.visualCount(typeID: 154), 1)
        // Mix4-1A: g2fx przypisuje mu wskaźnik, panele oryginału nie. Trzymamy się paneli.
        XCTAssertEqual(G2VisualStream.visualCount(typeID: 193), 0)
        // Moduł bez wskaźnika i bez grupy nie zajmuje w strumieniu nic.
        XCTAssertEqual(G2VisualStream.visualCount(typeID: 96), 0)
    }

    /// Voice przed fx, w każdym obszarze rosnąco po numerze modułu — kolejność, którą
    /// urządzenie zakłada milcząco (`usbComms.c`: location 1→0, indeks 0→255).
    func testStreamOrderIsVoiceBeforeFxAscendingByModuleID() {
        let patch = patch(voice: [(9, 4), (2, 123)], fx: [(5, 4), (1, 123)])
        let order = G2VisualStream.modulesInStreamOrder(patch).map { "\($0.area)\($0.id)" }
        XCTAssertEqual(order, ["voice2", "voice9", "fx1", "fx5"])
    }

    /// Wartość VU to PIERWSZY bajt dwubajtowego wpisu, po bajcie numeru pierwszego
    /// wskaźnika; wpis grupy diod zajmuje tyle samo miejsca i niesie indeks świecącej diody.
    func testDecodesMetersAndLedGroupsInStreamOrder() {
        // voice: 2-Out (2 wskaźniki), SeqCtr (grupa diod), Mix4-1C (1 wskaźnik)
        // fx:    2-Out (2 wskaźniki)
        let patch = patch(voice: [(1, 4), (2, 154), (3, 123)], fx: [(1, 4)])
        let payload: [UInt8] = [
            0x00, // od którego wskaźnika zaczyna się ten komunikat
            0x0A, 0x00, // voice 1, kanał L
            0x14, 0x00, // voice 1, kanał R
            0x05, 0x00, // voice 2 — grupa diod: 16 bitów, tu krok 5
            0x1E, 0x00, // voice 3
            0x28, 0x00, // fx 1, kanał L
            0x32, 0x00, // fx 1, kanał R
        ]
        let readings = G2VisualStream.decodeVolumeData(payload, patch: patch)
        XCTAssertEqual(readings.meters.count, 3)
        XCTAssertEqual(readings.meters[0].area, .voice)
        XCTAssertEqual(readings.meters[0].moduleID, 1)
        XCTAssertEqual(readings.meters[0].values, [10, 20])
        XCTAssertEqual(readings.meters[1].moduleID, 3)
        XCTAssertEqual(readings.meters[1].values, [30])
        XCTAssertEqual(readings.meters[2].area, .fx)
        XCTAssertEqual(readings.meters[2].values, [40, 50])

        XCTAssertEqual(readings.ledGroups.count, 1)
        XCTAssertEqual(readings.ledGroups[0].area, .voice)
        XCTAssertEqual(readings.ledGroups[0].moduleID, 2)
        XCTAssertEqual(readings.ledGroups[0].value, 5)
    }

    /// Sekwencer, który stoi, nadaje wartość spoza zakresu grupy (na sprzęcie 16 i 255).
    /// Dekoder ma ją oddać bez zmian — „nic nie świeci" rozstrzyga dopiero rysowanie,
    /// bo żadna dioda nie ma takiego `CodeRef`.
    func testStoppedSequencerReportsValueOutsideTheGroup() {
        let patch = patch(voice: [(1, 154)], fx: [])
        let readings = G2VisualStream.decodeVolumeData([0x00, 0x10, 0x00], patch: patch)
        XCTAssertEqual(readings.ledGroups.map(\.value), [16])
    }

    /// Wartość grupy jest **16-bitowa** (`SetMultiLed(uchar, ushort)`), czytana
    /// little-endian jak w oryginale. Zmierzone: zatrzymany sekwencer nadaje `FF 0F`,
    /// czyli `0x0FFF` — na samym młodszym bajcie wyszłoby z tego mylące 255.
    func testGroupValueIsSixteenBitLittleEndian() {
        let patch = patch(voice: [(1, 154)], fx: [])
        let readings = G2VisualStream.decodeVolumeData([0x00, 0xFF, 0x0F], patch: patch)
        XCTAssertEqual(readings.ledGroups.map(\.value), [0x0FFF])
    }

    /// Jedna reguła (`CPanel::Blink`) obsługuje wszystkie grupy — tryb niesie sama wartość.
    func testGroupValueDecidesHowTheGroupLightsUp() {
        let seqCtr = G2VisualStream.groupLeds(typeID: 154)
        XCTAssertEqual(seqCtr.count, 17) // 16 kroków + „Park"

        // Zwykła wartość = indeks jednej diody, po `CodeRef`.
        XCTAssertEqual(G2VisualStream.litLeds(groupValue: 5, in: seqCtr).map(\.codeRef), [5])
        // 16 to „Park" — dioda zielona sekwencera, też należąca do grupy.
        XCTAssertEqual(G2VisualStream.litLeds(groupValue: 16, in: seqCtr).map(\.codeRef), [16])
        // Wartość spoza grupy nie zapala niczego.
        XCTAssertTrue(G2VisualStream.litLeds(groupValue: 255, in: seqCtr).isEmpty)
        // 0xFFF zapala całą grupę — tak nadaje sekwencer przy zatrzymanym zegarze.
        XCTAssertEqual(G2VisualStream.litLeds(groupValue: 0xFFF, in: seqCtr).count, 17)

        // Maska: bity 0x3000 włączają tryb bitowy dla grup mniejszych niż 12 diod
        // (licznik binarny, przetwornik A/D, miernik kompresora).
        let binCounter = G2VisualStream.groupLeds(typeID: 130)
        XCTAssertEqual(binCounter.count, 8)
        XCTAssertEqual(G2VisualStream.litLeds(groupValue: 0x3000 | 0b0000_0101, in: binCounter)
            .map(\.codeRef).sorted(), [0, 2])
        // Grupa z co najmniej dwunastoma diodami maski nie przyjmuje — oryginał ją pomija.
        XCTAssertTrue(G2VisualStream.litLeds(groupValue: 0x3000 | 0b0011, in: seqCtr).isEmpty)
    }

    /// Pierwszy bajt payloadu to numer pierwszego wskaźnika w komunikacie
    /// (`SetMultiLed(start + i, …)` w oryginale), więc komunikat może zaczynać się
    /// od dalszego modułu. Wpisy sprzed `start` nie mają w nim wartości.
    func testFirstByteIsTheIndexOfTheFirstEntry() {
        let patch = patch(voice: [(1, 4), (2, 123)], fx: [])
        // Zaczynamy od wskaźnika nr 2, czyli od modułu voice 2 (voice 1 zajmuje 0 i 1).
        let readings = G2VisualStream.decodeVolumeData([0x02, 0x2A, 0x00], patch: patch)
        XCTAssertEqual(readings.meters.map(\.moduleID), [2])
        XCTAssertEqual(readings.meters[0].values, [42])
    }

    /// Komunikat ma stałą długość niezależnie od patcha (na sprzęcie: 81 B = 40 wpisów),
    /// więc moduły powyżej pojemności nie są raportowane. Dekoder ma je pominąć,
    /// a nie czytać poza bufor.
    func testStopsAtPayloadCapacityInsteadOfReadingPastTheEnd() {
        let patch = patch(voice: [(1, 4), (2, 4)], fx: [(1, 4)])
        XCTAssertEqual(G2VisualStream.entryCount(of: patch), 6)
        // Payload mieści tylko 3 wpisy z 6 potrzebnych.
        let payload: [UInt8] = [0x00, 0x07, 0x00, 0x08, 0x00, 0x09, 0x00]
        XCTAssertEqual(G2VisualStream.entryCapacity(payloadLength: payload.count), 3)
        let readings = G2VisualStream.decodeVolumeData(payload, patch: patch)
        // voice 1 dostaje oba kanały; voice 2 już się nie mieści w całości, więc wypada.
        XCTAssertEqual(readings.meters.map(\.moduleID), [1])
        XCTAssertEqual(readings.meters[0].values, [7, 8])
    }

    /// Poziomem jest młodszy PÓŁBAJT wartości (Peak Meter (Draw): `value & 0xf`),
    /// a nie cała wartość. Bez maski `Mix4-1C` nadający 41–43 stał na maksimum.
    func testSegmentLevelIsTheLowNibbleOfTheStreamValue() {
        XCTAssertEqual(G2VisualStream.segmentLevel(forValue: 0, segments: 15), 0)
        XCTAssertEqual(G2VisualStream.segmentLevel(forValue: 9, segments: 15), 9)
        XCTAssertEqual(G2VisualStream.segmentLevel(forValue: 15, segments: 15), 15)
        XCTAssertEqual(G2VisualStream.segmentLevel(forValue: 255, segments: 15), 15)
        XCTAssertEqual(G2VisualStream.segmentLevel(forValue: -1, segments: 15), 0)
    }

    /// Znaczniki podnoszą słupek do progu, zamiast zapalać konkretne kreski: `0x30` do 11
    /// (dwie górne żółte oryginału), `0x40` do 12 (czerwień). Przepisane wprost zrobiłyby
    /// na 15-kreskowym słupku dziurę — patrz `segmentLevel`.
    func testFlagsRaiseTheBarToAThresholdInsteadOfLightingSingleSegments() {
        // Zmierzone na sprzęcie na Mix4-1C: 41, 42, 43 = poziom 9, 10, 11 ze znacznikiem 0x20.
        // Dla wszystkich trzech oryginał pokazuje pełne cztery żółte — u nas tak samo.
        XCTAssertEqual(G2VisualStream.segmentLevel(forValue: 41, segments: 15), 11)
        XCTAssertEqual(G2VisualStream.segmentLevel(forValue: 42, segments: 15), 11)
        XCTAssertEqual(G2VisualStream.segmentLevel(forValue: 43, segments: 15), 11)
        // Przester zapala czerwień, choćby poziom był zerowy.
        XCTAssertEqual(G2VisualStream.segmentLevel(forValue: 0x40, segments: 15), 12)
        // Znacznik nie ŚCIĄGA słupka w dół — poziom wyższy od progu zostaje.
        XCTAssertEqual(G2VisualStream.segmentLevel(forValue: 0x2F, segments: 15), 15)
        XCTAssertEqual(G2VisualStream.segmentLevel(forValue: 0x4E, segments: 15), 14)
        // Bez znaczników nic się nie zmienia.
        XCTAssertEqual(G2VisualStream.segmentLevel(forValue: 0x09, segments: 15), 9)
    }

    /// Słupek w oknie patcha ma 12 diod jak Peak Meter (7 + 4 + czerwona). Przester
    /// (znacznik `0x40`) i każdy poziom od 12 wzwyż zapalają go do samej góry.
    func testTwelveLedMeterReachesTheTopOnOverload() {
        XCTAssertEqual(G2VisualStream.segmentLevel(forValue: 0x40, segments: 12), 12)
        XCTAssertEqual(G2VisualStream.segmentLevel(forValue: 0x43, segments: 12), 12)
        XCTAssertEqual(G2VisualStream.segmentLevel(forValue: 12, segments: 12), 12)
        XCTAssertEqual(G2VisualStream.segmentLevel(forValue: 15, segments: 12), 12)
        XCTAssertEqual(G2VisualStream.segmentLevel(forValue: 11, segments: 12), 11)
        XCTAssertEqual(G2VisualStream.segmentLevel(forValue: 0x29, segments: 12), 11)
    }

    // MARK: - Pojedyncze diody (0x39)

    /// Moduł z grupą oddaje do niej WSZYSTKIE swoje diody i nie wnosi nic do strumienia
    /// `0x39` — potwierdzone pomiarem: patch z 8 sekwencerami i 9 LFO miał w `0x39`
    /// dokładnie dziewięć żywych wpisów.
    func testModuleWithAGroupContributesNothingToTheSingleLedStream() {
        XCTAssertEqual(G2VisualStream.groupLeds(typeID: 154).count, 17) // SeqCtr: 16 kroków + Park
        XCTAssertTrue(G2VisualStream.singleLeds(typeID: 154).isEmpty)
        XCTAssertEqual(G2VisualStream.groupLeds(typeID: 21).count, 8) // Mux1-8
        XCTAssertTrue(G2VisualStream.singleLeds(typeID: 21).isEmpty)
        // Obwiednia nie ma grupy — jej jedyna dioda jest pojedyncza.
        XCTAssertTrue(G2VisualStream.groupLeds(typeID: 20).isEmpty) // EnvADSR
        XCTAssertEqual(G2VisualStream.singleLeds(typeID: 20).count, 1)
    }

    /// `0x39`: bajt numeru pierwszej diody, potem **2 bity na diodę, cztery w bajcie,
    /// od najmłodszych bitów** (`InterruptHandleBlinkData` gałąź `'9'`, g2fx `readLedData`).
    func testDecodesTwoBitsPerLedFromLeastSignificantBits() {
        // Trzy obwiednie w voice (po jednej diodzie) i jedna w fx.
        let patch = patch(voice: [(1, 20), (2, 20), (3, 20)], fx: [(1, 20)])
        // 0b11_00_10_01 → dioda 0 = 1, dioda 1 = 2, dioda 2 = 0, dioda 3 = 3
        let readings = G2VisualStream.decodeLedData([0x00, 0b1100_1001], patch: patch)
        XCTAssertEqual(readings.map(\.value), [1, 2, 0, 3])
        XCTAssertEqual(readings.map(\.isLit), [true, true, false, true])
        XCTAssertEqual(readings.map(\.moduleID), [1, 2, 3, 1])
        XCTAssertEqual(readings.map(\.area), [.voice, .voice, .voice, .fx])
    }

    /// Sekwencer stojący przed obwiednią NIE zajmuje miejsca w strumieniu `0x39` —
    /// pierwszy wpis należy do obwiedni. Do 2026-09-06 dokładaliśmy tu diodę „Park"
    /// sekwencera i przez to przesuwaliśmy wszystkie diody za nim.
    func testSequencerTakesNoSlotInTheSingleLedStream() {
        let patch = patch(voice: [(1, 154), (2, 20)], fx: [])
        let readings = G2VisualStream.decodeLedData([0x00, 0b0000_0010], patch: patch)
        XCTAssertEqual(readings.map(\.moduleID), [2])
        XCTAssertEqual(readings.map(\.codeRef), [0])
        XCTAssertEqual(readings.map(\.value), [2])
    }

    /// Powiadomienie o ruchu gałki NA URZĄDZENIU ma ten sam układ pięciu bajtów co
    /// komenda wychodząca — dekoder jest lustrem `setParameterPayload`.
    func testParamChangeNotificationMirrorsOutgoingCommand() {
        let outgoing = G2UsbProtocol.setParameterPayload(
            slot: 1, version: 0, area: .voice, moduleID: 12, paramIndex: 3, value: 101, variation: 2
        )
        let decoded = G2UsbProtocol.decodeParamChange(Array(outgoing.dropFirst(4)))
        XCTAssertEqual(decoded?.location, 1)
        XCTAssertEqual(decoded?.moduleID, 12)
        XCTAssertEqual(decoded?.paramIndex, 3)
        XCTAssertEqual(decoded?.value, 101)
        XCTAssertEqual(decoded?.variation, 2)
    }

    /// Obszar USTAWIEŃ patcha (2) też przychodzi tą samą podkomendą — dekoder ma go oddać
    /// jako 2, a nie sprowadzić do fx. Tędy idą gałki i źródła morfów (moduł 1).
    func testParamChangeKeepsTheSettingsLocation() {
        let outgoing = G2UsbProtocol.setParameterPayload(
            slot: 0, version: 0, location: 2, moduleID: 1, paramIndex: 3, value: 64, variation: 1
        )
        let decoded = G2UsbProtocol.decodeParamChange(Array(outgoing.dropFirst(4)))
        XCTAssertEqual(decoded?.location, G2UsbProtocol.settingsLocation)
        XCTAssertEqual(decoded?.moduleID, 1)
        XCTAssertEqual(decoded?.paramIndex, 3)
        XCTAssertEqual(decoded?.value, 64)
    }
}
