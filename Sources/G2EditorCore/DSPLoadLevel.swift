// DSPLoadLevel.swift
// Próg alarmowy dla obciążenia DSP — wspólny dla panelu „DSP Load" i belki górnej.
//
// Po co osobny typ: obie te rzeczy pokazują ten sam procent i do 2026-09-07 miały DWIE
// różne tabele progów (panel czerwienił się przy 100, belka przy 98), przy czym komentarz
// w obu twierdził, że to ten sam próg. Tu jest jedno miejsce i jest testowalne — bez
// SwiftUI, więc wchodzi do G2EditorCore, a nie do widoku.

import Foundation

/// Jak blisko ściany jest ten odczyt.
public enum DSPLoadLevel: Sendable, Equatable {
    case safe
    case warning
    case critical

    /// Pomarańczowy: patch przy 90% nie przyjmie już prawie żadnego modułu.
    public static let warningPercent = 90.0

    /// Czerwony. NIE przy 100%, bo setka wypada dokładnie tam, gdzie liczby są najgęstsze.
    ///
    /// Patch zbudowany w prawdziwym edytorze zatrzymuje się tuż POD limitem — jego autor
    /// dokłada moduły, dopóki edytor pozwala (zmierzone: 99,9% mocy, `ZPmem` 128/128).
    /// Próg `>= 100` przepuściłby taki patch jako „pomarańczowy".
    ///
    /// ⚠️ Przekroczyć setkę też można: raport `0x72` mówi, ile patch ŻĄDA, a urządzenie
    /// wgranego patcha pod tym kątem nie sprawdza (2026-09-08: 184,6% `Qmem`). Próg na 98
    /// łapie oba końce, `>= 100` łapałby tylko drugi.
    public static let criticalPercent = 98.0

    /// Próg liczony z liczby, KTÓRĄ WIDAĆ na ekranie, nie z surowej.
    ///
    /// Etykieta zaokrągla (`99,6%` → „100%"), więc kolor musi zaokrąglać tak samo. Inaczej
    /// widać „100%" na pomarańczowo i słusznie się to bierze za usterkę.
    public init(percent: Double) {
        switch percent.rounded() {
        case Self.criticalPercent...: self = .critical
        case Self.warningPercent...: self = .warning
        default: self = .safe
        }
    }
}
