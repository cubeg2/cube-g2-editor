import AppKit
import G2Core
import SwiftUI

extension PatchCanvasView {
    // MARK: - Modules

    /// Moduły idą na kanwę jako gotowe obrazki z `rasters` (patrz `ModuleRasterCache`);
    /// wektorowo rysuje się tylko moduł, którego obrazka jeszcze nie ma, i podglądy.
    /// Przy dużym powiększeniu SwiftUI woła to rysowanie osobno dla każdego kafelka
    /// kanwy — `clipBoundingRect` mówi, który to kafelek, i moduły spoza niego pomijamy.
    func drawModules(_ ctx: GraphicsContext) {
        let ro = rowOffset
        let mods = modules
        let clip = ctx.clipBoundingRect
        let margin = ModuleRasterCache.sideMargin
        let useRasters = !isPreviewMode
        var backingScale: CGFloat = 1
        if useRasters {
            if rasters.rasterZoom == 0 { rasters.rasterZoom = zoom }
            rasters.beginPass(moduleIDs: Set(mods.map(\.id)))
            rasters.onRendered = { rasterGeneration += 1 }
            backingScale = ModuleRasterCache.backingScale
        }
        // Przeciągane moduły rysujemy na końcu — zawsze na wierzchu innych modułów
        var deferred: [(module: G2Module, def: ModuleDef?, rect: CGRect)] = []
        for module in mods {
            let d = moduleDefinition(module.typeID)
            var rect = PatchLayout.moduleRect(module, def: d, rowOffset: ro, allModules: mods)
            let dragged = moduleDrag.map {
                $0.moduleID == module.id || $0.extraModules.contains(where: { $0.id == module.id })
            } ?? false
            if dragged, let drag = moduleDrag {
                rect = rect.offsetBy(dx: drag.dragOffset.width, dy: drag.dragOffset.height)
            }
            guard rect.insetBy(dx: -margin, dy: 0).intersects(clip) else { continue }
            if dragged {
                deferred.append((module, d, rect))
            } else {
                paintModule(ctx, module: module, def: d, rect: rect,
                            useRasters: useRasters, backingScale: backingScale)
            }
        }
        for item in deferred {
            paintModule(ctx, module: item.module, def: item.def, rect: item.rect,
                        useRasters: useRasters, backingScale: backingScale)
        }
        // Przy włączonym „Only audible" moduły, których nie słychać, gasną pod mgiełką
        // w kolorze tła — mutacja je omija (decyzja użytkownika 2026-09-17).
        if audibilityVisible, !isPreviewMode {
            let audibility = G2AudibilityMap(patch: patch)
            for module in mods where audibility.isSilent(area: module.area, module: module.id) {
                let rect = PatchLayout.moduleRect(module, def: moduleDefinition(module.typeID),
                                                  rowOffset: ro, allModules: mods)
                guard rect.intersects(clip) else { continue }
                ctx.fill(Path(rect), with: .color(UIColor.canvasBackground.opacity(0.55)))
            }
        }
        // Cienka czerwona ramka wokół modułów wyłączonych z mutacji — widoczna tylko
        // przy otwartym oknie mutatora, dokładnie jak w oryginale.
        if mutatorVisible {
            for module in mods where module.excludedFromMutation {
                let rect = PatchLayout.moduleRect(module, def: moduleDefinition(module.typeID),
                                                  rowOffset: ro, allModules: mods)
                guard rect.intersects(clip) else { continue }
                ctx.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)),
                           with: .color(Color(red: 0.85, green: 0.15, blue: 0.15)),
                           lineWidth: 1)
            }
        }
        // Ramki zaznaczenia NIE są tu rysowane — mają animowane kreski, więc idą do
        // osobnej, odświeżanej warstwy (`selectionOverlayView`), żeby animacja nie
        // przerysowywała wszystkich modułów i kabli w każdej klatce.
    }

    /// Wkleja obrazek modułu; gdy obrazka brak, rysuje moduł wektorowo i zamawia go.
    /// Nieświeży obrazek (np. sprzed ruchu gałki) idzie na jedną klatkę — świeży
    /// dociera z `onRendered` zaraz po tym przebiegu. Obrazek w powiększeniu innym niż
    /// bieżące (trwa gest zoomu) jest skalowany; w tym samym — wklejany piksel w piksel.
    private func paintModule(_ ctx: GraphicsContext, module: G2Module, def: ModuleDef?,
                             rect: CGRect, useRasters: Bool, backingScale: CGFloat)
    {
        guard useRasters else {
            drawModule(ctx, module: module, def: def, rect: rect)
            return
        }
        let key = rasterKey(for: module, height: rect.height, backingScale: backingScale)
        let owner = self
        let render: (ModuleRasterKey, ModuleDef?) -> CGImage? = { key, def in
            ModuleRasterView.render(owner: owner, key: key, def: def)
        }
        guard let (entry, exact) = rasters.image(for: module.id, key: key) else {
            drawModule(ctx, module: module, def: def, rect: rect)
            rasters.request(moduleID: module.id, key: key, def: def, render: render)
            return
        }
        if !exact { rasters.request(moduleID: module.id, key: key, def: def, render: render) }
        // Prostokąt docelowy = rozmiar obrazka w pt logicznych powiększenia, w którym
        // powstał; przy innym bieżącym powiększeniu skaluje się razem z kontekstem.
        let rasterPx = entry.key.zoom * entry.key.backingScale
        var target = CGRect(x: rect.minX - ModuleRasterCache.sideMargin, y: rect.minY,
                            width: CGFloat(entry.image.width) / rasterPx,
                            height: CGFloat(entry.image.height) / rasterPx)
        let oneToOne = entry.key.zoom == zoom
        if oneToOne {
            // Wyrównanie do siatki pikseli — bez niego wklejka w ułamkowym położeniu
            // rozmywałaby się o pół piksela.
            target.origin.x = (target.origin.x * rasterPx).rounded() / rasterPx
            target.origin.y = (target.origin.y * rasterPx).rounded() / rasterPx
        }
        let image = Image(decorative: entry.image, scale: 1)
            .interpolation(oneToOne ? .none : .medium)
        ctx.draw(image, in: target)
    }

    /// Klucz ważności obrazka — patrz `ModuleRasterKey`.
    private func rasterKey(for module: G2Module, height: CGFloat,
                           backingScale: CGFloat) -> ModuleRasterKey
    {
        let location: UInt8 = area == .voice ? 1 : 0
        return ModuleRasterKey(
            module: module,
            height: height,
            zoom: rasters.rasterZoom,
            backingScale: backingScale,
            isActive: activeModuleID == module.id,
            focusedMorph: focusedMorph,
            morphs: patch.morphs(in: patch.activeVariation)
                .filter { $0.location == location && $0.moduleID == module.id },
            momentaryFlashCodeRef: momentaryFlash.flatMap { $0.moduleID == module.id ? $0.codeRef : nil },
            vocoderPreset: vocoderSelectedPreset[module.id],
            seqNoteZoomLevel: seqNoteZoomLevel[module.id],
            seqNoteScrollOffset: seqNoteScrollOffset[module.id],
            octaveFlashIsUp: octaveButtonFlash.flatMap { $0.moduleID == module.id ? $0.isUp : nil },
            faderFlash: faderButtonFlash.flatMap {
                $0.moduleID == module.id ? .init(codeRef: $0.codeRef, isUp: $0.isUp) : nil
            },
            incDecHold: incDecHold.flatMap {
                $0.moduleID == module.id ? .init(codeRef: $0.codeRef, isUp: $0.isUp) : nil
            },
            knobStyle: knobStyle,
            panelShading: panelShading
        )
    }

    // MARK: - Drag-aware connector center

    /// Lewy górny róg modułu na kanwie, z przesunięciem trwającego przeciągania — ten
    /// sam punkt odniesienia, od którego `connectorCenterForDraw` liczy gniazda.
    func moduleOriginForDraw(_ module: G2Module) -> CGPoint {
        var origin = PatchLayout.moduleRect(module, def: moduleDefinition(module.typeID),
                                            rowOffset: rowOffset).origin
        if let drag = moduleDrag,
           drag.moduleID == module.id || drag.extraModules.contains(where: { $0.id == module.id })
        {
            origin.x += drag.dragOffset.width
            origin.y += drag.dragOffset.height
        }
        return origin
    }

    func connectorCenterForDraw(module: G2Module, connIndex: Int, isOutput: Bool) -> CGPoint {
        var pt = PatchLayout.connectorCenter(module: module, def: moduleDefinition(module.typeID),
                                             connIndex: connIndex, isOutput: isOutput,
                                             rowOffset: rowOffset)
        if let drag = moduleDrag,
           drag.moduleID == module.id || drag.extraModules.contains(where: { $0.id == module.id })
        {
            pt.x += drag.dragOffset.width
            pt.y += drag.dragOffset.height
        }
        return pt
    }

    // MARK: - Selection helpers

    /// Kreski przesuwają się wzdłuż obwodu ("marching ants") — ta sama przerywana ramka
    /// co przy zaznaczaniu (`drawRubberBand`), tylko żywa. `dashPhase` przesuwa wzór;
    /// wartość ujemna daje ruch zgodny z kierunkiem rysowania ścieżki (w prawo górą).
    func drawSelectionFrames(_ ctx: GraphicsContext, dashPhase: CGFloat) {
        let ro = rowOffset
        let mods = modules
        for module in mods where selectedModuleIDs.contains(module.id) {
            var rect = PatchLayout.moduleRect(module, def: moduleDefinition(module.typeID),
                                              rowOffset: ro, allModules: mods)
            if let drag = moduleDrag,
               drag.moduleID == module.id || drag.extraModules.contains(where: { $0.id == module.id })
            {
                rect = rect.offsetBy(dx: drag.dragOffset.width, dy: drag.dragOffset.height)
            }
            ctx.stroke(Path(rect.insetBy(dx: -1.0, dy: -1.0)),
                       with: .color(Color.white.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 0.8, dash: [3, 2], dashPhase: dashPhase))
        }
    }

    func drawRubberBand(_ ctx: GraphicsContext) {
        guard let start = rubberBandStart, let current = rubberBandCurrent else { return }
        let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(current.x - start.x), height: abs(current.y - start.y))
        guard rect.width > 1 || rect.height > 1 else { return }
        ctx.fill(Path(rect), with: .color(Color.white.opacity(0.05)))
        ctx.stroke(Path(rect), with: .color(Color.white.opacity(0.75)),
                   style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
    }

    func modulesInRect(_ rect: CGRect) -> Set<Int> {
        let ro = rowOffset
        let mods = modules
        var result = Set<Int>()
        for module in mods {
            let r = PatchLayout.moduleRect(module, def: moduleDefinition(module.typeID), rowOffset: ro, allModules: mods)
            if rect.intersects(r) { result.insert(module.id) }
        }
        return result
    }

    /// Rysuje jeden moduł wektorowo. ⚠️ Każdy nowy odczyt stanu widoku tutaj (albo w
    /// funkcjach wołanych stąd) musi trafić do `ModuleRasterKey`, bo wynik ląduje w
    /// pamięci obrazków (`ModuleRasterCache`) i bez tego nie odświeży się.
    func drawModule(
        _ ctx: GraphicsContext,
        module: G2Module,
        def: ModuleDef?,
        rect: CGRect
    ) {
        let isNameModule = (def?.shortName == "Name" || module.typeID == 126)
        // ── DRAW ORDER ────────────────────────────────────────────────────────
        // 1. CBMP bitmap  (full module rect, gray panel artwork)
        // 2. Module content  (knobs, connectors, labels — module-top-relative Y)
        // 3. Header strip  (drawn LAST so it covers anything that intrudes into top)
        //
        // All drawing is clipped to the module rect so nothing bleeds into
        // adjacent modules or below a Name bar.
        //
        // Y positions: all DB values × connYScale = screen pt from rect.minY.
        // Sizes (r, diam): already in X-scale screen pts — do NOT apply connYScale.

        // Clip rect rozszerzony o 4pt po bokach (lewo/prawo) żeby konektory na
        // krawędzi modułu nie były przecinane, ale pionowo ścisły — nic nie wychodzi
        // powyżej ani poniżej modułu.
        let connR = UIMetrics.connectorHalf + UIMetrics.socketOuterMargin + 0.5
        let clipRect = rect.insetBy(dx: -connR, dy: 0)

        if isNameModule {
            // ── Name moduł: pełna szerokość kolorowego paska ──────────────────
            var clipped = ctx
            clipped.clip(to: Path(rect))
            drawNameStrip(clipped, rect: rect, def: def, module: module, fullWidth: true)
            drawModuleBorder(ctx, rect: rect, isActive: activeModuleID == module.id)

        } else {
            // ── Zwykły moduł: renderowanie programowe ─────────────────────────
            //
            // KOLEJNOŚĆ:
            //   1. Tło modułu: szary panel (color=0) lub kolor użytkownika (color 1-24)
            //   2. Pasek nagłówka z nazwą
            //   3. Elementy UI z BVerhue .txt: knobs, buttons, labels, connectors

            var clipped = ctx
            clipped.clip(to: Path(clipRect))

            // 1. Tło modułu — szary panel dla domyślnego koloru, kolor użytkownika gdy ustawiony
            let bodyColor: Color = module.color == 0 ? UIColor.modulePanelGray : moduleHeaderColor(module, def: def)
            clipped.fill(Path(rect), with: .color(bodyColor))

            // 2. Pasek nazwy
            drawNameStrip(clipped, rect: rect, def: def, module: module, fullWidth: false)

            // 3. Elementy UI — rysowane NA WIERZCHU tła i paska nazwy
            drawBVLines(clipped, module: module, rect: rect)
            drawFaderBusLines(clipped, module: module, rect: rect)
            drawBVSymbols(clipped, module: module, rect: rect)
            drawBVTextLabels(clipped, module: module, rect: rect)
            drawModuleParameters(clipped, module: module, def: def, rect: rect)
            drawBVButtons(clipped, module: module, rect: rect)
            drawBVPartSelectors(clipped, module: module, rect: rect)
            drawBVLevelShifts(clipped, module: module, rect: rect)
            drawBVTextFields(clipped, module: module, rect: rect)
            drawBVGraphs(clipped, module: module, rect: rect)
            drawBVLEDs(clipped, module: module, rect: rect)
            drawBVMiniVUs(clipped, module: module, rect: rect)
            drawConnectorLabels(clipped, module: module, def: def, rect: rect)
            drawConnectors(clipped, module: module, def: def, rect: rect, isOutput: false)
            drawConnectors(clipped, module: module, def: def, rect: rect, isOutput: true)

            // Ramka 3D — rysowana NA KOŃCU (na wierzchu wszystkich elementów)
            drawModuleBorder(ctx, rect: rect, isActive: activeModuleID == module.id)
        }
    }

    // MARK: - Module 3D border

    /// Delikatna ramka z efektem wypukłości: górna+lewa jaśniejsza, dolna+prawa ciemniejsza.
    /// Obrys zewnętrzny zostaje prostokątny (moduły stykają się na siatce), a wewnętrzny
    /// ma zaokrąglone rogi. W dwóch rogach, gdzie jasne spotyka ciemne (prawy-górny
    /// i lewy-dolny), kolor przechodzi płynnie po przekątnej. Do 2026-09-27 obie strony
    /// stykały się ostrą ukośną linią (prośba użytkownika).
    /// isActive=true → dolna i prawa krawędź mają kolor canvasu, bez pogrubiania.
    private func drawModuleBorder(_ ctx: GraphicsContext, rect: CGRect, isActive: Bool = false) {
        let lw: CGFloat = 0.7
        let innerCorner: CGFloat = 1.0
        // Połowa długości przejścia jasne→ciemne, mierzona wzdłuż przekątnej rogu.
        let blend: CGFloat = 1.2
        let highlight = Color.white.opacity(0.55)
        let shadow = isActive ? UIColor.canvasBackground : Color.black.opacity(0.35)

        var ring = ctx
        var ringPath = Path(rect)
        ringPath.addPath(Path(roundedRect: rect.insetBy(dx: lw, dy: lw), cornerRadius: innerCorner))
        ring.clip(to: ringPath, style: FillStyle(eoFill: true))

        // Pas przejścia w rogu: prostopadły do przekątnej ↘, od linii, na której jest
        // jeszcze w pełni jasno, do linii, na której jest już w pełni ciemno — gradient
        // zaczyna się i kończy dokładnie na jego brzegach, więc nie ma szwu.
        let along = CGPoint(x: blend, y: blend)
        let across = CGPoint(x: 4, y: -4)
        func band(_ corner: CGPoint) -> Path {
            Path { p in
                p.move(to: CGPoint(x: corner.x - along.x + across.x, y: corner.y - along.y + across.y))
                p.addLine(to: CGPoint(x: corner.x + along.x + across.x, y: corner.y + along.y + across.y))
                p.addLine(to: CGPoint(x: corner.x + along.x - across.x, y: corner.y + along.y - across.y))
                p.addLine(to: CGPoint(x: corner.x - along.x - across.x, y: corner.y - along.y - across.y))
                p.closeSubpath()
            }
        }
        let corners = [CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY)]
        var bands = Path()
        for corner in corners {
            bands.addPath(band(corner))
        }

        // Jasna połowa: góra i lewa, odcięte ukosami z tych dwóch rogów.
        let reach = min(rect.width, rect.height) / 2
        let lit = Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - reach, y: rect.minY + reach))
            p.addLine(to: CGPoint(x: rect.minX + reach, y: rect.maxY - reach))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
        var plain = ring
        plain.clip(to: bands, options: .inverse)
        var light = plain
        light.clip(to: lit)
        light.fill(Path(rect), with: .color(highlight))
        var dark = plain
        dark.clip(to: lit, options: .inverse)
        dark.fill(Path(rect), with: .color(shadow))

        for corner in corners {
            ring.fill(band(corner), with: .linearGradient(
                Gradient(colors: [highlight, shadow]),
                startPoint: CGPoint(x: corner.x - along.x, y: corner.y - along.y),
                endPoint: CGPoint(x: corner.x + along.x, y: corner.y + along.y)
            ))
        }
    }

    // MARK: - Name strip

    // fullWidth=true  → Name moduł (pasek przez całą wysokość i szerokość)
    // fullWidth=false → zwykły moduł (pasek pełna szerokość, tylko wiersz nagłówka)

    private func drawNameStrip(
        _ ctx: GraphicsContext,
        rect: CGRect,
        def: ModuleDef?,
        module: G2Module,
        fullWidth: Bool
    ) {
        let catColor = moduleHeaderColor(module, def: def)
        // Etykieta: custom label (jeśli ustawiona) lub shortName modułu
        let fullLabel = !module.label.isEmpty
            ? module.label
            : (def?.shortName ?? "?\(module.typeID)")
        // Zwykły moduł: nazwa ogranicza się do 8 znaków + ".." — miejsce w nagłówku
        // koliduje z ikonką i elementami panelu. Name moduł (fullWidth) wyświetla
        // pełne do 16 znaków, bo nie ma nic innego na pasku.
        let label = fullLabel.count > 8 ? String(fullLabel.prefix(8)) + ".." : fullLabel
        // Name moduł: pasek wypełnia całą wysokość; zwykły moduł: tylko nagłówek
        let stripH = fullWidth ? rect.height : PatchLayout.headerH
        let fontSize = min(stripH * 0.62, UIFont.moduleName)

        // Pasek zawsze pełna szerokość modułu (kolor modułu = tło całego nagłówka)
        let stripW = rect.width
        let stripRect = CGRect(x: rect.minX, y: rect.minY, width: stripW, height: stripH)

        // Tło nagłówka — pełna szerokość
        ctx.fill(Path(stripRect), with: .color(catColor))

        // Linia górna nagłówka (subtelny highlight)
        ctx.fill(Path(CGRect(x: stripRect.minX, y: stripRect.minY,
                             width: stripW, height: 0.5)),
                 with: .color(.white.opacity(0.35)))

        if fullWidth {
            // ── Name bar: bez ikonki. Pełne do 16 znaków (max wpisu), wyśrodkowane —
            // jedyny moduł bez elementów kolidujących z nazwą, więc bez skracania.
            // Niezmieniona domyślna etykieta (Name, Name1, Name2…) zostaje ukryta;
            // widać ją dopiero w polu edycji. Moduł służy do opisywania patcha,
            // więc własna nazwa typu na panelu byłaby szumem.
            let isDefaultName = ModuleAutoLabel.isUntouchedDefault(
                module.label, shortName: def?.shortName ?? ""
            )
            if !module.label.isEmpty, !isDefaultName {
                ctx.draw(
                    Text(fullLabel)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundColor(.black),
                    at: CGPoint(x: stripRect.midX, y: stripRect.minY + stripH * 0.5),
                    anchor: .center
                )
            }
        } else {
            // ── Normalny moduł: ikonka + tekst nazwy ──────────────────────────
            let iconRect = PatchLayout.replacementIconRect(in: stripRect)
            let iconCol = pageColor(def?.page ?? "")
            ctx.stroke(
                Path(roundedRect: iconRect, cornerRadius: 0.9),
                with: .color(iconCol),
                lineWidth: 0.55
            )
            var tri = Path()
            tri.move(to: CGPoint(x: iconRect.minX + iconRect.width * 0.15,
                                 y: iconRect.minY + iconRect.height * 0.18))
            tri.addLine(to: CGPoint(x: iconRect.maxX - iconRect.width * 0.15,
                                    y: iconRect.minY + iconRect.height * 0.18))
            tri.addLine(to: CGPoint(x: iconRect.midX,
                                    y: iconRect.maxY - iconRect.height * 0.16))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(iconCol))

            ctx.draw(
                Text(label)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(.black),
                at: CGPoint(x: PatchLayout.moduleNameStartX(in: stripRect),
                            y: stripRect.minY + stripH * 0.5),
                anchor: .leading
            )
        }
    }

    // MARK: - Parameters / Knobs

    private func drawModuleParameters(
        _ ctx: GraphicsContext,
        module: G2Module,
        def: ModuleDef?,
        rect: CGRect
    ) {
        // ── Priorytet 1: BVerhue .txt — dokładne pozycje dla wszystkich 192 modułów ──
        // Współrzędne .xPt/.yPt są już w screen pt (Gen1px × 140/256).
        // Nie stosujemy connYScale — skala jest jednolita X=Y.
        if let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) {
            let defaults = ModuleDefaultsDatabase.defaults(forTypeID: module.typeID)
            // ── Pre-pass: SeqNote piano-roll grid ─────────────────────────────
            // Wykryj suwaki nutowe (infoFunc==13 = SeqNote) i narysuj tło siatki
            // raz przed pętlą, obejmując całą szerokość wszystkich kolumn.
            let noteKnobs = ui.seqNoteKnobs
            var noteRange = (lo: 0, hi: 127)
            if !noteKnobs.isEmpty {
                let noteParams = noteKnobs.map { k in
                    k.codeRef < module.parameters.count ? module.parameters[k.codeRef] : 60
                }
                noteRange = noteViewRange(params: noteParams,
                                          zoomLevel: seqNoteZoomLevel[module.id] ?? 1,
                                          loNoteOverride: seqNoteScrollOffset[module.id])

                // Prostokąt siatki = dokładnie obszar torów (ta sama geometria co niżej)
                let refFader = faderLayout(module: module, knob: noteKnobs[0], ui: ui, rect: rect)
                let sliderH = refFader.track.height
                let sliderW = refFader.track.width
                let sliderY = refFader.track.minY

                // Wszystkie kolumny mają szerokość ROZSTAWU kroków. Wcześniej ostatnia
                // kończyła się na szerokości samego toru (10 zamiast 12 pikseli
                // źródłowych), więc była wyraźnie węższa od pozostałych.
                let sortedNoteKnobs = noteKnobs.sorted { $0.xPt < $1.xPt }
                let stepPitch = sortedNoteKnobs.count > 1
                    ? sortedNoteKnobs[1].xPt - sortedNoteKnobs[0].xPt
                    : sliderW
                let minX = rect.minX + (sortedNoteKnobs.first?.xPt ?? 0)
                let maxX = rect.minX + (sortedNoteKnobs.last?.xPt ?? 0) + stepPitch
                let gridArea = CGRect(x: minX, y: sliderY,
                                      width: maxX - minX, height: sliderH)
                drawNoteGrid(ctx, area: gridArea,
                             loNote: noteRange.lo, hiNote: noteRange.hi)

                // Pionowe kreski oddzielające kroki — najciemniejszy odcień siatki,
                // ten sam co czarne klawisze
                let stepSepColor = UIColor.seqNoteBlackKey
                for (i, nk) in sortedNoteKnobs.enumerated() {
                    guard i > 0 else { continue } // lewa krawędź = ramka gridu
                    let lx = rect.minX + nk.xPt
                    var vline = Path()
                    vline.move(to: CGPoint(x: lx, y: sliderY))
                    vline.addLine(to: CGPoint(x: lx, y: sliderY + sliderH))
                    ctx.stroke(vline, with: .color(stepSepColor), lineWidth: 0.3)
                }
            }

            for knob in ui.knobs {
                let value = knob.codeRef < module.parameters.count
                    ? module.parameters[knob.codeRef] : 0
                // XPos/YPos in .txt = top-left of the knob widget, NOT the center.
                // For rotary knobs: add centerOffsetPt (from GetKnobMetrics).
                // For sliders/push/box: use top-left directly.
                let origin = knobOrigin(module: module, knob: knob)
                let tlx = rect.minX + origin.x
                let tly = rect.minY + origin.y
                if knob.type.isRotary {
                    let off = knob.type.centerOffsetPt
                    let maxValue = ParameterRangeDatabase.range(
                        moduleTypeID: module.typeID, codeRef: knob.codeRef
                    )?.upperBound ?? 127
                    drawKnob(ctx, cx: tlx + off.x, cy: tly + off.y,
                             radius: knob.type.radiusPt, value: value, maxValue: maxValue,
                             morph: morphTint(moduleID: module.id, paramIndex: knob.codeRef,
                                              value: value, maxValue: maxValue))
                    if knob.type.hasResetButton {
                        let isAtDefault = defaults.indices.contains(knob.codeRef)
                            && value == defaults[knob.codeRef]
                        drawKnobResetButton(ctx, centerX: tlx + off.x, topY: tly,
                                            isActive: isAtDefault)
                    }
                } else {
                    switch knob.type {
                    case .slider, .seqSlider:
                        let fader = faderLayout(module: module, knob: knob, ui: ui, rect: rect)
                        let track = fader.track
                        // SeqNote (infoFunc==13): thumb pozycjonowany w zakresie nut
                        if knob.infoFunc == 13 {
                            drawSeqSlider(ctx, x: track.minX, y: track.minY,
                                          w: track.width, h: track.height,
                                          value: value, loNote: noteRange.lo, hiNote: noteRange.hi)
                        } else {
                            drawSeqSlider(ctx, x: track.minX, y: track.minY,
                                          w: track.width, h: track.height, value: value)
                        }
                        // ▲/▼ przyciski pod torem slidera
                        let upFlash = faderButtonFlash?.moduleID == module.id
                            && faderButtonFlash?.codeRef == knob.codeRef
                            && faderButtonFlash?.isUp == true
                        let dnFlash = faderButtonFlash?.moduleID == module.id
                            && faderButtonFlash?.codeRef == knob.codeRef
                            && faderButtonFlash?.isUp == false
                        drawSeqIncDecButton(ctx, x: fader.up.minX, y: fader.up.minY,
                                            w: fader.up.width, h: fader.up.height,
                                            isUp: true, highlighted: upFlash)
                        drawSeqIncDecButton(ctx, x: fader.down.minX, y: fader.down.minY,
                                            w: fader.down.width, h: fader.down.height,
                                            isUp: false, highlighted: dnFlash)
                    default:
                        let sz = knob.type.sliderSizePt
                        drawToggle(ctx, x: tlx, y: tly, w: sz.width, h: sz.height, value: value)
                    }
                }
            }
            return
        }

        // Awaryjna siatka dla nieznanego typu modułu. Wszystkie 167 typów z panelem
        // mają komplet kontrolek chroniony przez ModuleInvariantTests.
        guard let d = def, !module.parameters.isEmpty else { return }
        guard !d.paramNames.isEmpty else { return }
        let hdr = PatchLayout.headerH
        let bodyH = rect.height - hdr
        guard bodyH > 4 else { return }
        let count = min(d.paramNames.count, module.parameters.count)
        guard count > 0 else { return }
        let cellW = rect.width / CGFloat(count)
        let knobR = min(max(min(cellW, bodyH) * 0.35, 3.0), 7.0)
        for i in 0 ..< count {
            let cx = rect.minX + (CGFloat(i) + 0.5) * cellW
            let cy = rect.minY + hdr + bodyH * 0.5
            drawKnob(ctx, cx: cx, cy: cy, radius: knobR, value: module.parameters[i])
        }
    }

    /// Oryginał (Knob Slider ABC (UpdateGraphics)): wartość przekazywana do gałki jest
    /// przeliczana jako `wartość × 127 / maksimum_parametru`, NIE branym wprost jako
    /// ułamek stałego 127 — gałka zawsze osiąga pełny obrót dokładnie przy WŁASNYM
    /// maksimum parametru (99 dla R/L Operatora, 7 dla Vel/RateScale/AMod, itd.), a nie
    /// dopiero przy 127. `maxValue` domyślnie 127 dla parametrów bez wpisu w
    /// `ParameterRangeDatabase` (zachowanie bez zmian).
    private func drawKnob(
        _ ctx: GraphicsContext,
        cx: CGFloat, cy: CGFloat, radius r: CGFloat, value: Int, maxValue: Int = 127,
        morph: MorphIndicator.Tint? = nil
    ) {
        let clampedMax = max(1, maxValue)
        // Wskaźnik idzie za morfem tylko wtedy, gdy oryginał też go przesuwa —
        // przy parametrze o zakresie mniejszym niż 0…127 pokazuje zero.
        let pointerValue = morph?.displayValue ?? value
        let norm = Double(max(0, min(clampedMax, pointerValue))) / Double(clampedMax)
        let center = CGPoint(x: cx, y: cy)
        let ir = KnobFace.draw(ctx, center: center, radius: r, style: knobStyle, fraction: norm)
        if let morph {
            MorphIndicator.draw(ctx, cx: cx, cy: cy, faceRadius: ir, tint: morph, look: knobStyle)
        }
        // Kreseczki min/max (pozycja 0 = 135°, pozycja 127 = 405°=45°)
        let tickLW = max(0.4, r * 0.12)
        for deg in [135.0, 405.0] as [CGFloat] {
            let a = deg * (.pi / 180.0)
            var tick = Path()
            tick.move(to: CGPoint(x: cx + cos(a) * (r + tickLW),
                                  y: cy + sin(a) * (r + tickLW)))
            tick.addLine(to: CGPoint(x: cx + cos(a) * (r + r * 0.30),
                                     y: cy + sin(a) * (r + r * 0.30)))
            ctx.stroke(tick, with: .color(.black.opacity(0.65)),
                       style: StrokeStyle(lineWidth: tickLW * 1.6, lineCap: .round))
        }
        // 135° = 7:30 (lewy-dół), +270° sweep → 12:00 w połowie → 4:30 na końcu
        KnobFace.drawPointer(ctx, center: center, radius: r, face: ir, fraction: norm, style: knobStyle)
    }

    /// Zabarwienie gałki morfem: czerwone, gdy parametr idzie za morfem z focusem
    /// (z wycinkiem pokazującym zakres), niebieskie, gdy za którymkolwiek z pozostałych
    /// → [[MorphIndicator]].
    func morphTint(moduleID: Int, paramIndex: Int, value: Int,
                   maxValue: Int) -> MorphIndicator.Tint?
    {
        let assigned = patch.morphs(variation: patch.activeVariation,
                                    location: area == .voice ? 1 : 0,
                                    moduleID: moduleID, paramIndex: paramIndex)
        return MorphIndicator.tint(for: assigned, focusedMorph: focusedMorph,
                                   value: value, maxValue: maxValue)
    }

    /// Górna krawędź trójkąta resetu. `GetKnobMetrics` rezerwuje 6 Gen1px między górną
    /// krawędzią widżetu a tarczą (CalcRect top=6 dla `Reset` i `Reset/medium`) — i to
    /// jest miejsce na trójkąt. Rysujemy go więc WEWNĄTRZ widżetu: 1 px od jego górnej
    /// krawędzi, co zostawia 1 px szczeliny nad tarczą. Rysowanie ponad widżetem (jak
    /// wcześniej) odsuwało grot od gałki, wchodziło w opis nad nią, a w niskich modułach
    /// (OscD: YPos:3) wypychało go poza górną ramkę panelu.
    func knobResetTriangleTopY(knobTopY: CGFloat) -> CGFloat {
        knobTopY + PatchLayout.bverhuePixelScale
    }

    /// Trójkąt resetu nad gałką — geometria BVerhue `M0,0 h10 l-5,4 z`
    /// z UnitModuleDef.pas/CreateCenterBtnOn, odsunięta od obrysu gałki o 1 px Gen1.
    /// Rogi lekko zaokrąglone, a sam trójkąt wypukły jak każdy przycisk — klik ustawia
    /// gałkę na środek, zieleń tylko mówi, że już tam stoi (2026-09-27).
    private func drawKnobResetButton(
        _ ctx: GraphicsContext,
        centerX: CGFloat,
        topY: CGFloat,
        isActive: Bool
    ) {
        let scale = CGFloat(140.0 / 256.0)
        let width = 10 * scale
        let height = 4 * scale
        let y = knobResetTriangleTopY(knobTopY: topY)
        let left = CGPoint(x: centerX - width / 2, y: y)
        let right = CGPoint(x: centerX + width / 2, y: y)
        let tip = CGPoint(x: centerX, y: y + height)
        // Małe, bo górne rogi mają tylko ~39° — większy promień wyraźnie zmniejszał trójkąt.
        let corner: CGFloat = 0.15
        let triangle = Path { path in
            path.move(to: CGPoint(x: centerX, y: y))
            path.addArc(tangent1End: right, tangent2End: tip, radius: corner)
            path.addArc(tangent1End: tip, tangent2End: left, radius: corner)
            path.addArc(tangent1End: left, tangent2End: right, radius: corner)
            path.closeSubpath()
        }
        PanelFace.raised(ctx, triangle, fill: isActive ? UIColor.powerButtonOn : UIColor.knobResetOff,
                         border: .black, lineWidth: 0.35, shaded: panelShading)
    }

    private func drawToggle(
        _ ctx: GraphicsContext,
        x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, value: Int
    ) {
        let r = CGRect(x: x, y: y, width: w, height: h)
        let fill: Color = value != 0 ? UIColor.toggleOn : UIColor.toggleOff
        PanelFace.raised(ctx, r, cornerRadius: 1.0,
                         fill: fill, border: .black.opacity(0.5), lineWidth: 0.5, shaded: panelShading)
    }

    /// Pionowy slider sekwencera (Type:"Slider" i Type:"SeqSlider").
    /// Mały prostokątny thumb przesuwa się wzdłuż ciemnej prowadnicy.
    /// Środek X napisu liczony po WIDOCZNYCH literach, nie po szerokości advance.
    /// Skrajne glify mają różne sidebearingi (np. „Inv" — 0,34pt z lewej, 0,26pt
    /// z prawej), więc `anchor: .center` zostawia po jednej stronie więcej światła
    /// niż po drugiej. Przy foncie przycisków 4pt to ułamek punktu, ale widać to
    /// na powiększeniu i różni się od napisu do napisu.
    func opticalCenterX(_ text: String, in rect: CGRect,
                        fontSize: CGFloat, weight: NSFont.Weight) -> CGFloat
    {
        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
        let ink = CTLineGetImageBounds(line, nil)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard advance > 0, ink.width > 0 else { return rect.midX }
        let leftBearing = ink.minX
        let rightBearing = advance - ink.maxX
        return rect.midX - (leftBearing - rightBearing) / 2
    }

    private func drawSeqSlider(
        _ ctx: GraphicsContext,
        x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
        value: Int, loNote: Int = 0, hiNote: Int = 127
    ) {
        let track = CGRect(x: x, y: y, width: w, height: h)
        // Tło slidera: przezroczyste gdy jest pod siatką nut, ciemne w trybie normalnym
        let hasNoteGrid = loNote > 0 || hiNote < 127
        if !hasNoteGrid {
            // Tor i uchwyt noszą paletę ekranów LCD tego samego modułu (tło ekranu +
            // zielony font odczytu) — fader stoi bezpośrednio pod swoim ekranem
            // i ma się czytać jako jego przedłużenie, nie osobny, szary widżet.
            // Narożniki jak u przycisków w tej samej kolumnie (▲/▼ i przyciski kroku).
            let corner = UIMetrics.buttonCornerRadius
            // Tor fadera jest wklęsły jak ekran, nad którym stoi; uchwyt leży na nim.
            PanelFace.recessed(ctx, track, cornerRadius: corner,
                               fill: UIColor.lcdBackground, shaded: panelShading)
        }

        let range = CGFloat(max(1, hiNote - loNote))
        // Wysokość thumba = 1 półton (dopasowana do siatki SeqNote)
        let thumbH: CGFloat = loNote < hiNote ? max(1.0, h / CGFloat(hiNote - loNote)) : 3.0
        let travelH = max(0, h - thumbH)
        // Uchwyt nuty MUSI pokrywać się z pasem swojego klawisza. Rozłożenie po
        // „drodze przesuwu" (h − thumbH) daje inne kroki niż siatka rysowana po
        // granicach półtonów, więc przy części wartości uchwyt lądował na styku
        // dwóch klawiszy zamiast na jednym z nich.
        if hasNoteGrid, loNote < hiNote {
            // Siatka rysuje pasy dla nut loNote ..< hiNote, więc górnym widocznym
            // klawiszem jest hiNote-1 — bez tego uchwyt nuty leżącej powyżej okna
            // wyjeżdżał ponad ramkę siatki.
            let clamped = max(loNote, min(hiNote - 1, value))
            let bandTop = y + (1 - CGFloat(clamped + 1 - loNote) / range) * h
            let thumbRect = CGRect(x: x, y: bandTop, width: w, height: max(1.0, h / range))
            let outside = value < loNote || value > hiNote
            if outside {
                // Nuta poza widocznym oknem — sam kontur, w tej samej zieleni co
                // uchwyt. Czarny gubił się na ciemnym tle siatki.
                ctx.stroke(Path(roundedRect: thumbRect, cornerRadius: 1.0),
                           with: .color(UIColor.lcdText), lineWidth: 0.8)
            } else {
                ctx.fill(Path(roundedRect: thumbRect, cornerRadius: 1.0),
                         with: .color(UIColor.lcdText))
                ctx.stroke(Path(roundedRect: thumbRect, cornerRadius: 1.0),
                           with: .color(.black.opacity(0.55)), lineWidth: 0.5)
            }
            return
        }

        // Pozycja thumba: nuta może być POZA widocznym oknem — klipujemy do krawędzi,
        // ale pokazujemy inny kolor (pomarańczowy) aby użytkownik wiedział, że jest poza widokiem.
        let outOfRange = hasNoteGrid && (value < loNote || value > hiNote)
        let norm: CGFloat = if outOfRange {
            value < loNote ? 0.0 : 1.0 // klip do dołu lub do góry
        } else {
            CGFloat(max(loNote, min(hiNote, value)) - loNote) / range
        }
        let thumbY = y + travelH * (1.0 - norm)
        let thumbRect = CGRect(x: x, y: thumbY, width: w, height: thumbH)
        // Thumb: pełny gdy w oknie, sam kontur gdy poza oknem
        if outOfRange {
            // Poza widocznym oknem — kontur w zieleni uchwytu, bez wypełnienia
            ctx.stroke(Path(roundedRect: thumbRect, cornerRadius: 1.0),
                       with: .color(UIColor.lcdText), lineWidth: 0.8)
        } else {
            // Zielony odczytu LCD — wspólny dla siatki nut (SeqNote) i faderów
            // stojących pod ekranem (MixFader, SeqCtr, SeqLev).
            ctx.fill(Path(roundedRect: thumbRect, cornerRadius: 1.0),
                     with: .color(UIColor.lcdText))
            ctx.stroke(Path(roundedRect: thumbRect, cornerRadius: 1.0),
                       with: .color(.black.opacity(0.55)), lineWidth: 0.5)
        }
    }

    // MARK: - SeqNote piano-roll grid

    /// Oblicza zakres widocznych nut (loNote, hiNote) dla trybu SeqNote.
    /// zoomLevel: 0 = 3 oktawy, 1 = 2 oktawy (domyślnie), 2 = 1 oktawa.
    /// Zakres zaokrąglony do C, wycentrowany na środku wartości sekwencera.
    /// loNoteOverride: explicit scroll offset (⌥+scroll) — pomija auto-centrowanie.
    func noteViewRange(params: [Int], zoomLevel: Int = 1, loNoteOverride: Int? = nil) -> (lo: Int, hi: Int) {
        let octaves = [3, 2, 1][max(0, min(2, zoomLevel))]
        let loNote: Int
        if let ov = loNoteOverride {
            loNote = max(0, min(127 - octaves * 12, ov))
        } else {
            let vals = params.filter { $0 >= 0 && $0 <= 127 }
            // Kroki z wartością 0 = nierozmieszczone; centrum na C4 (60) gdy brak aktywnych
            let activeVals = vals.filter { $0 > 0 }
            let centerNote = activeVals.isEmpty ? 60 : (activeVals.min()! + activeVals.max()!) / 2
            let centerOct = max(0, min(9, centerNote / 12))
            let loOct = max(0, centerOct - octaves / 2)
            loNote = loOct * 12
        }
        let hiNote = min(127, loNote + octaves * 12)
        return (lo: loNote, hi: hiNote)
    }

    /// Tło piano-roll: kolorowe pasy półtonów + separatory oktaw.
    /// Wywoływana raz przed pętlą sliderów, pokrywa pełną szerokość siatki.
    private func drawNoteGrid(
        _ ctx: GraphicsContext,
        area: CGRect, // prostokąt obejmujący wszystkie kolumny słupków
        loNote: Int, hiNote: Int
    ) {
        let range = CGFloat(hiNote - loNote)
        guard range > 0 else { return }

        let blackKeys: Set = [1, 3, 6, 8, 10] // C#, D#, F#, G#, A#

        // Pasy półtonów (od loNote na dole do hiNote na górze). Separator NIE jest
        // rysowany NA granicy pasów — pas jest o niego skrócony po stronie, z której
        // sąsiaduje z drugim białym klawiszem, więc linia nigdy nie leży na wierzchu
        // (przy każdym C bywała wtedy grubsza, a sąsiednie pasy wyglądały na niższe).
        // Kolor szczeliny bierze się z wypełnienia warstwy pod pasami.
        let bandPitch = area.height / range
        // Przy gęstej skali nie ma czego rozdzielać — separator zjadłby cały pas.
        let separator = min(0.3, max(0, bandPitch - 0.5) / 2)
        // Rogi jak u pozostałych ramek w aplikacji — pasy przycinamy do tego samego
        // kształtu, żeby nie wystawały w narożnikach.
        let corner = UIMetrics.buttonCornerRadius
        let frame = Path(roundedRect: area, cornerRadius: corner)
        ctx.drawLayer { layer in
            layer.clip(to: frame)
            layer.fill(frame, with: .color(UIColor.seqNoteKeyLine))
            for n in loNote ..< hiNote {
                let isBlack = blackKeys.contains(n % 12)
                // Linia tylko na styku dwóch białych klawiszy (E–F, H–C) — tam, gdzie
                // na klawiaturze nie ma między nimi czarnego. Pozostałe granice czyta
                // się z samej różnicy odcieni.
                let whiteAbove = !isBlack && !blackKeys.contains((n + 1) % 12)
                let whiteBelow = !isBlack && !blackKeys.contains((n + 11) % 12)
                let frac0 = CGFloat(n - loNote) / range
                let frac1 = CGFloat(n + 1 - loNote) / range
                let bandTop = area.minY + (1 - frac1) * area.height
                    + (whiteAbove ? separator / 2 : 0)
                let bandBot = area.minY + (1 - frac0) * area.height
                    - (whiteBelow ? separator / 2 : 0)
                let band = CGRect(x: area.minX, y: bandTop,
                                  width: area.width, height: max(0.3, bandBot - bandTop))
                layer.fill(Path(band),
                           with: .color(isBlack ? UIColor.seqNoteBlackKey : UIColor.seqNoteWhiteKey))
            }
        }

        // Ramka zewnętrzna. Siatka nut to ekran — wklęsła jak pozostałe; uchwyty nut
        // rysują się na niej. Tło z pasami leży już pod spodem, stąd `fill: nil`.
        PanelFace.recessed(ctx, frame, fill: nil, border: UIColor.seqNoteFrame, shaded: panelShading)
    }

    func drawSeqIncDecButton(
        _ ctx: GraphicsContext,
        x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, isUp: Bool,
        highlighted: Bool = false
    ) {
        let r = CGRect(x: x, y: y, width: w, height: h)
        let bgColor: Color = highlighted ? UIColor.buttonPressed : UIColor.buttonNeutral
        PanelFace.raised(ctx, r, cornerRadius: 0.5,
                         fill: bgColor, border: .black.opacity(0.4), shaded: panelShading)
        let cx = x + w / 2, midY = y + h / 2
        // Trójkąt RÓWNOBOCZNY: wysokość = bok × √3/2, więc obie połowy liczymy z boku.
        let side = min(w, h) * 0.52
        let base = side / 2
        let tip = side * sqrt(3) / 4
        var arrow = Path()
        if isUp {
            arrow.move(to: CGPoint(x: cx, y: midY - tip))
            arrow.addLine(to: CGPoint(x: cx - base, y: midY + tip))
            arrow.addLine(to: CGPoint(x: cx + base, y: midY + tip))
        } else {
            arrow.move(to: CGPoint(x: cx, y: midY + tip))
            arrow.addLine(to: CGPoint(x: cx - base, y: midY - tip))
            arrow.addLine(to: CGPoint(x: cx + base, y: midY - tip))
        }
        arrow.closeSubpath()
        ctx.fill(arrow, with: .color(Color(white: 0.25)))
    }

    /// Ikona Run/Loop dla ButtonFlat z InfoFunc:9 (SeqEvent, SeqLev, SeqCtr, SeqNote).
    /// Kształty z użytkownika: Loop-01.svg (loop) i Loop-02.svg (1-cycle).
    /// SVG viewBox 400×200 → normalizacja do content bounds każdej ikony.
    private func drawBVRunLoopIcon(_ ctx: GraphicsContext, in r: CGRect, isLoop: Bool) {
        PanelFace.raised(ctx, r, cornerRadius: UIMetrics.buttonFlatCornerRadius,
                         fill: UIColor.buttonActive, shaded: panelShading)

        let pad = r.height * 0.18
        // Ikona ma wąską górę (grot) i masywny dół (łuk), więc geometrycznie
        // wyśrodkowana sprawia wrażenie osadzonej za nisko — podnosimy ją o tyle,
        // żeby zrównoważyć optycznie ten ciężar.
        let ir = r.insetBy(dx: pad, dy: pad).offsetBy(dx: 0, dy: -r.height * 0.05)

        if isLoop {
            // ── Loop-01.svg ────────────────────────────────────────────────────────
            // Content bounds: (95.53, 13.41) → (304.48, 152.85), size 208.95 × 139.44
            // Wszystkie punkty relatywne do origin (95.53, 13.41)
            let pt: (CGFloat, CGFloat) -> CGPoint = { cx, cy in
                CGPoint(x: ir.minX + (cx / 208.95) * ir.width,
                        y: ir.minY + (cy / 139.44) * ir.height)
            }

            // Kształt pętli (rounded-rect loop arrows z arrowhead po prawej)
            var shape = Path()
            // Wlot łuku tuż za grotem kończy się PŁASKO. W oryginalnym SVG jest tu
            // klin wcięty w stronę grotu — przy naszym rozmiarze czytał się jak
            // drugi, przypadkowy grot doklejony do pętli.
            shape.move(to: pt(156.10, 33.74))
            shape.addLine(to: pt(138.50, 33.74)) // h-17.6
            shape.addLine(to: pt(138.50, 49.74)) // płaska krawędź wlotu
            shape.addLine(to: pt(156.10, 49.74)) // h17.6
            shape.addCurve(to: pt(192.95, 86.59),
                           control1: pt(176.42, 49.74), control2: pt(192.95, 66.27))
            shape.addCurve(to: pt(156.10, 123.44),
                           control1: pt(192.95, 106.91), control2: pt(176.42, 123.44))
            shape.addLine(to: pt(52.85, 123.44)) // h-103.25
            shape.addCurve(to: pt(16.00, 86.59),
                           control1: pt(32.53, 123.44), control2: pt(16.00, 106.91))
            shape.addCurve(to: pt(52.85, 49.74),
                           control1: pt(16.00, 66.27), control2: pt(32.53, 49.74))
            shape.addLine(to: pt(108.87, 49.74)) // h56.02
            shape.addLine(to: pt(108.87, 33.74)) // v-16
            shape.addLine(to: pt(52.85, 33.74)) // h-56.02
            shape.addCurve(to: pt(0.00, 86.59),
                           control1: pt(23.71, 33.74), control2: pt(0.00, 57.45))
            shape.addCurve(to: pt(52.85, 139.44),
                           control1: pt(0.00, 115.73), control2: pt(23.71, 139.44))
            shape.addLine(to: pt(156.10, 139.44)) // h103.25
            shape.addCurve(to: pt(208.95, 86.59),
                           control1: pt(185.24, 139.44), control2: pt(208.95, 115.73))
            shape.addCurve(to: pt(156.10, 33.74),
                           control1: pt(208.95, 57.45), control2: pt(185.24, 33.74))
            shape.closeSubpath()
            ctx.fill(shape, with: .color(.white))

            // Trójkąt play (polygon)
            var tri = Path()
            tri.move(to: pt(77.75, 0.00))
            tri.addLine(to: pt(77.75, 83.48))
            tri.addLine(to: pt(131.19, 41.74))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(.white))

        } else {
            // ── Loop-02.svg ────────────────────────────────────────────────────────
            // Content bounds: (92.30, 40.24) → (314.43, 159.76), size 222.13 × 119.52
            // Wszystkie punkty relatywne do origin (92.30, 40.24)
            let pt: (CGFloat, CGFloat) -> CGPoint = { cx, cy in
                CGPoint(x: ir.minX + (cx / 222.13) * ir.width,
                        y: ir.minY + (cy / 119.52) * ir.height)
            }
            // Minimalna grubość 0.8pt żeby cienkie elementy były widoczne przy zoom=1
            let minPx: CGFloat = 0.8

            // Trójkąt play
            var tri = Path()
            tri.move(to: pt(155.23, 18.02))
            tri.addLine(to: pt(155.23, 101.50))
            tri.addLine(to: pt(208.67, 59.76))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(.white))

            // Pozioma kreska →
            let hBarH = max((15.0 / 119.52) * ir.height, minPx)
            let hBarY = pt(0, 52.26).y + ((15.0 / 119.52) * ir.height - hBarH) / 2
            ctx.fill(Path(CGRect(x: pt(0, 0).x, y: hBarY,
                                 width: (187.99 / 222.13) * ir.width, height: hBarH)),
                     with: .color(.white))

            // Pionowy stop-bar |
            let vBarW = max((13.46 / 222.13) * ir.width, minPx)
            let vBarX = pt(208.67, 0).x
            ctx.fill(Path(CGRect(x: vBarX, y: pt(0, 0).y,
                                 width: vBarW, height: ir.height)),
                     with: .color(.white))
        }
    }

    // MARK: - Connectors

    // Źródło: BVE.NMG2TexturesGL.pas (BVerhue Gen3 source)
    //   CreateConnectorIn  → FillEllipse  = wejścia OKRĄGŁE
    //   CreateConnectorOut → FillRect     = wyjścia KWADRATOWE
    // Oba mają mały ciemny "otworek" (small inner ellipse) w centrum.
    // Kolory: Red=Audio(static/high-rate), Blue=Control+Audio(dynamic), Yellow=Logic

    private func drawConnectors(
        _ ctx: GraphicsContext,
        module: G2Module,
        def: ModuleDef?,
        rect _: CGRect,
        isOutput: Bool
    ) {
        // BVerhue — pozycje; g2ools — kolory (BVerhue .txt upraszcza pitchOrControl→Audio, więc overridujemy g2ools)
        if let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) {
            let list = isOutput ? ui.outputs : ui.inputs
            guard !list.isEmpty else { return }
            let g2conns = isOutput ? (def?.outputs ?? []) : (def?.inputs ?? [])
            for (i, bvConn) in list.enumerated() {
                let center = connectorCenterForDraw(module: module, connIndex: i, isOutput: isOutput)
                let sig: BVSignalType = i < g2conns.count
                    ? bvSignalFrom(connectorColor: g2conns[i].color)
                    : bvConn.signalType
                drawConnector(ctx, center: center, signalType: sig, isOutput: isOutput)
            }
            return
        }

        // Fallback — typ sygnału z ModuleDef (g2ools)
        let conns = isOutput ? (def?.outputs ?? []) : (def?.inputs ?? [])
        guard !conns.isEmpty else { return }
        for (i, conn) in conns.enumerated() {
            let center = connectorCenterForDraw(module: module, connIndex: i, isOutput: isOutput)
            let sig = bvSignalFrom(connectorColor: conn.color)
            drawConnector(ctx, center: center, signalType: sig, isOutput: isOutput)
        }
    }

    /// Rysuje pojedyncze gniazdo kabla.
    /// Wejścia (Input)  = OKRĄGŁE — FillEllipse (jak w BVerhue CreateConnectorIn)
    /// Wyjścia (Output) = KWADRATOWE — FillRect (jak w BVerhue CreateConnectorOut)
    private func drawConnector(
        _ ctx: GraphicsContext,
        center: CGPoint,
        signalType: BVSignalType,
        isOutput: Bool
    ) {
        let half: CGFloat = UIMetrics.connectorHalf
        let holeR: CGFloat = half * 0.35 // promień otworka (inner ellipse)

        // Bikolorowe typy — deleguj do osobnej funkcji
        switch signalType {
        case .pitchOrControl:
            drawBicolorConnector(ctx, center: center,
                                 leftColor: UIColor.connectorAudio,
                                 rightColor: UIColor.connectorControl,
                                 darkColor: UIColor.connectorAudioDark,
                                 isOutput: isOutput)
            return
        case .logicOrControl:
            drawBicolorConnector(ctx, center: center,
                                 leftColor: UIColor.connectorLogic,
                                 rightColor: UIColor.connectorOrange,
                                 darkColor: UIColor.connectorLogicDark,
                                 isOutput: isOutput)
            return
        default: break
        }

        let fillColor: Color
        let darkColor: Color
        switch signalType {
        case .audio:
            fillColor = UIColor.connectorAudio
            darkColor = UIColor.connectorAudioDark
        case .control:
            fillColor = UIColor.connectorControl
            darkColor = UIColor.connectorControlDark
        case .logic:
            fillColor = UIColor.connectorLogic
            darkColor = UIColor.connectorLogicDark
        default:
            fillColor = UIColor.connectorControl
            darkColor = UIColor.connectorControlDark
        }

        if isOutput {
            // KWADRAT — wyjście
            let r = UIMetrics.socketCornerRadius
            // Cień/obwódka
            ctx.fill(Path(roundedRect: CGRect(x: center.x - half - 0.6, y: center.y - half - 0.6,
                                              width: (half + 0.6) * 2, height: (half + 0.6) * 2),
                          cornerRadius: r + 0.6),
                     with: .color(.black.opacity(0.65)))
            // Kolorowy prostokąt
            ctx.fill(Path(roundedRect: CGRect(x: center.x - half, y: center.y - half,
                                              width: half * 2, height: half * 2),
                          cornerRadius: r),
                     with: .color(fillColor))
            // Ciemniejszy obwód (DrawRect — symulacja ramy gniazda)
            ctx.stroke(Path(roundedRect: CGRect(x: center.x - half + 0.5, y: center.y - half + 0.5,
                                                width: (half - 0.5) * 2, height: (half - 0.5) * 2),
                            cornerRadius: max(0, r - 0.5)),
                       with: .color(darkColor), lineWidth: 0.5)
            // Kolorowy pierścień gniazda stoi nad panelem — światło z lewej-góry jak na przyciskach.
            if panelShading { Bevel.raise(ctx, CGRect(x: center.x - half, y: center.y - half, width: half * 2, height: half * 2), cornerRadius: r) }
            // Mały okrągły otworek w centrum
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - holeR, y: center.y - holeR,
                                            width: holeR * 2, height: holeR * 2)),
                     with: .color(.black))
        } else {
            // OKRĄG — wejście
            // Cień
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - half - 0.6, y: center.y - half - 0.6,
                                            width: (half + 0.6) * 2, height: (half + 0.6) * 2)),
                     with: .color(.black.opacity(0.65)))
            // Kolorowa elipsa
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - half, y: center.y - half,
                                            width: half * 2, height: half * 2)),
                     with: .color(fillColor))
            // Ciemniejszy obwód (DrawEllipse)
            ctx.stroke(Path(ellipseIn: CGRect(x: center.x - half + 0.5, y: center.y - half + 0.5,
                                              width: (half - 0.5) * 2, height: (half - 0.5) * 2)),
                       with: .color(darkColor), lineWidth: 0.5)
            // Zaokrąglenie równe połowie boku robi z prostokąta koło — ten sam `Bevel`.
            if panelShading { Bevel.raise(ctx, CGRect(x: center.x - half, y: center.y - half, width: half * 2, height: half * 2), cornerRadius: half) }
            // Mały okrągły otworek w centrum
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - holeR, y: center.y - holeR,
                                            width: holeR * 2, height: holeR * 2)),
                     with: .color(.black))
        }
    }

    /// Rysuje bikolorowe gniazdo: lewa połowa = leftColor, prawa = rightColor.
    /// Wyjście (kwadrat): dwie half-rects. Wejście (okrąg): drawLayer + clip na każdą połowę.
    private func drawBicolorConnector(
        _ ctx: GraphicsContext,
        center: CGPoint,
        leftColor: Color, rightColor: Color,
        darkColor: Color,
        isOutput: Bool
    ) {
        let half: CGFloat = UIMetrics.connectorHalf
        let holeR: CGFloat = half * 0.35

        if isOutput {
            let r = UIMetrics.socketCornerRadius
            let bodyRect = CGRect(x: center.x - half, y: center.y - half,
                                  width: half * 2, height: half * 2)
            // Cień
            ctx.fill(Path(roundedRect: CGRect(x: center.x - half - 0.6, y: center.y - half - 0.6,
                                              width: (half + 0.6) * 2, height: (half + 0.6) * 2),
                          cornerRadius: r + 0.6),
                     with: .color(.black.opacity(0.65)))
            // Lewa połowa — zaokrąglony korpus przycięty do lewej strony
            ctx.drawLayer { lc in
                lc.clip(to: Path(CGRect(x: bodyRect.minX, y: bodyRect.minY,
                                        width: half, height: half * 2)))
                lc.fill(Path(roundedRect: bodyRect, cornerRadius: r), with: .color(leftColor))
            }
            // Prawa połowa
            ctx.drawLayer { lc in
                lc.clip(to: Path(CGRect(x: center.x, y: bodyRect.minY,
                                        width: half, height: half * 2)))
                lc.fill(Path(roundedRect: bodyRect, cornerRadius: r), with: .color(rightColor))
            }
            // Ramka
            ctx.stroke(Path(roundedRect: CGRect(x: center.x - half + 0.5, y: center.y - half + 0.5,
                                                width: (half - 0.5) * 2, height: (half - 0.5) * 2),
                            cornerRadius: max(0, r - 0.5)),
                       with: .color(darkColor), lineWidth: 0.5)
            // Pionowa linia podziału
            var div = Path()
            div.move(to: CGPoint(x: center.x, y: center.y - half + 0.5))
            div.addLine(to: CGPoint(x: center.x, y: center.y + half - 0.5))
            ctx.stroke(div, with: .color(darkColor.opacity(0.7)), lineWidth: 0.5)
            if panelShading { Bevel.raise(ctx, bodyRect, cornerRadius: r) }
            // Otworek
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - holeR, y: center.y - holeR,
                                            width: holeR * 2, height: holeR * 2)),
                     with: .color(.black))
        } else {
            let rect = CGRect(x: center.x - half, y: center.y - half,
                              width: half * 2, height: half * 2)
            // Cień
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - half - 0.6, y: center.y - half - 0.6,
                                            width: (half + 0.6) * 2, height: (half + 0.6) * 2)),
                     with: .color(.black.opacity(0.65)))
            // Lewa półelipsa (drawLayer z clip)
            ctx.drawLayer { lc in
                lc.clip(to: Path(CGRect(x: center.x - half - 0.5, y: center.y - half - 0.5,
                                        width: half + 0.5, height: half * 2 + 1)))
                lc.fill(Path(ellipseIn: rect), with: .color(leftColor))
            }
            // Prawa półelipsa
            ctx.drawLayer { lc in
                lc.clip(to: Path(CGRect(x: center.x, y: center.y - half - 0.5,
                                        width: half + 0.5, height: half * 2 + 1)))
                lc.fill(Path(ellipseIn: rect), with: .color(rightColor))
            }
            // Ramka
            ctx.stroke(Path(ellipseIn: CGRect(x: center.x - half + 0.5, y: center.y - half + 0.5,
                                              width: (half - 0.5) * 2, height: (half - 0.5) * 2)),
                       with: .color(darkColor), lineWidth: 0.5)
            // Pionowa linia podziału
            var div = Path()
            div.move(to: CGPoint(x: center.x, y: center.y - half + 0.5))
            div.addLine(to: CGPoint(x: center.x, y: center.y + half - 0.5))
            ctx.stroke(div, with: .color(darkColor.opacity(0.7)), lineWidth: 0.5)
            if panelShading { Bevel.raise(ctx, rect, cornerRadius: half) }
            // Otworek
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - holeR, y: center.y - holeR,
                                            width: holeR * 2, height: holeR * 2)),
                     with: .color(.black))
        }
    }

    /// Mapuje ConnectorColor (g2ools) → BVSignalType dla fallbacku (moduły bez BVerhue .txt).
    /// blue_red → audio (red): większość to miksery/procesory audio
    /// yellow_orange → logic (yellow): sygnały logiczne
    private func bvSignalFrom(connectorColor: ConnectorColor) -> BVSignalType {
        switch connectorColor {
        case .audio: .audio
        case .control: .control
        case .logic: .logic
        case .pitchOrControl: .control // blue_red → niebieski (jak w oryginale G2)
        case .logicOrControl: .logic // yellow_orange → żółty
        }
    }

    // MARK: - Connector name labels

    /// Rysuje nazwy gniazd kabli z ModuleDatabase (np. "Pitch", "Gate", "In", "Out").
    /// Tylko dla modułów BEZ PNG bitmapy — w bitmapie napisy są wypieczone w CBMP.
    /// Etykieta wycentrowana poziomo nad każdym gniazdem.
    private func drawConnectorLabels(
        _ ctx: GraphicsContext,
        module: G2Module,
        def: ModuleDef?,
        rect _: CGRect
    ) {
        // BVerhue .txt ma własną (choćby świadomie puste) definicję etykiet —
        // nie dubluj z ConnectorDef.name. Fallback tylko gdy mapowania na BVerhue
        // w ogóle nie znaleziono (np. Constant: brak <#Text> = oryginał nie
        // podpisuje jedynego wyjścia "Out", to nie dziura w danych).
        if ModuleUIDatabase.shared.uiDef(forID: module.typeID) != nil { return }
        guard let d = def else { return }

        let fontSize: CGFloat = 3.5
        let half = UIMetrics.connectorHalf

        for isOutput in [false, true] {
            let conns = isOutput ? d.outputs : d.inputs
            for (i, conn) in conns.enumerated() {
                guard !conn.name.isEmpty else { continue }
                let center = connectorCenterForDraw(module: module, connIndex: i, isOutput: isOutput)
                ctx.draw(
                    Text(conn.name)
                        .font(.system(size: fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(UIColor.textLabel),
                    at: CGPoint(x: center.x, y: center.y - half - 1.8),
                    anchor: .bottom
                )
            }
        }
    }

    // MARK: - ButtonFlat / ButtonText / ButtonIncDec

    /// Cache na NSImage ikon ButtonRadio (tworzone raz, nie na każdej klatce)
    private static var iconImageCache: [String: Image] = [:]

    /// Rysuje przyciski z opcjami tekstowymi (BVButtonFlat) i małe checkboxy (BVButtonText).
    /// Pozycja pionowa ButtonRadio współdzielona przez rysowanie i hit-testing.
    /// FltClassic wyrównuje dolną krawędź selektora 12/18/24 do zewnętrznej
    /// krawędzi kwadratowego gniazda wyjściowego.
    func buttonRadioYPt(moduleTypeID: Int, button: BVButtonRadio, ui: ModuleUIDef) -> CGFloat {
        if [3, 171].contains(moduleTypeID), button.codeRef == 0,
           let power = ui.buttonsText.first(where: { $0.codeRef == 1 })
        {
            // 4-Out/4-In: align the destination group with the visible outer edge of Power.
            let powerBottom = power.yPt + UIMetrics.buttonTextHeight / 2
                + UIMetrics.powerButtonSize / 2 + UIMetrics.socketOuterMargin
            return powerBottom - UIMetrics.buttonRadioHeight
        }

        if moduleTypeID == 199, button.codeRef == 0,
           let output = ui.outputs.first(where: { $0.codeRef == 0 })
        {
            // MonoKey: align Last/Lo/Hi with the visible outer edge of the output sockets.
            let sourceConnectorHalf = 5.5 * PatchLayout.bverhuePixelScale
            let outputBottom = output.yPt + sourceConnectorHalf
                + UIMetrics.connectorHalf + UIMetrics.socketOuterMargin
            return outputBottom - UIMetrics.buttonRadioHeight
        }

        guard moduleTypeID == 92, button.codeRef == 4,
              let output = ui.outputs.first(where: { $0.codeRef == 0 })
        else { return button.yPt }

        let sourceConnectorHalf = 5.5 * PatchLayout.bverhuePixelScale
        let outputBottom = output.yPt + sourceConnectorHalf
            + UIMetrics.connectorHalf + UIMetrics.socketOuterMargin
        return outputBottom - UIMetrics.buttonRadioHeight
    }

    private func drawBVButtons(_ ctx: GraphicsContext, module: G2Module, rect: CGRect) {
        guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { return }
        let d = moduleDefinition(module.typeID)

        // ── ButtonFlat ─────────────────────────────────────────────────────────
        // Kolor: gaśnie tylko gdy pierwsza opcja = "Off" i aktualnie wybrana = Off.
        // Bez Off: zawsze podświetlony (wszystkie stany = aktywne).
        // Gdy options==[] i imageCount>0 → przycisk ikonowy (np. Loop/Run, InfoFunc:9).
        for btn in ui.buttonsFlat {
            let value = btn.codeRef < module.parameters.count
                ? module.parameters[btn.codeRef] : 0

            // OscB (typeID:7): "On" (CodeRef:2) styka się z etykietą "KBT" —
            // wyrównaj jego prawą krawędź z przyciskiem "FM Lin" (CodeRef:10) poniżej.
            var btnXPt = btn.xPt
            if module.typeID == 7, btn.codeRef == 2,
               let fmLin = ui.buttonsFlat.first(where: { $0.codeRef == 10 })
            {
                btnXPt = fmLin.xPt + fmLin.widthPt - btn.widthPt
            }

            let x = rect.minX + btnXPt
            // Wyrównaj Y do pobliskiego RadioButton (±3 pt) — np. "0dB" w 2-In
            let alignedYPt = flatButtonYPt(module: module, button: btn, ui: ui)
            var y = rect.minY + alignedYPt
            // OscD: przycisk trybu "Semi/Freq/Fac/Part" (CodeRef:3) ma w źródle YPos o
            // 1 Gen1px niższy start niż sąsiedni ekran "+0 +0" (TextField MasterRef:0), ale
            // jest też wyższy (buttonFlatHeight 7 vs textFieldHeight 6.5) — razem wypadał
            // wyraźnie niżej niż środek ekranu. Wyrównaj do WSPÓLNEGO środka.
            if module.typeID == 96, btn.codeRef == 3,
               let field = ui.textFields.first(where: { $0.masterRef == 0 })
            {
                let fieldCenterY = field.yPt + UIMetrics.textFieldHeight / 2
                y = rect.minY + fieldCenterY - UIMetrics.buttonFlatHeight / 2
            } else if let field = ui.textFields.first(where: {
                // Ekran stojący W TYM SAMYM RZĘDZIE tuż PO PRAWEJ stronie przycisku
                // (LfoC: „Rate Lo" + ekran „0.64Hz"). W danych Gen1 oba widżety mają
                // inne wysokości niż nasze stałe, więc same YPos rozjeżdżają ich środki
                // o ~0,8pt — w oryginale stoją równo. Ta sama korekta co OscD wyżej.
                abs($0.yPt - btn.yPt) < 1.5
                    && $0.xPt >= btn.xPt + btn.widthPt - 1.0
                    && $0.xPt <= btn.xPt + btn.widthPt + 6.0
            }) {
                let fieldCenterY = field.yPt + UIMetrics.textFieldHeight / 2
                y = rect.minY + fieldCenterY - UIMetrics.buttonFlatHeight / 2
            }
            if module.typeID == 180, [18, 20].contains(btn.codeRef) {
                // Nadpisz ogólne wyrównanie do pobliskiego pola: dolne przyciski
                // Operatora należą do przesuniętego rzędu L/R-Depth.
                y = rect.minY + flatButtonYPt(module: module, button: btn, ui: ui)
            }
            // Wąskie ButtonFlat (np. T/G w SeqEvent) → rozmiar jak step-button
            let isStepSized = btn.widthPt < UIMetrics.buttonFlatHeight
            let w = isStepSized ? UIMetrics.seqFaderWidth : max(btn.widthPt, 8)
            let h: CGFloat = isStepSized ? UIMetrics.seqFaderWidth : UIMetrics.buttonFlatHeight
            let btnRect = CGRect(x: x, y: y, width: w, height: h)

            // Przycisk ikonowy (brak opcji tekstowych, ale ma ikony — np. Loop/Run)
            if btn.options.isEmpty {
                if btn.infoFunc == 9 {
                    drawBVRunLoopIcon(ctx, in: btnRect, isLoop: value != 0)
                }
                continue
            }

            let optIdx = max(0, min(value, btn.options.count - 1))
            // BVerhue zapisuje część list ze spacją wiodącą (MixFader: `" 0dB,-6dB,-12dB"`),
            // przez którą napis siadał wyraźnie na prawo od środka przycisku.
            let label = btn.options[optIdx].trimmingCharacters(in: .whitespaces)
            let hasOff = btn.options.first?.lowercased() == "off"
            let isOff = hasOff && optIdx == 0
            let bg: Color = isOff ? UIColor.buttonInactive : UIColor.buttonActive

            PanelFace.raised(ctx, btnRect, cornerRadius: UIMetrics.buttonFlatCornerRadius,
                             fill: bg, shaded: panelShading)
            ctx.draw(
                Text(label)
                    .font(.system(size: UIFont.buttonLabel, weight: .bold))
                    .foregroundColor(isOff ? Color(white: 0.20) : .white),
                at: CGPoint(
                    x: opticalCenterX(label, in: btnRect,
                                      fontSize: UIFont.buttonLabel, weight: .bold),
                    y: y + h / 2
                ),
                anchor: .center
            )
        }

        // ── ButtonText ─────────────────────────────────────────────────────────
        // Gdy codeRef wskazuje na parametr "Active" → ikona power zamiast tekstu.
        // Gdy text=="" → step-button (checkbox) bez etykiety.
        for btn in ui.buttonsText {
            let value = btn.codeRef < module.parameters.count
                ? module.parameters[btn.codeRef] : 0

            // Operator: "KB" (CodeRef:24, ButtonText Check/Slim) jest innym typem
            // widżetu niż "On" (CodeRef:0, ButtonFlat Slim) nad nim — różne stałe
            // wysokości (buttonTextHeight 6.5 vs buttonFlatHeight 7.0) i inna surowa
            // szerokość (18 vs 20 Gen1px) dawały zauważalnie mniejszy przycisk, źle
            // wyśrodkowany względem "On". Przejmij DOKŁADNIE wymiary i oś X "On",
            // żeby oba przyciski wyglądały jak ta sama rodzina widżetów.
            let kbtFlat = module.typeID == 180 && btn.codeRef == 24
                ? ui.buttonsFlat.first(where: { $0.codeRef == 0 })
                : nil
            let x = rect.minX + (kbtFlat?.xPt ?? btn.xPt)
            let y = rect.minY + rndClkADiceYPt(module: module, btn: btn, ui: ui)
            let w = kbtFlat.map { max($0.widthPt, 8) } ?? max(btn.widthPt, 6)
            let h: CGFloat = kbtFlat != nil
                ? UIMetrics.buttonFlatHeight
                : buttonTextHeight(module: module, button: btn)
            let isOn = value != 0

            // Clr/Rnd: chwilowe podświetlenie zamiast stałego stanu
            let isFlashing = momentaryFlash.map { $0.moduleID == module.id && $0.codeRef == btn.codeRef } ?? false
            let effectiveOn = isOn || isFlashing

            let isActive = d?.paramNames.indices.contains(btn.codeRef) == true
                && d?.paramNames[btn.codeRef] == "Active"

            // Niektóre przyciski Active (np. MetNoise) nie mają tekstu w danych
            // BVerhue. Muszą jednak dostać pełny wygląd Power, a nie wygląd
            // bezimiennego przycisku sekwencera.
            if isActive {
                let margin = UIMetrics.socketOuterMargin
                let greenRect = powerButtonRect(module: module, button: btn, ui: ui, rect: rect)
                let outerRect = greenRect.insetBy(dx: -margin, dy: -margin)
                ctx.fill(Path(roundedRect: outerRect, cornerRadius: UIMetrics.socketCornerRadius + margin),
                         with: .color(.black.opacity(0.65)))
                ctx.fill(Path(roundedRect: greenRect, cornerRadius: UIMetrics.socketCornerRadius),
                         with: .color(effectiveOn ? UIColor.powerButtonOn : UIColor.powerButtonOff))
                if panelShading { Bevel.raise(ctx, greenRect, cornerRadius: UIMetrics.socketCornerRadius) }
                drawPowerIcon(ctx, in: greenRect, isOn: effectiveOn)
                continue
            }

            if btn.text.isEmpty {
                // Step-enable button (np. SeqCtr/SeqLev/SeqNote) — kwadrat o boku =
                // szerokość fadera. Kwadrat jest NIŻSZY niż nominalna wysokość
                // przycisku tekstowego, więc siada na osi rzędu (tej samej, którą
                // wyrównuje `ModuleUILayout` i przez którą biegnie magistrala) —
                // rysowany od surowego YPos wypadał pół punktu za nisko.
                let bw = UIMetrics.seqFaderWidth
                let btnRect = CGRect(x: x + sequencerColumnOffset(ui: ui),
                                     y: y + (UIMetrics.buttonTextHeight - bw) / 2,
                                     width: bw, height: bw)
                let bg: Color = isOn ? UIColor.buttonActive : UIColor.buttonInactive
                PanelFace.raised(ctx, btnRect, cornerRadius: 0.5,
                                 fill: bg, border: .black.opacity(0.4), shaded: panelShading)
                continue
            }

            // Sync in Operator uses the same dimensions and surface style as
            // ButtonFlat controls while retaining ButtonText toggle behavior.
            let usesFlatStyle = module.typeID == 180 && btn.codeRef == 1
            let corner = usesFlatStyle
                ? UIMetrics.buttonFlatCornerRadius
                : UIMetrics.socketCornerRadius
            let bg: Color = if usesFlatStyle {
                effectiveOn ? UIColor.buttonActive : UIColor.buttonInactive
            } else {
                effectiveOn ? UIColor.buttonTextOn : UIColor.buttonNeutral
            }
            let borderOpacity = usesFlatStyle ? 0.45 : 0.4
            let inactiveText = Color(white: usesFlatStyle ? 0.20 : 0.25)

            // KeyQuant (152): klawiatura — te same kolory co każdy inny przycisk
            // (szary nieaktywny / niebieski `buttonTextOn` po wciśnięciu), tylko
            // węższa: generyczne minimum szerokości przycisku (6pt) było SZERSZE
            // niż odstęp między klawiszami w BVerhue (5.47pt), więc się nakładały.
            if module.typeID == 152 {
                let keyW = max(btn.widthPt - 0.5, 4.0)
                let keyRect = CGRect(x: x, y: y, width: keyW, height: h)
                let keyBg: Color = effectiveOn ? UIColor.buttonTextOn : UIColor.buttonNeutral
                // Klawisz jest przyciskiem, więc wypukły jak reszta (do 2026-09-27 płaski).
                PanelFace.raised(ctx, keyRect, cornerRadius: corner,
                                 fill: keyBg, border: .black.opacity(0.4), shaded: panelShading)
                let keyFontSize: CGFloat = btn.text.count > 1 ? 3.1 : 3.7
                ctx.draw(
                    Text(btn.text)
                        .font(.system(size: keyFontSize, weight: .bold))
                        .fontWidth(.condensed)
                        .tracking(-0.2)
                        .foregroundColor(effectiveOn ? .white : Color(white: 0.25)),
                    at: CGPoint(x: keyRect.midX, y: keyRect.midY),
                    anchor: .center
                )
                continue
            }

            let btnRect = CGRect(x: x, y: y, width: w, height: h)
            PanelFace.raised(ctx, btnRect, cornerRadius: corner,
                             fill: bg, border: .black.opacity(borderOpacity), shaded: panelShading)

            ctx.draw(
                Text(btn.text)
                    .font(.system(size: UIFont.buttonLabel, weight: .bold))
                    .foregroundColor(effectiveOn ? .white : inactiveText),
                at: CGPoint(
                    x: opticalCenterX(btn.text, in: btnRect,
                                      fontSize: UIFont.buttonLabel, weight: .bold),
                    y: y + h / 2
                ),
                anchor: .center
            )
        }

        // ── ButtonRadio ─────────────────────────────────────────────────────────
        for btn in ui.buttonsRadio {
            guard btn.buttonCount > 0 else { continue }
            let value = btn.codeRef < module.parameters.count
                ? module.parameters[btn.codeRef] : 0
            let selIdx = max(0, min(value, btn.buttonCount - 1))
            let x0 = rect.minX + btn.xPt
            let y0 = rect.minY + buttonRadioYPt(moduleTypeID: module.typeID, button: btn, ui: ui)
            // Grupa kończąca się dokładnie na X=256 w danych BVerhue (OscA, OscShpA
            // i inne selektory fal) sięga w Canvasie prawej krawędzi panelu, przez co
            // obrys ostatniego radia optycznie nachodzi na ukośną ramkę modułu.
            // Rozdziel 1.5 pt równo na wszystkie przyciski, bez zmiany ich kolejności.
            let rawWidth = max(btn.buttonWidthPt, UIMetrics.buttonRadioMinWidth)
            let isHorizontal = btn.orientation != "Vertical"
            // Pionowa grupa ma szerokość JEDNEGO przycisku — liczenie jej jak poziomej
            // (count × rawWidth) fałszywie wykrywało nachodzenie na sąsiedni ekran i
            // ściskało przyciski (FltNord BR/HP/BP/LP obok wykresu filtra).
            let groupWidth = CGFloat(btn.columns) * rawWidth
            let touchesRightEdge = btn.xPt + groupWidth > rect.width - 0.5
            // Grupa może też nachodzić na ekran (Graph) stojący bezpośrednio na prawo w
            // tym samym wierszu, nie tylko na krawędź modułu (np. LfoShpA: przyciski fal
            // kończą się na XPos:200 z Width:18×6, ekran zaczyna się tuż obok na
            // XPos:199) — dociśnij inset także do lewej krawędzi takiego ekranu.
            let overlappingGraph = isHorizontal ? ui.graphs.first {
                $0.xPt >= btn.xPt && $0.xPt < btn.xPt + groupWidth + 2.0 && abs($0.yPt - btn.yPt) < 6.0
            } : nil
            let graphOverlapInset = overlappingGraph.map { max(0, btn.xPt + groupWidth - $0.xPt + 1.5) } ?? 0
            let rightInset: CGFloat = max(
                isHorizontal && touchesRightEdge ? 1.5 : 0,
                graphOverlapInset
            )
            let bw = rawWidth - rightInset / CGFloat(btn.columns)
            let bh: CGFloat = UIMetrics.buttonRadioHeight
            let isVert = btn.orientation == "Vertical"
            // Pikselowe ikony dostępne?
            let hasPixels = !btn.iconPixels.isEmpty && btn.iconWidth > 0
            let iconH = hasPixels && btn.buttonCount > 0
                ? btn.iconPixels.count / (btn.buttonCount * btn.iconWidth) : 0

            for i in 0 ..< btn.buttonCount {
                // BVerhue Text kolejność: labels[0]=BR...labels[3]=LP (góra→dół wizualnie).
                // Protokół G2: value 0=LP, 1=BP, 2=HP, 3=BR (odwrócone względem label index).
                // drawPos = i → labels[0] na górze (zgodnie z oryginałem Clavii).
                // isSelected: value v → label index (count-1-v) jest aktywny.
                let drawPos = i
                let bx = x0 + CGFloat(drawPos % btn.columns) * bw
                let by = y0 + CGFloat(drawPos / btn.columns) * bh
                let br = CGRect(x: bx, y: by, width: bw - 0.5,
                                height: bh - (btn.rows > 1 ? 0.5 : 0))
                let isSelected = isVert
                    ? (i == btn.buttonCount - 1 - selIdx)
                    : (i == selIdx)

                let bg: Color = isSelected ? UIColor.radioSelected : UIColor.buttonInactive
                PanelFace.raised(ctx, br, cornerRadius: 1.0,
                                 fill: bg, shaded: panelShading)

                let pad: CGFloat = 1.0
                let iconRect = br.insetBy(dx: pad, dy: pad)
                let iconColor: Color = isSelected ? .white : Color(white: 0.20)

                // LfoShpA (165): oryginał (Lfo C Graph, patrz Docs/ui/
                // bverhue-behavior) potwierdza, że to ta sama rodzina krzywych co
                // ekran wykresu tego modułu (Sin2Saw/CosBell/TriBell/Tri2Saw/SqrTri/
                // Square) — zamiast surowej bitmapy Gen1 (placeholder z cyframi
                // 1-5 zamiast ikon) używamy krzywych, jak OscShpA w drawRadioIcon.
                // Była tu jeszcze gałąź `pixelOnlyInfoFuncs` — lista InfoFunc, które mają
                // iść surową bitmapą mimo dostępnego wektora. Wyczyszczono ją 2026-08-20
                // (ostatnie pozycje 164/165 dostały krzywe), więc warunek był od tego czasu
                // zawsze fałszywy. Usunięta 2026-08-28.
                let vectorInfoFuncs: Set = [58, 83, 84, 106, 136, 155, 156, 164, 165]

                if i < btn.buttonLabels.count,
                   !(vectorInfoFuncs.contains(btn.infoFunc) && Int(btn.buttonLabels[i]) != nil)
                {
                    // ── Etykiety tekstowe — priorytet nad ikonami wektorowymi ─
                    // (gdy .txt dostarcza Text:"BR,HP,BP,LP" itp., używamy tekstu).
                    // Wyjątek: LfoB (infoFunc:164) ma w źródle placeholder "1,2,3,4,5"
                    // (same cyfry, nie prawdziwe nazwy) zamiast ikon fal jak LfoA —
                    // dla infoFunc z listy wektorowej numeryczny placeholder ustępuje
                    // ikonie sinus/trójkąt/piła/kwadrat.
                    let label = btn.buttonLabels[i]
                    ctx.draw(
                        Text(label)
                            .font(.system(size: UIFont.radioLabel, weight: .bold))
                            .foregroundColor(isSelected ? .white : Color(white: 0.20)),
                        at: CGPoint(x: br.midX, y: br.midY),
                        anchor: .center
                    )

                } else if vectorInfoFuncs.contains(btn.infoFunc) {
                    // ── Wektorowe ikony fal / filtrów (gdy brak etykiet tekstowych) ──
                    drawRadioIcon(ctx, rect: iconRect, infoFunc: btn.infoFunc,
                                  count: btn.buttonCount, index: i, color: iconColor)

                } else if hasPixels, iconH > 0 {
                    // ── Pikselowe ikony (pozostałe typy) ──────────────────────
                    // Sprawdzone 2026-08-28: przy obecnych danych Gen1 ŻADEN ButtonRadio
                    // tu nie dochodzi — wszystkie mają albo etykiety, albo InfoFunc
                    // z listy wektorowej. Gałąź zostaje jako zabezpieczenie na wypadek
                    // zmiany danych; opis → [[Docs/ui/bitmap-audit]].
                    let cacheKey = "\(btn.iconPixels.count)_\(btn.iconWidth)_\(btn.buttonCount)_\(i)_\(isSelected)"
                    let img: Image
                    if let cached = Self.iconImageCache[cacheKey] {
                        img = cached
                    } else {
                        let ns = makeRadioButtonImage(
                            pixels: btn.iconPixels,
                            iconW: btn.iconWidth, iconH: iconH,
                            buttonCount: btn.buttonCount, index: i,
                            selected: isSelected
                        )
                        let built = Image(nsImage: ns)
                        Self.iconImageCache[cacheKey] = built
                        img = built
                    }
                    ctx.draw(img, in: iconRect)

                } else {
                    // ── Fallback geometryczny ─────────────────────────────────
                    drawRadioIcon(ctx, rect: iconRect, infoFunc: btn.infoFunc,
                                  count: btn.buttonCount, index: i, color: iconColor)
                }
            }
        }

        // ButtonIncDec — kwadratowe przyciski + / −.
        // Type:"Up/Down" (większość modułów, np. LevScaler "BP") → jeden nad drugim.
        // Type:"Left/Right" (np. SeqLev, SeqA) → obok siebie — zgodnie z oryginałem Clavii.
        for btn in ui.incDecButtons {
            let origin = operatorIncDecOrigin(module: module, button: btn)
            let x = rect.minX + origin.x
            let s: CGFloat = UIMetrics.incDecHeight // bok kwadratu
            let gap: CGFloat = UIMetrics.incDecGap

            // Surowy YPos z BVerhue czasem zostawia parę przycisków tak nisko, że
            // dolny dotyka (lub wychodzi poza) dolną krawędź modułu — np. ClkDiv
            // "Divider" miał <1.2pt marginesu. Dociśnij parę w górę, żeby zachować
            // minimalny margines od dołu; nie rusza modułów, gdzie już jest OK.
            let totalH = btn.isVertical ? s * 2 + gap : s
            let bottomMargin: CGFloat = 1.0
            let y = min(rect.minY + origin.y, rect.maxY - bottomMargin - totalH)

            // Pionowo: „+" u góry, „−" u dołu (bez zmian). Poziomo: „−" z LEWEJ,
            // „+" z PRAWEJ — jak przy pokrętłach (kręcenie w prawo = wzrost) i jak
            // w KAŻDYM innym poziomym rzędzie +/- w tej aplikacji; poprzedni układ
            // (+ z lewej) był tu jedynym wyjątkiem. `upRect`/`dnRect` oznaczają WIĘC
            // zawsze „przycisk zwiększający"/„zmniejszający", nie „lewy"/„prawy" —
            // ta sama zamiana musi się powtórzyć w `findIncDecButton` (Gestures.swift).
            let leftRect = CGRect(x: x, y: y, width: s, height: s)
            let secondRect = btn.isVertical
                ? CGRect(x: x, y: y + s + gap, width: s, height: s)
                : CGRect(x: x + s + gap, y: y, width: s, height: s)
            let upRect = btn.isVertical ? leftRect : secondRect
            let dnRect = btn.isVertical ? secondRect : leftRect

            let upHeld = incDecHold?.moduleID == module.id && incDecHold?.codeRef == btn.codeRef
                && incDecHold?.isUp == true
            let dnHeld = incDecHold?.moduleID == module.id && incDecHold?.codeRef == btn.codeRef
                && incDecHold?.isUp == false
            if ui.name == "SeqVal", btn.isVertical {
                drawSeqIncDecButton(ctx, x: upRect.minX, y: upRect.minY,
                                    w: upRect.width, h: upRect.height, isUp: true,
                                    highlighted: upHeld)
                drawSeqIncDecButton(ctx, x: dnRect.minX, y: dnRect.minY,
                                    w: dnRect.width, h: dnRect.height, isUp: false,
                                    highlighted: dnHeld)
            } else {
                drawIncDecButton(ctx, rect: upRect, isPlus: true, highlighted: upHeld)
                drawIncDecButton(ctx, rect: dnRect, isPlus: false, highlighted: dnHeld)
            }
        }
    }

    /// Rendered ButtonText height shared by drawing and hit testing.
    /// Only Operator Sync adopts the 7 pt ButtonFlat metric.
    /// Zielony kwadrat przycisku Power (parametr „Active"), bez ciemnej obwódki
    /// `socketOuterMargin`. Wspólny dla samego przycisku i dla linii panelu, które
    /// kończą się na jego obwódce (`drawBVLines`).
    func powerButtonRect(module: G2Module, button btn: BVButtonText, ui: ModuleUIDef, rect: CGRect) -> CGRect {
        let x = rect.minX + btn.xPt
        let w = max(btn.widthPt, 6)
        let h = buttonTextHeight(module: module, button: btn)
        let margin = UIMetrics.socketOuterMargin
        let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
        let size = UIMetrics.powerButtonSize
        let leftPt = (x - rect.minX) + (w - size) / 2 // lewa krawędź zielonego kwadratu
        func overlapsHorizontally(_ conn: BVConnector) -> Bool {
            conn.xPt + 2 * connHalf > leftPt && conn.xPt < leftPt + size
        }

        // Power stoi w dolnym rzędzie razem z gniazdem i przyciskiem Pos/Neg/Bip
        // (LevelShift). Wszystkie trzy mają w Gen1 ten sam YPos, ale różne
        // wysokości widżetu, więc licząc środek od własnej wysokości Power
        // wypadał ~0,25pt niżej niż tamte dwa. Bierzemy tę samą oś co
        // gniazdo/LevelShift (patrz `levelShiftRect`) — ale TYLKO dla gniazda
        // stojącego OBOK w tym samym wierszu, nie dla gniazda pod spodem.
        // Najbliższe w poziomie, nie pierwsze z listy (patrz `levelShiftRect`).
        let rowConn = (ui.inputs + ui.outputs)
            .filter { abs($0.yPt - btn.yPt) < 4.0 && !overlapsHorizontally($0) }
            .min { abs($0.xPt - leftPt) < abs($1.xPt - leftPt) }
        var centerY = rect.minY + (rowConn.map { $0.yPt + connHalf } ?? (btn.yPt + h / 2))

        // Gniazdo USTAWIONE PIONOWO POD Power (LfoC, RndState, RndStep mają w
        // Gen1 tylko 12px odstępu zamiast 13px jak Noise) — przy naszych
        // rozmiarach obwódki oba prostokąty nachodziłyby na siebie. Podnosimy
        // Power tak, żeby została taka sama minimalna szczelina jak w Noise.
        let minGap: CGFloat = 0.07
        if let below = (ui.inputs + ui.outputs).first(where: {
            $0.yPt > btn.yPt && overlapsHorizontally($0)
        }) {
            let socketOuterTop = rect.minY + below.yPt + connHalf - UIMetrics.connectorHalf - margin
            centerY = min(centerY, socketOuterTop - minGap - margin - size / 2)
        }

        return CGRect(x: x + (w - size) / 2, y: centerY - size / 2, width: size, height: size)
    }

    func buttonTextHeight(module: G2Module, button: BVButtonText) -> CGFloat {
        module.typeID == 180 && button.codeRef == 1
            ? UIMetrics.buttonFlatHeight
            : UIMetrics.buttonTextHeight
    }

    /// Operator ma wspólną szerokość dla odczytów jedno- i dwucyfrowych, dzięki czemu
    /// wartości nie zmieniają optycznego rozmiaru — dotyczy to też AMod (2026-08-12:
    /// dopasowany do BrPoint/L-Depth/R-Depth zamiast surowej, węższej szerokości z BVerhue).
    /// Współrzędne są wspólne dla rysowania oraz obsługi kliknięcia.
    /// RndClkA: przycisk „Dice" (losowanie wzorca, CodeRef 2) w źródle stoi wyżej niż
    /// „Poly" w tym samym rzędzie — wyrównaj do jego wysokości, tak samo jak ekran
    /// „Step" w `operatorTextFieldFrame`, żeby cały rząd siedział na jednej osi.
    /// Wspólna funkcja dla rysowania i obsługi kliknięcia/najechania.
    func rndClkADiceYPt(module: G2Module, btn: BVButtonText, ui: ModuleUIDef) -> CGFloat {
        if module.typeID == 180, btn.codeRef == 24,
           let envelope = ui.graphs.first(where: { $0.graphFunc == 29 })
        {
            // Operator: KB ends on the lower edge of the Envelope graph.
            return envelope.yPt + envelope.heightPt - UIMetrics.buttonFlatHeight
        }
        if module.typeID == 180, btn.codeRef == 1,
           let kbt = ui.buttonsFlat.first(where: { $0.codeRef == 0 })
        {
            // Operator: Sync ends on the same lower edge as the KBT switch.
            return kbt.yPt + UIMetrics.buttonFlatHeight
                - buttonTextHeight(module: module, button: btn)
        }
        guard module.typeID == 204, btn.codeRef == 2,
              let poly = ui.buttonsFlat.first(where: { $0.codeRef == 1 })
        else { return btn.yPt }
        return poly.yPt + UIMetrics.buttonFlatHeight / 2 - UIMetrics.buttonTextHeight / 2
    }

    /// Wspólna pozycja pionowa ButtonFlat dla rysowania, kliknięcia i hovera.
    /// Operator ma przyciski rodzaju krzywej obok ekranów L/R-Depth; ich górne
    /// krawędzie muszą być optycznie zrównane z ramką LCD i nie wchodzić w etykiety.
    func flatButtonYPt(module: G2Module, button: BVButtonFlat, ui: ModuleUIDef) -> CGFloat {
        if module.typeID == 180, button.codeRef == 2,
           let field = ui.textFields.first(where: { $0.id == 32 })
        {
            // Operator: Ratio's selector and LCD retain their source spacing while
            // the LCD's lower edge follows the KBT/Sync row.
            let frame = operatorTextFieldFrame(module: module, field: field)
            return frame.y - 16 * PatchLayout.bverhuePixelScale
        }
        if module.typeID == 180, [18, 20].contains(button.codeRef),
           let field = ui.textFields.first(where: { $0.masterRef == button.codeRef + 1 })
        {
            // Operator: the -Lin/-Exp button ends on the shared lower edge of
            // the BrPoint, L-Depth and R-Depth controls.
            return operatorTextFieldFrame(module: module, field: field).y
        }
        return ui.buttonsRadio.first(where: { abs($0.yPt - button.yPt) < 3.0 })?.yPt ?? button.yPt
    }

    func operatorTextFieldFrame(module: G2Module, field: BVTextField) -> (x: CGFloat, y: CGFloat, width: CGFloat) {
        if let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID),
           let row = sequencerLengthRow(module: module, ui: ui),
           ui.textFields.first(where: { $0.id == field.id }) != nil,
           field.yPt < PatchLayout.headerH,
           ui.incDecButtons.contains(where: { !$0.isVertical && $0.xPt < field.xPt })
        {
            // Ekran Length — pozycja z równomiernego rozkładu całego rzędu.
            return (row.fieldX, field.yPt, field.widthPt)
        }
        // SeqVal: ekrany kroków wiszą na pionowych magistralach — każdy stoi na osi
        // swojej kreski. Rysowana szerokość ma minimum, więc surowy XPos zostawiał
        // ekran przesunięty względem linii, która przez niego przechodzi.
        if module.typeID == 145,
           let ui = ModuleUIDatabase.shared.uiDef(forID: 145),
           field.yPt > PatchLayout.headerH
        {
            let width = max(field.widthPt, UIMetrics.textFieldMinWidth)
            let center = field.xPt + width / 2
            if let line = ui.lines
                .filter({ !$0.isHorizontal })
                .min(by: { abs($0.xPt - center) < abs($1.xPt - center) }),
                abs(line.xPt - center) < width / 2
            {
                return (line.xPt - width / 2, field.yPt, field.widthPt)
            }
        }
        if module.typeID == 178, field.masterRef == 0 {
            // DlyClock: „Sample Delay” i jego LCD tworzą pojedynczą, wyśrodkowaną
            // grupę. Surowe YPos:8 z BVerhue jest o jeden piksel źródłowy wyżej.
            let moduleCenterY = PatchLayout.ySpan
            return (field.xPt, moduleCenterY - UIMetrics.textFieldHeight / 2, field.widthPt)
        }
        if module.typeID == 98, field.masterRef == 0,
           let rangeButton = ModuleUIDatabase.shared.uiDef(forID: 98)?.buttonsFlat.first(where: { $0.codeRef == 2 })
        {
            // FreqShift: ekran Freq Shift jest dołem na osi przycisku „Range”.
            let y = rangeButton.yPt + UIMetrics.buttonFlatHeight - UIMetrics.textFieldHeight
            return (field.xPt, y, field.widthPt)
        }
        if [176, 177].contains(module.typeID), field.masterRef == 0,
           let selector = ModuleUIDatabase.shared.uiDef(forID: module.typeID)?.partSelectors.first
        {
            // Delay A/B: ekran Time ma wspólną dolną krawędź z ekranem „Range”.
            let y = selector.yPt + selector.heightPt - UIMetrics.textFieldHeight
            return (field.xPt, y, field.widthPt)
        }
        if module.typeID == 192, field.masterRef == 1,
           let typeButton = ModuleUIDatabase.shared.uiDef(forID: 192)?.buttonsFlat.first(where: { $0.codeRef == 0 })
        {
            // Phaser: Rate jest dołem na osi przycisku „Type I”.
            let y = typeButton.yPt + UIMetrics.buttonFlatHeight - UIMetrics.textFieldHeight
            return (field.xPt, y, field.widthPt)
        }
        if module.typeID == 12, [0, 1].contains(field.masterRef),
           let selector = ModuleUIDatabase.shared.uiDef(forID: 12)?.partSelectors.first
        {
            // Reverb: Time i Brightness mają wspólną dolną krawędź z pierwszym
            // ekranem „Type”, zamiast surowej górnej osi z Gen1.
            let y = selector.yPt + selector.heightPt - UIMetrics.textFieldHeight
            return (field.xPt, y, field.widthPt)
        }
        if module.typeID == 8, field.id == 17 {
            // OscShpB: pole „Shape %” (BVerhue YPos:7) i pole „+0 +0” (ID:7, YPos:4)
            // stoją wizualnie w jednym rzędzie ekranów, ale mają różny YPos w źródle —
            // wyrównaj do tego pierwszego, żeby oba LCD leżały na wspólnej osi.
            return (field.xPt, 4 * PatchLayout.bverhuePixelScale, field.widthPt)
        }
        if [204, 205].contains(module.typeID), field.masterRef == 0,
           let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID),
           let poly = ui.buttonsFlat.first(where: { $0.codeRef == (module.typeID == 204 ? 1 : 3) })
        {
            // RndClkA/RndTrig: ekran „Step"/„Prob" % w źródle stoi ciasno pod swoją
            // etykietą (etykieta ma literę z ogonkiem, np. „Step" — dosłownie dotykała
            // ekranu). Wyrównaj do wysokości przycisku „Poly" w tym samym rzędzie —
            // odsuwa to ekran od etykiety WŁAŚCIWYM sposobem (przez miejsce, nie przez
            // ciaśniejszy prześwit) i przy okazji zrównuje cały rząd kontrolek, bo
            // w źródle „Poly" i ekran mają dwa różne, nieprzystające YPos.
            let polyCenterY = poly.yPt + UIMetrics.buttonFlatHeight / 2
            return (field.xPt, polyCenterY - UIMetrics.textFieldHeight / 2, field.widthPt)
        }
        if module.typeID == 208, field.id == 12 || field.id == 8,
           let ui = ModuleUIDatabase.shared.uiDef(forID: 208)
        {
            // RndPattern: ekrany „A"/„B" („+0") mają w źródle YPos wyżej o ~0.84pt
            // niż wspólny środek ich wiersza (gniazdo wejściowe + para +/-), więc
            // stoją zauważalnie nie na osi z żadnym z nich. Wyrównaj do środka
            // najbliższego (tej samej wysokości) gniazda wejściowego.
            let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
            if let refInput = ui.inputs.min(by: { abs($0.yPt - field.yPt) < abs($1.yPt - field.yPt) }) {
                let centerY = refInput.yPt + connHalf
                return (field.xPt, centerY - UIMetrics.textFieldHeight / 2, field.widthPt)
            }
        }
        // RndPattern „Loop", EnvFollow „Attack"/„Release", PitchTrack „Threshold":
        // formuła `labelTopClearing` daje im już dodatni, niesklemowany prześwit
        // (nie wymagają `labelTopFloor`), ale ten sam ciasny 0.145×fontSize odstęp,
        // który gdzie indziej wygląda dobrze, tutaj czytelnie styka się z ekranem.
        // Zamiast dalej ściskać formułę (wpłynęłoby na całą aplikację), przesuwamy
        // SAM EKRAN niżej — etykieta jest liczona względem RAW `ui.textFields`
        // (niezmienionego tu), więc podąża za nim i odstęp faktycznie rośnie.
        let extraDrop: CGFloat? = switch (module.typeID, field.id) {
        case (208, 10): 1.5 // Loop
        case (71, 3), (71, 5): 1.5 // EnvFollow Attack/Release
        case (198, 0): 1.5 // PitchTrack Threshold
        default: nil
        }
        if let extraDrop {
            return (field.xPt, field.yPt + extraDrop, field.widthPt)
        }
        guard module.typeID == 180 else { return (field.xPt, field.yPt, field.widthPt) }
        let sourceScale = PatchLayout.bverhuePixelScale
        let shortWidth = 22.0 * sourceScale
        let topRowBottom = 24 * sourceScale + UIMetrics.buttonFlatHeight
        let bottomRowBottom = 164 * sourceScale + UIMetrics.buttonFlatHeight
        let envelopeLabelBottom = 82 * sourceScale
        let envelopeKnobTop = 99 * sourceScale
        let envelopeFieldY = (envelopeLabelBottom + envelopeKnobTop - UIMetrics.textFieldHeight) / 2

        switch field.id {
        case 8 ... 15: // R1…L4: equal vertical gaps to the raised label row and knobs.
            return (field.xPt + sourceScale, envelopeFieldY, field.widthPt)
        case 32: // Ratio: shared lower edge with Sync and KBT.
            return (91 * sourceScale, topRowBottom - UIMetrics.textFieldHeight, field.widthPt)
        case 38: // Detune: align the LCD's top edge with the adjacent + button.
            return (201 * sourceScale, 16 * sourceScale, shortWidth)
        case 43, 45: // Vel and RateScale: align each LCD's top edge with its + button.
            // Keep the established horizontal separation: RateScale stays at its
            // natural X position, while the complete Vel group remains 5 px left.
            let xShift: CGFloat = (field.id == 43 ? -5 : 0) * sourceScale
            return (field.xPt + xShift, 51 * sourceScale, shortWidth)
        case 55: // AMod — ta sama szerokość co BrPoint/L-Depth/R-Depth (shortWidth).
            // Lewa krawędź wymuszona na XPos:4 (jak pozostałe gniazda lewej kolumny),
            // nie surowe źródłowe XPos:5 tego pola — 0.55pt różnicy, ale użytkownik
            // chce dokładnego wyrównania do wspólnej krawędzi gniazd.
            return (4 * sourceScale, field.yPt, shortWidth)
        case 63, 67: // R-Depth, L-Depth — cały dolny rząd ekranów.
            // Wyrównaj DOLNĄ krawędź do przycisków „-Lin" obok (ButtonFlat YPos:164 +
            // buttonFlatHeight) — na tej samej linii kończą się też pary „+/−"
            // (YPos:154 + 2×incDecHeight + incDecGap = 96.7pt), więc cały dolny rząd
            // stoi równo. Ekran jest niższy od przycisku (6.5 vs 7.0pt), więc jego
            // górna krawędź musi zacząć się odpowiednio niżej niż surowe YPos:162.
            return (field.xPt, bottomRowBottom - UIMetrics.textFieldHeight, shortWidth)
        case 71: // BrPoint — jak wyżej (dolny rząd), plus +4 Gen1px w prawo. BrPoint nie
            // ma przycisku „-Lin/-Exp" obok (w przeciwieństwie do L-Depth/R-Depth), więc
            // jego grupa (ekran+przyciski) kończy się bliżej lewej krawędzi modułu niż
            // odstęp między pozostałymi dwiema grupami — użytkownik zmierzył to wizualnie
            // w oryginalnym edytorze (odstęp BrPoint→L-Depth był ~2× większy niż
            // L-Depth→R-Depth). +4px (razem z operatorIncDecOrigin case 17) zrównuje oba
            // odstępy dokładnie.
            return (field.xPt + 4 * sourceScale, bottomRowBottom - UIMetrics.textFieldHeight, shortWidth)
        default:
            return (field.xPt, field.yPt, field.widthPt)
        }
    }

    /// Sekwencery: rząd „Length − + [LCD]" w nagłówku. W źródle para „−/+" ma prawą
    /// krawędź NA ramce ekranu (Gen1 zostawia 0 pikseli), a odstępy między napisem,
    /// parą i ekranem są przypadkowe. Rozkładamy całą trójkę równo w wolnym miejscu
    /// między elementem po lewej a gniazdem po prawej — para liczy się jako JEDEN
    /// element. Wspólne dla napisu, przycisków i ekranu, żeby się nie rozjechały.
    func sequencerLengthRow(module: G2Module, ui: ModuleUIDef)
        -> (labelX: CGFloat, rowCenterY: CGFloat, incDecX: CGFloat, incDecY: CGFloat,
            fieldX: CGFloat)?
    {
        guard [121, 144, 145, 146, 154].contains(module.typeID),
              let label = ui.textLabels.first(where: { $0.text == "Length" }),
              let inc = ui.incDecButtons.first(where: {
                  !$0.isVertical && abs($0.yPt - label.yPt) < 6.0
              }),
              let field = ui.textFields.first(where: {
                  $0.xPt > inc.xPt && abs($0.yPt - inc.yPt) < 4.0
              })
        else { return nil }

        let side = UIMetrics.incDecHeight
        let pairWidth = 2 * side + UIMetrics.incDecGap
        let font = NSFont.systemFont(ofSize: label.fontSize, weight: .regular, width: .condensed)
        let labelWidth = (label.text as NSString).size(withAttributes: [.font: font]).width
        let connHalf: CGFloat = 5.5 * PatchLayout.bverhuePixelScale
        let rowY = label.yPt
        let connectors = ui.inputs + ui.outputs

        // Lewa granica: pionowa kreska, przycisk albo gniazdo kończące się przed napisem.
        var leftEdge: CGFloat = 0
        for line in ui.lines where !line.isHorizontal && line.xPt < label.xPt {
            leftEdge = max(leftEdge, line.xPt)
        }
        for button in ui.buttonsFlat where button.xPt + button.widthPt <= label.xPt + 1 {
            leftEdge = max(leftEdge, button.xPt + button.widthPt)
        }
        for conn in connectors
            where conn.xPt < label.xPt && abs(conn.yPt - rowY) < 8.0
        {
            leftEdge = max(leftEdge, conn.xPt + 2 * connHalf)
        }
        // Prawa granica: obrys najbliższego gniazda za ekranem.
        let connectorInset = connHalf - UIMetrics.connectorHalf - UIMetrics.socketOuterMargin
        let rightEdge = connectors
            .filter { $0.xPt > field.xPt && abs($0.yPt - rowY) < 8.0 }
            .map { $0.xPt + connectorInset }
            .min() ?? PatchLayout.moduleWidth

        // Ekran rysuje się z minimalną szerokością — bez tego rozkład wypychał go
        // pod gniazdo stojące zaraz za nim.
        let fieldWidth = max(field.widthPt, UIMetrics.textFieldMinWidth)
        let available = rightEdge - leftEdge
        let content = labelWidth + pairWidth + fieldWidth
        guard available > content else { return nil }
        // Napis, para i ekran opisują JEDNĄ wartość, więc trzymają się blisko siebie;
        // nadmiar miejsca zostaje po bokach, a nie rozpycha grupę.
        let gap = min((available - content) / 4, 1.6)
        let startX = leftEdge + (available - content - 2 * gap) / 2
        let incDecX = startX + labelWidth + gap
        return (startX,
                field.yPt + UIMetrics.textFieldHeight / 2,
                incDecX,
                field.yPt + (UIMetrics.textFieldHeight - side) / 2,
                incDecX + pairWidth + gap)
    }

    private func sequencerIncDecOrigin(module: G2Module, button: BVButtonIncDec) -> CGPoint? {
        guard [121, 144, 145, 146, 154].contains(module.typeID),
              let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID)
        else { return nil }

        if button.isVertical {
            // SeqVal: pionowa para „+/−" stoi na osi magistrali swojego rzędu,
            // czyli gniazda przy krawędzi panelu — oba przyciski przylegają do
            // linii tak samo jak ▲/▼ w pozostałych sekwencerach.
            let pairHeight = 2 * UIMetrics.incDecHeight + UIMetrics.incDecGap
            let connHalf: CGFloat = 5.5 * PatchLayout.bverhuePixelScale
            let center = button.yPt + pairHeight / 2
            guard let socket = (ui.inputs + ui.outputs)
                .map({ $0.yPt + connHalf })
                .filter({ abs($0 - center) < 5.0 })
                .min()
            else { return nil }
            return CGPoint(x: button.xPt, y: socket - pairHeight / 2)
        }

        guard let row = sequencerLengthRow(module: module, ui: ui) else { return nil }
        return CGPoint(x: row.incDecX, y: row.incDecY)
    }

    func operatorIncDecOrigin(module: G2Module, button: BVButtonIncDec) -> CGPoint {
        if let seq = sequencerIncDecOrigin(module: module, button: button) {
            return seq
        }
        if module.typeID == 108,
           let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID),
           let bandGraph = ui.graphs.first(where: { $0.graphFunc == 8 })
        {
            let sourceScale = PatchLayout.bverhuePixelScale
            let topBusYPt = 23 * sourceScale
            let routingGap = 2 * sourceScale
            let buttonY = topBusYPt + routingGap + bandGraph.heightPt + routingGap
            return CGPoint(x: button.xPt, y: buttonY)
        }

        guard module.typeID == 180 else { return CGPoint(x: button.xPt, y: button.yPt) }
        let sourceScale = PatchLayout.bverhuePixelScale

        switch button.codeRef {
        case 5: // Detune — przesunięty razem z ekranem (patrz operatorTextFieldFrame
            // case 38): z XPos:221 na XPos:225, żeby po poszerzeniu ekranu do
            // shortWidth zachować ~1.1pt odstępu ekran-przycisk i ~2.2pt luzu do FM.
            return CGPoint(x: 225 * sourceScale, y: 16 * sourceScale)
        case 6: // Vel — patrz operatorTextFieldFrame case 43/45: cały ekran i przycisk
            // przesunięte 5px w lewo (nie 3 — RateScale obok wróciło do naturalnej
            // pozycji, więc cała separacja od niego jest teraz po stronie Vel).
            return CGPoint(x: (205 - 5) * sourceScale, y: 51 * sourceScale)
        case 7: // RateScale — naturalna pozycja (241), BEZ dodatkowego przesunięcia —
            // wcześniejsze +3 dotykało prawej ramki modułu (patrz operatorTextFieldFrame
            // case 43/45).
            return CGPoint(x: 241 * sourceScale, y: 51 * sourceScale)
        case 16, 17, 19, 21:
            // AMod, BrPoint, L-Depth and R-Depth all use the same two-source-pixel
            // gap between the LCD and +/- pair. AMod additionally aligns the pair's
            // bottom edge with its LCD; the three depth groups keep their shared row.
            let fieldIDs = [16: 55, 17: 71, 19: 67, 21: 63]
            guard let fieldID = fieldIDs[button.codeRef],
                  let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID),
                  let field = ui.textFields.first(where: { $0.id == fieldID })
            else { return CGPoint(x: button.xPt, y: button.yPt) }
            let frame = operatorTextFieldFrame(module: module, field: field)
            let x = frame.x + frame.width + 2 * sourceScale
            let pairHeight = 2 * UIMetrics.incDecHeight + UIMetrics.incDecGap
            let y = button.codeRef == 16
                ? frame.y + UIMetrics.textFieldHeight - pairHeight
                : operatorBottomRowIncDecY(sourceScale: sourceScale)
            return CGPoint(x: x, y: y)
        default:
            return CGPoint(x: button.xPt, y: button.yPt)
        }
    }

    private func operatorBottomRowIncDecY(sourceScale: CGFloat) -> CGFloat {
        let bottom = 164 * sourceScale + UIMetrics.buttonFlatHeight
        return bottom - 2 * UIMetrics.incDecHeight - UIMetrics.incDecGap
    }

    /// OscD: w panelu Clavii prawa krawędź gałki Reset styka ekran fali. W renderze
    /// wektorowym obrysy optycznie się zlewają, więc zostawiamy 2 px Gen1 szczeliny.
    /// Ta sama pozycja jest używana przez rysowanie oraz obsługę kliknięcia.
    /// Offset from the source step-column X position. SeqNote centers the column
    /// on its track (see `faderLayout`). Modules without note tracks keep the
    /// source X position shared by their equally sized step and +/- buttons.
    func sequencerColumnOffset(ui: ModuleUIDef) -> CGFloat {
        let notes = ui.seqNoteKnobs.sorted { $0.xPt < $1.xPt }
        guard notes.count > 1 else { return 0 }
        return (notes[1].xPt - notes[0].xPt - UIMetrics.seqFaderWidth) / 2
    }

    /// Tor fadera razem z parą ▲/▼ pod nim — jedno źródło prawdy dla rysowania,
    /// hit-testu, kliknięć ▲/▼ i siatki nut SeqNote. Ten sam widżet ma wyglądać
    /// identycznie w każdym module, który go używa (SeqCtr/SeqLev/SeqNote, MixFader).
    struct FaderLayout {
        let track: CGRect
        let up: CGRect
        let down: CGRect
    }

    /// Cała kolumna dzieli JEDEN odstęp `faderGroupGap`: ekran/dioda → tor → para
    /// ▲/▼ → przycisk pod spodem. Wewnątrz pary ▲/▼ zostaje ciaśniejszy
    /// `seqFaderGap`, bo to jedna grupa, a nie dwa osobne elementy.
    ///
    /// Sąsiadów szukamy w kolumnie toru: nad nim ekranu albo diody kroku, pod nim
    /// przycisku (bezimienny przycisk kroku sekwencera albo nazwa kanału Ch1…Ch8
    /// MixFadera). Wysokość toru wychodzi z odejmowania, więc różni się między
    /// modułami o różnej wysokości panelu — ale odstępy są wszędzie te same.
    ///
    /// Wcześniej górę toru brała stała wyliczona pod sekwencery, a przycisk pod nim
    /// szukany był wyłącznie wśród BEZIMIENNYCH przycisków kroku — w MixFaderze
    /// dawało to tor zaczynający się NAD ekranami (chował się za nimi) i parę ▲/▼
    /// nachodzącą na nazwy kanałów.
    func faderLayout(module: G2Module, knob: BVKnob, ui: ModuleUIDef, rect: CGRect) -> FaderLayout {
        let w = UIMetrics.seqFaderWidth
        let iH = UIMetrics.seqFaderIncDecH
        let innerGap = UIMetrics.seqFaderGap
        let gap = UIMetrics.faderGroupGap
        let trackGap = UIMetrics.faderTrackGap
        let origin = knobOrigin(module: module, knob: knob)

        let columnLeft = origin.x
        let columnRight = origin.x + w
        func inColumn(_ x: CGFloat, _ width: CGFloat) -> Bool {
            max(columnLeft, x) < min(columnRight, x + width)
        }

        // Nad torem: ekran odczytu (MixFader) albo dioda kroku (sekwencery).
        let aboveBottoms = ui.textFields
            .filter { $0.yPt < origin.y && inColumn($0.xPt, $0.widthPt) }
            .map { $0.yPt + UIMetrics.textFieldHeight }
            + ui.leds
            .filter { $0.type == .sequencer && $0.yPt < origin.y && inColumn($0.xPt, UIMetrics.ledSeqWidth) }
            .map { $0.yPt + UIMetrics.ledSeqHeight }
        let top = aboveBottoms.max().map { $0 + trackGap } ?? origin.y

        // Pod parą ▲/▼: przycisk kroku albo nazwa kanału.
        let belowTop = ui.buttonsText
            .filter { $0.yPt > origin.y && inColumn($0.xPt, $0.widthPt) }
            .map(\.yPt).min()
            ?? (rect.height - PatchLayout.headerH)

        // Sekwencery mają w rzędzie ▲/▼ własne gniazdo przy krawędzi panelu — para
        // przycisków stoi na jego osi, bo łączy je z nim pozioma linia magistrali
        // (patrz `drawFaderBusLines`). Gdy takiego gniazda nie ma (MixFader), grupa
        // po prostu siada nad przyciskami z jednakowym odstępem.
        let groupHeight = 2 * iH + innerGap
        let connHalf: CGFloat = 5.5 * PatchLayout.bverhuePixelScale
        // Rząd ▲/▼ opisuje NAJNIŻSZE gniazdo nad rzędem przycisków kroku — wyżej
        // w tym samym paśmie stoją jeszcze gniazda lewej kolumny (Rst, Loop…),
        // które z tą magistralą nie mają nic wspólnego. Gniazda lewe i prawe różnią
        // się w źródle o piksel, więc bierzemy średnią z całego rzędu.
        let bandCenters = (ui.inputs + ui.outputs)
            .map { $0.yPt + connHalf }
            .filter { $0 > top && $0 < belowTop }
        let rowSocketCenterY: CGFloat? = bandCenters.max().map { lowest in
            let row = bandCenters.filter { abs($0 - lowest) < 3.0 }
            return row.reduce(0, +) / CGFloat(row.count)
        }
        let groupTop = rowSocketCenterY.map { $0 - groupHeight / 2 }
            ?? (belowTop - gap - groupHeight)

        // Tor ma tę samą wysokość w każdym module z faderami i jest wyśrodkowany
        // w przestrzeni, jaką zostawia panel. Wyjątkiem jest siatka nut SeqNote —
        // ta korzysta z całej dostępnej wysokości.
        let available = groupTop - trackGap - top
        let isNoteGrid = knob.infoFunc == 13
        let trackH = isNoteGrid
            ? max(6, available)
            : max(6, min(UIMetrics.faderTrackHeight, available))
        let trackTop = isNoteGrid ? top : top + (available - trackH) / 2

        // SeqNote: tor jest wąskim uchwytem wewnątrz kolumny kroku, a kolumna jest
        // szersza od niego o rozstaw — uchwyt stoi na jej osi, nie przy lewej krawędzi.
        var x = rect.minX + origin.x
        if knob.infoFunc == 13 {
            let notes = ui.seqNoteKnobs.sorted { $0.xPt < $1.xPt }
            if notes.count > 1 {
                x += (notes[1].xPt - notes[0].xPt - w) / 2
            }
        }
        let track = CGRect(x: x, y: rect.minY + trackTop, width: w, height: trackH)
        let upY = rect.minY + groupTop
        // Kwadrat ▲/▼ jest szerszy od toru — stoi na jego osi.
        let buttonX = x + (w - iH) / 2
        return FaderLayout(
            track: track,
            up: CGRect(x: buttonX, y: upY, width: iH, height: iH),
            down: CGRect(x: buttonX, y: upY + iH + innerGap, width: iH, height: iH)
        )
    }

    func knobOrigin(module: G2Module, knob: BVKnob) -> CGPoint {
        guard module.typeID == 96, knob.codeRef == 1 else {
            return CGPoint(x: knob.xPt, y: knob.yPt)
        }
        return CGPoint(x: knob.xPt - 2 * PatchLayout.bverhuePixelScale, y: knob.yPt)
    }

    /// Rysuje pojedynczy przycisk +/- jako wektor (nie Text) — gwarantuje dokładne
    /// wyśrodkowanie glifu niezależnie od metryk fontu systemowego. `highlighted` —
    /// podświetlenie podczas przytrzymania (patrz incDecPressGesture).
    private func drawIncDecButton(_ ctx: GraphicsContext, rect: CGRect, isPlus: Bool, highlighted: Bool = false) {
        let bgColor: Color = highlighted ? UIColor.buttonPressed : UIColor.buttonNeutral
        PanelFace.raised(ctx, rect, cornerRadius: UIMetrics.buttonCornerRadius,
                         fill: bgColor, border: .black.opacity(0.4), shaded: panelShading)

        let arm = min(rect.width, rect.height) * 0.5
        let cx = rect.midX, cy = rect.midY
        var glyph = Path()
        glyph.move(to: CGPoint(x: cx - arm / 2, y: cy))
        glyph.addLine(to: CGPoint(x: cx + arm / 2, y: cy))
        if isPlus {
            glyph.move(to: CGPoint(x: cx, y: cy - arm / 2))
            glyph.addLine(to: CGPoint(x: cx, y: cy + arm / 2))
        }
        ctx.stroke(glyph, with: .color(UIColor.textLabel),
                   style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
    }

    // MARK: - PartSelector (selektor ikon — kształty fal, tryby…)

    /// Rzeczywisty obszar selektora. OscShpB w danych Gen1 ma szerokie pole 41 px,
    /// które zasłania wykres — własny ekran PartSelectora się nie rysuje (patrz
    /// drawBVPartSelectors), więc klikalny obszar dopasowujemy do PRAWDZIWEGO,
    /// widocznego ekranu wykresu (Graph ID:26, XPos 208/Width 35 w OscShpB.txt),
    /// nie do węższej, oryginalnej 9px zakładki-strzałki z Gen1 (BVerhue tam
    /// odzwierciedlał FButtonRect z g2_graph.pas — tu każdy inny selektor fal
    /// otwiera listę po kliknięciu w cały ekran, więc OscShpB ma być spójny).
    /// InfoFunc selektora OutputType (BiPol/Pos/Neg) w rodzinie Random/RndClk/RndPattern.
    /// BVerhue zapisuje go jako ButtonFlat z trzema obrazkami, więc parser robi z niego
    /// PartSelector — ale w oryginale to zwykły, kwadratowy przycisk przy gnieździe
    /// wyjściowym, bliźniaczy do LevelShift („P+"/„B−") w modułach obwiedni.
    static let outputTypeInfoFunc = 204

    /// InfoFunc selektora Normal/Reset w obwiedniach (EnvADSR, EnvAHD, EnvADR,
    /// EnvADDSR, EnvMulti). Też zapisany jako ButtonFlat z obrazkami, też jest
    /// w rzeczywistości małym przyciskiem, nie ekranem z listą.
    static let envRetriggerInfoFunc = 138

    /// Selektory, które renderujemy jako kwadratowy przycisk z literą zamiast ekranu.
    static func shortLabelButtonTitle(infoFunc: Int, value: Int) -> String? {
        switch infoFunc {
        case outputTypeInfoFunc:
            // BVerhue `prtBipPosNeg` (slButtonText „BiPol;Pos;Neg;").
            switch value % 3 {
            case 0: "B"
            case 1: "P"
            default: "N"
            }
        case envRetriggerInfoFunc:
            value % 2 == 0 ? "N" : "R" // Normal / Reset
        default:
            nil
        }
    }

    /// Kwadratowy przycisk rozmiaru Power, wyrównany do osi gniazda stojącego obok —
    /// wspólna geometria dla LevelShift i selektora OutputType.
    private func powerSizedButtonRect(xPt: CGFloat, yPt: CGFloat,
                                      ui: ModuleUIDef, in moduleRect: CGRect) -> CGRect
    {
        let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
        let s = UIMetrics.powerButtonSize
        let nearbyConn = (ui.inputs + ui.outputs)
            .filter {
                abs($0.yPt - yPt) < 4.0
                    && ($0.xPt + 2 * connHalf <= xPt || $0.xPt >= xPt + s)
            }
            .min { abs($0.xPt - xPt) < abs($1.xPt - xPt) }

        // Przycisk wciśnięty między parę +/− a Power dostaje równe odstępy po obu
        // stronach. BVerhue zapisuje surowy XPos wymierzony dla SZERSZEGO widżetu
        // oryginału, więc u nas przyklejał się do „−" i zostawiał lukę przy Power
        // (RndPattern — jedyny taki układ w całej bazie 168 modułów).
        let leftEdge = ui.incDecButtons
            .filter { abs($0.yPt - yPt) < 4.0 }
            .map { $0.xPt + ($0.isVertical ? UIMetrics.incDecHeight
                    : 2 * UIMetrics.incDecHeight + UIMetrics.incDecGap) }
            .filter { $0 <= xPt + 0.5 }
            .max()
        let rightEdge = ui.buttonsText
            .filter { abs($0.yPt - yPt) < 4.0 && $0.xPt >= xPt + s - 0.5 }
            .map(\.xPt)
            .min()
        let x: CGFloat = if let leftEdge, let rightEdge, rightEdge - leftEdge >= s {
            leftEdge + (rightEdge - leftEdge - s) / 2
        } else {
            xPt
        }
        return CGRect(x: moduleRect.minX + x,
                      y: moduleRect.minY + (nearbyConn.map { $0.yPt + connHalf - s / 2 } ?? yPt),
                      width: s, height: s)
    }

    func partSelectorRect(_ selector: BVPartSelector, moduleTypeID: Int, in moduleRect: CGRect) -> CGRect {
        if Self.shortLabelButtonTitle(infoFunc: selector.infoFunc, value: 0) != nil,
           let ui = ModuleUIDatabase.shared.uiDef(forID: moduleTypeID)
        {
            return powerSizedButtonRect(xPt: selector.xPt, yPt: selector.yPt, ui: ui, in: moduleRect)
        }
        if moduleTypeID == 8, selector.id == 20 {
            let scale = PatchLayout.bverhuePixelScale
            return CGRect(x: moduleRect.minX + 208 * scale, y: moduleRect.minY + 4 * scale,
                          width: 35 * scale, height: 22 * scale)
        }
        if isSmallFilterSlopeSelector(moduleTypeID: moduleTypeID, selector: selector),
           let graph = ModuleUIDatabase.shared.uiDef(forID: moduleTypeID)?.graphs.first(where: {
               $0.graphFunc == 30 || $0.graphFunc == 31
           })
        {
            return CGRect(x: moduleRect.minX + graph.xPt, y: moduleRect.minY + graph.yPt,
                          width: graph.widthPt, height: graph.heightPt)
        }
        if isTextLcdPartSelector(selector, moduleTypeID: moduleTypeID) {
            // Wysokie ekrany Range/Type/Character z Gen1 wyglądały obok zwykłych
            // LCD jak inny rodzaj widżetu. Ujednolicamy je z TextField: zostawiamy
            // szerokość i dolną krawędź, zmniejszamy tylko wysokość, więc font
            // `lcdDisplay` ma identyczny rozmiar w całej rodzinie.
            let bottom = selector.yPt + selector.heightPt
            return CGRect(x: moduleRect.minX + selector.xPt,
                          y: moduleRect.minY + bottom - UIMetrics.textFieldHeight,
                          width: selector.widthPt, height: UIMetrics.textFieldHeight)
        }
        return CGRect(x: moduleRect.minX + selector.xPt, y: moduleRect.minY + selector.yPt,
                      width: selector.widthPt, height: selector.heightPt)
    }

    private func isTextLcdPartSelector(_ selector: BVPartSelector, moduleTypeID: Int) -> Bool {
        // Te panele mają własne diagramy stanu, mimo że baza potrafi zwrócić dla nich
        // etykietę tekstową. Ich oryginalnej geometrii nie zmieniamy — spłaszczenie do
        // wysokości TextFielda robiło z ekranu Gate (39×22, atlas sześciu bramek) wąski
        // pasek, zupełnie niepodobny do sąsiedniego FlipFlopa (42×24).
        guard ![38, 42, 64, 69, 91].contains(moduleTypeID),
              selector.heightPt > UIMetrics.textFieldHeight,
              let modeNames = moduleDefinition(moduleTypeID)?.modeNames,
              modeNames.indices.contains(selector.codeRef)
        else { return false }
        return g2ModeLabel(modeName: modeNames[selector.codeRef], value: 0) != nil
    }

    private func drawBVPartSelectors(_ ctx: GraphicsContext, module: G2Module, rect: CGRect) {
        guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { return }
        guard !ui.partSelectors.isEmpty else { return }
        let modeNames = moduleDefinition(module.typeID)?.modeNames ?? []

        for sel in ui.partSelectors {
            // OutputType (Random/RndClk/RndPattern): kwadratowy przycisk przy gnieździe
            // wyjściowym, nie ekran z listą. Trzy stany wg BVerhue `prtBipPosNeg`
            // (0=BiPol, 1=Pos, 2=Neg) — pierwsza litera na przycisku, jak „P+"/„B−"
            // w LevelShift obwiedni.
            let selValue = sel.codeRef < module.parameters.count ? module.parameters[sel.codeRef] : 0
            if let label = Self.shortLabelButtonTitle(infoFunc: sel.infoFunc, value: selValue) {
                drawPowerSizedLabelButton(
                    ctx,
                    in: partSelectorRect(sel, moduleTypeID: module.typeID, in: rect),
                    label: label
                )
                continue
            }

            // Oryginalne panele mają wykres X=168, W=32 i osobny,
            // wąski selektor X=200, W=8. Zamkniętym ekranem jest żywy wykres;
            // selektor dostarcza tylko języczek i sześć pozycji menu.
            if isSmallFilterSlopeSelector(moduleTypeID: module.typeID, selector: sel) {
                if sel.imageCount > 1 {
                    drawSelectorDisclosure(
                        ctx,
                        screen: partSelectorRect(sel, moduleTypeID: module.typeID, in: rect)
                    )
                }
                continue
            }

            // OscShpB ma osobny GraphFunc 18, który jest pełnym ekranem przebiegu.
            // PartSelector ID 20 służy wyłącznie do hit-testu i menu wyboru fali —
            // jego WŁASNY ekran (zamknięty stan z ikoną) nie może się rysować, bo
            // dublowałby żywy wykres. Zakładka rozwijania (drawSelectorDisclosure)
            // to jednak osobny, mały trójkąt przy prawym rogu — bez niej nie ma
            // żadnego widocznego sygnału, że tam w ogóle da się kliknąć (2026-08-11:
            // klik technicznie działał w wąskim pasku z partSelectorRect, ale nikt
            // nie widział, że tam jest). Rysujemy ją przy prawej krawędzi PRAWDZIWEGO
            // ekranu wykresu (GraphFunc 18: XPos 208 vs PartSelector XPos 210 — 2 Gen1px
            // różnicy w źródle, więc generyczne dopasowanie `hasGraphReplacement`
            // niżej go nie łapie), nie przy węższym, czysto klikalnym `partSelectorRect`.
            if module.typeID == 8, sel.id == 20 {
                let graphScreen = ui.graphs.first(where: { abs($0.yPt - sel.yPt) < 2.0 })
                    .map { CGRect(x: rect.minX + $0.xPt, y: rect.minY + $0.yPt,
                                  width: $0.widthPt, height: $0.heightPt) }
                    ?? CGRect(x: rect.minX + sel.xPt, y: rect.minY + sel.yPt,
                              width: sel.widthPt, height: sel.heightPt)
                if sel.imageCount > 1 {
                    drawSelectorDisclosure(ctx, screen: graphScreen)
                }
                continue
            }

            // FltLP/FltHP definiują w tym samym miejscu PartSelector oraz Graph
            // (dynamiczną charakterystykę filtra). Graph jest kompletnym odpowiednikiem
            // tego pola, więc równoległe rysowanie selektora zostawiało zielone
            // artefakty poza węższym wykresem.
            let hasGraphReplacement = ui.graphs.contains {
                abs($0.xPt - sel.xPt) < 0.1 && abs($0.yPt - sel.yPt) < 0.1
            }
            if hasGraphReplacement {
                let graphScreen = CGRect(x: rect.minX + sel.xPt, y: rect.minY + sel.yPt,
                                         width: sel.widthPt, height: sel.heightPt)
                if sel.imageCount > 1 {
                    drawSelectorDisclosure(ctx, screen: graphScreen)
                }
                continue
            }

            let selRect = partSelectorRect(sel, moduleTypeID: module.typeID, in: rect)

            // Zakładka jest pod ekranem, przez co fizycznie łączy się z jego prawym rogiem.
            if sel.imageCount > 1 {
                drawSelectorDisclosure(ctx, screen: selRect)
            }

            let value: Int = sel.usesParameter
                ? (sel.codeRef < module.parameters.count ? module.parameters[sel.codeRef] : 0)
                : (sel.codeRef < module.modes.count ? module.modes[sel.codeRef] : 0)
            let clampedVal = max(0, min(value, sel.imageCount - 1))
            // Ikony w .txt są przechowywane z przesunięciem -1 względem wartości:
            // value=0→icon(N-1), value=1→icon0, …
            let selIdx = (clampedVal + sel.imageCount - 1) % sel.imageCount

            // ── Wybór renderowania: schemat / LCD tekst / ikony ──────────────────────────
            if module.typeID == 42 || module.typeID == 91 || module.typeID == 69 || module.typeID == 38 {
                // Logic Delay, FlipFlop, ClkDiv i Pulse: skalowalny schemat wektorowy ma pierwszeństwo
                // przed tekstową nazwą trybu (np. "Gated"/"Toggled" dla ClkDiv) — g2ModeLabel
                // istnieje dla dymka/tooltipa, ale na ekranie modułu ma być rysunek, nie napis.
                // Warianty odpowiadają BVE.NMG2Pathdata.pas (Pos/Neg/Cycle Delay oraz D/SR) oraz
                // odzyskanemu wzorcowi ClkDiv (SVG-PNG/Logic-ClkDiv-1/2.png).
                drawLogicPartSelector(ctx, rect: selRect,
                                      moduleTypeID: module.typeID, index: clampedVal)
                continue
            }

            let modeName = sel.codeRef < modeNames.count ? modeNames[sel.codeRef] : ""
            if isPMDriverPartSelector(moduleTypeID: module.typeID, selector: sel) {
                // PM Driver nie używa generycznych Option 1…4 ani symboli fal.
                // Cztery klatki atlasu Clavii odtwarzamy wektorowo tym samym
                // rendererem, który zasila rozwiniętą listę selektora.
                PanelFace.recessed(ctx, selRect, cornerRadius: 1.0,
                                   fill: UIColor.lcdBackground, shaded: panelShading)
                drawPMDriverSelectorIcon(
                    ctx,
                    rect: selRect,
                    value: clampedVal,
                    color: UIColor.lcdText,
                    accentColor: UIColor.pmDriverAccent,
                    fontSize: UIFont.lcdDisplay(boxHeight: selRect.height)
                )
            } else if let label = g2ModeLabel(modeName: modeName, value: clampedVal) {
                // Text-type selector (np. DelayRange) — renderuj LCD fontem
                PanelFace.recessed(ctx, selRect, cornerRadius: 1.0,
                                   fill: UIColor.lcdBackground, shaded: panelShading)
                let fontSize = UIFont.lcdDisplay(boxHeight: selRect.height)
                drawLcdText(ctx, text: label, box: selRect, fontSize: fontSize)
            } else {
                // Icon-type selector — skalowalne ikony wektorowe
                let waveInfoFunc = sel.imageCount == 8 ? 200 : sel.infoFunc
                if isWavePartSelector(moduleTypeID: module.typeID, selector: sel) {
                    PanelFace.recessed(ctx, selRect, cornerRadius: 1.0,
                                       fill: UIColor.lcdBackground, shaded: panelShading)
                    let iconRect = selRect.insetBy(dx: 1, dy: 1)
                    // Ikony ZAWSZE wektorowo — bitmapa z Gen1 .txt służy nam tylko jako
                    // wzorzec kształtu (obrysowany w `drawLfoCWaveIcon`), nie jako obrazek
                    // do wyświetlenia: przy powiększeniu interfejsu piksele 22×18 widać
                    // jako schodki, a krzywe zostają gładkie na każdym zoomie.
                    drawWaveSelectorIcon(
                        ctx,
                        rect: iconRect,
                        moduleTypeID: module.typeID,
                        value: clampedVal,
                        color: UIColor.lcdText
                    )
                } else if waveInfoFunc == 136 {
                    PanelFace.recessed(ctx, selRect, cornerRadius: 1.0,
                                       fill: UIColor.lcdBackground, shaded: panelShading)
                    let shapeType = (clampedVal + 1) % 4
                    // Wypełniony kształt nie ma obrysu, który mógłby wyjść poza pole,
                    // więc zostawiamy tylko tyle, ile zajmuje ramka ekranu (0.5pt).
                    // Poprzedni margines 1pt z każdej strony zjadał ~18% szerokości
                    // i ~33% wysokości pola — ikona wyglądała na zgubioną w ekranie.
                    drawEnvShapeIcon(ctx, rect: selRect.insetBy(dx: 0.5, dy: 0.5),
                                     shapeType: shapeType, color: UIColor.lcdText, lw: 0.8,
                                     solidFill: true)
                } else {
                    // Pozostałe nieopisane selektory zachowują dotychczasowy,
                    // również wektorowy fallback — bez bitmap i bez udawania FlipFlopa.
                    PanelFace.recessed(ctx, selRect, cornerRadius: 1.0,
                                       fill: UIColor.lcdBackground, shaded: panelShading)
                    drawWaveIcon(ctx, rect: selRect.insetBy(dx: 2, dy: 2),
                                 infoFunc: waveInfoFunc, waveIndex: selIdx,
                                 color: UIColor.lcdText, lw: 0.5)
                }
            }
        }
    }

    /// Szerokość zakładki jest wspólna z pozycjonowaniem menu SwiftUI.
    func selectorDisclosureTabWidth(for _: CGRect) -> CGFloat {
        // Ramka ekranu ma 0,5 pt — zakładka nie może zająć miejsca kontrolek obok.
        0.5 * 3
    }

    /// Zakładka rozwijanej listy, zintegrowana z prawym górnym rogiem ekranu.
    private func drawSelectorDisclosure(_ ctx: GraphicsContext, screen: CGRect) {
        let borderWidth: CGFloat = 0.5
        // Widoczna, prawa połowa podstawy ma trzy grubości ramki; lewa jest wsunięta
        // pod ekran, dzięki czemu wierzchołek przylega do jego prawej ramki.
        let halfWidth = selectorDisclosureTabWidth(for: screen)
        let height = halfWidth * CGFloat(sqrt(3.0))
        // Zewnętrzna krawędź ramki jest o połowę jej grubości ponad prostokątem ekranu.
        let top = screen.minY - borderWidth / 2
        let apexX = screen.maxX
        let roundedEnd = min(borderWidth, halfWidth * 0.52)

        var tab = Path()
        tab.move(to: CGPoint(x: apexX - halfWidth, y: top))
        tab.addLine(to: CGPoint(x: apexX + halfWidth - roundedEnd, y: top))
        tab.addQuadCurve(to: CGPoint(x: apexX + halfWidth, y: top + roundedEnd),
                         control: CGPoint(x: apexX + halfWidth, y: top))
        tab.addLine(to: CGPoint(x: apexX, y: top + height))
        tab.closeSubpath()
        ctx.fill(tab, with: .color(.black.opacity(0.7)))
    }

    /// Wektorowe selektory schematów Logic Delay (3 tryby), FlipFlop (D/SR) i ClkDiv
    /// (2 tryby). Geometria jest znormalizowana do rect, więc pozostaje ostra przy
    /// każdym zoomie.
    private func drawLogicPartSelector(_ ctx: GraphicsContext, rect: CGRect,
                                       moduleTypeID: Int, index: Int)
    {
        // Bez wewnętrznego paska/strzałki: rozwijanie sygnalizuje wyłącznie języczek
        // na zewnątrz ekranu (drawSelectorDisclosure), rysowany osobno przez wywołującego.
        // Wklęsły jak pozostałe ekrany wyboru (`drawBVPartSelectors`).
        PanelFace.recessed(ctx, rect, cornerRadius: 1.0,
                           fill: logicSelectorBackgroundColor(moduleTypeID: moduleTypeID),
                           shaded: panelShading)

        let diagram = rect.insetBy(dx: 1.0, dy: 1.0)
        drawLogicSelectorDiagram(ctx, in: diagram, moduleTypeID: moduleTypeID, index: index)
    }

    /// Tło ekranu selektora Logic — zunifikowane standardowe zielonkawe LCD dla
    /// wszystkich modułów (Delay, ClkDiv, FlipFlop). Wcześniejszy opis „FlipFlop ma
    /// czarne tło" (rzekomo wg `SVG-PNG/Logic-FlipFlop-1/2.png`) nie potwierdza się przy
    /// bliższym oglądzie referencji — wnętrze kwadratu na tym zrzucie jest ciemnozielone,
    /// nie czarne; tylko OTOCZENIE modułu (tło panelu) jest czarne.
    func logicSelectorBackgroundColor(moduleTypeID _: Int) -> Color {
        UIColor.lcdBackground
    }

    /// Metryki wiersza selektora Gate (etykieta/symbol/tabela) dla danej wysokości —
    /// jedno źródło prawdy współdzielone przez `gateSelectorRowWidth` (szerokość listy,
    /// PatchCanvasView+Controls.swift) i `drawLogicSelectorDiagram` (pozycje stref), żeby
    /// oba miejsca zawsze się zgadzały. `symbolWidth` to najszerszy z 6 stanów (XNOR) —
    /// tabela wyrównuje się do niego, więc kolumny są w jednej linii we wszystkich wierszach.
    private func gateSelectorRowMetrics(rowHeight rowH: CGFloat)
        -> (leftPad: CGFloat, labelWidth: CGFloat, labelFontSize: CGFloat,
            symbolWidth: CGFloat, tableWidth: CGFloat, tableFontSize: CGFloat)
    {
        // Sam font co na zamkniętym ekranie (Matrix Sans Screen, jak drawLcdText) — wcześniej
        // system-monospaced, więc nazwa bramki w rozwiniętej liście wyglądała inaczej niż na
        // ekranie. LCD-font ma inną szerokość niż system-mono, więc labelWidth (a za nim
        // symbol i tabela — patrz symbolStartX/tableX niżej) przesuwają się odpowiednio.
        let labelFontSize = rowH * 0.62
        let labelFont = NSFont(name: "MatrixSansScreen-Regular", size: labelFontSize)
            ?? NSFont.monospacedSystemFont(ofSize: labelFontSize, weight: .semibold)
        let labelWidth = ["AND", "NAND", "OR", "NOR", "XOR", "XNOR"]
            .map { ($0 as NSString).size(withAttributes: [.font: labelFont]).width }
            .max() ?? labelFontSize * 4

        let h = rowH * 0.6 // symRect.height po insetBy(dy: symbolZone.height*0.2)
        let legLen = h * 0.55 * 4.0 / 3.0
        let arcGap = h * 0.28
        let bubbleR = h * 0.11
        let orBodyWidth = h * 0.675 // płaski "grzybek" — o połowę węższy niż pierwsza wersja
        // Najszerszy przypadek to XNOR: nóżka + luk XOR + grzybek OR + bańka + nóżka.
        let symbolWidth = legLen + arcGap + orBodyWidth + bubbleR * 2 + legLen

        let tableFontSize = max(3, (rowH / 4) * 1.05)
        let tableFont = NSFont.monospacedSystemFont(ofSize: tableFontSize, weight: .regular)
        let tableWidth = ["  0 0 = 0", "  0 1 = 1", "  1 0 = 1", "  1 1 = 1"]
            .map { ($0 as NSString).size(withAttributes: [.font: tableFont]).width }
            .max() ?? tableFontSize * 9

        return (rowH * 0.06, labelWidth, labelFontSize, symbolWidth, tableWidth, tableFontSize)
    }

    /// Naturalna szerokość wiersza selektora Gate — dopasowana do zawartości (etykieta +
    /// symbol + tabela prawdy), bez pustego miejsca na końcu. Wołane z Controls.swift, żeby
    /// ustawić szerokość rozwijanej listy na dokładnie tyle, ile jest potrzebne.
    func gateSelectorRowWidth(rowHeight rowH: CGFloat) -> CGFloat {
        let m = gateSelectorRowMetrics(rowHeight: rowH)
        let labelToSymbolGap = rowH * 0.30 // dość miejsca, żeby nóżki nie dotykały liter (np. "XNOR")
        let symbolToTableGap = rowH * 0.09 // tabela blisko najdalszej nóżki (XNOR), ale bez dotykania
        let rightPad = rowH * 0.05
        return m.leftPad + m.labelWidth + labelToSymbolGap + m.symbolWidth + symbolToTableGap
            + m.tableWidth + rightPad
    }

    /// Sam schemat krzywych, bez tła/ramki/strzałki rozwijania — współdzielony między
    /// zamkniętym selektorem (`diagram` zwężony o pasek strzałki, `lineWidthScale` 1) i
    /// wierszami rozwiniętej listy (pełna szerokość wiersza; `lineWidthScale` niesie zoom
    /// ekranu — inaczej niż zamknięty selektor, Canvas wiersza rysuje w pikselach ekranu,
    /// nie w punktach patcha — oraz opcjonalne podświetlenie pod kursorem).
    func drawLogicSelectorDiagram(_ ctx: GraphicsContext, in diagram: CGRect,
                                  moduleTypeID: Int, index: Int, lineWidthScale: CGFloat = 1.0,
                                  color: Color = UIColor.lcdText)
    {
        // Standardowa grubość linii — jak wszystkie inne wykresy/ikony ekranowe.
        let stroke = StrokeStyle(lineWidth: UIMetrics.graphLineWidth * lineWidthScale,
                                 lineCap: .square, lineJoin: .miter)

        /// Ścieżka przebiegu prostokątnego: `highRanges` to pary (start, koniec) w ułamku
        /// szerokości `diagram`, gdzie przebieg jest na poziomie `yHigh`; reszta to `yLow`.
        /// `openEnded`: gdy ostatni zakres sięga do prawej krawędzi (koniec 1.0), przebieg
        /// zostaje wysoki i jest po prostu ucięty krawędzią ekranu — bez opadającego zbocza
        /// (tak jak w referencji ClkDiv: ostatni impuls wyjściowy nie wraca do zera w kadrze).
        func squareWavePath(highRanges: [(CGFloat, CGFloat)], yLow: CGFloat, yHigh: CGFloat,
                            openEnded: Bool = false) -> Path
        {
            var path = Path()
            path.move(to: CGPoint(x: diagram.minX, y: yLow))
            for (offset, range) in highRanges.enumerated() {
                let (start, end) = range
                let isOpenEnd = openEnded && offset == highRanges.count - 1 && end >= 1.0
                let xa = diagram.minX + diagram.width * start
                let xb = diagram.minX + diagram.width * end
                path.addLine(to: CGPoint(x: xa, y: yLow))
                path.addLine(to: CGPoint(x: xa, y: yHigh))
                path.addLine(to: CGPoint(x: xb, y: yHigh))
                if !isOpenEnd {
                    path.addLine(to: CGPoint(x: xb, y: yLow))
                }
            }
            if !(openEnded && highRanges.last?.1 ?? 0 >= 1.0) {
                path.addLine(to: CGPoint(x: diagram.maxX, y: yLow))
            }
            return path
        }

        if moduleTypeID == 42 {
            /// Logic Delay: wejściowy impuls u góry (delikatniejsza zielona linia — to
            /// tylko odniesienie) i opóźnione wyjście u dołu standardową grubością.
            /// Geometria odtworzona piksel po pikselu z SVG-PNG/Logic-Delay-1/2/3.png:
            /// każdy tryb inaczej wiąże wyjście z wejściem — to NIE jest ten sam kształt
            /// przesunięty o inną wartość.
            func pulsePath(yLow: CGFloat, yHigh: CGFloat,
                           rise: CGFloat, fall: CGFloat) -> Path
            {
                squareWavePath(highRanges: [(rise, fall)], yLow: yLow, yHigh: yHigh)
            }

            let topLow = diagram.minY + diagram.height * 0.42
            let topHigh = diagram.minY + diagram.height * 0.08
            let bottomLow = diagram.maxY - diagram.height * 0.08
            let bottomHigh = diagram.minY + diagram.height * 0.58
            let top: (CGFloat, CGFloat)
            let bottom: (CGFloat, CGFloat)
            switch index % 3 {
            case 0:
                // Positive edge delay: narastanie wyjścia opóźnione, ale opadanie
                // zsynchronizowane z opadaniem wejścia (ten sam koniec impulsu).
                top = (0.25, 0.8333)
                bottom = (0.4583, 0.8333)
            case 1:
                // Negative edge delay: narastanie zsynchronizowane z wejściem, opadanie
                // wyjścia opóźnione (impuls wydłużony po zaniku wejścia).
                top = (0.25, 0.625)
                bottom = (0.25, 0.8333)
            default:
                // Cycle delay: cały impuls (oba zbocza) przesunięty o tę samą wartość —
                // kształt i szerokość identyczne z wejściem, tylko później.
                top = (0.25, 0.625)
                bottom = (0.4583, 0.8333)
            }
            let inputStroke = StrokeStyle(lineWidth: UIMetrics.graphLineWidth * 0.75 * lineWidthScale,
                                          lineCap: .square, lineJoin: .miter)
            ctx.stroke(pulsePath(yLow: topLow, yHigh: topHigh,
                                 rise: top.0, fall: top.1),
                       with: .color(UIColor.lcdText.opacity(0.45)), style: inputStroke)
            ctx.stroke(pulsePath(yLow: bottomLow, yHigh: bottomHigh,
                                 rise: bottom.0, fall: bottom.1),
                       with: .color(UIColor.lcdText), style: stroke)
            return
        }

        if moduleTypeID == 69 {
            // ClkDiv: zegar wejściowy u góry (4 impulsy, stały wzorzec, delikatniejsza
            // linia — to tylko odniesienie) i podzielony przebieg wyjściowy u dołu,
            // standardową grubością — wąski impuls (stan 0) vs szeroki (stan 1).
            // Geometria odtworzona piksel po pikselu z SVG-PNG/Logic-ClkDiv-1/2.png.
            let topLow = diagram.minY + diagram.height * 0.42
            let topHigh = diagram.minY + diagram.height * 0.08
            let bottomLow = diagram.maxY - diagram.height * 0.08
            let bottomHigh = diagram.minY + diagram.height * 0.58

            // Geometria zmierzona piksel po pikselu z referencji (24×19, treść po
            // odjęciu 1px ramki z każdej strony = siatka 22 jednostek — dokładnie to,
            // co reprezentuje `diagram` w tym kodzie, insetowany o 1pt z `rect`).
            // Zegar: pierwszy impuls startuje na jednostce 1, szerokość impulsu 3
            // jednostki, okres 6 jednostek — stąd ostatni (4.) impuls trafia dokładnie
            // na jednostkę 22 (prawa krawędź), więc `openEnded` otwiera go automatycznie
            // bez żadnego dociągania/rozciągania.
            let unit: CGFloat = 1.0 / 22
            let clockPulseWidth = 3 * unit
            let clockPeriod = 6 * unit
            let clockStart = 1 * unit
            // Koniec ostatniego zakresu wpisany wprost jako 1.0 (nie wyliczony przez
            // dodawanie ułamków `unit`) — inaczej błąd zaokrąglenia zmiennoprzecinkowego
            // (22 * (1.0/22) potrafi wyjść 0.9999999999999999) fałszywie wyłączyłby
            // `openEnded` w `squareWavePath`, które sprawdza `end >= 1.0`.
            let clockRanges: [(CGFloat, CGFloat)] = (0 ..< 4).map { i in
                let start = clockStart + CGFloat(i) * clockPeriod
                return (start, i == 3 ? 1.0 : start + clockPulseWidth)
            }
            // Wyjście: pierwszy impuls startuje razem z zegarem (jednostka 1) — wąski
            // (stan 0) ma tę samą szerokość co impuls zegara, szeroki (stan 1) ma
            // szerokość 9 jednostek. Ostatni, otwarty odcinek ZAWSZE ma szerokość
            // impulsu zegara (nie szerokość własnego pierwszego impulsu!) i startuje
            // razem z ostatnim impulsem zegara (jednostka 19) — w referencji ten
            // ostatni pasek jest wąski w obu stanach, nawet gdy pierwszy jest szeroki.
            let outputEnd: CGFloat = index % 2 == 0 ? clockStart + clockPulseWidth : clockStart + 9 * unit
            let outputLastStart = clockStart + 3 * clockPeriod
            let outputRanges: [(CGFloat, CGFloat)] = [(clockStart, outputEnd), (outputLastStart, 1.0)]

            let clockStroke = StrokeStyle(lineWidth: UIMetrics.graphLineWidth * 0.75 * lineWidthScale,
                                          lineCap: .square, lineJoin: .miter)
            ctx.stroke(squareWavePath(highRanges: clockRanges, yLow: topLow, yHigh: topHigh,
                                      openEnded: true),
                       with: .color(UIColor.lcdText.opacity(0.45)), style: clockStroke)
            ctx.stroke(squareWavePath(highRanges: outputRanges, yLow: bottomLow, yHigh: bottomHigh,
                                      openEnded: true),
                       with: .color(UIColor.lcdText), style: stroke)
            return
        }

        if moduleTypeID == 64 {
            // Logic Gate: PartSelector z 6 stanami (AND/NAND/OR/NOR/XOR/XNOR, g2ModeLabel
            // "GateMode1"/"GateMode2"). Każdy wiersz rozwiniętej listy pokazuje nazwę,
            // klasyczny schematyczny symbol bramki (IEEE/ANSI: płaski grzbiet + półokrąg
            // dla rodziny AND, wklęsły grzbiet + ostry dziób dla rodziny OR, dodatkowa
            // krzywa przed grzbietem dla XOR/XNOR, kółko na wyjściu dla negacji) i tabelę
            // prawdy — jak w oryginalnym BVerhue. Symbole są standardowymi kształtami
            // schematycznymi, nie rekonstrukcją piksel-po-pikselu.
            let truthTables: [[Int]] = [
                [0, 0, 0, 1], // AND
                [1, 1, 1, 0], // NAND
                [0, 1, 1, 1], // OR
                [1, 0, 0, 0], // NOR
                [0, 1, 1, 0], // XOR
                [1, 0, 0, 1], // XNOR
            ]
            let clampedIndex = max(0, min(index, truthTables.count - 1))
            let isNegated = [1, 3, 5].contains(clampedIndex)
            let isOrFamily = [2, 3, 4, 5].contains(clampedIndex)
            let isXorFamily = [4, 5].contains(clampedIndex)
            let name = g2ModeLabel(modeName: "GateMode1", value: clampedIndex) ?? ""

            // Pozycje stref liczone z tych samych metryk co `gateSelectorRowWidth`
            // (Controls.swift ustawia na ich podstawie szerokość listy) — więc zawartość
            // dokładnie wypełnia ekran, bez pustego miejsca na końcu.
            let m = gateSelectorRowMetrics(rowHeight: diagram.height)
            let labelToSymbolGap = diagram.height * 0.30
            let symbolToTableGap = diagram.height * 0.09
            let labelX = diagram.minX + m.leftPad
            let symbolStartX = labelX + m.labelWidth + labelToSymbolGap
            let tableX = symbolStartX + m.symbolWidth + symbolToTableGap

            let symRect = CGRect(x: symbolStartX, y: diagram.minY, width: m.symbolWidth, height: diagram.height)
                .insetBy(dx: 0, dy: diagram.height * 0.2)
            let h = symRect.height
            // Nóżki wejścia zaczepiają na lewej krawędzi bryły w 1/5 i 4/5 jej wysokości
            // (nie w rogach 0/1) — bliżej poziomej osi symetrii, sama bryła ("grzybek")
            // zostaje pełnej wysokości symRect.
            let legTopY = symRect.minY + h * 0.2
            let legBottomY = symRect.minY + h * 0.8
            // Proporcje wg opisu referencji: dwie poziome nóżki wejścia z lewej — TEJ SAMEJ
            // długości we wszystkich stanach (także XOR/XNOR — dotykają dodatkowego łuku,
            // nie są od niego oddzielone przerwą), dłuższe o 1/3 niż pierwsza wersja;
            // "grzybek" AND/OR płaski — o połowę węższy niż pierwsza wersja (bliżej
            // oryginału), łuk grzbietu OR płytki (nie mocno wygięty), bańka negacji NA
            // WYJŚCIU przed ostatnią nóżką — ta ma tę samą długość co nóżki wejścia.
            let legLen = h * 0.55 * 4.0 / 3.0
            let arcGap = h * 0.28
            let bubbleR = h * 0.11
            let andBodyWidth = h * 0.5
            let orBodyWidth = h * 0.675
            let backX = symRect.minX + legLen + (isXorFamily ? arcGap : 0)
            let bodyWidth = isOrFamily ? orBodyWidth : andBodyWidth
            let bodyRect = CGRect(x: backX, y: symRect.minY, width: bodyWidth, height: h)

            /// Bramka AND: płaski grzbiet z lewej, wąski półokrągły "grzybek" z prawej.
            func andBody(_ rect: CGRect) -> Path {
                let r = rect.height / 2
                let flatX = rect.maxX - r
                var path = Path()
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: flatX, y: rect.minY))
                path.addArc(center: CGPoint(x: flatX, y: rect.midY), radius: r,
                            startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.closeSubpath()
                return path
            }
            /// Bramka OR/XOR: płytko wklęsły grzbiet z lewej (niemocno wygięty), ostry dziób z prawej.
            func orBody(_ rect: CGRect) -> Path {
                let w = rect.width
                let bh = rect.height
                let tip = CGPoint(x: rect.maxX, y: rect.midY)
                let backTop = CGPoint(x: rect.minX, y: rect.minY)
                let backBottom = CGPoint(x: rect.minX, y: rect.maxY)
                let bulgeX = rect.minX + w * 0.16
                var path = Path()
                path.move(to: backTop)
                path.addCurve(to: tip,
                              control1: CGPoint(x: rect.minX + w * 0.62, y: rect.minY),
                              control2: CGPoint(x: rect.minX + w * 0.86, y: rect.midY - bh * 0.16))
                path.addCurve(to: backBottom,
                              control1: CGPoint(x: rect.minX + w * 0.86, y: rect.midY + bh * 0.16),
                              control2: CGPoint(x: rect.minX + w * 0.62, y: rect.maxY))
                path.addQuadCurve(to: backTop, control: CGPoint(x: bulgeX, y: rect.midY))
                return path
            }
            /// Dodatkowa kreska XOR: ten sam płytki łuk co grzbiet OR, dotykający końców nóżek.
            func xorExtraArc(_ rect: CGRect, gap: CGFloat) -> Path {
                let x = rect.minX - gap
                let top = CGPoint(x: x, y: rect.minY)
                let bottom = CGPoint(x: x, y: rect.maxY)
                let bulgeX = x + rect.width * 0.16
                var path = Path()
                path.move(to: top)
                path.addQuadCurve(to: bottom, control: CGPoint(x: bulgeX, y: rect.midY))
                return path
            }

            let gateStroke = StrokeStyle(lineWidth: UIMetrics.graphLineWidth * 0.85 * lineWidthScale,
                                         lineCap: .round, lineJoin: .round)

            var legs = Path()
            legs.move(to: CGPoint(x: symRect.minX, y: legTopY))
            legs.addLine(to: CGPoint(x: symRect.minX + legLen, y: legTopY))
            legs.move(to: CGPoint(x: symRect.minX, y: legBottomY))
            legs.addLine(to: CGPoint(x: symRect.minX + legLen, y: legBottomY))
            ctx.stroke(legs, with: .color(color), style: gateStroke)

            if isXorFamily {
                ctx.stroke(xorExtraArc(bodyRect, gap: arcGap), with: .color(color), style: gateStroke)
            }
            ctx.stroke(isOrFamily ? orBody(bodyRect) : andBody(bodyRect),
                       with: .color(color), style: gateStroke)

            var tipX = bodyRect.maxX
            if isNegated {
                let cx = tipX + bubbleR
                let circle = CGRect(x: cx - bubbleR, y: symRect.midY - bubbleR,
                                    width: bubbleR * 2, height: bubbleR * 2)
                ctx.stroke(Path(ellipseIn: circle), with: .color(color), style: gateStroke)
                tipX = cx + bubbleR
            }
            // Nóżka wyjściowa ma tę samą długość co nóżki wejścia (nie "dociąga" do
            // krawędzi strefy symbolu) — stąd stały koniec, nie symRect.maxX.
            var outLeg = Path()
            outLeg.move(to: CGPoint(x: tipX, y: symRect.midY))
            outLeg.addLine(to: CGPoint(x: tipX + legLen, y: symRect.midY))
            ctx.stroke(outLeg, with: .color(color), style: gateStroke)

            ctx.draw(
                Text(name)
                    .font(.custom("MatrixSansScreen-Regular", size: m.labelFontSize))
                    .foregroundColor(color),
                at: CGPoint(x: labelX, y: diagram.midY),
                anchor: .leading
            )

            // Tabela prawdy: cyfry maksymalnie duże (prawie dotykają góry/dołu ekranu),
            // odstępy między wierszami minimalne — każdy wiersz zajmuje 1/4 wysokości.
            let truth = truthTables[clampedIndex]
            let rowSlot = diagram.height / 4
            let rows = ["  0 0 = \(truth[0])", "  0 1 = \(truth[1])", "  1 0 = \(truth[2])", "  1 1 = \(truth[3])"]
            for (r, rowText) in rows.enumerated() {
                let rowY = diagram.minY + rowSlot * (CGFloat(r) + 0.5)
                ctx.draw(
                    Text(rowText)
                        .font(.system(size: m.tableFontSize, weight: .regular, design: .monospaced))
                        .foregroundColor(color),
                    at: CGPoint(x: tableX, y: rowY),
                    anchor: .leading
                )
            }
            return
        }

        if moduleTypeID == 38 {
            // Logic Pulse: u góry poziom wejścia — widoczne tylko jedno zbocze (odniesienie,
            // sygnał nie wraca do poprzedniego poziomu w kadrze), u dołu stały impuls
            // wyjściowy wyzwalany dokładnie w tym samym momencie co zbocze wejścia.
            // Geometria piksel po pikselu z SVG-PNG/Logic-Pulse-1 (Pos edge, index 0) i
            // Logic-Pulse-2 (Neg edge, index 1).png.
            let topLow = diagram.minY + diagram.height * 0.42
            let topHigh = diagram.minY + diagram.height * 0.08
            let bottomLow = diagram.maxY - diagram.height * 0.08
            let bottomHigh = diagram.minY + diagram.height * 0.58

            let edgeX: CGFloat = 7.0 / 24
            let outputRise: CGFloat = 7.0 / 24
            let outputFall: CGFloat = 15.0 / 24

            func edgeStepPath(risingEdge: Bool) -> Path {
                let xEdge = diagram.minX + diagram.width * edgeX
                let startY = risingEdge ? topLow : topHigh
                let endY = risingEdge ? topHigh : topLow
                var path = Path()
                path.move(to: CGPoint(x: diagram.minX, y: startY))
                path.addLine(to: CGPoint(x: xEdge, y: startY))
                path.addLine(to: CGPoint(x: xEdge, y: endY))
                path.addLine(to: CGPoint(x: diagram.maxX, y: endY))
                return path
            }

            let inputStroke = StrokeStyle(lineWidth: UIMetrics.graphLineWidth * 0.75 * lineWidthScale,
                                          lineCap: .square, lineJoin: .miter)
            ctx.stroke(edgeStepPath(risingEdge: index % 2 == 0),
                       with: .color(UIColor.lcdText.opacity(0.45)), style: inputStroke)
            ctx.stroke(squareWavePath(highRanges: [(outputRise, outputFall)], yLow: bottomLow, yHigh: bottomHigh),
                       with: .color(UIColor.lcdText), style: stroke)
            return
        }

        // FlipFlop: kwadratowa obudowa układu niemal na całą wysokość ekranu, wypełniona
        // standardowym zielonym LCD; wejścia po lewej, Q / Q̅ po prawej.
        let chipMargin = diagram.height * 0.02
        let chipSize = diagram.height - chipMargin * 2
        let chip = CGRect(x: diagram.midX - chipSize / 2, y: diagram.minY + chipMargin,
                          width: chipSize, height: chipSize)
        ctx.fill(Path(chip), with: .color(UIColor.lcdBackground))
        ctx.stroke(Path(chip), with: .color(UIColor.lcdText), style: stroke)

        var pins = Path()
        // Wysokości pinów liczone dokładnie tak samo jak prawdziwy przewód gniazda
        // (PatchLayout.connectorCenter: yPt + połowa 11px widgetu gniazda ≈ 3,008pt —
        // środek okrągłego gniazda, nie surowy YPos z pliku). Wynik wyrażamy jako
        // BEZWYMIAROWY UŁAMEK wysokości selektora, nie punkty — `diagram` tutaj bywa w
        // dwóch różnych skalach: punkty modułu (zamknięty ekran) albo piksele ekranu
        // (wiersz rozwiniętej listy w Controls.swift). Punktowy offset pasował tylko
        // do tej pierwszej, w liście "przyklejał" piny do samej góry.
        let flipFlopUI = ModuleUIDatabase.shared.uiDef(forID: moduleTypeID)
        let connectorHalf: CGFloat = 5.5 * (140.0 / 256.0)
        let selector = flipFlopUI?.partSelectors.first
        let selectorTopY = selector?.yPt ?? 0
        let selectorInset: CGFloat = 1.0 // rect.insetBy(dx: 1, dy: 1) w drawLogicPartSelector
        let selectorDiagramHeight = max((selector?.heightPt ?? 1) - selectorInset * 2, 1)
        let dInputCenterY = (flipFlopUI?.inputs.first(where: { $0.codeRef == 1 })?.yPt ?? 0) + connectorHalf
        let clkInputCenterY = (flipFlopUI?.inputs.first(where: { $0.codeRef == 0 })?.yPt ?? 0) + connectorHalf
        let upperFrac = (dInputCenterY - selectorTopY - selectorInset) / selectorDiagramHeight
        let lowerFrac = (clkInputCenterY - selectorTopY - selectorInset) / selectorDiagramHeight
        let upperY = diagram.minY + diagram.height * upperFrac
        let lowerY = diagram.minY + diagram.height * lowerFrac
        pins.move(to: CGPoint(x: diagram.minX, y: upperY))
        pins.addLine(to: CGPoint(x: chip.minX, y: upperY))
        pins.move(to: CGPoint(x: diagram.minX, y: lowerY))
        pins.addLine(to: CGPoint(x: chip.minX, y: lowerY))
        pins.move(to: CGPoint(x: chip.maxX, y: upperY))
        pins.addLine(to: CGPoint(x: diagram.maxX, y: upperY))
        pins.move(to: CGPoint(x: chip.maxX, y: lowerY))
        pins.addLine(to: CGPoint(x: diagram.maxX, y: lowerY))
        ctx.stroke(pins, with: .color(UIColor.lcdText), style: stroke)

        let labelSize = max(2.6, chip.height * 0.38)
        // Oba warianty (D/Clk i S/Clk) mają ten sam trójkąt zegara u dołu po lewej —
        // różni je tylko górna litera (D vs S), potwierdzone na obu rysunkach referencji.
        let leftTop = index % 2 == 0 ? "D" : "S"
        // Odstęp liter/trójkąta od ramki kwadratu, proporcjonalny do jego rozmiaru (nie
        // stały punkt) — przy dużym kwadracie inaczej prawie dotykały krawędzi.
        let labelInset = chip.width * 0.07

        func drawChipLabel(_ label: String, size: CGFloat, at point: CGPoint, anchor: UnitPoint) {
            ctx.draw(
                Text(label)
                    .font(.system(size: size, weight: .medium))
                    .foregroundColor(UIColor.lcdText),
                at: point,
                anchor: anchor
            )
        }

        drawChipLabel(leftTop, size: labelSize, at: CGPoint(x: chip.minX + labelInset, y: upperY), anchor: .leading)

        // Trójkąt zegara — pełny, wypełniony kształt (nie glif czcionki, który wychodził
        // jako sam kontur).
        let triHeight = labelSize * 0.85 * 0.75
        let triWidth = triHeight * 0.72
        var clockTriangle = Path()
        clockTriangle.move(to: CGPoint(x: chip.minX + labelInset, y: lowerY - triHeight / 2))
        clockTriangle.addLine(to: CGPoint(x: chip.minX + labelInset, y: lowerY + triHeight / 2))
        clockTriangle.addLine(to: CGPoint(x: chip.minX + labelInset + triWidth, y: lowerY))
        clockTriangle.closeSubpath()
        ctx.fill(clockTriangle, with: .color(UIColor.lcdText))

        // Prawa kolumna (oba Q) wyrównana ręcznie liczonym środkiem znaku, a nie kotwicą
        // .trailing — przy dwóch różnych rozmiarach fontu SwiftUI nie wyrównywało ich
        // wizualnie do tej samej krawędzi (mniejsza litera "uciekała" w prawo).
        let topQGlyphWidth = labelSize * 0.6
        let topQCenterX = (chip.maxX - labelInset) - topQGlyphWidth / 2
        drawChipLabel("Q", size: labelSize, at: CGPoint(x: topQCenterX, y: upperY), anchor: .center)

        // Dolne Q jest o 1/3 mniejsze od górnego — tak jak w rozwiniętej referencji
        // użytkownika. Q̅: jawnie rysowana kreska nad literą zamiast znaku łączonego
        // (combining overline) — czcionka systemowa nie zawsze poprawnie go składa.
        // Kreska jest wyśrodkowana nad (mniejszą) literą i blisko jej górnej krawędzi,
        // ale jej nie dotyka.
        let bottomQSize = labelSize * 2.0 / 3.0
        let qGlyphWidth = bottomQSize * 0.6
        // Ten sam prawy brzeg co górne Q (chip.maxX - labelInset), więc obie litery mają
        // wspólną oś niezależnie od różnicy szerokości wynikającej z rozmiaru fontu.
        let qGlyphCenterX = (chip.maxX - labelInset) - qGlyphWidth / 2
        let qBarWidth = qGlyphWidth
        let qBarGap = bottomQSize * 0.1
        // Kreska dokłada wysokość ponad samą literę — bez korekty cała grupa (kreska+Q)
        // wypadała wyżej niż środek dolnego rzędu. Przesuwamy literę w dół o połowę tego
        // naddatku, żeby grupa jako całość była wyśrodkowana w pionie względem górnego Q
        // (a więc symetrycznie na osi dolnej pary gniazd, tak jak górne Q na górnej).
        let qDrawY = lowerY + qBarGap / 2
        let qBarY = qDrawY - bottomQSize * 0.5 - qBarGap
        var qOverline = Path()
        qOverline.move(to: CGPoint(x: qGlyphCenterX - qBarWidth / 2, y: qBarY))
        qOverline.addLine(to: CGPoint(x: qGlyphCenterX + qBarWidth / 2, y: qBarY))
        ctx.stroke(qOverline, with: .color(UIColor.lcdText),
                   lineWidth: max(0.3, UIMetrics.graphLineWidth * 0.7 * lineWidthScale))
        drawChipLabel("Q", size: bottomQSize, at: CGPoint(x: qGlyphCenterX, y: qDrawY), anchor: .center)
    }

    // MARK: - TextField (wyświetlacz LCD wartości parametru)

    private func drawBVTextFields(_ ctx: GraphicsContext, module: G2Module, rect: CGRect) {
        guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { return }
        guard !ui.textFields.isEmpty else { return }

        for tf in ui.textFields {
            let field = operatorTextFieldFrame(module: module, field: tf)
            let x = rect.minX + field.x
            let y = rect.minY + field.y
            let h: CGFloat = UIMetrics.textFieldHeight

            // Wąskie ekrany z parą +/- po prawej (np. Operator: Detune, Vel,
            // RateScale) nie mogą być rozszerzane na przyciski. BVerhue zostawia
            // między nimi małą szczelinę; zachowujemy ją, a minimum szerokości
            // stosujemy tylko wtedy, gdy nic nie stoi bezpośrednio obok.
            let incDecHeight = UIMetrics.incDecHeight
            let incDecGap = UIMetrics.incDecGap
            let nextIncDecX = ui.incDecButtons
                .filter { btn in
                    let origin = operatorIncDecOrigin(module: module, button: btn)
                    let buttonHeight = btn.isVertical ? incDecHeight * 2 + incDecGap : incDecHeight
                    let overlapsVertically = origin.y < field.y + h && origin.y + buttonHeight > field.y
                    return origin.x > field.x && overlapsVertically
                }
                .map { operatorIncDecOrigin(module: module, button: $0).x }
                .min()
            let isOperatorAMod = module.typeID == 180 && tf.id == 55
            let preferredWidth = isOperatorAMod ? field.width : max(field.width, UIMetrics.textFieldMinWidth)
            let maxWidthBeforeButton = nextIncDecX.map {
                max(field.width, $0 - field.x - 0.75)
            }
            let w = min(preferredWidth, maxWidthBeforeButton ?? preferredWidth)

            // Tło wyświetlacza: ciemnozielony LCD
            let boxRect = CGRect(x: x, y: y, width: w, height: h)
            PanelFace.recessed(ctx, boxRect, cornerRadius: UIMetrics.buttonCornerRadius,
                               fill: UIColor.lcdBackground, lineWidth: 0.4, shaded: panelShading)

            // Napis liczy `G2ParameterText.fieldText` — ta sama reguła służy oknu
            // Parameter Pages i narzędziom, które opisują patch bez okna.
            let text = G2ParameterText.fieldText(tf, module: module)

            // Tekst: jasna zieleń (LCD-style), proporcjonalny sans-serif (wąskie "1" bez podstawy).
            // `drawLcdText` centruje i dopasowuje rozmiar sam — dawny osobny hack dla krótkich
            // wartości Operatora (mniejszy font + inne centrowanie) niepotrzebny, ujednolicone.
            let fontSize: CGFloat = UIFont.lcdDisplay(boxHeight: h)
            drawLcdText(ctx, text: text, box: boxRect, fontSize: fontSize)
        }
    }

    /// Dzieli tekst LCD na część numeryczną i jednostkę (trailing litery / %).
    /// Np. "623.3HZ" → ("623.3", "HZ"), "50%" → ("50", "%"), "+12 +0" → ("+12 +0", "")
    private func splitLcdText(_ text: String) -> (num: String, unit: String) {
        // "/" dołączone do dopasowania, żeby sufiksy typu "m/oct"/"s/oct" (Glide Lin)
        // trafiały w całości do mniejszej czcionki jednostki, a nie tylko "oct"
        // (bez tego "m/" zostawało w dużej czcionce razem z cyframi i nie mieściło się).
        var splitIdx = text.endIndex
        for idx in text.indices.reversed() {
            if text[idx].isLetter || text[idx] == "%" || text[idx] == "/" {
                splitIdx = idx
            } else {
                break
            }
        }
        // Gdy wartość składa się wyłącznie z liter (np. "OFF"), nie jest jednostką
        // liczby — ma używać pełnego fontu LCD.
        if splitIdx == text.startIndex { return (text, "") }
        return (String(text[..<splitIdx]), String(text[splitIdx...]))
    }

    /// Rysuje tekst LCD: cyfry pełnym fontem, trailing litery/% mniejszym (65%).
    /// Wyrównanie do prawej krawędzi boxa, obie części na tej samej linii bazowej;
    /// tekst automatycznie zwęża odstępy i font, aby zachować margines po obu stronach.
    /// Zwraca rozmiar fontu PO dopasowaniu do boksu — wywołujący, który dorysowuje
    /// coś w tej samej matrycy pikseli (PM Driver), musi znać rzeczywistą wielkość
    /// liter, a nie tę żądaną.
    @discardableResult
    func drawLcdText(_ ctx: GraphicsContext, text: String, box: CGRect, fontSize: CGFloat,
                     color: Color = UIColor.lcdText, preferredTracking: CGFloat? = nil,
                     centered: Bool = false, unitRatio: CGFloat = 1.0) -> CGFloat
    {
        let fontName = "MatrixSansScreen-Regular"
        // Matrix Sans Screen: drobna korekta w dół, zmierzona piksel-po-pikselu.
        let yDescFix: CGFloat = fontSize * 0.013

        let (numStr, unitStr) = splitLcdText(text)

        func measuredWidth(_ string: String, size: CGFloat) -> CGFloat {
            guard !string.isEmpty else { return 0 }
            let font = NSFont(name: fontName, size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            return (string as NSString).size(withAttributes: [.font: font]).width
        }

        let initialUnitSize = fontSize * unitRatio
        let initialGap = unitStr.isEmpty ? 0 : fontSize * 0.10
        let initialWidth = measuredWidth(numStr, size: fontSize)
            + measuredWidth(unitStr, size: initialUnitSize) + initialGap
        let glyphGaps = max(1, numStr.count + unitStr.count - 1)
        let availableWidth = max(1, box.width - 1.4)

        // Litery zlewają się przy mocnej kompresji łatwiej niż cyfry — ogranicz kompresję
        // do 6% (zamiast 18%), reszta niedopasowania i tak trafi w proporcjonalne
        // zmniejszenie fontu (fitScale niżej).
        // Kropka w Matrix Sans Screen ma normalny, dodatni advance (200/1000 em) z
        // marginesem proporcjonalnie takim samym jak przy cyfrach (~5.7% em po obu
        // stronach, zmierzone z .ttf) — w odróżnieniu od poprzedniego DSEG14 (advance=0,
        // margines 5x węższy niż międzycyfrowy) nie potrzebuje już osobnego traktowania.
        let lettersOnly = text.allSatisfy(\.isLetter)
        let trackingFloorRatio: CGFloat = lettersOnly ? 0.06 : 0.18
        // Najpierw redukuj odstępy między znakami (do trackingFloorRatio wysokości fontu),
        // dopiero pozostały nadmiar kompensuj proporcjonalnym zmniejszeniem fontu.
        let requestedTracking = (availableWidth - initialWidth) / CGFloat(glyphGaps)
        let initialTracking: CGFloat = if let preferredTracking {
            // Kontrolki o nazwach własnych (DrumSynth) mogą wykorzystywać wolną
            // szerokość na równy, dodatni odstęp; nigdy nie zmniejszamy wtedy fontu.
            min(preferredTracking, max(0, requestedTracking))
        } else {
            max(-fontSize * trackingFloorRatio, min(0, requestedTracking))
        }
        let trackedWidth = max(1, initialWidth + initialTracking * CGFloat(glyphGaps))
        let fitScale = min(1, availableWidth / trackedWidth)

        let fittedFontSize = fontSize * fitScale
        let unitSize = fittedFontSize * unitRatio
        let tracking = initialTracking * fitScale
        let gap = unitStr.isEmpty ? 0 : fittedFontSize * 0.10
        let unitGaps = max(0, unitStr.count - 1)
        let unitW = measuredWidth(unitStr, size: unitSize)
            + tracking * CGFloat(unitGaps) + gap

        // Wyśrodkowanie całego bloku (liczba+jednostka razem) w boksie zamiast
        // przyklejenia do prawej krawędzi — jednakowy margines z obu stron zamiast
        // pustego miejsca po lewej przy krótszej treści. `finalWidth` to rzeczywista
        // szerokość po dopasowaniu (trackedWidth pomniejszone przez fitScale, albo
        // availableWidth gdy fitScale=1) — ten sam wzór co przy liczeniu fitScale wyżej.
        let finalWidth = min(trackedWidth, availableWidth)
        let rightX = box.minX + (box.width + finalWidth) / 2 + 0.4
        let centerText = centered && unitStr.isEmpty

        let baseY = box.midY + yDescFix
        let unitBaseShift = (fittedFontSize - unitSize) * 0.5

        if !unitStr.isEmpty {
            ctx.draw(
                Text(unitStr)
                    .font(.custom(fontName, size: unitSize))
                    .tracking(tracking)
                    .foregroundColor(color),
                at: CGPoint(x: rightX, y: baseY + unitBaseShift),
                anchor: .trailing
            )
        }
        if !numStr.isEmpty {
            ctx.draw(
                Text(numStr)
                    .font(.custom(fontName, size: fittedFontSize))
                    .tracking(tracking)
                    .foregroundColor(color),
                at: CGPoint(x: centerText || lettersOnly ? box.midX : rightX - unitW, y: baseY),
                anchor: centerText || lettersOnly ? .center : .trailing
            )
        }
        return fittedFontSize
    }

    // MARK: - LevelShift (OutputType cyclic button)

    /// Klikalny/rysowalny obszar LevelShift (kolorowy środek, bez ciemnej obwódki) —
    /// wspólny dla rysowania, hit-testingu i obsługi kliknięcia, żeby wszystkie trzy
    /// zawsze zgadzały się co do tego samego prostokąta. Wyrównuje pionowo do środka
    /// najbliższego gniazda w tym samym wierszu (BVerhue YPos zostawia zwykle ~1pt
    /// luzu, przez co surowa pozycja stała odrobinę wyżej niż środek gniazda obok);
    /// surowy YPos zostaje, gdy żadne gniazdo nie jest w pobliżu.
    func levelShiftRect(_ ls: BVLevelShift, moduleTypeID: Int, in moduleRect: CGRect) -> CGRect {
        guard let ui = ModuleUIDatabase.shared.uiDef(forID: moduleTypeID) else {
            let s = UIMetrics.powerButtonSize
            return CGRect(x: moduleRect.minX + ls.xPt, y: moduleRect.minY + ls.yPt, width: s, height: s)
        }
        let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
        // Gniazdo OBOK w tym samym wierszu (nie pod spodem — patrz analogiczny warunek
        // przy przycisku Power), żeby wyrównać oba do jednej osi poziomej. Bierzemy
        // NAJBLIŻSZE w poziomie, nie pierwsze z listy: w LfoShpA gniazdo wejściowe po
        // lewej stronie modułu ma YPos:59, a sąsiadujące wyjście YPos:60 — pierwsze z
        // brzegu dawało oś o 0,55pt wyżej niż gniazdo faktycznie stojące obok.
        let nearbyConn = (ui.inputs + ui.outputs)
            .filter {
                abs($0.yPt - ls.yPt) < 4.0
                    && ($0.xPt + 2 * connHalf <= ls.xPt || $0.xPt >= ls.xPt + UIMetrics.powerButtonSize)
            }
            .min { abs($0.xPt - ls.xPt) < abs($1.xPt - ls.xPt) }
        let s = UIMetrics.powerButtonSize
        let x: CGFloat
        if moduleTypeID == 24,
           let led = ui.leds.first(where: { $0.type == .green })
        {
            // LfoC places PosInv directly below its status LED, so both controls
            // share one horizontal center despite their different widths.
            x = moduleRect.minX + led.xPt + (UIMetrics.ledGreenSize - s) / 2
        } else if moduleTypeID == 157,
                  let input = ui.inputs.first,
                  let output = ui.outputs.first
        {
            // LevConv: przycisk B+/P+/N+ stoi dokładnie pośrodku wolnego
            // miejsca między zewnętrznymi krawędziami obu gniazd.
            let connectorSide = 2 * connHalf
            let gapLeft = moduleRect.minX + input.xPt + connectorSide
            let gapRight = moduleRect.minX + output.xPt
            x = (gapLeft + gapRight - s) / 2
        } else {
            x = moduleRect.minX + ls.xPt
        }
        let y = moduleRect.minY + (nearbyConn.map { $0.yPt + connHalf - s / 2 } ?? ls.yPt)
        return CGRect(x: x, y: y, width: s, height: s)
    }

    private func drawBVLevelShifts(_ ctx: GraphicsContext, module: G2Module, rect: CGRect) {
        guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { return }
        guard !ui.levelShifts.isEmpty else { return }

        for ls in ui.levelShifts {
            let innerRect = levelShiftRect(ls, moduleTypeID: module.typeID, in: rect)
            let value = ls.codeRef < module.parameters.count ? module.parameters[ls.codeRef] : 0
            let shortLabel = switch value % 6 {
            case 0: "P+"
            case 1: "P\u{2212}" // P−
            case 2: "N+"
            case 3: "N\u{2212}" // N−
            case 4: "B+"
            default: "B\u{2212}" // B−
            }

            drawPowerSizedLabelButton(ctx, in: innerRect, label: shortLabel)
        }
    }

    /// Kwadratowy przycisk rozmiaru Power z krótkim napisem w środku — wspólny wygląd
    /// LevelShift („P+"/„B−") i selektora OutputType („B"/„P"/„N").
    ///
    /// Ten sam CAŁKOWITY rozmiar co przycisk Power (`innerRect` rozszerzony o
    /// `socketOuterMargin`, patrz `isActive` w drawBVButtons) — zewnętrzna krawędź
    /// zostaje w tym samym miejscu co dotąd. Ramka to jednak cienki kontur, taki
    /// sam jak w pozostałych przyciskach (KB/Gate), a nie gruba czarna obwódka
    /// Power — ta ostatnia na małym, niepodświetlanym przycisku wyglądała znacznie
    /// grubiej niż ramki sąsiednich przycisków (zgłoszone przez użytkownika).
    func drawPowerSizedLabelButton(_ ctx: GraphicsContext, in innerRect: CGRect, label: String) {
        let margin = UIMetrics.socketOuterMargin
        let outerRect = innerRect.insetBy(dx: -margin, dy: -margin)
        let corner = UIMetrics.socketCornerRadius + margin
        PanelFace.raised(ctx, outerRect, cornerRadius: corner,
                         fill: UIColor.buttonActive, border: .black.opacity(0.4), shaded: panelShading)
        // Kerning ujemny ściąga znak +/− bliżej litery (para w pełnym rozstawie nie
        // mieści się w ~5.6pt boksie). Doliczany jest jednak także PO ostatnim znaku,
        // więc pudełko tekstu kończy się o `kerning` wcześniej niż same litery —
        // wyśrodkowanie pudełka wypychało napis o pół kerna w prawo i „+"/„−" dotykał
        // prawej krawędzi przycisku. Cofnięcie o tę połowę stawia litery w jego osi.
        // Napis jednoznakowy (OutputType) nie ma czego ściągać — stoi w czystej osi.
        let kerning: CGFloat = label.count > 1 ? -0.4 : 0
        ctx.draw(
            Text(label)
                .font(.system(size: UIFont.buttonLabel, weight: .bold))
                .kerning(kerning)
                .foregroundColor(.white),
            at: CGPoint(x: innerRect.midX + kerning / 2, y: innerRect.midY),
            anchor: .center
        )
    }
}
