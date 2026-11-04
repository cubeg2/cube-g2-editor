// VariationBarView.swift
// Pasek wariacji w górnej belce — dokładnie tam, gdzie ma go oryginał.
//
// Clavia trzyma wariacje w pasku okna patcha (Patch Toolbar): osiem przycisków
// `CTextRadioButton` 15×14 px z etykietami „1,2,3,4,5,6,7,8" i dymkiem „Variation",
// tuż obok `CTextPushButton` „Init" z dymkiem „recall variation init", a pod prawym
// przyciskiem myszy menu „Copy Focused To" (Variation 1…8, kreska, Variation Init).
// Ten plik odtwarza ten układ jeden do jednego → [[Docs/ui/variations]]. Nasz dodatek:
// Shift-klik (i „Compare … With" w tym samym menu) porównuje wariację z grającą.
//
// Wariacja jest kompletnym zestawem wartości parametrów: przełączenie nie przerywa
// dźwięku, a ta sama gałka pokazuje w każdej z ośmiu co innego — dlatego pasek jest
// widoczny stale, a nie chowa się w oknie, które można zamknąć.
//
// Pasek dostaje numer slotu, bo pas slotu B pokazuje wariacje slotu B także wtedy,
// gdy edytowany jest A (View ▸ Slot Layout). Klik w wariację najpierw daje slotowi
// focus — edytowany slot idzie za ostatnim kliknięciem.

import G2Core
import G2EditorCore
import SwiftUI

struct VariationBarView: View {
    let state: PatchState
    let slot: Int

    private var active: Int {
        state.header(slot: slot).activeVariation
    }

    /// Patch gra z bufora Patch Mutatora — wtedy żaden z ośmiu przycisków nie świeci,
    /// tak samo jak w oryginale („no Patch Variation is selected"). Nazwą w miejscach,
    /// gdzie zwykle stoi numer wariacji, jest wtedy „Mutator". Bufor mutatora
    /// dotyczy wyłącznie slotu z focusem.
    private var auditioning: Bool {
        state.isAuditioningMutation && state.selectedSlot == slot
    }

    private func focusing(_ action: () -> Void) {
        state.focusSlot(slot)
        action()
    }

    /// Slot gra brzmienie spod fadera wariacji (bufor odsłuchu, jak Mutator).
    private var fading: Bool {
        state.activeVariationFader(slot: slot) != nil
    }

    private var activeName: String {
        fading ? "Fader Sound" : auditioning ? "Mutator" : "Variation \(active + 1)"
    }

    var body: some View {
        HStack(spacing: 6) {
            // Przyciski na dawnej wysokości, fader pod nimi jako nakładka — jak podpis nad
            // nimi, nie bierze miejsca w układzie, wchodzi w wolne pole pod przyciskami,
            // które zostawia wysoka gałka Vol (Kuba 2026-11-03: przyciski mają nie skakać).
            HStack(spacing: VariationFaderView.buttonSpacing) {
                ForEach(0 ..< 8, id: \.self) { variation in
                    variationButton(variation)
                }
            }
            .topBarCaptionAbove("Variations:")
            .overlay(alignment: .bottomLeading) {
                VariationFaderView(state: state, slot: slot)
                    .alignmentGuide(.bottom) { $0[.top] - 2 }
            }
            TopBarButton(content: .text("Init")) {
                focusing { state.copyVariation(from: G2Patch.initVariation, to: active, slot: slot) }
            }
            .help("Recall the init values into \(activeName.lowercased())")
            // Z edytora BVerhue (Clavia go nie ma): pomarańczowy, bo zapomniany zmienia
            // po cichu wszystkie osiem wariacji przy każdym ruchu gałki.
            TopBarButton(content: .text("Edit all"), isOn: state.editAllVariationSlots.contains(slot),
                         tint: .orange)
            {
                focusing { state.toggleEditAllVariations(slot: slot) }
            }
            .help("When lit, every knob and button change goes into all eight variations at once")
        }
        // Kopiowanie siedzi pod prawym przyciskiem myszy, tak jak w oryginale — w belce
        // nie ma miejsca na kolejne rozwijane menu, a jest to polecenie rzadkie.
        .contextMenu {
            if fading { storeMenu } else { copyMenu }
            compareMenu
        }
    }

    /// „Zapisz to, co słychać, do wariacji N” — brzmienie znalezione faderem „pomiędzy”.
    private var storeMenu: some View {
        Menu("Store Fader Sound To") {
            ForEach(0 ..< 8, id: \.self) { variation in
                Button("Variation \(variation + 1)") {
                    focusing { state.storeVariationFaderSound(to: variation, slot: slot) }
                }
            }
        }
    }

    /// Kwadraty w rozmiarze reszty belki — do 2026-09-10 miały 18 pt i były
    /// najdrobniejszym celem myszy w całym edytorze.
    /// Shift-klik nie przełącza dźwięku, tylko porównuje wariację z grającą — świeci
    /// wtedy turkusem, tym samym co różnice na kanwie.
    /// W trakcie przejścia fadera świecą dwaj sąsiedzi, każdy na tyle, ile go słychać
    /// (przy 3,5: trójka i czwórka po połowie).
    private func variationButton(_ variation: Int) -> some View {
        let compared = state.comparedVariation(slot: slot) == variation
        let weight = state.variationFaderWeight(of: variation, slot: slot)
        let lit = weight.map { $0 >= 1 } ?? (variation == active)
        return TopBarButton(content: .text("\(variation + 1)"),
                            isOn: lit || compared,
                            tint: compared ? UIColor.variationCompare : .accentColor)
        {
            focusing {
                if NSEvent.modifierFlags.contains(.shift) {
                    state.toggleCompare(with: variation, slot: slot)
                } else {
                    state.selectVariation(variation, slot: slot)
                }
            }
        }
        .overlay {
            if let weight, weight > 0, weight < 1, !compared {
                RoundedRectangle(cornerRadius: TopBarMetrics.cornerRadius)
                    .fill(Color.accentColor.opacity(0.18 * weight))
                    .overlay(RoundedRectangle(cornerRadius: TopBarMetrics.cornerRadius)
                        .strokeBorder(Color.accentColor.opacity(weight), lineWidth: 1))
                    .allowsHitTesting(false)
            }
        }
        .help(compared ? "Variation \(variation + 1) – compared (Shift-click or Esc to stop)"
            : "Variation \(variation + 1) – Shift-click to compare with \(activeName.lowercased())")
    }

    private var compareMenu: some View {
        Menu("Compare \(activeName) With") {
            ForEach(0 ..< 8, id: \.self) { variation in
                Toggle("Variation \(variation + 1)", isOn: Binding(
                    get: { state.comparedVariation(slot: slot) == variation },
                    set: { _ in focusing { state.toggleCompare(with: variation, slot: slot) } }
                ))
                .disabled(variation == active)
            }
        }
    }

    private var copyMenu: some View {
        Menu("Copy \(activeName) To") {
            ForEach(0 ..< 8, id: \.self) { variation in
                Button("Variation \(variation + 1)") {
                    focusing { state.copyVariation(from: active, to: variation, slot: slot) }
                }
                .disabled(variation == active)
            }
            Divider()
            Button("Variation Init") {
                focusing { state.copyVariation(from: active, to: G2Patch.initVariation, slot: slot) }
            }
        }
    }
}
