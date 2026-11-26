// ClickThrough.swift
// Pierwsze kliknięcie w oknie edytora działa od razu, także gdy klawiaturę trzymało
// akurat okno panelu (Patch Mutator, Sequence Editor).
//
// macOS traktuje kliknięcie w okno, które nie jest kluczowe, jako „uaktywnij okno” —
// widok dostaje je tylko wtedy, gdy sam o to poprosi (`acceptsFirstMouse`). Kanwa
// SwiftUI nie prosi, więc po kliknięciu w Mutatorze pierwszy klik w przełącznik na
// module tylko przełączał okno, a działał dopiero drugi (zgłoszenie Kuby 2026-11-25).
// Dotyczyło to też gałek, kabli i wszystkiego innego w oknie.
//
// Rozwiązanie: zanim kliknięcie trafi do okna, robimy je kluczowym — AppKit widzi
// wtedy zwykły klik w aktywne okno i przekazuje go dalej. Tylko gdy edytor JEST już
// aktywną aplikacją: kliknięcie z Findera czy przeglądarki dalej tylko przywołuje
// edytor, jak w każdej aplikacji Maca.

import AppKit

@MainActor
enum ClickThrough {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            // Monitor lokalny woła się na głównym wątku, przed wysłaniem zdarzenia do okna.
            MainActor.assumeIsolated { makeKeyBeforeClick(event) }
            return event
        }
    }

    private static func makeKeyBeforeClick(_ event: NSEvent) {
        guard NSApp.isActive, NSApp.modalWindow == nil,
              let window = event.window, window.isVisible, !window.isKeyWindow,
              window.canBecomeKey, window.attachedSheet == nil
        else { return }
        // Panel, który z założenia nie bierze klawiatury (DSP, klawiatura ekranowa…),
        // ma ją zostawić oknu edytora — inaczej wyszarza się połowa menu.
        if let panel = window as? NSPanel, panel.becomesKeyOnlyIfNeeded { return }
        window.makeKey()
    }
}
