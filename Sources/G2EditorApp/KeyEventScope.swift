// KeyEventScope.swift
// Jedna odpowiedź na pytanie „czy ten klawisz jest dla nas?", wspólna dla obu
// monitorów skrótów (`EditorKeyboardShortcuts`, `PatchCanvasView+KeyNavigation`).
//
// Monitory `NSEvent.addLocalMonitorForEvents` widzą KAŻDY klawisz w oknie, także
// wpisywany do pola tekstowego i wciskany w liście, która sama nawiguje strzałkami
// (panel Patches). Skrót ma działać nad patchem, a nie zamiast pisania i przewijania.

import AppKit

enum KeyEventScope {
    /// Czy klawisz należy do czegoś, co ma pierwszeństwo przed skrótami patcha.
    ///
    /// Dwa przypadki i oba są konkretne:
    /// • **edytor tekstu** — pole nazwy patcha, nazwy modułu, notatki. Bez tego
    ///   litera „v" wybierałaby obszar Voice zamiast się wpisać.
    /// • **lista** — panel Patches wybiera pozycje strzałkami; strzałka ma tam
    ///   przewijać listę, a nie dostrajać parametr na kanwie.
    static func belongsToAnotherControl(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if responder is NSText { return true }
        guard let view = responder as? NSView else { return false }
        return isTextOrList(view) || view.enclosingScrollView.map { scroll in
            scroll.documentView.map(isTextOrList) ?? false
        } ?? false
    }

    private static func isTextOrList(_ view: NSView) -> Bool {
        view is NSTextView || view is NSTextField || view is NSTableView
    }
}
