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
// ⚠️ Czego szacunek NIE obejmuje: kabli (pomiar robiony bez nich) ani nastawy czasu
// w modułach opóźniających, dla których koszt od niej zależy. Moduł spoza katalogu
// (typ nierozpoznany) liczy się jako zerowy — takie wyłapuje `PatchValidator`.

import Foundation

public extension G2PatchLoad {
    /// Sumuje koszt modułów obszaru w taki sam odczyt, jaki przysyła urządzenie.
    ///
    /// Zmierzone 2026-09-08 na 22 modułach `DlyClock`: 22 × 131 = 2882 jednostki pamięci Y
    /// (96,3% z 2992) i 22 × 47 = 1034 cykle (75,4% z 1371) — dokładnie to, co pokazał Nord.
    static func estimate(area: PatchArea, modules: [G2Module]) -> G2PatchLoad {
        let total = modules
            .compactMap { ModuleResourceCostDatabase.cost(typeID: $0.typeID) }
            .reduce(ModuleResourceCost.zero, +)
        return G2PatchLoad(
            area: area,
            cyclesRed: total.cyclesRed,
            cyclesBlue: total.cyclesBlue,
            zeroPageMemory: total.zeroPageMemory,
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

public extension ModuleResourceCost {
    /// Pusty obszar — punkt startowy sumowania.
    static let zero = ModuleResourceCost(0, 0, 0, 0, 0, 0, 0, 0, 0)

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
