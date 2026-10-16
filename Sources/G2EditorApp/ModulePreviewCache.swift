// ModulePreviewCache.swift
// Generuje NSImage dla każdego modułu przez off-screen NSWindow + NSHostingView.
// Off-screen window = SwiftUI renderuje poprawnie (jest w view hierarchy).
// Cache dwupoziomowy: pamięć (ten obiekt) + PNG na dysku w Application Support.
// Komplet 168 modułów renderuje się w kilka sekund, w tle (po każdej przebudowie
// aplikacji), z dysku wczytuje w ~0,02 s.

import AppKit
import G2Core
import G2EditorCore
import SwiftUI

// MARK: - Cache

@Observable
final class ModulePreviewCache {
    static let shared = ModulePreviewCache()

    /// typeID → wyrenderowany NSImage (zoom=2.0, moduł na ciemnym tle)
    private(set) var images: [Int: NSImage] = [:]
    /// typeID → trwa generowanie (żeby nie duplikować requestów)
    private var generating: Set<Int> = []
    /// `warmUp` w toku — komplet przyjdzie z dysku albo z jego renderu, więc pojedynczy
    /// wiersz paska nie rysuje wtedy swojego. Bez tego każdy wiersz biblioteki modułów
    /// renderował sam, zanim cache z dysku zdążył dojść: ~10 s kółka przy starcie.
    @ObservationIgnored private var warming = false
    @ObservationIgnored private var warmUpStarted = false
    /// Podglądy, o które pytał pasek w trakcie `warmUp`, w kolejności pytań — wiersze
    /// pytają od góry, więc render idzie od góry tego, co widać, a dopiero potem reszta.
    @ObservationIgnored private var requested: [Int] = []

    /// Pierwszy komplet podglądów gotowy (z dysku albo z renderu) — na to czeka przy
    /// starcie schowana biblioteka modułów. Zmienia się raz, więc obserwowanie go
    /// nie przerysowuje okna przy każdym obrazku.
    private(set) var allReady = false

    /// Wszystkie podglądy gotowe — do tej chwili nad biblioteką kręci się kółko.
    var isComplete: Bool {
        images.count >= ModuleDatabase.all.count
    }

    private init() {}

    /// Zwraca cached image lub nil (i startuje generowanie w tle).
    @MainActor
    func image(forTypeID typeID: Int) -> NSImage? {
        if let img = images[typeID] { return img }
        // Pasek z biblioteką modułów pyta o podglądy, zanim `AppDelegate` zdąży
        // zawołać `warmUp` — wtedy to pierwsze pytanie go uruchamia.
        if !warmUpStarted { warmUp() }
        if warming, !requested.contains(typeID) { requested.append(typeID) }
        if !warming, !generating.contains(typeID) {
            generating.insert(typeID)
            Task { @MainActor in
                let img = Self.render(typeID: typeID, zoom: Self.previewZoom)
                images[typeID] = img
                generating.remove(typeID)
            }
        }
        return nil
    }

    /// Wstępnie generuje obrazy dla wszystkich modułów (wywołaj przy starcie apki).
    /// Najpierw próbuje wczytać PNG z dysku; renderuje tylko gdy cache jest
    /// nieważny albo niekompletny, i wtedy zapisuje go na przyszłe uruchomienia.
    @MainActor
    func warmUp() {
        guard !warming else { return }
        warmUpStarted = true
        warming = true
        requested = []
        Task { @MainActor in
            defer { warming = false }
            let stamp = Self.currentStamp()
            if let cached = await Self.loadFromDisk(stamp: stamp) {
                images = cached
                allReady = true
                return
            }

            var pngs: [Int: Data] = [:]
            let all = ModuleDatabase.all.map(\.id)
            var done: Set<Int> = []
            // Najpierw to, o co pytał pasek (od góry ekranu), potem kolejność bazy.
            while let id = requested.first(where: { !done.contains($0) })
                ?? all.first(where: { !done.contains($0) })
            {
                done.insert(id)
                let img = images[id] ?? Self.render(typeID: id, zoom: Self.previewZoom)
                images[id] = img
                // Obraz z awaryjnego rysowania ma inną geometrię niż render SwiftUI —
                // takiego nie utrwalamy, bo cache musi mieć przewidywalny rozmiar.
                if img.size == Self.previewPointSize(typeID: id, zoom: Self.previewZoom),
                   let data = Self.pngData(img)
                {
                    pngs[id] = data
                }
                await Task.yield()
            }

            allReady = true
            guard pngs.count == ModuleDatabase.all.count else { return }
            Self.writeDiskCache(pngs, stamp: stamp)
        }
    }

    /// Zmiana wyglądu gałek w Options: podglądy renderują się od nowa (w tle, jak przy
    /// pierwszym starcie) i trafiają na dysk ze znacznikiem nowego wyglądu.
    @MainActor
    func redraw() {
        images = [:]
        warmUp()
    }

    // MARK: - Rendering

    /// Renderuje moduł do NSImage przez off-screen NSWindow.
    /// NSWindow (poza ekranem) = SwiftUI ma pełną hierarchię widoków → poprawny render.
    @MainActor
    static func render(typeID: Int, zoom: CGFloat) -> NSImage {
        let def = ModuleDatabase.module(id: typeID)
        let modH = CGFloat(def?.height ?? 2) * PatchLayout.ySpan
        let pad = PatchLayout.padding
        let sz = CGSize(
            width: (PatchLayout.moduleWidth + 2 * pad) * zoom,
            height: (modH + 2 * pad) * zoom
        )

        // Patch z jednym modułem
        var module = G2Module(id: 1, typeID: typeID, area: .voice)
        let defaults = ModuleDefaultsDatabase.defaults(forTypeID: typeID)
        if let mdef = def {
            module.parameters = defaults.isEmpty
                ? Array(repeating: 0, count: mdef.paramNames.count)
                : defaults
            module.modes = Array(repeating: 0, count: mdef.modeNames.count)
        }
        var patch = G2Patch()
        patch.voiceModules = [module]

        let view = PatchCanvasView(
            patch: patch, area: .voice, zoom: zoom,
            minSize: sz, isPreviewMode: true
        )

        // Off-screen window — poza ekranem (x: -30000), ale istnieje w hierarchii.
        // NSHostingView renderuje SwiftUI poprawnie tylko gdy jest w window.
        let screenH = NSScreen.main?.frame.height ?? 800
        let winRect = NSRect(x: -30000, y: screenH / 2, width: sz.width, height: sz.height)
        let win = NSWindow(
            contentRect: winRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: sz)
        win.contentView = hosting

        // Pokaż okno (poza ekranem) — SwiftUI musi widzieć okno żeby renderować
        win.orderBack(nil)

        // Układ od razu, bez czekania na klatkę: dawne `RunLoop.run(0,05 s)` kosztowało
        // 50 ms na moduł i blokowało start, a zdjęcia 168 modułów wychodzą identyczne
        // co do piksela (`--check-modules`, 2026-10-09) — zwykle; gdy nie, niżej czekamy.
        hosting.layoutSubtreeIfNeeded()

        // Capture bitmap — przechwytuj tylko obszar modułu bez ciemnego paddingu (12pt).
        // NSHostingView jest flipped (y=0 u góry) — moduł jest w (pad,pad).
        // Zostawiamy tylko mały border (capPad) żeby krawędź modułu nie była ucięta.
        let capPad = Self.capPad // pt ciemnego tła wokół modułu (1pt = minimalna krawędź)
        let capSz = previewPointSize(typeID: typeID, zoom: zoom)
        let capRect = NSRect(
            x: (pad - capPad) * zoom,
            y: (pad - capPad) * zoom, // NSHostingView flipped: y=0 u góry
            width: capSz.width,
            height: capSz.height
        )

        // Bywa, że SwiftUI nie zdążył jeszcze narysować modułu i zdjęcie wychodzi puste
        // (2026-10-15: cała biblioteka w czarnych prostokątach). Wtedy dajemy mu chwilę
        // i robimy zdjęcie jeszcze raz.
        var bitmap = hosting.bitmapImageRepForCachingDisplay(in: capRect)
        for _ in 0 ..< 20 {
            guard let rep = bitmap else { break }
            hosting.cacheDisplay(in: capRect, to: rep)
            if !Self.looksBlank(rep) { break }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            bitmap = hosting.bitmapImageRepForCachingDisplay(in: capRect)
        }

        let image: NSImage
        if let bitmapRep = bitmap, !Self.looksBlank(bitmapRep) {
            image = NSImage(size: capSz)
            image.addRepresentation(bitmapRep)
        } else {
            // Fallback: AppKit drawing (zawsze działa). Ma inny rozmiar, więc nie trafi na dysk.
            image = fallbackImage(typeID: typeID, def: def, sz: sz, zoom: zoom)
        }

        win.orderOut(nil)
        return image
    }

    /// Pusty zrzut ma dwa, trzy kolory (tło okna); prawdziwy moduł — napisy,
    /// gniazda i wygładzane krawędzie — ma ich dziesiątki.
    private static func looksBlank(_ rep: NSBitmapImageRep) -> Bool {
        var colors: Set<UInt32> = []
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let key = UInt32(color.redComponent * 255) << 16
                    | UInt32(color.greenComponent * 255) << 8 | UInt32(color.blueComponent * 255)
                colors.insert(key)
                if colors.count > 8 { return false }
            }
        }
        return true
    }

    /// Rozmiar (w punktach) obrazu, jaki `render` zwraca dla danego modułu.
    /// PNG na dysku trzyma same piksele, więc przy odczycie musimy podać punkty sami —
    /// inaczej na ekranie Retina obrazek wyszedłby dwa razy za duży.
    static func previewPointSize(typeID: Int, zoom: CGFloat) -> CGSize {
        let modH = CGFloat(ModuleDatabase.module(id: typeID)?.height ?? 2) * PatchLayout.ySpan
        return CGSize(
            width: (PatchLayout.moduleWidth + 2 * capPad) * zoom,
            height: (modH + 2 * capPad) * zoom
        )
    }

    // MARK: - Cache na dysku

    /// Wersja układu plików cache — podbij, gdy zmienia się sposób zapisu lub odczytu.
    private static let cacheFormatVersion = 1
    static let previewZoom: CGFloat = 2.0
    private static let capPad: CGFloat = 1

    private static var cacheDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("G2Editor/previews", isDirectory: true)
    }

    private static var stampURL: URL? {
        cacheDirectory?.appendingPathComponent("cache_version.txt")
    }

    /// Znacznik ważności cache. Zarówno baza modułów, jak i kod je rysujący siedzą
    /// w binarce, więc jej data i rozmiar łapią każdą zmianę wyglądu — nie tylko
    /// dopisanie modułu. Po przebudowie aplikacji podglądy renderują się raz od nowa.
    private static func currentStamp() -> String {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path)
        let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? Int) ?? 0
        return "v\(cacheFormatVersion) zoom=\(previewZoom) modules=\(ModuleDatabase.all.count) "
            + "knobs=\(KnobLook.stored.cacheTag) shading=\(PanelShading.stored) bin=\(Int(date)):\(size)"
    }

    /// Wczytuje komplet podglądów z dysku. `nil` = cache nieważny, niekompletny
    /// albo uszkodzony; wtedy wołający renderuje wszystko od nowa.
    @MainActor
    private static func loadFromDisk(stamp: String) async -> [Int: NSImage]? {
        guard let dir = cacheDirectory, let stampURL else { return nil }
        let ids = ModuleDatabase.all.map(\.id)

        // Odczyt z dysku poza głównym wątkiem; dekodowanie PNG-ów już na nim,
        // bo NSImage nie przechodzi przez granicę zadania.
        let files: [Int: Data]? = await Task.detached {
            guard let saved = try? String(contentsOf: stampURL, encoding: .utf8),
                  saved == stamp else { return nil }
            var out: [Int: Data] = [:]
            for id in ids {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(id).png"))
                else { return nil }
                out[id] = data
            }
            return out
        }.value

        guard let files else { return nil }
        var loaded: [Int: NSImage] = [:]
        for (id, data) in files {
            guard let rep = NSBitmapImageRep(data: data) else { return nil }
            let img = NSImage(size: previewPointSize(typeID: id, zoom: previewZoom))
            img.addRepresentation(rep)
            loaded[id] = img
        }
        return loaded
    }

    /// Zapisuje komplet PNG-ów, a znacznik ważności **na końcu** — przerwany zapis
    /// zostawia katalog bez znacznika, czyli cache nieważny, a nie po cichu wybrakowany.
    private static func writeDiskCache(_ pngs: [Int: Data], stamp: String) {
        guard let dir = cacheDirectory, let stampURL else { return }
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            try? fm.removeItem(at: dir)
            guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
            else { return }
            for (id, data) in pngs {
                guard (try? data.write(to: dir.appendingPathComponent("\(id).png"), options: .atomic)) != nil
                else { return }
            }
            try? stamp.write(to: stampURL, atomically: true, encoding: .utf8)
        }
    }

    private static func pngData(_ image: NSImage) -> Data? {
        if let rep = image.representations.first as? NSBitmapImageRep {
            return rep.representation(using: .png, properties: [:])
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Fallback

    private static func fallbackImage(
        typeID _: Int, def: ModuleDef?, sz: NSSize, zoom: CGFloat
    ) -> NSImage {
        let pad = PatchLayout.padding * zoom
        let modW = PatchLayout.moduleWidth * zoom
        let modH = CGFloat(def?.height ?? 2) * PatchLayout.ySpan * zoom
        let headerH = PatchLayout.headerH * zoom

        let image = NSImage(size: sz)
        image.lockFocusFlipped(true)

        NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.16, alpha: 1).setFill()
        NSRect(origin: .zero, size: sz).fill()

        NSColor(calibratedRed: 0.741, green: 0.741, blue: 0.741, alpha: 1).setFill()
        NSRect(x: pad, y: pad, width: modW, height: modH).fill()

        // Nagłówek — kolor kategorii
        let catColor = categoryNSColor(def?.page ?? "")
        catColor.setFill()
        NSRect(x: pad, y: pad, width: modW, height: headerH).fill()

        // Nazwa
        let fontSize = max(4, min(headerH * 0.62, 5.5 * zoom))
        let name = def?.shortName ?? "?"
        NSAttributedString(
            string: name,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor.black,
            ]
        ).draw(at: NSPoint(x: pad + 3 * zoom, y: pad + (headerH - fontSize) * 0.5))

        image.unlockFocus()
        return image
    }

    private static func categoryNSColor(_ cat: String) -> NSColor {
        switch cat {
        case "In/Out": NSColor(calibratedRed: 0.392, green: 0.392, blue: 0.392, alpha: 1)
        case "Note": NSColor(calibratedRed: 0.549, green: 0.008, blue: 0.992, alpha: 1)
        case "Osc": NSColor(calibratedRed: 0.792, green: 0.000, blue: 0.000, alpha: 1)
        case "LFO": NSColor(calibratedRed: 0.000, green: 0.000, blue: 0.792, alpha: 1)
        case "Rnd": NSColor(calibratedRed: 0.000, green: 0.588, blue: 0.902, alpha: 1)
        case "Env": NSColor(calibratedRed: 0.000, green: 0.733, blue: 0.733, alpha: 1)
        case "Filter": NSColor(calibratedRed: 0.000, green: 0.510, blue: 0.518, alpha: 1)
        case "FX": NSColor(calibratedRed: 0.918, green: 0.392, blue: 0.690, alpha: 1)
        case "Delay": NSColor(calibratedRed: 0.514, green: 0.349, blue: 1.000, alpha: 1)
        case "Shaper": NSColor(calibratedRed: 0.855, green: 0.647, blue: 0.125, alpha: 1)
        case "Level": NSColor(calibratedRed: 0.000, green: 0.502, blue: 0.000, alpha: 1)
        case "Mixer": NSColor(calibratedRed: 0.000, green: 0.392, blue: 0.000, alpha: 1)
        case "Switch": NSColor(calibratedRed: 0.502, green: 0.502, blue: 0.000, alpha: 1)
        case "Logic": NSColor(calibratedRed: 0.784, green: 0.784, blue: 0.000, alpha: 1)
        case "Seq": NSColor(calibratedRed: 0.784, green: 0.784, blue: 0.000, alpha: 1)
        case "MIDI": NSColor(calibratedRed: 0.784, green: 0.392, blue: 0.000, alpha: 1)
        case "PM": NSColor(calibratedRed: 0.200, green: 0.600, blue: 0.400, alpha: 1)
        default: NSColor.gray
        }
    }
}
