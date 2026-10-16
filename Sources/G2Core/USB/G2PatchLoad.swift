// G2PatchLoad.swift
// Obciążenie DSP obszaru patcha — treść komunikatu `0x72` (Patch Load).
//
// Po co: G2 ma twardy limit mocy i pamięci na slot, a oryginalny edytor mówi, ile
// zostało, dopiero PO dodaniu modułu. Żeby dało się to odwrócić, trzeba najpierw
// umieć odczytać, ile patch zjada teraz.
//
// ŹRÓDŁO NR 1 — Clavia, przeczytana 2026-09-07. Patch Load (ReadStream) czyta bajt
// obszaru i 27 bajtów, które są DOKŁADNIE strukturą `SModuleResourceSpec` (dowód:
// Patch Load (SetDspReportedLoad) kopiuje 8 × 4 bajty, a `GetCycles`/`GetXmem`/…
// czytają te same przesunięcia). Wzory i dzielniki niżej pochodzą z tych getterów.
//
// BVerhue (`TG2Slot.ProcessMsgResourcesUsed` + `CalcPatchLoadCycles`/`CalcPatchLoadMem`)
// ma te same POZYCJE pól, ale inną arytmetykę — i myli się. Do 2026-09-07 liczyliśmy
// za nim → [[Docs/usb/protocol-map]]. (Uwaga na nazwy u BVerhue: `ProcessMsgPatchLoad`
// to co innego — „patch został załadowany", czyta nazwę i chunk.)
//
// **Zmierzone na żywym G2 2026-09-07** (`USBProbe --dsp`, firmware 1.62): osiem próśb
// `0x71` → osiem odpowiedzi, każda z JEDNYM rekordem 28 B. Pusty slot daje 27 zer,
// a pole Qmem jest niezerowe wyłącznie w fx — tam, gdzie siedzą delay i reverb.
//
// **Skala potwierdzona 2026-09-08** na `wtabxshapesyn_tk.prf2` przy 6 głosach — patchu,
// który stoi pod samym korkiem. Dzielnik mocy 1371 trafiony co do ułamka cyklu (obszar
// zgłosił 1370,25 → 99,9%), a ZPmem doszło do 128/128, czyli równo 100,0%. Dowodem jest to,
// że patch powstał w PRAWDZIWYM edytorze: jego autor dokładał moduły, dopóki edytor pozwalał,
// więc zatrzymał się tuż pod granicą, którą odtwarzamy.
//
// ⚠️ **Raport mówi, ile patch ŻĄDA — nie ile dostał.** Urządzenie nie sprawdza wgranego
// patcha pod kątem zasobów: sześć modułów DelayB dało 110,8% Qmem, dziesięć 184,6%
// (`USBProbe --dspcost 177 10`, 2026-09-08). Limitów pilnuje edytor, nie sprzęt — więc
// sprzęt nie może ich potwierdzić. Wszystkie siedem dzielników pamięci i 1371 dla mocy
// odpowiadają oryginalnemu edytorowi znak po znaku.

import Foundation

/// Siedem pamięci, o które patch może się rozbić. Numeracja jest Clavii — kolejność
/// porównań w Patch Load (FindCriticalResourceType), gdzie funkcja zwraca właśnie 1…7.
public enum DSPResource: Int, Sendable, CaseIterable {
    case xMemory = 1
    case yMemory = 2
    case programMemory = 3
    case zeroPageMemory = 4
    case ram = 5
    case qMemory = 6
    case rMemory = 7

    /// Nazwa do interfejsu — angielska, jak reszta UI.
    public var label: String {
        switch self {
        case .xMemory: "X memory"
        case .yMemory: "Y memory"
        case .programMemory: "Program memory"
        case .zeroPageMemory: "Zero page"
        case .ram: "RAM"
        case .qMemory: "Q memory"
        case .rMemory: "R memory"
        }
    }
}

/// Zasób, który jest najbliżej swojego limitu — to on rozstrzyga „ile pamięci zostało".
public struct DSPCriticalResource: Sendable, Equatable {
    public let resource: DSPResource
    public let used: Int
    public let limit: Int

    public var percent: Double {
        100.0 * Double(used) / Double(limit)
    }
}

/// Odczyt obciążenia JEDNEGO obszaru (voice albo fx) jednego slotu.
///
/// Pola są surowe — przeliczanie na procenty siedzi w `cyclesPercent`/`memoryPercent`,
/// bo to ono jest wiedzą o oryginale, nie same liczby.
public struct G2PatchLoad: Sendable, Equatable {
    public let area: PatchArea
    /// Dwa zegary DSP, które G2 rozlicza osobno — u BVerhue „red" i „blue".
    public let cyclesRed: Int
    public let cyclesBlue: Int
    /// Pamięć strony zerowej (`GetZPmem`), jedyne pole jednobajtowe w rekordzie.
    public let zeroPageMemory: Int
    /// Trzy pamięci DSP. Każda jest SUMĄ dwóch pól rekordu — Clavia dodaje je do siebie
    /// (`GetXmem` czyta `+0x08` i `+0x0e`), a BVerhue drugiej połowy nie czytał wcale.
    public let xMemory: Int
    public let yMemory: Int
    public let programMemory: Int
    /// Trzy pamięci zewnętrzne. `qMemory` to ta, którą BVerhue nazywał „RAM" — jedyne
    /// pole 32-bitowe. Pełnymi bajtami idzie też `zeroPageMemory`; maska siódmego bitu
    /// dotyczy wyłącznie pól 16-bitowych.
    public let ram: Int
    public let qMemory: Int
    public let rMemory: Int

    /// Ile procent mocy DSP zjada ten obszar (Patch Load (GetCycles)).
    ///
    /// Clavia liczy `(red + blue/4) / 1371`, czyli zegar „blue" waży cztery razy mniej.
    /// BVerhue rozbijał to na dwa ułamki i dzielił „blue" przez 5000 zamiast przez 5484
    /// — na zmierzonym patchu dawało to 37,5% zamiast 36,2%.
    public var cyclesPercent: Double {
        (Double(cyclesRed) + Double(cyclesBlue) * 0.25) * 100.0 / 1371.0
    }

    /// Siedem pamięci ze swoimi limitami, **w kolejności porównań Clavii**. Kolejność nie
    /// jest ozdobna: przy remisie wygrywa wcześniejsza (`FindCriticalResourceType` porównuje
    /// pierwszą parę nieostro, resztę ostro), więc przestawienie zmieniłoby wynik.
    /// Dzielniki są z getterów Patch Load; trzy z nich (`ZPmem` 1/128, `RAM` 1/131072,
    /// `Rmem` 1/256) widać drugi raz wprost w `FindCriticalResourceType`.
    private var resources: [DSPCriticalResource] {
        [
            .init(resource: .xMemory, used: xMemory, limit: 4336),
            .init(resource: .yMemory, used: yMemory, limit: 2992),
            .init(resource: .programMemory, used: programMemory, limit: 6498),
            .init(resource: .zeroPageMemory, used: zeroPageMemory, limit: 128),
            .init(resource: .ram, used: ram, limit: 131_072),
            .init(resource: .qMemory, used: qMemory, limit: 260_096),
            .init(resource: .rMemory, used: rMemory, limit: 256),
        ]
    }

    /// Zasób najbliższy swojego limitu — wąskie gardło tego obszaru.
    ///
    /// Zmierzone 2026-09-08: w KAŻDYM dotąd odczytanym obszarze wygrywa `ZPmem` albo
    /// `Qmem`. Pozostałych pięciu dzielników sprzęt jeszcze nie potwierdził.
    public var criticalResource: DSPCriticalResource {
        resources.dropFirst().reduce(resources[0]) { best, next in
            next.percent > best.percent ? next : best
        }
    }

    /// Ile procent pamięci zjada ten obszar. Moc DSP do tego maksimum NIE wchodzi —
    /// dlatego panel ma dwa paski, nie jeden.
    public var memoryPercent: Double {
        criticalResource.percent
    }

    public init(area: PatchArea, cyclesRed: Int, cyclesBlue: Int, zeroPageMemory: Int,
                xMemory: Int, yMemory: Int, programMemory: Int,
                ram: Int, qMemory: Int, rMemory: Int)
    {
        self.area = area
        self.cyclesRed = cyclesRed
        self.cyclesBlue = cyclesBlue
        self.zeroPageMemory = zeroPageMemory
        self.xMemory = xMemory
        self.yMemory = yMemory
        self.programMemory = programMemory
        self.ram = ram
        self.qMemory = qMemory
        self.rMemory = rMemory
    }
}

public extension G2UsbProtocol {
    /// Długość jednego rekordu obciążenia: bajt obszaru + 27 bajtów danych.
    private static var patchLoadRecordLength: Int {
        28
    }

    /// Rozkłada payload `0x72` na odczyty obszarów.
    ///
    /// Jedna ramka MOŻE nieść dwa rekordy — voice i fx — rozdzielone powtórzonym bajtem
    /// podkomendy; `TG2Slot.ProcessMsgResourcesUsed` czyta drugi dokładnie tak samo, gdy
    /// zostało miejsce przed CRC. ⚠️ Na naszym G2 (fw 1.62) ta forma się nie pojawiła:
    /// osiem próśb `0x71` dało osiem odpowiedzi po jednym rekordzie. Pętla zostaje, bo
    /// oryginał ją dopuszcza, ale nie jest zmierzona.
    static func decodePatchLoad(_ payload: [UInt8]) -> [G2PatchLoad] {
        var readings: [G2PatchLoad] = []
        var index = 0
        while index + patchLoadRecordLength <= payload.count {
            // Znacznik drugiego (i kolejnego) rekordu w tej samej ramce.
            if payload[index] == subResponsePatchLoad, index + 1 + patchLoadRecordLength <= payload.count {
                index += 1
            }
            let area: PatchArea = payload[index] == 1 ? .voice : .fx
            let body = Array(payload[(index + 1) ..< (index + patchLoadRecordLength)])

            /// Pola 16-bitowe idą przez Bit Stream (GetUWordMSBZeros), czyli SIEDEM bitów
            /// na bajt (`(b0 & 0x7f) << 7 | (b1 & 0x7f)`). Poza nimi są DWA pola czytane
            /// pełnymi bajtami: Qmem (Clavia woła Bit Stream (GetUWord) wprost, z pominięciem
            /// tablicy wirtualnej) i jednobajtowe ZPmem.
            ///
            /// ⚠️ Pomiar 2026-09-08 prostuje wcześniejszą notatkę stąd, że „bajty > 0x7F
            /// występują wyłącznie w Qmem". Patch pod korek dał **ZPmem = `0x80`**, czyli
            /// pełne 128 ze 128. Gdyby to pole szło przez maskę siódmego bitu, pokazalibyśmy
            /// 0% w chwili, gdy pamięć strony zerowej jest wyczerpana do końca.
            func word(_ offset: Int) -> Int {
                Int(body[offset] & 0x7F) << 7 | Int(body[offset + 1] & 0x7F)
            }

            readings.append(G2PatchLoad(
                area: area,
                cyclesRed: word(0),
                cyclesBlue: word(2),
                zeroPageMemory: Int(body[4]),
                xMemory: word(7) + word(13),
                yMemory: word(9) + word(15),
                programMemory: word(11) + word(17),
                ram: word(19),
                qMemory: Int(body[21]) << 24 | Int(body[22]) << 16 | Int(body[23]) << 8 | Int(body[24]),
                rMemory: word(25)
            ))
            index += patchLoadRecordLength
        }
        return readings
    }
}
