// VariationBarView.swift
// Pasek wariacji w górnej belce — dokładnie tam, gdzie ma go oryginał.
//
// Clavia trzyma wariacje w pasku okna patcha (Patch Toolbar): osiem przycisków
// `CTextRadioButton` 15×14 px z etykietami „1,2,3,4,5,6,7,8" i dymkiem „Variation",
// tuż obok `CTextPushButton` „Init" z dymkiem „recall variation init", a pod prawym
// przyciskiem myszy menu „Copy Focused To" (Variation 1…8, kreska, Variation Init).
// Ten plik odtwarza ten układ jeden do jednego → [[Docs/ui/variations]].
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

    private var activeName: String {
        auditioning ? "Mutator" : "Variation \(active + 1)"
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0 ..< 8, id: \.self) { variation in
                    variationButton(variation)
                }
            }
            .topBarCaptionAbove("Variations:")
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
        .contextMenu { copyMenu }
    }

    /// Kwadraty w rozmiarze reszty belki — do 2026-09-10 miały 18 pt i były
    /// najdrobniejszym celem myszy w całym edytorze.
    private func variationButton(_ variation: Int) -> some View {
        TopBarButton(content: .text("\(variation + 1)"),
                     isOn: variation == active)
        {
            focusing { state.selectVariation(variation, slot: slot) }
        }
        .help("Variation \(variation + 1)")
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
