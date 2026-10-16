// SlotSelectorView.swift
// Przyciski slotów A–D w pasku narzędzi. Trzy stany i trzy sposoby klikania — dokładnie
// tak, jak opisuje instrukcja oryginału (str. 59, „SLOT BUTTONS") i jak rysuje je Clavia
// (Slot Button (Draw) + TB Window (Setup)) → [[Docs/usb/slots]]:
//
//   • GRA (slot active)      — „If several Slots are active, this is indicated by the
//                              blue Slot buttons" → niebieskie tło
//   • KLAWIATURA (keyboard)  — „All slot buttons that have a red line on top of them
//                              will follow the keyboard" → czerwona kreska NAD przyciskiem
//   • NUTY Z DAW (nasze)     — zielona kreska nad czerwoną, gdy wtyczka DAW gra ten slot
//   • EDYTOWANY (focus)      — „The focused Slot has a white frame around it" → biała ramka
//                              (biała w ciemnym trybie systemu; na jasnej belce narzędzi
//                              biel znika, więc tam ta sama rola przypada czerni)
//
// Klikanie (instrukcja, ten sam akapit):
//   • zwykłe        — daj slotowi focus do edycji; milczący slot — wg Setup ▸ Options
//                     (domyślnie dołącza do grających, oryginał gra nim samym)
//   • SHIFT+klik    — włącz/wyłącz slot (kilka slotów naraz = gra multitimbralnie)
//   • CTRL+klik     — przypisz/odbierz klawiaturę (czerwona kreska)

import AppKit
import G2Core
import G2EditorCore
import SwiftUI

struct SlotSelectorView: View {
    @Bindable var state: PatchState
    let device: DeviceConnection
    /// Które litery pokazać. `nil` = wszystkie sloty dokumentu (jeden pas u góry);
    /// rząd w układzie czterech pasów i okno slotu pokazują tylko własną literę.
    var shown: [Int]?
    @Environment(\.colorScheme) private var colorScheme

    private let labels = ["A", "B", "C", "D"]

    var body: some View {
        HStack(spacing: 4) {
            // `slotCount`, nie `slots`: selektor nie może budzić się od ruchu gałki.
            ForEach(shown ?? Array(0 ..< state.slotCount), id: \.self) { index in
                if index < state.slotCount {
                    slotButton(index)
                }
            }
        }
    }

    private func slotButton(_ index: Int) -> some View {
        let focused = state.selectedSlot == index
        let playing = isPlaying(index)
        let keyboard = keyboardEnabled(index)
        let dawNotes = device.dawNoteSlots.indices.contains(index) && device.dawNoteSlots[index]
        return Button {
            let modifiers = NSEvent.modifierFlags
            if modifiers.contains(.shift) {
                Task { await device.togglePlayingSlot(index) }
            } else if modifiers.contains(.control) {
                Task { await device.toggleKeyboardSlot(index) }
            } else {
                state.focusSlot(index)
            }
        } label: {
            Text(labels[index])
                .font(.system(size: TopBarMetrics.labelSize,
                              weight: focused ? .bold : .medium))
                .frame(width: TopBarMetrics.slotButtonWidth,
                       height: TopBarMetrics.slotButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: TopBarMetrics.cornerRadius)
                        // Grający slot świeci na zielono jak „On" przy Vol (`TopBarButton`
                        // z `tint: .green`) — prośba użytkownika 2026-10-12.
                        .fill(playing ? Color.green.opacity(0.18) : Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TopBarMetrics.cornerRadius)
                        .stroke(focused ? focusFrameColor
                            : (playing ? Color.green : Color.primary.opacity(0.25)),
                            lineWidth: focused ? 1.5 : 1)
                )
                // Kreski wiszą NAD przyciskiem jako nakładka i nie biorą miejsca w układzie:
                // gdy stały w jednym stosie z przyciskiem, środek stosu wypadał na osi pasa,
                // a sam przycisk siedział ~5 pt niżej niż On/Off i Voices (2026-09-27).
                .overlay(alignment: .top) {
                    VStack(spacing: 2) {
                        // Zielona kreska nad czerwoną — nuty z wtyczki DAW właśnie grają ten slot.
                        // Tylko te: nut z klawiatury Norda edytor nie widzi.
                        Capsule()
                            .fill(dawNotes ? Color.green : Color.clear)
                            .frame(width: TopBarMetrics.slotButtonWidth,
                                   height: TopBarMetrics.slotKeyboardBarHeight)
                        // Czerwona kreska NAD przyciskiem — u Clavii dioda klawiatury.
                        // Szerokość bierze z przycisku pod nią: kreska ma go przykrywać co do
                        // punktu, inaczej wygląda jak przypadkowy znaczek obok litery.
                        Capsule()
                            .fill(keyboard ? Color.red : Color.clear)
                            .frame(width: TopBarMetrics.slotButtonWidth,
                                   height: TopBarMetrics.slotKeyboardBarHeight)
                    }
                    .alignmentGuide(.top) { $0[.bottom] + 2 }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(playing ? Color.green : Color.secondary)
        .help(helpText(index, focused: focused, playing: playing, keyboard: keyboard))
    }

    /// Ramka slotu edytowanego. Instrukcja oryginału mówi „white frame", bo panel Clavii
    /// jest zawsze ciemny — u nas belka narzędzi idzie za trybem systemu i na jasnej białą
    /// ramkę widać tyle co nic.
    private var focusFrameColor: Color {
        colorScheme == .dark ? .white : .black
    }

    /// Czy slot brzmi. Podłączony Nord jest źródłem prawdy (nagłówek performance'u);
    /// bez niego zostaje to, co powiedział plik `.prf2`, a przy zwykłym patchu — slot oglądany.
    private func isPlaying(_ index: Int) -> Bool {
        if device.playingSlots.indices.contains(index) {
            return device.playingSlots[index]
        }
        if state.hasPerformanceSettings, state.performance.slots.indices.contains(index) {
            return state.performance.slots[index].enabled
        }
        return index == state.selectedSlot
    }

    private func keyboardEnabled(_ index: Int) -> Bool {
        if device.keyboardSlots.indices.contains(index) {
            return device.keyboardSlots[index]
        }
        return state.hasPerformanceSettings
            && state.performance.slots.indices.contains(index)
            && state.performance.slots[index].keyboard
    }

    private func helpText(_ index: Int, focused: Bool, playing: Bool, keyboard: Bool) -> String {
        var parts = ["Slot \(labels[index])"]
        parts.append(playing ? "playing" : "silent")
        if focused { parts.append("editing") }
        if keyboard { parts.append("keyboard") }
        parts.append("green line: notes from a DAW plugin")
        return parts.joined(separator: " · ")
            + " — shift-click plays or mutes it, control-click assigns the keyboard."
    }
}
