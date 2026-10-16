// EditorKeyboardShortcuts.swift
// Skróty jednoklawiszowe z tabeli na str. 132 instrukcji Clavii:
//
//   1…8   wybór wariacji            A/B/C/D  wybór slotu
//   V     obszar Voice              F        obszar FX
//   R     start/stop zegara         F5…F8    żółte dymki nad kontrolkami
//
// Dlaczego monitor AppKit, a nie `keyboardShortcut` SwiftUI: gołe litery jako skróty
// menu **wyprzedzają pole tekstowe** — z włączonym „V" nie dałoby się wpisać litery
// „v" w nazwie patcha. Monitor sprawdza pierwszego respondera okna i przy aktywnym
// edytorze tekstu przepuszcza zdarzenie dalej, nietknięte.

import AppKit
import G2Core
import G2EditorCore
import SwiftUI

struct EditorKeyboardShortcuts: NSViewRepresentable {
    let state: PatchState
    let viewState: CanvasViewState
    let device: DeviceConnection

    func makeNSView(context _: Context) -> SingleKeyMonitorNSView {
        let view = SingleKeyMonitorNSView()
        view.handler = handle
        return view
    }

    func updateNSView(_ view: SingleKeyMonitorNSView, context _: Context) {
        view.handler = handle
    }

    /// `true` = skrót obsłużony, zdarzenie znika.
    @MainActor
    private func handle(_ characters: String, _ keyCode: UInt16) -> Bool {
        // Klawisze funkcyjne przychodzą jako znaki z prywatnego obszaru Unicode.
        if let overlay = Self.overlayModes[keyCode] {
            viewState.toggleOverlay(overlay)
            return true
        }

        switch characters {
        case "1", "2", "3", "4", "5", "6", "7", "8":
            guard let digit = Int(characters) else { return false }
            state.selectVariation(digit - 1)
            return true

        case "a", "b", "c", "d":
            // Instrukcja: „Select Slot A (if Slot is Active)".
            guard let slot = Self.slotKeys.firstIndex(of: characters),
                  state.slots.indices.contains(slot) else { return false }
            state.selectedSlot = slot
            return true

        // Instrukcja: „View Voice Area" / „View FX Area" — jeden obszar na cały
        // ekran. Podział okna na dwie części robi się przyciskami w belce.
        case "v":
            viewState.showOnly(.voice)
            return true

        case "f":
            viewState.showOnly(.fx)
            return true

        case "r":
            MasterClockView.toggleRun(state: state, device: device)
            return true

        case "s":
            // Instrukcja ma tu Ctrl+Spację („Shake Cables"), ale spacja nad kanwą jest
            // u nas rączką do przesuwania widoku, więc rozsypanie kabli siedzi pod „S".
            viewState.shakeCables()
            return true

        default:
            return false
        }
    }

    private static let slotKeys = ["a", "b", "c", "d"]

    /// Kody klawiszy F5–F8 na klawiaturze Apple.
    private static let overlayModes: [UInt16: CanvasOverlayMode] = [
        96: .values, // F5
        97: .morphGroups, // F6
        98: .knobAssignments, // F7
        100: .midiControllers, // F8
    ]
}

/// Monitor `keyDown` dla całego okna. Sam niczego nie rysuje i nie łapie myszy.
final class SingleKeyMonitorNSView: NSView {
    var handler: ((String, UInt16) -> Bool)?

    private var monitor: Any?

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        } else if window == nil {
            removeMonitor()
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, window.isKeyWindow, event.window === window else { return event }
        // Żaden modyfikator: ⌘V to wklejenie, a nie „pokaż obszar Voice".
        // Shift przepuszczamy — na klawiaturze bez klawisza Fn bywa częścią F5…F8.
        guard event.modifierFlags.isDisjoint(with: [.command, .option, .control])
        else { return event }
        // Caps Lock włączony = litery grają nuty (`MusicalTyping`); „A” nie ma wtedy
        // wybierać slotu A. Kolejność monitorów nie jest gwarantowana, więc ustępujemy sami.
        if event.modifierFlags.contains(.capsLock), MusicalTyping.claims(keyCode: event.keyCode) {
            return event
        }
        // Pisanie w polu i nawigacja po liście mają pierwszeństwo — patrz `KeyEventScope`.
        if KeyEventScope.belongsToAnotherControl(in: window) { return event }
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else { return event }
        return handler?(characters, event.keyCode) == true ? nil : event
    }
}
