// CanvasSelection.swift
// Zaznaczenie modułów jednej kanwy — wyjęte z `PatchCanvasView` na zewnątrz.
//
// Do 2026-09-10 zaznaczenie było `@State` wewnątrz kanwy i nikt poza nią go nie widział.
// Wystarczało to myszy (menu pod prawym przyciskiem siedzi w tym samym widoku), ale nie
// menu głównemu: pozycje Edit ▸ Cut / Copy / Delete / Select All muszą wiedzieć, co jest
// zaznaczone, a menu żyje w `Scene`, nie w kanwie. Stąd zwykły obiekt, którym kanwa
// i menu mogą się podzielić.
//
// Jeden obiekt na kanwę: przy podzielonym oknie (Voice u góry, FX pod spodem) każda
// połowa ma własne zaznaczenie, tak jak własny zoom → [[Docs/ui/top-bar]].

import G2Core
import Observation

@MainActor
@Observable
final class CanvasSelection {
    /// Moduły objęte zaznaczeniem (gumka, ⇧-klik).
    var moduleIDs: Set<Int> = []
    /// Ostatnio kliknięty moduł — rysowany inaczej niż reszta zaznaczenia i cel poleceń,
    /// gdy zaznaczenia nie ma wcale.
    var activeID: Int?

    var isEmpty: Bool {
        moduleIDs.isEmpty && activeID == nil
    }

    /// Moduły, których dotyczy polecenie: całe zaznaczenie, a bez niego sam aktywny.
    var targets: Set<Int> {
        if !moduleIDs.isEmpty { return moduleIDs }
        if let activeID { return [activeID] }
        return []
    }

    func clear() {
        moduleIDs = []
        activeID = nil
    }
}

/// Zaznaczenia obu kanw w jednym pudełku. Menu główne dostaje JEDEN obiekt o stałej
/// tożsamości zamiast świeżej paczki domknięć przy każdym przerysowaniu — inaczej
/// każde drgnięcie gałki przebudowywałoby całe menu.
@MainActor
@Observable
final class CanvasSelectionHub {
    let voice = CanvasSelection()
    let fx = CanvasSelection()

    func selection(for area: PatchArea) -> CanvasSelection {
        area == .voice ? voice : fx
    }
}
