import AppKit
import G2Core
import G2EditorCore
import SwiftUI

struct RootView: View {
    /// Startuje od pustego dokumentu, nie od ekranu powitalnego — patrz `startEmpty`.
    @State private var state: PatchState = {
        let state = PatchState()
        state.startEmpty()
        return state
    }()

    @State private var viewState = CanvasViewState()
    @State private var zoomPanController = CanvasZoomPanController()
    /// Zaznaczenie modułów obu kanw — czyta je menu Edit (patrz `CanvasSelectionHub`).
    @State private var selections = CanvasSelectionHub()
    @State private var showFileImporter = false
    /// Slot, do którego ma trafić otwierany plik („Open To ▸" w menu File). `nil` = zwykłe
    /// Open, czyli plik zastępuje cały dokument.
    @State private var openIntoSlot: Int?
    @State private var device = DeviceConnection()
    /// Panele boczne — jeden system dla wszystkich (patrz `PanelController`).
    @State private var panels = PanelController()
    /// Folder z patchami pokazywany w panelu Banks — niezależny od podłączonego Norda.
    @State private var library = DiskBankLibrary()
    /// Caps Lock → litery grają nuty na Nordzie, także przy zamkniętym oknie klawiatury.
    @State private var typing = MusicalTyping()
    /// Układ slotów — okna slotów (`SlotWindows`) trzeba otwierać i zamykać stąd,
    /// bo tylko tu jest komplet stanu, który dostają.
    @AppStorage(SlotLayout.storageKey) private var slotLayoutRaw = SlotLayout.single.rawValue

    private var slotLayout: SlotLayout {
        SlotLayout.stored(slotLayoutRaw)
    }

    var body: some View {
        ContentView(
            state: state,
            viewState: viewState,
            zoomPanController: zoomPanController,
            selections: selections,
            device: device,
            panels: panels,
            library: library,
            typing: typing,
            fileOpenRequest: $showFileImporter
        )
        // Systemowy pas zakładek okien zdejmujemy z samego okna — sama flaga klasy
        // `NSWindow` nie wystarczyła. Ten sam widok rejestruje okno główne dla okien slotów.
        .background(EditorWindowSetup().frame(width: 0, height: 0))
        // Most PatchState ↔ USB. Kierunek „w dół" (edycja i undo/redo) idzie dwiema
        // ścieżkami: `onLiveParameterChange` dla wartości i `onLiveStructureChange` dla
        // modułów i kabli; kierunek „w górę" to powiadomienia, które Nord nadaje sam
        // z siebie — ruch gałki na froncie, przełączenie slotu i wariacji.
        .task {
            UnsavedChangesGuard.shared.state = state
            PluginHost.bridge.state = state
            PluginHost.bridge.device = device
            state.onLiveParameterChange = { [device] slot, area, moduleID, paramIndex, value, variation in
                device.sendParameterLive(slot: slot, area: area, moduleID: moduleID,
                                         paramIndex: paramIndex, value: value, variation: variation)
            }
            state.onLiveParameterBatch = { [device] slot, changes, variation in
                device.sendParametersLive(slot: slot, changes: changes, variation: variation)
            }
            state.onLiveStructureChange = { [device] slot, patch in
                device.syncStructure(slot: slot, patch: patch)
            }
            state.onMutatorAudition = { [device] slot, patch, variation in
                device.sendMutatorAudition(slot: slot, patch: patch, variation: variation)
            }
            state.onVariationDump = { [device] slot, patch, variations in
                device.sendVariationDump(slot: slot, patch: patch, variations: variations)
            }
            state.onVariationChange = { [device] slot, variation in
                device.sendVariation(slot: slot, variation: variation)
            }
            state.onVariationCopy = { [device] slot, from, to in
                device.sendVariationCopy(slot: slot, from: from, to: to)
            }
            // ⌘Z po New / Init / kopii wariacji: slot wraca w całości (focus już na nim).
            state.onSlotRestore = { [device, weak state] _ in
                guard let state else { return }
                Task { await device.send(state, onlyFocusedSlot: true) }
            }
            state.onMorphRangeChange = { [device] slot, location, moduleID, paramIndex, morph, range, variation in
                device.sendMorphRange(slot: slot, location: location, moduleID: moduleID,
                                      paramIndex: paramIndex, morph: morph,
                                      range: range, variation: variation)
            }
            state.onKnobAssignmentChange = { [device] slot, knob, assignment in
                device.sendKnobAssignment(slot: slot, knob: knob, assignment: assignment)
            }
            state.onMidiControllerAssignmentChange = { [device] slot, cc, assignment in
                device.sendMidiControllerAssignment(slot: slot, cc: cc, assignment: assignment)
            }
            state.onParameterPageChange = { [device] slot, page, global in
                device.sendParameterPage(slot: slot, page: page, global: global)
            }
            state.onGlobalParameterPagesChange = { [device] enabled in
                device.sendGlobalPages(enabled)
            }
            state.onPatchDescriptionChange = { [device] slot, description in
                device.sendPatchDescription(slot: slot, description: description)
            }
            state.onPatchSettingChange = { [device] slot, moduleID, paramIndex, value, variation in
                device.sendPatchSetting(slot: slot, moduleID: moduleID,
                                        paramIndex: paramIndex, value: value, variation: variation)
            }
            device.onPatchesDownloaded = { [state, device] patches in
                // Nazwę bierzemy z nagłówka, który `connect` przeczytał chwilę wcześniej —
                // na ekranie stoi zawartość Norda, więc i nazwa ma być jego.
                state.loadFromDevice(patches: patches,
                                     performanceName: device.devicePerformanceName ?? "",
                                     performance: device.devicePerformance)
            }
            device.onDeviceParameterChange = { [state] slot, area, moduleID, paramIndex, value, variation in
                state.applyDeviceParameter(slot: slot, area: area, moduleID: moduleID,
                                           paramIndex: paramIndex, value: value, variation: variation)
            }
            device.onDeviceSettingChange = { [state] slot, moduleID, paramIndex, value, variation in
                state.applyDeviceSetting(slot: slot, moduleID: moduleID, paramIndex: paramIndex,
                                         value: value, variation: variation)
            }
            device.onDeviceSlotChange = { [state] slot in
                guard state.slots.indices.contains(slot) else { return }
                state.selectedSlot = slot
            }
            device.onDeviceVariationChange = { [state] slot, variation in
                state.applyDeviceVariation(slot: slot, variation: variation)
            }
            device.onDeviceParameterPageChange = { [state] slot, page, global in
                state.applyDeviceParameterPage(page, slot: slot, global: global)
            }
            device.onDeviceGlobalPagesChange = { [state] enabled in
                state.applyDeviceGlobalParameterPages(enabled)
            }
            device.onDevicePatchReloaded = { [state] slot, patch in
                state.replaceSlotFromDevice(slot: slot, patch: patch)
            }
            device.onDevicePatchesReloaded = { [state, device] patches in
                state.replaceSlotsFromDevice(patches: patches,
                                             performanceName: device.devicePerformanceName ?? "",
                                             performance: device.devicePerformance)
            }
            device.patchForSlot = { [state] slot in
                state.slots.indices.contains(slot) ? state.slots[slot] : nil
            }
            // Plik otwarty przy odłączonym Nordzie ma pierwszeństwo — samo podłączenie
            // kabla nie może skasować czyjejś pracy. Gdy jednak plik już poleciał do
            // urządzenia (a otwarcie wgrywa go od razu), ekran i Nord pokazują to samo
            // i zmiana na jego froncie ma prawo przejąć widok.
            device.mayReplaceEditorContent = { [state] in !state.isLoaded || state.mayBeReplacedByDevice }
            device.onEditorContentAtConnect = { [state, device] virtualDevice in
                await EditorContentAtConnect.resolve(state: state, device: device, virtualDevice: virtualDevice)
            }
            device.onDeviceLost = { [state] in state.deviceLost() }
            device.startAutoConnect()
            VirtualDeviceLauncher.shared.watch(device)
            typing.start(device: device)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            // Cel zdejmujemy zawsze — także po anulowaniu okna, żeby kolejne zwykłe Open
            // nie poleciało do slotu wybranego przed chwilą.
            let targetSlot = openIntoSlot
            openIntoSlot = nil
            guard case let .success(urls) = result, let url = urls.first else { return }
            let guardian = UnsavedChangesGuard.shared
            guard targetSlot.map(guardian.confirmDiscard(slot:)) ?? guardian.confirmDiscard(opening: url)
            else { return }
            if let targetSlot {
                // „Open To ▸ Slot X": zmienia się jeden slot, więc tylko on jedzie do Norda —
                // trzy pozostałe grają dalej, tak jak przy New Patch.
                state.load(url: url, intoSlot: targetSlot)
                guard state.errorMessage == nil else { return }
                Task { await device.send(state, onlyFocusedSlot: true) }
                return
            }
            let ext = url.pathExtension.lowercased()
            guard ext == "pch2" || ext == "prf2" else {
                state.errorMessage = "Please open a .pch2 or .prf2 file.\nSelected: \(url.lastPathComponent)"
                return
            }
            let onlySlot = state.load(url: url)
            // Otwarty plik ma wylądować także w Nordzie — jego slot jest buforem roboczym
            // edytora, tak jak w oryginale Clavii. Bez podłączonego G2 `send` cicho odmawia.
            guard state.errorMessage == nil else { return }
            Task { await device.send(state, onlyFocusedSlot: onlySlot, followDocument: true) }
        }
        .alert("Parse Error", isPresented: .init(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
        // Wystaw state + binding do menu commands (MainMenu.swift).
        .focusedSceneValue(\.patchState, state)
        .focusedSceneValue(\.canvasViewState, viewState)
        .focusedSceneValue(\.canvasSelections, selections)
        .focusedSceneValue(\.fileOpenRequest, $showFileImporter)
        .focusedSceneValue(\.openIntoSlotRequest, $openIntoSlot)
        .focusedSceneValue(\.deviceConnection, device)
        .focusedSceneValue(\.panelController, panels)
        // Bez tego zmiany na żywo dalej leciałyby do slotu sprzed przełączenia A/B/C/D.
        // Siedzi tu, nie w `ContentView`: przy slotach w oknach jest kilka `ContentView`
        // naraz, a komenda do Norda ma pójść raz. W układzie okien zmiana focusu
        // (Nord, menu File ▸ New To) wysuwa też zakładkę tego slotu.
        .onChange(of: state.selectedSlot) { _, newSlot in
            Task { await device.selectTargetSlot(newSlot) }
            SlotWindows.shared.reveal(slot: newSlot)
        }
        // Okna slotów żyją poza drzewem SwiftUI, tak jak pływające panele — otwiera
        // i zamyka je jedno miejsce, przy każdej zmianie tego, od czego zależą.
        .onChange(of: slotLayoutRaw) { _, _ in syncSlotWindows() }
        // `slotCount`, nie `slots.count`: odczyt `slots` w tym `body` budziłby cały
        // widok przy każdym ruchu gałki (patrz `PatchBoundViews.swift`).
        .onChange(of: state.slotCount) { _, _ in syncSlotWindows() }
        .onChange(of: state.isLoaded) { _, _ in syncSlotWindows() }
        // Pływające okna paneli żyją poza drzewem SwiftUI, więc ktoś musi je doprowadzić
        // do zgodności ze stanem. Robi to jedno miejsce, przy każdej zmianie zbioru.
        .onChange(of: panels.windows) { _, _ in
            PanelWindows.shared.sync(panels: panels, context: panelContext)
        }
        .onAppear {
            PanelWindows.shared.sync(panels: panels, context: panelContext)
            syncSlotWindows()
        }
    }

    private func syncSlotWindows() {
        SlotWindows.shared.sync(layout: state.isLoaded ? slotLayout : .single,
                                context: panelContext, openIntoSlot: $openIntoSlot)
    }

    /// To, czego potrzebują treści paneli — patrz `PanelContext`.
    private var panelContext: PanelContext {
        PanelContext(state: state, device: device, library: library,
                     viewState: viewState, fileOpenRequest: $showFileImporter,
                     panels: panels, typing: typing)
        { url in
            guard UnsavedChangesGuard.shared.confirmDiscard(opening: url) else { return }
            let onlySlot = state.load(url: url)
            Task { await device.send(state, onlyFocusedSlot: onlySlot, followDocument: true) }
        }
    }
}

/// Granica Voice / FX przy podzielonym oknie. Kursor „góra-dół" trzyma własny licznik
/// `push`/`pop`, żeby nieparzysta liczba zdjęć nie przywróciła kursora innej kontrolce —
/// SwiftUI potrafi zgłosić wyjście spod myszy bez wejścia (np. gdy widok znika).
struct CanvasSplitHandle: View {
    let height: CGFloat
    /// Przesunięcie w punktach od poprzedniego wywołania (nie od początku gestu).
    let onDrag: (CGFloat) -> Void

    @State private var pushedCursor = false
    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.35))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 40, height: 2)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside, !pushedCursor {
                    NSCursor.resizeUpDown.push()
                    pushedCursor = true
                } else if !inside, pushedCursor {
                    NSCursor.pop()
                    pushedCursor = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        onDrag(value.translation.height - lastTranslation)
                        lastTranslation = value.translation.height
                    }
                    .onEnded { _ in lastTranslation = 0 }
            )
            .help("Drag to change how much room the Voice and FX areas get")
    }
}

// MARK: - Main editor view

struct ContentView: View {
    @Bindable var state: PatchState
    /// Zoom, obszar i widoczność kabli — współdzielone z menu (patrz CanvasViewState).
    @Bindable var viewState: CanvasViewState
    let zoomPanController: CanvasZoomPanController
    /// Druga kanwa (FX pod Voice) ma własny kontroler zoomu — jeden obsługuje jeden
    /// `NSView`, a przy podziale okna są dwa. Zoom pozostaje wspólny: obie połowy
    /// zapisują go do tego samego `viewState.zoom`.
    @State private var fxZoomPanController = CanvasZoomPanController()
    /// Zaznaczenie każdej z kanw — dzielone z menu Edit.
    let selections: CanvasSelectionHub
    let device: DeviceConnection
    @Bindable var panels: PanelController
    let library: DiskBankLibrary
    /// Klawiatura muzyczna pod Caps Lockiem — okno Virtual Keyboard dostaje ją z `PanelContext`.
    let typing: MusicalTyping
    /// Żądanie otwarcia pliku (File → Open) — panele w osobnych oknach muszą podać je
    /// menu głównemu, patrz `PanelBody`.
    let fileOpenRequest: Binding<Bool>

    /// Ghost drag preview — pozycja kursora w ContentView coords, typeID przeciąganego modułu.
    @State private var dragGhost: (typeID: Int, pos: CGPoint)?
    @AppStorage("standardZoom") private var standardZoom: Double = 2.0
    @AppStorage("g2_recently_used") private var recentlyUsedRaw: String = ""
    /// Tryb sidebaru — potrzebny do obliczenia poprawnej granicy X dla ghosta.
    @AppStorage("g2_sidebar_view_mode") private var sidebarViewModeRaw: String = "visual"
    /// Pasek z obciążeniem pod modułem chwyconym z palety — przełącznik w menu View.
    @AppStorage("g2_show_drag_load") private var showDragLoad: Bool = true
    /// Dolna część paska narzędzi — „Extended Toolbar {Ctrl-T}" z instrukcji.
    @AppStorage("g2_extended_toolbar") private var extendedToolbar: Bool = true
    /// Układ slotów — View ▸ Slot Layout (`SlotLayout`).
    @AppStorage(SlotLayout.storageKey) private var slotLayoutRaw = SlotLayout.single.rawValue
    /// Slot, do którego to okno jest przypięte na stałe (okno slotu w układzie
    /// `.windows`). `nil` = okno główne: w układzie jednego pasa i czterech rzędów
    /// pokazuje slot z focusem, w układzie okien — slot A.
    var pinnedSlot: Int?
    /// Okno „Setup ▸ Options" — wygląd kabli i sposób kręcenia gałkami (str. 125).
    @AppStorage(CableStyle.storageKey) private var cableStyleRaw = CableStyle.curved3D.rawValue
    /// Spektrogram emulatora w tle kanwy — przełącznik siedzi w oknie „Spectrum".
    @AppStorage(SpectrogramSettings.inCanvasKey) private var spectrogramInCanvas = false
    @AppStorage(LiveAudioSource.kindKey) private var audioSourceKind = LiveAudioSource.virtualKind
    @AppStorage(KnobControl.storageKey) private var knobControlRaw = KnobControl.vertical.rawValue
    @AppStorage(KnobStyle.storageKey) private var knobStyleRaw = KnobStyle.light.rawValue
    @AppStorage(KnobRangeSegments.storageKey) private var knobRangeSegmentsRaw = KnobRangeSegments.line.rawValue
    @AppStorage(KnobRangeColor.storageKey) private var knobRangeColorRaw = KnobRangeColor.green.rawValue
    @AppStorage(GlowAmount.storageKey) private var glowAmount = 0.0
    @AppStorage(KnobPointerColor.storageKey) private var knobPointerColorRaw = KnobPointerColor.white.rawValue
    @AppStorage(KnobMorphRange.storageKey) private var knobMorphRangeRaw = KnobMorphRange.full.rawValue
    @AppStorage(PanelShading.storageKey) private var panelShading = true
    @State private var showOptions = false
    /// Czy to okno jest kluczowe albo główne. Przy slotach w oknach jest kilka
    /// `ContentView` naraz, a arkusz (Patch Settings, Notes…) ma wyjechać z JEDNEGO —
    /// tego, w którym użytkownik pracuje. Pytamy o to tylko w chwili otwarcia arkusza:
    /// pod wysuniętym arkuszem okno wprawdzie zostaje główne, ale SwiftUI zgłasza je
    /// jako `.inactive` — patrz `presentedSheets`.
    @Environment(\.controlActiveState) private var controlActiveState
    /// Arkusze, które wyjechały z TEGO okna. Decyzja „czy to moje okno" zapada raz,
    /// przy otwarciu. Do 2026-09-16 `sheetBinding` sprawdzał `controlActiveState` przy
    /// każdym przerysowaniu — a pod arkuszem jest `.inactive`, więc każde odświeżenie
    /// (mierniki z grającego G2 przychodzą kilka razy na sekundę) zamykało arkusz, okno
    /// wracało do `.key`, arkusz otwierał się od nowa — i tak w kółko (#99).
    @State private var presentedSheets: Set<SharedSheet> = []

    private var selectedArea: PatchArea {
        viewState.selectedArea
    }

    private var slotLayout: SlotLayout {
        SlotLayout.stored(slotLayoutRaw)
    }

    /// Slot, którego patch jest na kanwie tego okna. Okno przypięte pokazuje swój slot
    /// niezależnie od focusu; okno główne idzie za focusem, chyba że sloty siedzą
    /// w oknach — wtedy jest oknem slotu A.
    private var slot: Int {
        if let pinnedSlot { return pinnedSlot }
        return slotLayout == .windows ? 0 : state.selectedSlot
    }

    private var currentZoom: CGFloat {
        viewState.clampedZoom
    }

    var body: some View {
        // Pasek narzędzi idzie przez CAŁĄ szerokość okna, a biblioteka modułów siedzi
        // pod nim — inaczej wysunięcie biblioteki zabierało pasek z lewej strony
        // i ściskało go razem z zegarem i slotami.
        VStack(spacing: 0) {
            toolbar
            Divider()
            // Pas slotu: sloty, nazwa, wariacje, Vol, On/Off, Voices i morfy — wszystko
            // o JEDNYM patchu, w jednym rzędzie i w kolejności oryginału. Do 2026-09-10
            // było to rozbite na trzy rzędy i przemieszane z ustawieniami aplikacji.
            // Chowa go „Extended Toolbar {Ctrl-T}" (instrukcja, str. 130), u nas ⌘T
            // z menu View — wariacje mają wtedy nadal skróty 1–8.
            if extendedToolbar {
                slotBars
                Divider()
            }

            HStack(spacing: 0) {
                // Szuflada z lewej: biblioteka modułów ALBO przeglądarka patchy — jedna
                // naraz, bo obie zajmują ten sam pas ekranu i służą do tego samego
                // ruchu: wybrać coś i przenieść na patch.
                if panels.isOpen(.modules) {
                    ModuleSidebarView(
                        onAdd: { typeID in
                            state.addModule(typeID: typeID, area: selectedArea)
                            trackRecentlyUsed(typeID)
                        },
                        onGhostMove: { typeID, pt in dragGhost = (typeID, pt) },
                        onGhostEnd: { dragGhost = nil },
                        // Wyłączony przełącznik = brak domknięcia, więc podgląd w palecie
                        // nawet nie pyta o liczby.
                        patchLoadPreview: showDragLoad ? { patchLoadAfterAdding(typeID: $0) } : nil
                    )
                    .environment(\.canvasZoom, currentZoom)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    // zIndex(1): overlay hover popup sidebaru renderuje się PONAD canvasem
                    // (w HStack bez zIndex canvas byłby na wierzchu i zasłaniał popup)
                    .zIndex(1)
                    Divider()
                }

                if panels.isOpen(.banks) {
                    DrawerPanel(panels: panels, panel: .banks, context: panelContext)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(1)
                }

                canvasArea
                    .overlay { TransferProgressStrip(device: device) }
                    .overlay(alignment: .top) { UploadFailureBar(device: device) }
            }
        }
        // Skróty jednoklawiszowe z instrukcji (1–8, A–D, V, F, R, F5–F8) — patrz
        // `EditorKeyboardShortcuts`. Warstwa jest przezroczysta i nie łapie myszy.
        .background(EditorKeyboardShortcuts(state: state, viewState: viewState, device: device))
        // Esc zamyka wysuniętą szufladę i oddaje fokus canvasowi.
        .onExitCommand { withAnimation(.easeInOut(duration: 0.18)) { panels.close() } }
        // Biblioteka z obrazkami czeka przy starcie schowana, aż podglądy będą gotowe,
        // i wtedy się wysuwa — puste kolorowe kategorie wyglądały źle (2026-10-09).
        .onAppear {
            guard pinnedSlot == nil, panels.drawer == .modules, sidebarViewModeRaw == "visual",
                  !ModulePreviewCache.shared.allReady else { return }
            panels.holdDrawer()
        }
        .onChange(of: ModulePreviewCache.shared.allReady) { _, ready in
            guard ready, panels.drawerHeld else { return }
            withAnimation(.easeInOut(duration: 0.25)) { panels.releaseDrawer() }
        }
        .overlay(alignment: .topLeading) { dragGhostOverlay }
        .focusedSceneValue(\.optionsRequest, $showOptions)
        // Okno slotu jest oknem AppKit poza sceną — tam menu Options… dostaje żądanie
        // tą samą drogą co panele w oknach (`PanelBody`).
        .focusedValue(\.optionsRequest, $showOptions)
        // Options (⌘,), Patch, Performance i Synth Settings to od 2026-10-15 jedno okno
        // z zakładkami (`SettingsWindow`), nie arkusze. Flagi zostają drogą z menu do okna.
        .onChange(of: showOptions) { _, on in openSettings(nil, on) { showOptions = false } }
        .onChange(of: state.showPatchSettings) { _, on in
            openSettings(.patch, on) { state.showPatchSettings = false }
        }
        .onChange(of: state.showPerformanceSettings) { _, on in
            openSettings(.performance, on) { state.showPerformanceSettings = false }
        }
        .onChange(of: state.showSynthSettings) { _, on in
            openSettings(.synth, on) { state.showSynthSettings = false }
        }
        .sheet(isPresented: sheetBinding(.patchNotes, $state.showPatchNotes)) {
            PatchNotesSheet(state: state)
        }
        .onChange(of: state.showPatchNotes) { _, on in claimSheet(.patchNotes, on) }
        .sheet(isPresented: sheetBinding(.bankUpload, $state.showBankUpload)) {
            BankUploadSheet(isPresented: $state.showBankUpload, device: device)
        }
        .onChange(of: state.showBankUpload) { _, on in claimSheet(.bankUpload, on) }
        // Tytuł i podtytuł liczy osobny widok — podtytuł czyta patch (liczby modułów).
        .background(DocumentTitles(state: state, slot: slot, layout: slotLayout))
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            viewState.zoomRequester = zoomPanController
        }
        // Zoom z menu i skrótów kotwiczy się na kanwie okna kluczowego — przy kilku
        // oknach slotów każde ma własny kontroler, a `zoomRequester` jest jeden.
        .onChange(of: controlActiveState) { _, active in
            if active == .key { viewState.zoomRequester = zoomPanController }
        }
        // ⌘Z i ⇧⌘Z niesie teraz menu Edit (patrz `MainMenu.swift`). Zostaje samo ⌘Y,
        // którego menu macOS nie zna, a które ma na klawiaturze oryginalny edytor.
        .background { RedoShortcut(state: state) }
    }

    /// Arkusze wspólne dla wszystkich okien slotów — ich flagi mieszkają w `PatchState`,
    /// bo otwiera je menu, a to nie wie, które okno ma je pokazać.
    private enum SharedSheet: Hashable {
        case patchNotes, bankUpload
    }

    /// Flaga z menu otwiera okno Settings na zakładce i od razu gaśnie — przy oknach
    /// slotów obserwuje ją kilka widoków, ale okno jest jedno.
    private func openSettings(_ tab: SettingsTab?, _ on: Bool, reset: () -> Void) {
        guard on else { return }
        SettingsWindow.show(tab, state: state, device: device)
        reset()
    }

    /// Arkusz wyjeżdża tylko z okna, w którym użytkownik pracuje — patrz `presentedSheets`.
    /// Zamknięcie z klawiatury (Esc) zdejmuje też flagę w `PatchState`; przycisk Done
    /// zdejmuje ją sam, a `claimSheet` sprząta wtedy nasz zbiór.
    private func sheetBinding(_ sheet: SharedSheet, _ flag: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { presentedSheets.contains(sheet) },
            set: { if !$0 { presentedSheets.remove(sheet)
                flag.wrappedValue = false
            } }
        )
    }

    /// Flaga w `PatchState` zmieniła się: okno, w którym użytkownik pracuje, bierze
    /// arkusz na siebie; zdjęta flaga zamyka go wszędzie.
    private func claimSheet(_ sheet: SharedSheet, _ on: Bool) {
        if on {
            if controlActiveState != .inactive { presentedSheets.insert(sheet) }
        } else {
            presentedSheets.remove(sheet)
        }
    }

    // MARK: - Pasy slotów

    /// Pasy slotów wg układu (View ▸ Slot Layout): jeden dla slotu tego okna albo
    /// cztery rzędy, po jednym na slot. Zwykły patch ma jeden slot, więc cztery rzędy
    /// sprowadzają się do jednego. Ten sam komponent w każdym układzie — różni się
    /// tylko liczba pasów i miejsce litery slotu → [[Docs/ui/slot-layout]].
    @ViewBuilder
    private var slotBars: some View {
        switch slotLayout {
        case .single, .windows:
            SlotBarView(state: state, device: device, slot: slot, layout: slotLayout)
        case .fourRows:
            SlotBarRows(state: state, device: device)
        }
    }

    // MARK: - Kanwa: jeden obszar albo oba jeden pod drugim

    /// Wciśnięte oba przyciski Area → okno dzieli się wzdłuż: Voice u góry, FX pod
    /// spodem, a granicę między nimi da się przeciągnąć myszą.
    @ViewBuilder
    private var canvasArea: some View {
        let areas = viewState.orderedVisibleAreas
        if areas.count > 1 {
            GeometryReader { geo in
                // Uchwyt zabiera swoje 6 pt, reszta idzie do obu kanw wg `splitFraction`.
                let usable = max(geo.size.height - Self.splitHandleHeight, 0)
                let top = (usable * viewState.splitFraction).rounded()
                VStack(spacing: 0) {
                    canvasPane(.voice, controller: zoomPanController)
                        .frame(height: top)
                    CanvasSplitHandle(height: Self.splitHandleHeight) { delta in
                        guard usable > 0 else { return }
                        viewState.setSplitFraction(viewState.splitFraction + delta / usable)
                    }
                    canvasPane(.fx, controller: fxZoomPanController)
                        .frame(height: max(usable - top, 0))
                }
            }
        } else {
            canvasPane(areas.first ?? .voice, controller: zoomPanController)
        }
    }

    private static let splitHandleHeight: CGFloat = 6

    /// Tło kanwy: zwykle jednolita szarość, a przy włączonym spektrogramie — warstwa
    /// z obrazem. **Leży POD `ScrollView`**, więc odświeża się sama, nie budząc kanwy
    /// z modułami (patrz nagłówek `SpectrogramPanel.swift`).
    @ViewBuilder
    private var canvasBackdrop: some View {
        if showsSpectrumBackdrop {
            SpectrogramBackdrop()
        } else {
            UIColor.canvasBackground
        }
    }

    /// Spektrogram pod patchem: dźwięk emulatora albo wejść interfejsu (Nord).
    private var showsSpectrumBackdrop: Bool {
        spectrogramInCanvas && (device.isVirtualDevice || audioSourceKind == LiveAudioSource.interfaceKind)
    }

    private func canvasPane(_ area: PatchArea, controller: CanvasZoomPanController) -> some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                canvasContent(area: area, minSize: geo.size, controller: controller)
            }
            .background(canvasBackdrop)
            .onAppear { reportViewport(area: area, size: geo.size) }
            .onChange(of: geo.size) { _, new in reportViewport(area: area, size: new) }
            // Przy podzielonym oknie celem poleceń (nowy moduł z palety, „Zoom to Fit",
            // odczyt liczby modułów) jest ta połowa, nad którą stoi kursor.
            .onHover { inside in
                guard inside, viewState.isSplit, viewState.selectedArea != area else { return }
                viewState.selectedArea = area
                reportViewport(area: area, size: geo.size)
            }
        }
    }

    /// „Zoom to Fit" mierzy okno tego obszaru, którego dotyczy — czyli tego z fokusem.
    private func reportViewport(area: PatchArea, size: CGSize) {
        guard area == viewState.selectedArea else { return }
        viewState.viewportSize = size
    }

    private func canvasContent(area: PatchArea,
                               minSize: CGSize,
                               controller: CanvasZoomPanController) -> some View
    {
        // Patch czyta dopiero `CanvasPane` — tick gałki budzi kanwę, nie całe okno
        // (patrz `PatchBoundViews.swift`).
        CanvasPane(
            state: state,
            viewState: viewState,
            selections: selections,
            device: device,
            panels: panels,
            slot: slot,
            area: area,
            zoom: currentZoom,
            minSize: minSize,
            controller: controller,
            cableStyle: CableStyle(rawValue: cableStyleRaw) ?? .curved3D,
            knobControl: KnobControl(rawValue: knobControlRaw) ?? .vertical,
            knobStyle: KnobLook(style: KnobStyle(rawValue: knobStyleRaw) ?? .light,
                                rangeSegments: KnobRangeSegments(rawValue: knobRangeSegmentsRaw) ?? .line,
                                rangeColor: KnobRangeColor(rawValue: knobRangeColorRaw) ?? .green,
                                glow: glowAmount,
                                pointerColor: KnobPointerColor(rawValue: knobPointerColorRaw) ?? .white,
                                morphRange: KnobMorphRange(rawValue: knobMorphRangeRaw) ?? .full),
            panelShading: panelShading,
            showsBackdrop: showsSpectrumBackdrop,
            onModuleAdded: trackRecentlyUsed
        )
    }

    /// To, czego potrzebują treści paneli — patrz `PanelContext`.
    private var panelContext: PanelContext {
        PanelContext(state: state, device: device, library: library,
                     viewState: viewState, fileOpenRequest: fileOpenRequest,
                     panels: panels, typing: typing)
        { url in
            guard UnsavedChangesGuard.shared.confirmDiscard(opening: url) else { return }
            let onlySlot = state.load(url: url)
            Task { await device.send(state, onlyFocusedSlot: onlySlot, followDocument: true) }
        }
    }

    /// Górna belka aplikacji — wszystko, co dotyczy CAŁEGO edytora, a nie jednego
    /// patcha (ten ma własny pas, `SlotBarView`). Kolejność sekcji i wygląd wg szkicu
    /// użytkownika z 2026-09-10: jedna ramka dla wszystkich przycisków, jedna para
    /// strzałek dla wszystkich liczb → `TopBarControls.swift`.
    private var toolbar: some View {
        // Belka ZAWIJA SIĘ: przy wąskim oknie grupa, która się nie mieści, przechodzi
        // w całości do rzędu niżej (TopBar 1A) zamiast ściskać się do zera.
        TopBarFlowLayout(spacing: 10) {
            // Dwie szuflady lewej krawędzi obok siebie: moduły i patche. Jedna naraz —
            // klik w drugą podmienia pierwszą. Open/Save tu nie ma: te same polecenia
            // (i te same skróty) siedzą w menu File, a pasek ma zostać wąski.
            HStack(spacing: 3) {
                drawerButton(.modules)
                drawerButton(.banks)
            }

            topBarFlowDivider()

            deviceConnectionControl


            topBarFlowDivider()

            // Zegar główny — w oryginale i w obu odtworzonych edytorach siedzi dokładnie
            // tu: w globalnej belce, między nazwą performance'u a paskiem slotów.
            MasterClockView(state: state, device: device)

            topBarFlowDivider()

            // Sloty A/B/C/D i wariacje przeniosły się do `SlotBarView` — ten pasek
            // trzyma już tylko to, co dotyczy CAŁEJ aplikacji, nie jednego patcha.
            areaControls

            topBarFlowDivider()

            zoomControls

            topBarFlowDivider()

            cableControls

            topBarFlowDivider()

            // Panele we własnych oknach, a za nimi odczyt obciążenia oglądanego slotu
            // (VA / FX / Cycles / Memory). Do 2026-09-10 stał tu `Spacer()`, który
            // odrzucał jedno i drugie na prawą krawędź — teraz idą dalej w lewo,
            // razem z resztą opcji.
            HStack(spacing: 3) {
                windowButton(.parameterPages)
                windowButton(.parameterOverview)
                windowButton(.patchAdjuster)
                windowButton(.mutator)
                windowButton(.dsp)
                windowButton(.keyboard)
                windowButton(.colors)
                // Oba słuchają wirtualnego G2 albo wejść interfejsu audio (wybór w oknie),
                // więc działają też bez emulatora — z Nordem podpiętym do interfejsu.
                windowButton(.spectrogram)
                windowButton(.xyPlot)
            }

            topBarFlowDivider()

            // Oba odczyty czytają patch, więc są osobnymi widokami — tick gałki
            // odświeża je, ale nie resztę belki (patrz `PatchBoundViews.swift`).
            ToolbarPatchLoad(state: state, device: device, slot: slot)

            topBarFlowDivider()

            ToolbarPatchStats(state: state, slot: slot, area: selectedArea)
        }
        .padding(.horizontal, 12)
        // Belkę mierzy najwyższy element — tabelka Cycles / Memory. Odstęp nad nią
        // i pod nią jest tu celowo minimalny: użytkownik zgłosił belkę jako za wysoką.
        .padding(.vertical, 3)
    }

    /// Voice i FX to DWA ZWYKŁE przyciski, nie przełącznik radiowy: wciśnięte oba
    /// dzielą kanwę wzdłuż (Voice u góry, FX pod spodem). Ostatniego widocznego nie
    /// da się zgasić — kanwa nie miałaby czego pokazać.
    private var areaControls: some View {
        HStack(spacing: 6) {
            TopBarCaption(text: "Area")
            VStack(spacing: 2) {
                areaButton(.voice, title: "Voice")
                areaButton(.fx, title: "FX")
            }
        }
    }

    private func areaButton(_ area: PatchArea, title: String) -> some View {
        let visible = viewState.isAreaVisible(area)
        let last = visible && viewState.visibleAreas.count == 1
        return TopBarSmallButton(title: title, width: 44, isOn: visible) {
            viewState.toggleArea(area)
        }
        .help(last
            ? "\(title) area — press FX or Voice to show both, split top and bottom"
            : (visible ? "Hide the \(title) area" : "Show the \(title) area"))
    }

    /// Skala kanwy. Pierwszy przycisk wraca do skali ustalonej (prawy klawisz = wybór
    /// z listy), drugi dopasowuje widok do wszystkich modułów, dalej odczyt ze
    /// strzałkami. Skróty klawiszowe siedzą w menu View (MainMenu.swift), nie tutaj,
    /// żeby nie było dwóch komend na ten sam skrót.
    private var zoomControls: some View {
        HStack(spacing: 6) {
            TopBarButton(content: .icon("arrow.down.right.and.arrow.up.left")) {
                viewState.requestZoom(CGFloat(standardZoom))
            }
            .help("Standard zoom — \(Int(standardZoom * 50))% (right-click to choose)")
            // Prawy klawisz na przycisku wybiera, do jakiej skali on wraca.
            .contextMenu {
                ForEach(Self.standardZoomChoices, id: \.self) { percent in
                    Toggle("\(percent)%", isOn: Binding(
                        get: { isStandardZoom(percent) },
                        set: { _ in
                            standardZoom = Double(percent) / 50.0
                            viewState.requestZoom(CGFloat(percent) / 50.0)
                        }
                    ))
                }
            }

            TopBarButton(content: .icon("arrow.up.left.and.arrow.down.right")) {
                zoomToFit()
            }
            .help("Fit all modules in the window (⌘⇧0)")

            Text("\(Int(currentZoom * 50))%")
                .font(.system(size: TopBarMetrics.labelSize))
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)

            TopBarStepper(
                canIncrement: currentZoom < CanvasViewState.maxZoom,
                canDecrement: currentZoom > CanvasViewState.minZoom,
                onIncrement: { viewState.zoomIn() },
                onDecrement: { viewState.zoomOut() }
            )
        }
    }

    private static let standardZoomChoices = [100, 120, 140]

    private func isStandardZoom(_ percent: Int) -> Bool {
        abs(standardZoom - Double(percent) / 50.0) < 0.001
    }

    private var cableControls: some View {
        HStack(spacing: 6) {
            TopBarCaption(text: "Cables:")

            // Sztywna szerokość, bo napis się zmienia: bez niej „Show" był szerszy od
            // „Hide" i każdy klik przesuwał w bok całą resztę belki.
            TopBarButton(content: .text(viewState.allCablesHidden ? "Show" : "Hide"),
                         isOn: viewState.allCablesHidden,
                         fixedWidth: 46)
            {
                viewState.allCablesHidden.toggle()
            }
            .help(viewState.allCablesHidden ? "Show all cables" : "Hide all cables")

            // Skrót „S" siedzi w `EditorKeyboardShortcuts`, a nie tutaj: gołe litery
            // jako skróty SwiftUI wyprzedzają pole tekstowe i nie dałoby się wpisać
            // „s" w nazwie patcha.
            TopBarButton(content: .icon("waveform.path.ecg")) { viewState.shakeCables() }
                .help("Shake cables (S)")

            HStack(spacing: 4) {
                ForEach(CableColor.allCases, id: \.self) { color in
                    cableColorButton(color)
                }
            }
            .padding(.leading, 2)
        }
    }

    /// Przycisk szuflady (moduły, patche). Podświetlony = ta szuflada jest wysunięta.
    private func drawerButton(_ panel: PanelController.Panel) -> some View {
        let open = panels.isOpen(panel)
        let hint = "\(open ? "Hide" : "Show") \(panel.title.lowercased()) (\(shortcutHint(panel)))"
        return TopBarButton(content: .icon(panel.symbol), isOn: open) {
            withAnimation(.easeInOut(duration: 0.2)) { panels.toggle(panel) }
        }
        .help(hint)
    }

    /// Przycisk panelu, który mieszka we własnym oknie — klik otwiera je i zamyka.
    private func windowButton(_ panel: PanelController.Panel) -> some View {
        let open = panels.isOpen(panel)
        return TopBarButton(content: .icon(panel.symbol), isOn: open) {
            panels.toggle(panel)
        }
        .help("\(panel.title) — \(open ? "close the window" : "open in a window") (\(shortcutHint(panel)))")
    }

    private func shortcutHint(_ panel: PanelController.Panel) -> String {
        "⌘⌥\(String(panel.shortcutKey))"
    }

    /// Obciążenie do paska pod modułem chwyconym z palety — liczone w chwili
    /// najechania, nie przy każdym przerysowaniu.
    private func dspLoad(area: PatchArea) -> G2PatchLoad? {
        if let reported = device.patchLoad(slot: slot, area: area) { return reported }
        guard state.slots.indices.contains(slot) else { return nil }
        return .estimate(area: area, modules: state.slots[slot].modules(in: area))
    }

    /// Dodaje typeID na początek listy ostatnio używanych (max 10, bez duplikatów).
    private func trackRecentlyUsed(_ typeID: Int) {
        var recent = recentlyUsedRaw.split(separator: ",").compactMap { Int($0) }
        recent.removeAll { $0 == typeID }
        recent.insert(typeID, at: 0)
        if recent.count > 10 { recent = Array(recent.prefix(10)) }
        recentlyUsedRaw = recent.map(String.init).joined(separator: ",")
    }

    /// Sam wskaźnik, bez przycisku: edytor łączy się z Nordem samoczynnie, tak jak
    /// oryginał Clavii. Nie ma czego klikać — jest albo nie ma urządzenia.
    /// Wskaźnik połączenia jest też menu diagnostyki USB. Przełącznika „Live Meters"
    /// tu NIE MA: wskaźniki chodzą zawsze, bo ich wyłączenie tylko odbierało edytorowi
    /// podgląd sygnału, nic w zamian nie przyspieszając.
    private var deviceConnectionControl: some View {
        // `device` przychodzi tu jako `let` — bez `@Bindable` nie ma z czego zrobić
        // `$device.usbLogEnabled` dla przełącznika.
        @Bindable var device = device
        return Menu {
            // Zbieranie chodzi cały czas w pamięci, więc przełącznik ZAPISUJE, a nie
            // „włącza" — i zapisze też to, co wydarzyło się przed kliknięciem (2026-09-19).
            Toggle("Write USB Log to File", isOn: $device.usbLogEnabled)
                .help("Save raw USB traffic to a file, including what happened before you switched this on.")
            if device.usbLogEnabled {
                Button("Reveal USB Log in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: device.usbLogPath)])
                }
            }
        } label: {
            HStack(spacing: 6) {
                // W miejscu kropki stanu kręci się kółko, gdy trwa transfer: wgranie patcha
                // i odczyt z Norda zajmują sekundy, a bez tego wyglądają jak zawieszenie.
                // Stała ramka trzyma szerokość paska, żeby nic nie podskakiwało.
                ZStack {
                    if device.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Circle()
                            .fill(deviceStatusColor)
                            .frame(width: 8, height: 8)
                    }
                }
                .frame(width: 14, height: 14)
                Text(deviceStatusTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(deviceStatusHelp)
    }

    /// Wirtualny G2 świeci NIEBIESKO, nie na zielono. Zielone „G2 Live" ma znaczyć
    /// „sprzęt odpowiada" i nic innego — atrapa odpowiada tak, jak MY rozumiemy
    /// protokół, więc pomylenie jej ze sprzętem przebiera nasz własny błąd za sukces
    /// → [[Docs/usb/emulator]].
    private var deviceStatusColor: Color {
        switch device.status {
        case .searching: .secondary
        case .connecting: .yellow
        case .connected: device.isVirtualDevice ? .cyan : .green
        case .error: .red
        }
    }

    private var deviceStatusTitle: String {
        // Wysyłka slotu to kilkaset komend, a odczyt po patchu załadowanym na froncie
        // Norda to do ~72 kB — bez tego wskaźnik przez te kilka sekund pokazywałby
        // „G2 Live", choć edytor akurat jest zajęty transferem.
        if let progress = device.sendProgress ?? device.loadProgress { return progress }
        if let upload = device.bankUpload { return "Downloading Banks \(upload.done)/\(upload.total)" }
        return switch device.status {
        case .searching: "No G2"
        case .connecting: "Connecting…"
        case .connected: device.isVirtualDevice ? "Virtual G2" : "G2 Live"
        case .error: "G2 Error"
        }
    }

    private var deviceStatusHelp: String {
        if case let .error(message) = device.status { return message }
        return switch device.status {
        case .searching: "Waiting for a Nord G2 on USB — the editor connects on its own."
        case .connecting: "Reading the four slots from the Nord G2…"
        default: device.isVirtualDevice
            ? "Connected to the virtual G2, not to hardware. It answers the way this editor expects, so it proves nothing about a real Nord."
            : "Connected to \(connectedDeviceName). Knob moves play live on the Nord, and its front panel plays back here."
        }
    }

    /// Model i firmware tak, jak urządzenie samo się przedstawiło w handshake.
    private var connectedDeviceName: String {
        guard let identity = device.deviceIdentity else { return "a Nord G2" }
        guard let firmware = identity.firmwareText else { return identity.displayName }
        return "\(identity.displayName) \(firmware)"
    }

    private func cableColorButton(_ color: CableColor) -> some View {
        let isHidden = !viewState.isCableColorVisible(color)
        return Button {
            viewState.toggleCableColor(color)
        } label: {
            // Widoczny kolor: przygaszone wnętrze i obwódka w pełnym kolorze; ukryty: sama
            // obwódka (prośba użytkownika 2026-10-13; wcześniej widoczny był pełną kropką).
            Circle()
                .fill(isHidden ? Color.clear : color.swatch.opacity(0.35))
                .frame(width: TopBarMetrics.colorDotSize, height: TopBarMetrics.colorDotSize)
                .overlay(
                    Circle().strokeBorder(color.swatch, lineWidth: 1.5)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color.displayName + (isHidden ? " (hidden)" : ""))
    }

    private func zoomToFit() {
        let modules = state.patch(inSlot: slot).modules(in: selectedArea)
        guard !modules.isEmpty else { return }
        let rowOffset = PatchLayout.minRow(modules: modules)
        let contentSize = PatchLayout.canvasSize(
            modules: modules,
            defs: { ModuleDatabase.module(id: $0) },
            rowOffset: rowOffset
        )
        viewState.zoomToFit(contentSize: contentSize)
    }

    // MARK: - Drag ghost overlay

    /// Prawa krawędź wysuniętej szuflady w ContentView coords (+1 za divider).
    /// Ghost jest widoczny TYLKO gdy kursor jest po prawej stronie tej granicy.
    private var sidebarEdge: CGFloat {
        switch panels.drawerHeld ? nil : panels.drawer {
        case .modules: (sidebarViewModeRaw == "visual" ? PanelController.Panel.drawerWidth : 190) + 1
        case .banks: PanelController.Panel.drawerWidth
        default: 0
        }
    }

    /// Ghost preview podczas draga z sidebaru — renderowany nad całym oknem (sidebar + canvas).
    /// Lewy górny róg ghosta = pozycja kursora (spójne z drag image panelem).
    @ViewBuilder
    private var dragGhostOverlay: some View {
        if let g = dragGhost, g.pos.x > sidebarEdge, let mdef = ModuleDatabase.module(id: g.typeID) {
            let w = PatchLayout.moduleWidth * currentZoom
            let h = CGFloat(mdef.height) * PatchLayout.ySpan * currentZoom
            let stripeColor = ghostCategoryColor(for: mdef.page)
            let fontSize = max(min(h * 0.28, 13.0), 9.0)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.80)
                Rectangle()
                    .fill(stripeColor)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity, alignment: .leading)
                Text(mdef.shortName)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.leading, PatchLayout.dragGhostLabelLeadingPadding)
                    .padding(.top, 3)
            }
            .frame(width: w, height: h)
            .overlay(Rectangle().stroke(Color.white.opacity(0.6), lineWidth: 1))
            .position(x: g.pos.x + w / 2, y: g.pos.y + h / 2)
            .allowsHitTesting(false)
        }
    }

    /// Obciążenie po dorzuceniu modułu tego typu — dla paska pod podglądem w palecie.
    /// Moduł ląduje w obszarze oglądanym na canvasie, więc tylko ten się zmienia.
    private func patchLoadAfterAdding(typeID: Int) -> (voice: G2PatchLoad?, fx: G2PatchLoad?) {
        let voice = dspLoad(area: .voice)
        let fx = dspLoad(area: .fx)
        return (
            selectedArea == .voice ? voice?.adding(typeID: typeID) : voice,
            selectedArea == .fx ? fx?.adding(typeID: typeID) : fx
        )
    }

    private func ghostCategoryColor(for page: String) -> Color {
        switch page {
        case "In/Out": Color(red: 0.392, green: 0.392, blue: 0.392)
        case "Note": Color(red: 0.549, green: 0.008, blue: 0.992)
        case "Osc": Color(red: 0.792, green: 0.000, blue: 0.000)
        case "LFO": Color(red: 0.000, green: 0.000, blue: 0.792)
        case "Rnd": Color(red: 0.000, green: 0.588, blue: 0.902)
        case "Env": Color(red: 0.000, green: 0.733, blue: 0.733)
        case "Filter": Color(red: 0.000, green: 0.510, blue: 0.518)
        case "FX": Color(red: 0.918, green: 0.392, blue: 0.690)
        case "Delay": Color(red: 0.514, green: 0.349, blue: 1.000)
        case "Shaper": Color(red: 0.808, green: 0.443, blue: 0.451)
        case "Level": Color(red: 0.251, green: 0.627, blue: 0.000)
        case "Mixer": Color(red: 1.000, green: 0.502, blue: 0.251)
        case "Switch": Color(red: 0.400, green: 0.851, blue: 1.000)
        case "Logic": Color(red: 0.961, green: 0.918, blue: 0.004)
        case "Seq": Color(red: 0.996, green: 0.812, blue: 0.255)
        case "MIDI": Color(red: 0.753, green: 0.502, blue: 0.000)
        case "PM": Color(red: 0.200, green: 0.600, blue: 0.400)
        default: Color(red: 0.392, green: 0.392, blue: 0.392)
        }
    }
}

/// Niewidzialny ⌘Y. Osobny widok, bo czyta `undoRevision` — w `ContentView` każda edycja
/// przeliczałaby całe okno, a bez tego odczytu wyszarzenie stało na starym stanie.
private struct RedoShortcut: View {
    let state: PatchState

    var body: some View {
        _ = state.undoRevision
        return Button("") { state.undoManager.redo() }
            .keyboardShortcut("y", modifiers: .command)
            .disabled(!state.undoManager.canRedo)
            .opacity(0)
            .allowsHitTesting(false)
    }
}

/// Nord podłączył się, a edytor ma własny patch — opcja `ConnectContentMode` (decyzja
/// użytkownika 2026-10-15: domyślnie Send, bez pytania). Wcześniej ekran pokazywał patch
/// z edytora, a Nord grał swoje.
@MainActor
private enum EditorContentAtConnect {
    static func resolve(state: PatchState, device: DeviceConnection, virtualDevice: Bool) async {
        var choice = virtualDevice ? .sendToDevice : ConnectContentMode.stored
        if choice == .ask { choice = ask() }
        switch choice {
        case .loadFromDevice:
            // Cancel w pytaniu o zapis = edytor zostaje przy swoim, Nord przy swoim.
            guard UnsavedChangesGuard.shared.confirmDiscard() else { return }
            await device.loadDeviceContentIntoEditor()
        case .sendToDevice, .ask:
            // Tryb Norda zmieniamy tylko dla otwartego `.prf2`. Dokument złożony z pojedynczych
            // patchy nie mówi jednoznacznie, w którym trybie ma grać — wtedy tryb zostaje.
            await device.send(state, followDocument: state.performanceFileURL != nil)
        }
    }

    private static func ask() -> ConnectContentMode {
        let alert = NSAlert()
        alert.messageText = "The G2 is connected. Which patch should play?"
        alert.informativeText = "The editor has its own patch open. Send it to the G2, or load the G2's patch "
            + "into the editor. Sending replaces only the G2's current slots, not its memory banks."
        alert.addButton(withTitle: "Send to G2")
        alert.addButton(withTitle: "Load from G2")
        return alert.runModal() == .alertSecondButtonReturn ? .loadFromDevice : .sendToDevice
    }
}

/// Pasek postępu na środku kanwy na czas transferu z Norda i do Norda (prośba użytkownika
/// 2026-10-15): duży performance idzie kilka sekund, a samo kółko przy wskaźniku
/// połączenia łatwo przeoczyć. Widać go od pierwszej chwili transferu (decyzja
/// użytkownika). Postęp w procentach znamy tylko przy wysyłce slot po slocie — cały
/// performance to jedna komenda, więc wtedy pasek jedzie bez procentów. Na środku,
/// nie przy górnej krawędzi — tam ginął (prośba użytkownika 2026-10-15).
private struct TransferProgressStrip: View {
    let device: DeviceConnection

    var body: some View {
        if let message = device.sendProgress ?? device.loadProgress {
            VStack(spacing: 4) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let fraction = device.transferFraction {
                    ProgressView(value: fraction)
                } else {
                    ForwardProgressBar()
                }
            }
            .frame(width: 260)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // Czarne okienko w obu motywach (wybór użytkownika z makiet 2026-10-15) —
            // ciemny schemat, żeby napis i pasek z procentami były jasne na czerni.
            .background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 8))
            .environment(\.colorScheme, .dark)
            .shadow(radius: 6)
            .allowsHitTesting(false)
        }
    }
}

/// Nord nie przyjął wysłanego patcha (#143). Do 2026-10-20 mówiła o tym tylko czerwona
/// kropka, gasnąca po 2 s, a slot milczał dalej. Pasek zostaje, dopóki slot nie zostanie
/// potwierdzony (następna udana wysyłka) albo użytkownik go nie zamknie. Wygląd jak pasek
/// błędu w panelu Banks — ten sam rodzaj wiadomości.
private struct UploadFailureBar: View {
    let device: DeviceConnection

    var body: some View {
        if let message = device.uploadFailure {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    device.dismissUploadFailure()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: 560)
            // Kryjące tło pod pomarańczowym odcieniem — pasek leży na kanwie z modułami.
            .background {
                RoundedRectangle(cornerRadius: 6).fill(.background)
                RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12))
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.orange.opacity(0.5)))
            .padding(.top, 8)
        }
    }
}

/// Pasek bez procentów: rząd kresek, po których w prawo przebiega fala zielonego
/// światła — jak diody (wybór użytkownika z makiet 2026-10-15; systemowy
/// `ProgressView` jeździł tam i z powrotem). Zielony ten sam co „On” w belce.
private struct ForwardProgressBar: View {
    private let dashCount = 13
    private let cycle: TimeInterval = 1.3
    /// Opóźnienie fali między sąsiednimi kreskami.
    private let step: TimeInterval = 0.1
    /// Zgaszona kreska — przygaszona zieleń, jak niezapalona dioda.
    private let unlitOpacity = 0.25

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0 ..< dashCount, id: \.self) { index in
                    let lit = brightness(at: time - Double(index) * step)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.green)
                        .opacity(unlitOpacity + (1 - unlitOpacity) * lit)
                }
            }
            .frame(height: 6)
        }
    }

    /// Kreska zapala się przez pierwsze 20 % cyklu i gaśnie przez kolejne 20 %.
    private func brightness(at time: TimeInterval) -> Double {
        var phase = time.truncatingRemainder(dividingBy: cycle) / cycle
        if phase < 0 { phase += 1 }
        if phase < 0.2 { return phase / 0.2 }
        if phase < 0.4 { return (0.4 - phase) / 0.2 }
        return 0
    }
}
