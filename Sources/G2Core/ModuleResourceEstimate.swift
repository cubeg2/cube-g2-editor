// ModuleResourceEstimate.swift
// Obciążenie obszaru policzone z samego patcha — bez pytania urządzenia.
//
// Po co: raport `0x72` przychodzi wyłącznie od podłączonego G2, więc dla patcha z dysku
// panel DSP nie miał czego pokazać. Ta sama arytmetyka na zmierzonej tabeli kosztów
// (`ModuleResourceCost`) daje odczyt bez sprzętu — a przy podłączonym Nordzie służy do
// sprawdzenia, czy tabela wciąż zgadza się z rzeczywistością.
//
// Wynikiem jest zwykły `G2PatchLoad`, więc procenty, wąskie gardło i progi kolorów liczy
// dokładnie ten sam kod co dla odczytu ze sprzętu. To jest cały sens: jeden zestaw wzorów,
// dwa źródła liczb — inaczej rozjechałyby się przy pierwszej poprawce.
//
// Od 2026-10-28 szacunek zna też uprate, podłączone wejścia i tryby modułów
// (`ModuleResourceCostExtras`). Bez tego Vermona PERfourMER pokazywał 69 %, a Nord liczył
// go na 117 % i patch milczał: uprate przenosi zegar „blue” (ważony 1/4) na „red”.
// Sprawdzone na 80 patchach z raportem `0x72`: moc obu obszarów w ±0,25 punktu.
// Pamięć delaya zależy od zakresu (trybu), nie od nastawy czasu. Każdy obszar dokłada
// stronę zerową na klawiaturę i wspólną pulę (`sharedZeroPage`) — bez tego 0-Coast
// pokazywał 65,6 % pamięci zamiast 79,7 %.
//
// Moduł spoza katalogu (typ nierozpoznany) liczy się jako zerowy — takie wyłapuje
// `PatchValidator`.

import Foundation

public extension G2PatchLoad {
    /// Obciążenie obszaru tak, jak policzy je Nord po wgraniu patcha przez edytor.
    ///
    /// Flagi uprate są przeliczane na kopii, bo edytor robi to przy otwarciu każdego
    /// pliku — patch zapisany bez nich (np. przez MCP) i tak dojdzie do Norda z nimi.
    static func estimate(area: PatchArea, patch: G2Patch) -> G2PatchLoad {
        var patch = patch
        patch.recomputeUprates()
        return estimate(area: area, modules: patch.modules(in: area), cables: patch.cables(in: area))
    }

    /// Sumuje koszt modułów obszaru w taki sam odczyt, jaki przysyła urządzenie.
    /// Flagi uprate bierze z modułów takie, jakie są.
    ///
    /// Zmierzone 2026-09-08 na 22 modułach `DlyClock`: 22 × 131 = 2882 jednostki pamięci Y
    /// (96,3% z 2992) i 22 × 47 = 1034 cykle (75,4% z 1371) — dokładnie to, co pokazał Nord.
    static func estimate(area: PatchArea, modules: [G2Module], cables: [G2Cable] = []) -> G2PatchLoad {
        let connected = Set(cables.flatMap { [$0.destinationConnector, $0.sourceConnector] }
            .filter { !$0.isOutput })
        let total = modules.reduce(ModuleResourceCost.zero) { sum, module in
            let inputs = connected.filter { $0.moduleID == module.id }.map(\.index)
            return sum + ModuleResourceCostDatabase.cost(of: module, connectedInputs: inputs)
        }
        return G2PatchLoad(
            area: area,
            cyclesRed: total.cyclesRed,
            cyclesBlue: total.cyclesBlue,
            zeroPageMemory: total.zeroPageMemory + ModuleResourceCostDatabase.sharedZeroPage(of: modules),
            xMemory: total.xMemory,
            yMemory: total.yMemory,
            programMemory: total.programMemory,
            ram: total.ram,
            qMemory: total.qMemory,
            rMemory: total.rMemory
        )
    }

    /// Ten sam odczyt powiększony o jeden moduł danego typu — „ile będzie po dorzuceniu".
    ///
    /// Punktem wyjścia bywa raport z urządzenia, więc dokładany jest wyłącznie koszt
    /// z tabeli. Typ spoza katalogu nie zmienia nic — nie znamy jego ceny i nie ma
    /// powodu jej zgadywać.
    func adding(typeID: Int) -> G2PatchLoad {
        guard let cost = ModuleResourceCostDatabase.cost(typeID: typeID) else { return self }
        return G2PatchLoad(
            area: area,
            cyclesRed: cyclesRed + cost.cyclesRed,
            cyclesBlue: cyclesBlue + cost.cyclesBlue,
            zeroPageMemory: zeroPageMemory + cost.zeroPageMemory,
            xMemory: xMemory + cost.xMemory,
            yMemory: yMemory + cost.yMemory,
            programMemory: programMemory + cost.programMemory,
            ram: ram + cost.ram,
            qMemory: qMemory + cost.qMemory,
            rMemory: rMemory + cost.rMemory
        )
    }
}

public extension ModuleResourceCostDatabase {
    /// Strona zerowa, którą obszar dokłada ponad koszt samych modułów. Tabela kosztów jest
    /// z kalibracji molekułami, a przy wgraniu całym patchem (jak edytor) Nord bierze więcej:
    /// Keyboard, Device i MonoKey płacą raz swoją kwotę, pozostałe typy dzielą jedną pulę,
    /// której wielkość wyznacza najbardziej wymagający obecny typ — jak w instrukcji G2:
    /// pierwszy LFO zjada dużo, następny mało. Zmierzone 2026-10-28: voice 62 z 83,
    /// fx 51 z 53 obszarów dokładnie, reszta ±1–2 jednostki.
    static func sharedZeroPage(of modules: [G2Module]) -> Int {
        let types = Set(modules.map(\.typeID))
        let once = types.reduce(0) { $0 + (onceZeroPage[$1] ?? 0) }
        return once + (types.compactMap { poolZeroPage[$0] }.max() ?? 0)
    }

    /// Koszt jednego modułu w patchu: sam moduł, dopłaty za podłączone wejścia i uprate.
    /// Typ spoza katalogu kosztuje zero. `connectedInputs` może się powtarzać.
    ///
    /// Uprate zwykle przenosi CAŁY zegar „blue” (ważony 1/4) na „red”; pamięć się nie
    /// zmienia. Zmierzone 2026-10-28 (`USBProbe --dspcal`), np. `OscB` 66/8 → 74/0. Wyjątki
    /// (obwiednie nie drożeją wcale, `Overdrive` przenosi 70 z 96) są w `uprateExtra`.
    /// Dopłaty za wejścia przechodzą na „red” zawsze.
    static func cost(of module: G2Module, connectedInputs: [Int]) -> ModuleResourceCost {
        guard let measured = cost(typeID: module.typeID) else { return .zero }
        // Tryby (zakres delaya, kształt fali, nachylenie filtra) zmieniają koszt samego modułu.
        let modeTable = modeExtra[module.typeID] ?? [:]
        let single = module.modes.enumerated().reduce(measured) { sum, mode in
            sum + (modeTable[mode.offset]?[mode.element] ?? .zero)
        }
        let extras = inputExtra[module.typeID] ?? [:]
        // Wejścia jednej grupy (Pitch i PitchVar, para wejść miksera) płacą raz.
        let groups = inputGroup[module.typeID] ?? [:]
        let paying = Set(connectedInputs.map { groups[$0] ?? $0 })
        let wiring = paying.reduce(ModuleResourceCost.zero) { $0 + (extras[$1] ?? .zero) }
        guard module.uprate else { return single + wiring }
        let body = uprateExtra[module.typeID].map { single + $0 } ?? single.atAudioRate
        return body + wiring.atAudioRate
    }
}

public extension ModuleResourceCost {
    /// Pusty obszar — punkt startowy sumowania.
    static let zero = ModuleResourceCost(0, 0, 0, 0, 0, 0, 0, 0, 0)

    /// Ten sam koszt z zegarem „blue” przeniesionym na „red” — tak liczy go uprate.
    var atAudioRate: ModuleResourceCost {
        self + ModuleResourceCost(cyclesBlue, -cyclesBlue, 0, 0, 0, 0, 0, 0, 0)
    }

    static func + (lhs: ModuleResourceCost, rhs: ModuleResourceCost) -> ModuleResourceCost {
        ModuleResourceCost(
            lhs.cyclesRed + rhs.cyclesRed,
            lhs.cyclesBlue + rhs.cyclesBlue,
            lhs.xMemory + rhs.xMemory,
            lhs.yMemory + rhs.yMemory,
            lhs.programMemory + rhs.programMemory,
            lhs.zeroPageMemory + rhs.zeroPageMemory,
            lhs.ram + rhs.ram,
            lhs.qMemory + rhs.qMemory,
            lhs.rMemory + rhs.rMemory
        )
    }
}
