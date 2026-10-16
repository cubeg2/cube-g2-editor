// ModuleRasterCache.swift
// Gotowe obrazki modułów dla kanwy — mechanizm, na którym stoją edytory modułowe,
// które nie przycinają: moduł rysuje się wektorowo RAZ, a kanwa wkleja bitmapę.
//
// Do 2026-09-11 każde odświeżenie kanwy rysowało każdy moduł od zera: tło, nagłówek,
// kilkanaście etykiet, gałki, gniazda — ~0,4 ms na moduł w release (dwa razy tyle
// w debug), czyli ~50 ms na patch ze stu modułami. Kanwa odświeża się przy każdym
// kroku zoomu, każdej zmianie podświetlenia i każdej gałce, więc zoom szedł w kilkunastu
// klatkach na sekundę, a przy dużym powiększeniu SwiftUI dzieli kanwę na kafelki
// i woła rysowanie osobno dla każdego — z pełnym kosztem za każdym razem.
//
// Teraz `drawModules` wkleja obrazek z tej pamięci (`ctx.draw(Image)`, ułamek
// milisekundy), a wektorowe rysowanie zostaje wyłącznie do WYTWORZENIA obrazka —
// przez `ImageRenderer` na tej samej funkcji `drawModule`, więc wygląd nie ma prawa
// się rozjechać. Obrazek jest ważny, dopóki nie zmieni się nic, co `drawModule`
// czyta (patrz `ModuleRasterKey`); przekręcona gałka unieważnia jeden moduł, nie sto.
//
// Zoom: obrazki powstają w powiększeniu `rasterZoom`. W trakcie gestu (pinch, ⌘scroll)
// kanwa wkleja je przeskalowane — lekko miękkie, ale bez rysowania — a
// `PatchCanvasView` po chwili ciszy przestawia `rasterZoom` i moduły rysują się
// na ostro jeden raz (jak Podgląd czy Safari).

import AppKit
import G2Core
import G2EditorCore
import SwiftUI

/// Wszystko, od czego zależy wygląd jednego modułu na kanwie. **Każdy nowy odczyt stanu
/// widoku w `drawModule` (i funkcjach, które woła) musi trafić tutaj** — inaczej kanwa
/// pokaże nieświeży obrazek. Lista odpowiada audytowi odczytów z 2026-09-11:
/// `activeModuleID`, `focusedMorph`, `patch.morphs`, `momentaryFlash`,
/// `vocoderSelectedPreset`, `seqNoteZoomLevel`, `seqNoteScrollOffset`,
/// `octaveButtonFlash`, `faderButtonFlash`, `incDecHold`; od 2026-09-26 `knobStyle` i `panelShading`.
struct ModuleRasterKey: Equatable {
    var module: G2Module
    /// Wysokość efektywna (do sąsiada z dołu) — zmienia się, gdy sąsiad się przesunie.
    var height: CGFloat
    var zoom: CGFloat
    var backingScale: CGFloat
    var isActive: Bool
    var focusedMorph: Int
    var morphs: [G2MorphAssignment]
    var momentaryFlashCodeRef: Int?
    var vocoderPreset: Int?
    var seqNoteZoomLevel: Int?
    var seqNoteScrollOffset: Int?
    var octaveFlashIsUp: Bool?
    var faderFlash: FaderFlash?
    var incDecHold: IncDecHold?
    var knobStyle: KnobLook
    var panelShading: Bool

    struct FaderFlash: Equatable {
        var codeRef: Int
        var isUp: Bool
    }

    struct IncDecHold: Equatable {
        var codeRef: Int
        var isUp: Bool
    }
}

/// Pamięć obrazków jednej kanwy. Referencja trzymana w `@State` — jej zmiany nie budzą
/// widoku; o przerysowanie prosi sama, przez `onRendered`.
@MainActor
final class ModuleRasterCache {
    struct Entry {
        var key: ModuleRasterKey
        var image: CGImage
    }

    /// Powiększenie, w którym powstają obrazki. Kanwa wkleja je przeskalowane
    /// o `zoom / rasterZoom`; `0` = jeszcze nieustalone.
    var rasterZoom: CGFloat = 0
    private var entries: [Int: Entry] = [:]
    /// Moduły, których obrazek jest do zrobienia albo do odświeżenia — zbierane w trakcie
    /// rysowania, renderowane zaraz po nim (`flushPending`).
    private var pending: [Int: PendingRender] = [:]
    private var flushScheduled = false
    /// Moduły wklejone w ostatnim przebiegu — tylko one dostają nowe obrazki po zmianie
    /// zoomu; reszta (poza ekranem) czeka, aż będzie potrzebna.
    private(set) var recentlyDrawn: Set<Int> = []
    /// Wołane po wyrenderowaniu zaległych obrazków — kanwa ma się przerysować.
    var onRendered: (() -> Void)?

    struct PendingRender {
        let key: ModuleRasterKey
        let def: ModuleDef?
        let render: (ModuleRasterKey, ModuleDef?) -> CGImage?
    }

    /// Margines po bokach modułu, na gniazda wystające poza jego prostokąt — ten sam,
    /// którym `drawModule` rozszerza obcięcie.
    static let sideMargin: CGFloat = UIMetrics.connectorHalf + UIMetrics.socketOuterMargin + 0.5

    static var backingScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Początek przebiegu kanwy: moduły, których już nie ma w patchu, zwalniają pamięć.
    func beginPass(moduleIDs: Set<Int>) {
        recentlyDrawn.removeAll(keepingCapacity: true)
        for moduleID in Array(entries.keys) where !moduleIDs.contains(moduleID) {
            entries.removeValue(forKey: moduleID)
        }
    }

    /// Obrazek do wklejenia, jeśli jest i jest aktualny (`exact`), albo nieświeży —
    /// lepszy na jedną klatkę niż nic. `nil` = modułu jeszcze nie ma w pamięci.
    func image(for moduleID: Int, key: ModuleRasterKey) -> (entry: Entry, exact: Bool)? {
        recentlyDrawn.insert(moduleID)
        guard let entry = entries[moduleID] else { return nil }
        return (entry, entry.key == key)
    }

    /// Zamawia obrazek; rysowanie odbywa się po zakończeniu bieżącego przebiegu kanwy —
    /// nie w jego trakcie, bo `ImageRenderer` to osobne przejście SwiftUI.
    func request(moduleID: Int, key: ModuleRasterKey, def: ModuleDef?,
                 render: @escaping (ModuleRasterKey, ModuleDef?) -> CGImage?)
    {
        if pending[moduleID]?.key == key { return }
        pending[moduleID] = PendingRender(key: key, def: def, render: render)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flushPending() }
    }

    private func flushPending() {
        flushScheduled = false
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        var rendered = false
        for (moduleID, job) in batch {
            guard let image = job.render(job.key, job.def) else { continue }
            entries[moduleID] = Entry(key: job.key, image: image)
            rendered = true
        }
        if rendered { onRendered?() }
    }

    /// Nowe powiększenie: obrazki ostatnio wklejonych modułów powstają od razu (jeden
    /// przystanek po geście, zamiast rysowania przy każdym jego kroku), pozostałe
    /// wypadają — zrobią się, gdy wjadą na ekran.
    func setRasterZoom(_ zoom: CGFloat, render: (ModuleRasterKey, ModuleDef?) -> CGImage?) {
        guard zoom != rasterZoom else { return }
        rasterZoom = zoom
        pending.removeAll()
        for moduleID in Array(entries.keys) where !recentlyDrawn.contains(moduleID) {
            entries.removeValue(forKey: moduleID)
        }
        let backingScale = Self.backingScale
        for (moduleID, entry) in entries {
            var key = entry.key
            key.zoom = zoom
            key.backingScale = backingScale
            if let image = render(key, ModuleDatabase.module(id: key.module.typeID)) {
                entries[moduleID] = Entry(key: key, image: image)
            } else {
                entries.removeValue(forKey: moduleID)
            }
        }
    }
}

/// Widok, z którego `ImageRenderer` robi obrazek jednego modułu: ta sama `drawModule`
/// co na kanwie. Moduł rysuje się w swoim PRAWDZIWYM położeniu na kanwie, a kontekst
/// jest przesunięty tak, by to położenie wypadło w lewym górnym rogu obrazka (z marginesem
/// na gniazda) — bo gniazda i ich opisy liczą pozycję z kolumny i wiersza modułu
/// (`connectorCenterForDraw`), nie z przekazanego prostokąta.
struct ModuleRasterView: View {
    let owner: PatchCanvasView
    let module: G2Module
    let def: ModuleDef?
    let height: CGFloat
    let zoom: CGFloat
    let backingScale: CGFloat

    /// Rozmiar obrazka w punktach — zaokrąglony w górę do pełnych pikseli ekranu, żeby
    /// wklejka 1:1 nie wymagała przeskalowania o ułamek piksela.
    var pointSize: CGSize {
        let width = (PatchLayout.moduleWidth + 2 * ModuleRasterCache.sideMargin) * zoom
        return CGSize(width: (width * backingScale).rounded(.up) / backingScale,
                      height: (height * zoom * backingScale).rounded(.up) / backingScale)
    }

    var body: some View {
        let margin = ModuleRasterCache.sideMargin
        let origin = owner.moduleOriginForDraw(module)
        let size = pointSize
        Canvas { ctx, _ in
            ctx.scaleBy(x: zoom, y: zoom)
            ctx.translateBy(x: margin - origin.x, y: -origin.y)
            owner.drawModule(ctx, module: module, def: def,
                             rect: CGRect(origin: origin,
                                          size: CGSize(width: PatchLayout.moduleWidth, height: height)))
        }
        .frame(width: size.width, height: size.height)
    }

    /// Obrazek w rozdzielczości ekranu (`backingScale`), przezroczysty poza modułem.
    @MainActor
    static func render(owner: PatchCanvasView, key: ModuleRasterKey, def: ModuleDef?) -> CGImage? {
        let renderer = ImageRenderer(content: ModuleRasterView(
            owner: owner, module: key.module, def: def, height: key.height,
            zoom: key.zoom, backingScale: key.backingScale
        ))
        renderer.scale = key.backingScale
        renderer.isOpaque = false
        return renderer.cgImage
    }
}
