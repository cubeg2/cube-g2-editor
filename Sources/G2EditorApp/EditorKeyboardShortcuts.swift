// EditorKeyboardShortcuts.swift
// Keys that work on the patch: slots, variations, areas, the clock, the overlays. Which
// key does what comes from `ShortcutStore` (defaults: the table on page 132 of the
// manual); Esc is fixed.
//
// Why an AppKit monitor and not SwiftUI's `keyboardShortcut`: a plain letter as a menu
// shortcut **comes before the text field** — with „V” assigned, no „v” could be typed into
// a patch name. The monitor checks the window's first responder and passes the event on,
// untouched, while text is being edited.

import AppKit
import G2Core
import G2EditorCore
import SwiftUI

struct EditorKeyboardShortcuts: NSViewRepresentable {
    let state: PatchState
    let viewState: CanvasViewState
    let device: DeviceConnection
    /// Zaznaczenia kanw — Esc odkłada w nich czekające wklejenie.
    var selections: CanvasSelectionHub?

    func makeNSView(context _: Context) -> SingleKeyMonitorNSView {
        let view = SingleKeyMonitorNSView()
        view.handler = handle
        return view
    }

    func updateNSView(_ view: SingleKeyMonitorNSView, context _: Context) {
        view.handler = handle
    }

    /// `true` = handled, the event goes no further.
    @MainActor
    private func handle(_ stroke: KeyStroke) -> Bool {
        // Esc ends the variation comparison (Shift-click on the variation bar) and the
        // changes the variation fader left on the canvas; otherwise it is left to others.
        if stroke.key == "escape" {
            guard stroke.modifiers.isDisjoint(with: [.command, .option, .control]) else { return false }
            // A paste waiting for its click (⌘V) — Esc drops it.
            if let selections, let waiting = [selections.voice, selections.fx].first(where: { $0.pendingPaste != nil }) {
                waiting.pendingPaste = nil
                return true
            }
            return state.endCanvasComparison(slot: state.selectedSlot)
        }
        guard let command = ShortcutStore.shared.command(for: stroke, in: .patch) else { return false }
        return perform(command)
    }

    @MainActor
    private func perform(_ command: ShortcutCommand) -> Bool {
        if let variation = ShortcutCommand.variations.firstIndex(of: command) {
            state.selectVariation(variation)
            return true
        }
        if let slot = ShortcutCommand.slots.firstIndex(of: command) {
            // The manual: „Select Slot A (if Slot is Active)”.
            guard state.slots.indices.contains(slot) else { return false }
            state.selectedSlot = slot
            return true
        }
        if let mode = CanvasOverlayMode.allCases.first(where: { ShortcutCommand.overlay($0) == command }) {
            viewState.toggleOverlay(mode)
            return true
        }
        switch command {
        // „View Voice Area” / „View FX Area” — one area on the whole screen; the split
        // view has its buttons in the top bar.
        case ShortcutCommand.viewVoice: viewState.showOnly(.voice)
        case ShortcutCommand.viewFX: viewState.showOnly(.fx)
        case ShortcutCommand.masterClock: MasterClockView.toggleRun(state: state, device: device)
        // The manual has Ctrl+Space for „Shake Cables”, but Space over the canvas moves
        // the view here, so the default is „S”.
        case ShortcutCommand.shakeCables: viewState.shakeCables()
        default: return false
        }
        return true
    }
}

/// Monitor `keyDown` dla całego okna. Sam niczego nie rysuje i nie łapie myszy.
final class SingleKeyMonitorNSView: NSView {
    var handler: ((KeyStroke) -> Bool)?

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
        // ⌘X/C/V/A przy pisaniu w polu: tekst, nie moduły kanwy (wyszukiwarka panelu Patches).
        if KeyEventScope.forwardTextEditingShortcut(event, in: window) { return nil }
        // Caps Lock włączony = litery grają nuty (`MusicalTyping`); „A” nie ma wtedy
        // wybierać slotu A. Kolejność monitorów nie jest gwarantowana, więc ustępujemy sami.
        if event.modifierFlags.contains(.capsLock),
           event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
           MusicalTyping.claims(keyCode: event.keyCode)
        {
            return event
        }
        // Pisanie w polu ma pierwszeństwo; zaznaczona lista już nie — patrz `KeyEventScope.isTyping`.
        if KeyEventScope.isTyping(in: window) { return event }
        guard let stroke = KeyStroke(event: event) else { return event }
        return handler?(stroke) == true ? nil : event
    }
}
