// SlotBarView.swift
// Jeden pas ustawień slotu — wszystko, co dotyczy JEDNEGO patcha, w jednym rzędzie.
//
// Oryginalny NMG2 Editor trzyma te kontrolki razem: litera slotu, nazwa patcha, osiem
// wariacji, Vol, On/Off, Voices, osiem morfów. U nas były rozbite na trzy rzędy górnej
// belki i przemieszane z ustawieniami całej aplikacji (szuflady, połączenie z Nordem,
// zegar, zoom) — ten plik składa je z powrotem w jedno.
//
// Kolejność członów jest wyborem użytkownika (2026-09-10) i różni się od oryginału:
//
//   Init 1/2 │ Patch: nazwa, kategoria │ Sloty A–D │ Vol, On/Off, Voices │ Wariacje │ Morfy
//
// Szablony Init idą pierwsze, bo zaczynają pracę nad brzmieniem; morfy ostatnie, bo są
// najszersze i mają dojeżdżać do prawej krawędzi.
//
// Pas ZAWIJA SIĘ: gdy okno jest za wąskie, grupa, która się nie mieści, przechodzi
// w całości do rzędu niżej (TopBar 2A) → `TopBarFlowLayout`.
//
// Pas jest JEDNYM komponentem dla trzech układów (View ▸ Slot Layout, `SlotLayout`):
// jeden pas dla slotu z focusem, cztery rzędy po jednym na slot, albo pas w oknie
// slotu. Pas dostaje numer slotu i czyta WYŁĄCZNIE nagłówek swojego slotu — nigdy
// `state.patch`, bo ten pokazuje slot z focusem, a pas B ma pokazywać B także wtedy,
// gdy edytowany jest A. Każda akcja w pasie najpierw przenosi focus na swój slot
// (`focusSlot`): slot edytowany dla Norda idzie za ostatnim kliknięciem
// → [[Docs/ui/slot-layout]].
//
// Kategoria i Init 1/2 zostają w pasie na życzenie użytkownika, choć oryginał ich tu
// nie ma — stąd pas jest o jakieś 120 pt szerszy niż pierwowzór.

import G2Core
import G2EditorCore
import SwiftUI

struct SlotBarView: View {
    @Bindable var state: PatchState
    let device: DeviceConnection
    /// Slot, o którym mówi ten pas. W układzie jednego pasa to slot z focusem,
    /// w czterech rzędach i w oknach — stały numer rzędu albo okna.
    let slot: Int
    /// Układ, w którym pas siedzi. Decyduje tylko o selektorze: jeden pas pokazuje
    /// wszystkie litery A–D (to jedyne miejsce zmiany slotu), zakładka samą własną
    /// literę w tym samym miejscu, a cztery rzędy własną literę na początku rzędu —
    /// jak w oryginalnym NMG2 Editorze.
    var layout: SlotLayout = .single

    /// Nazwa jest edytowana lokalnie: Enter zatwierdza, Esc wychodzi bez zmiany —
    /// dokładnie tak opisuje to instrukcja („Press Enter … To exit without changing
    /// the name, press Esc").
    @State private var editedName: String = ""
    @FocusState private var nameFocused: Bool
    /// Tryb głosów w trakcie przeciągania okienka Voices — `nil`, gdy mysz puszczona.
    @State private var draggedVoiceMode: Int?

    /// Nagłówek patcha tego pasa — celowo NIE `state.slots[slot]`: pas czyta tylko
    /// to, co pokazuje, więc ruch gałki w module go nie budzi (patrz `SlotHeader`).
    private var header: SlotHeader {
        state.header(slot: slot)
    }

    private var isFocused: Bool {
        state.selectedSlot == slot
    }

    var body: some View {
        TopBarFlowLayout(spacing: 12) {
            // Litera slotu otwiera rząd, gdy pasy stoją jeden pod drugim — inaczej nie
            // wiadomo, który rząd to który.
            if layout == .fourRows {
                SlotSelectorView(state: state, device: device, shown: [slot])
                topBarFlowDivider()
            }

            initButtons

            topBarFlowDivider()

            // Nazwa i kategoria to jedna grupa — przy zawijaniu pasa mają zostać razem.
            HStack(spacing: 12) {
                nameField
                categoryPicker
            }

            // W trybie jednego pasa selektor musi zostać: to jedyny sposób na zmianę
            // slotu. W zakładce stoi tu sama własna litera — w tym samym miejscu co A–D
            // w jednym pasie (życzenie użytkownika 2026-09-24), nie na początku rzędu.
            // Sloty A–D są zawsze, jak na pasku Clavii (życzenie użytkownika 2026-09-25).
            if layout != .fourRows {
                topBarFlowDivider()
                SlotSelectorView(state: state, device: device,
                                 shown: layout == .windows ? [slot] : nil)
            }

            topBarFlowDivider()

            HStack(spacing: 12) {
                patchLevel
                voiceMode
            }

            topBarFlowDivider()

            VariationBarView(state: state, slot: slot)

            topBarFlowDivider()

            MorphBarView(state: state, slot: slot)
        }
        .padding(.horizontal, 12)
        // Tyle samo co pas globalny — wysokość ma dawać treść, nie odstępy.
        .padding(.vertical, 3)
        .background(background)
        .onAppear { editedName = header.name }
        // Po przełączeniu slotu albo wczytaniu innego pliku w polu ma stać nowa nazwa.
        .onChange(of: header.name) { _, new in
            guard !nameFocused else { return }
            editedName = new
        }
        .onChange(of: slot) { _, _ in editedName = header.name }
    }

    /// Przy kilku pasach naraz rząd z focusem jest podświetlony — sama ramka na
    /// literze ginie wśród czterech rzędów kontrolek. Jeden pas tła nie potrzebuje.
    private var background: some View {
        Rectangle().fill(layout == .fourRows && isFocused
            ? AnyShapeStyle(Color.accentColor.opacity(0.12))
            : AnyShapeStyle(.quaternary.opacity(0.25)))
    }

    /// Każda akcja w pasie najpierw przenosi focus na swój slot — slot edytowany
    /// dla Norda idzie za ostatnim kliknięciem, także gdy kliknięto gałkę, nie literę.
    private func focusing(_ action: () -> Void) {
        state.focusSlot(slot)
        action()
    }

    // MARK: - Patch name

    private var nameField: some View {
        TextField("Name", text: $editedName)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: TopBarMetrics.labelSize))
            .frame(width: 130)
            .focused($nameFocused)
            .onSubmit { commitName() }
            .onExitCommand {
                editedName = header.name
                nameFocused = false
            }
            .onChange(of: nameFocused) { _, focused in
                // Klik w pole to też klik w slot. Klik poza polem działa jak
                // Enter — inaczej wpisana nazwa po cichu przepadała.
                if focused { state.focusSlot(slot) } else { commitName() }
            }
            .onChange(of: editedName) { _, new in
                let clean = G2PatchName.sanitized(new)
                if clean != new { editedName = clean }
            }
            .help("Patch name — up to \(G2PatchName.maxLength) characters")
            .topBarCaptionAbove("Patch:")
    }

    private func commitName() {
        state.setPatchName(editedName, slot: slot)
        editedName = header.name
    }

    // MARK: - Category

    private var categoryPicker: some View {
        Picker("Category", selection: Binding(
            get: { min(header.category, G2PatchCategory.names.count - 1) },
            set: { category in focusing { state.setCategory(category, slot: slot) } }
        )) {
            ForEach(G2PatchCategory.names.indices, id: \.self) { index in
                Text(G2PatchCategory.names[index]).tag(index)
            }
        }
        .labelsHidden()
        .frame(width: 110)
        .font(.system(size: TopBarMetrics.labelSize))
        .help("Sound category — how the patch is filed in the synth's memory")
    }

    // MARK: - Voice mode

    /// Okienko z trybem głosów i para strzałek, jak w oryginale. Jedna liczba niesie
    /// oba pola nagłówka — patrz `G2VoiceMode`.
    private var voiceMode: some View {
        let index = header.voiceModeIndex
        return HStack(spacing: 5) {
            // W trakcie przeciągania zmienia się tylko napis; do patcha (i Norda) idzie
            // jedna zmiana po puszczeniu — jeden krok Undo zamiast kilkunastu.
            TopBarValueField(text: G2VoiceMode.label(index: draggedVoiceMode ?? index), width: 56)
                .topBarDragAdjust(value: draggedVoiceMode ?? index,
                                  range: G2VoiceMode.minIndex ... G2VoiceMode.maxIndex,
                                  pointsPerStep: 6,
                                  onChange: { draggedVoiceMode = $0 },
                                  onEnd: {
                                      if let target = draggedVoiceMode {
                                          focusing { state.setVoiceMode(index: target, slot: slot) }
                                      }
                                      draggedVoiceMode = nil
                                  })
                .topBarCaptionAbove("Voices:")
            TopBarStepper(
                canIncrement: index < G2VoiceMode.maxIndex,
                canDecrement: index > G2VoiceMode.minIndex,
                onIncrement: { focusing { state.setVoiceMode(index: index + 1, slot: slot) } },
                onDecrement: { focusing { state.setVoiceMode(index: index - 1, slot: slot) } }
            )
        }
        .help("Voice mode — Legato, Mono, or the number of voices")
    }

    // MARK: - Init 1 / Init 2

    /// „Click on the Init 1 or Init 2 buttons to recall one of the two Init Patches"
    /// (instrukcja, str. 60). Szablon zapisuje się z menu File → Save Init Patch;
    /// dopóki go nie ma, przycisk jest wyszarzony. Szablon wchodzi do slotu Z FOCUSEM,
    /// więc przycisk najpierw daje focus swojemu — i jedzie do Norda jak Open To
    /// (do 2026-09-25 zostawał tylko na ekranie).
    ///
    /// Niezapisana praca ginęła tu bez słowa, więc Init pyta tak samo jak „Open To"
    /// — z własnym przełącznikiem w Settings. Anulowane pytanie nie rusza nawet focusu.
    private var initButtons: some View {
        HStack(spacing: 3) {
            ForEach(InitPatchLibrary.slots, id: \.self) { template in
                let saved = InitPatchLibrary.exists(template)
                TopBarButton(content: .text("Init \(template)"), isEnabled: saved) {
                    guard UnsavedChangesGuard.shared.confirmDiscard(initPatchInto: slot) else { return }
                    focusing { state.recallInitPatch(slot: template) }
                    guard state.errorMessage == nil else { return }
                    Task { await device.send(state, onlyFocusedSlot: true) }
                }
                .help(saved
                    ? "Recall init patch \(template) into this slot"
                    : "No init patch \(template) saved yet — File ▸ Save Init Patch")
            }
        }
    }

    // MARK: - Patch level

    /// Gałka poziomu i przycisk On/Off. Oba pola siedzą w ustawieniach patcha
    /// (`patchVolume` i `activeMuted`), więc idą tą samą drogą co suwaki arkusza
    /// Patch Settings — z cofaniem i wysyłką do Norda.
    private var patchLevel: some View {
        // `activeMuted` = 1 znaczy „gra" (BVerhue `VolMute: Off;On`), więc wyciszony to 0.
        let muted = header.activeMuted == 0
        let volume = header.patchVolume
        return HStack(spacing: 5) {
            // Ta sama gałka co osiem gałek morfów, dwa razy większa i z wieńcem 16 diod
            // zamiast obwódki (próba wyglądu, prośba użytkownika 2026-09-25).
            SmallKnob(value: volume,
                      size: TopBarMetrics.volumeKnobSize,
                      ledCount: TopBarMetrics.volumeKnobLeds,
                      onBegin: { focusing { state.beginParameterGesture() } },
                      onChange: { state.setPatchSetting(.patchVolume, value: $0, slot: slot) },
                      onEnd: { state.endParameterGesture() })
                .help("Patch level (\(volume)) — MIDI CC #7")
            // Grający patch świeci na zielono jak `Run`, wyciszony na czerwono. Oba stany
            // są zapalone: wyciszenie to nie „nic", tylko stan, który ma rzucać się w oczy.
            // Pełna wysokość belki, jak okienko Voices i sloty A–D (prośba użytkownika
            // 2026-09-27) — niski przycisk wyglądał obok nich na zgubiony.
            TopBarButton(content: .text(muted ? "Off" : "On"),
                         isOn: true,
                         tint: muted ? .red : .green,
                         fixedWidth: 36)
            {
                focusing { state.setPatchSetting(.activeMuted, value: muted ? 1 : 0, slot: slot) }
            }
            .help(muted ? "Patch output is muted" : "Mute the patch output")
            .topBarCaptionAbove("Vol:")
        }
    }
}
