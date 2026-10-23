// MorphBarView.swift
// Osiem morfów — ostatni człon pasa slotu (`SlotBarView`), na jego prawym końcu.
// Własnego tła ani odstępów nie ma: dostaje je pas, w którym siedzi.
//
// Oryginał trzyma go w pasku narzędzi (Morph Container w TB Window, tym samym
// oknie co zegar główny): panel 311×55 px, osiem kolumn co 39 px, w każdej nazwa
// morfu u góry, gałka pod nią i przycisk źródła („Knob" albo nazwane źródło,
// przy Sust.Pd trzecia pozycja „G Wh 1"). Odtwarzamy ten układ kolumna w kolumnę.
//
// Jeden morf jest „z focusem" (Patch Manager (SetFocusedMorphGroup)) — to jego
// dotyczy Option-przeciąganie gałki w patchu, którym przypisuje się parametr
// do morfu → [[Docs/ui/morphs]].
//
// Pasek dostaje numer slotu: pas slotu B pokazuje morfy slotu B także wtedy, gdy
// edytowany jest A (View ▸ Slot Layout). Ruch gałki najpierw daje slotowi focus.

import G2Core
import G2EditorCore
import SwiftUI

struct MorphBarView: View {
    let state: PatchState
    let slot: Int

    /// Nagłówek slotu zamiast `state.slots[slot]`: pas czyta tylko gałki, źródła
    /// i przypisania morfów, więc ruch gałki w module go nie budzi (`SlotHeader`).
    private var header: SlotHeader {
        state.header(slot: slot)
    }

    /// Morf, którego nazwa jest właśnie edytowana (podwójny klik, jak u Clavii).
    @State private var renaming: Int?
    @State private var draft = ""
    @FocusState private var nameFieldFocused: Bool

    private func focusing(_ action: () -> Void) {
        state.focusSlot(slot)
        action()
    }

    var body: some View {
        HStack(spacing: 0) {
            // Manual v1.4 nazywa je „Morph groups" — dwuwierszowo, żeby podpis nie
            // zjadał szerokości paska.
            TopBarCaption(text: "Morph", secondLine: "Groups")
                .padding(.trailing, 8)
            // Odstęp między kafelkami — bez niego ramki sąsiadów zlewały się w jedną.
            HStack(spacing: Self.columnSpacing) {
                ForEach(0 ..< G2Morph.count, id: \.self) { morph in
                    morphColumn(morph)
                }
            }
        }
    }

    // MARK: - Kolumna jednego morfu

    /// Kafelek kwadratowy: 2 × 12 pt napisów + `knobRowHeight` + 2 pt = 52 pt
    /// (prośba użytkownika 2026-09-28 — niższy kafelek obniża cały pas).
    private static let columnWidth: CGFloat = 52
    private static let columnSpacing: CGFloat = 4
    /// Wiersz gałki niższy od jej ramki (34 pt): tarcza z kreseczkami zajmuje ~25 pt,
    /// reszta ramki to pusty margines nad i pod nią, który rozpychał kafelek.
    private static let knobRowHeight: CGFloat = 26

    private func morphColumn(_ morph: Int) -> some View {
        let focused = state.focusedMorph == morph
        let assigned = header.morphAssigned[morph]
        // Cała kolumna jest kafelkiem w barwach przycisków belki (`TopBarButton`):
        // szara ramka — morf pusty, niebieska z niebieskim tłem — morf z przypisaniami
        // (jak wybrana wariacja), czerwona — morf z focusem (jak „Off" przy Vol).
        // Zastąpiło to obwódkę wokół gałki, która była za cienka, żeby ją zauważyć
        // (prośba użytkownika 2026-09-27).
        let tint: Color? = focused || assigned ? MorphIndicator.color(focused: focused) : nil
        // Bez odstępów w stosie: napisy przylegają do gałki, żeby większa tarcza
        // nie podnosiła całego pasa.
        return VStack(spacing: 0) {
            // Nazwa morfu i źródło pod gałką chodzą tym samym krojem co podpis
            // „Morph Groups" obok — jeden rozmiar podpisów w całej belce.
            morphName(morph, focused: focused, tint: tint)
            SmallKnob(value: header.morphDials[morph],
                      size: TopBarMetrics.morphKnobSize,
                      onBegin: { focusing { state.beginParameterGesture() } },
                      onChange: { state.setMorphDial(morph, value: $0, slot: slot) },
                      onEnd: { state.endParameterGesture() })
                .help("\(header.morphDials[morph])")
                .frame(height: Self.knobRowHeight)
            sourceMenu(morph)
        }
        .frame(width: Self.columnWidth)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: TopBarMetrics.cornerRadius)
                .fill(tint?.opacity(0.18) ?? Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: TopBarMetrics.cornerRadius)
                .strokeBorder(tint ?? Color.primary.opacity(0.25), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { focusing { state.focusedMorph = morph } }
        .help("Morph \(morph + 1) — \(header.morphNames[morph])")
        .contextMenu { contextMenu(morph) }
    }

    /// Nazwa nad gałką; po podwójnym kliku pole do jej zmiany (7 znaków — tyle mieści Nord).
    /// Enter albo kliknięcie obok zatwierdza, Esc porzuca.
    @ViewBuilder
    private func morphName(_ morph: Int, focused: Bool, tint: Color?) -> some View {
        if renaming == morph {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: TopBarMetrics.captionSize))
                .multilineTextAlignment(.center)
                .frame(height: 12)
                .background(Color.primary.opacity(0.12))
                .focused($nameFieldFocused)
                .onChange(of: draft) { _, text in
                    if text.count > G2MorphLabelSection.nameLength {
                        draft = String(text.prefix(G2MorphLabelSection.nameLength))
                    }
                }
                .onSubmit { commitRename() }
                .onExitCommand { renaming = nil }
                .onChange(of: nameFieldFocused) { _, isFocused in
                    if !isFocused { commitRename() }
                }
        } else {
            Text(header.morphNames[morph])
                .font(.system(size: TopBarMetrics.captionSize, weight: focused ? .bold : .regular))
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .frame(height: 12)
                .onTapGesture(count: 2) { beginRename(morph) }
        }
    }

    private func beginRename(_ morph: Int) {
        state.focusSlot(slot)
        draft = header.morphNames[morph]
        renaming = morph
        nameFieldFocused = true
    }

    private func commitRename() {
        guard let morph = renaming else { return }
        renaming = nil
        state.setMorphName(morph, name: draft, slot: slot)
    }

    /// Przycisk źródła pod gałką — u Clavii Rotate Text Button z tekstem
    /// „Knob,<źródło>": klik przełącza na następną pozycję w kółko.
    private func sourceMenu(_ morph: Int) -> some View {
        let options = G2Morph.sourceOptions(morph: morph)
        let current = min(header.morphModes[morph], options.count - 1)
        return Button {
            focusing { state.setMorphMode(morph, value: (current + 1) % options.count, slot: slot) }
        } label: {
            Text(options[current])
                .font(.system(size: TopBarMetrics.captionSize))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 12)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Morph source: \(options.joined(separator: " / "))")
    }

    /// „Assign ▸ Page A ▸ Column 2" — tak przypina się gałkę morfu do gałki panelu
    /// w oryginale (instrukcja s. 20: „right-click the Morph group knob and select
    /// Assign|Page X|Knob"). Menu ma dokładnie ten kształt co Knob Assign Menu:
    /// pięć liter, w każdej trzy wiersze, zajęte oznaczone „(used)".
    /// Adresem jest obszar ustawień patcha: moduł 1, parametr = numer morfu.
    private func assignMenu(_ morph: Int) -> some View {
        Menu("Assign to Knob") {
            ForEach(0 ..< 5, id: \.self) { letter in
                Menu(pageLabel("Page \(Self.pageLetters[letter])",
                               pages: (letter * 3) ..< (letter * 3 + 3)))
                {
                    ForEach(0 ..< 3, id: \.self) { row in
                        let page = letter * 3 + row
                        Button(pageLabel("Column \(row + 1)", pages: page ..< (page + 1))) {
                            // Przypisanie idzie do slotu z focusem — stąd focus najpierw.
                            focusing {
                                state.assignKnob(toPage: page, location: 2,
                                                 moduleID: Self.morphSettingsModule,
                                                 paramIndex: morph)
                            }
                        }
                    }
                }
            }
        }
    }

    private static let pageLetters = ["A", "B", "C", "D", "E"]
    /// Numer modułu morfów w obszarze ustawień patcha (`PATCH_MORPH`).
    private static let morphSettingsModule = 1

    /// Dopisek „(used)", gdy na którejkolwiek ze wskazanych stron siedzi już przypisanie.
    private func pageLabel(_ text: String, pages: Range<Int>) -> String {
        let used = pages.contains { header.knobPageUsed[$0] }
        return used ? "\(text) (used)" : text
    }

    @ViewBuilder
    private func contextMenu(_ morph: Int) -> some View {
        Button("Rename Morph \(morph + 1)…") { beginRename(morph) }
        Divider()
        assignMenu(morph)
        Divider()
        Button("Clear Morph \(morph + 1)") { focusing { state.clearMorph(morph, slot: slot) } }
        Menu("Clear All Morphs") {
            Button("This Variation") { focusing { state.clearAllMorphs(allVariations: false, slot: slot) } }
            Button("All Variations") { focusing { state.clearAllMorphs(allVariations: true, slot: slot) } }
        }
        Divider()
        Menu("Copy Morph \(morph + 1) To") {
            ForEach(0 ..< G2Morph.count, id: \.self) { target in
                Button("Morph \(target + 1) — \(header.morphNames[target])") {
                    focusing { state.copyMorph(from: morph, to: target, slot: slot) }
                }
                .disabled(target == morph)
            }
        }
    }
}
