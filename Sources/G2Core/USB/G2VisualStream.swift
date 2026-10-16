// G2VisualStream.swift
// Dekodowanie strumienia wskaźników, który G2 nadaje sam z siebie po `Start`:
// `SUB_RESPONSE_VOLUME_INDICATOR` (0x3A, ~40×/s na slot). To jedyne źródło danych
// dla wskaźników miniVU — bez tego pokazują ciszę niezależnie od tego, co gra.
//
// Komunikat nie niesie ŻADNEJ adresacji: to goła sekwencja wartości, których
// przypisanie do modułów wynika wyłącznie z zawartości patcha w slocie. Dlatego
// tabela „ile miejsca zajmuje moduł danego typu" musi być dokładna — jedna pomyłka
// przesuwa wszystkie kolejne wartości.

import Foundation

/// Odczyt wskaźników VU jednego modułu; `values` to SUROWE bajty ze strumienia, po jednym
/// na kanał, w kolejności `groupID` z `MiniVUDatabase` (dla 2-Out: L, R). Poziom słupka
/// siedzi w młodszym półbajcie — przelicza go `segmentLevel(forValue:segments:)`.
public struct G2MeterReading: Sendable, Equatable {
    public let area: PatchArea
    public let moduleID: Int
    public let values: [Int]

    public init(area: PatchArea, moduleID: Int, values: [Int]) {
        self.area = area
        self.moduleID = moduleID
        self.values = values
    }
}

/// Odczyt GRUPY diod jednego modułu — 16-bitowa wartość ze strumienia `0x3A`.
/// Co znaczy, rozstrzyga `G2VisualStream.litLeds(groupValue:in:)`: zwykle jest indeksem
/// świecącej diody, przy ustawionych bitach `0x3000` maską, a `0xFFF` zapala całą grupę.
public struct G2LedGroupReading: Sendable, Equatable {
    public let area: PatchArea
    public let moduleID: Int
    public let value: Int

    public init(area: PatchArea, moduleID: Int, value: Int) {
        self.area = area
        self.moduleID = moduleID
        self.value = value
    }
}

/// Odczyt POJEDYNCZEJ diody (obwiednia, LFO, „Link" sekwencera) z komunikatu `0x39`.
/// `value` to dwa bity, 0–3; widżet oryginału zapala się przy czymkolwiek ≠ 0
/// (Green Led (SetColor): `lit = (value != 0)`).
public struct G2LedReading: Sendable, Equatable {
    public let area: PatchArea
    public let moduleID: Int
    /// `CodeRef` diody z panelu — po nim rysowanie ją odnajduje.
    public let codeRef: Int
    public let value: Int

    public var isLit: Bool {
        value != 0
    }

    public init(area: PatchArea, moduleID: Int, codeRef: Int, value: Int) {
        self.area = area
        self.moduleID = moduleID
        self.codeRef = codeRef
        self.value = value
    }
}

/// Wszystko, co niesie jeden komunikat `0x3A`: wskaźniki VU i grupy diod. Jadą wspólnym
/// strumieniem wpisów, więc i rozkładane są jednym przebiegiem.
public struct G2VisualReadings: Sendable, Equatable {
    public var meters: [G2MeterReading] = []
    public var ledGroups: [G2LedGroupReading] = []

    public init(meters: [G2MeterReading] = [], ledGroups: [G2LedGroupReading] = []) {
        self.meters = meters
        self.ledGroups = ledGroups
    }
}

public enum G2VisualStream {
    /// Które diody grupy mają świecić przy tej wartości ze strumienia.
    ///
    /// **Jedna reguła dla wszystkich grup** — multiplekserów, liczników, sekwencerów,
    /// przetwornika A/D i miernika kompresora. Rozstrzygnięte 2026-09-06 wprost
    /// z `CPanel::Blink(groupIndex, value)` w oryginalnym edytorze: o sposobie odczytu decyduje
    /// **sama wartość**, a nie typ modułu (dlatego nie ma tu żadnej tabeli typów):
    ///
    /// | wartość | znaczenie |
    /// |---|---|
    /// | `v & 0x3000 == 0x3000` | **maska bitowa** — bit `i` zapala diodę `i`; oryginał robi tak tylko dla grup mniejszych niż 12 diod, większe zostawia zgaszone |
    /// | `0xFFF` | **wszystkie diody grupy** świecą |
    /// | pozostałe | **indeks** jednej diody; wartość spoza grupy = nie świeci nic |
    ///
    /// Indeksem jest `CodeRef`, nie kolejność wpisu w panelu: `CLedDataList::PopulateList`
    /// wstawia diodę do wektora **pod indeks równy jej `CodeRef`** (`resize(CodeRef + 1)`),
    /// więc pomieszana kolejność wpisów w panelu (SeqNote: 0,1,2,3,12,13,…) nie ma znaczenia.
    ///
    /// Potwierdzone na żywym Nordzie 2026-09-06 (patch `noisemaker2_730`, slot D):
    /// przy zatrzymanym zegarze wszystkie grupy nadawały `0x0FFF`, a po `Run` multiplekser
    /// `Mux8-1` przeszedł czysty przemiat **0→1→…→7→6→…→0**, a osiem `SeqCtr` numery
    /// kroków z zakresu 0…15.
    public static func litLeds(groupValue: Int, in leds: [BVLED]) -> [BVLED] {
        let lit = Set(litCodeRefs(groupValue: groupValue, codeRefs: leds.map(\.codeRef)))
        return leds.filter { lit.contains($0.codeRef) }
    }

    /// Ta sama reguła co `litLeds(groupValue:in:)`, ale na samych numerach `CodeRef` —
    /// rysowanie ma je policzone z góry (patrz `LiveIndicatorPlan`) i nie musi przy każdej
    /// klatce sięgać do definicji panelu.
    public static func litCodeRefs(groupValue: Int, codeRefs: [Int]) -> [Int] {
        // Rozmiar grupy liczy się jak w oryginale: wektor jest rozciągnięty do
        // największego `CodeRef` + 1, więc luki w numeracji też zajmują miejsce.
        let count = (codeRefs.max() ?? -1) + 1
        if groupValue & 0x3000 == 0x3000 {
            guard count < 12 else { return [] }
            return codeRefs.filter { $0 < count && (groupValue >> $0) & 1 == 1 }
        }
        if groupValue == 0xFFF { return codeRefs }
        return codeRefs.filter { $0 == groupValue }
    }

    /// Typy modułów, których GRUPA diod jedzie tym samym strumieniem co VU — jedna
    /// grupa = jeden wpis (2 bajty), niezależnie od liczby diod w grupie. Pojedyncze
    /// diody (obwiednie, LFO) idą osobnym komunikatem `LED_DATA` (0x39) i tu ich nie ma.
    ///
    /// Źródło: `reference/g2fx/src/main/java/org/g2fx/g2lib/model/ModuleType.java`
    /// (`ledgroup(…)`) + `PatchVisuals.readVolumeData`, gdzie strumień składa się z
    /// wpisów `Meter` i `LedGroup` razem. Zgodność ID sprawdzona z `ModuleDatabase`.
    public static let ledGroupModuleTypes: Set<Int> = [
        21, // Mux1-8
        60, // Mux8-1X
        86, // 8Counter
        91, // FlipFlop
        121, // SeqNote
        124, // Mux8-1
        130, // BinCounter
        131, // ADConv
        144, // SeqEvent
        145, // SeqVal
        146, // SeqLev
        150, // Compress
        154, // SeqCtr
    ]

    /// Diody należące do GRUPY modułu — tej, której wartość niesie strumień `0x3A`.
    /// Pusto, gdy moduł grupy nie ma.
    ///
    /// **Do grupy należą WSZYSTKIE diody modułu**, także zielona „Park" sekwencera
    /// (`CodeRef` 16, obok szesnastu diod kroków). Wynika to wprost z panelu: wszystkie
    /// mają `GroupId:0`, a `CPanel::Blink` bierze do grupy każdą diodę o tym `GroupId`.
    /// Dlatego wartość 16 zapala „Park" — i dokładnie taką wartość nadawały sekwencery
    /// zmierzone 2026-09-04, gdy stały. (g2fx modeluje to inaczej — `ledgroup(Radio,16)`
    /// plus osobna dioda „Link" — i to jego rekonstrukcja, nie oryginał: pomiar
    /// 2026-09-06 pokazał, że urządzenie **nie** wysyła dla sekwencera wpisu w `0x39`.)
    public static func groupLeds(typeID: Int) -> [BVLED] {
        guard ledGroupModuleTypes.contains(typeID),
              let ui = ModuleUIDatabase.shared.uiDef(forID: typeID) else { return [] }
        return ui.leds
    }

    /// Diody sterowane komunikatem `0x39` — pojedyncze diody modułów **bez** grupy
    /// (obwiednie, LFO, bramki logiczne). Moduł z grupą nie wnosi do tego strumienia nic.
    ///
    /// Zmierzone na żywym Nordzie 2026-09-06: patch z ośmioma `SeqCtr` i dziewięcioma
    /// LFO dawał w `0x39` **dokładnie dziewięć** żywych wpisów — tyle, ile LFO. Wpisy
    /// dalej niż dziewiąty były stale zgaszone, czyli urządzenie ich w ogóle nie ma.
    public static func singleLeds(typeID: Int) -> [BVLED] {
        guard !ledGroupModuleTypes.contains(typeID),
              let ui = ModuleUIDatabase.shared.uiDef(forID: typeID) else { return [] }
        return ui.leds
    }

    /// Ile wpisów (po 2 bajty) zajmuje w strumieniu moduł danego typu.
    /// Liczba VU bierze się z `MiniVUDatabase` — tej samej tabeli, z której rysujemy
    /// wskaźniki na panelu (18 modułów, 29 wskaźników; zgodna co do sztuki z
    /// `Class: "MiniVU"` w danych paneli oryginalnego edytora).
    public static func visualCount(typeID: Int) -> Int {
        MiniVUDatabase.defs(forModuleID: typeID).count + (ledGroupModuleTypes.contains(typeID) ? 1 : 0)
    }

    /// Moduły w kolejności, w jakiej ich wartości leżą w komunikacie: najpierw obszar
    /// voice, potem fx, w każdym rosnąco po numerze modułu (`CPatch` po stronie
    /// urządzenia iteruje tak samo — `usbComms.c` idzie `location` 1→0, indeks 0→255).
    public static func modulesInStreamOrder(_ patch: G2Patch) -> [G2Module] {
        [PatchArea.voice, .fx].flatMap { area in
            patch.modules(in: area).sorted { $0.id < $1.id }
        }
    }

    /// Ile wpisów mieści się w payloadzie tej długości. Komunikat ma **stałą wielkość**
    /// (81 B = 1 + 40 wpisów, zmierzone na żywym sprzęcie 2026-09-04 — identyczna dla
    /// patcha z 7 wskaźnikami i dla patcha z 54), więc moduły powyżej 40. wpisu po prostu
    /// nie są raportowane. To ograniczenie urządzenia, nie nasze.
    public static func entryCapacity(payloadLength: Int) -> Int {
        max(0, (payloadLength - 1) / 2)
    }

    /// Ile wpisów zajęłaby pełna zawartość patcha — diagnostyka (`USBProbe --listen`),
    /// pozwala zobaczyć, ile modułów wypada poza pojemność komunikatu.
    public static func entryCount(of patch: G2Patch) -> Int {
        modulesInStreamOrder(patch).reduce(0) { $0 + visualCount(typeID: $1.typeID) }
    }

    /// Przelicza wartość wskaźnika ze strumienia na liczbę zapalonych segmentów.
    ///
    /// **Poziomem są cztery najmłodsze bity, nie cała wartość** (`value & 0x0F` → 0…15).
    /// Rozstrzygnięte 2026-09-06 wprost w oryginalnym edytorze Clavii. Widżetem, który w oknie
    /// patcha powstaje z wpisu `<#MiniVU` panelu, jest Peak Meter (7×16 px):
    /// Module Generic (CreateLed) tworzy dla diod dokładnie pięć klas i to jedyna
    /// „miernikowa" wśród nich. Jej `Draw` zaczyna od `bVar5 = (byte)value & 0xf`
    /// i tylko tym steruje słupkiem — 7 zielonych linii świeci przy `poziom >= 7…1`,
    /// 4 żółte przy `poziom >= 11…8`, czerwony blok przy `poziom > 11`.
    ///
    /// Bez maski wartość 41 (`0x29` = poziom 9 ze znacznikiem `0x20`) przycinała się do 15
    /// i wskaźnik stał na maksimum — tak wyglądało zgłoszenie „`Mix4-1C` pokazuje 41–43".
    ///
    /// **Starsze bity to ZNACZNIKI i podnoszą słupek do progu, zamiast zapalać kreski.**
    /// Oryginał zapala nimi konkretne elementy niezależnie od poziomu: `0x40` czerwony blok
    /// (przester), `0x30` dwie górne żółte linie — te, które normalnie potrzebują poziomu
    /// 11 i 10. Przepisane wprost, zrobiłoby to na słupku **dziurę**: świeci do połowy,
    /// przerwa, znów dwie kreski — wyglądałoby na błąd rysowania.
    ///
    /// Dlatego znacznik działa jak **podłoga**: `0x30` → co najmniej 11, `0x40` → co
    /// najmniej 12. Słupek w oknie patcha ma 12 diod jak oryginał, więc przester zapala
    /// go do samej góry (do 2026-09-27 miał 15 kresek i przester sięgał tylko do 12.). Dla wartości zmierzonych na sprzęcie wychodzi **dokładnie ten sam
    /// obrazek co u Clavii** — `0x29`/`0x2A`/`0x2B` (poziom 9/10/11 ze znacznikiem) dają
    /// u obu pełne cztery żółte. Różnimy się dopiero przy poziomie 8 ze znacznikiem: Clavia
    /// pokazuje wtedy dziurę (jedna żółta, przerwa, dwie górne), a my ciągły słupek.
    /// Wybór świadomy — patrz [[Docs/ui/widgets]].
    ///
    /// Zakres 0–15 zgadza się z BVerhue (`TTiledTexture.CreateMiniVU`: 16 wierszy,
    /// zieleń < 8, żółć 8–11, czerwień 12–15), więc rozpoznanie z 2026-09-04 było dobre
    /// co do zakresu — myliło się tylko co do tego, że wartość to sam poziom.
    public static func segmentLevel(forValue value: Int, segments: Int) -> Int {
        guard segments > 0, value >= 0 else { return 0 }
        var level = value & 0x0F
        if value & 0x30 != 0 { level = max(level, 11) }
        if value & 0x40 != 0 { level = max(level, 12) }
        return min(segments, level)
    }

    /// Rozkłada payload 0x3A na odczyty VU i grup diod dla modułów tego patcha.
    ///
    /// Układ, wprost z oryginału (Synth Port (InterruptHandleBlinkData), gałąź `':'`):
    /// pierwszy bajt payloadu to **numer pierwszego wskaźnika** w tym komunikacie
    /// (`SetMultiLed(start + i, …)`), potem po 2 bajty na wpis, czytane jako liczba
    /// 16-bitowa. Dla wskaźnika VU znaczący jest młodszy bajt (0–255) — tak samo bierze
    /// go BVerhue (`Read(Unknown,1); Read(b,1); Led.SetValue(b)`) i g2fx.
    ///
    /// Wpisy grup diod zajmują tyle samo miejsca i niosą **indeks świecącej diody**
    /// (patrz `G2LedGroupReading`) — do 2026-09-06 były tu tylko przeskakiwane, więc
    /// sekwencer na ekranie nie pokazywał, na którym kroku gra.
    ///
    /// **Zweryfikowane na żywym sprzęcie 2026-09-04.** Dla patcha z 24 grupami diod
    /// bajty ułożyły się dokładnie tak, jak przewiduje ta kolejność: 18 wpisów obszaru
    /// voice, potem dwa bloki po 8 sekwencerów `SeqCtr` (wartości 16 i 255 — oba poza
    /// zakresem 0…15, czyli „nic nie świeci", bo sekwencery stały), potem sześć wpisów
    /// kolejnych modułów fx — i koniec na 40.
    public static func decodeVolumeData(_ payload: [UInt8], layout: G2VisualLayout) -> G2VisualReadings {
        guard let first = payload.first else { return G2VisualReadings() }
        let start = Int(first)
        let capacity = entryCapacity(payloadLength: payload.count)
        /// Wartość wpisu o numerze `index` liczonym od początku CAŁEJ tablicy wskaźników,
        /// nie od początku komunikatu — komunikat może zaczynać się od dalszego wskaźnika.
        /// Dla wskaźnika VU znaczący jest młodszy bajt; grupa diod używa obu.
        func value(at index: Int) -> (low: Int, word: Int)? {
            let offset = index - start
            guard offset >= 0, offset < capacity else { return nil }
            let low = Int(payload[1 + 2 * offset])
            let high = 2 + 2 * offset < payload.count ? Int(payload[2 + 2 * offset]) : 0
            return (low, low | (high << 8))
        }

        var readings = G2VisualReadings()
        for meter in layout.meters {
            // Poza oknem komunikatu nie ma już czego czytać — wpisy PRZED nim po prostu
            // pomijamy (moduł jest w slocie, tylko ten komunikat go nie opisuje).
            guard meter.firstEntry < start + capacity else { break }
            // Moduł wpadający w krawędź okna (część kanałów poza nim) opuszczamy
            // w całości — pół odczytu byłoby myląco przypisane do złych kanałów.
            let values = (0 ..< meter.count).compactMap { value(at: meter.firstEntry + $0)?.low }
            guard values.count == meter.count else { continue }
            readings.meters.append(G2MeterReading(area: meter.area, moduleID: meter.moduleID,
                                                  values: values))
        }
        for group in layout.groups {
            guard group.entry < start + capacity else { break }
            guard let groupValue = value(at: group.entry) else { continue }
            readings.ledGroups.append(G2LedGroupReading(area: group.area, moduleID: group.moduleID,
                                                        value: groupValue.word))
        }
        return readings
    }

    /// Wygoda dla testów i `USBProbe`, gdzie plan liczy się raz na wywołanie. Aplikacja
    /// używa wersji z gotowym `G2VisualLayout` — patrz `DeviceConnection.visualLayout`.
    public static func decodeVolumeData(_ payload: [UInt8], patch: G2Patch) -> G2VisualReadings {
        decodeVolumeData(payload, layout: G2VisualLayout(patch: patch))
    }

    /// Rozkłada payload `0x39` (`LED_DATA`) na pojedyncze diody modułów tego patcha.
    ///
    /// Układ, wprost z oryginału (Synth Port (InterruptHandleBlinkData), gałąź `'9'`):
    /// pierwszy bajt payloadu to numer pierwszej diody, potem **2 bity na diodę, cztery
    /// diody w bajcie, licząc od najmłodszych bitów**. Tak samo czyta to g2fx
    /// (`PatchVisuals.readLedData`). Komunikat ma 11 B = 1 + 40 diod, czyli tyle, ile
    /// mieści tablica urządzenia (`0x28` w `SetDualLed`).
    ///
    /// Kolejność diod jest ta sama, co przy wskaźnikach: obszar voice, potem fx, w każdym
    /// rosnąco po numerze modułu, a w module — kolejnością z panelu (`singleLeds`).
    public static func decodeLedData(_ payload: [UInt8], layout: G2VisualLayout) -> [G2LedReading] {
        guard let first = payload.first else { return [] }
        let start = Int(first)
        let capacity = (payload.count - 1) * 4
        var readings: [G2LedReading] = []
        for led in layout.leds {
            let offset = led.index - start
            guard offset >= 0 else { continue }
            guard offset < capacity else { break }
            let value = (Int(payload[1 + offset / 4]) >> (2 * (offset % 4))) & 0x03
            readings.append(G2LedReading(area: led.area, moduleID: led.moduleID,
                                         codeRef: led.codeRef, value: value))
        }
        return readings
    }

    /// Wygoda dla testów i `USBProbe` — jak przy `decodeVolumeData`.
    public static func decodeLedData(_ payload: [UInt8], patch: G2Patch) -> [G2LedReading] {
        decodeLedData(payload, layout: G2VisualLayout(patch: patch))
    }
}
