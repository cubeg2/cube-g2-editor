import CoreGraphics
import G2Core
import Observation

/// Kanał do zachowania kotwicy canvasu podczas programowej zmiany zoomu.
@MainActor
public protocol CanvasZoomRequesting: AnyObject {
    func requestZoom(_ newZoom: CGFloat)
}

/// Stan **widoku** canvasu współdzielony między `ContentView` a `Commands` z `MainMenu`.
///
/// Menu aplikacji stoi na poziomie `App` i nie sięga stanu prywatnego widoku, dlatego
/// zoom, obszar (Voice/FX) i widoczność kabli mieszkają tutaj. Stan pozostaje osobno
/// od `PatchState`, bo zoom i filtry widoku nie są częścią danych patcha.
@MainActor
@Observable
public final class CanvasViewState {
    public static let minZoom: CGFloat = 0.25
    public static let maxZoom: CGFloat = 8.0

    /// Aktualny zoom canvasu. Zapis wyłącznie przez `requestZoom(_:)` albo z NSView
    /// (pinch / ⌘scroll), które melduje wynik z powrotem.
    public var zoom: CGFloat = 2.0
    /// Strona patcha, do której trafiają nowe moduły i polecenia menu. Gdy widać oba
    /// obszary naraz, ustawia ją ten, nad którym stoi kursor.
    public var selectedArea: PatchArea = .voice
    /// Obszary pokazane na kanwie. Voice i FX to w oryginale dwa ZWYKŁE przyciski,
    /// nie przełącznik radiowy — wciśnięte oba dzielą okno wzdłuż: Voice u góry,
    /// FX pod spodem. Zbiór nigdy nie jest pusty.
    public var visibleAreas: Set<PatchArea> = [.voice]
    /// Ile wspólnego okna zajmuje górna część (Voice), gdy widać oba obszary.
    public var splitFraction: CGFloat = 0.5
    /// Rozmiar widocznego kawałka canvasu — potrzebny do „Zoom to Fit".
    public var viewportSize: CGSize = .zero

    /// Kolory kabli ukryte pojedynczo.
    public var hiddenCableColors: Set<CableColor> = []
    /// Master „schowaj wszystkie" — trzymany osobno, żeby zdjęcie go przywracało
    /// wcześniejszy wybór pojedynczych kolorów.
    public var allCablesHidden = false
    public var cableShakeSeed: UInt64 = 0

    /// Nakładka „żółtych dymków" nad kontrolkami — klawisze F5–F8 z instrukcji.
    public var overlayMode: CanvasOverlayMode = .none

    /// Adapter warstwy UI utrzymujący środek widoku przy zmianie zoomu.
    @ObservationIgnored public weak var zoomRequester: (any CanvasZoomRequesting)?

    public var clampedZoom: CGFloat {
        min(max(zoom, Self.minZoom), Self.maxZoom)
    }

    /// Efektywny zbiór ukrytych kolorów przekazywany do canvasu.
    public var effectiveHiddenCableColors: Set<CableColor> {
        allCablesHidden ? Set(CableColor.allCases) : hiddenCableColors
    }

    public init() {}

    // MARK: - Voice / FX

    /// Kolejność jest stała: Voice zawsze nad FX, niezależnie od tego, który przycisk
    /// wciśnięto pierwszy.
    public var orderedVisibleAreas: [PatchArea] {
        [.voice, .fx].filter { visibleAreas.contains($0) }
    }

    public var isSplit: Bool {
        visibleAreas.count > 1
    }

    public func isAreaVisible(_ area: PatchArea) -> Bool {
        visibleAreas.contains(area)
    }

    /// Klik w przycisk Voice albo FX. Wyłączyć się nie da ostatniego widocznego —
    /// pusta kanwa nie ma czego pokazać.
    public func toggleArea(_ area: PatchArea) {
        if visibleAreas.contains(area) {
            guard visibleAreas.count > 1 else { return }
            visibleAreas.remove(area)
            selectedArea = orderedVisibleAreas[0]
        } else {
            visibleAreas.insert(area)
            selectedArea = area
        }
    }

    /// Klawisze „V" i „F" z tabeli skrótów — pokazują JEDEN obszar, tak jak w oryginale.
    public func showOnly(_ area: PatchArea) {
        visibleAreas = [area]
        selectedArea = area
    }

    /// Granica między Voice a FX; skrajne położenia zostawiają obu częściom resztkę,
    /// żeby dało się ją przeciągnąć z powrotem.
    public func setSplitFraction(_ value: CGFloat) {
        splitFraction = min(max(value, 0.1), 0.9)
    }

    // MARK: - Zoom

    public func requestZoom(_ newZoom: CGFloat) {
        let clamped = min(max(newZoom, Self.minZoom), Self.maxZoom)
        if let zoomRequester {
            zoomRequester.requestZoom(clamped)
        } else {
            zoom = clamped
        }
    }

    public func zoomIn() {
        requestZoom(clampedZoom + 0.25)
    }

    public func zoomOut() {
        requestZoom(clampedZoom - 0.25)
    }

    /// Dopasowuje zoom tak, żeby podany rozmiar zawartości zmieścił się w viewportcie.
    public func zoomToFit(contentSize: CGSize) {
        guard contentSize.width > 0, contentSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0
        else { return }
        requestZoom(min(viewportSize.width / contentSize.width,
                        viewportSize.height / contentSize.height))
    }

    // MARK: - Kable

    public func isCableColorVisible(_ color: CableColor) -> Bool {
        !allCablesHidden && !hiddenCableColors.contains(color)
    }

    public func toggleCableColor(_ color: CableColor) {
        if allCablesHidden {
            // Rozwijamy master na zwykły zbiór, żeby klik w pojedynczy kolor dał widoczny efekt.
            allCablesHidden = false
            hiddenCableColors = Set(CableColor.allCases)
        }
        if hiddenCableColors.contains(color) {
            hiddenCableColors.remove(color)
        } else {
            hiddenCableColors.insert(color)
        }
    }

    public func showAllCables() {
        allCablesHidden = false
        hiddenCableColors = []
    }

    public func hideAllCables() {
        allCablesHidden = true
    }

    public func shakeCables() {
        cableShakeSeed = UInt64.random(in: 1 ... UInt64.max)
    }

    // MARK: - Nakładki F5–F8

    /// Ten sam klawisz włącza i wyłącza nakładkę; inny ją podmienia.
    public func toggleOverlay(_ mode: CanvasOverlayMode) {
        overlayMode = overlayMode == mode ? .none : mode
    }
}

/// Co pokazują żółte dymki nad kontrolkami patcha. Kolejność i klawisze za tabelą
/// skrótów z instrukcji (str. 132): F5 — wartości, F6 — morfy, F7 — gałki panelu,
/// F8 — numery MIDI CC.
///
/// Uwaga: strona 94 przypisuje F5 i F7 odwrotnie („F7 … which Morph group",
/// „F5 displays the Morph ranges"). Tabela na str. 132 jest późniejsza i spójna
/// z nazwami poleceń („View Parameter Values", „View Morph Groups", „View Knob
/// Assignments", „View MIDI CC# Assignments"), więc idziemy za nią.
public enum CanvasOverlayMode: String, CaseIterable, Sendable {
    case none
    case values
    case morphGroups
    case knobAssignments
    case midiControllers

    public var title: String {
        switch self {
        case .none: "Off"
        case .values: "Parameter Values"
        case .morphGroups: "Morph Groups"
        case .knobAssignments: "Knob Assignments"
        case .midiControllers: "MIDI CC Assignments"
        }
    }

    /// Numer klawisza funkcyjnego — `nil` dla `.none`.
    public var functionKey: Int? {
        switch self {
        case .none: nil
        case .values: 5
        case .morphGroups: 6
        case .knobAssignments: 7
        case .midiControllers: 8
        }
    }
}
