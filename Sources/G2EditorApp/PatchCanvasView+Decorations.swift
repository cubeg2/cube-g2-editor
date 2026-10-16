import AppKit
import G2Core
import G2EditorCore
import SwiftUI

extension PatchCanvasView {
    // MARK: - Cables

    func drawCables(_ ctx: GraphicsContext) {
        var byID = [Int: G2Module]()
        for m in modules {
            byID[m.id] = m
        }
        let highlighted = highlightedChain()
        // Przy dużym powiększeniu kanwa rysuje się kafelkami — kabel spoza kafelka pomijamy.
        let clip = ctx.clipBoundingRect

        for (idx, cable) in cables.enumerated() {
            guard !hiddenColors.contains(cable.color) else { continue }
            guard let src = byID[cable.fromModule],
                  let dst = byID[cable.toModule] else { continue }

            // Kabel wejście→wejście zaczyna się na wejściu — z `isOutput: true` jego
            // początek lądował w miejscu nieistniejącego wyjścia o tym numerze.
            let p1 = connectorCenterForDraw(module: src, connIndex: cable.fromConnector,
                                            isOutput: cable.sourceIsOutput)
            let p2 = connectorCenterForDraw(module: dst, connIndex: cable.toConnector, isOutput: false)
            let shakeX = cableShakeOffset(cableIndex: idx)
            guard Self.cableBounds(from: p1, to: p2, shakeX: shakeX).intersects(clip) else { continue }

            drawCable(ctx, from: p1, to: p2, color: cable.color,
                      shakeX: shakeX,
                      highlighted: highlighted.contains { $0.connectsSameAs(cable) })
        }

        // Rubber-band: nowy kabel
        if let drag = connectorDrag {
            let color = renderedCableColor(for: drag.source.signalType)
            drawCable(ctx, from: drag.source.center, to: drag.tipPt, color: color, shakeX: 0)
        }

        // Rubber-band: repatch (od kotwicy do kursora)
        if let drag = repatchDrag {
            let color = renderedCableColor(for: drag.anchor.signalType)
            drawCable(ctx, from: drag.anchor.center, to: drag.tipPt, color: color, shakeX: 0)
        }
    }

    private func cableShakeOffset(cableIndex: Int) -> CGFloat {
        guard cableShakeSeed != 0 else { return 0 }
        let hash = cableShakeSeed &* 6_364_136_223_846_793_005 &+ UInt64(cableIndex) &* 1_442_695_040_888_963_407
        return (CGFloat(hash >> 32) / CGFloat(UInt32.max) - 0.5) * 30
    }

    private func drawCable(_ ctx: GraphicsContext, from p1: CGPoint, to p2: CGPoint,
                           color: CableColor, shakeX: CGFloat, highlighted: Bool = false)
    {
        let path = Self.cablePath(from: p1, to: p2, shakeX: shakeX, style: cableStyle)
        // „3D" to gruby kabel z cieniem, „Thin" — sama cienka linia (instrukcja, str. 125).
        if cableStyle.hasShadow {
            ctx.stroke(path, with: .color(.black.opacity(0.25)),
                       style: StrokeStyle(lineWidth: UIMetrics.cableShadowWidth, lineCap: .round))
        }
        let width = cableStyle.hasShadow ? UIMetrics.cableWidth : UIMetrics.cableThinWidth
        // „The highlighted cable(s) turns light blue" (instrukcja, str. 84).
        let stroke = highlighted ? Self.highlightColor : cableColor(color).opacity(0.92)
        ctx.stroke(path, with: .color(stroke),
                   style: StrokeStyle(lineWidth: highlighted ? width * 1.4 : width, lineCap: .round))
    }

    private static let highlightColor = Color(red: 0.55, green: 0.85, blue: 1.0)

    /// Łańcuch podświetlony na jasnoniebiesko: ten, który dochodzi do gniazda pod
    /// kursorem. Instrukcja (str. 84) każe pokazywać go przy przytrzymaniu gniazda;
    /// u nas wystarczy nad nim stanąć, bo przytrzymanie zaczyna już nowy kabel.
    private func highlightedChain() -> [G2Cable] {
        guard !isPreviewMode, hoverScreenPt != .zero else { return [] }
        let point = CGPoint(x: hoverScreenPt.x / zoom, y: hoverScreenPt.y / zoom)
        guard let connector = findConnector(at: point),
              let seed = cablesAt(connector: connector).first else { return [] }
        return patch.cableChain(containing: seed, in: area)
    }

    /// Obrys, poza który kabel nie wychodzi: prostokąt na końcach, poszerzony o zwis
    /// (`sag` w `cablePath`) i o wychylenie „potrząśnięcia" — do pomijania kabli
    /// leżących poza rysowanym kafelkiem.
    static func cableBounds(from p1: CGPoint, to p2: CGPoint, shakeX: CGFloat) -> CGRect {
        let sag = max(6, abs(p2.y - p1.y) * 0.35)
        var box = CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                         width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
        box.size.height += sag
        return box.insetBy(dx: -(abs(shakeX) + UIMetrics.cableShadowWidth),
                           dy: -UIMetrics.cableShadowWidth)
    }

    /// Kształt kabla — jedno miejsce dla rysowania i dla trafiania kursorem, żeby
    /// klik zawsze szedł po tej samej linii, którą widać na ekranie.
    static func cablePath(from p1: CGPoint, to p2: CGPoint, shakeX: CGFloat,
                          style: CableStyle) -> Path
    {
        var path = Path()
        path.move(to: p1)
        guard style.isCurved else {
            path.addLine(to: p2)
            return path
        }
        let dy = abs(p2.y - p1.y)
        let sag = max(6, dy * 0.35)
        let midX = (p1.x + p2.x) / 2 + shakeX
        let cp1 = CGPoint(x: p1.x + (midX - p1.x) * 0.5, y: p1.y + sag)
        let cp2 = CGPoint(x: p2.x + (midX - p2.x) * 0.5, y: p2.y + sag)
        path.addCurve(to: p2, control1: cp1, control2: cp2)
        return path
    }

    // MARK: - BVerhue text labels (dla modułów bez PNG bitmapy)

    // Rysuje statyczne etykiety z plików .txt wyłącznie gdy brak PNG —
    // w modułach z PNG napisy są już wypieczone w bitmapie CBMP.

    /// Najbliższa "kontrolka wiersza" (TextField/ButtonFlat/ButtonText/ButtonRadio/
    /// PartSelector/Graph/Knob) leżąca POD etykietą i zachodząca z nią w poziomie —
    /// używana do dociśnięcia etykiety w górę, gdy standardowa korekta Y (chroniąca
    /// tylko przed nagłówkiem, patrz gałąź `!isBeside, yPt < headerH`) zostawia
    /// za mało miejsca. Gałki uwzględniamy od 2026-08-11: BVerhue czasem zostawia
    /// dokładnie 0pt odstępu (np. OscDual „PW"/„Lvl"/„Sub" — dolna krawędź napisu
    /// i górna krawędź gałki wypadały piksel w piksel). Funkcja tylko PODNOSI
    /// etykietę przy realnej kolizji, nigdy nie obniża — dopisanie gałek nie może
    /// więc zepsuć układów, które już miały wystarczający odstęp.
    /// Górna krawędź trójkąta resetu gałki stojącej pod etykietą (i pokrywającej się
    /// z nią poziomo). Trójkąt siedzi tuż nad tarczą, więc w ciasnych modułach
    /// (OscA/OscPerc/OscString „Cent") opis musi mu ustąpić — inaczej grot dotyka
    /// zejść liter. Szerokość odniesienia = szerokość widżetu gałki (22 Gen1px).
    private func resetTriangleTopBelow(ui: ModuleUIDef, label lbl: BVTextLabel) -> CGFloat? {
        let estWidth = 0.52 * lbl.fontSize * CGFloat(lbl.text.count)
        return ui.knobs
            .filter(\.type.hasResetButton)
            .filter { knob in
                let top = knobResetTriangleTopY(knobTopY: knob.yPt)
                let w = knob.type.btnsSizePt.width
                return top > lbl.yPt + 0.5
                    && max(lbl.xPt, knob.xPt) < min(lbl.xPt + estWidth, knob.xPt + w)
            }
            .map { knobResetTriangleTopY(knobTopY: $0.yPt) }
            .min()
    }

    /// Odległość od GÓRNEJ krawędzi pudełka wiersza (`anchor: .top`) do WIDOCZNEGO
    /// dołu liter — czyli do podstawy liter, a dla napisów z ogonkiem („g/j/p/q/y")
    /// do końca ogonka.
    ///
    /// SwiftUI kotwiczy `Text` po pudełku wiersza (line box), nie po samych literach.
    /// Zmierzone na headless renderze (condensed SF): pudełko ma ≈1.42×fontSize, a
    /// podstawa liter leży ≈0.36×fontSize NAD jego dolną krawędzią (zapas na ogonki
    /// + leading). Napis BEZ ogonka kończy się więc wizualnie sporo nad krawędzią
    /// pudełka i wygląda na odsunięty od elementu pod nim, mimo że liczbowo margines
    /// się zgadza — dokładnie ten efekt sprawiał, że kolejne zmniejszanie marginesu
    /// w Operatorze nie dawało rezultatu. Licząc od WIDOCZNEGO dołu, napisy bez
    /// ogonków siadają bliżej gniazd/kontrolek, a te z ogonkami przestają ich dotykać.
    private func visibleTextBottomOffset(_ text: String, fontSize: CGFloat) -> CGFloat {
        let hasDescender = text.contains { "gjpqy".contains($0) }
        return hasDescender
            ? labelBaselineOffset(fontSize: fontSize) + 0.211 * fontSize
            : labelBaselineOffset(fontSize: fontSize)
    }

    /// Odległość od GÓRNEJ krawędzi pudełka wiersza do PODSTAWY liter (bez ogonków).
    private func labelBaselineOffset(fontSize: CGFloat) -> CGFloat {
        1.059 * fontSize
    }

    /// Odległość od GÓRNEJ krawędzi pudełka wiersza do GÓRY wielkich liter — o tyle
    /// wyżej niż widoczny napis leży jego line-box SwiftUI.
    private func labelCapTopOffset(fontSize: CGFloat) -> CGFloat {
        labelBaselineOffset(fontSize: fontSize) - NSFont.systemFont(ofSize: fontSize).capHeight
    }

    /// Y dla anchora `.top` tak, żeby WIDOCZNE litery stanęły dokładnie pośrodku
    /// wolnej przestrzeni `top ... bottom` — po tyle samo światła nad i pod napisem.
    /// Liczone od góry wielkich liter do podstawy (albo do końca ogonków), nie od
    /// pudełka wiersza, które ma zapas z obu stron.
    private func labelTopCenteredInGap(
        top: CGFloat, bottom: CGFloat, label lbl: BVTextLabel
    ) -> CGFloat {
        let capTop = labelCapTopOffset(fontSize: lbl.fontSize)
        let inkHeight = visibleTextBottomOffset(lbl.text, fontSize: lbl.fontSize) - capTop
        return (top + bottom) / 2 - inkHeight / 2 - capTop
    }

    /// Y dla anchora `.top` tak, żeby WIDOCZNE litery napisu wypadły środkiem
    /// dokładnie na wskazanej osi (np. na środku gniazda obok).
    private func labelTopCenteredOn(_ centerY: CGFloat, label lbl: BVTextLabel) -> CGFloat {
        labelTopCenteredInGap(top: centerY, bottom: centerY, label: lbl)
    }

    /// Realna szerokość napisu w kroju, którym rysujemy etykiety (system condensed).
    /// `GraphicsContext.resolve(…).measure(…)` zaokrągla wynik W GÓRĘ do pełnych punktów
    /// („Rate" 9.28 → 10.0), a przy czcionce ~5pt to za gruby błąd, żeby na nim opierać
    /// decyzję „czy napis się jeszcze mieści".
    private func labelWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular, width: .condensed)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Sufit pozycji Y etykiety (anchor `.top`) tak, by WIDOCZNY dół jej liter
    /// zostawił jednakowy odstęp nad elementem zaczynającym się na `elementTop`.
    private func labelTopClearing(above elementTop: CGFloat, label lbl: BVTextLabel,
                                  reserveDescender: Bool = false) -> CGFloat
    {
        // ≈0.7pt przy typowym foncie etykiet 4.92pt — ten sam realny odstęp,
        // niezależnie od tego, czy napis ma ogonek.
        let gap = 0.145 * lbl.fontSize
        // Nad PRZYCISKIEM rezerwujemy ogonek nawet napisom, które go nie mają.
        // Ramka z zaokrąglonym narożnikiem ciśnie tekst bardziej niż gniazdo, a bez
        // tego napisy w jednym rzędzie rozjeżdżały się o ~1 pt: „Shape" (z ogonkiem)
        // szło w górę, „Glide" i „Echo" zostawały na ramce swojego Off/On.
        let bottom = reserveDescender
            ? labelBaselineOffset(fontSize: lbl.fontSize) + 0.211 * lbl.fontSize
            : visibleTextBottomOffset(lbl.text, fontSize: lbl.fontSize)
        return elementTop - gap - bottom
    }

    /// Sufit pozycji Y etykiety (anchor `.top`) tak, by jej widoczny dół zostawił
    /// odstęp nad trójkątem resetu. Bez trójkąta pod spodem zwraca `y` bez zmian.
    private func labelTopClearingResetTriangle(
        _ y: CGFloat, ui: ModuleUIDef, label lbl: BVTextLabel
    ) -> CGFloat {
        guard let top = resetTriangleTopBelow(ui: ui, label: lbl) else { return y }
        return min(y, labelTopClearing(above: top, label: lbl))
    }

    /// Górna krawędź kontrolki stojącej bezpośrednio pod etykietą oraz informacja,
    /// czy jest nią PRZYCISK — ten potrzebuje większego zapasu (patrz `labelTopClearing`).
    private func nearestControlBelow(ui: ModuleUIDef,
                                     label lbl: BVTextLabel) -> (y: CGFloat, isButton: Bool)?
    {
        let estWidth = 0.52 * lbl.fontSize * CGFloat(lbl.text.count)
        func overlaps(_ x: CGFloat, _ w: CGFloat) -> Bool {
            max(lbl.xPt, x) < min(lbl.xPt + estWidth, x + w)
        }
        var best: (y: CGFloat, isButton: Bool)?
        func consider(_ y: CGFloat, _ x: CGFloat, _ w: CGFloat, isButton: Bool = false) {
            guard y > lbl.yPt + 0.5, overlaps(x, w) else { return }
            if best == nil || y < best!.y { best = (y, isButton) }
        }
        for tf in ui.textFields {
            consider(tf.yPt, tf.xPt, tf.widthPt)
        }
        for b in ui.buttonsFlat {
            consider(b.yPt, b.xPt, b.widthPt, isButton: true)
        }
        for b in ui.buttonsText {
            consider(b.yPt, b.xPt, b.widthPt, isButton: true)
        }
        for b in ui.buttonsRadio {
            consider(b.yPt, b.xPt, CGFloat(b.buttonCount) * b.buttonWidthPt)
        }
        for g in ui.graphs {
            consider(g.yPt, g.xPt, g.widthPt)
        }
        for p in ui.partSelectors {
            consider(p.yPt, p.xPt, p.widthPt)
        }
        for k in ui.knobs where k.type.isRotary {
            consider(k.yPt, k.xPt, k.type.centerOffsetPt.x * 2)
        }
        return best
    }

    /// Gałka bezpośrednio pod etykietą, gdy surowy XPos etykiety faktycznie leży
    /// nad jej szerokością (nie tylko "gdzieś blisko" — próg 2pt, znacznie ściślejszy
    /// niż `aboveConnMatch`, żeby nie łapać napisów opisujących coś innego obok).
    /// Fallback dla modułów bez dedykowanej obsługi centrowania (np. OscPM „Cent").
    private func aboveKnobMatch(_ l: BVTextLabel, ui: ModuleUIDef) -> BVKnob? {
        ui.knobs.first { k in
            // Próg 2 pt (nie 0.5) odróżnia napis STOJĄCY NAD gałką (wyraźna przerwa
            // pionowa, np. OscA/OscPM "Cent": 4.4 pt) od napisu OBOK niej w tym samym
            // wierszu (np. MetNoise "Freq"/"Color": 0.5 pt, XPos zaczyna się dokładnie
            // na prawej krawędzi gałki — to poprawna pozycja z BVerhue, nie błąd do
            // centrowania). Zbyt mały próg centrował "Freq"/"Color" na gałce i wciągał
            // tekst w jej obrys, mimo że surowy XPos już był poprawny.
            guard k.type.isRotary, k.yPt > l.yPt + 2.0 else { return false }
            let w = k.type.centerOffsetPt.x * 2
            if l.xPt >= k.xPt - 2.0, l.xPt <= k.xPt + w + 2.0 { return true }
            // Napis szerszy od gałki bywa zapisany z XPos na lewo od jej obrysu
            // (Mux8-1X „X-Fade": 183 wobec gałki na 190) — o przynależności decyduje
            // wtedy jego ŚRODEK, a nie początek.
            let centerX = l.xPt + 0.52 * l.fontSize * CGFloat(l.text.count) / 2
            return centerX >= k.xPt && centerX <= k.xPt + w
        }
    }

    /// Po której stronie własnego przycisku Off/On stoi etykieta „KBT".
    enum KBTPlacement {
        /// Wyśrodkowana NAD przyciskiem (tak zapisuje ją BVerhue w filtrach i LFO).
        /// `topY` to gotowa pozycja Y dla anchora `.top` — liczona razem z decyzją,
        /// bo od niej zależy, czy napis w ogóle mieści się nad przyciskiem.
        case above(topY: CGFloat)
        /// Dosunięta do LEWEJ krawędzi przycisku, w jego wierszu (oscylatory) —
        /// tam nad przyciskiem stoi ekran LCD.
        case leftOf
    }

    /// Przycisk keyboard-trackingu (Off/On albo Off/25%…/100%), przy którym ma stać
    /// etykieta „KBT". CodeRef bywa różny w każdym module (LfoA/LfoShpA: 2, LfoB: 3,
    /// Operator: 0), więc szukamy geometrycznie: przycisk leżący PONIŻEJ etykiety
    /// i najbliższy jej w poziomie.
    ///
    /// `placement` mówi, po której stronie przycisku napis ma stanąć — patrz
    /// `KBTPlacement`. `nil` = w module nie ma na niego miejsca nad przyciskiem,
    /// więc zostaje na surowej pozycji z BVerhue.
    private func kbtOwnButton(ui: ModuleUIDef,
                              label lbl: BVTextLabel) -> (button: BVButtonFlat, placement: KBTPlacement)?
    {
        // Przycisk keyboard-trackingu poznajemy po opcjach: pierwsza to zawsze „Off"
        // („Off,On" w oscylatorach, „Off,25%,50%,75%,100%" w LFO i filtrach). CodeRef
        // jest w każdym module inny (LfoA/LfoShpA: 2, LfoB: 3, Operator: 0), a szukanie
        // „najbliższego przycisku poniżej" myliło się tam, gdzie przycisk KBT stoi w tym
        // samym wierszu co etykieta (OscShpA/OscB) — wybierało wtedy przycisk FM Lin.
        let labelCenterX = lbl.xPt + 0.52 * lbl.fontSize * CGFloat(lbl.text.count) / 2
        func score(_ b: BVButtonFlat) -> CGFloat {
            abs(b.xPt + b.widthPt / 2 - labelCenterX) + abs(b.yPt - lbl.yPt)
        }
        guard let button = ui.buttonsFlat
            .filter({ $0.options.first == "Off" })
            .min(by: { score($0) < score($1) })
        else { return nil }

        // BVerhue stawia „KBT" na dwa sposoby i oba trzeba uszanować: NAD przyciskiem
        // (YPos etykiety ~5pt wyżej — filtry, LfoB/LfoShpA, OscDual, LevScaler) albo
        // w JEGO WIERSZU po lewej stronie (YPos równy lub niższy — oscylatory, LfoA,
        // FltHP/FltLP, Resonator). W tej drugiej grupie nad przyciskiem stoi ekran LCD
        // i wypychanie napisu w górę chowało go pod ekranem (OscA/OscC/OscMaster…).
        guard button.yPt > lbl.yPt + 1.0 else { return (button, .leftOf) }

        // Wariant „nad": napis musi się zmieścić w module i nie wejść pod pasek
        // z nazwą modułu. Gdy pełny prześwit nad przyciskiem wypycha litery w pasek
        // (LfoShpA, FltPhase, Operator — przycisk stoi wysoko), napis siada tuż POD
        // paskiem zamiast wracać na surową pozycję BVerhue, gdzie stał w lewo od
        // własnego przycisku. Dociskamy tylko wtedy, gdy nadal mieści się nad
        // przyciskiem — inaczej zostaje pełny prześwit (RandomB).
        let clearance = labelTopClearing(above: button.yPt, label: lbl)
        let underHeader = PatchLayout.headerH - labelCapTopOffset(fontSize: lbl.fontSize)
        let fitsUnderHeader = underHeader + labelBaselineOffset(fontSize: lbl.fontSize) <= button.yPt
        let top = fitsUnderHeader ? max(clearance, underHeader) : clearance
        guard top >= 1.5 else { return nil }
        return (button, .above(topY: top))
    }

    /// Ekran (TextField) leżący BEZPOŚREDNIO POD etykietą, którą opisuje
    /// (OscShpA/OscB „Shape", Compressor, Glide „Time"…). Warunki są ciasne, żeby nie
    /// łapać nagłówków grup ani napisów opisujących coś innego obok:
    /// – ekran musi być w NASTĘPNYM wierszu (4…8 pt niżej), nie w tym samym,
    /// – napis w czcionce ORYGINAŁU musi się w całości MIEŚCIĆ w szerokości ekranu
    ///   (samo „zachodzenie" łapało np. Eq3band „Mid" czy Glide „Glide" — nagłówki
    ///   grup stojące nad kilkoma ekranami naraz).
    private func fieldBelowLabel(ui: ModuleUIDef, label lbl: BVTextLabel) -> BVTextField? {
        // Szerokosc mierzona NASZA czcionka (do 2026-08-20: szacunek szerszej czcionki
        // oryginalu). Kryterium brzmi „napis miesci sie w ekranie" — a miesci sie ten,
        // ktory faktycznie rysujemy. Dziesiec dwuczlonowych opisow stojacych dokladnie
        // nad swoim ekranem (PitchTrack/NoiseGate „Threshold", Compressor „Release"
        // i „Ref Lvl", FreqShift, PShift, Scratch, SyncOsc, EnvFollow, PulseOsc)
        // przekraczalo limit o 0.4-4.9pt tylko w tym szacunku i zostawalo bez
        // wysrodkowania. Pelna tabela pomiarow → Docs/ui/bverhue-behavior.
        let width = labelWidth(lbl.text, fontSize: lbl.fontSize)
        return ui.textFields.first {
            let gap = $0.yPt - lbl.yPt
            return gap >= 4.0 && gap <= 8.0
                && lbl.xPt >= $0.xPt - 2.0
                && lbl.xPt + width <= $0.xPt + $0.widthPt + 2.0
        }
    }

    /// Ekranik-selektor (PartSelector) leżący BEZPOŚREDNIO POD etykietą, którą opisuje
    /// (EnvADDSR „Shape"). Odpowiednik `fieldBelowLabel` dla ekranów z ikoną zamiast
    /// tekstu. Kryterium poziome jest luźniejsze niż tam — nie „cały napis mieści się
    /// w ekranie", tylko „jego ŚRODEK leży w obrębie ekranu": ekraniki ikonowe są
    /// węższe od pól tekstowych i napis bywa od nich szerszy („Shape" nad polem 20
    /// Gen1px), a i tak jednoznacznie do nich należy.
    private func selectorBelowLabel(ui: ModuleUIDef, label lbl: BVTextLabel) -> BVPartSelector? {
        // 0.58 × rozmiar fontu ≈ szerokość znaku w czcionce oryginału.
        let originalCenter = lbl.xPt + 0.58 * lbl.fontSize * CGFloat(lbl.text.count) / 2
        return ui.partSelectors.first {
            let gap = $0.yPt - lbl.yPt
            // OutputType i Normal/Reset nie są ekranami, tylko kwadratowymi przyciskami
            // przy gnieździe (patrz `partSelectorRect`) — ich prostokąt tu nie obowiązuje.
            return PatchCanvasView.shortLabelButtonTitle(infoFunc: $0.infoFunc, value: 0) == nil
                && gap >= 3.0 && gap <= 9.0
                && originalCenter >= $0.xPt && originalCenter <= $0.xPt + $0.widthPt
        }
    }

    /// Górna krawędź najwyżej położonego elementu leżącego pod prostokątem tekstu —
    /// razem z GNIAZDAMI, których `nearestControlBelow` nie bierze pod uwagę.
    /// `knobRowY` — wysokosc rzedu galek, w ktorym stoi opisywana galka. Galki tego
    /// rzedu sa wtedy pomijane: stoja OBOK etykiety, w jednej z nia linii, a nie pod
    /// nia. Traktowanie ich jak „elementu pod spodem" podbijalo opis o ~4.7pt — tak
    /// wjezdzal pod ekrany („A"/„D"/„S"/„R" w obwiedniach, „1…4" w Mix4-1B) i tak
    /// powstawal odstajacy „D2" w EnvADDSR (jego prostokat nachodzil na sasiednia
    /// galke „L1" o 0.11pt).
    private func topOfElementBelow(ui: ModuleUIDef, xRange: ClosedRange<CGFloat>,
                                   below y: CGFloat,
                                   knobRowY: CGFloat? = nil) -> CGFloat?
    {
        var best: CGFloat?
        func consider(_ top: CGFloat, _ x: CGFloat, _ w: CGFloat) {
            guard top > y + 0.5, max(xRange.lowerBound, x) < min(xRange.upperBound, x + w)
            else { return }
            if best == nil || top < best! { best = top }
        }
        let connSide: CGFloat = 11.0 * (140.0 / 256.0)
        for c in ui.inputs + ui.outputs {
            consider(c.yPt, c.xPt, connSide)
        }
        for f in ui.textFields {
            consider(f.yPt, f.xPt, f.widthPt)
        }
        for b in ui.buttonsFlat {
            consider(b.yPt, b.xPt, b.widthPt)
        }
        for b in ui.buttonsText {
            consider(b.yPt, b.xPt, b.widthPt)
        }
        for k in ui.knobs where k.type.isRotary {
            if let knobRowY, abs(k.yPt - knobRowY) < 2.5 { continue }
            consider(k.yPt, k.xPt, k.type.centerOffsetPt.x * 2)
        }
        return best
    }

    /// Ekran (TextField) stojący W TYM SAMYM WIERSZU tuż PO PRAWEJ stronie etykiety.
    /// BVerhue zapisuje XPos etykiety tak, żeby jej PRAWA krawędź w szerokiej czcionce
    /// oryginału kończyła się dokładnie przy ekranie (ClkGen „Sync every" → ekran liczby
    /// taktów, LfoB „Phase" → ekran stopni). Nasza czcionka jest węższa, więc trzymany
    /// surowy XPos zostawia dużą dziurę — zamiast tego dosuwamy napis do ekranu.
    private func fieldRightOfLabel(ui: ModuleUIDef, label lbl: BVTextLabel) -> BVTextField? {
        // 0.58 × rozmiar fontu ≈ szerokość znaku w czcionce oryginału (9 Gen1px → ~5.2px).
        let originalRightEdge = lbl.xPt + 0.58 * lbl.fontSize * CGFloat(lbl.text.count)
        return ui.textFields.first {
            abs($0.yPt - lbl.yPt) < 2.5 && abs($0.xPt - originalRightEdge) < 1.5
        }
    }

    /// Gałka opisywana przez etykietę stojącą bezpośrednio PO JEJ LEWEJ w tym samym
    /// wierszu (EnvADSR „A/D/S/R", Eq3band „Gain/Freq/Lev", ModADSR, EqPeak, DelayB
    /// „HP/LP"…). Tak jak przy ekranach: BVerhue tak dobiera `XPos`, żeby PRAWA
    /// krawędź napisu w szerokiej czcionce oryginału kończyła się tuż przy gałce —
    /// przy naszej, węższej, zostaje wyraźna dziura i napis wygląda na zgubiony.
    private func knobRightOfLabel(ui: ModuleUIDef, label lbl: BVTextLabel) -> BVKnob? {
        // 0.58 × rozmiar fontu ≈ szerokość znaku w czcionce oryginału.
        let originalRightEdge = lbl.xPt + 0.58 * lbl.fontSize * CGFloat(lbl.text.count)
        // Próg 4.0 pt (do 2026-08-20: 3.0): jednoznakowe opisy w EnvAHD/EnvADR/AR-Env
        // („A", „D", „H") mają w źródle 3.7 pt luzu i wypadały tuż POZA regułą — zostawały
        // na surowym XPos, wyraźnie oderwane od swoich gałek, podczas gdy sąsiedzi w tym
        // samym rzędzie byli już dosunięci. Przeskan wszystkich 168 modułów: przy 4.0 pt
        // dochodzi 18 dopasowań i wszystkie są opisami gałki w tym samym wierszu.
        // NAJBLIŻSZA, nie pierwsza z listy — luźniejszy próg mógłby inaczej złapać
        // dalszą gałkę tylko dlatego, że stoi wcześniej w pliku.
        return ui.knobs
            .filter {
                $0.type.isRotary
                    && abs($0.yPt - lbl.yPt) < 2.5
                    && abs($0.xPt - originalRightEdge) < 4.0
            }
            .min { abs($0.xPt - originalRightEdge) < abs($1.xPt - originalRightEdge) }
    }

    /// Prawa krawędź opisu stojącego przed gałką — 0.5pt od WIDOCZNEJ tarczy, nie od
    /// lewej krawędzi widżetu (ta leży jeszcze ~0.55pt dalej, bo widżet jest szerszy
    /// niż tarcza). Poprzednie `knob.xPt - 1.0` dawało 1.55pt prześwitu, a szczelina
    /// między gałkami rzędu to ~8.2pt: 5-punktowy opis wypadał niemal dokładnie w jej
    /// środku i nie było widać, do której gałki należy (EnvADDSR „L2"). Napis rośnie
    /// w lewo, więc dosunięcie ODDALA go od gałki sąsiedniej — nie może jej dotknąć
    /// bardziej niż dotąd.
    private func labelRightEdgeAtKnob(_ knob: BVKnob) -> CGFloat {
        knob.xPt + knob.type.centerOffsetPt.x - knob.type.radiusPt - 0.5
    }

    /// Najwyzej, jak opis moze usiasc, zeby nie dotykac gornej ramki modulu.
    /// Wielkie litery zaczynaja sie jeszcze ~1.8pt nizej, wiec to realny margines.
    /// 0.3pt (do 2026-08-20: 1.2pt) — ta sama wartość, co "podłoga przy kolizji" już
    /// ustalona w gałęzi "etykiety wewnątrz nagłówka" (patrz linia z `hasCollisionBelow
    /// ? 0.3 : 0.7`). 1.2pt było arbitralnym wyborem, który przy okazji ZWIĘKSZAŁ Y
    /// (przesuwał w DÓŁ, bliżej pola poniżej) dla etykiet, których naturalna pozycja
    /// była dodatnia, ale mniejsza niż 1.2 — PitchTrack "Threshold" (naturalne 0.64pt)
    /// dostawało przez to ciaśniejszy odstęp niż zaprojektowany (0.15pt zamiast 0.71pt),
    /// mimo że w ogóle nie potrzebowało podłogi. 0.3pt koliduje tylko z etykietami,
    /// które NAPRAWDĘ wychodziłyby poza moduł (wartość ujemna) — i wtedy zabiera im
    /// najmniej możliwe z zaprojektowanego prześwitu nad polem poniżej.
    private static let labelTopFloor: CGFloat = 0.3

    /// Wysokosc opisu stojacego przed galka.
    ///
    /// Rzad wychodzi rowny sam z siebie: wszystkie galki rzedu maja ten sam `yPt`,
    /// a kolizji szukamy z pominieciem galek TEGO rzedu (`knobRowY`). Wczesniejsza
    /// proba wyrownania przez „najnizszy sufit calego rzedu" byla bledna: roznosila
    /// kolizje jednej etykiety na wszystkie pozostale i wpychala rzad pod ekrany.
    ///
    /// W ciasnych modulach napis nie miesci sie miedzy gorna ramka a ekranem pod
    /// spodem — dotad uciekal wtedy w gore, az POZA modul (Clip „Clip Lev", KeyQuant
    /// i NoteQuant „Range", PCSend „Program", RndClkA „Step" wychodzily na -0.4pt;
    /// PitchTrack „Threshold" wjezdzal na nazwe modulu). Zamiast tego zatrzymujemy go
    /// na podlodze `labelTopFloor` — przeswit nad ekranem robi sie ciasny, ale napis
    /// zostaje w calosci w module i zachowuje ten sam rozmiar czcionki co reszta.
    private func knobRowLabelTopY(ui: ModuleUIDef, label lbl: BVTextLabel, knob: BVKnob) -> CGFloat {
        let base = knob.yPt - lbl.fontSize * 0.25
        let rightX = labelRightEdgeAtKnob(knob)
        let leftX = rightX - labelWidth(lbl.text, fontSize: lbl.fontSize)
        guard let below = topOfElementBelow(ui: ui, xRange: leftX ... rightX,
                                            below: base, knobRowY: knob.yPt)
        else { return base }
        return clampedLabelTop(min(base, labelTopClearing(above: below, label: lbl)))
    }

    /// Podloga dla kazdego opisu dosunietego w gore przez `labelTopClearing`. Czcionka
    /// zostaje bez zmian — wszystkie etykiety maja jeden rozmiar; napis po prostu
    /// zatrzymuje sie przy ramce zamiast z niej wyjezdzac.
    private func clampedLabelTop(_ y: CGFloat) -> CGFloat {
        max(Self.labelTopFloor, y)
    }

    /// Pionowy środek WIELKICH LITER etykiety — w miejscu, w którym naprawdę ją
    /// rysujemy, nie na jej surowym `yPt`. Potrzebne kresce łączącej dwa opisy:
    /// ma trafiać w ich oś, a nie w górną krawędź liter.
    private func labelCapCenterY(ui: ModuleUIDef, label lbl: BVTextLabel) -> CGFloat {
        let top = fieldBelowLabel(ui: ui, label: lbl)
            .map { labelTopClearing(above: $0.yPt, label: lbl) } ?? lbl.yPt
        let capHeight = NSFont.systemFont(ofSize: lbl.fontSize).capHeight
        return top + labelCapTopOffset(fontSize: lbl.fontSize) + capHeight / 2
    }

    /// Etykieta stojąca bezpośrednio PRZED poziomą kreską, która po drugiej stronie
    /// też kończy się przy etykiecie (EnvMulti „T1—L1", „T2—L2"…). Skan wszystkich
    /// 168 modułów: taki układ ma tylko EnvMulti, więc reguła nie rusza kresek
    /// łączących gniazdo z gałką ani podkreśleń grup.
    private func labelLeftOfLine(_ line: BVLine, ui: ModuleUIDef) -> BVTextLabel? {
        guard line.isHorizontal else { return nil }
        func inRow(_ l: BVTextLabel) -> Bool {
            abs(l.yPt - line.yPt) < 4.0
        }
        func gapAfter(_ l: BVTextLabel) -> CGFloat {
            line.xPt - (l.xPt + labelWidth(l.text, fontSize: l.fontSize))
        }
        let left = ui.textLabels.first { inRow($0) && (-1.0 ... 4.0).contains(gapAfter($0)) }
        let hasRight = ui.textLabels.contains {
            inRow($0) && (-1.0 ... 4.0).contains($0.xPt - (line.xPt + line.lengthPt))
        }
        return hasRight ? left : nil
    }

    /// Strzałka resetu/wyzwalania (Symbol „Trig 1") stojąca bezpośrednio PRZED etykietą
    /// w tym samym wierszu — napis ma się do niej dosunąć zamiast trzymać surowy XPos.
    private func resetArrowLeftOf(ui: ModuleUIDef, label lbl: BVTextLabel) -> BVSymbol? {
        ui.symbols.first {
            $0.type == "Trig 1"
                && abs($0.yPt - lbl.yPt) < 3.0
                && lbl.xPt > $0.xPt
                && lbl.xPt - ($0.xPt + $0.widthPt) < 3.0
        }
    }

    /// The exact title row used by the Operator's Coarse and Fine controls.
    private func operatorTopLabelRowY(ui: ModuleUIDef, rect: CGRect) -> CGFloat? {
        guard let label = ui.textLabels.first(where: { $0.text == "Coarse" }),
              let knob = ui.knobs.first(where: { $0.codeRef == 3 })
        else { return nil }

        let textBottom = label.yPt + label.fontSize
        let shiftUp: CGFloat = textBottom > PatchLayout.headerH - 1.0 ? 1.0 : 0.0
        let sourceY = max(1.5, label.yPt - shiftUp)
        let clearedY = labelTopClearing(above: knob.yPt, label: label)
        return rect.minY + min(sourceY, clearedY)
    }

    /// The shared title row used by BrPoint, L-Depth and R-Depth.
    private func operatorBottomLabelRowY(
        module: G2Module,
        ui: ModuleUIDef,
        rect: CGRect
    ) -> CGFloat? {
        guard let label = ui.textLabels.first(where: { $0.text == "L-Depth" }),
              let field = ui.textFields.first(where: { $0.id == 67 })
        else { return nil }
        let frame = operatorTextFieldFrame(module: module, field: field)
        return rect.minY + labelTopClearing(above: frame.y, label: label)
    }

    /// Horizontal bounds and top edge of an Operator LCD combined with its vertical +/- pair.
    private func operatorIncDecGroupLayout(
        module: G2Module,
        field: BVTextField,
        button: BVButtonIncDec
    ) -> (centerX: CGFloat, rightX: CGFloat, topY: CGFloat) {
        let frame = operatorTextFieldFrame(module: module, field: field)
        let buttonOrigin = operatorIncDecOrigin(module: module, button: button)
        let groupLeft = min(frame.x, buttonOrigin.x)
        let groupRight = max(
            frame.x + frame.width,
            buttonOrigin.x + UIMetrics.incDecHeight
        )
        return ((groupLeft + groupRight) / 2, groupRight, min(frame.y, buttonOrigin.y))
    }

    func drawBVTextLabels(_ ctx: GraphicsContext, module: G2Module, rect: CGRect) {
        guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { return }
        guard !ui.textLabels.isEmpty else { return }

        let labelColor = UIColor.textLabel
        let allConnectors = ui.inputs + ui.outputs

        // Nazwy grup kontrolek z oryginalnego edytora Clavii. Ani pliki paneli, ani
        // pliki Gen1 BVerhue ich nie zawierają (są wypalone w bitmapach CBMP), więc
        // rysujemy je wektorowo — inaczej moduł traci podział na sekcje.
        // `lineYPx` bywa POD napisem (DrumSynth) albo NAD nim (Operator) — kod rysuje
        // linię po prostu na podanej wysokości, kolejność nie ma znaczenia.
        let groupLabels: [(text: String, xPx: CGFloat, yPx: CGFloat, lineYPx: CGFloat, lineEndPx: CGFloat)] = switch module.typeID {
        case 58:
            // DrumSynth. lineYPx = yPx (góra napisu) + 9 Gen1px — przy foncie 9×scale≈4.92pt
            // (dopasowanym do opisów gałek, patrz niżej) sam napis zajmuje ~7.3 Gen1px
            // wysokości; +9 daje ~2px marginesu pod nim, żeby linia nie dotykała liter
            // (2026-08-12, druga korekta: poprzednie +8 nadal stykało się z podstawą liter).
            // Budżet do wiersza PONIŻEJ (Freq/Res/Swp/Dcy, Amt/Dcy, TextField ekranów) jest
            // ciasny (12-13 Gen1px), więc zostaje z tego tylko 3-4px — mniej niż poprzednie 5,
            // ale brak dotykania napisu nad linią ma pierwszeństwo.
            [
                ("MasterOsc", 24, 14, 25, 115),
                ("NoiseFilter", 123, 26, 37, 228),
                ("SlaveOsc", 24, 67, 78, 115),
                ("Bend", 125, 72, 83, 174),
            ]
        case 180:
            // Operator: dwie sekcje oddzielone poziomą kreską NAD nazwą, biegnącą
            // przez całą szerokość modułu — „Envelope" nad wykresem obwiedni i
            // „KBLevScale" nad wykresem skalowania. Odczytane ze zrzutu oryginału.
            // xPx:42 (nie 35) — para +/- AMod (CodeRef:16) stoi na XPos:29-40,
            // węższy start nachodził na przycisk i chował literę „K" za nim.
            // yPx tuż pod linią (0.5 Gen1px, nie 2) — napis ma stać blisko niej.
            [
                ("Envelope", 42, 40.5, 40, 250),
                ("KBLevScale", 42, 123.5, 123, 250),
            ]
        default:
            []
        }
        if !groupLabels.isEmpty {
            for group in groupLabels {
                let scale = PatchLayout.bverhuePixelScale
                let lineY = rect.minY + group.lineYPx * scale
                var line = Path()
                line.move(to: CGPoint(x: rect.minX + group.xPx * scale, y: lineY))
                line.addLine(to: CGPoint(x: rect.minX + group.lineEndPx * scale, y: lineY))
                ctx.stroke(line, with: .color(UIColor.knobOuter), lineWidth: 0.5)
                ctx.draw(
                    Text(group.text)
                        // Ta sama wielkość co prawdziwe opisy gałek tego modułu w BVerhue
                        // (Text "Freq"/"Res"/"Dcy"… FontSize:9 w DrumSynth.txt) — parser
                        // (BVerhueParser.makeTextLabel) skaluje surowe FontSize przez
                        // bverhuePixelScale przy zapisie do BVTextLabel.fontSize, więc
                        // realny rozmiar to 9×scale ≈ 4.92pt, nie surowe 9 (próba z 9pt
                        // nachodziła katastrofalnie na resztę modułu) ani osobna wartość 4.2.
                        .font(.system(size: 9.0 * PatchLayout.bverhuePixelScale, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(
                        x: rect.minX + group.xPx * PatchLayout.bverhuePixelScale,
                        y: rect.minY + group.yPx * PatchLayout.bverhuePixelScale
                    ),
                    anchor: .topLeading
                )
            }
        }

        // Indeksowana lista: (connector, index w swoim tablicy, isOutput) — do connectorCenterForDraw
        let indexedConns: [(conn: BVConnector, idx: Int, isOutput: Bool)] =
            ui.outputs.enumerated().map { (conn: $0.element, idx: $0.offset, isOutput: true) }
                + ui.inputs.enumerated().map { (conn: $0.element, idx: $0.offset, isOutput: false) }

        // Etykiety w dolnych 2 pt nagłówka (YPos ≈ 12-14) nakładają się na nazwę modułu → zepchnij poniżej
        let headerPushThreshold = PatchLayout.headerH - 2.0

        /// Etykieta powyżej gniazda (yPt < conn.yPt, podobne X ≤ 5 pt) → centrujemy poziomo
        /// na gniazdo. Wydzielone jako funkcja (nie tylko inline dla `lbl`), bo używane też
        /// niżej do sprawdzenia, czy INNA etykieta w tym samym wierszu korzysta z tej gałęzi
        /// (i jej przesunięcia -1pt) — potrzebne do spójnego wyrównania "skrajnego prawego
        /// gniazda" (patrz nearbyRightSocket niżej).
        func aboveConnMatch(_ l: BVTextLabel) -> (conn: BVConnector, idx: Int, isOutput: Bool)? {
            indexedConns.first(where: {
                $0.conn.yPt > l.yPt + 1.5 && abs($0.conn.xPt - l.xPt) < 5.0
            })
        }

        /// Gniazdo tuż przy prawej krawędzi modułu, którego BVerhue XPos leży za daleko od
        /// etykiety, by trafić w aboveConnMatch (próg 5pt) — ale nadal opisuje realne gniazdo
        /// poniżej (np. PitchTrack/ZeroCnt/OscMaster "Pitch", OscPerc "Punch", BinCounter "128",
        /// Status "Voice No." — wszystkie mają Output tuż przy XPos:240/256). Rysowanie na
        /// surowym XPos etykiety wypycha wtedy tekst POZA moduł, bo nie ma miejsca żeby go
        /// wycentrować. Zwraca gniazdo tylko gdy surowe pozycjonowanie faktycznie by przelało.
        func nearbyRightSocket(_ l: BVTextLabel) -> BVConnector? {
            let estWidth = 0.52 * l.fontSize * CGFloat(l.text.count)
            guard rect.minX + l.xPt + estWidth > rect.maxX - 1.5 else { return nil }
            return indexedConns.first(where: {
                $0.conn.yPt > l.yPt + 1.5 && $0.conn.xPt > l.xPt - 2.0 && $0.conn.xPt - l.xPt < 10.0
            })?.conn
        }

        /// Liczba stojąca przed gniazdem w tym samym wierszu może nachodzić na jego obrys,
        /// bo BVerhue zapisuje pozycję węższego fontu Delphi. Korygujemy wyłącznie realne
        /// kolizje, pozostawiając wszystkie etykiety z prawidłowym odstępem bez zmian.
        func numericLabelOverlappingRightSocket(_ l: BVTextLabel) -> BVConnector? {
            guard Int(l.text) != nil else { return nil }
            let estimatedRightEdge = l.xPt + 0.52 * l.fontSize * CGFloat(l.text.count)
            return allConnectors
                .filter {
                    $0.xPt >= l.xPt && abs($0.yPt - l.yPt) <= 3.0
                        && estimatedRightEdge > $0.xPt - 1.0
                }
                .min { $0.xPt < $1.xPt }
        }

        // 8Counter/BinCounter: etykiety wag bitowych ("1".."128") w kolejności X, do
        // sparowania z diodami tym samym indeksem (patrz niżej — dopasowanie "najbliższa
        // dioda" zawodzi dla "128", bo odstęp etykieta→własna dioda rośnie z szerokością
        // tekstu i "128" wypada bliżej cudzej diody "64" niż swojej). 8Counter.txt ma
        // dla każdej wagi bitowej DWA identyczne <#Text> (zdublowane w źródle BVerhue,
        // prawdopodobnie kopiuj-wklej przy tworzeniu pliku) — bez odfiltrowania duplikatów
        // sortowanie po X przeplata obie kopie i psuje indeksację (8 diod dostawało
        // pierwsze 8 z 16 posortowanych etykiet = "1,1,2,2,3,3,4,4"). Dedup po treści
        // (pierwsze wystąpienie w kolejności X) usuwa problem niezależnie od tego, która
        // kopia zostaje.
        var seenWeightTexts = Set<String>()
        let numericLabelsSorted = ui.textLabels
            .filter { Int($0.text) != nil }
            .sorted { $0.xPt < $1.xPt }
            .filter { seenWeightTexts.insert($0.text).inserted }
        let ledsSorted = ui.leds.sorted { $0.xPt < $1.xPt }

        let switchModuleIDs: Set = [
            15, 17, 21, 36, 53, 60, 76, 78, 79, 85, 88, 90, 100, 105, 124, 139, 186, 187,
        ]
        let muxModuleIDs: Set = [21, 60, 124]

        // Mux8-1/Mux8-1X oraz Mux1-8: źródło ma numery bardzo blisko diod, a Mux1-8
        // dodatkowo zawiera dwa kompletne zestawy 1...8. Każdej zielonej diodzie
        // przypisujemy dokładnie jedną etykietę i później rysujemy ją ze stałym
        // prześwitem po lewej, na osi diody.
        let muxNumericTargets: [Int: Int] = {
            guard muxModuleIDs.contains(module.typeID) else { return [:] }
            let greenLEDs = ui.leds.filter { $0.type == .green }.sorted { $0.xPt < $1.xPt }
            var result: [Int: Int] = [:]
            for (index, led) in greenLEDs.enumerated() {
                let expected = String(index + 1)
                let candidates = ui.textLabels.filter { $0.text == expected }
                guard let label = candidates.min(by: { lhs, rhs in
                    let lhsPenalty: CGFloat = lhs.xPt <= led.xPt ? 0 : 1000
                    let rhsPenalty: CGFloat = rhs.xPt <= led.xPt ? 0 : 1000
                    return lhsPenalty + abs(led.xPt - lhs.xPt)
                        < rhsPenalty + abs(led.xPt - rhs.xPt)
                }) else { continue }
                result[label.id] = led.id
            }
            return result
        }()

        // W kilku plikach Switch (m.in. Mux1-8 i oba ValSw) ten sam napis Ctrl
        // występuje dwa razy praktycznie w tym samym punkcie. Zachowujemy pierwszą
        // kopię, a kolejne bliskie duplikaty pomijamy.
        let duplicateSwitchLabelIDs: Set<Int> = {
            guard switchModuleIDs.contains(module.typeID) else { return [] }
            var skipped = Set<Int>()
            for (index, label) in ui.textLabels.enumerated() {
                guard ui.textLabels[..<index].contains(where: {
                    $0.text == label.text
                        && abs($0.xPt - label.xPt) <= 1.5
                        && abs($0.yPt - label.yPt) <= 1.5
                }) else { continue }
                skipped.insert(label.id)
            }
            return skipped
        }()

        // Vocoder: wspólny poziom etykiety Ctrl i numerów pasm wypada dokładnie
        // pośrodku wolnej przestrzeni między dolną krawędzią ikonki podmiany
        // a górną krawędzią gniazda Ctrl. Dzięki temu napis nie ciąży ku nagłówkowi,
        // a wszystkie numery stoją na jednej osi i zachowują światło nad magistralą.
        let vocoderControlLabelCenterY: CGFloat? = {
            guard module.typeID == 108,
                  let controlIndex = ui.inputs.firstIndex(where: { $0.codeRef == 0 })
            else { return nil }
            let iconBottom = PatchLayout.replacementIconRect(in: rect).maxY
            let controlCenter = connectorCenterForDraw(
                module: module,
                connIndex: controlIndex,
                isOutput: false
            )
            let socketTop = controlCenter.y - UIMetrics.connectorHalf - UIMetrics.socketOuterMargin
            return (iconBottom + socketTop) / 2
        }()

        for lbl in ui.textLabels {
            if muxModuleIDs.contains(module.typeID), Int(lbl.text) != nil {
                guard let ledID = muxNumericTargets[lbl.id],
                      let led = ui.leds.first(where: { $0.id == ledID })
                else { continue }
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(
                        x: rect.minX + led.xPt - 1.2,
                        y: rect.minY + led.yPt + UIMetrics.ledGreenSize / 2
                    ),
                    anchor: .trailing
                )
                continue
            }

            if duplicateSwitchLabelIDs.contains(lbl.id) {
                continue
            }

            if [36, 76, 90, 100, 186, 187].contains(module.typeID), lbl.text == "Ctrl",
               let field = ui.textFields.first(where: { $0.masterRef == 0 })
            {
                // Te ekrany są w źródle węższe niż nasze minimum rysowania
                // (17 px ≈ 9,3 pt wobec textFieldMinWidth 12 pt), więc napis stojący
                // na oryginalnym XPos wchodził na zielone tło. Odstęp liczymy od
                // prawej krawędzi ekranu w rozmiarze, w jakim faktycznie go rysujemy.
                let fieldWidth = max(field.widthPt, UIMetrics.textFieldMinWidth)
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(
                        x: rect.minX + field.xPt + fieldWidth + 1.5,
                        y: rect.minY + field.yPt + UIMetrics.textFieldHeight / 2
                    ),
                    anchor: .leading
                )
                continue
            }

            if switchModuleIDs.contains(module.typeID), Int(lbl.text) != nil {
                // Numery stojące po lewej stronie gniazd dostają wspólny prześwit
                // od rzeczywistego obrysu gniazda i jego oś Y. To usuwa różnicę,
                // przez którą np. 1/2 były bliżej swoich gniazd niż 3/4.
                let connectors = ui.inputs.enumerated().map {
                    (index: $0.offset, conn: $0.element, isOutput: false)
                } + ui.outputs.enumerated().map {
                    (index: $0.offset, conn: $0.element, isOutput: true)
                }
                if let target = connectors
                    .filter({
                        $0.conn.xPt >= lbl.xPt
                            && $0.conn.xPt - lbl.xPt < 15
                            && abs($0.conn.yPt - lbl.yPt) < 4
                    })
                    .min(by: { $0.conn.xPt - lbl.xPt < $1.conn.xPt - lbl.xPt })
                {
                    let center = connectorCenterForDraw(
                        module: module,
                        connIndex: target.index,
                        isOutput: target.isOutput
                    )
                    let socketLeft = center.x - UIMetrics.connectorHalf
                        - UIMetrics.socketOuterMargin
                    ctx.draw(
                        Text(lbl.text)
                            .font(.system(size: lbl.fontSize, weight: .regular))
                            .fontWidth(.condensed)
                            .foregroundColor(labelColor),
                        at: CGPoint(x: socketLeft - 1.2, y: center.y),
                        anchor: .trailing
                    )
                    continue
                }
            }

            if module.typeID == 157, lbl.text == "In signal type",
               let button = ui.buttonsRadio.first(where: { $0.codeRef == 1 })
            {
                // LevConv: tytuł należy do całej trzyczęściowej grupy
                // BiPol/Pos/Neg, więc jego oś X wynika z szerokości grupy. Oś Y
                // jest środkiem rzeczywistej wolnej przestrzeni między wewnętrzną
                // krawędzią ramki a górą przycisków, nie stałym przesunięciem.
                let groupWidth = CGFloat(button.buttonCount) * button.buttonWidthPt
                let panelTop = rect.minY + 0.7
                let buttonTop = rect.minY
                    + buttonRadioYPt(moduleTypeID: module.typeID, button: button, ui: ui)
                let titleCenterY = (panelTop + buttonTop) / 2
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(
                        x: rect.minX + button.xPt + groupWidth / 2,
                        y: titleCenterY
                    ),
                    anchor: .center
                )
                continue
            }

            if module.typeID == 128, ["Min", "Max"].contains(lbl.text) {
                let codeRef = lbl.text == "Min" ? 0 : 1
                if let index = ui.outputs.firstIndex(where: { $0.codeRef == codeRef }) {
                    let center = connectorCenterForDraw(
                        module: module,
                        connIndex: index,
                        isOutput: true
                    )
                    let socketLeft = center.x - UIMetrics.connectorHalf
                        - UIMetrics.socketOuterMargin
                    ctx.draw(
                        Text(lbl.text)
                            .font(.system(size: lbl.fontSize, weight: .regular))
                            .fontWidth(.condensed)
                            .foregroundColor(labelColor),
                        at: CGPoint(x: socketLeft + 0.2, y: center.y),
                        anchor: .trailing
                    )
                    continue
                }
            }

            if module.typeID == 150 {
                let scale = PatchLayout.bverhuePixelScale
                let meterCenterX = rect.minX + 200 * scale
                let meterBottom = LedGeometry.compressorPowerBottomY(ui: ui, rect: rect)
                let ledTop = LedGeometry.compressorMeterBars(ui: ui, rect: rect).first?.minY ?? meterBottom
                let ledStrokeHalf: CGFloat = 0.175

                if lbl.text == "Gain Reduction" {
                    // Tytuł miernika ma wspólną oś z dziesięcioma segmentami, nie ze
                    // skalą po lewej. Wtedy nie styka się też z najwyższą cyfrą „1”.
                    ctx.draw(
                        Text(lbl.text)
                            .font(.system(size: lbl.fontSize, weight: .regular))
                            .fontWidth(.condensed)
                            .foregroundColor(labelColor),
                        at: CGPoint(x: meterCenterX, y: rect.minY + 2 * scale),
                        anchor: .top
                    )
                    continue
                }

                // Skala ma równe pionowe odstępy. Widoczna góra „1” pokrywa się z
                // górą pierwszego segmentu (łącznie z obrysem), a widoczny dół „30”
                // z dołem Power.
                let reductionScale = ["1", "4", "9", "15", "24", "30"]
                if let index = reductionScale.firstIndex(of: lbl.text) {
                    let firstTop = ledTop - ledStrokeHalf - labelCapTopOffset(fontSize: lbl.fontSize)
                    let lastTop = meterBottom - visibleTextBottomOffset(lbl.text, fontSize: lbl.fontSize)
                    let y = firstTop + CGFloat(index) * (lastTop - firstTop) / 5
                    ctx.draw(
                        Text(lbl.text)
                            .font(.system(size: lbl.fontSize, weight: .regular))
                            .foregroundColor(labelColor),
                        at: CGPoint(x: rect.minX + 194 * scale, y: y),
                        anchor: .topTrailing
                    )
                    continue
                }
            }

            // Tytuł sekcji Vocodera ma tę samą oś pionową co nazwa modułu w nagłówku.
            if module.typeID == 108, lbl.text == "Analysis" {
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(
                        x: rect.minX + lbl.xPt,
                        y: rect.minY + PatchLayout.headerH / 2
                    ),
                    anchor: .leading
                )
                continue
            }

            if module.typeID == 108, lbl.text == "Ctrl",
               let centerY = vocoderControlLabelCenterY
            {
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + lbl.xPt, y: centerY),
                    anchor: .leading
                )
                continue
            }

            if module.typeID == 178, ["Sample", "Delay"].contains(lbl.text) {
                // DlyClock: oba wiersze są jednym podpisem pola „Sample Delay”.
                // Osadzamy całą parę na środku modułu, zamiast pozwolić ogólnej
                // regule nagłówka rozdzielić je po dwóch stronach tej samej osi.
                let lineGap: CGFloat = 0.8
                let pairHeight = 2 * lbl.fontSize + lineGap
                let top = PatchLayout.ySpan - pairHeight / 2
                let y = lbl.text == "Sample" ? top : top + lbl.fontSize + lineGap
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + lbl.xPt, y: rect.minY + y),
                    anchor: .topLeading
                )
                continue
            }

            // Vocoder: numery 1...16 muszą stać dokładnie nad osiami swoich
            // pionowych przewodów i par +/-. Surowe XPos opisuje lewą krawędź
            // węższego fontu Clavii, przez co u nas szczególnie 15 nachodziło na 16.
            if module.typeID == 108,
               let band = Int(lbl.text), (1 ... 16).contains(band),
               let button = ui.incDecButtons.first(where: { $0.codeRef == band - 1 }),
               let centerY = vocoderControlLabelCenterY
            {
                let origin = operatorIncDecOrigin(module: module, button: button)
                let centerX = rect.minX + origin.x + UIMetrics.incDecHeight / 2
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: centerY),
                    anchor: .center
                )
                continue
            }

            // 8Counter/BinCounter (wagi bitowe "1".."128") i ADConv ("D0".."D7"): BVerhue
            // zostawia bardzo ciasny, stały odstęp etykieta→dioda/gniazdo (4-13px Gen1) —
            // przy naszej czcionce tekst nachodzi na kontrolkę, a dla najdłuższych ("128")
            // wypycha się poza moduł. Zamiast surowego XPos: dopasuj wg pozycji w
            // posortowanej liście (8Counter/BinCounter) lub najbliższe gniazdo wyjściowe
            // (ADConv) i narysuj etykietę tuż przed nią, wyśrodkowaną pionowo na jej
            // wysokości. Warunek na treść (tylko cyfry / tylko "Dn") wyklucza inne
            // etykiety modułu ("Clk", "Rst", "Input"), które opisują coś innego.
            if [86, 130].contains(module.typeID), Int(lbl.text) != nil,
               let idx = numericLabelsSorted.firstIndex(where: { $0.text == lbl.text }),
               idx < ledsSorted.count
            {
                let led = ledsSorted[idx]
                let centerY = rect.minY + led.yPt + UIMetrics.ledGreenSize / 2
                let leftEdge = rect.minX + led.xPt
                // Odstęp między sąsiednimi diodami bywa za wąski, żeby zmieścić 2-3-znakowe
                // wagi ("16".."128") bez nachodzenia na poprzednią diodę — jeśli szacowana
                // szerokość tekstu przekracza dostępną przestrzeń, skaluj czcionkę w dół
                // (podłoga 70%), żeby etykieta zmieściła się w szczelinie.
                let estWidth = 0.52 * lbl.fontSize * CGFloat(lbl.text.count)
                let availableWidth: CGFloat = idx > 0
                    ? (led.xPt - ledsSorted[idx - 1].xPt - UIMetrics.ledGreenSize) - 2.0
                    : .infinity
                let fitScale = availableWidth.isFinite && estWidth > availableWidth && estWidth > 0
                    ? max(0.7, availableWidth / estWidth) : 1.0
                // Przesunięcie o pół szerokości znaku w prawo (bliżej diody) na życzenie użytkownika.
                let halfCharWidth = 0.26 * lbl.fontSize * fitScale
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize * fitScale, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: leftEdge - 1.5 + halfCharWidth, y: centerY),
                    anchor: .trailing
                )
                continue
            }
            if module.typeID == 131, lbl.text.count == 2, lbl.text.hasPrefix("D"), lbl.text.dropFirst().first?.isNumber == true,
               let outputConn = ui.outputs.min(by: { abs($0.xPt - lbl.xPt) < abs($1.xPt - lbl.xPt) })
            {
                let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
                let side = connHalf * 2
                let centerY = rect.minY + outputConn.yPt + connHalf
                let leftEdge = rect.minX + outputConn.xPt
                // Gniazda są równo rozstawione (jack co ~12.6pt, szerokość ~6pt), więc
                // szczelina na 2-znakowy tekst "Dn" jest bardzo ciasna — jak w
                // 8Counter/BinCounter, skaluj czcionkę w dół (podłoga 70%), gdy szacowana
                // szerokość przekracza dostępną przestrzeń do POPRZEDNIEGO gniazda.
                let outputsSorted = ui.outputs.sorted { $0.xPt < $1.xPt }
                let estWidth = 0.52 * lbl.fontSize * CGFloat(lbl.text.count)
                let availableWidth: CGFloat = {
                    guard let idx = outputsSorted.firstIndex(where: { $0.id == outputConn.id }), idx > 0 else {
                        return .infinity
                    }
                    return (outputConn.xPt - outputsSorted[idx - 1].xPt - side) - 1.0
                }()
                let fitScale = availableWidth.isFinite && estWidth > availableWidth && estWidth > 0
                    ? max(0.7, availableWidth / estWidth) : 1.0
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize * fitScale, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: leftEdge - 0.2, y: centerY),
                    anchor: .trailing
                )
                continue
            }

            // Etykieta na tej samej osi Y co gniazdo I blisko w X → .leading (pionowo
            // wyśrodkowana z gniazdem). Samo Y nie wystarczy: etykiety opisujące coś
            // INNEGO (np. "KBT" nad przyciskiem) trafiają czasem przypadkiem na tę
            // samą wysokość co odległe gniazdo z drugiej strony modułu (np. Input z
            // lewej krawędzi) — bez warunku na X takie etykiety dziedziczyłyby zły,
            // przypadkowy środek (zob. bug-history: OscA/OscB/LfoA "KBT").
            let besideConn = allConnectors.first(where: {
                abs($0.yPt - lbl.yPt) < 1.5 && abs($0.xPt - lbl.xPt) < 15.0
            })
            let isBeside = besideConn != nil

            let aboveConn = aboveConnMatch(lbl)

            // Wykryj grupowy nagłówek: gdy aboveConn znalazło gniazdo i w tej samej linii Y
            // są inne gniazda w promieniu 15 pt od etykiety → wycentruj na środku grupy.
            // Podkreślenie rysowane tylko pod dolną etykietą (blisko wiersza gniazd, odległość Y < 8 pt).
            // WHITELIST typeID: aktywne tylko dla jawnie wymienionych modułów.
            // typeID 30 = Device ("Global Wheels" nad gniazdami 1 i 2)
            let connGroupModules: Set = [30]
            let aboveConnGroup: (centerX: CGFloat, lineMinX: CGFloat, lineMaxX: CGFloat, drawLine: Bool)? = {
                guard connGroupModules.contains(module.typeID) else { return nil }
                guard let match = aboveConn else { return nil }
                let matchY = match.conn.yPt
                let nearby = indexedConns.filter {
                    abs($0.conn.yPt - matchY) < 2.0 && abs($0.conn.xPt - lbl.xPt) < 15.0
                }
                guard nearby.count >= 2 else { return nil }
                let xs = nearby.map(\.conn.xPt)
                let minX = xs.min()!, maxX = xs.max()!
                // Środek gniazda = xPt + half (BVerhue XPos = lewy-górny róg widżetu 11×11 Gen1px)
                let connHalf: CGFloat = 5.5 * (140.0 / 256.0) // ≈ 3.008 pt
                let drawLine = (matchY - lbl.yPt) < 8.0
                return (
                    centerX: rect.minX + (minX + maxX) / 2 + connHalf,
                    lineMinX: rect.minX + minX,
                    lineMaxX: rect.minX + maxX + 2 * connHalf,
                    drawLine: drawLine
                )
            }()

            // Etykieta powyżej grupy radio-buttonów → centerX pary buttonów pod etykietą.
            // Algorytm: znajdź indeks najbliższego buttona, wycentruj na parze [idx, idx+1].
            // Np. "In" nad btn1-2, "Bus" nad btn3-4 w module 2-In.
            let aboveRadioCenterX: CGFloat? = {
                guard let btn = ui.buttonsRadio.first(where: {
                    $0.yPt > lbl.yPt + 1.5
                        && lbl.xPt >= $0.xPt - 2.0
                        && lbl.xPt <= $0.xPt + CGFloat($0.buttonCount) * $0.buttonWidthPt + 2.0
                }) else { return nil }
                // Indeks buttona najbliższego xPt etykiety (clamped do [0, count-2])
                let rawIdx = Int((lbl.xPt - btn.xPt) / btn.buttonWidthPt)
                let idx = max(0, min(btn.buttonCount - 2, rawIdx))
                let c0 = btn.xPt + (CGFloat(idx) + 0.5) * btn.buttonWidthPt
                let c1 = btn.xPt + (CGFloat(idx + 1) + 0.5) * btn.buttonWidthPt
                return (c0 + c1) / 2
            }()

            // Dwa rozbite na wiersze podpisy (`Phase Mod` i `Step/ Prob`) przecinają
            // dolną strefę nagłówka. To jeden opis, więc jego dolny wiersz zachowuje
            // dokładne odstępy BVerhue zamiast zostać zepchniętym poniżej nagłówka.
            // RndPattern "Prob" (dolny wiersz pary "Step/ Prob") wyleciał stąd
            // 2026-08-21: generyczna gałąź `aboveConn` (dopasowuje gniazdo
            // modulacji pod gałką Prob) daje TAKI SAM prześwit jak „Seed" w
            // RndTrig — użytkownik chciał dokładnie tego wyglądu, nie ciasnego
            // `labelTopClearing` nad samą gałką, który tu był wcześniej.
            let keepsCompoundLabelSpacing =
                (module.typeID == 183 && ["Phase", "Mod"].contains(lbl.text))
                    || (module.typeID == 208 && lbl.text == "Step/")

            let drawY: CGFloat
            if lbl.text == "Sync", isBeside, let trig = ui.symbols.first(where: { $0.type == "Trig 1" }) {
                // "Sync" wyrównane do wysokości strzałki "Trig 1" (która jest już
                // dobrze wycentrowana na gnieździe) — dla modułów, gdzie napis stoi
                // OBOK gniazda na tej samej wysokości (OscB/OscDual/OscShpA/OscShpB:
                // `besideConn` łapie gniazdo w promieniu 1.5pt Y / 15pt X). Warunek
                // `isBeside` dodany 2026-08-11: bez niego ta sama reguła łapała też
                // moduły, gdzie "Sync" stoi NAD gniazdem o dobry kawałek wyżej
                // (OscC/OscPM, ~6.6pt luzu w źródle) — wyrównanie do środka strzałki
                // ściągało wtedy napis w dół, prosto na gniazdo (które rysuje się
                // później i go zasłaniało). Te moduły spadają teraz do zwykłej
                // gałęzi Y (nagłówek/pod nagłówkiem), z zapasem miejsca nad gniazdem.
                drawY = rect.minY + trig.yPt + trig.heightPt / 2
            } else if module.typeID == 197 {
                // Status: "Patch Active"/"Var. Active"/"Voice No." leżą tuż nad swoim
                // gniazdem (BVerhue YPos zostawia ~0.5pt odstępu) — prawie się stykają.
                // Gniazda są już na wysokości zbliżonej do Keyboard (nie ruszamy ich —
                // to realna pozycja podłączenia kabli), więc odsuwamy tylko etykietę.
                drawY = rect.minY + max(0.5, lbl.yPt - 1.0)
            } else if module.typeID == 156, lbl.text == "Note" {
                // NoteDet: "Note" leży tuż nad wyświetlaczem tekstowym (BVerhue YPos
                // zostawia ~0.5pt odstępu) — prawie dotyka ekranu. Odsuń pod górną ramkę.
                drawY = rect.minY + 0.5
            } else if module.typeID == 158, lbl.text == "Time" {
                // Glide: "Time" leży tuż nad wyświetlaczem tekstowym (BVerhue YPos
                // zostawia ~0.5pt odstępu) — prawie dotyka ekranu. Odsuń pod górną ramkę.
                drawY = rect.minY + 0.5
            } else if [41, 55].contains(module.typeID), lbl.text == "Env",
                      let envOutput = ui.outputs.first(where: { $0.codeRef == 0 })
            {
                // EnvH/EnvD: przy naszym kroju widoczny dół „Env” prawie styka się
                // z własnym gniazdem Control. Ten sam stały prześwit co nad ekranami.
                drawY = rect.minY + max(0.3, labelTopClearing(above: envOutput.yPt, label: lbl))
            } else if module.typeID == 158, lbl.text == "Shape" {
                // Glide: "Shape" leży tuż nad przyciskiem "Log,Lin" (yPt≈7.66) —
                // ogólny warunek shiftUp (tekst pcha się w dół gdy jego dolna
                // krawędź przekracza headerH-1) o włos (~0.1pt) NIE się uruchamiał,
                // więc zejście litery "p" dotykało przycisku. Ta sama podłoga 1.5pt
                // co inne etykiety w nagłówku (patrz gałąź "!isBeside, yPt<headerH"
                // niżej) — wystarczający odstęp od zejść liter.
                drawY = rect.minY + 1.5
            } else if module.typeID == 25, ["Shape", "Phase"].contains(lbl.text),
                      let radio = ui.buttonsRadio.first(where: { $0.codeRef == 11 })
            {
                // LfoShpA: "Shape"/"Phase" (YPos:19) stoją w źródle tuż pod wierszem
                // przycisków fal (ButtonRadio YPos:4, wysokość ~buttonRadioHeight) —
                // ta sama kategoria kolizji co Glide "Shape" wyżej, tylko górna
                // krawędź kolidującego elementu jest tu zmienna (zależy od
                // buttonRadioHeight), więc liczymy prześwit zamiast sztywnej stałej.
                let radioBottom = radio.yPt + UIMetrics.buttonRadioHeight
                var y = max(lbl.yPt, radioBottom + 1.0)
                // „Shape" ma pod sobą własną gałkę zaledwie 9 Gen1px niżej — dosuwamy
                // napis DO NIEJ, żeby czytał się jako jej podpis, a nie jako opis wiersza
                // przycisków fal nad nim. Prześwit liczymy od PODSTAWY liter, nie od końca
                // ogonka „p" jak wspólny `labelTopClearing`: napis jest wyśrodkowany na osi
                // gałki, a ogonek stoi ~1.3pt w bok od niej, gdzie okrągła krawędź tarczy
                // zeszła już niżej — mieści się więc w prześwicie, którego „nie widać".
                if lbl.text == "Shape", let knob = ui.knobs.first(where: { $0.codeRef == 5 }) {
                    let baselineAboveDial: CGFloat = 0.9
                    y = knob.yPt - baselineAboveDial - labelBaselineOffset(fontSize: lbl.fontSize)
                }
                drawY = rect.minY + y
            } else if module.typeID == 117, lbl.text == "AM",
                      let modDepthLbl = ui.textLabels.first(where: { $0.text == "Mod depth" })
            {
                // LevMod: "AM" ma mieć tę samą wysokość co "Mod depth" — przelicz
                // Y "Mod depth" tą samą formułą co domyślna gałąź "wewnątrz nagłówka"
                // (poniżej), żeby obie etykiety wypadły na identycznej linii.
                let textBottom = modDepthLbl.yPt + modDepthLbl.fontSize
                let shiftUp: CGFloat = textBottom > PatchLayout.headerH - 1.0 ? 1.0 : 0.0
                drawY = rect.minY + max(1.5, modDepthLbl.yPt - shiftUp)
            } else if module.typeID == 102, lbl.text == "KBT" {
                // FltPhase: SwiftUI ma wyższy line box niż etykieta Clavii, więc
                // surowe YPos zostawiało KBT niemal na przycisku pod nim.
                drawY = rect.minY + max(1.5, lbl.yPt - 4.0)
            } else if module.typeID == 102, lbl.text == "FB", lbl.yPt < PatchLayout.headerH {
                // Górne „FB” opisuje gałkę ze strzałką resetu. Podnieś wyłącznie ten
                // podpis, aby nie stykał się z trójkątem; dolne „FB” pozostaje opisem
                // własnego gniazda w drugim rzędzie.
                drawY = rect.minY + max(1.5, lbl.yPt - 1.0)
            } else if module.typeID == 51, lbl.yPt < PatchLayout.headerH,
                      lbl.text == "Freq" || lbl.text == "Res",
                      let knob = ui.knobs.filter({ $0.type.isRotary && $0.yPt > lbl.yPt })
                      .min(by: { abs($0.xPt - lbl.xPt) < abs($1.xPt - lbl.xPt) })
            {
                // FltNord: "Freq"/"Res" mają BVerhue yPt≈2.2-2.7pt — bardzo blisko
                // górnej ramki modułu, a gałka pod nimi zaczyna się już przy yPt≈7.7-8.2pt
                // (mało miejsca w sumie). Wyśrodkuj tekst w dostępnej szczelinie między
                // górną ramką i górną krawędzią gałki, zamiast sztywnej wartości, która
                // dla "Freq" (gałka Big, wyżej) i "Res" (gałka Medium, niżej) inaczej się sprawdza.
                drawY = rect.minY + max(1.0, (knob.yPt - lbl.fontSize) / 2)
            } else if module.typeID == 177, lbl.text == "HP" {
                // DelayB: "HP" leży tuż pod granicą nagłówka (yPt≈7.7 < headerH≈8.2)
                // i błędnie trafia w gałąź "wewnątrz nagłówka" — przez co wypada
                // wyżej niż "LP" względem swojej gałki. Wymuszamy tę samą gałąź
                // pozycjonowania co dla "LP" (poniżej nagłówka).
                drawY = rect.minY + lbl.yPt - 1.5
            } else if module.typeID == 182, lbl.text == "FB" || lbl.text == "X-FB",
                      let lp = ui.textLabels.first(where: { $0.text == "LP" })
            {
                // DlyStereo: "FB"/"X-FB" mają yPt tuż pod progiem nagłówka (≈7.1pt),
                // więc trafiały w gałąź "zepchnij poniżej nagłówka" i lądowały na
                // swoich gałkach. Wyrównaj do linii "LP"/"HP" w tym samym wierszu.
                drawY = rect.minY + lp.yPt - 1.5
            } else if module.typeID == 9, lbl.text == "Sync" {
                // OscC: Sync jest etykietą NAD wejściem (XPos:155, YPos:17; wejście
                // XPos:158, YPos:29 w panelu Clavii). Ogólna ochrona nagłówka mylnie
                // przesuwała ją pod gniazdo, bo napis leży przy dolnej granicy headera.
                drawY = rect.minY + lbl.yPt
            } else if keepsCompoundLabelSpacing {
                drawY = rect.minY + lbl.yPt
            } else if lbl.yPt > headerPushThreshold, lbl.yPt < PatchLayout.headerH {
                // Dolne 2 pt nagłówka: nakładają się na nazwę → zepchnij poniżej nagłówka
                drawY = rect.minY + PatchLayout.headerH + 1.0
            } else if !isBeside, lbl.yPt >= PatchLayout.headerH {
                // Etykiety poniżej nagłówka: SwiftUI font ma większy line box niż Delphi TLabel
                // → przesunięcie 1.5 pt w górę zapobiega nachodeniu na elementy poniżej.
                // Ta sama podłoga co w gałęzi nagłówkowej niżej — tylko podnosi przy
                // realnej kolizji (np. OscDual "Phase"/"Lvl" dotykały gałek poniżej).
                let y = lbl.yPt - 1.5
                let belowLimit = nearestControlBelow(ui: ui, label: lbl)
                    .map { labelTopClearing(above: $0.y, label: lbl, reserveDescender: $0.isButton) }
                let clamped = belowLimit.map { min(y, $0) } ?? y
                drawY = rect.minY + labelTopClearingResetTriangle(clamped, ui: ui, label: lbl)
            } else if !isBeside, lbl.yPt < PatchLayout.headerH {
                // Etykiety wewnątrz nagłówka (górna część):
                // – podłoga 1.5 pt od górnej ramki (ramka highlight = 0.7 pt)
                // – jeśli dolna krawędź tekstu sięga granicy nagłówka → przesuń 1 pt w górę
                let textBottom = lbl.yPt + lbl.fontSize
                let shiftUp: CGFloat = textBottom > PatchLayout.headerH - 1.0 ? 1.0 : 0.0
                var y = max(1.5, lbl.yPt - shiftUp)
                // Powyższe chroni tylko przed nagłówkiem — nie przed kontrolką
                // BEZPOŚREDNIO pod etykietą (np. Glide "Shape" nad przyciskiem
                // Log/Lin, KeyQuant "Range" nad wyświetlaczem LCD). Jeśli taka
                // jest blisko, dociśnij tekst wyżej (nigdy niżej), żeby zejścia
                // liter ("p"/"g") jej nie dotykały — `labelTopClearing` liczy to od
                // WIDOCZNEGO dołu liter, więc napisy bez ogonków siadają bliżej.
                let belowLimit = nearestControlBelow(ui: ui, label: lbl)
                    .map { labelTopClearing(above: $0.y, label: lbl, reserveDescender: $0.isButton) }
                if let belowLimit {
                    y = min(y, belowLimit)
                }
                // Podłoga tylko gdy NIE ma kolizji od dołu — inaczej cofałaby
                // dociśnięcie z powyższej linii i pchała etykietę z powrotem w
                // stronę kontrolki (dokładnie odwrotnie niż trzeba), tak jak w
                // przypadku KeyQuant "Range" dotykającego ekranu LCD poniżej.
                // Gdy kolizja jest tak ciasna że i tak wychodzi ujemne — 0.3pt
                // (subtelne zbliżenie do cienkiej ramki highlight 0.7pt jest
                // mniej widoczne niż dotknięcie ekranu/przycisku).
                // Trójkąt resetu nie jest „kontrolką" z nearestControlBelow, a stoi
                // dokładnie pod opisem swojej gałki — traktujemy go tak samo.
                let triangleY = labelTopClearingResetTriangle(y, ui: ui, label: lbl)
                let hasCollisionBelow = belowLimit != nil || triangleY < y
                let floor: CGFloat = hasCollisionBelow ? 0.3 : 0.7
                drawY = rect.minY + max(floor, min(y, triangleY))
            } else if let bc = besideConn {
                // Etykieta "beside" gniazda: wyśrodkuj pionowo na rzeczywistym środku
                // gniazda (BVerhue XPos/YPos = lewy-górny róg widżetu 11×11 Gen1px),
                // nie na surowym YPos etykiety — inaczej tekst wypada nad kropką.
                let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
                drawY = rect.minY + bc.yPt + connHalf
            } else {
                drawY = rect.minY + lbl.yPt
            }

            // ── Module-specific overrides ───────────────────────────────────────
            if [121, 144, 145, 146, 154].contains(module.typeID), Int(lbl.text) != nil,
               !ui.leds.filter({ $0.type == .sequencer }).isEmpty
            {
                // Numery kroków opisują diody pod sobą: stoją na osi swojej diody
                // i wszystkie w jednym rzędzie. W źródle skrajny numer („16") bywa
                // szerszy od pozostałych i wpadał w inną gałąź wyrównania, przez co
                // siadał niżej niż reszta rzędu.
                let labelCenter = lbl.xPt + labelWidth(lbl.text, fontSize: lbl.fontSize) / 2
                let leds = ui.leds.filter { $0.type == .sequencer }
                let led = leds.min {
                    abs($0.xPt + UIMetrics.ledSeqWidth / 2 - labelCenter)
                        < abs($1.xPt + UIMetrics.ledSeqWidth / 2 - labelCenter)
                }!
                let rowTop = leds.map(\.yPt).min() ?? led.yPt
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + led.xPt + UIMetrics.ledSeqWidth / 2,
                                y: labelTopClearing(above: rect.minY + rowTop, label: lbl)),
                    anchor: .top
                )
            } else if lbl.text == "Length", let row = sequencerLengthRow(module: module, ui: ui) {
                // Napis należy do rozkładu całego rzędu (patrz `sequencerLengthRow`)
                // i stoi na osi ekranu oraz pary −/+.
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + row.labelX,
                                y: labelTopCenteredOn(rect.minY + row.rowCenterY, label: lbl)),
                    anchor: .topLeading
                )
            } else if [121, 144, 145, 146, 154].contains(module.typeID),
                      parkArrowLayout(module: module, ui: ui) == nil || lbl.text != "Park",
                      let target = sequencerLabelTarget(lbl, ui: ui)
            {
                // Opis stoi tuż przy kontrolce, którą nazywa, i na jej osi.
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + target.leftEdge - 1.5,
                                y: labelTopCenteredOn(rect.minY + target.centerY, label: lbl)),
                    anchor: .topTrailing
                )
            } else if lbl.text == "Park", let park = parkArrowLayout(module: module, ui: ui) {
                // Napis ustępuje miejsca strzałce przeniesionej za gniazdo i siada
                // na jego osi — w źródle wisiał pod nią.
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + park.labelX,
                                y: labelTopCenteredOn(rect.minY + park.socketCenterY, label: lbl)),
                    anchor: .topLeading
                )
            } else if [121, 144, 145, 146, 154].contains(module.typeID), lbl.xPt < 5.0,
                      let socketIdx = ui.inputs.indices
                      .filter({ ui.inputs[$0].xPt < 5.0 && ui.inputs[$0].yPt > lbl.yPt + 1.5 })
                      .min(by: { ui.inputs[$0].yPt < ui.inputs[$1].yPt })
            {
                // Sekwencery: opisy gniazd w lewej kolumnie („Clk", „Rst", „Loop")
                // wisiały wysoko nad swoim gniazdem, bo BVerhue rozstawia je w rytmie
                // wyższego panelu oryginału. Napis siada tuż nad obrysem SWOJEGO
                // gniazda, czyli najbliższego w tej samej kolumnie poniżej — szukamy
                // go wprost, bo ogólne dopasowanie łapało czasem gniazdo wyjściowe
                // z drugiej strony panelu.
                let center = connectorCenterForDraw(module: module,
                                                    connIndex: socketIdx,
                                                    isOutput: false)
                let socketTop = center.y - UIMetrics.connectorHalf - UIMetrics.socketOuterMargin
                // Prześwit liczymy od PODSTAWY liter, nie od końca ogonka: inaczej
                // „Loop" (ogonek „p") siadałby o punkt wyżej niż „Clk" czy „Rst"
                // i cała kolumna opisów wyglądałaby na nierówną. Ogonek schodzi
                // w prześwit, którego i tak nie widać.
                let clearance = socketTop - 0.145 * lbl.fontSize
                    - labelBaselineOffset(fontSize: lbl.fontSize)
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + max(1.5, ui.inputs[socketIdx].xPt),
                                y: clearance),
                    anchor: .topLeading
                )
            } else if module.typeID == 161, lbl.text == "Pad",
                      let button = ui.buttonsFlat.first(where: { $0.codeRef == 17 })
            {
                // MixFader: „Pad" opisuje przycisk obok, więc stoi tuż przy jego
                // lewej krawędzi i na jego osi — w źródle wisiał wyżej (YPos:6 przy
                // YPos:4 przycisku) i o ~2,4pt dalej, przez co czytał się jak osobny
                // napis nagłówka, a nie podpis tej kontrolki.
                let gap: CGFloat = 1.5
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(
                        x: rect.minX + button.xPt - gap,
                        y: rect.minY + button.yPt + UIMetrics.buttonFlatHeight / 2
                    ),
                    anchor: .trailing
                )
            } else if module.typeID == 140, ["L", "R"].contains(lbl.text), lbl.xPt < 100,
                      let match = aboveConnMatch(lbl)
            {
                // Mix4-1S: opisy wejść stereo należą do gniazda pod sobą. Pierwsza
                // para stoi przy lewej krawędzi modułu i jako jedyna wpadała w ogólną
                // regułę „napisy nad kolumną wejść wyrównaj do lewej" — cała czwórka
                // par liczy się teraz tak samo, każdy napis na osi swojego gniazda.
                let center = connectorCenterForDraw(module: module,
                                                    connIndex: match.idx,
                                                    isOutput: match.isOutput)
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: center.x, y: drawY - 1.0),
                    anchor: .top
                )
            } else if module.typeID == 140, ["L", "R"].contains(lbl.text),
                      let vu = MiniVUDatabase.defs(forModuleID: module.typeID)
                      .min(by: { abs($0.xPt - lbl.xPt) < abs($1.xPt - lbl.xPt) }),
                      let socketIdx = ui.inputs.firstIndex(where: {
                          abs($0.xPt - lbl.xPt) < 5.0 && $0.yPt < lbl.yPt
                      })
            {
                // Mix4-1S: „L"/„R" nad wskaźnikami wyjścia dotykały ich górnej
                // krawędzi. Napis siada w środku wolnej przestrzeni między gniazdem
                // Chain nad nim a wskaźnikiem pod nim i stoi na osi wskaźnika.
                let socketCenter = connectorCenterForDraw(module: module,
                                                          connIndex: socketIdx,
                                                          isOutput: false)
                let socketBottom = socketCenter.y + UIMetrics.connectorHalf + UIMetrics.socketOuterMargin
                let vuTop = rect.minY + vu.yPt - UIMetrics.miniVUTopShift
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(
                        x: rect.minX + vu.xPt + UIMetrics.miniVUWidth / 2,
                        y: labelTopCenteredInGap(top: socketBottom, bottom: vuTop, label: lbl)
                    ),
                    anchor: .top
                )
            } else if module.typeID == 48, Int(lbl.text) != nil,
                      let match = aboveConnMatch(lbl)
            {
                // MixStereo: numery kanałów zachodziły na obrys swojego gniazda.
                // Wolnego miejsca jest tu dokładnie tyle, ile mierzy sama cyfra, więc
                // sadzamy ją pośrodku między dolną krawędzią nagłówka a górą gniazda.
                let center = connectorCenterForDraw(module: module,
                                                    connIndex: match.idx,
                                                    isOutput: match.isOutput)
                let socketTop = center.y - UIMetrics.connectorHalf - UIMetrics.socketOuterMargin
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(
                        x: center.x,
                        y: labelTopCenteredInGap(top: rect.minY + PatchLayout.headerH,
                                                 bottom: socketTop, label: lbl)
                    ),
                    anchor: .top
                )
            } else if module.typeID == 48, ["Main Out", "Master"].contains(lbl.text),
                      let knob = ui.knobs.first(where: { $0.type == .big })
            {
                // MixStereo: oba podpisy należą do gałki Main Out, więc stoją na jej
                // osi (BVerhue zapisał je jako lewą krawędź napisu — obydwa wypadały
                // wyraźnie w lewo). „Master" dodatkowo schodzi na środek przestrzeni
                // między tarczą a wskaźnikami, zamiast wisieć tuż pod gałką.
                var y = drawY
                if lbl.text == "Master",
                   let vuTopPt = MiniVUDatabase.defs(forModuleID: module.typeID).map(\.yPt).min()
                {
                    let knobBottom = rect.minY + knob.yPt + knob.type.centerOffsetPt.y + knob.type.radiusPt
                    let vuTop = rect.minY + vuTopPt - UIMetrics.miniVUTopShift
                    y = labelTopCenteredInGap(top: knobBottom, bottom: vuTop, label: lbl)
                }
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + knob.xPt + knob.type.centerOffsetPt.x, y: y),
                    anchor: .top
                )
            } else if module.typeID == 33, lbl.text == "Mid",
                      let line = ui.lines.first(where: { $0.id == 23 })
            {
                // Eq3Band: nagłówek sekcji jest wyśrodkowany na poziomej kresce pod nim.
                let centerX = rect.minX + line.xPt + line.lengthPt / 2
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: drawY),
                    anchor: .top
                )
            } else if module.typeID == 33, ["Lo", "Lev"].contains(lbl.text),
                      let codeRef = lbl.text == "Lo" ? 0 : 4,
                      let knob = ui.knobs.first(where: { $0.codeRef == codeRef })
            {
                // Eq3Band: skrajne opisy korzystają z tej samej osi i odstępu od
                // potencjometru co Gain/Freq/Hi, mimo niższego YPos źródłowego „Lev".
                let rightX = labelRightEdgeAtKnob(knob)
                let topY = knobRowLabelTopY(ui: ui, label: lbl, knob: knob)
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + rightX, y: rect.minY + topY),
                    anchor: .topTrailing
                )
            } else if module.typeID == 103, lbl.text == "Lev",
                      let knob = ui.knobs.first(where: { $0.codeRef == 4 })
            {
                // EqPeak: Lev należy do tego samego rzędu co Freq/Gain/BW.
                let rightX = labelRightEdgeAtKnob(knob)
                let topY = knobRowLabelTopY(ui: ui, label: lbl, knob: knob)
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + rightX, y: rect.minY + topY),
                    anchor: .topTrailing
                )
            } else if module.typeID == 162, lbl.text == "Type",
                      let button = ui.buttonsFlat.first(where: { $0.codeRef == 5 })
            {
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + button.xPt + button.widthPt / 2, y: drawY),
                    anchor: .top
                )
            } else if module.typeID == 35, lbl.text == "Type",
                      let selector = ui.partSelectors.first(where: { $0.id == 7 })
            {
                // PM Driver: napis opisuje cały ekran PartSelectora, więc jego oś
                // musi wynikać z faktycznie rysowanego prostokąta, nie z XPos tekstu.
                let centerX = partSelectorRect(selector, moduleTypeID: module.typeID, in: rect).midX
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: drawY),
                    anchor: .top
                )
            } else if module.typeID == 35,
                      let codeRef = ["Embouchure": 1, "Stiffness": 0][lbl.text],
                      let knob = ui.knobs.first(where: { $0.codeRef == codeRef })
            {
                // PM Driver: oba napisy mają wspólną oś ze środkiem własnej gałki.
                let origin = knobOrigin(module: module, knob: knob)
                let centerX = rect.minX + origin.x + knob.type.centerOffsetPt.x
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: drawY),
                    anchor: .top
                )
            } else if module.typeID == 162, lbl.text == "Lev",
                      let knob = ui.knobs.first(where: { $0.codeRef == 6 })
            {
                let rightX = labelRightEdgeAtKnob(knob)
                let topY = knobRowLabelTopY(ui: ui, label: lbl, knob: knob)
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + rightX, y: rect.minY + topY),
                    anchor: .topTrailing
                )
            } else if module.typeID == 102, lbl.text == "Type",
                      let button = ui.buttonsFlat.first(where: { $0.codeRef == 9 })
            {
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + button.xPt + button.widthPt / 2, y: drawY),
                    anchor: .top
                )
            } else if module.typeID == 102, lbl.text == "Spread",
                      let knob = ui.knobs.first(where: { $0.codeRef == 5 })
            {
                let centerX = rect.minX + knob.xPt + knob.type.centerOffsetPt.x
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: drawY),
                    anchor: .top
                )
            } else if module.typeID == 102, lbl.text == "FB",
                      let knob = ui.knobs.first(where: { $0.codeRef == 3 })
            {
                // FB siedzi bezpośrednio nad trójkątem resetu. Liczymy od widocznej
                // podstawy liter i zostawiamy tylko 0,2pt, żeby napis nie uciekał wysoko.
                let triangleTop = knobResetTriangleTopY(knobTopY: knob.yPt)
                let topY = triangleTop - 0.2 - visibleTextBottomOffset(lbl.text, fontSize: lbl.fontSize)
                let centerX = rect.minX + knob.xPt + knob.type.centerOffsetPt.x
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: rect.minY + max(Self.labelTopFloor, topY)),
                    anchor: .top
                )
            } else if module.typeID == 102, lbl.text == "Notch",
                      let field = ui.textFields.first(where: { $0.masterRef == 4 })
            {
                let centerX = rect.minX + field.xPt + field.widthPt / 2
                let topY = clampedLabelTop(labelTopClearing(above: field.yPt, label: lbl))
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: rect.minY + topY),
                    anchor: .top
                )
            } else if module.typeID == 92, lbl.text == "dB/Oct",
                      let button = ui.buttonsRadio.first(where: { $0.codeRef == 4 })
            {
                let buttonY = buttonRadioYPt(moduleTypeID: module.typeID, button: button, ui: ui)
                let rawWidth = max(button.buttonWidthPt, UIMetrics.buttonRadioMinWidth)
                let centerX = rect.minX + button.xPt + CGFloat(button.buttonCount) * rawWidth / 2
                let topY = buttonY - 0.2 - visibleTextBottomOffset(lbl.text, fontSize: lbl.fontSize)
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: rect.minY + topY),
                    anchor: .top
                )
            } else if module.typeID == 45, lbl.text == "Vowel navigator",
                      let leftLine = ui.lines.first(where: { $0.id == 16 }),
                      let rightLine = ui.lines.first(where: { $0.id == 25 })
            {
                let centerX = rect.minX + (leftLine.xPt + rightLine.xPt) / 2
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: drawY),
                    anchor: .top
                )
            } else if module.typeID == 165, ["Feedback", "Algorithm"].contains(lbl.text),
                      let codeRef = lbl.text == "Feedback" ? 1 : 0,
                      let field = ui.textFields.first(where: { $0.masterRef == codeRef }),
                      let incDec = ui.incDecButtons.first(where: { $0.codeRef == codeRef })
            {
                // DXRouter: nagłówek opisuje cały zestaw sterujący — ekran LCD oraz
                // parę +/- — więc środek liczymy z obu elementów, nie z surowego XPos.
                let minX = min(field.xPt, incDec.xPt)
                let maxX = max(field.xPt + field.widthPt, incDec.xPt + UIMetrics.incDecHeight)
                let centerX = rect.minX + (minX + maxX) / 2
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: drawY),
                    anchor: .top
                )
            } else if module.typeID == 180, lbl.xPt < 10,
                      let codeRef = ["Pitch": 6, "Freq": 0, "Gate": 2,
                                     "Note": 3, "AMod": 4, "Vel": 5][lbl.text],
                      let input = ui.inputs.first(where: { $0.codeRef == codeRef })
            {
                // Warunek `lbl.xPt < 10` jest KONIECZNY: panel ma DWIE etykiety „Vel" —
                // tę z lewej kolumny (XPos:4 → 2.19pt) i tę nad ekranem przy RateScale
                // (ID:47, XPos:182 → 99.5pt). Bez niego obie trafiały na lewą krawędź,
                // jedna na drugą, a ekran przy RateScale zostawał BEZ podpisu.
                // Pozostałe nazwy z tej mapy występują w panelu tylko raz.
                // Operator: podpisy lewej kolumny muszą jednoznacznie wskazywać własne
                // gniazdo. PRAWDZIWA przyczyna, dla której trzy poprzednie tury (0.8 →
                // 0.3 → 0.1pt) nie dawały efektu: `anchor: .bottomLeading` wyrównuje
                // DOLNĄ KRAWĘDŹ PUDEŁKA WIERSZA (line box), a nie widoczną podstawę
                // liter. Przy condensed SF @4.92pt pudełko ma 7.0pt wysokości, ale
                // podstawa liter leży ~1.8pt NAD jego dolną krawędzią (zapas na ogonki
                // „g/q" + leading). Zmierzone na renderze niezależnie dla „Pitch" (1.79pt)
                // i „Note" (1.78pt) — więc margines 0.1pt dawał w rzeczywistości ~1.9pt
                // widocznego odstępu i napis wypadał w połowie drogi między gniazdami.
                // Kompensujemy tę niewidoczną przestrzeń, żeby `ownGap` znaczyło realny,
                // widoczny odstęp podstawy liter od krawędzi gniazda.
                // Litery z ogonkiem („q" w „Freq") schodzą wtedy o ~0.8pt niżej, ale stoją
                // na prawo od gniazda (gniazdo kończy się na 8.2pt, ogonek jest przy ~11pt),
                // więc nie ma kolizji.
                let leadingX = rect.minX + max(1.5, input.xPt)
                let lineBoxDescent: CGFloat = 1.8
                // 1.2pt (nie 0.7) — użytkownik ocenił poprzedni odstęp jako wciąż zbyt
                // ciasny (2026-08-12, piąta tura). `ownMargin = ownGap - lineBoxDescent`
                // sprawia, że `ownGap` to bezpośrednio WIDOCZNY odstęp (patrz wyprowadzenie
                // w komentarzu wyżej) — podnosimy go bez zmiany reszty wzoru.
                let ownGap: CGFloat = 1.2
                let ownMargin: CGFloat = ownGap - lineBoxDescent
                if lbl.text == "AMod",
                   let field = ui.textFields.first(where: { $0.id == 55 })
                {
                    // AMod opisuje parę gniazdo+ekran, ale gniazdo (yPt≈77.7) jest DALEKO
                    // pod ekranem (yPt≈68.9) — licz odstęp od ekranu, tak jak inne opisy
                    // liczą margines od swojego gniazda, żeby napis stał tuż nad ekranem,
                    // nie osobno gdzieś między Note a ekranem.
                    let frame = operatorTextFieldFrame(module: module, field: field)
                    ctx.draw(
                        Text(lbl.text)
                            .font(.system(size: lbl.fontSize, weight: .regular))
                            .fontWidth(.condensed)
                            .foregroundColor(labelColor),
                        at: CGPoint(x: leadingX, y: rect.minY + frame.y - ownMargin),
                        anchor: .bottomLeading
                    )
                } else {
                    let center = connectorCenterForDraw(
                        module: module,
                        connIndex: ui.inputs.firstIndex(where: { $0.id == input.id }) ?? 0,
                        isOutput: false
                    )
                    ctx.draw(
                        Text(lbl.text)
                            .font(.system(size: lbl.fontSize, weight: .regular))
                            .fontWidth(.condensed)
                            .foregroundColor(labelColor),
                        at: CGPoint(x: leadingX, y: center.y - UIMetrics.connectorHalf - ownMargin),
                        anchor: .bottomLeading
                    )
                }
            } else if module.typeID == 180, lbl.xPt >= 10, lbl.text == "RateScale",
                      let field = ui.textFields.first(where: { $0.masterRef == 7 }),
                      let button = ui.incDecButtons.first(where: { $0.codeRef == 7 })
            {
                // Keep the title on one line and center it over the complete group.
                let group = operatorIncDecGroupLayout(module: module, field: field, button: button)
                let labelY = rect.minY + labelTopClearing(
                    above: group.topY,
                    label: lbl
                )
                ctx.draw(
                    Text("Rate Scale")
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + group.rightX, y: labelY),
                    anchor: .topTrailing
                )
            } else if module.typeID == 180, lbl.xPt >= 10, lbl.text == "Vel",
                      let field = ui.textFields.first(where: { $0.masterRef == 6 }),
                      let button = ui.incDecButtons.first(where: { $0.codeRef == 6 })
            {
                // This is the upper Vel title, centered over its LCD and +/- pair.
                let group = operatorIncDecGroupLayout(module: module, field: field, button: button)
                let labelY = rect.minY + labelTopClearing(
                    above: group.topY,
                    label: lbl
                )
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + group.centerX, y: labelY),
                    anchor: .top
                )
            } else if module.typeID == 180, lbl.text == "Detune",
                      let field = ui.textFields.first(where: { $0.id == 38 }),
                      let button = ui.incDecButtons.first(where: { $0.codeRef == 5 })
            {
                // Keep Detune on the same label row as Coarse/Fine and center it
                // over its complete control group: the LCD and the vertical +/- pair.
                let group = operatorIncDecGroupLayout(module: module, field: field, button: button)
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(
                        x: rect.minX + group.centerX,
                        y: operatorTopLabelRowY(ui: ui, rect: rect) ?? drawY
                    ),
                    anchor: .top
                )
            } else if module.typeID == 180, lbl.text == "OutLev",
                      let field = ui.textFields.first(where: { $0.masterRef == 22 })
            {
                // OutLev: surowy XPos jest lewą krawędzią napisu, nie środkiem ekranu
                // pod nim — wyśrodkuj nad WŁASNYM ekranem, jak "Coarse"/"Fine" nad gałką
                // niżej (gałąź `aboveKnobMatch`).
                let centerX = rect.minX + field.xPt + field.widthPt / 2
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: rect.minY + labelTopClearing(above: field.yPt, label: lbl)),
                    anchor: .top
                )
            } else if module.typeID == 180,
                      ["R1", "L1", "R2", "L2", "R3", "L3", "R4", "L4",
                       "BrPoint", "L-Depth", "R-Depth", "Coarse", "Fine"].contains(lbl.text)
            {
                // Operator: osiem odczytów R/L ma być dokładnie pod własnymi nazwami.
                // Trzy opisy na dole kończą się zaś na prawej krawędzi ekranu poniżej;
                // dzięki temu BrPoint, L-Depth i R-Depth tworzą jeden spokojny wiersz.
                let envelopeRefs: [String: Int] = [
                    "R1": 8, "L1": 9, "R2": 10, "L2": 11,
                    "R3": 12, "L3": 13, "R4": 14, "L4": 15,
                ]
                let bottomFieldIDs: [String: Int] = ["BrPoint": 71, "L-Depth": 67, "R-Depth": 63]

                if let codeRef = envelopeRefs[lbl.text],
                   let field = ui.textFields.first(where: { $0.masterRef == codeRef })
                {
                    let frame = operatorTextFieldFrame(module: module, field: field)
                    ctx.draw(
                        Text(lbl.text)
                            .font(.system(size: lbl.fontSize, weight: .regular))
                            .fontWidth(.condensed)
                            .foregroundColor(labelColor),
                        // Raise the complete R/L title row by one source pixel. The
                        // readouts below are centered between this row and the knobs.
                        at: CGPoint(x: rect.minX + frame.x + frame.width / 2,
                                    y: rect.minY + 73.0 * PatchLayout.bverhuePixelScale),
                        anchor: .top
                    )
                } else if let fieldID = bottomFieldIDs[lbl.text],
                          let field = ui.textFields.first(where: { $0.id == fieldID })
                {
                    let frame = operatorTextFieldFrame(module: module, field: field)
                    let labelY = operatorBottomLabelRowY(module: module, ui: ui, rect: rect)
                        ?? rect.minY + labelTopClearing(above: frame.y, label: lbl)
                    ctx.draw(
                        Text(lbl.text)
                            .font(.system(size: lbl.fontSize, weight: .regular))
                            .fontWidth(.condensed)
                            .foregroundColor(labelColor),
                        // Opis jedzie razem ze swoim ekranem (ten zszedł niżej, żeby
                        // dolny rząd stał równo z „-Lin" i „+/−") — wspólna zasada
                        // `labelTopClearing` trzyma stały, widoczny odstęp nad ekranem
                        // zamiast sztywnego poziomu, który trzeba było korygować przy
                        // każdym ruchu ekranów.
                        at: CGPoint(x: rect.minX + frame.x + frame.width,
                                    y: labelY),
                        anchor: .topTrailing
                    )
                } else if let codeRef = ["Coarse": 3, "Fine": 4][lbl.text],
                          let knob = ui.knobs.first(where: { $0.codeRef == codeRef })
                {
                    ctx.draw(
                        Text(lbl.text)
                            .font(.system(size: lbl.fontSize, weight: .regular))
                            .fontWidth(.condensed)
                            .foregroundColor(labelColor),
                        at: CGPoint(x: rect.minX + knob.xPt + knob.type.centerOffsetPt.x, y: drawY),
                        anchor: .top
                    )
                }
                // DelayB (typeID:177): nagłówki "FB"/"Filter"/"Dry/Wet" wycentrowane
                // nad odpowiadającą gałką (BVerhue XPos nagłówka nie jest wyśrodkowany
                // względem gałki poniżej). "FB"/"Dry/Wet" → tylko główny potencjometr
                // (bez gałki modulacji pod nim); "Filter" → środek między HP i LP.
            } else if module.typeID == 177, ["FB", "Filter", "Dry/Wet"].contains(lbl.text),
                      let centerX = {
                          let codeRefs: [Int] = lbl.text == "FB" ? [1]
                              : lbl.text == "Filter" ? [2, 8] : [3]
                          let matching = ui.knobs.filter { codeRefs.contains($0.codeRef) }
                          guard !matching.isEmpty else { return nil as CGFloat? }
                          let xs = matching.map { $0.xPt + $0.type.centerOffsetPt.x }
                          return rect.minX + xs.reduce(0, +) / CGFloat(xs.count)
                      }()
            {
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: drawY - 1.0),
                    anchor: .top
                )
            } else if module.typeID == 182, lbl.text == "Filter",
                      let centerX = {
                          let filterRefs = Set([7, 10]) // LP i HP
                          let matching = ui.knobs.filter { filterRefs.contains($0.codeRef) }
                          guard matching.count == 2 else { return nil as CGFloat? }
                          return rect.minX + matching
                              .map { $0.xPt + $0.type.centerOffsetPt.x }
                              .reduce(0, +) / 2
                      }()
            {
                // DlyStereo: „Filter” jest nagłówkiem wspólnym dla pary LP/HP,
                // a nie podpisem wyłącznie lewego potencjometru.
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: drawY),
                    anchor: .top
                )
            } else if module.typeID == 197,
                      let statusRef = ["Patch Active": 0, "Var. Active": 1, "Voice No.": 2][lbl.text],
                      let conn = ui.outputs.first(where: { $0.codeRef == statusRef })
            {
                // Status: BVerhue XPos nagłówków nie jest wyśrodkowany względem gniazd
                // poniżej — wycentruj każdą etykietę nad jej własnym gniazdem.
                let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
                let centerX = rect.minX + conn.xPt + connHalf
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: drawY),
                    anchor: .top
                )
            } else if module.typeID == 58,
                      ["Dcy", "Lev", "Freq", "Res", "Swp", "Amt", "Click", "Noise"].contains(lbl.text),
                      let knob = ui.knobs
                      .filter({ $0.type.isRotary && $0.yPt > lbl.yPt && $0.yPt - lbl.yPt < 18.0 })
                      .min(by: { abs($0.xPt - lbl.xPt) < abs($1.xPt - lbl.xPt) })
            {
                // Napisy parametrów DrumSynth były przesunięte w lewo względem gałek.
                // Każdy podpis dostaje środek własnego potencjometru, bez zmiany jego Y.
                let centerX = rect.minX + knob.xPt + knob.type.centerOffsetPt.x
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: drawY),
                    anchor: .top
                )
            } else if lbl.text == "KBT", let kbt = kbtOwnButton(ui: ui, label: lbl) {
                // BVerhue zapisuje XPos etykiety jako LEWĄ krawędź napisu w swojej
                // szerokiej czcionce — przy naszej wąskiej „KBT" wypada wyraźnie w lewo
                // od środka własnego przycisku Off/On (LfoA/LfoB/LfoShpA/OscDual, filtry).
                // Wybór przycisku i strony → `kbtOwnButton`.
                let text = Text(lbl.text)
                    .font(.system(size: lbl.fontSize, weight: .regular))
                    .fontWidth(.condensed)
                    .foregroundColor(labelColor)
                switch kbt.placement {
                case let .above(topY):
                    // Odstęp: anchor `.top` + realny prześwit liczony od WIDOCZNEGO dołu liter
                    // (`labelTopClearing`), bo `.bottom` mierzy do dolnej krawędzi line-boxa
                    // SwiftUI i dawał wyraźnie większy widoczny prześwit niż zamierzony.
                    ctx.draw(
                        text,
                        at: CGPoint(x: rect.minX + kbt.button.xPt + kbt.button.widthPt / 2,
                                    y: rect.minY + topY),
                        anchor: .top
                    )
                case .leftOf:
                    // Tuż przy lewej krawędzi przycisku (0.3pt, do 2026-08-20: 0.8pt),
                    // wyśrodkowana na jego wysokości. Przycisk Off/On jest znacznie
                    // szerszy niż napis "On"/"Off" wewnątrz niego (musi pomieścić
                    // dłuższe "Off"), więc nawet przy dosunięciu do PRAWDZIWEJ krawędzi
                    // widżetu zostaje widoczny odstęp do samego tekstu — dosuwamy więc
                    // maksymalnie ciasno do krawędzi, żeby powiązanie było jednoznaczne.
                    ctx.draw(
                        text,
                        at: CGPoint(x: rect.minX + kbt.button.xPt - 0.3,
                                    y: rect.minY + kbt.button.yPt + UIMetrics.buttonFlatHeight / 2),
                        anchor: .trailing
                    )
                }
            } else if module.typeID == 52, lbl.text == "Sustain",
                      let button = ui.buttonsFlat.first(where: { $0.codeRef == 9 })
            {
                // EnvMulti: „Sustain" opisuje przycisk L1/L2/L3/Trg pod sobą, ale nie da
                // się go nad nim wyśrodkować — napis jest szerszy od przycisku, a tuż po
                // prawej stoi ekran wykresu. Wyrównanie PRAWĄ krawędzią do prawej krawędzi
                // przycisku trzyma go w obrębie własnej kontrolki i z dala od ekranu.
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + button.xPt + button.widthPt,
                                y: rect.minY + labelTopClearing(above: button.yPt, label: lbl)),
                    anchor: .topTrailing
                )
            } else if module.typeID == 25, lbl.text == "Shape",
                      let knob = ui.knobs.first(where: { $0.codeRef == 5 })
            {
                // LfoShpA: „Shape" (XPos:119) opisuje gałkę Shape (XPos:121). Tak samo jak
                // przy „KBT" — XPos to lewa krawędź napisu w szerokiej czcionce oryginału,
                // więc przy naszej trzeba wyśrodkować na osi gałki.
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + knob.xPt + knob.type.centerOffsetPt.x, y: drawY),
                    anchor: .top
                )
            } else if module.typeID == 51, lbl.text == "Freq" || lbl.text == "FM Lin" {
                // FltNord: „Freq" opisuje dużą gałkę odcięcia (CodeRef:0, XPos:79),
                // a „FM Lin" parę gniazdo (CodeRef:3, XPos:45) + gałka (CodeRef:7,
                // XPos:59) pod sobą. Oba stały na surowym XPos, czyli wyraźnie w lewo
                // od swoich elementów (XPos to lewa krawędź napisu w szerokiej
                // czcionce oryginału) — „Freq" lądowało obok nazwy modułu,
                // a „FM Lin" dotykało sąsiedniej etykiety „Pitch".
                let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
                let centerX: CGFloat? = if lbl.text == "Freq" {
                    ui.knobs.first { $0.codeRef == 0 }
                        .map { $0.xPt + $0.type.centerOffsetPt.x }
                } else if let socket = (ui.inputs + ui.outputs).first(where: { $0.codeRef == 3 }),
                          let knob = ui.knobs.first(where: { $0.codeRef == 7 })
                {
                    ((socket.xPt + connHalf) + (knob.xPt + knob.type.centerOffsetPt.x)) / 2
                } else {
                    nil
                }
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + (centerX ?? lbl.xPt), y: drawY),
                    anchor: centerX == nil ? .topLeading : .top
                )
            } else if !isBeside, let field = fieldRightOfLabel(ui: ui, label: lbl) {
                // Dosuń napis do ekranu po prawej (patrz `fieldRightOfLabel`). Gałąź musi
                // stać WYSOKO w łańcuchu — niżej przechwytywały te napisy ogólne reguły
                // „nad gniazdem"/„nad grupą" i dosunięcie nigdy nie dochodziło do skutku.
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + field.xPt - 1.0,
                                y: rect.minY + field.yPt + UIMetrics.textFieldHeight / 2),
                    anchor: .trailing
                )
            } else if !isBeside, let field = fieldBelowLabel(ui: ui, label: lbl) {
                // Napis opisujący ekran POD sobą: wyśrodkuj go na ekranie i zostaw
                // prześwit liczony od WIDOCZNEGO dołu liter (dotąd „Shape" w OscShpA/
                // OscB siadał na ekranie i był względem niego przesunięty w lewo).
                // Pozycja ekranu przez `operatorTextFieldFrame` (nie surowy field.yPt) —
                // RndClkA/RndTrig przesuwają tam swój ekran w dół, żeby zrobić miejsce
                // etykiecie („Step"/„Prob" dotykały go inaczej); licząc od surowego
                // źródła prześwit wychodziłby tak, jakby ekran wcale się nie ruszył.
                let frame = operatorTextFieldFrame(module: module, field: field)
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + frame.x + frame.width / 2,
                                y: rect.minY + clampedLabelTop(
                                    labelTopClearing(above: frame.y, label: lbl)
                                )),
                    anchor: .top
                )
            } else if !isBeside, let knob = knobRightOfLabel(ui: ui, label: lbl) {
                // Dosuń napis do gałki po prawej (patrz `knobRightOfLabel`). Wysokość
                // bierzemy Z GAŁKI, nie z własnego YPos etykiety: wtedy wszystkie opisy
                // jednego rzędu siadają równo (Eq3band „Lev" ma w źródle YPos niższy o
                // 7 Gen1px od „Gain"/„Freq", mimo że wszystkie trzy gałki stoją w linii),
                // a napis nie jest już podnoszony przez ogólną regułę „kontrolka pod
                // spodem" (to ona wypychała „Gain" aż na ekran nad nim).
                // …ale nie kosztem wejścia na to, co leży POD napisem: w LfoShpA „Rate"
                // stoi dokładnie nad dwoma gniazdami i przy wysokości wziętej z gałki
                // dotykało ich zejście litery. Sufit liczymy tak jak wszędzie indziej —
                // od widocznego dołu liter, ale WSPÓLNIE dla całego rzędu, żeby opisy
                // sąsiednich gałek stały na jednej linii (patrz `knobRowLabelTopY`).
                let rightX = labelRightEdgeAtKnob(knob)
                let topY = knobRowLabelTopY(ui: ui, label: lbl, knob: knob)
                let text = Text(lbl.text)
                    .font(.system(size: lbl.fontSize, weight: .regular))
                    .fontWidth(.condensed)
                    .foregroundColor(labelColor)
                // Gałka z gniazdem PRZYPIĘTYM do jej lewej krawędzi (w źródle łączy je
                // gruba kreska: LfoB/LfoShpA „Rate", FltNord „Res", FltComb/FltPhase „FB")
                // to jedna kontrolka — napis nad nią opisuje parę, więc siada na środku
                // GNIAZDA, nie przy krawędzi gałki. Mierzymy realną szerokość napisu:
                // wyśrodkowanie ma sens tylko dopóki nie wsuwa liter na gałkę.
                let textWidth = labelWidth(lbl.text, fontSize: lbl.fontSize)
                let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
                // Lewa krawędź TARCZY gałki (nie widżetu — ten jest szerszy o ~1pt).
                let dialLeftX = knob.xPt + knob.type.centerOffsetPt.x - knob.type.radiusPt
                let pairedSocket: BVConnector? = allConnectors.first { conn in
                    let gapToKnob: CGFloat = knob.xPt - (conn.xPt + 2 * connHalf)
                    let centerX: CGFloat = conn.xPt + connHalf
                    return conn.yPt > lbl.yPt + 1.5
                        && gapToKnob >= 0 && gapToKnob < 4.0
                        && centerX + textWidth / 2 <= dialLeftX - 0.3
                }
                if let socket = pairedSocket {
                    ctx.draw(text, at: CGPoint(x: rect.minX + socket.xPt + connHalf, y: rect.minY + topY),
                             anchor: .top)
                } else {
                    ctx.draw(text, at: CGPoint(x: rect.minX + rightX, y: rect.minY + topY), anchor: .topTrailing)
                }
            } else if !isBeside, let selector = selectorBelowLabel(ui: ui, label: lbl) {
                // Napis opisujący ekranik-selektor POD sobą (EnvADDSR „Shape", DelayA
                // „Range", Reverb „Type"): ta sama zasada co przy ekranach tekstowych —
                // wyśrodkuj na ekranie i zostaw prześwit liczony od WIDOCZNEGO dołu
                // liter. Gałąź stoi PO `knobRightOfLabel`, bo w modułach obwiedni opis
                // gałki „A" ma przypadkiem pod sobą ekranik Log/Lin — należy do gałki
                // obok, nie do niego.
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + selector.xPt + selector.widthPt / 2,
                                y: rect.minY + clampedLabelTop(
                                    labelTopClearing(above: selector.yPt, label: lbl)
                                )),
                    anchor: .top
                )
            } else if let arrow = resetArrowLeftOf(ui: ui, label: lbl) {
                // Napis tuż ZA strzałką resetu/wyzwalania (Symbol „Trig 1"): LfoB „Rst",
                // ClkGen „Reset", OscB/OscDual/OscShpA/OscShpB „Sync", liczniki „Clk".
                // W źródle odstęp za grotem jest wymierzony dla szerokiej czcionki
                // oryginału; przy naszej wąskiej napis wygląda na oderwany od strzałki.
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + arrow.xPt + arrow.widthPt + 0.6, y: drawY),
                    anchor: isBeside ? .leading : .topLeading
                )
            } else if module.typeID == 164,
                      let codeRef: Int = {
                          switch lbl.text {
                          case "PW": 11
                          case "Phase": 8
                          case "Sub": 9
                          case "Lvl": lbl.yPt < 20 ? 5 : 7
                          default: nil
                          }
                      }(),
                      let knob = ui.knobs.first(where: { $0.codeRef == codeRef })
            {
                // OscDual: BVerhue zapisuje XPos jako lewą krawędź podpisu, przez co
                // PW, dwa Lvl, Phase i Sub nie licują się z własnymi gałkami. Dwa Lvl
                // rozróżnia ich wiersz — górny opisuje CodeRef 5, dolny CodeRef 7.
                // (PW=11/Phase=8 poprawione 2026-08-11 — pomylone z numerem ID gałki
                // w źródłowym .txt zamiast jej CodeRef, więc centrowały złą gałkę.)
                let centerX = rect.minX + knob.xPt + knob.type.centerOffsetPt.x
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: drawY),
                    anchor: .top
                )
            } else if module.typeID == 8, lbl.text == "Shape", lbl.yPt < 10,
                      let field = ui.textFields.first(where: { $0.masterRef == 6 })
            {
                // OscShpB: opis "Shape" nad ekranem "50%" ma w źródle XPos tuż za
                // sąsiednim wyświetlaczem "+0 +0" po lewej (2px odstępu) — o wiele
                // bliżej NIEWŁAŚCIWEGO ekranu niż własnego, 26px dalej w prawo.
                // Wyrównaj do prawej krawędzi z małym odstępem od WŁASNEGO ekranu.
                // Pionowo: do PODSTAWY obu ekranów LCD (nie do surowego YPos etykiety,
                // które wypadało w połowie ich wysokości) — ten sam punkt odniesienia
                // co pole "50%" po wyrównaniu jego YPos do "+0 +0" w operatorTextFieldFrame.
                let frame = operatorTextFieldFrame(module: module, field: field)
                let baseY = rect.minY + frame.y + UIMetrics.textFieldHeight
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + field.xPt - 1.5, y: baseY),
                    anchor: .bottomTrailing
                )
            } else if module.typeID == 8, lbl.text == "Shape", lbl.yPt >= 10,
                      let input = ui.inputs.first(where: { $0.codeRef == 4 })
            {
                // OscShpB: drugi napis "Shape" (modulacja ShapeMod) opisuje parę
                // gniazdo+gałka (Input CodeRef:4, Knob CodeRef:7) — w źródle miał XPos
                // wsunięty w lewo, pod przycisk "FM Lin" i sąsiednią gałkę FmAmount.
                // Wyśrodkowanie na samej gałce (2026-08-11, pierwsza próba) wypadło
                // za daleko w prawo i weszło na jej obrys — wyśrodkuj na czerwonym
                // gnieździe wejściowym po lewej, tak jak wskazał użytkownik.
                let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
                let centerX = rect.minX + input.xPt + connHalf
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: drawY),
                    anchor: .top
                )
            } else if module.typeID == 196,
                      let codeRef = ["Cent": 1, "Dcy": 5, "Click": 6][lbl.text],
                      let knob = ui.knobs.first(where: { $0.codeRef == codeRef }),
                      let dcyLabel = ui.textLabels.first(where: { $0.text == "Dcy" })
            {
                // OscPerc: źródłowy napis „Cent” ma YPos o 4 px wyżej niż „Dcy” i
                // „Click”, mimo że wszystkie trzy opisują jeden rząd gałek. Zachowaj
                // wiersz Dcy jako wspólną bazę i wyśrodkuj każdy napis na jego gałce.
                // Cały wiersz podnosi się o tyle, ile potrzebuje najciaśniejszy z nich —
                // „Cent” stoi nad gałką Reset/medium, więc musi zrobić miejsce trójkątowi.
                let dcyTextBottom = dcyLabel.yPt + dcyLabel.fontSize
                let dcyShiftUp: CGFloat = dcyTextBottom > PatchLayout.headerH - 1.0 ? 1.0 : 0.0
                let rowY = ["Cent", "Dcy", "Click"]
                    .compactMap { name in ui.textLabels.first { $0.text == name } }
                    .reduce(max(1.5, dcyLabel.yPt - dcyShiftUp)) { acc, l in
                        labelTopClearingResetTriangle(acc, ui: ui, label: l)
                    }
                let commonY = rect.minY + max(0.7, rowY)
                let centerX = rect.minX + knob.xPt + knob.type.centerOffsetPt.x
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: commonY),
                    anchor: .top
                )
            } else if module.typeID == 13,
                      let codeRef = ["Cent": 1, "Decay": 5, "Damp": 6][lbl.text],
                      let knob = ui.knobs.first(where: { $0.codeRef == codeRef }),
                      let decayLabel = ui.textLabels.first(where: { $0.text == "Decay" })
            {
                // OscString: Cent ma w źródle wyższy YPos niż Decay/Damp, mimo że
                // opisuje ten sam wiersz gałek. Wspólną bazą jest Decay; każdy napis
                // centrujemy na gałce odpowiadającej własnemu CodeRef.
                // Wspólny wiersz Cent/Decay/Damp musi zostawić przerwę nad trójkątem
                // resetu Cent. Oryginał ma osobne pozycje Y, ale w naszym większym
                // kroju bez tej korekty dolna część „Cent” dotykała trójkąta.
                let labelGap = 3 * PatchLayout.bverhuePixelScale
                let rowY = ["Cent", "Decay", "Damp"]
                    .compactMap { name in ui.textLabels.first { $0.text == name } }
                    .reduce(decayLabel.yPt - labelGap) { acc, l in
                        labelTopClearingResetTriangle(acc, ui: ui, label: l)
                    }
                let commonY = rect.minY + max(0.7, rowY)
                let centerX = rect.minX + knob.xPt + knob.type.centerOffsetPt.x
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: commonY),
                    anchor: .top
                )
            } else if lbl.text == "Dry/Wet",
                      let dryWetRef = [12: 2, 176: 3, 182: 8][module.typeID],
                      let knob = ui.knobs.first(where: { $0.codeRef == dryWetRef })
            {
                // Reverb (12), DelayA (176) i DlyStereo (182): BVerhue XPos etykiety
                // "Dry/Wet" nie jest wyśrodkowany względem swojej gałki — wycentruj
                // tekst na osi właściwego potencjometru.
                let centerX = rect.minX + knob.xPt + knob.type.centerOffsetPt.x
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: drawY),
                    anchor: .top
                )
            } else if module.typeID == 156, lbl.text == "Note",
                      let field = ui.textFields.first
            {
                // NoteDet: "Note" wyśrodkowane nad wyświetlaczem tekstowym (oś pionowa
                // ekranu), nie na surowym XPos etykiety z BVerhue.
                let centerX = rect.minX + field.xPt + field.widthPt / 2
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: drawY),
                    anchor: .top
                )
            } else if module.typeID == 158, lbl.text == "Time",
                      let field = ui.textFields.first(where: { $0.masterRef == 0 })
            {
                // Glide: "Time" wyśrodkowane nad wyświetlaczem tekstowym (oś pionowa
                // ekranu), nie na surowym XPos etykiety z BVerhue.
                let centerX = rect.minX + field.xPt + field.widthPt / 2
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: drawY),
                    anchor: .top
                )
            } else if module.typeID == 69, lbl.text == "Divider",
                      let field = ui.textFields.first(where: { $0.masterRef == 0 })
            {
                // ClkDiv (Logic): "Divider" wyrównane do prawej krawędzi wyświetlacza
                // LCD poniżej, nie na surowym XPos etykiety z BVerhue (nie licuje się).
                let rightEdge = rect.minX + field.xPt + field.widthPt
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rightEdge, y: drawY),
                    anchor: .topTrailing
                )
            } else if module.typeID == 68,
                      let codeRef = ["Clk Active": 2, "1/96": 0, "1/16": 1, "Sync": 3][lbl.text],
                      let conn = ui.outputs.first(where: { $0.codeRef == codeRef })
            {
                // ClkGen: cztery etykiety opisują pionową kolumnę gniazd Logic po prawej
                // stronie modułu — BVerhue XPos każdej zostawia inny odstęp od własnego
                // gniazda (192/220/222/216 dla gniazda przy stałym 240), co dawało
                // nierówne wyrównanie i "Sync" nachodzące na "1/96". Wyrównaj wszystkie
                // do wspólnej prawej krawędzi tuż przed WŁASNYM gniazdem, wyśrodkowane
                // pionowo na jego środku.
                let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
                let leftEdge = rect.minX + conn.xPt
                let centerY = rect.minY + conn.yPt + connHalf
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: leftEdge - 2.0, y: centerY),
                    anchor: .trailing
                )
            } else if module.typeID == 117, lbl.text == "Mod depth" || lbl.text == "AM",
                      let centerX = {
                          // LevMod: "AM" → wycentruj na gałce CodeRef:1 ("Reset") poniżej.
                          if lbl.text == "AM" {
                              guard let knob = ui.knobs.first(where: { $0.codeRef == 1 }) else { return nil as CGFloat? }
                              return rect.minX + knob.xPt + knob.type.centerOffsetPt.x
                          }
                          // "Mod depth" → wycentruj na środku między gniazdem (CodeRef:2)
                          // i gałką (CodeRef:0) — opisuje oba razem.
                          guard let knob = ui.knobs.first(where: { $0.codeRef == 0 }) else { return nil as CGFloat? }
                          let knobCenter = knob.xPt + knob.type.centerOffsetPt.x
                          guard let conn = ui.inputs.first(where: { $0.codeRef == 2 }) else {
                              return rect.minX + knobCenter
                          }
                          let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
                          let connCenter = conn.xPt + connHalf
                          return rect.minX + (knobCenter + connCenter) / 2
                      }()
            {
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: drawY - 1.0),
                    anchor: .top
                )
            } else if module.typeID == 1, lbl.text == "Velocity",
                      let leftLine = ui.lines.first(where: { $0.id == 14 }),
                      let rightLine = ui.lines.first(where: { $0.id == 13 })
            {
                // Keyboard: "Velocity" siedzi w luce między dwiema natywnymi kreskami
                // BVerhue (ID:14 z lewej, ID:13 z prawej) — wyśrodkuj dokładnie na tej luce
                // zamiast na którymkolwiek z sąsiadujących gniazd (Lin/Exp), inaczej tekst
                // nachodzi na jedną z kresek.
                let gapMinX = leftLine.xPt + leftLine.lengthPt
                let gapMaxX = rightLine.xPt
                let centerX = rect.minX + (gapMinX + gapMaxX) / 2
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: drawY - 2.0),
                    anchor: .top
                )
            } else if let group = aboveConnGroup {
                // Grupowy nagłówek: wycentrowany na środku grupy gniazd
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: group.centerX, y: drawY - 1.0),
                    anchor: .top
                )
                // Podkreślenie pod dolną etykietą (bliżej wiersza gniazd)
                if group.drawLine {
                    let lineY = drawY - 1.0 + lbl.fontSize + 1.0
                    var underline = Path()
                    underline.move(to: CGPoint(x: group.lineMinX, y: lineY))
                    underline.addLine(to: CGPoint(x: group.lineMaxX, y: lineY))
                    ctx.stroke(underline, with: .color(labelColor.opacity(0.6)), lineWidth: 0.5)
                }
            } else if !isBeside, let match = aboveConn {
                // `!isBeside` (2026-08-20): etykieta stojąca OBOK gniazda w swoim wierszu
                // opisuje właśnie je, a nie gniazdo z wiersza NIŻEJ, które przypadkiem ma
                // podobny X. Bez tego warunku „A" w RndPattern wjeżdżało na własne gniazdo:
                // Y brało ze swojego (wiersz górny), a X ze środka gniazda „B" pod spodem.
                // Skan 168 modułów: dotyczy 9 etykiet (In, Rst, Chain, L/R, A, Clk) i w
                // każdej z nich opisywane jest gniazdo obok.
                // Centrowanie poziome na gniazdo — X z canvas; Y oryginalne BVerhue
                var connCenter = connectorCenterForDraw(module: module,
                                                        connIndex: match.idx,
                                                        isOutput: match.isOutput)
                // Nazwy nad wejściami stojącymi przy LEWEJ krawędzi nie mogą być
                // centrowane niezależnie na każdym gnieździe. Krótsze napisy dostawały
                // wtedy mniejszy margines od ramki (np. Operator „AMod”), mimo że
                // wszystkie opisują pionową kolumnę wejść. Wspólna oś prowadząca jest
                // zgodna z XPos:4 z paneli Clavii i obejmuje każdy taki moduł.
                if !match.isOutput, match.conn.xPt <= 2.5 {
                    let leadingX = rect.minX + max(1.5, match.conn.xPt)
                    ctx.draw(
                        Text(lbl.text)
                            .font(.system(size: lbl.fontSize, weight: .regular))
                            .fontWidth(.condensed)
                            .foregroundColor(labelColor),
                        at: CGPoint(x: leadingX, y: drawY - 1.0),
                        anchor: .topLeading
                    )
                    continue
                }
                // Gdy gniazdo leży tuż przy lewej krawędzi modułu (np. LevScaler "Note"
                // nad Input przy XPos:4), wyśrodkowanie na jego środku wypycha tekst na
                // samą krawędź albo poza nią — im dłuższa etykieta, tym gorzej (dotyczy
                // wielu modułów, nie tylko LevScaler). Oszacuj połowę szerokości tekstu
                // (kondensowany font ≈0.52×fontSize na znak) i nie pozwól środkowi zejść
                // poniżej tej połowy + mały margines od ramki modułu.
                let estHalfWidth = 0.52 * lbl.fontSize * CGFloat(lbl.text.count) / 2
                let minCenterX = rect.minX + estHalfWidth + 1.5
                connCenter.x = max(connCenter.x, minCenterX)
                // Podpis lamany na dwa wiersze ma zachowac DOKLADNIE odstepy ze zrodla —
                // wspolny przeswit 1pt podnosil oba jego wiersze ponad pozycje wyliczona
                // przez galaz `keepsCompoundLabelSpacing` (RndPattern „Step/ Prob").
                // "Env" (rodzina modułów obwiedni: EnvADSR/ADR/AHD/Multi) opisuje WŁASNE
                // gniazdo Output tuż pod sobą z wygodnym natywnym odstępem (~5pt BVerhue)
                // — dodatkowy 1pt przeswit tej gałęzi (dostrojony do ciasnych etykiet typu
                // In/Rst/Chain) tylko oddalał napis od gniazda i zbliżał go do ekranu nad nim.
                let clearance: CGFloat = (keepsCompoundLabelSpacing || (lbl.text == "Env" && match.isOutput)) ? 0 : 1.0
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: connCenter.x, y: drawY - clearance),
                    anchor: .top
                )
            } else if let cx = aboveRadioCenterX {
                // Centrowanie na parę buttonów; -1pt offset dla clearance.
                // 2-In/2-Out/Fx-In: "In"/"Bus"/"Out"/"Fx" mają BVerhue YPos:2 (tuż w
                // nagłówku, ~1.1pt), a `drawY` tej gałęzi wewnątrz-nagłówkowej dociska
                // je już do ~0.7pt (kolizja z ButtonRadio poniżej) — dodatkowe -1pt tutaj
                // spycha je NA UJEMNĄ współrzędną (nad górną krawędź modułu = dotyka/
                // przebija ramkę). Mała podłoga (0.3pt, ta sama stała co przy kolizji z
                // kontrolką w gałęzi "wewnątrz nagłówka" wyżej) chroni tylko przed tym
                // przypadkiem — nie może zderzyć osobnych wierszy etykiet, bo uruchamia
                // się wyłącznie gdy wynik i tak wypadłby blisko/poza górną krawędzią.
                let y = max(drawY - 1.0, rect.minY + 0.3)
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: rect.minX + cx, y: y),
                    anchor: .top
                )
            } else if !isBeside, let rightConn = nearbyRightSocket(lbl) {
                // Skrajne prawe gniazdo (patrz komentarz przy nearbyRightSocket) — zamiast
                // surowego XPos (który wypycha tekst poza moduł), kończymy tekst równo z
                // prawą krawędzią tego gniazda.
                let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
                let connRightEdge = rect.minX + rightConn.xPt + 2 * connHalf
                // Jeśli inna etykieta w TYM SAMYM wierszu trafia w aboveConnMatch (rysowana
                // z przesunięciem -1pt), dopasuj się do jej linii; w przeciwnym razie zostaw
                // Y bez zmian (np. Status "Voice No." — żadna etykieta w wierszu tego nie robi,
                // więc zmiana wprowadziłaby NOWĄ niespójność zamiast ją naprawić).
                let rowAligns = ui.textLabels.contains(where: {
                    abs($0.yPt - lbl.yPt) < 1.5 && aboveConnMatch($0) != nil
                })
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: connRightEdge, y: drawY - (rowAligns ? 1.0 : 0.0)),
                    anchor: .topTrailing
                )
            } else if let rightConn = numericLabelOverlappingRightSocket(lbl) {
                // Liczby opisujące gniazda (DXRouter „1” i podobne) kończą się z
                // minimalnym, stałym światłem przed obrysem zamiast go dotykać i są
                // pionowo wyśrodkowane na rzeczywistym środku tego gniazda.
                let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(
                        x: rect.minX + rightConn.xPt - 0.5,
                        y: rect.minY + rightConn.yPt + connHalf
                    ),
                    anchor: .trailing
                )
            } else if !isBeside, let knob = aboveKnobMatch(lbl, ui: ui) {
                // Etykieta nad gałką bez dedykowanej obsługi modułu (np. OscPM/OscA
                // "Cent") — BVerhue zapisuje XPos jako lewą krawędź napisu, nie środek
                // gałki pod nim, więc bez tego tekst wygląda na przesunięty w lewo.
                let centerX = rect.minX + knob.xPt + knob.type.centerOffsetPt.x
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: centerX, y: drawY),
                    anchor: .top
                )
            } else {
                // DelayB (typeID:177): "HP"/"LP" leżą tuż przy swojej gałce —
                // dosuń je odrobinę bliżej (BVerhue XPos zostawia zbyt duży odstęp).
                var startX = rect.minX + lbl.xPt
                if module.typeID == 177, lbl.text == "HP" || lbl.text == "LP" { startX += 2.5 }
                // RndPattern: „A"/„B" opisują gniazda modulacji tej samej kolumny —
                // oba wejścia mają IDENTYCZNY XPos w źródle, ale same etykiety różnią
                // się o pół punktu (BVerhue), więc stały jedna pod drugą niedokładnie.
                // Wymuś wspólny X (mniejszy z dwóch), żeby litery stanęły w jednej osi.
                if module.typeID == 208, lbl.text == "A" || lbl.text == "B",
                   let sharedX = ui.textLabels.filter({ $0.text == "A" || $0.text == "B" })
                   .map(\.xPt).min()
                {
                    startX = rect.minX + sharedX
                }
                ctx.draw(
                    Text(lbl.text)
                        .font(.system(size: lbl.fontSize, weight: .regular))
                        .fontWidth(.condensed)
                        .foregroundColor(labelColor),
                    at: CGPoint(x: startX, y: drawY),
                    anchor: isBeside ? .leading : .topLeading
                )
            }
        }
    }

    // MARK: - BVerhue decorative lines / symbols (live .txt, nie legacy baza)

    /// Moduły rodziny obwiedni z trójkątem "sygnał → gniazdo Env" (dekodowany z
    /// <#Bitmap> — patrz drawBVSymbols) i parą pionowych <#Line> prowadzących do
    /// niego z obu stron. ID linii różni się w każdym pliku BVerhue.
    private static let envJackTriangleLineIDs: [Int: (above: Int, below: Int)] = [
        20: (26, 29), // EnvADSR
        23: (23, 24), // ModADSR
        46: (19, 26), // EnvAHD
        169: (32, 33), // ModAHD
    ]

    /// Geometria lejka "Env" dla jednego modułu: oś (pozioma/pionowa), zakres
    /// wzdłuż osi (`axisStart`...`axisEnd`) i stała współrzędna prostopadła
    /// (`centerAxis`). Cztery moduły z `envJackTriangleLineIDs` mają dedykowaną
    /// parę linii BVerhue; reszta liczy wprost z pozycji gniazd Audio In/Out
    /// (orientacja pozioma gdy gniazda mają tę samą Y, pionowa gdy tę samą X).
    private func envJackFunnelGeometry(
        module: G2Module, ui: ModuleUIDef, rect: CGRect
    ) -> (horizontal: Bool, axisStart: CGFloat, axisEnd: CGFloat, centerAxis: CGFloat, thickness: CGFloat)? {
        if let envTri = Self.envJackTriangleLineIDs[module.typeID],
           let lineAbove = ui.lines.first(where: { $0.id == envTri.above }),
           let lineBelow = ui.lines.first(where: { $0.id == envTri.below })
        {
            return (
                horizontal: false,
                axisStart: rect.minY + lineAbove.yPt,
                axisEnd: rect.minY + lineBelow.yPt + lineBelow.lengthPt,
                centerAxis: rect.minX + lineAbove.xPt,
                thickness: lineAbove.isThick ? 1.0 : 0.5
            )
        }
        let horizontalFunnelModules: Set = [41, 52, 55, 119] // EnvH, EnvMulti, EnvD, EnvADDSR
        let verticalFunnelModules: Set = [84, 115] // EnvADR, LevScaler
        guard horizontalFunnelModules.contains(module.typeID) || verticalFunnelModules.contains(module.typeID),
              let audioIn = ui.inputs.first(where: { $0.signalType == .audio }),
              let audioOut = ui.outputs.first(where: { $0.signalType == .audio })
        else { return nil }
        let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
        let side = connHalf * 2
        if horizontalFunnelModules.contains(module.typeID) {
            return (
                horizontal: true,
                axisStart: rect.minX + audioIn.xPt + side,
                axisEnd: rect.minX + audioOut.xPt,
                centerAxis: rect.minY + audioIn.yPt + connHalf,
                thickness: 0.5
            )
        }
        return (
            horizontal: false,
            axisStart: rect.minY + audioIn.yPt + side,
            axisEnd: rect.minY + audioOut.yPt,
            centerAxis: rect.minX + audioIn.xPt + connHalf,
            thickness: 0.5
        )
    }

    /// Rysuje lejek (odcinek → równoboczny trójkąt (tylko kontur) → odcinek).
    /// Trójkąt jest OBRYSOWANY, nie wypełniony — środek zostaje pusty (tło modułu).
    /// Żeby łączące odcinki nie tylko DOTYKAŁY wierzchołków trójkąta (co przy
    /// osobnych ścieżkach dawało niewielką, ale widoczną szczelinę na złączu —
    /// zgłoszone przez użytkownika), każdy odcinek wchodzi w trójkąt o `overlap`
    /// (pół grubości linii) zamiast kończyć się dokładnie na jego krawędzi/wierzchołku.
    /// Rozmiar trójkąta jest STAŁY (`side` = pełna średnica gniazda) — ten sam
    /// niezależnie od orientacji czy modułu.
    private func drawEnvJackFunnel(_ ctx: GraphicsContext, horizontal: Bool,
                                   axisStart: CGFloat, axisEnd: CGFloat, centerAxis: CGFloat,
                                   thickness: CGFloat)
    {
        let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
        let side = connHalf * 2
        let triDepth = side * CGFloat(3.0.squareRoot()) / 2.0 // równoboczny: wszystkie boki = side
        let gap = axisEnd - axisStart
        let capAxis = axisStart + (gap - triDepth) / 2
        let tipAxis = capAxis + triDepth
        let overlap = thickness / 2

        func pt(_ axis: CGFloat, _ cross: CGFloat) -> CGPoint {
            horizontal ? CGPoint(x: axis, y: cross) : CGPoint(x: cross, y: axis)
        }

        var lineIn = Path()
        lineIn.move(to: pt(axisStart, centerAxis))
        lineIn.addLine(to: pt(capAxis + overlap, centerAxis))
        ctx.stroke(lineIn, with: .color(UIColor.knobOuter),
                   style: StrokeStyle(lineWidth: thickness, lineCap: .butt))

        var lineOut = Path()
        lineOut.move(to: pt(tipAxis - overlap, centerAxis))
        lineOut.addLine(to: pt(axisEnd, centerAxis))
        ctx.stroke(lineOut, with: .color(UIColor.knobOuter),
                   style: StrokeStyle(lineWidth: thickness, lineCap: .butt))

        var tri = Path()
        tri.move(to: pt(capAxis, centerAxis - side / 2))
        tri.addLine(to: pt(capAxis, centerAxis + side / 2))
        tri.addLine(to: pt(tipAxis, centerAxis))
        tri.closeSubpath()
        ctx.stroke(tri, with: .color(UIColor.knobOuter),
                   style: StrokeStyle(lineWidth: thickness, lineJoin: .miter))
    }

    /// Vocoder ma jedną wspólną instalację przewodów: 16 pionów przechodzi
    /// za ekranem i przyciskami, a dolna magistrala leży dokładnie na końcach
    /// linii wychodzących z przycisków minus. Osobna geometria usuwa rozjazd
    /// wynikający z tego, że współczesne przyciski mają inną wysokość niż Gen1.
    private func drawVocoderRoutingLines(_ ctx: GraphicsContext,
                                         module: G2Module,
                                         ui: ModuleUIDef,
                                         rect: CGRect)
    {
        let buttons = ui.incDecButtons.sorted { $0.codeRef < $1.codeRef }
        guard buttons.count == 16 else { return }

        let sourceScale = PatchLayout.bverhuePixelScale
        let buttonSide = UIMetrics.incDecHeight
        let buttonGap = UIMetrics.incDecGap
        let totalButtonHeight = 2 * buttonSide + buttonGap
        let centers = buttons.map { button -> CGFloat in
            let origin = operatorIncDecOrigin(module: module, button: button)
            return rect.minX + origin.x + buttonSide / 2
        }
        let firstOrigin = operatorIncDecOrigin(module: module, button: buttons[0])
        let buttonY = min(
            rect.minY + firstOrigin.y,
            rect.maxY - 1.0 - totalButtonHeight
        )
        let routingGap = 2 * sourceScale
        let bottomBusY = buttonY + totalButtonHeight + routingGap
        let topBusY = rect.minY + 23 * sourceScale
        let branchX = rect.minX + 26 * sourceScale

        let connectorSourceHalf = 5.5 * sourceScale
        let connectorSourceSide = 2 * connectorSourceHalf
        let bottomInput = ui.inputs.first(where: { $0.codeRef == 1 })
        let bottomOutput = ui.outputs.first(where: { $0.codeRef == 0 })
        let boxCenterX: CGFloat
        if let bottomInput, let bottomOutput {
            let leftEdge = rect.minX + bottomInput.xPt + connectorSourceSide
            let rightEdge = rect.minX + bottomOutput.xPt
            boxCenterX = (leftEdge + rightEdge) / 2
        } else {
            boxCenterX = rect.minX + 229 * sourceScale
        }

        var routing = Path()
        for centerX in centers {
            routing.move(to: CGPoint(x: centerX, y: topBusY))
            routing.addLine(to: CGPoint(x: centerX, y: bottomBusY))
        }
        routing.move(to: CGPoint(x: branchX, y: topBusY))
        routing.addLine(to: CGPoint(x: centers.last!, y: topBusY))
        routing.move(to: CGPoint(x: centers[0], y: bottomBusY))
        routing.addLine(to: CGPoint(x: boxCenterX, y: bottomBusY))

        if let controlIndex = ui.inputs.firstIndex(where: { $0.codeRef == 0 }) {
            let controlCenter = connectorCenterForDraw(
                module: module,
                connIndex: controlIndex,
                isOutput: false
            )
            routing.move(to: CGPoint(
                x: controlCenter.x + UIMetrics.connectorHalf + UIMetrics.socketOuterMargin,
                y: controlCenter.y
            ))
            routing.addLine(to: CGPoint(x: branchX, y: controlCenter.y))
            routing.addLine(to: CGPoint(x: branchX, y: topBusY))
        }

        if let bottomInput {
            let boxCenterY = rect.minY + bottomInput.yPt + connectorSourceHalf
            let squareSide = connectorSourceSide * 0.8
            routing.move(to: CGPoint(x: boxCenterX, y: bottomBusY))
            routing.addLine(to: CGPoint(x: boxCenterX, y: boxCenterY - squareSide / 2))
        }

        ctx.stroke(
            routing,
            with: .color(UIColor.knobOuter),
            style: StrokeStyle(lineWidth: 0.5, lineCap: .butt, lineJoin: .miter)
        )
    }

    /// Zewnętrzne obrysy gniazd i przycisków Power razem z ich ciemną obwódką — obszar,
    /// w który nie wchodzą linie panelu. `round` = wejście (koło); reszta to zaokrąglone kwadraty.
    private func socketRims(module: G2Module, ui: ModuleUIDef, rect: CGRect) -> [(box: CGRect, round: Bool)] {
        let margin = UIMetrics.socketOuterMargin
        let half = UIMetrics.connectorHalf + margin
        var rims: [(box: CGRect, round: Bool)] = []
        for isOutput in [false, true] {
            for i in (isOutput ? ui.outputs : ui.inputs).indices {
                let c = connectorCenterForDraw(module: module, connIndex: i, isOutput: isOutput)
                rims.append((CGRect(x: c.x - half, y: c.y - half, width: half * 2, height: half * 2), !isOutput))
            }
        }
        let names = moduleDefinition(module.typeID)?.paramNames ?? []
        for btn in ui.buttonsText where names.indices.contains(btn.codeRef) && names[btn.codeRef] == "Active" {
            let box = powerButtonRect(module: module, button: btn, ui: ui, rect: rect)
            rims.append((box.insetBy(dx: -margin, dy: -margin), false))
        }
        return rims
    }

    /// Rysuje elementy <#Line> z plików BVerhue — np. "schodek" łączący gałkę
    /// z podkreśleniem grupy radio-buttonów (OscB: Shape → ostatnie 2 fale).
    func drawBVLines(_ ctx: GraphicsContext, module: G2Module, rect: CGRect) {
        guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { return }
        guard !ui.lines.isEmpty else { return }
        // Obwódka gniazd i przycisku Power jest półprzezroczysta, więc linia wchodząca
        // pod nią prześwitywała (uwaga użytkownika 2026-09-27, FreqShift). Linie
        // kończą się na zewnętrznej krawędzi obwódki.
        let rims = socketRims(module: module, ui: ui, rect: rect)
        var ctx = ctx
        var rimsPath = Path()
        let rimCorner = UIMetrics.socketCornerRadius + UIMetrics.socketOuterMargin
        for rim in rims {
            if rim.round {
                rimsPath.addEllipse(in: rim.box)
            } else {
                rimsPath.addRoundedRect(in: rim.box, cornerSize: CGSize(width: rimCorner, height: rimCorner))
            }
        }
        ctx.clip(to: rimsPath, options: .inverse)
        // Pełny, kryjący szary — bez przezroczystości (decorativeLine ma opacity
        // 0.5 i brunatny odcień, niedopasowany do tej grafiki). Ten sam odcień co
        // ciemny obrys gałek (knobOuter), żeby linia wizualnie "pasowała" do gałek.
        let lineColor = UIColor.knobOuter

        if module.typeID == 108 {
            drawVocoderRoutingLines(ctx, module: module, ui: ui, rect: rect)
            return
        }

        // ModAmt (typeID:195) / LevMod (typeID:117): linie łączące gniazdo Mod
        // z trójkątem Amplifier rysujemy w całości w drawBVSymbols (razem z
        // trójkątem, bo ich geometria musi być wzajemnie zsynchronizowana —
        // patrz tam). Pozostałe linie tych modułów (np. podkreślenie pod gałką
        // "Mod depth") rysujemy tu normalnie.
        let excludedLineIDs: Set<Int> = if let envTri = Self.envJackTriangleLineIDs[module.typeID] {
            // Rodzina obwiedni z trójkątem "Env" (patrz drawBVSymbols niżej) — te
            // dwie linie kończą się na krawędziach trójkąta, nie rysują się same.
            [envTri.above, envTri.below]
        } else {
            switch module.typeID {
            case 195: [8, 9] // ModAmt: linie do trójkąta Amplifier rysowane w drawBVSymbols
            case 117: [5, 15] // LevMod: jw.
            case 112: [4, 8] // LevAdd: przewody przy kole „+" rysowane razem z symbolem
            case 50, 188: [7] // ConstSw: routing Bitmap ID 4 rysowany niżej jako jeden wektor
            // SeqNote: kreski obrysowujące siatkę nut i pasek lupki. Siatka ma własną
            // ramkę, a kreski biegły przez pół panelu (jedna aż do rzędu ▲/▼)
            // i czytały się jak przypadkowe linie, nie jak obrys. ID 97 to łącznik
            // ekranu nuty z klawiaturą (ID 20 i 97), ID 19 zostawiał ogonek przy
            // pierwszej kolumnie.
            case 121: [19, 20, 97, 99, 100, 102]
            case 81: [4] // LevAmp: magistrala kończy się na pionowym łączniku trójkąta
            // OscString: pięć odcinków ramki tworzy rozgałęziony układ. Ogólny
            // algorytm łączenia linii traktował go jak jedną ścieżkę i wydłużał
            // lewą krawędź kwadratu oraz przewód wejściowy do jego wnętrza.
            case 13: [13, 14, 17, 18, 19, 26]
            // Compress: dwa kwadraty komórek Gain Reduction (L/R), każdy z 4 osobnych
            // linii tworzących ZAMKNIĘTĄ pętlę — generyczny algorytm buduje z nich
            // jeden ŁAŃCUCH, ale nigdy nie zamyka go z powrotem do punktu startowego
            // (ten sam problem co OscString wyżej), więc jedna krawędź wystawała.
            // Rysowane osobno niżej jako właściwy prostokąt (Path(CGRect), który
            // domyka się sam) — patrz "Compress" po bloku OscString.
            case 150: [42, 48, 50, 51, 55, 56, 57, 58]
            // DrumSynth: elementy 22/28 nie wyznaczają grup parametrów. Na skalowanym
            // panelu zaczynały się tuż pod LCD i były widoczne jako samotna kropka.
            case 58: [22, 28]
            default: []
            }
        }
        // Sekwencery: magistrale rzędu ▲/▼ i rzędu przycisków kroku rysujemy jako
        // dwie proste linie (`drawFaderBusLines` niżej). W źródle są „schodkami",
        // które omijają elementy o rozmiarach oryginalnego panelu — przy naszych
        // proporcjach schodek nie ma czego omijać i wygląda jak usterka.
        let busRows = sequencerBusRowsYPt(module: module, ui: ui, rect: rect)
        let bvLines = ui.lines.filter { line in
            !excludedLineIDs.contains(line.id) && !isSequencerBusLine(line, rows: busRows)
        }

        struct Seg { let a: CGPoint
            let b: CGPoint
            let thickness: CGFloat
        }
        // DlyStereo (typeID:182): linia 29 (poziomy "schodek" L→R) w BVerhue kończy się
        // 1 Gen1px (≈0.55pt) za linią 27 (pionowy podział sekcji Filter/Dry-Wet) —
        // niewidoczne na rastrze oryginału, ale w naszej kreślonej linii wystaje jako
        // mały "wąs" przez pionową kreskę. Utnij ją dokładnie na X linii 27.
        let line27X = ui.lines.first(where: { $0.id == 27 })?.xPt
        let segs: [Seg] = bvLines.map { line in
            // Kreska między dwoma opisami siada w osi ich wielkich liter. BVerhue
            // zapisuje YPos wymierzony dla wyższej czcionki oryginału, przez co u nas
            // przechodziła przez górną krawędź liter zamiast przez ich środek.
            let lineY = labelLeftOfLine(line, ui: ui)
                .map { labelCapCenterY(ui: ui, label: $0) } ?? line.yPt
            var a = CGPoint(x: rect.minX + line.xPt, y: rect.minY + lineY)
            var b = line.isHorizontal
                ? CGPoint(x: a.x + line.lengthPt, y: a.y)
                : CGPoint(x: a.x, y: a.y + line.lengthPt)
            if module.typeID == 182, line.id == 29, let clipX = line27X {
                b.x = min(b.x, rect.minX + clipX)
            }
            // Linia dochodząca do gniazda albo Power trafia w jego oś. BVerhue podaje
            // lewą (górną) krawędź piksela linii, a środek elementu wypada pół piksela
            // dalej — przewód nad Power w FreqShift stał obok osi (uwaga 2026-09-27).
            let lo = CGPoint(x: min(a.x, b.x), y: min(a.y, b.y))
            let hi = CGPoint(x: max(a.x, b.x), y: max(a.y, b.y))
            if let rim = rims.first(where: { rim in
                line.isHorizontal
                    ? abs(rim.box.midY - a.y) < 0.8 && hi.x >= rim.box.minX - 1 && lo.x <= rim.box.maxX + 1
                    : abs(rim.box.midX - a.x) < 0.8 && hi.y >= rim.box.minY - 1 && lo.y <= rim.box.maxY + 1
            }) {
                if line.isHorizontal { a.y = rim.box.midY
                    b.y = rim.box.midY
                } else { a.x = rim.box.midX
                    b.x = rim.box.midX
                }
            }
            return Seg(a: a, b: b, thickness: line.isThick ? 1.0 : 0.5)
        }

        // Segmenty typu "schodek" (np. gałka Shape → podkreślenie radio-buttonów)
        // to w BVerhue kilka osobnych <#Line>, które mają się stykać końcami.
        // Rysowanie ich jako niezależnych, "podbitych" prostokątów dawało albo
        // szczelinę w rogu, albo (po podbiciu) krzyżujące się nadlapki. Właściwe
        // rozwiązanie: złącz segmenty o wspólnych końcach (tolerancja 2pt) w JEDNĄ
        // ścieżkę i narysuj ją z miter-joinami — narożnik wychodzi idealnie ostry,
        // bez przecinania się i bez szczeliny.
        func closeEnough(_ p: CGPoint, _ q: CGPoint) -> Bool {
            abs(p.x - q.x) < 2.0 && abs(p.y - q.y) < 2.0
        }

        var used = Set<Int>()
        var chains: [(points: [CGPoint], thickness: CGFloat)] = []
        for i in segs.indices where !used.contains(i) {
            used.insert(i)
            var points = [segs[i].a, segs[i].b]
            var extended = true
            while extended {
                extended = false
                for j in segs.indices where !used.contains(j) {
                    if closeEnough(points.last!, segs[j].a) {
                        points.append(segs[j].b)
                        used.insert(j)
                        extended = true
                    } else if closeEnough(points.last!, segs[j].b) {
                        points.append(segs[j].a)
                        used.insert(j)
                        extended = true
                    } else if closeEnough(points[0], segs[j].a) {
                        points.insert(segs[j].b, at: 0)
                        used.insert(j)
                        extended = true
                    } else if closeEnough(points[0], segs[j].b) {
                        points.insert(segs[j].a, at: 0)
                        used.insert(j)
                        extended = true
                    }
                }
            }
            chains.append((points: points, thickness: segs[i].thickness))
        }

        // Punkty końcowe sąsiednich odcinków z BVerhue rzadko są piksel-w-piksel
        // identyczne (zaokrąglenia przy konwersji Gen1→pt) — łączenie ich
        // bezpośrednio dawało mikroskopijną przekątną w narożniku ("zjazd" widoczny
        // po powiększeniu). Każdy WEWNĘTRZNY punkt (czyli narożnik, nie prawdziwy
        // koniec linii) przeliczamy na dokładne przecięcie: oś, na której leżał
        // poprzedni (już skorygowany) odcinek, × oś następnego — realny kąt 90°.
        for chain in chains {
            guard chain.points.count >= 2 else { continue }
            var corrected = [chain.points[0]]
            for i in 1 ..< chain.points.count - 1 {
                let prev = corrected[i - 1]
                let raw = chain.points[i]
                let next = chain.points[i + 1]
                let isPrevHorizontal = abs(raw.x - prev.x) > abs(raw.y - prev.y)
                corrected.append(isPrevHorizontal
                    ? CGPoint(x: next.x, y: prev.y)
                    : CGPoint(x: prev.x, y: next.y))
            }
            if chain.points.count > 1 { corrected.append(chain.points[chain.points.count - 1]) }

            // OscB (typeID:7): górny odcinek "schodka" od gałki Shape ma podkreślać
            // dwa ostatnie przyciski wyboru fali, ale jego BVerhue Length kończy go
            // w połowie 4. przycisku — dociągnij do prawej krawędzi grupy radio.
            // WARUNEK count > 2: to musi być prawdziwy, wieloodcinkowy "schodek"
            // (po scaleniu segmentów) — inaczej trafiały w to także osobne, proste
            // 2-punktowe podkreślenia pod innymi gałkami (np. pod FM-Lin mod),
            // które przypadkiem są poziome i kończyły się rozciągnięte do tego
            // samego punktu, tworząc jedną fałszywą długą linię.
            if module.typeID == 7, corrected.count > 2,
               let waveRadio = ui.buttonsRadio.first(where: { $0.codeRef == 8 })
            {
                // -1pt marginesu — żeby linia kończyła się tuż przy krawędzi
                // ostatniego przycisku, a nie idealnie na niej (gdzie .square/zoom
                // antyaliasing dawał wrażenie dotykania ramki modułu).
                let groupRight = rect.minX + waveRadio.xPt
                    + CGFloat(waveRadio.buttonCount) * waveRadio.buttonWidthPt - 1.0
                let last = corrected.count - 1
                if abs(corrected[last].y - corrected[last - 1].y) < 0.5, corrected[last].x < groupRight {
                    corrected[last].x = groupRight
                }
            }

            var path = Path()
            path.move(to: corrected[0])
            for p in corrected.dropFirst() {
                path.addLine(to: p)
            }
            // .butt (nie .square) na wolnych końcach — .square dorzuca pół grubości
            // linii ZA punktem końcowym, co przy dosuniętym do krawędzi modułu
            // ostatnim punkcie (patrz wydłużenie do groupRight wyżej) realnie
            // wystawało poza moduł / dotykało ramki.
            ctx.stroke(path, with: .color(lineColor),
                       style: StrokeStyle(lineWidth: chain.thickness, lineCap: .butt, lineJoin: .miter))
        }

        if module.typeID == 13,
           let audioIn = ui.inputs.first(where: { $0.codeRef == 0 }),
           let audioOut = ui.outputs.first(where: { $0.codeRef == 0 })
        {
            // OscString: oryginalny panel ma prosty kwadrat 10×10 px między
            // wejściem i wyjściem. Rysujemy osobno ramkę i dwa przewody, aby każdy
            // dochodził dokładnie do zewnętrznej krawędzi gniazda/kwadratu.
            let scale = PatchLayout.bverhuePixelScale
            let connHalf: CGFloat = 5.5 * scale
            let connSide = connHalf * 2
            let box = CGRect(x: rect.minX + 240 * scale, y: rect.minY + 17 * scale,
                             width: 10 * scale, height: 10 * scale)
            let wireX = rect.minX + audioIn.xPt + connHalf
            let inputBottom = rect.minY + audioIn.yPt + connSide
            let outputTop = rect.minY + audioOut.yPt

            var wires = Path()
            wires.move(to: CGPoint(x: wireX, y: inputBottom))
            wires.addLine(to: CGPoint(x: wireX, y: box.minY))
            wires.move(to: CGPoint(x: wireX, y: box.maxY))
            wires.addLine(to: CGPoint(x: wireX, y: outputTop))
            ctx.stroke(wires, with: .color(lineColor),
                       style: StrokeStyle(lineWidth: 0.5, lineCap: .butt))
            ctx.stroke(Path(box), with: .color(lineColor),
                       style: StrokeStyle(lineWidth: 0.5, lineJoin: .miter))
        }

        // Compress (typeID:150): dwie kwadratowe komórki Gain Reduction. Powstają
        // ręcznie, bo linie panelu tworzą zamknięte pętle, których nie składa renderer.
        // Pozycję wyprowadzamy z rzeczywistych gniazd, aby środek każdego kwadratu
        // pozostawał dokładnie pomiędzy odpowiadającym wejściem i wyjściem.
        if module.typeID == 150 {
            let scale = PatchLayout.bverhuePixelScale
            let connectorSide: CGFloat = 11 * scale
            let boxSide: CGFloat = 10 * scale
            let inputByCode = Dictionary(uniqueKeysWithValues: ui.inputs.map { ($0.codeRef, $0) })
            let outputByCode = Dictionary(uniqueKeysWithValues: ui.outputs.map { ($0.codeRef, $0) })
            for codeRef in [0, 1] {
                guard let input = inputByCode[codeRef], let output = outputByCode[codeRef] else { continue }
                let centerX = rect.minX + input.xPt + connectorSide / 2
                let inputBottom = rect.minY + input.yPt + connectorSide
                let outputTop = rect.minY + output.yPt
                let centerY = (inputBottom + outputTop) / 2
                let box = CGRect(x: centerX - boxSide / 2, y: centerY - boxSide / 2,
                                 width: boxSide, height: boxSide)
                ctx.stroke(Path(box), with: .color(lineColor),
                           style: StrokeStyle(lineWidth: 0.5, lineJoin: .miter))
            }
        }
    }

    /// Kształt strzałki "Trig 1" — ostry szczyt, płaska pozioma podstawa trójkąta,
    /// prostokątny trzon. Wydzielone jako osobna funkcja, bo "Trig 2" to ta sama
    /// strzałka z dodatkową poziomą "czapką" nad nią. Wcześniejsza wersja próbowała
    /// odwzorować zaokrągloną kopułę z referencji piksel-po-pikselu, ale przy
    /// rzeczywistym (bardzo małym) rozmiarze renderowania krzywe gubiły ostrość i
    /// wyglądały jak plamka zamiast strzałki — prosty trójkąt czyta się lepiej
    /// w tej skali, zgodnie z oceną użytkownika.
    private func trigArrowPath(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> Path {
        let headH = min(h, w * 1.6)
        var path = Path()
        path.move(to: CGPoint(x: x + w / 2, y: y))
        path.addLine(to: CGPoint(x: x + w, y: y + headH))
        path.addLine(to: CGPoint(x: x, y: y + headH))
        path.closeSubpath()
        let shaftW = max(0.5, w * 0.3)
        path.addRect(CGRect(x: x + (w - shaftW) / 2, y: y + headH,
                            width: shaftW, height: max(0, h - headH)))
        return path
    }

    /// Sekwencery: opis stojący PRZED kontrolką, którą nazywa („XFade" przed
    /// przyciskiem, „Park" przed diodą). BVerhue rozstawia je z zapasem wymierzonym
    /// dla wyższego panelu oryginału i na własnym YPos, więc napis wisiał obok
    /// kontrolki zamiast na jej osi. Zwraca lewą krawędź kontrolki i jej oś.
    private func sequencerLabelTarget(_ lbl: BVTextLabel, ui: ModuleUIDef)
        -> (leftEdge: CGFloat, centerY: CGFloat)?
    {
        guard lbl.xPt > 20, lbl.yPt < PatchLayout.headerH else { return nil }
        // Kontrolka musi stać TUŻ za napisem — inaczej to nie jest jego opis, tylko
        // przypadkowy element gdzieś dalej w rzędzie (np. „Rec" i dioda „Park"
        // na drugim końcu panelu).
        let reach: CGFloat = 16.0
        let labelRight = lbl.xPt + labelWidth(lbl.text, fontSize: lbl.fontSize)
        var best: (leftEdge: CGFloat, centerY: CGFloat)?
        func consider(_ x: CGFloat, _ y: CGFloat, _ height: CGFloat) {
            guard x > lbl.xPt, x - labelRight < reach,
                  abs(y + height / 2 - (lbl.yPt + 2.5)) < 5.0 else { return }
            if best == nil || x < best!.leftEdge { best = (x, y + height / 2) }
        }
        for button in ui.buttonsFlat {
            consider(button.xPt, button.yPt, UIMetrics.buttonFlatHeight)
        }
        for led in ui.leds where led.type == .green {
            consider(led.xPt, led.yPt, UIMetrics.ledGreenSize)
        }
        return best
    }

    /// Sekwencery: strzałka „park" stoi w źródle PRZED swoim gniazdem, mimo że
    /// razem z napisem „Park" po prawej stronie opisuje to samo wejście — czytała
    /// się więc jak opis sąsiedniego ekranu. Przenosimy ją między gniazdo a napis
    /// i odsuwamy sam napis o jej szerokość.
    private func parkArrowLayout(module: G2Module, ui: ModuleUIDef)
        -> (symbolID: Int, symbolX: CGFloat, labelX: CGFloat, socketCenterY: CGFloat)?
    {
        guard [121, 144, 145, 146, 154].contains(module.typeID),
              let label = ui.textLabels.first(where: { $0.text == "Park" }),
              let sym = ui.symbols.first(where: { $0.type == "Trig 1" && $0.xPt < label.xPt
                      && $0.yPt < PatchLayout.headerH
              }),
              let socket = ui.inputs.first(where: { $0.xPt > sym.xPt && $0.xPt < label.xPt })
        else { return nil }

        let connHalf: CGFloat = 5.5 * PatchLayout.bverhuePixelScale
        let socketRight = socket.xPt + connHalf + UIMetrics.connectorHalf + UIMetrics.socketOuterMargin
        let gap: CGFloat = 0.6
        let symbolX = socketRight + gap
        return (sym.id, symbolX, symbolX + sym.widthPt + gap, socket.yPt + connHalf)
    }

    /// Referencyjny fader modułu — pierwszy tor w kolejności X. `nil` dla modułów
    /// bez faderów.
    private func referenceFader(module: G2Module, ui: ModuleUIDef, rect: CGRect)
        -> FaderLayout?
    {
        guard let knob = ui.knobs
            .filter({ $0.type == .slider || $0.type == .seqSlider })
            .min(by: { $0.xPt < $1.xPt })
        else { return nil }
        return faderLayout(module: module, knob: knob, ui: ui, rect: rect)
    }

    /// Osie magistral sekwencera w układzie panelu: rząd pary ▲/▼ (gdy moduł ma
    /// fadery) i każdy rząd przycisków bez etykiet. SeqEvent ma dwa takie rzędy
    /// i wcale nie ma faderów.
    private func sequencerBusRowsYPt(module: G2Module, ui: ModuleUIDef, rect: CGRect)
        -> [(center: CGFloat, halfHeight: CGFloat)]
    {
        // WYŁĄCZNIE sekwencery. Przyciski bez etykiet i pionowe pary „+/−" mają też
        // moduły, które żadnej magistrali nie mają (Operator, LevScaler, FltPhase,
        // Digitizer, nadajniki MIDI) — bez tego warunku dostawały linię przez cały panel.
        guard [121, 144, 145, 146, 154].contains(module.typeID) else { return [] }
        var rows: [(center: CGFloat, halfHeight: CGFloat)] = []
        if let fader = referenceFader(module: module, ui: ui, rect: rect) {
            let center = (fader.up.minY + fader.down.maxY) / 2 - rect.minY
            rows.append((center, (fader.down.maxY - fader.up.minY) / 2))
        }
        let stepRows = Set(ui.buttonsText
            .filter(\.text.isEmpty)
            .map { ($0.yPt * 10).rounded() / 10 })
        rows.append(contentsOf: stepRows.map {
            ($0 + UIMetrics.buttonTextHeight / 2, UIMetrics.buttonTextHeight / 2)
        })
        // SeqVal: rząd pionowych par „+/−" ma własną magistralę.
        let pairHeight = 2 * UIMetrics.incDecHeight + UIMetrics.incDecGap
        let incRows = Set(ui.incDecButtons.filter(\.isVertical).map { button -> CGFloat in
            let origin = operatorIncDecOrigin(module: module, button: button)
            return ((origin.y + pairHeight / 2) * 10).rounded() / 10
        })
        rows.append(contentsOf: incRows.map { ($0, pairHeight / 2) })
        return rows
    }

    /// Linie źródłowe należące do magistrali — zastępujemy je jedną prostą.
    /// Poza samą magistralą to także krótkie odcinki „schodka", którym źródło
    /// podchodziło do rzędu: poziome na wysokości KRAWĘDZI przycisków (nie osi)
    /// i pionowe haczyki na końcach. Przy prostej magistrali zostają jako
    /// sterczące kreski obok skrajnych przycisków.
    private func isSequencerBusLine(
        _ line: BVLine, rows: [(center: CGFloat, halfHeight: CGFloat)]
    ) -> Bool {
        guard !rows.isEmpty else { return false }
        if line.isHorizontal {
            return rows.contains { abs(line.yPt - $0.center) < $0.halfHeight + 1.5 }
        }
        guard line.lengthPt < 8.0 else { return false }
        let top = line.yPt, bottom = line.yPt + line.lengthPt
        return rows.contains { $0.center > top - 2.0 && $0.center < bottom + 2.0 }
    }

    /// Dwie poziome magistrale sekwencera: jedna przez oś pary ▲/▼, druga przez oś
    /// rzędu przycisków kroku. Obie biegną od gniazda przy lewej krawędzi panelu do
    /// gniazda przy prawej i są rysowane PRZED widżetami, więc przyciski je zasłaniają
    /// — widać tylko odcinki między nimi, dokładnie jak na oryginalnym panelu.
    func drawFaderBusLines(_ ctx: GraphicsContext, module: G2Module, rect: CGRect) {
        guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { return }
        let rows = sequencerBusRowsYPt(module: module, ui: ui, rect: rect)
        guard !rows.isEmpty else { return }

        let connHalf: CGFloat = 5.5 * PatchLayout.bverhuePixelScale
        let conns = ui.inputs + ui.outputs

        /// Returns the socket centers that bound a bus on the requested row.
        func busSpan(at centerY: CGFloat) -> (from: CGFloat, to: CGFloat)? {
            let row = conns
                .filter { abs(rect.minY + $0.yPt + connHalf - centerY) < 4.0 }
                .sorted { $0.xPt < $1.xPt }
            guard let first = row.first, let last = row.last,
                  last.xPt - first.xPt > 1
            else { return nil }

            // SeqEvent has two inputs on the left of each bus. Starting at the
            // outer input incorrectly draws a visible segment between the sockets.
            let left = module.typeID == 144 && row.count >= 3 ? row[1] : first
            return (rect.minX + left.xPt + connHalf,
                    rect.minX + last.xPt + connHalf)
        }

        var path = Path()
        for row in rows {
            let y = rect.minY + row.center
            guard let span = busSpan(at: y) else { continue }
            path.move(to: CGPoint(x: span.from, y: y))
            path.addLine(to: CGPoint(x: span.to, y: y))
        }
        guard !path.isEmpty else { return }
        ctx.stroke(path, with: .color(UIColor.knobOuter),
                   style: StrokeStyle(lineWidth: 0.5, lineCap: .butt))
    }

    /// Wektorowy odpowiednik `<#Bitmap>` 62×9 (XPos:184 YPos:4) w rodzinie
    /// Pan / X-Fade / Fade1-2 / Fade2-1 — rysunku trasy sygnału nad gniazdami.
    /// Bitmap w BVerhue trzyma surowe piksele, których nie dekodujemy; wzór odczytany
    /// z tych pikseli i odtworzony 1:1 krzywymi (piksel źródłowy = `bverhuePixelScale`).
    ///
    /// Wszystkie cztery mają ten sam szkielet: pionowy „pień" przy POJEDYNCZYM
    /// gnieździe, pozioma linia u góry, grot w dół i pod nim GRUBA belka (3 piksele)
    /// rozpięta między PARĄ gniazd, z nogą do każdego z nich. Różnią się dwiema
    /// rzeczami:
    ///   - stroną: Pan/Fade1-2 rozdzielają (jedno wejście → para wyjść L/R),
    ///     X-Fade/Fade2-1 łączą (para wejść → jedno wyjście) — wynika to wprost
    ///     z tego, którego rodzaju gniazda jest w tym rzędzie tylko jedno;
    ///   - belką: ciągła (Pan, X-Fade) albo przerwana pod grotem szerokością
    ///     grotu (Fade1-2, Fade2-1).
    private func drawFadeRouting(
        _ ctx: GraphicsContext,
        module: G2Module,
        ui: ModuleUIDef,
        rect: CGRect
    ) {
        // Przerwa w belce odróżnia moduły przełączające (Fade) od rozdzielających/
        // sumujących (Pan, X-Fade) — patrz zdekodowany wzór pikseli.
        let brokenBar: Bool
        switch module.typeID {
        case 47, 18: brokenBar = false
        case 113, 114: brokenBar = true
        default: return
        }

        let px = PatchLayout.bverhuePixelScale
        let connHalf: CGFloat = 5.5 * px
        // Rząd gniazd objęty rysunkiem: bitmapa zaczyna się na XPos:184 i sięga
        // prawej krawędzi panelu, a trzy gniazda pod nią leżą w jednym wierszu.
        let bitmapLeft = 184 * px
        let row = (ui.inputs.map { ($0, false) } + ui.outputs.map { ($0, true) })
            .filter { $0.0.xPt + connHalf >= bitmapLeft }
            .sorted { $0.0.xPt < $1.0.xPt }
        guard row.count == 3 else { return }

        // Pojedyncze gniazdo to to, którego rodzaj (wejście/wyjście) występuje raz.
        let outputCount = row.filter(\.1).count
        let singleIsOutput = outputCount == 1
        guard outputCount == 1 || outputCount == 2 else { return }
        guard let single = row.first(where: { $0.1 == singleIsOutput })?.0 else { return }
        let pair = row.filter { $0.1 != singleIsOutput }.map(\.0)
        guard pair.count == 2 else { return }

        func centerX(_ conn: BVConnector) -> CGFloat {
            rect.minX + conn.xPt + connHalf
        }
        let stemX = centerX(single)
        let barLeft = centerX(pair[0])
        let barRight = centerX(pair[1])
        let arrowX = (barLeft + barRight) / 2

        // Wiersze wzoru (piksel źródłowy, licząc od YPos:4 bitmapy).
        let topY = rect.minY + 4 * px // pozioma linia u góry
        let barTopY = rect.minY + 8 * px // czubek grotu = góra belki
        let barBottomY = rect.minY + 11 * px // belka ma 3 piksele grubości
        let legBottomY = rect.minY + 13 * px // nogi wchodzą w obrys gniazd
        let thin = px // linia i noga: 1 piksel
        let color = UIColor.knobOuter

        // Grot: wierzchołek zostaje na belce, a podstawa sięga GÓRNEJ krawędzi
        // poziomej linii — w bitmapie zaczyna się piksel niżej, przez co między
        // linią a skosem widać uskok. Trójkąt jest powiększony proporcjonalnie
        // (wysokość 4 piksele zamiast 3), więc skos zachowuje kąt ze źródła.
        let arrowTopY = topY
        let arrowScale = (barTopY - arrowTopY) / (3 * px)
        let arrowHalf = 2.5 * px * arrowScale // w źródle 5 pikseli podstawy

        var frame = Path()
        // Pień przy pojedynczym gnieździe + pozioma do osi grotu.
        frame.addRect(CGRect(x: stemX - thin / 2, y: topY,
                             width: thin, height: legBottomY - topY))
        frame.addRect(CGRect(x: min(stemX, arrowX), y: topY,
                             width: abs(arrowX - stemX), height: thin))
        // Nogi z końców belki do obu gniazd pary.
        for x in [barLeft, barRight] {
            frame.addRect(CGRect(x: x - thin / 2, y: barBottomY,
                                 width: thin, height: legBottomY - barBottomY))
        }
        ctx.fill(frame, with: .color(color))

        // Belka — w wariancie „Fade" przerwana dokładnie na szerokość grotu.
        var bar = Path()
        if brokenBar {
            let gapHalf = 1.5 * px
            bar.addRect(CGRect(x: barLeft - thin / 2, y: barTopY,
                               width: (arrowX - gapHalf) - (barLeft - thin / 2),
                               height: barBottomY - barTopY))
            bar.addRect(CGRect(x: arrowX + gapHalf, y: barTopY,
                               width: (barRight + thin / 2) - (arrowX + gapHalf),
                               height: barBottomY - barTopY))
        } else {
            bar.addRect(CGRect(x: barLeft - thin / 2, y: barTopY,
                               width: (barRight + thin / 2) - (barLeft - thin / 2),
                               height: barBottomY - barTopY))
        }
        ctx.fill(bar, with: .color(color))

        // Grot: podstawa u góry, czubek na belce.
        var arrow = Path()
        arrow.move(to: CGPoint(x: arrowX - arrowHalf, y: arrowTopY))
        arrow.addLine(to: CGPoint(x: arrowX + arrowHalf, y: arrowTopY))
        arrow.addLine(to: CGPoint(x: arrowX, y: barTopY))
        arrow.closeSubpath()
        ctx.fill(arrow, with: .color(color))
    }

    /// Wektorowy odpowiednik Bitmap ID:4 w ConstSwT/ConstSwM.
    private func drawConstSwitchRouting(
        _ ctx: GraphicsContext,
        module: G2Module,
        ui: ModuleUIDef,
        rect: CGRect
    ) {
        guard [50, 188].contains(module.typeID),
              let bmp = ui.bitmaps.first(where: { $0.widthPx == 23 && $0.heightPx == 10 })
        else { return }
        let scale = PatchLayout.bverhuePixelScale
        let origin = CGPoint(x: rect.minX + bmp.xPt, y: rect.minY + bmp.yPt)
        let lcdRight = ui.textFields.first(where: { $0.masterRef == 0 })
            .map { rect.minX + $0.xPt + $0.widthPt } ?? origin.x
        let color = UIColor.knobOuter
        let thickness = max(0.5, scale)

        // Kreska i dźwignia muszą być JEDNĄ łamaną — jako osobne odcinki z płaskim
        // zakończeniem zostawiały w miejscu styku szczerbinę zamiast narożnika.
        var route = Path()
        route.move(to: CGPoint(x: lcdRight, y: origin.y + 6.5 * scale))
        route.addLine(to: CGPoint(x: origin.x + 7 * scale, y: origin.y + 6.5 * scale))
        route.addLine(to: CGPoint(x: origin.x + 15.5 * scale, y: origin.y + 1.5 * scale))
        route.move(to: CGPoint(x: origin.x + 15 * scale, y: origin.y + 6.5 * scale))
        route.addLine(to: CGPoint(x: origin.x + 23 * scale, y: origin.y + 6.5 * scale))
        ctx.stroke(route, with: .color(color),
                   style: StrokeStyle(lineWidth: thickness, lineCap: .butt, lineJoin: .miter))

        let nodeRadius = 1.25 * scale
        let nodeCenter = CGPoint(x: origin.x + 15 * scale, y: origin.y + 6.5 * scale)
        let node = CGRect(x: nodeCenter.x - nodeRadius, y: nodeCenter.y - nodeRadius,
                          width: nodeRadius * 2, height: nodeRadius * 2)
        ctx.fill(Path(ellipseIn: node), with: .color(color))
    }

    /// Wektorowy odpowiednik małego rastra z parą pionowych strzałek ▲▼.
    /// Występuje w dwóch rozmiarach i dwóch rolach, ale to ten sam rysunek:
    /// 7×12 przy przycisku chwilowym (ConstSwM i trzy chwilowe Switche) oraz
    /// 5×13 przy gnieździe Gate w NoteSend. Proporcje bierzemy z wersji 7×12.
    private func drawConstSwitchMomentaryArrows(
        _ ctx: GraphicsContext,
        module: G2Module,
        ui: ModuleUIDef,
        rect: CGRect
    ) {
        guard [36, 143, 186, 187, 188].contains(module.typeID),
              let bmp = ui.bitmaps.first(where: {
                  ($0.widthPx == 7 && $0.heightPx == 12) || ($0.widthPx == 5 && $0.heightPx == 13)
              })
        else { return }
        // `scale` liczymy tak, żeby wzorcowe 7 jednostek szerokości wypadło na
        // rzeczywistą szerokość rastra — dzięki temu obie wersje mają ten sam kształt.
        let pixel = PatchLayout.bverhuePixelScale
        let scale = pixel * CGFloat(bmp.widthPx) / 7
        // Przy przycisku chwilowym strzałki trzymają JEGO oś pionową — inaczej
        // zostałyby na surowym YPos, gdy `ModuleUILayout` wyśrodkuje „Switch".
        // Przy gnieździe (NoteSend) takiego przycisku nie ma i zostaje własny YPos.
        let arrowHeight = 12 * scale
        let centerY = ui.buttonsText
            .first(where: { $0.type == "Push" })
            .map { rect.minY + $0.yPt + UIMetrics.buttonTextHeight / 2 }
            ?? rect.minY + bmp.yPt + CGFloat(bmp.heightPx) * pixel / 2
        let origin = CGPoint(x: rect.minX + bmp.xPt, y: centerY - arrowHeight / 2)
        let centerX = origin.x + 3.5 * scale
        let color = UIColor.knobOuter

        var arrows = Path()
        arrows.move(to: CGPoint(x: centerX, y: origin.y))
        arrows.addLine(to: CGPoint(x: origin.x, y: origin.y + 3.5 * scale))
        arrows.addLine(to: CGPoint(x: origin.x + 7 * scale, y: origin.y + 3.5 * scale))
        arrows.closeSubpath()
        arrows.addRect(CGRect(x: centerX - 0.6 * scale, y: origin.y + 3.5 * scale,
                              width: 1.2 * scale, height: 5 * scale))
        arrows.move(to: CGPoint(x: origin.x, y: origin.y + 8.5 * scale))
        arrows.addLine(to: CGPoint(x: origin.x + 7 * scale, y: origin.y + 8.5 * scale))
        arrows.addLine(to: CGPoint(x: centerX, y: origin.y + 12 * scale))
        arrows.closeSubpath()
        ctx.fill(arrows, with: .color(color))
    }

    /// Wektorowe odpowiedniki bitmap przełączników z grupy Switch. Cała grupa używa
    /// tylko dwóch rastrów, odczytanych piksel po pikselu z plików Gen1:
    ///
    /// * **23×16 — przełącznik pojedynczy** (SwOnOffM/T, WindSw, S&H, T&H): przewód
    ///   sterujący opadający z poziomej kreski, dźwignia uniesiona w prawo i wypełniony
    ///   styk przy wyjściu. To ten sam rysunek co Bitmap ID:4 w ConstSwT, tyle że
    ///   z dodatkowym pionowym przewodem — dlatego współrzędne są identyczne.
    /// * **24×16 — przełącznik przełączny** (Sw2-1(M), Sw1-2(M), oba ValSw): przewód
    ///   opada z góry, dźwignia odchyla się do lewego z dwóch styków.
    ///
    /// Położenie bierzemy z `<#Bitmap` w danych źródłowych, więc rysunek trafia dokładnie
    /// tam, gdzie był w oryginale — bez zgadywania odstępów od gniazd.
    private func drawSwitchRouting(
        _ ctx: GraphicsContext,
        module: G2Module,
        ui: ModuleUIDef,
        rect: CGRect
    ) {
        let switchIDs: Set = [17, 36, 53, 76, 85, 90, 100, 105, 139, 186, 187]
        guard switchIDs.contains(module.typeID) else { return }

        let scale = PatchLayout.bverhuePixelScale
        let color = UIColor.knobOuter
        let thickness = max(0.5, scale)
        let nodeRadius = 1.25 * scale

        for bmp in ui.bitmaps where bmp.heightPx == 16 && (bmp.widthPx == 23 || bmp.widthPx == 24) {
            let origin = CGPoint(x: rect.minX + bmp.xPt, y: rect.minY + bmp.yPt)
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
            }
            func fillNode(_ center: CGPoint) {
                ctx.fill(Path(ellipseIn: CGRect(
                    x: center.x - nodeRadius, y: center.y - nodeRadius,
                    width: 2 * nodeRadius, height: 2 * nodeRadius
                )), with: .color(color))
            }

            var route = Path()
            let nodes: [CGPoint]

            if bmp.widthPx == 23 {
                // Przewód sterujący zwisa z poziomej kreski nad rysunkiem. W części
                // modułów kreska stoi piksel wyżej niż raster, więc jej Y bierzemy
                // z danych — inaczej przewód wisiałby w powietrzu. Dół kończymy tak,
                // by przerwa do dźwigni była taka sama jak przerwa dźwignia↔styk.
                let lineTopY = ui.lines
                    .filter { $0.isHorizontal && $0.yPt <= bmp.yPt + 0.01 }
                    .max(by: { $0.yPt < $1.yPt })
                    .map { rect.minY + $0.yPt } ?? p(0, 0).y
                let node = p(15, 12.5)
                // W S&H/T&H zaraz za stykiem stoi ramka komórki „M" — przewód ma
                // dobijać do jej lewej krawędzi, a nie wchodzić do środka.
                let cellLeft = ui.bitmaps
                    .filter { $0.widthPx == 11 && $0.heightPx == 12 && $0.xPt > bmp.xPt }
                    .min(by: { $0.xPt < $1.xPt })
                    .map { rect.minX + $0.xPt }
                route.move(to: p(0, 12.5)) // przewód od gniazda wejściowego
                route.addLine(to: p(7, 12.5))
                route.addLine(to: p(15.5, 7.5)) // dźwignia uniesiona — styk rozwarty
                route.move(to: CGPoint(x: p(10.5, 0).x, y: lineTopY))
                route.addLine(to: p(10.5, 6.5))
                route.move(to: node)
                route.addLine(to: CGPoint(x: min(p(23, 0).x, cellLeft ?? .infinity),
                                          y: p(0, 12.5).y))
                nodes = [node]
            } else {
                let leftNode = p(8, 12.5)
                let rightNode = p(17, 12.5)
                route.move(to: p(0, 12.5))
                route.addLine(to: leftNode)
                route.move(to: rightNode)
                route.addLine(to: p(24, 12.5))
                route.move(to: p(12.5, 0)) // przewód sterujący
                route.addLine(to: p(12.5, 7))
                route.addLine(to: leftNode) // dźwignia opuszczona na lewy styk
                nodes = [leftNode, rightNode]
            }

            ctx.stroke(route, with: .color(color),
                       style: StrokeStyle(lineWidth: thickness, lineCap: .butt, lineJoin: .miter))
            nodes.forEach(fillNode)
        }
    }

    /// Bok kwadratowej ramki z literą, w pikselach źródłowych. Wspólny dla komórki
    /// pamięci S&H/T&H („M") i komórki danych nadajników MIDI („D") — ten sam element
    /// ma wyglądać tak samo niezależnie od modułu, a rastry źródłowe różnią się o piksel.
    private static let letteredCellSidePx: CGFloat = 8.5

    /// Ramka z jedną literą w środku.
    ///
    /// Litera jest centrowana na METRYKACH FONTU, nie na pudełku wiersza: `anchor`
    /// odnosi się do ramki tekstu, w której wielka litera (bez ogonka) siedzi wyżej
    /// niż jej środek — dlatego liczymy pozycję linii bazowej przez `firstBaseline`
    /// i cofamy o połowę wysokości wielkiej litery. Bez tego „D" i „M" uciekały w górę.
    private func drawLetteredCell(_ ctx: GraphicsContext, box: CGRect, letter: String) {
        let color = UIColor.knobOuter
        ctx.stroke(Path(box), with: .color(color),
                   style: StrokeStyle(lineWidth: max(0.5, PatchLayout.bverhuePixelScale),
                                      lineJoin: .miter))

        let fontSize = box.height * 0.78
        let capHeight = NSFont.systemFont(ofSize: fontSize, weight: .medium).capHeight
        let resolved = ctx.resolve(
            Text(letter)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(color)
        )
        let textSize = resolved.measure(in: CGSize(width: box.width * 4, height: box.height * 4))
        let baseline = resolved.firstBaseline(in: textSize)
        ctx.draw(resolved,
                 at: CGPoint(x: box.midX, y: box.midY + capHeight / 2 - baseline),
                 anchor: .top)
    }

    /// S&H/T&H: komórka Sample/Hold za stykiem to osobna bitmapa 11×12 — ramka „M".
    private func drawSampleHoldCell(
        _ ctx: GraphicsContext,
        module: G2Module,
        ui: ModuleUIDef,
        rect: CGRect
    ) {
        guard [53, 139].contains(module.typeID),
              let bmp = ui.bitmaps.first(where: { $0.widthPx == 11 && $0.heightPx == 12 })
        else { return }
        let scale = PatchLayout.bverhuePixelScale
        // Ramka jest mniejsza niż raster (11×11 → 8,5×8,5), więc wstawiamy ją w jego
        // środek: przewody dochodzą do niej w połowie wysokości, tak jak w źródle.
        let side = Self.letteredCellSidePx * scale
        let inset = (11 * scale - side) / 2
        drawLetteredCell(ctx, box: CGRect(x: rect.minX + bmp.xPt + inset,
                                          y: rect.minY + bmp.yPt + inset,
                                          width: side, height: side),
                         letter: "M")
    }

    /// CtrlSend/PCSend/Automate: Bitmap 20×12 między napisem „Send" a gniazdem to
    /// przewód z lewej, ramka z literą „D" (dana MIDI) i przewód w prawo. Ramka stoi
    /// w rastrze na (6,2) i ma 8×9 pikseli, przewody biegną w połowie jego wysokości.
    private func drawMidiSendCell(
        _ ctx: GraphicsContext,
        module: G2Module,
        ui: ModuleUIDef,
        rect: CGRect
    ) {
        guard [57, 141, 142].contains(module.typeID),
              let bmp = ui.bitmaps.first(where: { $0.widthPx == 20 && $0.heightPx == 12 })
        else { return }

        let scale = PatchLayout.bverhuePixelScale
        let origin = CGPoint(x: rect.minX + bmp.xPt, y: rect.minY + bmp.yPt)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        // Ramka jest kwadratowa i stoi na środku swojego miejsca w rastrze (6,2)-(13,10).
        let side = Self.letteredCellSidePx * scale
        let wireY = p(0, 6.5).y
        let box = CGRect(x: p(10, 0).x - side / 2, y: wireY - side / 2,
                         width: side, height: side)

        // Lewy przewód zaczyna się tuż za napisem „Send", a nie na krawędzi rastra —
        // w źródle zostawała tam wyraźna dziura między napisem a początkiem kreski.
        let wireStart = ui.textLabels
            .first(where: { $0.text == "Send" })
            .map { rect.minX + $0.xPt + labelWidth($0.text, fontSize: $0.fontSize) + 1.5 }
            .map { min($0, origin.x) } ?? origin.x

        var wires = Path()
        wires.move(to: CGPoint(x: wireStart, y: wireY))
        wires.addLine(to: CGPoint(x: box.minX, y: wireY))
        wires.move(to: CGPoint(x: box.maxX, y: wireY))
        wires.addLine(to: CGPoint(x: p(20, 0).x, y: wireY))
        ctx.stroke(wires, with: .color(UIColor.knobOuter),
                   style: StrokeStyle(lineWidth: max(0.5, scale), lineCap: .butt))

        drawLetteredCell(ctx, box: box, letter: "D")
    }

    /// Wektorowy odpowiednik Bitmap ID:2 w LevAdd — koło z plusem i komplet przewodów.
    private func drawLevAddSymbol(_ ctx: GraphicsContext, module: G2Module, ui: ModuleUIDef, rect: CGRect) {
        guard module.typeID == 112,
              let input = ui.inputs.first,
              let output = ui.outputs.first
        else { return }

        let scale = PatchLayout.bverhuePixelScale
        let connectorSide = 11 * scale
        let connectorHalf = connectorSide / 2
        let centerY = rect.minY + input.yPt + connectorHalf
        let inputRight = rect.minX + input.xPt + connectorSide
        let outputLeft = rect.minX + output.xPt
        let diameter = connectorSide
        let centerX = (inputRight + outputLeft) / 2
        let circle = CGRect(x: centerX - diameter / 2, y: centerY - diameter / 2,
                            width: diameter, height: diameter)
        let thickness: CGFloat = 0.5
        let color = UIColor.knobOuter

        var leads = Path()
        leads.move(to: CGPoint(x: inputRight, y: centerY))
        leads.addLine(to: CGPoint(x: circle.minX, y: centerY))
        leads.move(to: CGPoint(x: circle.maxX, y: centerY))
        leads.addLine(to: CGPoint(x: outputLeft, y: centerY))
        if let topLine = ui.lines.first(where: { $0.id == 7 }) {
            leads.move(to: CGPoint(x: centerX, y: rect.minY + topLine.yPt))
            leads.addLine(to: CGPoint(x: centerX, y: circle.minY))
        }
        ctx.stroke(leads, with: .color(color),
                   style: StrokeStyle(lineWidth: thickness, lineCap: .butt, lineJoin: .miter))
        ctx.stroke(Path(ellipseIn: circle), with: .color(color), lineWidth: thickness)

        let plusHalf = diameter * 0.24
        var plus = Path()
        plus.move(to: CGPoint(x: centerX - plusHalf, y: centerY))
        plus.addLine(to: CGPoint(x: centerX + plusHalf, y: centerY))
        plus.move(to: CGPoint(x: centerX, y: centerY - plusHalf))
        plus.addLine(to: CGPoint(x: centerX, y: centerY + plusHalf))
        ctx.stroke(plus, with: .color(color),
                   style: StrokeStyle(lineWidth: thickness, lineCap: .butt))
    }

    /// Rysuje elementy <#Symbol>. Obsługiwane typy: "Trig 1" (mała czarna strzałka
    /// do góry, np. przed "Sync") i "Amplifier" (trójkąt wzmacniacza łączący linie
    /// modulacji z wyjściem, np. ModAmt). Inne typy są pomijane, tak jak wcześniej
    /// gdy Symbol nie był wcale parsowany — moduły z bitmapą PNG mają je już
    /// wypieczone w grafice (np. LevMod) i nie potrzebują rysowania wektorowego.
    func drawBVSymbols(_ ctx: GraphicsContext, module: G2Module, rect: CGRect) {
        guard let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID) else { return }

        drawSwitchRouting(ctx, module: module, ui: ui, rect: rect)
        drawSampleHoldCell(ctx, module: module, ui: ui, rect: rect)
        drawMidiSendCell(ctx, module: module, ui: ui, rect: rect)
        drawConstSwitchRouting(ctx, module: module, ui: ui, rect: rect)
        drawConstSwitchMomentaryArrows(ctx, module: module, ui: ui, rect: rect)
        drawLevAddSymbol(ctx, module: module, ui: ui, rect: rect)

        // Invert (typeID:5): trójkąt NOT — jak trójkąt "Amplifier" niżej, ale z kółkiem
        // negacji na prawym wierzchołku — wbudowany w kolejność: gniazdo Input, linia,
        // trójkąt, kółko, linia, dioda, linia, gniazdo Output. Linie łączące (Input→trójkąt
        // i dioda→Output, ta druga biegnie POD diodą) to gotowe elementy <#Line> z BVerhue
        // (rysowane w drawBVLines) — tu dorysowujemy TYLKO trójkąt+kółko, bez własnych linii,
        // inaczej dublują się z tamtymi. Moduł ma DWA niezależne inwertery — w pliku źródłowym
        // LED obu grup mają CodeRef:0 (błąd/niekonsekwencja danych BVerhue, InputCodeRef i
        // OutputCodeRef poprawnie 0/1), więc grupowanie po CodeRef zawodzi dla LED — użyte
        // zamiast tego pary kolejnych <#Line> posortowane wg X (dokładnie 2 na grupę: ta przed
        // trójkątem i ta za kółkiem). Trójkąt+kółko skalowane tak, aby dokładnie wypełnić
        // szczelinę między końcem pierwszej linii a początkiem drugiej — bez tego zostaje
        // szczelina (linia "nie dochodzi") albo zachodzi na trójkąt (linia dłuższa niż
        // szczelina), bo obie linie mają stałą długość z pliku, niezależną od pozycji diody.
        // W BVerhue trójkąt+kółko zakodowane jako <#Bitmap> (piksele), które nie dekodujemy.
        if module.typeID == 5 {
            let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
            let side = connHalf * 2
            let baseTriH = side
            let baseTriW = side * CGFloat(3.0.squareRoot()) / 2.0
            let baseBubbleR = side * 0.14
            let baseWidth = baseTriW + baseBubbleR * 2
            let thickness: CGFloat = 0.5

            let horizontalLines = ui.lines.filter(\.isHorizontal).sorted { $0.xPt < $1.xPt }

            for (i, codeRef) in [0, 1].enumerated() {
                guard let input = ui.inputs.first(where: { $0.codeRef == codeRef }),
                      horizontalLines.count >= (i + 1) * 2 else { continue }
                let leftLine = horizontalLines[i * 2]
                let rightLine = horizontalLines[i * 2 + 1]
                let leftX = rect.minX + leftLine.xPt + leftLine.lengthPt
                let rightX = rect.minX + rightLine.xPt
                let availableWidth = rightX - leftX
                guard availableWidth > 0 else { continue }

                let fitScale = availableWidth / baseWidth
                let triW = baseTriW * fitScale
                let triH = baseTriH * fitScale
                let bubbleR = baseBubbleR * fitScale

                let centerY = rect.minY + input.yPt + connHalf
                let topY = centerY - triH / 2

                var tri = Path()
                tri.move(to: CGPoint(x: leftX, y: topY))
                tri.addLine(to: CGPoint(x: leftX, y: topY + triH))
                tri.addLine(to: CGPoint(x: leftX + triW, y: centerY))
                tri.closeSubpath()
                ctx.stroke(tri, with: .color(UIColor.knobOuter),
                           style: StrokeStyle(lineWidth: thickness, lineJoin: .miter))

                let bubbleCenterX = leftX + triW + bubbleR
                let bubble = CGRect(x: bubbleCenterX - bubbleR, y: centerY - bubbleR,
                                    width: bubbleR * 2, height: bubbleR * 2)
                ctx.stroke(Path(ellipseIn: bubble), with: .color(UIColor.knobOuter),
                           style: StrokeStyle(lineWidth: thickness))
            }
        }

        drawFadeRouting(ctx, module: module, ui: ui, rect: rect)

        // Rodzina obwiedni z gniazdem "Env"/lejkiem sygnału (LevScaler 115, EnvMulti
        // 52, EnvADSR 20, ModADSR 23, EnvH 41, EnvAHD 46, EnvD 55, EnvADR 84,
        // EnvADDSR 119, ModAHD 169): odcinek → RÓWNOBOCZNY trójkąt (STAŁY rozmiar,
        // side = pełna średnica gniazda, ten sam we WSZYSTKICH tych modułach —
        // zunifikowane, wcześniej EnvADSR/ModADSR/EnvAHD/ModAHD miały większy
        // trójkąt niż reszta, co dawało niespójny wygląd) → odcinek. W BVerhue
        // zakodowany jako <#Bitmap> (piksele, nie dekodujemy) — kształt
        // potwierdzony ręcznym zdekodowaniem pikseli (audyt: "pominięte elementy
        // Bitmap"). Cztery moduły (20/23/46/169) mają dodatkowo osobną parę linii
        // BVerhue prowadzących do trójkąta (`envJackTriangleLineIDs`, wykluczone z
        // generycznego rysowania linii w drawBVLines) — reszta korzysta wprost z
        // pozycji gniazd Audio In/Out.
        if let (horizontal, axisStart, axisEnd, centerAxis, thickness) = envJackFunnelGeometry(
            module: module, ui: ui, rect: rect
        ) {
            drawEnvJackFunnel(ctx, horizontal: horizontal, axisStart: axisStart,
                              axisEnd: axisEnd, centerAxis: centerAxis, thickness: thickness)
        }

        let parkArrow = parkArrowLayout(module: module, ui: ui)
        for sym in ui.symbols {
            let x: CGFloat
            if let park = parkArrow, sym.id == park.symbolID {
                x = rect.minX + park.symbolX
            } else if module.typeID == 84, sym.type == "Trig 1",
                      let end = ui.textLabels.first(where: { $0.text == "End" }),
                      let endOutput = ui.outputs.first(where: { $0.codeRef == 2 })
            {
                // EnvADR: grot ma dzielić wolne miejsce między „End” a gniazdem.
                // Zostawiamy etykietę i gniazdo na ich pozycjach źródłowych.
                let endRight = end.xPt + labelWidth(end.text, fontSize: end.fontSize)
                x = rect.minX + (endRight + endOutput.xPt - sym.widthPt) / 2
            } else {
                x = rect.minX + sym.xPt
            }
            let y = rect.minY + sym.yPt
            let w = sym.widthPt
            let h = sym.heightPt
            switch sym.type {
            case "Trig 1":
                ctx.fill(trigArrowPath(x: x, y: y, w: w, h: h), with: .color(.black))
            case "Trig 2":
                // Dokładnie ta sama strzałka co "Trig 1" plus prosta pozioma kreska
                // (bez zaokrągleń) tuż nad jej czubkiem. Występuje w 13 modułach
                // BVerhue (ClkDiv, SeqNote, SeqA, SeqLev, SeqVal, SeqEvent, RndClkA/B,
                // RndTrig, RndChaos, RndPattern, NoteSend, ClkDivFix). BVerhue deklaruje
                // Trig1/Trig2 z lekko różnym Width (np. ClkDiv: Trig1=3, Trig2=4 Gen1px)
                // — przy tak małych rozmiarach (rzędu 1-2pt) ta niewielka różnica
                // widocznie zniekształcała proporcje strzałki. Żeby zagwarantować
                // identyczny kształt (nie tylko "ten sam wzór z innym w"), pożycz
                // rozmiar z sąsiedniego "Trig 1" w tym samym module, jeśli istnieje.
                let arrowSize = ui.symbols.first(where: { $0.type == "Trig 1" })
                    .map { (w: $0.widthPt, h: $0.heightPt) } ?? (w: w, h: h)
                let lineH = max(0.6, arrowSize.h * 0.12)
                let lineRect = CGRect(x: x, y: y - lineH, width: arrowSize.w, height: lineH)
                ctx.fill(Path(lineRect), with: .color(.black))
                ctx.fill(trigArrowPath(x: x, y: y, w: arrowSize.w, h: arrowSize.h), with: .color(.black))
            case "Amplifier":
                // Trójkąt wzmacniacza: tylko obrys, równoboczny (wszystkie boki =
                // średnica gniazda), wyśrodkowany W SZCZELINIE między prawą krawędzią
                // bliższego (okrągłego) gniazda Input a lewą krawędzią gniazda Output
                // — nie na środku bounding-boxu Symbol z BVerhue (inny margines).
                let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
                let side = connHalf * 2
                let triH = side
                let triW = side * CGFloat(3.0.squareRoot()) / 2.0 // równoboczny: wszystkie boki = side

                /// Wspólne dla obu modułów: trójkąt wyśrodkowany w szczelinie
                /// connNear↔Output, środek pionowego łącznika dokładnie na środku
                /// GÓRNEJ SKOŚNEJ krawędzi (góra-lewo → wierzchołek) — linia pionowa
                /// naturalnie ją przecina, więc nie zlewa się z nią tak jak by się
                /// zlała z płaską, wertykalną lewą krawędzią.
                func triangleGeometry(connNear: BVConnector, outputConn: BVConnector) -> (
                    thickness: CGFloat, centerY: CGFloat, connNearRight: CGFloat,
                    outputLeft: CGFloat, leftX: CGFloat, topY: CGFloat, midX: CGFloat, midY: CGFloat
                ) {
                    let centerY = rect.minY + connNear.yPt + connHalf
                    let connNearRight = rect.minX + connNear.xPt + side
                    let outputLeft = rect.minX + outputConn.xPt
                    let gap = outputLeft - connNearRight
                    let leftX = connNearRight + (gap - triW) / 2
                    let topY = centerY - triH / 2
                    return (0.5, centerY, connNearRight, outputLeft, leftX, topY,
                            leftX + triW / 2, topY + triH / 4)
                }

                func drawTriangleAndOutput(g: (thickness: CGFloat, centerY: CGFloat, connNearRight: CGFloat,
                                               outputLeft: CGFloat, leftX: CGFloat, topY: CGFloat,
                                               midX: CGFloat, midY: CGFloat))
                {
                    var tri = Path()
                    tri.move(to: CGPoint(x: g.leftX, y: g.topY))
                    tri.addLine(to: CGPoint(x: g.leftX, y: g.topY + triH))
                    tri.addLine(to: CGPoint(x: g.leftX + triW, y: g.topY + triH / 2))
                    tri.closeSubpath()
                    ctx.stroke(tri, with: .color(UIColor.knobOuter),
                               style: StrokeStyle(lineWidth: g.thickness, lineJoin: .miter))

                    var outLine = Path()
                    outLine.move(to: CGPoint(x: g.leftX + triW, y: g.centerY))
                    outLine.addLine(to: CGPoint(x: g.outputLeft, y: g.centerY))
                    ctx.stroke(outLine, with: .color(UIColor.knobOuter),
                               style: StrokeStyle(lineWidth: g.thickness, lineCap: .butt))
                }

                if module.typeID == 195,
                   let connNear = ui.inputs.max(by: { $0.xPt < $1.xPt }),
                   let connFar = ui.inputs.min(by: { $0.xPt < $1.xPt }),
                   let outputConn = ui.outputs.first,
                   let routingLine = ui.lines.first(where: { $0.id == 9 })
                {
                    let g = triangleGeometry(connNear: connNear, outputConn: outputConn)
                    let thickness: CGFloat = routingLine.isThick ? 1.0 : 0.5
                    let riserX = rect.minX + connFar.xPt + connHalf
                    let topLineY = rect.minY + routingLine.yPt

                    var routing = Path()
                    routing.move(to: CGPoint(x: riserX, y: g.centerY))
                    routing.addLine(to: CGPoint(x: riserX, y: topLineY))
                    routing.addLine(to: CGPoint(x: g.midX, y: topLineY))
                    routing.addLine(to: CGPoint(x: g.midX, y: g.midY))
                    ctx.stroke(routing, with: .color(UIColor.knobOuter),
                               style: StrokeStyle(lineWidth: thickness, lineCap: .butt, lineJoin: .miter))

                    var directLine = Path()
                    directLine.move(to: CGPoint(x: g.connNearRight, y: g.centerY))
                    directLine.addLine(to: CGPoint(x: g.leftX, y: g.centerY))
                    ctx.stroke(directLine, with: .color(UIColor.knobOuter),
                               style: StrokeStyle(lineWidth: thickness, lineCap: .butt))

                    drawTriangleAndOutput(g: (thickness, g.centerY, g.connNearRight, g.outputLeft,
                                              g.leftX, g.topY, g.midX, g.midY))
                } else if module.typeID == 117,
                          let connNear = ui.inputs.first(where: { $0.codeRef == 0 }),
                          let modIn = ui.inputs.first(where: { $0.codeRef == 1 }),
                          let outputConn = ui.outputs.first
                {
                    // LevMod: dodatkowo mała prostokątna ikona (BVerhue <#Bitmap>,
                    // pomijana jak inline-bitmapy tła — tu jest jednak małym
                    // elementem trasy sygnału, nie tłem) między gniazdem "Mod"
                    // a "schodkiem" schodzącym do trójkąta.
                    let g = triangleGeometry(connNear: connNear, outputConn: outputConn)
                    let modCenterY = rect.minY + modIn.yPt + connHalf
                    let modRight = rect.minX + modIn.xPt + side

                    // Mniejszy prostokąt niż poprzednio — szerszy wystawał poza
                    // wierzchołek trójkąta, więc pionowy odcinek schodka lądował
                    // na wysokości gniazda Output, nie na skośnej krawędzi trójkąta.
                    let rectGap: CGFloat = side * 0.3
                    let rectW: CGFloat = side * 0.8
                    let rectH: CGFloat = side * 0.55
                    let rectX = modRight + rectGap
                    let rectY = modCenterY - rectH / 2

                    var toRect = Path()
                    toRect.move(to: CGPoint(x: modRight, y: modCenterY))
                    toRect.addLine(to: CGPoint(x: rectX, y: modCenterY))
                    ctx.stroke(toRect, with: .color(UIColor.knobOuter),
                               style: StrokeStyle(lineWidth: g.thickness, lineCap: .butt))

                    ctx.stroke(Path(CGRect(x: rectX, y: rectY, width: rectW, height: rectH)),
                               with: .color(UIColor.knobOuter), style: StrokeStyle(lineWidth: g.thickness))

                    // Zygzak: z prawego boku prostokąta najpierw kawałek W PRAWO
                    // (na zewnątrz), potem W DÓŁ, potem W LEWO do X punktu na
                    // skośnej krawędzi, potem znowu W DÓŁ do tego punktu.
                    let outX = rectX + rectW + side * 0.3
                    let midDropY = (modCenterY + g.midY) / 2
                    var routing = Path()
                    routing.move(to: CGPoint(x: rectX + rectW, y: modCenterY))
                    routing.addLine(to: CGPoint(x: outX, y: modCenterY))
                    routing.addLine(to: CGPoint(x: outX, y: midDropY))
                    routing.addLine(to: CGPoint(x: g.midX, y: midDropY))
                    routing.addLine(to: CGPoint(x: g.midX, y: g.midY))
                    ctx.stroke(routing, with: .color(UIColor.knobOuter),
                               style: StrokeStyle(lineWidth: g.thickness, lineCap: .butt, lineJoin: .miter))

                    var directLine = Path()
                    directLine.move(to: CGPoint(x: g.connNearRight, y: g.centerY))
                    directLine.addLine(to: CGPoint(x: g.leftX, y: g.centerY))
                    ctx.stroke(directLine, with: .color(UIColor.knobOuter),
                               style: StrokeStyle(lineWidth: g.thickness, lineCap: .butt))

                    drawTriangleAndOutput(g: g)
                } else if [44, 81].contains(module.typeID),
                          let connNear = ui.inputs.first(where: { $0.codeRef == 0 }),
                          let outputConn = ui.outputs.first,
                          let topLine = ui.lines.first(where: { $0.isHorizontal })
                {
                    // LevAmp i LevMult: trójkąt leży dokładnie na osi gniazd,
                    // a pionowy łącznik trafia w środek jego górnej skosnej
                    // krawędzi i dochodzi do poziomej magistrali nad nim.
                    let g = triangleGeometry(connNear: connNear, outputConn: outputConn)
                    let topLineY = rect.minY + topLine.yPt

                    var routing = Path()
                    if module.typeID == 81 {
                        routing.move(to: CGPoint(x: rect.minX + topLine.xPt, y: topLineY))
                        routing.addLine(to: CGPoint(x: g.midX, y: topLineY))
                    }
                    routing.move(to: CGPoint(x: g.connNearRight, y: g.centerY))
                    routing.addLine(to: CGPoint(x: g.leftX, y: g.centerY))
                    routing.move(to: CGPoint(x: g.midX, y: topLineY))
                    routing.addLine(to: CGPoint(x: g.midX, y: g.midY))
                    ctx.stroke(routing, with: .color(UIColor.knobOuter),
                               style: StrokeStyle(lineWidth: g.thickness, lineCap: .butt,
                                                  lineJoin: .miter))
                    drawTriangleAndOutput(g: g)
                } else {
                    // Pozostałe moduły z symbolem "Amplifier" — prosty równoboczny
                    // trójkąt wyśrodkowany w boksie Symbol.
                    let triHFallback = min(h, side)
                    let triWFallback = triHFallback * CGFloat(3.0.squareRoot()) / 2.0
                    let leftXFallback = x + (w - triWFallback) / 2
                    let topYFallback = y + (h - triHFallback) / 2
                    var triFallback = Path()
                    triFallback.move(to: CGPoint(x: leftXFallback, y: topYFallback))
                    triFallback.addLine(to: CGPoint(x: leftXFallback, y: topYFallback + triHFallback))
                    triFallback.addLine(to: CGPoint(x: leftXFallback + triWFallback, y: topYFallback + triHFallback / 2))
                    triFallback.closeSubpath()
                    ctx.stroke(triFallback, with: .color(UIColor.knobOuter),
                               style: StrokeStyle(lineWidth: 0.5, lineJoin: .miter))
                }
            case "Box":
                // "Czarna skrzynka" łącząca gniazdo In z Out (np. NoteQuant, KeyQuant,
                // Glide, PartQuant, ZeroCnt) — KWADRAT pośrodku, trochę mniejszy niż
                // gniazdo (0.8×side), krótkie odcinki ("leady") do gniazd po obu
                // stronach. Wyśrodkowane między RZECZYWISTYMI gniazdami In/Out
                // (najbliższe symbolowi po Y — niektóre moduły mają dodatkowe gniazda
                // gdzie indziej, np. Vocoder/DlySingleB), a NIE proporcją z
                // bounding-boxu Symbol z .txt — ten bywał przesunięty względem
                // faktycznych gniazd, przez co "leady" wychodziły nierówne.
                let connHalf: CGFloat = 5.5 * (140.0 / 256.0)
                let side = connHalf * 2
                let squareSide = side * 0.8

                if let input = ui.inputs.min(by: { abs($0.yPt - sym.yPt) < abs($1.yPt - sym.yPt) }),
                   let output = ui.outputs.min(by: { abs($0.yPt - sym.yPt) < abs($1.yPt - sym.yPt) })
                {
                    let leftEdge = rect.minX + input.xPt + side
                    let rightEdge = rect.minX + output.xPt
                    let centerX = (leftEdge + rightEdge) / 2
                    let centerY = rect.minY + input.yPt + connHalf
                    let boxLeft = centerX - squareSide / 2
                    let boxRight = centerX + squareSide / 2

                    var leads = Path()
                    leads.move(to: CGPoint(x: leftEdge, y: centerY))
                    leads.addLine(to: CGPoint(x: boxLeft, y: centerY))
                    leads.move(to: CGPoint(x: boxRight, y: centerY))
                    leads.addLine(to: CGPoint(x: rightEdge, y: centerY))
                    ctx.stroke(leads, with: .color(UIColor.knobOuter),
                               style: StrokeStyle(lineWidth: 0.5, lineCap: .butt))
                    ctx.stroke(Path(CGRect(x: boxLeft, y: centerY - squareSide / 2,
                                           width: squareSide, height: squareSide)),
                               with: .color(UIColor.knobOuter), style: StrokeStyle(lineWidth: 0.5))
                }
            default:
                continue
            }
        }
    }

    // MARK: - Color helpers

    // Kolory stron z BVE.NMG2Types.pas — ModulePageColors[0..15]
    // Źródło: MODULECATEGORIES array, format Delphi $00BBGGRR → R=low byte, G=mid, B=high
    func pageColor(_ page: String) -> Color {
        switch page {
        case "In/Out": Color(red: 0.392, green: 0.392, blue: 0.392) // idx 0 — $646464
        case "Note": Color(red: 0.549, green: 0.008, blue: 0.992) // idx 1 — $FD028C
        case "Osc": Color(red: 0.792, green: 0.000, blue: 0.000) // idx 2 — $0000CA
        case "LFO": Color(red: 0.000, green: 0.000, blue: 0.792) // idx 3 — $CA0000
        case "Rnd": Color(red: 0.000, green: 0.588, blue: 0.902) // idx 4 — $E69600
        case "Env": Color(red: 0.000, green: 0.733, blue: 0.733) // idx 5 — $BBBB00
        case "Filter": Color(red: 0.000, green: 0.510, blue: 0.518) // idx 6 — $848200
        case "FX": Color(red: 0.918, green: 0.392, blue: 0.690) // idx 7 — $B064EA
        case "Delay": Color(red: 0.514, green: 0.349, blue: 1.000) // idx 8 — $FF5983
        case "Shaper": Color(red: 0.808, green: 0.443, blue: 0.451) // idx 9 — $7371CE
        case "Level": Color(red: 0.251, green: 0.627, blue: 0.000) // idx 10 — $00A040
        case "Mixer": Color(red: 1.000, green: 0.502, blue: 0.251) // idx 11 — $4080FF
        case "Switch": Color(red: 0.400, green: 0.851, blue: 1.000) // idx 12 — $FFD966
        case "Logic": Color(red: 0.961, green: 0.918, blue: 0.004) // idx 13 — $01EAF5
        case "Seq": Color(red: 0.996, green: 0.812, blue: 0.255) // idx 14 — $41CFFE
        case "MIDI": Color(red: 0.753, green: 0.502, blue: 0.000) // idx 15 — $0080C0
        case "PM": Color(red: 0.200, green: 0.600, blue: 0.400) // Physical Modelling
        default: Color(red: 0.39, green: 0.39, blue: 0.39)
        }
    }

    private func connectorColor(_ color: ConnectorColor) -> Color {
        switch color {
        case .audio: Color(red: 0.88, green: 0.18, blue: 0.18)
        case .control: Color(red: 0.20, green: 0.48, blue: 0.95)
        case .logic: Color(red: 0.95, green: 0.88, blue: 0.10)
        case .pitchOrControl: Color(red: 0.58, green: 0.35, blue: 0.95)
        case .logicOrControl: Color(red: 0.98, green: 0.65, blue: 0.08)
        }
    }

    private func cableColor(_ color: CableColor) -> Color {
        switch color {
        case .red: Color(red: 0.92, green: 0.18, blue: 0.18)
        case .blue: Color(red: 0.20, green: 0.50, blue: 1.00)
        case .yellow: Color(red: 0.95, green: 0.88, blue: 0.10)
        case .orange: Color(red: 0.98, green: 0.55, blue: 0.08)
        case .green: Color(red: 0.18, green: 0.78, blue: 0.28)
        case .purple: Color(red: 0.62, green: 0.22, blue: 0.88)
        case .white: Color(red: 0.92, green: 0.92, blue: 0.92)
        }
    }
}
