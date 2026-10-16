// SidePanels.swift
// Warstwa widoku systemu paneli — punkt 0.1 planu udoskonaleń. Reguły (co jest szufladą,
// a co oknem, wysunięta jedna szuflada, zapamiętane szerokości) siedzą w `PanelController`;
// tutaj jest wyłącznie to, co widać.
//
// Dwie części:
//   • `PanelBody`   — nagłówek (tytuł, zamknij) i treść jednego panelu,
//   • `DrawerPanel` — `PanelBody` przy lewej krawędzi plus uchwyt do zmiany szerokości.
//
// Przyciski, którymi się to otwiera, siedzą w pasku narzędzi (`ContentView.toolbar`):
// szuflady z lewej strony paska, okna z prawej. Okna prowadzi `PanelWindows` (AppKit).
//
// Biblioteka modułów jest szufladą, ale nie przechodzi przez `PanelContent`: niesie ze
// sobą obsługę przeciągania na canvas i sama zna swoją szerokość (zależy od trybu
// listy), więc `ContentView` stawia ją wprost.

import G2Core
import G2EditorCore
import SwiftUI

// MARK: - Co panel dostaje z aplikacji

/// Wszystko, czego mogą potrzebować treści paneli, w jednej paczce. Bez tego każdy nowy
/// panel dokłada parametr do `PanelBody`, `DrawerPanel` i okna naraz.
struct PanelContext {
    let state: PatchState
    let device: DeviceConnection
    let library: DiskBankLibrary
    /// Stan widoku canvasu i żądanie otwarcia pliku — panel w osobnym oknie musi je
    /// podać menu głównemu, patrz `PanelBody.body`.
    let viewState: CanvasViewState
    let fileOpenRequest: Binding<Bool>
    let panels: PanelController
    /// Caps Lock → litery grają nuty; żyje na poziomie aplikacji, okno klawiatury tylko
    /// je rysuje (patrz `MusicalTyping`).
    let typing: MusicalTyping
    /// Otwarcie pliku patcha — tą samą drogą co File → Open.
    let onOpenFile: (URL) -> Void
}

// MARK: - Panel: nagłówek + treść

struct PanelBody: View {
    @Bindable var panels: PanelController
    let panel: PanelController.Panel
    let context: PanelContext
    /// Panel w oknie ma własny pasek tytułu, więc nie potrzebuje nagłówka.
    var showsHeader = true

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                Divider()
            }
            PanelContent(panel: panel, context: context)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Panele w osobnych oknach są oknami AppKit, więc nie należą do sceny SwiftUI
        // i `focusedSceneValue` z `ContentView` do nich nie sięga. Bez tego kliknięcie
        // w panel wyszarzało pół menu głównego (New Patch, Open…), bo `@FocusedValue`
        // w `MainMenuCommands` nie miało skąd wziąć stanu.
        .focusedValue(\.patchState, context.state)
        .focusedValue(\.canvasViewState, context.viewState)
        .focusedValue(\.fileOpenRequest, context.fileOpenRequest)
        .focusedValue(\.deviceConnection, context.device)
        .focusedValue(\.panelController, context.panels)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(panel.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if panel == .banks {
                PatchKindToggles(library: context.library)
                    .padding(.trailing, 4)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { panels.close() }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("Close panel")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

/// Treść panelu. Jedyne miejsce, które wie, co siedzi pod którym przyciskiem.
struct PanelContent: View {
    let panel: PanelController.Panel
    let context: PanelContext

    var body: some View {
        switch panel {
        case .modules:
            // Stawia ją `ContentView` — patrz nagłówek pliku.
            EmptyView()
        case .banks:
            BanksPanel(state: context.state, device: context.device,
                       library: context.library, onOpenFile: context.onOpenFile)
        case .dsp:
            DSPLoadPanel(device: context.device, state: context.state)
        case .keyboard:
            KeyboardPanel(device: context.device, state: context.state, typing: context.typing)
        case .parameterPages:
            ParameterPagesPanel(state: context.state)
        case .parameterOverview:
            ParameterOverviewPanel(state: context.state)
        case .mutator:
            MutatorPanel(state: context.state, panels: context.panels)
        case .patchAdjuster:
            PatchAdjusterPanel(state: context.state)
        case .colors:
            ColorsPanel(state: context.state)
        case .spectrogram:
            SpectrogramPanel()
        case .xyPlot:
            XYPlotPanel()
        case .mutatorTree:
            MutatorTreeView(state: context.state, panels: context.panels, tile: 36, showsWindowButton: false)
                .padding(10)
                .background(MutatorColor.panelBackground)
        }
    }
}

// MARK: - Szuflada przy lewej krawędzi

/// Szuflada przy lewej krawędzi. **Stałej szerokości** (`PanelController.Panel.drawerWidth`) —
/// obie szuflady zajmują ten sam pas ekranu, więc przełączenie jednej na drugą nie ma
/// prawa przesuwać kanwy. Biblioteka modułów trzyma tę samą miarę u siebie, bo w trybie
/// listy zwęża się do 190 pt.
struct DrawerPanel: View {
    @Bindable var panels: PanelController
    let panel: PanelController.Panel
    let context: PanelContext

    var body: some View {
        PanelBody(panels: panels, panel: panel, context: context)
            .frame(width: PanelController.Panel.drawerWidth)
    }
}
