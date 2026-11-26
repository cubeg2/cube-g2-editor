// KeyEventScope.swift
// Odpowiedź na pytanie „czy ten klawisz jest dla nas?" dla monitorów skrótów:
// `belongsToAnotherControl` (strzałki kanwy) i węższe `isTyping` (`EditorKeyboardShortcuts`).
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

    /// Czy w oknie trwa pisanie — kursor stoi w polu albo edytorze tekstu.
    ///
    /// Węższe niż `belongsToAnotherControl`, dla skrótów jednoklawiszowych (1–8, A–D, V…):
    /// lista zaznaczona kliknięciem potrzebuje strzałek, nie cyfr i liter. Gdy zabierała
    /// i je, po wyborze patcha w panelu Patches/Banks wariacje i sloty przestawały reagować
    /// aż do kliknięcia w pole tekstowe (zgłoszenie użytkownika 2026-10-21).
    static func isTyping(in window: NSWindow) -> Bool {
        window.firstResponder is NSText || window.firstResponder is NSTextField
    }

    /// ⌘X, ⌘C, ⌘V i ⌘A przy pisaniu w polu idą wprost do pola: monitor widzi klawisz, zanim
    /// dostaną go niewidoczne przyciski kanwy i menu Edit, które mają te same skróty i
    /// zajmują się modułami, a nie tekstem. Bez tego ⌘V w wyszukiwarce panelu Patches nic
    /// nie wklejało, choć „Paste” z menu pod prawym klawiszem działało (zgłoszenie Kuby
    /// 2026-11-17). `true` = pole przyjęło polecenie, zdarzenie ma zniknąć.
    ///
    /// ⌘Z i ⌘⇧Z działają tak samo: pozycje Undo / Redo w menu cofają patch (nasz stos
    /// w `PatchState`), więc po wklejeniu do pola ⌘Z cofało patch zamiast wklejenia (zgłoszenie
    /// Kuby 2026-11-17). Pole dostaje je tylko wtedy, gdy ma co cofnąć (lub ponowić); inaczej
    /// skrót idzie dalej do patcha, żeby kursor stojący w pustym polu nie zabierał cofania.
    @MainActor
    static func forwardTextEditingShortcut(_ event: NSEvent, in window: NSWindow) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard isTyping(in: window) else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased()
        if key == "z", flags == .command || flags == [.command, .shift] {
            let redo = flags.contains(.shift)
            if let manager = window.firstResponder?.undoManager, !(redo ? manager.canRedo : manager.canUndo) {
                return false
            }
            return NSApp.sendAction(Selector(redo ? "redo:" : "undo:"), to: nil, from: nil)
        }
        guard flags == .command, let selector = textEditingSelector(for: key) else { return false }
        return NSApp.sendAction(selector, to: nil, from: nil)
    }

    /// Polecenie edycji tekstu dla litery skrótu z ⌘; `nil` dla pozostałych liter.
    static func textEditingSelector(for characters: String?) -> Selector? {
        switch characters?.lowercased() {
        case "x": #selector(NSText.cut(_:))
        case "c": #selector(NSText.copy(_:))
        case "v": #selector(NSText.paste(_:))
        case "a": #selector(NSText.selectAll(_:))
        default: nil
        }
    }

    private static func isTextOrList(_ view: NSView) -> Bool {
        view is NSTextView || view is NSTextField || view is NSTableView
    }
}
