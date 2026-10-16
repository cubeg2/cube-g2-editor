// SlotLayout.swift
// Jak pokazać cztery sloty performance'u — View ▸ Slot Layout.
//
// Pas slotu (`SlotBarView`) jest JEDNYM komponentem; tryb decyduje tylko, ile pasów
// widać i gdzie mieszkają. Slot z focusem (ten, który edytuje Nord — `0x09`) idzie
// zawsze za ostatnim kliknięciem, niezależnie od trybu → [[Docs/ui/slot-layout]].
//
// Trzymane w `UserDefaults` (`@AppStorage` po stronie widoków) — to ustawienie
// programu, nie patcha. Menu View ▸ Slot Layout istniało już raz (do 2026-09-10)
// i zapisywało klucz, którego nikt nie czytał — stąd wróciło dopiero razem z kodem,
// który go czyta.

import Foundation

public enum SlotLayout: String, CaseIterable, Sendable {
    /// Jeden pas u góry — dla slotu z focusem; selektor A–D w pasie.
    case single
    /// Cztery pasy jeden pod drugim, jak w oryginalnym NMG2 Editorze; litera slotu
    /// otwiera każdy rząd.
    case fourRows
    /// Każdy slot w osobnym oknie, spiętym z resztą w zakładki systemu; pas slotu
    /// jedzie razem z oknem, gdy zakładkę odpiąć.
    case windows

    public static let storageKey = "g2_slot_layout"

    /// Układy widoczne w menu. `fourRows` jest ukryty (2026-09-11): dwa pozostałe
    /// na razie wystarczą; kod rzędów zostaje, żeby go kiedyś odsłonić jedną linią.
    public static let menuCases: [SlotLayout] = [.single, .windows]

    /// Układ z `UserDefaults`; wartość ukryta w menu (albo nieznana) → `.single`,
    /// żeby użytkownik nie utknął w trybie, którego nie da się wybrać.
    public static func stored(_ raw: String) -> SlotLayout {
        guard let layout = SlotLayout(rawValue: raw), menuCases.contains(layout) else { return .single }
        return layout
    }

    public var title: String {
        switch self {
        case .single: "Single Bar"
        case .fourRows: "Four Rows"
        case .windows: "Windows"
        }
    }

    /// Klawisz skrótu w menu View (z ⌘⌥, jak szuflady). S — single, F — four rows,
    /// D — detached windows; ⌘⌥W odpada, bo to systemowe „Close All".
    public var shortcutKey: Character {
        switch self {
        case .single: "s"
        case .fourRows: "f"
        case .windows: "d"
        }
    }
}
