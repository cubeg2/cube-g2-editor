import AppKit
import G2Core
import G2EditorCore
import SwiftUI

// MARK: - FocusedValues do przekazania stanu z RootView do menu commands

private struct PatchStateKey: FocusedValueKey {
    typealias Value = PatchState
}

private struct CanvasViewStateKey: FocusedValueKey {
    typealias Value = CanvasViewState
}

private struct FileOpenRequestKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

/// Slot docelowy dla „Open To ▸" — ustawiony tuż przed otwarciem okna wyboru pliku mówi
/// `RootView`, że wczytany patch ma trafić do jednego slotu, a nie zastąpić cały dokument.
private struct OpenIntoSlotKey: FocusedValueKey {
    typealias Value = Binding<Int?>
}

/// Most do Norda. Menu File go potrzebuje, bo nowy patch ma od razu polecieć do
/// urządzenia — u BVerhue `Init patch` kończy się `SendSetPatchMessage`.
private struct DeviceConnectionKey: FocusedValueKey {
    typealias Value = DeviceConnection
}

/// Panele boczne — menu View przełącza je tak samo jak zakładki na pasku.
private struct PanelControllerKey: FocusedValueKey {
    typealias Value = PanelController
}

/// Okno „Setup ▸ Options" — na macOS wisi pod ⌘, w menu aplikacji.
private struct OptionsRequestKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

/// Zaznaczenie modułów na kanwie — menu Edit działa na tym samym zbiorze co menu
/// pod prawym przyciskiem myszy.
private struct CanvasSelectionsKey: FocusedValueKey {
    typealias Value = CanvasSelectionHub
}

extension FocusedValues {
    var patchState: PatchState? {
        get { self[PatchStateKey.self] }
        set { self[PatchStateKey.self] = newValue }
    }

    var canvasViewState: CanvasViewState? {
        get { self[CanvasViewStateKey.self] }
        set { self[CanvasViewStateKey.self] = newValue }
    }

    var fileOpenRequest: Binding<Bool>? {
        get { self[FileOpenRequestKey.self] }
        set { self[FileOpenRequestKey.self] = newValue }
    }

    var openIntoSlotRequest: Binding<Int?>? {
        get { self[OpenIntoSlotKey.self] }
        set { self[OpenIntoSlotKey.self] = newValue }
    }

    var deviceConnection: DeviceConnection? {
        get { self[DeviceConnectionKey.self] }
        set { self[DeviceConnectionKey.self] = newValue }
    }

    var panelController: PanelController? {
        get { self[PanelControllerKey.self] }
        set { self[PanelControllerKey.self] = newValue }
    }

    var optionsRequest: Binding<Bool>? {
        get { self[OptionsRequestKey.self] }
        set { self[OptionsRequestKey.self] = newValue }
    }

    var canvasSelections: CanvasSelectionHub? {
        get { self[CanvasSelectionsKey.self] }
        set { self[CanvasSelectionsKey.self] = newValue }
    }
}

// MARK: - Main menu (Commands)

//
// Struktura zgodna z Docs/ui/menu-spec.md.
// Wyszarzone (.disabled(true)) pozycje: Faza 2 USB, funkcje wymagające PatchCanvasView selection
// (do podłączenia po recovery — patrz Docs/context/bug-history.md #WF-1).

struct MainMenuCommands: Commands {
    @FocusedValue(\.patchState) private var focusedState: PatchState?
    @FocusedValue(\.canvasViewState) private var focusedCanvas: CanvasViewState?
    @FocusedBinding(\.fileOpenRequest) var fileOpen: Bool?
    @FocusedValue(\.openIntoSlotRequest) private var focusedOpenIntoSlot: Binding<Int?>?
    @FocusedValue(\.deviceConnection) private var focusedDevice: DeviceConnection?
    @FocusedValue(\.panelController) private var focusedPanels: PanelController?
    @FocusedBinding(\.optionsRequest) var showOptions: Bool?
    @FocusedValue(\.canvasSelections) private var focusedSelections: CanvasSelectionHub?

    /// Zakładki slotów B–D to okna AppKit: podają stan przez `focusedValue`, a ten dochodzi
    /// do menu tylko wtedy, gdy w oknie coś ma fokus klawiatury. Klik w kanwę go nie daje,
    /// więc w zakładce B menu dostawało nil i np. View ▸ Slot Layout stało szare — wracało
    /// dopiero w zakładce A (zgłoszenie użytkownika 2026-09-24). Wtedy stan bierzemy
    /// wprost z okna kluczowego (`SlotWindows.keyWindowContext`).
    private var fallback: SlotWindows.KeyWindowContext? {
        SlotWindows.shared.keyWindowContext
    }

    var state: PatchState? { focusedState ?? fallback?.context.state }
    var canvas: CanvasViewState? { focusedCanvas ?? fallback?.context.viewState }
    var openIntoSlot: Binding<Int?>? { focusedOpenIntoSlot ?? fallback?.openIntoSlot }
    var device: DeviceConnection? { focusedDevice ?? fallback?.context.device }
    var panels: PanelController? { focusedPanels ?? fallback?.context.panels }
    var selections: CanvasSelectionHub? { focusedSelections ?? fallback?.selections }

    var body: some Commands {
        // Karta powitalna (logo, Ko-fi, noty) zamiast systemowego okienka „About".
        CommandGroup(replacing: .appInfo) {
            Button("About Cube G2 Editor") { SplashWindow.show() }
            Button("Check for Updates…") { AppUpdates.shared.checkNow() }
        }

        // „Setup ▸ Options" oryginału (str. 125). Na macOS to samo okno wisi tam,
        // gdzie system każe go szukać: w menu aplikacji, pod ⌘,.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { showOptions = true }
                .keyboardShortcut(",", modifiers: [.command])
                .disabled(showOptions == nil)
        }

        // File — zastępujemy domyślne SwiftUI New/Open
        CommandGroup(replacing: .newItem) {
            FileMenuNewButton(state: state, device: device, kind: .patch)
            FileMenuOpenButton(fileOpen: $fileOpen)
            RecentFilesMenu(state: state, device: device)

            Divider()

            // Oba podmenu wiszą u Clavii na `GetTopPerformance()`; u nas sloty są zawsze cztery,
            // więc działają zawsze, a do Norda jedzie tylko wskazany slot.
            SlotTargetMenu(title: "New To", state: state) { slot in
                guard let state, UnsavedChangesGuard.shared.confirmDiscard(slot: slot) else { return }
                state.newPatch(inSlot: slot)
                guard let device else { return }
                Task { await device.send(state, onlyFocusedSlot: true) }
            }
            SlotTargetMenu(title: "Open To", state: state) { slot in
                openIntoSlot?.wrappedValue = slot
                fileOpen = true
            }
            // Cały patch z pliku jako Building Block — to samo, co przeciągnięcie `.pch2` na kanwę.
            Button("Insert Patch File…") {
                guard let state else { return }
                BuildingBlockInsert.insertFile(into: state, selections: selections)
            }
            .disabled(state?.isLoaded != true)

            Divider()

            FileMenuSaveButton(state: state)
            FileMenuSaveAsButton(state: state)
            // „Save From ▸ Slot X" (str. 116): kopia jednego slotu jako osobny `.pch2`,
            // bez ruszania pliku, do którego slot należy.
            SlotTargetMenu(title: "Save From", state: state) { slot in
                guard let state else { return }
                guard let url = FilePanels.saveURL(
                    name: state.slots.indices.contains(slot) ? state.slots[slot].name : "Patch",
                    extension: "pch2"
                ) else { return }
                state.saveSlot(slot, to: url)
            }

            // „Save InitPatch1 & 2" (str. 116) — dwa szablony pod przyciskami „Init"
            // w pasku narzędzi.
            Menu("Save Init Patch") {
                ForEach(InitPatchLibrary.slots, id: \.self) { slot in
                    Button("Init \(slot)") { state?.saveInitPatch(slot: slot) }
                }
            }
            .disabled(state?.isLoaded != true)

            Button("Save Patch as SysEx") {}
                .disabled(true) // Faza 2 USB
            // „Save Patch as FXP" USUNIĘTE 2026-09-11: `.fxp` to preset wtyczki VST
            // BVerhue, która istnieje wyłącznie na Windows. Bez własnej wtyczki ten
            // plik nie ma czego otworzyć → [[Docs/roadmap]].

            Divider()

            FileMenuNewButton(state: state, device: device, kind: .performance)
            // Ten sam picker co Open — akceptuje `.pch2` i `.prf2`. Oryginał ma osobne
            // okno wyboru performance'ów; u nas rozstrzyga rozszerzenie pliku.
            Button("Load Performance…") { fileOpen = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(fileOpen == nil)
            FileMenuSavePerfButton(state: state)
            Button("Save Performance as SysEx") {}
                .disabled(true) // Faza 2
        }

        // Edit — trzy grupy naraz, patrz `EditMenuCommands`. Osobno się nie zmieszczą:
        // `CommandsBuilder` przyjmuje najwyżej dziesięć członów w jednym `body`.
        EditMenuCommands(state: state, canvas: canvas, selections: selections)

        // View — patrz `ViewMenuCommands`.
        ViewMenuCommands(state: state, canvas: canvas, panels: panels)

        // Patch — Clavia menu
        CommandMenu("Patch") {
            Button("Patch Settings") { state?.showPatchSettings = true }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(state == nil)
            Button("Notes (Textpad)") { state?.showPatchNotes = true }
                .keyboardShortcut("j", modifiers: [.command])
                .disabled(state == nil)

            Divider()

            DeleteUnusedModulesButton(state: state, canvas: canvas)

            Divider()

            // Cały patch slotu z focusem jeszcze raz do G2. Bez okna wyboru slotu z oryginału:
            // u nas slot edytora i urządzenia to ta sama liczba. To też droga ratunkowa po
            // patchu, którego G2 nie przyjął (#143) — poprawiona notatka sama do Norda nie jedzie.
            Button("Download To Slot") {
                guard let state, let device else { return }
                Task { await device.send(state, onlyFocusedSlot: true) }
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(state == nil || device?.status != .connected)
        }

        // Performance — Clavia menu + Slot switching
        CommandMenu("Performance") {
            // Sekcja 0x11 istnieje tylko w plikach .prf2 — dla patcha nie ma czego pokazać.
            Button("Performance Settings") { state?.showPerformanceSettings = true }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!(state?.hasPerformanceSettings ?? false))

            PerformanceModeButton(device: device)

            Divider()

            Button("Download") {}
                .disabled(true) // Faza 2

            Divider()

            SlotSwitchButton(state: state, index: 0, label: "Slot: A", shortcut: "1")
            SlotSwitchButton(state: state, index: 1, label: "Slot: B", shortcut: "2")
            SlotSwitchButton(state: state, index: 2, label: "Slot: C", shortcut: "3")
            SlotSwitchButton(state: state, index: 3, label: "Slot: D", shortcut: "4")
        }

        // Synth — Clavia menu
        CommandMenu("Synth") {
            // Ustawienia samego urządzenia — pozycja zapala się dopiero, gdy Nord odpowie
            // na `0x02`: w pliku patcha ani performance'u tych pól NIE MA.
            SynthSettingsButton(state: state, device: device)
            Button("Upload Active Slot") {}
                .keyboardShortcut("u", modifiers: [.command])
                .disabled(true) // Faza 2
            Button("Save In Synth…") {}
                .disabled(true) // Faza 2

            Divider()

            // U Clavii „Bank Upload / Bank Download” z punktu widzenia Norda — u nas
            // odwrotnie, z punktu widzenia komputera (decyzja użytkownika 2026-10-13).
            // Działa też z wirtualnym G2 — jego flash ma bank fabryczny (krok 2 bank-dump).
            Button("Download Banks from G2…") { state?.showBankUpload = true }
                .disabled(device?.status != .connected || device?.bankEntries.isEmpty != false)
            Button("Upload Banks to G2…") {}.disabled(true) // Faza 2

            Divider()

            Button("Send Controller Snapshot") {}
                .disabled(true) // Faza 2 (skrót ⌘M zajęty przez Minimize Window)
            Button("Dump One") {}
                .keyboardShortcut("1", modifiers: [.command, .shift])
                .disabled(true) // Faza 2
        }

        // Tools — narzędzia pracujące PRZY patchu. Wszystkie mieszkają w pływających
        // oknach, więc menu jest listą przełączników tych okien; ta sama kolejność,
        // co przyciski w górnej belce.
        CommandMenu("Tools") {
            // „Deassign All MIDI" (instrukcja, str. 130). Dwa polecenia obok niego
            // („…to Selection", „…from Selection") działają na zaznaczeniu, więc siedzą
            // w menu pod prawym przyciskiem nad modułem.
            Button("Deassign All MIDI") { state?.clearAllMidiControllers() }
                .disabled(state?.isLoaded != true)

            Divider()

            SidePanelMenu(panels: panels, shown: [
                .parameterPages, .parameterOverview, .patchAdjuster,
                .mutator, .keyboard, .colors, .spectrogram, .xyPlot, .dsp,
            ])

            Divider()

            VirtualDeviceButton(device: device)

        }

        // Help — nasze
        CommandGroup(replacing: .help) {
            Button("G2 Editor Documentation") {}.disabled(true)
            Button("BVerhue Reference") {}.disabled(true)
            Button("Nord Modular G2 Manual") {}.disabled(true)
        }
    }
}

// MARK: - View

/// Menu View w całości. Musi być `CommandGroup(replacing: .sidebar)`, a NIE
/// `CommandMenu("View")`: SwiftUI zakłada własne menu View i przy `CommandMenu` w pasku
/// stały DWA menu o tej samej nazwie. Podmiana grupy `.sidebar` wkłada nasze pozycje do
/// tego jedynego, systemowego menu.
///
/// Grupy `.toolbar` NIE ruszamy: aplikacja nie ma `NSToolbar`, więc system i tak nic tam
/// nie wstawia, a `CommandGroup(replacing: .toolbar) {}` zostawiał na szczycie menu pustą
/// kreskę oddzielającą.
private struct ViewMenuCommands: Commands {
    let state: PatchState?
    let canvas: CanvasViewState?
    let panels: PanelController?

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            ZoomMenuButton(canvas: canvas, kind: .zoomIn)
            ZoomMenuButton(canvas: canvas, kind: .zoomOut)
            ZoomMenuButton(canvas: canvas, kind: .actualSize)
            ZoomToFitMenuButton(canvas: canvas, state: state)

            Divider()

            // Szuflady lewej krawędzi. Narzędzia pracujące przy patchu (strony
            // parametrów, mutator, adjuster, klawiatura, paleta kolorów, DSP Load)
            // przeniosły się 2026-09-11 do menu Tools.
            SidePanelMenu(panels: panels, shown: [.modules, .banks])
            SidebarModeMenu()
            ExtendedToolbarToggle()
            PanelShadingToggle()
            SlotLayoutMenu(state: state)
            DragLoadToggle()

            Divider()

            OverlayMenu(canvas: canvas)

            Divider()

            CablesMenu(canvas: canvas)
            // Bez skrótu: Space obsługuje „rączkę" (pan) nad canvasem — patrz CanvasZoomPanNSView.
            Button("Shake Cables") { canvas?.shakeCables() }
                .disabled(canvas == nil)
        }
    }
}

// MARK: - Widoki komend reagujące na stan @Observable

/// New Patch czyści slot z focusem, New Performance czyści wszystkie cztery. Pusty patch idzie od razu do Norda, tak
/// jak u BVerhue (`aInitPatchExecute` / `aInitPerfExecute`); bez podłączonego urządzenia
/// `send` cicho odmawia.
private struct FileMenuNewButton: View {
    enum Kind {
        case patch, performance
    }

    let state: PatchState?
    let device: DeviceConnection?
    let kind: Kind

    var body: some View {
        Button(title) {
            let guardian = UnsavedChangesGuard.shared
            guard let state else { return }
            switch kind {
            case .patch:
                guard guardian.confirmDiscard(slot: state.selectedSlot) else { return }
                state.newPatch()
            case .performance:
                guard guardian.confirmDiscard() else { return }
                state.newPerformance()
            }
            guard let device else { return }
            Task { await device.send(state, onlyFocusedSlot: kind != .performance, followDocument: true) }
        }
        .keyboardShortcut("n", modifiers: modifiers)
        .disabled(state == nil)
    }

    private var title: String {
        switch kind {
        case .patch: "New Patch"
        case .performance: "New Performance"
        }
    }

    private var modifiers: EventModifiers {
        switch kind {
        case .patch: [.command]
        case .performance: [.command, .shift]
        }
    }
}

/// „New To ▸", „Open To ▸" i „Save From ▸" — cztery sloty. Oryginał trzyma numer slotu
/// w `CRange<0…3>`, więc podmenu ma zawsze cztery pozycje, także tę, którą właśnie oglądamy.
private struct SlotTargetMenu: View {
    let title: String
    let state: PatchState?
    let action: (Int) -> Void

    private static let labels = ["A", "B", "C", "D"]

    var body: some View {
        Menu(title) {
            ForEach(Self.labels.indices, id: \.self) { slot in
                Button("Slot \(Self.labels[slot])") { action(slot) }
            }
        }
        .disabled(state == nil)
    }
}

private struct FileMenuOpenButton: View {
    @Binding var fileOpen: Bool?

    var body: some View {
        Button("Open Patch…") { fileOpen = true }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(fileOpen == nil)
    }
}

/// Save — patch slotu z focusem do jego `.pch2`; slot bez pliku pyta najpierw o miejsce,
/// jak `CPatch::SavePatch` u Clavii.
private struct FileMenuSaveButton: View {
    let state: PatchState?

    var body: some View {
        Button("Save") {
            guard let state else { return }
            SaveActions.save(state)
        }
        .keyboardShortcut("s", modifiers: [.command])
        .disabled(state?.isLoaded != true)
    }
}

/// „Save As" (str. 116) — okno zapisu, a potem plik staje się plikiem slotu z focusem.
/// Działa też dla slotu bez pliku źródłowego: nowy patch i zawartość odczytana z Norda
/// dostają szkielet z `PatchParser`.
private struct FileMenuSaveAsButton: View {
    let state: PatchState?

    var body: some View {
        Button("Save As…") {
            guard let state else { return }
            SaveActions.saveAs(state)
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])
        .disabled(state?.isLoaded != true)
    }
}

/// „Delete Unused Modules" (str. 119) — moduły bez jednego kabla w oglądanym obszarze.
/// Wyszarzone, gdy nie ma czego kasować, żeby nie trzeba było zgadywać.
private struct DeleteUnusedModulesButton: View {
    let state: PatchState?
    let canvas: CanvasViewState?

    var body: some View {
        let area = canvas?.selectedArea ?? .voice
        let count = state?.unusedModuleIDs(area: area).count ?? 0
        Button(count > 0 ? "Delete Unused Modules (\(count))" : "Delete Unused Modules") {
            state?.deleteUnusedModules(area: area)
        }
        .disabled(count == 0)
    }
}

/// „Recent files" (str. 116) — dziesięć ostatnio otwartych plików. Wybór działa
/// jak zwykłe Open: plik wchodzi do edytora i od razu leci do Norda.
private struct RecentFilesMenu: View {
    let state: PatchState?
    let device: DeviceConnection?

    var body: some View {
        let files = RecentFiles.urls
        Menu("Open Recent") {
            ForEach(files, id: \.self) { url in
                Button(url.lastPathComponent) {
                    guard let state, UnsavedChangesGuard.shared.confirmDiscard(opening: url) else { return }
                    let onlySlot = state.load(url: url)
                    guard state.errorMessage == nil, let device else { return }
                    Task { await device.send(state, onlyFocusedSlot: onlySlot, followDocument: true) }
                }
            }
            if !files.isEmpty {
                Divider()
                Button("Clear Menu") { RecentFiles.clear() }
            }
        }
        .disabled(files.isEmpty || state == nil)
    }
}

/// Save Performance — cztery sloty i nagłówek do `.prf2`; bez pliku pyta o miejsce,
/// jak `CPerformanceManager::SavePerformance` u Clavii.
private struct FileMenuSavePerfButton: View {
    let state: PatchState?

    var body: some View {
        Button("Save Performance") {
            guard let state else { return }
            SaveActions.savePerformance(state)
        }
        .disabled(state?.isLoaded != true)
    }
}

/// Tryb urządzenia: Performance (cztery sloty razem) albo Patch (gra jeden).
/// Komenda `0x3E`; stan czytamy przy łączeniu → [[Docs/usb/slots]].
/// „Synth Settings…" — osobny widok, żeby obserwacja `DeviceConnection` działała:
/// `Commands` nie przelicza się od zmiany pola `@Observable`, widok tak.
private struct SynthSettingsButton: View {
    let state: PatchState?
    let device: DeviceConnection?

    var body: some View {
        Button("Synth Settings…") { state?.showSynthSettings = true }
            .keyboardShortcut("g", modifiers: [.command])
            .disabled(device?.synthSettings == nil)
    }
}

private struct PerformanceModeButton: View {
    let device: DeviceConnection?

    var body: some View {
        Toggle("Performance Mode", isOn: Binding(
            get: { device?.performanceMode == true },
            set: { on in
                guard let device else { return }
                Task { await device.setPerformanceMode(on) }
            }
        ))
        .disabled(device?.status != .connected)
    }
}

/// Wirtualny G2 — pozycja, która go włącza i wyłącza, i przełącznik startu samoczynnego
/// (gdy nie ma Norda; zasady i dawne powody przeciw — w `VirtualDeviceLauncher`).
///
/// Pozycji nie ma wcale, gdy na tym komputerze nie ma programu wirtualnego G2 — tak
/// wygląda wersja publiczna. Przy podłączonym Nordzie pozycja jest szara — sprzęt
/// i tak wygrywa, więc wirtualny G2 byłby uruchomiony po nic.
private struct VirtualDeviceButton: View {
    let device: DeviceConnection?

    var body: some View {
        let launcher = VirtualDeviceLauncher.shared
        let connected = device?.status == .connected
        let hardware = connected && device?.isVirtualDevice == false
        // Wirtualny G2, którego NIE uruchomił edytor — uruchomiony z terminala albo inny
        // program na tym samym gnieździe. Nie mamy czego zatrzymać, a start
        // i tak by się nie udał: gniazdo jest zajęte.
        let foreign = connected && device?.isVirtualDevice == true && !launcher.isRunning
        if launcher.isRunning || VirtualDeviceLauncher.binaryURL != nil {
            Button(launcher.isRunning ? "Stop Virtual G2" : "Start Virtual G2") {
                if launcher.isRunning { launcher.stop() } else { launcher.start() }
            }
            .disabled(!launcher.isRunning && (hardware || foreign))
            .help(helpText(launcher: launcher, hardware: hardware, foreign: foreign))
            Toggle("Start Virtual G2 Automatically", isOn: $automatic)
                .help("Starts the virtual G2 when no Nord G2 is plugged in. A Nord plugged in later takes over.")
            // Opis stoi w podmenu POD wyborem, a nie w dymku: dymek pozycji menu macOS
            // kładzie sam, obok, i zasłaniał nim oba wybory (zgłoszenie 2026-09-25).
            Menu("Virtual G2 DSPs") {
                Picker("Virtual G2 DSPs", selection: Binding(
                    get: { VirtualDeviceLauncher.dspCountChoices.contains(dspCount) ? dspCount : 8 },
                    set: { launcher.setDSPCount($0) }
                )) {
                    Text("4 DSPs (no Expansion Board)").tag(4)
                    Text("8 DSPs (with Expansion Board)").tag(8)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Text("4 DSPs use about half as much of the Mac's CPU,")
                Text("but large patches will not fit.")
                Text("Changing this restarts the virtual G2.")
            }
        }
    }

    @AppStorage(VirtualDeviceLauncher.autoStartKey) private var automatic = true
    @AppStorage(VirtualDeviceLauncher.dspCountKey) private var dspCount = 8

    private func helpText(launcher: VirtualDeviceLauncher, hardware: Bool, foreign: Bool) -> String {
        if launcher.isRunning {
            return "Stops the virtual G2. The editor goes back to looking for real hardware."
        }
        if hardware {
            return "A real Nord G2 is connected — hardware always wins, so the virtual one would be ignored."
        }
        if foreign {
            return "A virtual G2 is already running. The editor did not start it, so it cannot stop it either."
        }
        return "Starts a software G2 so the editor has something to talk to without hardware. "
            + "It boots for a few seconds, plays through the Mac's audio output and takes notes from "
            + "any MIDI keyboard — but it answers the way this editor expects, so it proves nothing "
            + "about a real Nord. It uses a lot of CPU while running."
    }
}


/// Zoom In / Zoom Out / Actual Size. Wyszarza się na krańcach zakresu (0.25–8.0).
private struct ZoomMenuButton: View {
    enum Kind {
        case zoomIn, zoomOut, actualSize
    }

    let canvas: CanvasViewState?
    let kind: Kind
    @AppStorage("standardZoom") private var standardZoom: Double = 2.0

    var body: some View {
        let zoom = canvas?.clampedZoom
        Button(title) {
            guard let canvas else { return }
            switch kind {
            case .zoomIn: canvas.zoomIn()
            case .zoomOut: canvas.zoomOut()
            case .actualSize: canvas.requestZoom(CGFloat(standardZoom))
            }
        }
        .keyboardShortcut(shortcut, modifiers: [.command])
        .disabled(isDisabled(zoom: zoom))
    }

    private var title: String {
        switch kind {
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .actualSize: "Actual Size"
        }
    }

    private var shortcut: KeyEquivalent {
        switch kind {
        case .zoomIn: "="
        case .zoomOut: "-"
        case .actualSize: "0"
        }
    }

    private func isDisabled(zoom: CGFloat?) -> Bool {
        guard let zoom else { return true }
        switch kind {
        case .zoomIn: return zoom >= CanvasViewState.maxZoom
        case .zoomOut: return zoom <= CanvasViewState.minZoom
        case .actualSize: return false
        }
    }
}

/// Zoom to Fit — potrzebuje modułów bieżącego obszaru, więc czyta oba stany naraz.
private struct ZoomToFitMenuButton: View {
    let canvas: CanvasViewState?
    let state: PatchState?

    var body: some View {
        Button("Zoom to Fit") {
            guard let canvas, let state else { return }
            let modules = state.patch.modules(in: canvas.selectedArea)
            guard !modules.isEmpty else { return }
            let rowOffset = PatchLayout.minRow(modules: modules)
            let contentSize = PatchLayout.canvasSize(
                modules: modules,
                defs: { ModuleDatabase.module(id: $0) },
                rowOffset: rowOffset
            )
            canvas.zoomToFit(contentSize: contentSize)
        }
        .keyboardShortcut("0", modifiers: [.command, .shift])
        .disabled(canvas == nil || state?.isLoaded != true)
    }
}

/// Żółte dymki nad kontrolkami — F5…F8 z instrukcji (str. 132). Ten sam klawisz
/// je gasi; skrót obsługuje `EditorKeyboardShortcuts`, tu jest tylko po to, żeby
/// dało się je znaleźć bez tabeli skrótów.
private struct OverlayMenu: View {
    let canvas: CanvasViewState?

    var body: some View {
        Menu("Show On Controls") {
            ForEach(CanvasOverlayMode.allCases, id: \.self) { mode in
                let selected = canvas?.overlayMode == mode
                Button {
                    canvas?.overlayMode = mode
                } label: {
                    if let key = mode.functionKey {
                        Text(selected ? "✓ \(mode.title)  (F\(key))" : "\(mode.title)  (F\(key))")
                    } else {
                        Text(selected ? "✓ \(mode.title)" : mode.title)
                    }
                }
            }
        }
        .disabled(canvas == nil)
    }
}

/// Widoczność kabli — „ptaszek" oznacza kolor widoczny.
private struct CablesMenu: View {
    let canvas: CanvasViewState?

    var body: some View {
        Menu("Cables") {
            Button("Show All") { canvas?.showAllCables() }
            Button("Hide All") { canvas?.hideAllCables() }

            Divider()

            ForEach(CableColor.allCases, id: \.self) { color in
                let isVisible = canvas?.isCableColorVisible(color) ?? false
                Toggle(color.displayName, isOn: Binding(
                    get: { isVisible },
                    set: { _ in canvas?.toggleCableColor(color) }
                ))
            }
        }
        .disabled(canvas == nil)
    }
}

/// Pasek z obciążeniem pod modułem chwyconym z palety — da się wyłączyć, bo przy
/// szybkim układaniu patcha bywa tylko zasłoną.
private struct DragLoadToggle: View {
    @AppStorage("g2_show_drag_load") private var showDragLoad: Bool = true

    var body: some View {
        Toggle("Show Load When Dragging Modules", isOn: $showDragLoad)
    }
}

/// Wypukłe przyciski i wgłębione ekrany na modułach (`Bevel`) — dla lubiących płaski panel.
/// Podglądy w palecie modułów trzeba przy tym przerysować, bo leżą w pamięci podręcznej.
private struct PanelShadingToggle: View {
    @AppStorage(PanelShading.storageKey) private var panelShading = true

    var body: some View {
        Toggle("3D Buttons and Screens", isOn: $panelShading)
            .onChange(of: panelShading) { ModulePreviewCache.shared.redraw() }
    }
}

/// „Extended Toolbar {Ctrl-T}" z instrukcji (str. 130): chowa dolną część paska
/// narzędzi — nazwę patcha, kategorię, tryb głosów, poziom i pasek morfów.
private struct ExtendedToolbarToggle: View {
    @AppStorage("g2_extended_toolbar") private var extendedToolbar: Bool = true

    var body: some View {
        Toggle("Extended Toolbar", isOn: $extendedToolbar)
            .keyboardShortcut("t", modifiers: [.command])
    }
}

/// View ▸ Slot Layout — jeden pas albo okna slotów (`SlotLayout.menuCases`).
/// Zwykły patch ma jeden slot, więc bez performance'u menu jest wyszarzone: każdy
/// z układów wyglądałby wtedy tak samo.
private struct SlotLayoutMenu: View {
    let state: PatchState?
    @AppStorage(SlotLayout.storageKey) private var layoutRaw = SlotLayout.single.rawValue

    var body: some View {
        Menu("Slot Layout") {
            ForEach(SlotLayout.menuCases, id: \.self) { layout in
                Toggle(layout.title, isOn: Binding(
                    get: { layoutRaw == layout.rawValue },
                    set: { _ in layoutRaw = layout.rawValue }
                ))
                .keyboardShortcut(KeyEquivalent(layout.shortcutKey), modifiers: [.command, .option])
            }
        }
        .disabled(state == nil)
    }
}

private struct SidebarModeMenu: View {
    @AppStorage("sidebarViewMode") private var mode = "compact"

    var body: some View {
        Menu("Sidebar Mode") {
            Toggle("Compact", isOn: Binding(
                get: { mode == "compact" }, set: { _ in mode = "compact" }
            ))
            Toggle("Expanded", isOn: Binding(
                get: { mode == "expanded" }, set: { _ in mode = "expanded" }
            ))
        }
    }
}

/// Przełączniki paneli — te same, co przyciski w pasku narzędzi, bo skrót ma otwierać
/// i zamykać tak samo jak mysz (zasada 0.3 planu: wszystko nowe dostaje skrót
/// klawiszowy). Menu View trzyma szuflady, menu Tools resztę.
private struct SidePanelMenu: View {
    let panels: PanelController?
    /// Które panele ma pokazać to menu — kolejność jest kolejnością pozycji.
    let shown: [PanelController.Panel]

    var body: some View {
        // `Toggle`, nie `Label(…, systemImage: "checkmark")`: na macOS 15.7 ikona `Label`
        // w ogóle nie trafia do `NSMenuItem`, więc ptaszka nie było widać. `Toggle`
        // ustawia `NSMenuItem.state`, czyli systemowy ptaszek — działa na każdej wersji
        // → [[Docs/context/bug-history]] #81.
        ForEach(shown) { panel in
            Toggle(panel.title, isOn: Binding(
                get: { panels?.isOpen(panel) == true },
                set: { _ in panels?.toggle(panel) }
            ))
            .keyboardShortcut(KeyEquivalent(panel.shortcutKey), modifiers: [.command, .option])
            .disabled(panels == nil)
        }
    }
}

private struct SlotSwitchButton: View {
    let state: PatchState?
    let index: Int
    let label: String
    let shortcut: KeyEquivalent

    init(state: PatchState?, index: Int, label: String, shortcut: String) {
        self.state = state
        self.index = index
        self.label = label
        self.shortcut = KeyEquivalent(Character(shortcut))
    }

    var body: some View {
        let isActive = state?.selectedSlot == index
        Button(isActive ? "✓ \(label)" : label) {
            state?.selectedSlot = index
        }
        .keyboardShortcut(shortcut, modifiers: [.command])
        .disabled(state == nil)
    }
}

// MARK: - Edit

/// Menu Edit w całości. Domyślne pozycje SwiftUI były tu martwe: Undo/Redo celują
/// w `UndoManager` okna, a nasz stos undo siedzi w `PatchState`; Cut/Copy/Paste/Delete/
/// Select All szukają w łańcuchu respondera kogoś, kto je zna, a kanwa jest widokiem
/// SwiftUI i nikim takim nie jest. Obie grupy podmieniamy na własne.
private struct EditMenuCommands: Commands {
    let state: PatchState?
    let canvas: CanvasViewState?
    let selections: CanvasSelectionHub?

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            UndoMenuButton(state: state, redo: false)
            UndoMenuButton(state: state, redo: true)
        }

        CommandGroup(replacing: .pasteboard) {
            EditPasteboardCommands(state: state, canvas: canvas, selections: selections)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            // „Copy Variation" kopiuje CAŁY zestaw wartości oglądanej wariacji do innej —
            // to samo polecenie ma pasek wariacji pod prawym przyciskiem myszy.
            CopyVariationMenu(state: state)
        }
    }
}

/// Undo / Redo naszego stosu. `UndoManager` z `PatchState` nie jest tym, który system
/// podsuwa oknu, więc systemowe pozycje Edit ▸ Undo były trwale szare — mimo że ⌘Z
/// działało (ContentView trzymał niewidzialny przycisk ze skrótem).
///
/// Nazwa czynności („Undo Change Parameter") jest tym, co rejestruje `setActionName`
/// przy każdej operacji — dzięki temu z menu widać, co dokładnie się cofnie.
private struct UndoMenuButton: View {
    let state: PatchState?
    let redo: Bool

    var body: some View {
        // Odczyt licznika wiąże pozycję z historią undo — bez niego tytuł i wyszarzenie
        // zostawały na stanie sprzed kilku operacji (patrz `PatchState.undoRevision`).
        let _ = state?.undoRevision
        let manager = state?.undoManager
        let possible = redo ? (manager?.canRedo ?? false) : (manager?.canUndo ?? false)
        let name = redo ? (manager?.redoActionName ?? "") : (manager?.undoActionName ?? "")
        Button(title(name: name, possible: possible)) {
            if redo { manager?.redo() } else { manager?.undo() }
        }
        .keyboardShortcut("z", modifiers: redo ? [.command, .shift] : [.command])
        .disabled(!possible)
    }

    private func title(name: String, possible: Bool) -> String {
        let verb = redo ? "Redo" : "Undo"
        guard possible, !name.isEmpty else { return verb }
        return "\(verb) \(name)"
    }
}

/// Cut / Copy / Paste / Delete / Select All dla modułów na kanwie.
///
/// Każda pozycja NAJPIERW podaje polecenie łańcuchowi respondera i dopiero gdy nikt go
/// nie przyjął, robi swoje. Bez tego ⌘C w polu nazwy patcha przestałoby kopiować tekst:
/// skróty menu wyprzedzają pole tekstowe, więc pozycja menu musi umieć oddać mu ruch.
///
/// Wszystkie zostają CZYNNE, dopóki jest wczytany patch — także przy pustym zaznaczeniu.
/// Szara pozycja menu połyka swój skrót i nie oddaje go dalej, więc wyszarzone „Copy"
/// zabrałoby kopiowanie tekstu w polu nazwy.
private struct EditPasteboardCommands: View {
    let state: PatchState?
    let canvas: CanvasViewState?
    let selections: CanvasSelectionHub?

    var body: some View {
        Button("Cut") { forward(#selector(NSText.cut(_:))) { cut() } }
            .keyboardShortcut("x", modifiers: [.command])
            .disabled(state?.isLoaded != true)

        Button("Copy") { forward(#selector(NSText.copy(_:))) { copy() } }
            .keyboardShortcut("c", modifiers: [.command])
            .disabled(state?.isLoaded != true)

        Button("Paste") { forward(#selector(NSText.paste(_:))) { paste() } }
            .keyboardShortcut("v", modifiers: [.command])
            .disabled(state?.isLoaded != true)

        // Bez skrótu: ⌫ jako skrót menu wyprzedziłby KAŻDE pole tekstowe w oknie
        // i zamiast kasować znak, kasowałby moduły.
        Button("Delete", role: .destructive) { forward(#selector(NSText.delete(_:))) { delete() } }
            .disabled(state?.isLoaded != true)

        Divider()

        Button("Select All") { forward(#selector(NSText.selectAll(_:))) { selectAll() } }
            .keyboardShortcut("a", modifiers: [.command])
            .disabled(state?.isLoaded != true)

        Divider()

        // Bez skrótu, więc wygaszenie przy pustym zaznaczeniu niczego nie połyka.
        Button("Save Selection as Block…") {
            guard let state, let selection else { return }
            BuildingBlockSave.save(from: state, area: area, moduleIDs: selection.targets)
        }
        .disabled(state?.isLoaded != true || selection?.isEmpty != false)
    }

    /// `sendAction` zwraca `false`, gdy nikt w łańcuchu respondera polecenia nie zna —
    /// wtedy i tylko wtedy zajmuje się nim kanwa.
    private func forward(_ selector: Selector, otherwise action: () -> Void) {
        guard !NSApp.sendAction(selector, to: nil, from: nil) else { return }
        action()
    }

    private var area: PatchArea {
        canvas?.selectedArea ?? .voice
    }

    private var selection: CanvasSelection? {
        selections?.selection(for: area)
    }

    private func copy() {
        guard let state, let selection else { return }
        let area = area
        guard let content = G2ClipboardContent.make(modules: state.patch.modules(in: area),
                                                    cables: state.patch.cables(in: area),
                                                    ids: selection.targets,
                                                    labels: state.patch.moduleLabels(in: area)) else { return }
        content.writeToPasteboard()
    }

    private func cut() {
        copy()
        delete()
    }

    private func paste() {
        guard let state, let content = G2ClipboardContent.readFromPasteboard() else { return }
        state.pasteModules(content, area: area)
    }

    private func delete() {
        guard let state, let selection else { return }
        let targets = selection.targets
        guard !targets.isEmpty else { return }
        state.deleteModules(moduleIDs: targets, area: area)
        selection.clear()
    }

    private func selectAll() {
        guard let state, let selection else { return }
        selection.moduleIDs = Set(state.patch.modules(in: area).map(\.id))
        selection.activeID = nil
    }
}

/// „Copy Variation" — cały zestaw wartości oglądanej wariacji do jednej z ośmiu
/// pozostałych albo do wariacji Init (instrukcja, str. 61).
private struct CopyVariationMenu: View {
    let state: PatchState?

    var body: some View {
        let active = state?.patch.activeVariation ?? 0
        Menu("Copy Variation") {
            ForEach(0 ..< 8, id: \.self) { variation in
                Button("To Variation \(variation + 1)") {
                    state?.copyVariation(from: active, to: variation)
                }
                .disabled(variation == active)
            }
            Divider()
            Button("To Variation Init") {
                state?.copyVariation(from: active, to: G2Patch.initVariation)
            }
        }
        .disabled(state?.isLoaded != true)
    }
}
