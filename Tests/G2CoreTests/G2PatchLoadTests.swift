@testable import G2Core
import XCTest

/// Obciążenie DSP (`0x72`) i dwie komendy, które przy nim stoją.
///
/// Bajty w testach są ZMIERZONE na żywym G2 (firmware 1.62, 2026-09-07, `USBProbe --dsp`),
/// a oczekiwane procenty policzone z getterów Patch Load w oryginalnym edytorze Clavii. Dzięki
/// temu zmiana dekodera musi się wytłumaczyć i przed urządzeniem, i przed oryginałem.
final class G2PatchLoadTests: XCTestCase {
    /// Slot z patchem „Drama (SC)": 31 modułów w voice, 5 w fx.
    private let voicePayload: [UInt8] = [
        0x01, 0x02, 0x39, 0x05, 0x5D, 0x2F, 0x00, 0x00, 0x04, 0x27, 0x01, 0x27, 0x04, 0x19,
        0x01, 0x02, 0x00, 0x64, 0x06, 0x5D, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
    ]
    private let fxPayload: [UInt8] = [
        0x00, 0x04, 0x0A, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x52, 0x00, 0x19, 0x02, 0x3B,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xBB, 0x8B, 0x00, 0x0A,
    ]

    // MARK: - Układ pól

    /// Pozycje pól są z Patch Load (ReadStream): rekord to `SModuleResourceSpec`,
    /// a trzy pamięci DSP są SUMĄ dwóch pól każda.
    func testDecodesVoiceRecordFromRealG2() {
        let load = G2UsbProtocol.decodePatchLoad(voicePayload)[0]
        XCTAssertEqual(load.area, .voice)
        XCTAssertEqual(load.cyclesRed, 313)
        XCTAssertEqual(load.cyclesBlue, 733)
        XCTAssertEqual(load.zeroPageMemory, 47)
        XCTAssertEqual(load.xMemory, 551 + 130)
        XCTAssertEqual(load.yMemory, 167 + 100)
        XCTAssertEqual(load.programMemory, 537 + 861)
        XCTAssertEqual(load.ram, 0)
        XCTAssertEqual(load.qMemory, 0)
        XCTAssertEqual(load.rMemory, 16)
    }

    /// Qmem czytane jest pełnymi bajtami (Bit Stream (GetUWord)), nie przez maskę
    /// siódmego bitu — tu widać to na `0xBB`, `0x8B`. Drugim takim polem jest ZPmem,
    /// co pokazał dopiero pomiar patcha pod korek (niżej).
    func testDecodesFxRecordAndReadsQmemAsFullBytes() {
        let load = G2UsbProtocol.decodePatchLoad(fxPayload)[0]
        XCTAssertEqual(load.area, .fx)
        XCTAssertEqual(load.cyclesRed, 522)
        XCTAssertEqual(load.cyclesBlue, 0)
        XCTAssertEqual(load.zeroPageMemory, 7)
        XCTAssertEqual(load.xMemory, 82)
        XCTAssertEqual(load.yMemory, 25)
        XCTAssertEqual(load.programMemory, 315)
        XCTAssertEqual(load.qMemory, 113_547)
        XCTAssertEqual(load.rMemory, 10)
    }

    func testShortPayloadYieldsNothingRatherThanGarbage() {
        XCTAssertTrue(G2UsbProtocol.decodePatchLoad([1, 2, 3]).isEmpty)
    }

    /// Jedna ramka MOŻE nieść oba obszary, rozdzielone powtórzonym bajtem podkomendy.
    /// ⚠️ Na naszym G2 ta forma się nie pojawiła — test pilnuje tylko, że jej nie zgubimy.
    func testDecodesBothAreasFromOneFrame() {
        let readings = G2UsbProtocol.decodePatchLoad(voicePayload + [0x72] + fxPayload)
        XCTAssertEqual(readings.map(\.area), [.voice, .fx])
        XCTAssertEqual(readings[0].cyclesRed, 313)
        XCTAssertEqual(readings[1].cyclesRed, 522)
    }

    // MARK: - Procenty (wzory Clavii, nie BVerhue)

    /// `GetCycles` = `(red + blue/4) * 100 / 1371`. BVerhue dzielił „blue" przez 5000
    /// zamiast przez 5484 i na tym patchu mówił 37,5% zamiast 36,2%.
    func testCyclesPercentFollowsClaviaNotBVerhue() {
        let voice = G2UsbProtocol.decodePatchLoad(voicePayload)[0]
        XCTAssertEqual(voice.cyclesPercent, 36.19, accuracy: 0.01)

        let bverhue = 100.0 * 313.0 / 1372.0 + 100.0 * 733.0 / 5000.0
        XCTAssertEqual(bverhue, 37.47, accuracy: 0.01)
        XCTAssertNotEqual(voice.cyclesPercent, bverhue, accuracy: 0.5)

        // Przy zerowym zegarze „blue" oba wzory się schodzą — dlatego fx niczego nie ujawnia.
        let fx = G2UsbProtocol.decodePatchLoad(fxPayload)[0]
        XCTAssertEqual(fx.cyclesPercent, 38.07, accuracy: 0.01)
    }

    /// „Pamięć" to zasób najbliższy swojego limitu — maksimum z siedmiu, nie ich suma
    /// (`FindCriticalResourceType`). Moc DSP do tego maksimum nie wchodzi.
    func testMemoryPercentTakesTheCriticalResource() {
        // voice: wygrywa pamięć strony zerowej, 47/128.
        let voice = G2UsbProtocol.decodePatchLoad(voicePayload)[0]
        XCTAssertEqual(voice.memoryPercent, 36.72, accuracy: 0.01)
        // fx: wygrywa Qmem, 113 547/260 096 — czyli bufor delaya/reverbu.
        let fx = G2UsbProtocol.decodePatchLoad(fxPayload)[0]
        XCTAssertEqual(fx.memoryPercent, 43.66, accuracy: 0.01)
    }

    /// Pamięci, których BVerhue nie liczył wcale — dopóki ich nie było, patch mógł
    /// pokazywać komfortowy zapas, mając Pmem pod korkiem.
    func testProgramMemoryCanWinTheMaximum() {
        var body = [UInt8](repeating: 0, count: 27)
        body[11] = 0x32 // Pmem, pierwsza połowa: 50 * 128 = 6400 > limit 6498 × 0,98
        let load = G2UsbProtocol.decodePatchLoad([1] + body)[0]
        XCTAssertEqual(load.programMemory, 6400)
        XCTAssertEqual(load.memoryPercent, 98.49, accuracy: 0.01)
    }

    /// Pusty slot na żywym G2 odpowiada 27 zerami — przepowiednia z roadmapy
    /// („pusty patch = 0%") sprawdzona na sprzęcie 2026-09-07.
    func testEmptySlotOnRealG2ReadsAsZeroPercent() {
        let load = G2UsbProtocol.decodePatchLoad([1] + [UInt8](repeating: 0, count: 27))[0]
        XCTAssertEqual(load.cyclesPercent, 0, accuracy: 0.0001)
        XCTAssertEqual(load.memoryPercent, 0, accuracy: 0.0001)
    }

    // MARK: - Punkt kalibracyjny: patch pod korek

    /// `wtabxshapesyn_tk.prf2` przy 6 głosach, slot A — zmierzone 2026-09-08. To jedyny
    /// odczyt, przy którym znamy prawidłową odpowiedź NIEZALEŻNIE od naszych wzorów:
    /// G2 nie przyjmie już nic więcej, więc musi wyjść ~100%. Drugim takim punktem jest
    /// pusty slot (0%). Dwa znane punkty ustawiają całą skalę.
    private let ceilingVoice: [UInt8] = [
        0x01, 0x08, 0x56, 0x08, 0x11, 0x7E, 0x00, 0x00, 0x01, 0x04, 0x02, 0x2F, 0x07, 0x50,
        0x01, 0x45, 0x01, 0x1C, 0x09, 0x25, 0x00, 0x00, 0x00, 0x00, 0xBC, 0x9D, 0x00, 0x53,
    ]
    private let ceilingFx: [UInt8] = [
        0x00, 0x08, 0x78, 0x06, 0x75, 0x80, 0x00, 0x00, 0x01, 0x1F, 0x0A, 0x0D, 0x08, 0x2A,
        0x01, 0x2E, 0x05, 0x54, 0x06, 0x65, 0x00, 0x00, 0x00, 0x01, 0x77, 0x16, 0x01, 0x01,
    ]

    /// Dzielnik mocy 1371 trafiony co do ułamka cyklu: obszar zgłosił 1110 + 1041 × 0,25
    /// = **1370,25**, czyli trzy czwarte cyklu pod limitem. Gdyby dzielnik był choćby
    /// o kilka procent inny, patch, którego G2 nie chce już rozbudować, nie wypadłby tu.
    func testCyclesDivisorLandsOnTheCeilingWithinOneCycle() {
        let voice = G2UsbProtocol.decodePatchLoad(ceilingVoice)[0]
        XCTAssertEqual(voice.cyclesRed, 1110)
        XCTAssertEqual(voice.cyclesBlue, 1041)
        XCTAssertEqual(voice.cyclesPercent, 99.95, accuracy: 0.01)

        let fx = G2UsbProtocol.decodePatchLoad(ceilingFx)[0]
        XCTAssertEqual(fx.cyclesPercent, 99.58, accuracy: 0.01)
    }

    /// ZPmem doszło do `0x80` = 128 ze 128, czyli równo 100,0% — dzielnik potwierdzony
    /// dokładnie. **Bajt jest powyżej `0x7F`**, więc gdyby pole szło przez maskę siódmego
    /// bitu jak pola 16-bitowe, wyszłoby 0% w chwili całkowitego wyczerpania pamięci.
    func testZeroPageMemoryIsAFullByteAndReachesExactlyHundred() {
        let fx = G2UsbProtocol.decodePatchLoad(ceilingFx)[0]
        XCTAssertEqual(fx.zeroPageMemory, 128)
        XCTAssertEqual(fx.memoryPercent, 100, accuracy: 0.001)
    }

    /// Patch z prawdziwego edytora siada tuż POD limitem — jego autor dokładał moduły,
    /// dopóki edytor pozwalał. To dlatego próg czerwieni stoi na 98, a nie na 100
    /// (usterka #73): inaczej taki patch świeciłby na pomarańczowo.
    func testAPatchBuiltInTheRealEditorSitsJustUnderTheLimit() {
        for payload in [ceilingVoice, ceilingFx] {
            let load = G2UsbProtocol.decodePatchLoad(payload)[0]
            XCTAssertLessThanOrEqual(load.cyclesPercent, 100)
            XCTAssertLessThanOrEqual(load.memoryPercent, 100)
            XCTAssertGreaterThan(max(load.cyclesPercent, load.memoryPercent), 98)
        }
    }

    /// ⚠️ Ale przekroczyć limit MOŻNA: raport mówi, ile patch ŻĄDA, a urządzenie wgranego
    /// patcha pod tym kątem nie sprawdza. Wartości niżej to sześć modułów DelayB wgranych
    /// do slotu D 2026-09-08 (`USBProbe --dspcost 177 6`); jeden kosztuje 48 011 `Qmem`,
    /// więc sześć żąda 288 066 z 260 096 — **110,8%**.
    ///
    /// Test stoi na WARTOŚCIACH, nie na bajtach: sonda wypisuje odczyt już rozłożony,
    /// a rozdziału `Qmem` na cztery bajty nie mam z pomiaru i nie zamierzam go zmyślać.
    /// Sprawdzana jest tu arytmetyka procentu, nie dekoder — ten ma własne testy wyżej.
    func testDeviceReportsDemandSoThePercentageCanExceedHundred() {
        let sixDelays = G2PatchLoad(
            area: .fx, cyclesRed: 510, cyclesBlue: 0, zeroPageMemory: 6,
            xMemory: 84, yMemory: 36, programMemory: 426,
            ram: 0, qMemory: 288_066, rMemory: 24
        )
        XCTAssertEqual(sixDelays.memoryPercent, 110.75, accuracy: 0.01)
        XCTAssertEqual(sixDelays.criticalResource.resource, .qMemory)
        // Panel nie może tego obcinać do „100%": dwukrotne przekroczenie budżetu wyglądałoby
        // wtedy jak patch idealnie zapełniony.
        XCTAssertGreaterThan(sixDelays.memoryPercent, 100)
    }

    // MARK: - Wąskie gardło

    /// Panel nazywa zasób, nie tylko procent. Numeracja i KOLEJNOŚĆ porównań są Clavii
    /// (`FindCriticalResourceType` zwraca 1…7 w tej samej kolejności).
    func testCriticalResourceNamesTheBottleneck() {
        let ceiling = G2UsbProtocol.decodePatchLoad(ceilingFx)[0]
        XCTAssertEqual(ceiling.criticalResource.resource, .zeroPageMemory)
        XCTAssertEqual(ceiling.criticalResource.used, 128)
        XCTAssertEqual(ceiling.criticalResource.limit, 128)

        // W fx „Drama (SC)" wygrywa bufor delaya/reverbu, nie strona zerowa.
        let fx = G2UsbProtocol.decodePatchLoad(fxPayload)[0]
        XCTAssertEqual(fx.criticalResource.resource, .qMemory)
        XCTAssertEqual(fx.criticalResource.used, 113_547)
    }

    /// Kolejność w tablicy nie jest ozdobna: Clavia porównuje pierwszą parę NIEOSTRO,
    /// resztę ostro, więc przy remisie wygrywa zasób wcześniejszy. Tu `Xmem` i `Ymem`
    /// stoją oba równo w połowie — wskazać trzeba `Xmem`.
    func testTieGoesToTheEarlierResourceLikeInClavia() {
        var body = [UInt8](repeating: 0, count: 27)
        body[7] = 0x10 // Xmem = 2048 z 4336
        body[8] = 0x00
        body[9] = 0x0B // Ymem = 1408 z 2992
        body[10] = 0x00
        let load = G2UsbProtocol.decodePatchLoad([1] + body)[0]
        XCTAssertEqual(load.xMemory, 2048)
        XCTAssertEqual(load.yMemory, 1408)
        XCTAssertEqual(100.0 * 2048 / 4336, 100.0 * 1408 / 2992, accuracy: 0.5) // remis
        XCTAssertEqual(load.criticalResource.resource, .xMemory)
    }

    /// `memoryPercent` i `criticalResource` nie mogą się rozjechać — to jedna liczba.
    func testMemoryPercentIsTheCriticalResourcePercent() {
        for payload in [voicePayload, fxPayload, ceilingVoice, ceilingFx] {
            let load = G2UsbProtocol.decodePatchLoad(payload)[0]
            XCTAssertEqual(load.memoryPercent, load.criticalResource.percent, accuracy: 0.0001)
        }
    }

    // MARK: - Komendy

    func testPatchLoadRequestCarriesTheArea() {
        XCTAssertEqual(G2UsbProtocol.patchLoadRequestPayload(slot: 1, version: 9, area: .voice),
                       [0x01, 0x29, 9, 0x71, 1])
        XCTAssertEqual(G2UsbProtocol.patchLoadRequestPayload(slot: 0, version: 0, area: .fx)[4], 0)
    }

    /// Play Note jest komunikatem SYSTEMOWYM (`Synth.InitMsg` u BVerhue), więc nagłówek
    /// jest ten sam co przy zmianie trybu Patch/Performance, nie slotowy.
    func testPlayNoteIsASystemMessage() {
        XCTAssertEqual(G2UsbProtocol.playNotePayload(note: 60, on: true),
                       [0x01, 0x2C, 0x41, 0x56, 0x00, 60])
        XCTAssertEqual(G2UsbProtocol.playNotePayload(note: 60, on: false),
                       [0x01, 0x2C, 0x41, 0x56, 0x01, 60])
    }
}
