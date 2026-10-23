// LiveIndicatorLayer.swift
// Warstwa 5 mechanizmu Clavii: rysowanie tego, co miga, ODDZIELONE od reszty edytora.
//
// Do 2026-09-06 poziomy wskaźników szły przez `ContentView` jako zwykły parametr
// `PatchCanvasView`. `ContentView` czytał wtedy `device.meters` we własnym `body`, więc
// KAŻDA paczka wskaźników (20×/s) unieważniała całe okno: pasek narzędzi, kanwę i menu
// kontekstowe razem z nią — otwarta lista kolorów modułu mrugała, dopóki grał dźwięk.
//
// Teraz `device.meters` czyta wyłącznie ta warstwa. Reszta widoków dostaje sam obiekt
// `DeviceConnection` i nie sięga do jego pól, więc Observation ich nie budzi. To ta sama
// zasada, na której stoi oryginał: Patch Background (UpdateBlink) przerysowuje wyłącznie
// widżety z zapalonym znacznikiem `dirty`, nie patch → [[Docs/usb/notifications]].
//
// Drugi krok w tę samą stronę (2026-09-06): geometria — które moduły mają wskaźniki, gdzie
// leżą ich segmenty i diody — liczy się RAZ na układ patcha, nie przy każdej klatce.
// Wcześniej każda paczka przeliczała `PatchLayout.moduleRect` dla wszystkich modułów, a ta
// dla każdego przegląda całą listę w poszukiwaniu sąsiada z dołu (`effectiveHeightRows`):
// koszt rósł z kwadratem liczby modułów i wracał 20×/s po ten sam wynik. Oryginał robi to
// samo co my teraz — `CLedDataList::PopulateList` buduje listę widżetów przy otwarciu
// patcha, a strumień jest już tylko ciągiem wartości.

import G2Core
import G2EditorCore
import SwiftUI

/// Klucz pojedynczego wskaźnika: moduł + numer grupy w `MiniVUDatabase`
/// (2-Out: 0 = L, 1 = R).
struct LiveVUKey: Hashable {
    let moduleID: Int
    let groupID: Int
}

/// Geometria i kolory segmentów miniVU — **jedno** miejsce dla obu warstw: kanwa rysuje
/// wskaźnik wygaszony, ta warstwa dokłada na wierzch segmenty zapalone. Rozjazd między
/// dwiema kopiami tych obliczeń byłby widoczny jako przesunięte słupki.
enum MiniVUGeometry {
    /// Grubość ramki wskaźnika. Oryginał obrysowuje Peak Meter czarną obwódką
    /// i dopiero w środku rysuje paski — bez niej wygaszone segmenty zlewają się
    /// z kolorowym tłem modułu. Ramka mieści się W OBRYSIE wskaźnika, więc jego
    /// wielkość i położenie się nie zmieniają.
    static let frameWidth: CGFloat = 0.4

    /// Zaokrąglenie rogów ramki. Mniejsze niż ~1 pt, więc róg diody wewnątrz nigdy
    /// nie wystaje poza zaokrąglenie i diody nie trzeba przycinać.
    static let cornerRadius: CGFloat = 0.8

    /// Cały obrys wskaźnika: górna krawędź to `yPt` z BVerhue podniesione
    /// o `miniVUTopShift` (nasz wskaźnik jest wyższy niż oryginał), dolna nie wychodzi
    /// poza panel modułu.
    static func bounds(def: BVMiniVUDef, in rect: CGRect) -> CGRect {
        let top = rect.minY + def.yPt - UIMetrics.miniVUTopShift
        let bottom = min(top + UIMetrics.miniVUHeight, rect.maxY - 1.0)
        return CGRect(x: rect.minX + def.xPt, y: top,
                      width: UIMetrics.miniVUWidth, height: bottom - top)
    }

    /// Czarna kreska między sąsiednimi diodami — przez nią prześwituje ramka. Bez niej
    /// zapalony słupek wyglądał jak trzy jednolite plamy zamiast rzędu diod.
    static let separator: CGFloat = 0.15

    /// Wysokość czerwonej diody przesteru w jednostkach zwykłej diody. U Clavii
    /// (Peak Meter, 16 px) zielone i żółte linie mają po 1 px, czerwony blok 3 px.
    static let clipLedUnits: CGFloat = 3

    /// Prostokąty diod od DOŁU (indeks 0 = najniższa), w układzie kanwy. Leżą
    /// **wewnątrz ramki**, rozdzielone kreską `separator`; ostatnia, czerwona, jest
    /// `clipLedUnits` razy wyższa od pozostałych.
    static func segments(def: BVMiniVUDef, in rect: CGRect) -> [CGRect] {
        let inner = bounds(def: def, in: rect).insetBy(dx: frameWidth, dy: frameWidth)
        let count = UIMetrics.miniVUSegments
        let units = CGFloat(count - 1) + clipLedUnits
        let unit = (inner.height - CGFloat(count - 1) * separator) / units
        var bottom = inner.maxY
        return (0 ..< count).map { index in
            let height = index == count - 1 ? unit * clipLedUnits : unit
            defer { bottom -= height + separator }
            return CGRect(x: inner.minX, y: bottom - height, width: inner.width, height: height)
        }
    }

    /// Kolor ramki — ciemny, żeby wskaźnik odcinał się od tła modułu w każdym kolorze.
    static let frameColor = Color(red: 0.06, green: 0.06, blue: 0.06)

    /// Trzy strefy, **z progami oryginału**: Peak Meter (Draw) zapala siedem zielonych
    /// linii przy poziomie 1…7, cztery żółte przy 8…11, a czerwony blok od 12 wzwyż albo
    /// przy znaczniku przesteru. Tyle samo diod ma nasz słupek (od 2026-09-27; wcześniej
    /// 15 kresek z czterema czerwonymi, z których przester zapalał tylko jedną).
    ///
    /// Do 2026-09-06 zieleń sięgała ósmej kreski (za BVerhue) i przez to pierwsza żółta
    /// zapalała się o jeden poziom za późno.
    static func color(segment: Int, lit: Bool) -> Color {
        if segment < 7 {
            return lit ? Color(red: 0.0, green: 0.85, blue: 0.15) : Color(red: 0.0, green: 0.22, blue: 0.0)
        }
        if segment < 11 {
            return lit ? Color(red: 0.95, green: 0.85, blue: 0.0) : Color(red: 0.22, green: 0.20, blue: 0.0)
        }
        return lit ? Color(red: 0.95, green: 0.1, blue: 0.1) : Color(red: 0.22, green: 0.0, blue: 0.0)
    }
}

/// Geometria i kolory diod — jak przy miniVU, **jedno** miejsce dla obu warstw.
enum LedGeometry {
    /// Prostokąt diody. `XPos`/`YPos` z BVerhue to lewy-górny róg (konwencja Delphi);
    /// dioda kroku sekwencera stoi dokładnie tam, gdzie ją zapisano — te same dane co
    /// tory faderów pod nią, więc odstęp dioda→tor jest wszędzie jednakowy.
    static func rect(for led: BVLED, typeID: Int, in moduleRect: CGRect) -> CGRect {
        if typeID == compressorTypeID, let ui = ModuleUIDatabase.shared.uiDef(forID: typeID) {
            let bars = compressorMeterBars(ui: ui, rect: moduleRect)
            if bars.indices.contains(led.codeRef) { return bars[led.codeRef] }
        }
        let origin = CGPoint(x: moduleRect.minX + led.xPt, y: moduleRect.minY + led.yPt)
        switch led.type {
        case .green:
            return CGRect(origin: origin,
                          size: CGSize(width: UIMetrics.ledGreenSize, height: UIMetrics.ledGreenSize))
        case .sequencer:
            return CGRect(origin: origin,
                          size: CGSize(width: UIMetrics.ledSeqWidth, height: UIMetrics.ledSeqHeight))
        }
    }

    // MARK: Compress — miernik Gain Reduction

    static let compressorTypeID = 150

    /// Dziesięć segmentów Gain Reduction, od góry (indeks = `CodeRef` diody: w danych
    /// panelu `CodeRef` 0 stoi najwyżej, 9 najniżej). Miernik jest dosunięty dołem do
    /// Power, a nie ustawiony wg `YPos` z danych — i dlatego kanwa (zgaszone) i warstwa
    /// na żywo (zapalone) MUSZĄ brać prostokąty stąd. Do 2026-09-25 warstwa na żywo brała
    /// `YPos` i zapalone segmenty wisiały wyżej niż zgaszone.
    static func compressorMeterBars(ui: ModuleUIDef, rect: CGRect) -> [CGRect] {
        let x = rect.minX + 195 * PatchLayout.bverhuePixelScale
        let width = UIMetrics.ledSeqWidth
        let height = UIMetrics.ledSeqHeight
        let gap: CGFloat = 0.75
        // Obrys ma grubość 0.35 pt, więc geometryczny prostokąt przesuwamy
        // o połowę obrysu: widoczny dół ostatniej diody równa się Power.
        let strokeHalf: CGFloat = 0.175
        let bottom = compressorPowerBottomY(ui: ui, rect: rect) - strokeHalf
        let top = bottom - height - 9 * (height + gap)
        return (0 ..< 10).map { index in
            CGRect(x: x, y: top + CGFloat(index) * (height + gap), width: width, height: height)
        }
    }

    /// Dolna krawędź zewnętrznej obwódki Power w Compressie. Obliczenie powiela
    /// geometrię `drawBVButtons`, aby miernik Gain Reduction dzielił z nią tę samą
    /// oś także przy zmianie skali canvasu.
    static func compressorPowerBottomY(ui: ModuleUIDef, rect: CGRect) -> CGFloat {
        guard let power = ui.buttonsText.first(where: { $0.codeRef == 6 }) else {
            return rect.minY
        }

        let margin = UIMetrics.socketOuterMargin
        let connHalf: CGFloat = 5.5 * PatchLayout.bverhuePixelScale
        let size = UIMetrics.powerButtonSize
        let width = max(power.widthPt, 6)
        let leftPt = power.xPt + (width - size) / 2
        func overlapsHorizontally(_ conn: BVConnector) -> Bool {
            conn.xPt + 2 * connHalf > leftPt && conn.xPt < leftPt + size
        }
        let rowConn = (ui.inputs + ui.outputs)
            .filter { abs($0.yPt - power.yPt) < 4.0 && !overlapsHorizontally($0) }
            .min { abs($0.xPt - leftPt) < abs($1.xPt - leftPt) }
        let centerY = rect.minY + (rowConn.map { $0.yPt + connHalf }
            ?? power.yPt + UIMetrics.buttonTextHeight / 2)
        return centerY + size / 2 + margin
    }

    static func color(type: BVLEDType, lit: Bool) -> Color {
        switch type {
        case .green: lit ? UIColor.ledGreenOn : UIColor.ledGreenOff
        case .sequencer: lit ? UIColor.ledSequencerOn : UIColor.ledSequencer
        }
    }

    /// Jedna dioda — wklęsła jak ekran. Kanwa rysuje wszystkie zgaszone, a warstwa na
    /// żywo kładzie zapaloną na wierzch; ta zakrywa wgłębienie pod sobą, więc ma własne.
    static func draw(_ ctx: GraphicsContext, rect ledRect: CGRect, type: BVLEDType, lit: Bool, shaded: Bool) {
        PanelFace.recessed(ctx, ledRect, cornerRadius: 0.5, fill: color(type: type, lit: lit),
                           border: .black.opacity(type == .green ? 0.5 : 0.4),
                           lineWidth: type == .green ? 0.4 : 0.3, shaded: shaded)
    }
}

// MARK: - Plan rysowania

/// Gotowa geometria wszystkiego, co może się zaświecić w tym obszarze patcha. Liczona raz
/// na układ modułów; klatka tylko wybiera z niej to, co niesie strumień.
struct LiveIndicatorPlan {
    struct Led {
        let codeRef: Int
        let rect: CGRect
        let type: BVLEDType
    }

    struct Module {
        /// Obrys każdego wskaźnika, `[groupID]` — pod wgłębienie (`Bevel.recess`).
        let vuBounds: [CGRect]
        /// Segmenty wskaźników, `[groupID][segment od dołu]`.
        let vuSegments: [[CGRect]]
        /// Diody należące do grupy (`0x3A`) — razem z numerami do reguły `CPanel::Blink`.
        let groupLeds: [Led]
        let groupCodeRefs: [Int]
        /// Diody sterowane pojedynczo (`0x39`), po numerze `CodeRef`.
        let singleLeds: [Int: Led]
    }

    let modules: [Int: Module]
    let signature: Int

    static let empty = LiveIndicatorPlan(modules: [:], signature: 0)

    private init(modules: [Int: Module], signature: Int) {
        self.modules = modules
        self.signature = signature
    }

    /// Odcisk układu: co, jakiego typu i w którym miejscu siatki stoi. Zmiana
    /// któregokolwiek z tych trzech przesuwa prostokąty, więc plan trzeba przeliczyć;
    /// obrót gałki ani zmiana nazwy — nie.
    static func signature(patch: G2Patch, area: PatchArea) -> Int {
        var hasher = Hasher()
        for module in patch.modules(in: area) {
            hasher.combine(module.id)
            hasher.combine(module.typeID)
            hasher.combine(module.column)
            hasher.combine(module.row)
        }
        return hasher.finalize()
    }

    init(patch: G2Patch, area: PatchArea) {
        let allModules = patch.modules(in: area)
        let rowOffset = PatchLayout.minRow(modules: allModules)
        var modules: [Int: Module] = [:]
        for module in allModules {
            let vuDefs = MiniVUDatabase.defs(forModuleID: module.typeID)
            let groupDefs = G2VisualStream.groupLeds(typeID: module.typeID)
            let singleDefs = G2VisualStream.singleLeds(typeID: module.typeID)
            guard !vuDefs.isEmpty || !groupDefs.isEmpty || !singleDefs.isEmpty else { continue }
            let rect = PatchLayout.moduleRect(module,
                                              def: ModuleDatabase.module(id: module.typeID),
                                              rowOffset: rowOffset,
                                              allModules: allModules)
            let groupLeds = groupDefs.map {
                Led(codeRef: $0.codeRef, rect: LedGeometry.rect(for: $0, typeID: module.typeID, in: rect),
                    type: $0.type)
            }
            var singleLeds: [Int: Led] = [:]
            for led in singleDefs {
                singleLeds[led.codeRef] = Led(codeRef: led.codeRef,
                                              rect: LedGeometry.rect(for: led, typeID: module.typeID, in: rect),
                                              type: led.type)
            }
            modules[module.id] = Module(
                vuBounds: vuDefs.map { MiniVUGeometry.bounds(def: $0, in: rect) },
                vuSegments: vuDefs.map { MiniVUGeometry.segments(def: $0, in: rect) },
                groupLeds: groupLeds,
                groupCodeRefs: groupLeds.map(\.codeRef),
                singleLeds: singleLeds
            )
        }
        self.modules = modules
        signature = Self.signature(patch: patch, area: area)
    }

    /// Plan z modułami `ids` przesuniętymi o `offset` — w trakcie przeciągania kanwa rysuje
    /// je w nowym miejscu, a patch zna jeszcze stare (zmienia się dopiero po puszczeniu).
    func shifted(_ ids: Set<Int>, by offset: CGSize) -> LiveIndicatorPlan {
        guard offset != .zero, !ids.isEmpty else { return self }
        var moved = modules
        for id in ids {
            guard let module = modules[id] else { continue }
            func move(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: offset.width, dy: offset.height) }
            func move(_ led: Led) -> Led { Led(codeRef: led.codeRef, rect: move(led.rect), type: led.type) }
            moved[id] = Module(
                vuBounds: module.vuBounds.map(move),
                vuSegments: module.vuSegments.map { $0.map(move) },
                groupLeds: module.groupLeds.map(move),
                groupCodeRefs: module.groupCodeRefs,
                singleLeds: module.singleLeds.mapValues(move)
            )
        }
        return LiveIndicatorPlan(modules: moved, signature: signature)
    }
}

/// Trzyma ostatni plan między klatkami. Zwykły obiekt, celowo NIE `@Observable`:
/// jego podmiana nie ma prawa unieważnić żadnego widoku.
final class LiveIndicatorPlanCache {
    private var plan = LiveIndicatorPlan.empty

    func plan(patch: G2Patch, area: PatchArea) -> LiveIndicatorPlan {
        let signature = LiveIndicatorPlan.signature(patch: patch, area: area)
        if plan.signature != signature { plan = LiveIndicatorPlan(patch: patch, area: area) }
        return plan
    }
}

// MARK: - Warstwa

/// Przezroczysta kanwa nad panelami: rysuje wyłącznie to, co świeci. Bez połączenia
/// (albo gdy strumień dotyczy innego slotu niż oglądany) nie rysuje NIC — wskaźniki
/// wygaszone maluje wtedy zwykła kanwa, dokładnie jak przed tą zmianą.
struct LiveIndicatorLayer: View {
    let patch: G2Patch
    let area: PatchArea
    let zoom: CGFloat
    /// Slot pokazany w edytorze — strumień z innego slotu nie opisuje tego, co widać.
    let slot: Int
    let canvasSize: CGSize
    let device: DeviceConnection?
    /// View ▸ 3D Buttons and Screens — zapalone diody i kreski Mini VU dostają to samo
    /// wgłębienie co zgaszone.
    var panelShading = true
    /// Setup ▸ Options ▸ Glow — blask wokół zapalonych diod i kresek Mini VU.
    var glow = 0.0
    /// Moduły w trakcie przeciągania i droga myszy (pt kanwy) — diody jadą razem z nimi.
    var draggedModuleIDs: Set<Int> = []
    var dragOffset: CGSize = .zero

    @State private var cache = LiveIndicatorPlanCache()

    var body: some View {
        let levels = vuLevels()
        let groups = ledGroupValues()
        let lit = litLeds()
        // Plan liczymy dopiero, gdy jest co rysować — patch bez połączenia nie płaci nic.
        let plan = levels.isEmpty && groups.isEmpty && lit.isEmpty
            ? LiveIndicatorPlan.empty
            : cache.plan(patch: patch, area: area).shifted(draggedModuleIDs, by: dragOffset)
        Canvas { ctx, _ in
            guard !plan.modules.isEmpty else { return }
            ctx.scaleBy(x: zoom, y: zoom)
            if glow > 0.001 {
                Glow.fill(ctx, glowLights(plan: plan, levels: levels, groups: groups, lit: lit),
                          size: UIMetrics.ledGreenSize, amount: glow)
            }
            for (key, level) in levels where level > 0 {
                guard let module = plan.modules[key.moduleID],
                      module.vuSegments.indices.contains(key.groupID) else { continue }
                let lit = module.vuSegments[key.groupID].prefix(level)
                for (index, segment) in lit.enumerated() {
                    ctx.fill(Path(segment), with: .color(MiniVUGeometry.color(segment: index, lit: true)))
                }
                // Zapalone diody zakrywają wgłębienie, które kanwa narysowała na zgaszonych —
                // kładziemy je jeszcze raz, ale tylko na nie, żeby nigdzie nie wyszło podwójnie.
                if panelShading {
                    var shade = ctx
                    shade.clip(to: Path { path in lit.forEach { path.addRect($0) } })
                    Bevel.recess(shade, module.vuBounds[key.groupID], cornerRadius: MiniVUGeometry.cornerRadius)
                }
            }
            // Grupa diod: świeci ta, której `CodeRef` wskazuje wartość ze strumienia.
            // Wartość spoza zakresu (sekwencer stojący nadaje 16 albo 255) nie trafia
            // w żaden `CodeRef`, więc nie świeci nic — i o to chodzi.
            for (moduleID, value) in groups {
                guard let module = plan.modules[moduleID], !module.groupLeds.isEmpty else { continue }
                let refs = Set(G2VisualStream.litCodeRefs(groupValue: value,
                                                          codeRefs: module.groupCodeRefs))
                guard !refs.isEmpty else { continue }
                for led in module.groupLeds where refs.contains(led.codeRef) {
                    LedGeometry.draw(ctx, rect: led.rect, type: led.type, lit: true, shaded: panelShading)
                }
            }
            // Pojedyncze diody (obwiednie, LFO) — osobny komunikat `0x39`.
            for (moduleID, codeRefs) in lit {
                guard let module = plan.modules[moduleID] else { continue }
                for codeRef in codeRefs {
                    guard let led = module.singleLeds[codeRef] else { continue }
                    LedGeometry.draw(ctx, rect: led.rect, type: led.type, lit: true, shaded: panelShading)
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        // Warstwa leży NAD panelami, więc bez tego przechwytywałaby każde kliknięcie
        // w moduł — gałki, przyciski i kable przestałyby działać.
        .allowsHitTesting(false)
    }

    /// Wszystko, co w tej klatce świeci — pod blask, rysowany jedną warstwą pod diodami.
    /// Te same reguły wyboru co w `body`.
    private func glowLights(plan: LiveIndicatorPlan, levels: [LiveVUKey: Int], groups: [Int: Int],
                            lit: [Int: Set<Int>]) -> [(rect: CGRect, color: Color)]
    {
        var lights: [(rect: CGRect, color: Color)] = []
        for (key, level) in levels where level > 0 {
            guard let module = plan.modules[key.moduleID],
                  module.vuSegments.indices.contains(key.groupID) else { continue }
            for (index, segment) in module.vuSegments[key.groupID].prefix(level).enumerated() {
                lights.append((segment, MiniVUGeometry.color(segment: index, lit: true)))
            }
        }
        for (moduleID, value) in groups {
            guard let module = plan.modules[moduleID], !module.groupLeds.isEmpty else { continue }
            let refs = Set(G2VisualStream.litCodeRefs(groupValue: value, codeRefs: module.groupCodeRefs))
            for led in module.groupLeds where refs.contains(led.codeRef) {
                lights.append((led.rect, LedGeometry.color(type: led.type, lit: true)))
            }
        }
        for (moduleID, codeRefs) in lit {
            guard let module = plan.modules[moduleID] else { continue }
            for codeRef in codeRefs {
                if let led = module.singleLeds[codeRef] {
                    lights.append((led.rect, LedGeometry.color(type: led.type, lit: true)))
                }
            }
        }
        return lights
    }

    /// Czy strumień, który mamy, opisuje to, co widać na ekranie.
    private var readsDevice: DeviceConnection? {
        guard let device, device.status == .connected, device.meterSlot == slot else { return nil }
        return device
    }

    /// Wartość grupy diod per moduł — surowa, ze strumienia. Co z niej wynika (indeks,
    /// maska, „wszystkie"), rozstrzyga `G2VisualStream.litCodeRefs(groupValue:codeRefs:)`;
    /// jedna reguła obsługuje multipleksery, liczniki, sekwencery, przetwornik A/D
    /// i miernik kompresora, bo tryb niesie sama wartość.
    private func ledGroupValues() -> [Int: Int] {
        guard let device = readsDevice else { return [:] }
        var values: [Int: Int] = [:]
        for reading in device.ledGroups where reading.area == area {
            values[reading.moduleID] = reading.value
        }
        return values
    }

    /// Świecące pojedyncze diody: moduł → zbiór `CodeRef`. Oryginał zapala widżet przy
    /// każdej wartości ≠ 0 (Green Led (SetColor)), więc dwa bity znaczą u nas
    /// „świeci / nie świeci".
    private func litLeds() -> [Int: Set<Int>] {
        guard let device = readsDevice else { return [:] }
        var lit: [Int: Set<Int>] = [:]
        for reading in device.leds where reading.area == area && reading.isLit {
            lit[reading.moduleID, default: []].insert(reading.codeRef)
        }
        return lit
    }

    /// Poziomy przeliczone ze strumienia urządzenia na liczbę zapalonych segmentów.
    /// **To jedyne miejsce w aplikacji, które czyta `device.meters`.**
    private func vuLevels() -> [LiveVUKey: Int] {
        guard let device = readsDevice else { return [:] }
        var levels: [LiveVUKey: Int] = [:]
        for reading in device.meters where reading.area == area {
            for (groupID, value) in reading.values.enumerated() {
                let level = G2VisualStream.segmentLevel(forValue: value,
                                                        segments: UIMetrics.miniVUSegments)
                guard level > 0 else { continue }
                levels[LiveVUKey(moduleID: reading.moduleID, groupID: groupID)] = level
            }
        }
        return levels
    }
}
