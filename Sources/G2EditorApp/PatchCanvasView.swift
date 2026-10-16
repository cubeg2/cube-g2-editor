import AppKit
import G2Core
import G2EditorCore
import SwiftUI

// MARK: - Rozmiary fontów (jedno miejsce dla wszystkich elementów UI modułu)

enum UIFont {
    static let moduleName: CGFloat = 5.5
    static let buttonLabel: CGFloat = 4.0
    static let radioLabel: CGFloat = 4.0
    static func lcdDisplay(boxHeight: CGFloat) -> CGFloat {
        boxHeight - 0.7
    }
}

// MARK: - Kolory UI (jedno miejsce dla wszystkich kolorów)

enum UIColor {
    /// Canvas
    static let canvasBackground = Color(red: 0.16, green: 0.16, blue: 0.16)
    /// Moduł bez PNG — szary panel
    static let modulePanelGray = Color(red: 0.741, green: 0.741, blue: 0.741)
    /// Tło ekranów LCD
    static let lcdBackground = Color(red: 0.05, green: 0.18, blue: 0.08)
    /// Napisy na ekranach — ta sama zieleń co krzywe (`graphLine`); do 2026-09-27
    /// były jaśniejsze i bledsze (0.55/1.0/0.55), co wyglądało jak dwa różne ekrany.
    static let lcdText = graphLine
    /// Czerwone krzywe na selektorze `Type` modułu PM Driver — kolor atlasu
    /// oryginalnego panelu Clavii (`#dd0b01`).
    static let pmDriverAccent = Color(red: 221.0 / 255.0, green: 11.0 / 255.0, blue: 1.0 / 255.0)
    /// Pozycje nieaktywne na rozwiniętej liście ekranu — przygaszone względem
    /// aktywnej, ale o połowę jaśniejsze niż pierwsza próba (zlewały się z tłem
    /// `lcdBackground`) — w ~70 % drogi od tła ekranu do pełnego `lcdText`.
    static let lcdTextDim = Color(red: 0.085, green: 0.72, blue: 0.27)
    /// Siatka piano-roll SeqNote — paleta ekranu, nie szarości panelu. Klawisze
    /// białe są jaśniejsze od czarnych (jak na prawdziwej klawiaturze), oba w
    /// zieleni ciemniejszej niż `lcdText`, żeby uchwyt nuty pozostał najjaśniejszym
    /// elementem siatki.
    static let seqNoteWhiteKey = Color(red: 0.106, green: 0.306, blue: 0.145)
    static let seqNoteBlackKey = Color(red: 0.020, green: 0.082, blue: 0.039)
    /// Separator rysowany tylko na styku dwóch białych klawiszy (E–F, H–C).
    static let seqNoteKeyLine = Color(red: 0.306, green: 0.592, blue: 0.341)
    /// Ramka siatki i tło widoczne w szczelinach między kolumnami.
    static let seqNoteFrame = Color(red: 0.090, green: 0.239, blue: 0.118)
    /// Zabarwienie kontrolki morfowanej. Kolor niesie tę samą informację co u Clavii:
    /// czerwony = morf Z FOCUSEM, niebieski = którykolwiek z pozostałych siedmiu
    /// (BVerhue `ActiveMorphColor := claRed` / `InactiveMorphColor := claBlue`).
    /// Niebieski jaśniejszy i bardziej nasycony niż czysty claBlue — na naszym ciemnym
    /// tle granat zlewał się z szarą obwódką gałki → [[Docs/ui/morphs]].
    static let morphFocused = Color(red: 0.85, green: 0.12, blue: 0.12)
    static let morphOther = Color(red: 0.20, green: 0.55, blue: 1.0)
    // Gałka rotacyjna — `knobOuter` służy też liniom dekoracji; tarcze rysuje `KnobFace`
    static let knobOuter = Color(red: 0.22, green: 0.22, blue: 0.22)
    // Suwak / toggle
    static let toggleOn = Color(red: 0.20, green: 0.78, blue: 0.25)
    static let toggleOff = Color(red: 0.82, green: 0.76, blue: 0.60)
    // Przyciski — jeden odcień niebieskiego dla wszystkich aktywnych buttonów
    static let buttonBlue = Color(red: 0.35, green: 0.55, blue: 0.85)
    static let buttonActive = buttonBlue
    static let buttonInactive = Color(white: 0.78) // ButtonFlat off, RadioButton unselected
    static let buttonNeutral = Color(white: 0.80) // ButtonText off, IncDec face
    static let buttonTextOn = buttonBlue
    /// Przycisk przytrzymany myszą (+/− i ▲/▼) — jaśniejszy od `buttonBlue`.
    static let buttonPressed = Color(red: 0.35, green: 0.65, blue: 1.0)
    /// Obrys przycisku i ekranu — domyślne w `PanelFace`; pojedyncze elementy, które mają
    /// jaśniejszy lub ciemniejszy obrys, podają go same.
    static let buttonBorder = Color.black.opacity(0.45)
    static let screenBorder = Color.black.opacity(0.7)
    /// Trójkąt resetu nad gałką, gdy gałka nie stoi na środku (na środku: `powerButtonOn`).
    static let knobResetOff = Color.gray
    /// Zgaszony segment miernika Gain Reduction w Compressorze.
    static let compressorSegmentOff = Color(red: 0.10, green: 0.42, blue: 0.12)
    // Przycisk Active/Power
    static let powerButtonOn = Color(red: 0.18, green: 0.72, blue: 0.28)
    static let powerButtonOff = Color(white: 0.32)
    // Ikona Power
    static let powerIconOn = Color(white: 1.0) // biała ikona na zielonym tle
    static let powerIconOff = Color(white: 0.55)
    /// RadioButton zaznaczony — ten sam odcień co buttonActive
    static let radioSelected = buttonBlue
    // Diody LED — kolory wzięte z wyglądu SAMEGO ORYGINAŁU (2026-09-06):
    // dioda zielona 7×7 px i dioda sekwencera 12×6 px, zapalone i zgaszone. Obie zgaszone mają ten sam
    // odcień `#216921`; zapalone różnią się (`#1AFF1A` vs czyste `#00FF00`).
    // Wcześniejsze wartości były przybliżeniem „na oko" i wychodziły ciemniejsze.
    static let ledGreenOff = Color(red: 0x21 / 255.0, green: 0x69 / 255.0, blue: 0x21 / 255.0)
    static let ledGreenOn = Color(red: 0x1A / 255.0, green: 1.0, blue: 0x1A / 255.0)
    static let ledSequencer = ledGreenOff
    static let ledSequencerOn = Color(red: 0.0, green: 1.0, blue: 0.0)
    // Gniazda kabli — Audio
    static let connectorAudio = Color(red: 0.90, green: 0.18, blue: 0.18)
    static let connectorAudioDark = Color(red: 0.50, green: 0.06, blue: 0.06)
    // Gniazda kabli — Control
    static let connectorControl = Color(red: 0.20, green: 0.48, blue: 0.95)
    static let connectorControlDark = Color(red: 0.06, green: 0.20, blue: 0.52)
    // Gniazda kabli — Logic
    static let connectorLogic = Color(red: 0.95, green: 0.85, blue: 0.08)
    static let connectorLogicDark = Color(red: 0.52, green: 0.45, blue: 0.02)
    // Gniazda kabli — Orange (logicOrControl prawa połowa)
    static let connectorOrange = Color(red: 0.98, green: 0.55, blue: 0.08)
    static let connectorOrangeDark = Color(red: 0.55, green: 0.28, blue: 0.02)
    /// Etykiety tekstowe (moduły bez PNG)
    static let textLabel = Color(red: 0.08, green: 0.08, blue: 0.08)
    /// Linie dekoracyjne (legacy)
    static let decorativeLine = Color(red: 0.20, green: 0.15, blue: 0.05).opacity(0.50)
    // Wykresy graficzne (ADSR, filtry, kształty) — to samo tło co ekrany LCD z cyframi
    // (unifikacja 2026-08-12: osobny, neutralnie szary `graphBackground` wyglądał jak
    // inny, "mocniejszy" czarny obok zielonkawych ekranów LCD).
    static let graphBackground = lcdBackground
    static let graphLine = Color(red: 0.10, green: 0.95, blue: 0.35)
    static let graphBorder = Color(red: 0.28, green: 0.28, blue: 0.28)
    /// Zunifikowana linia bazowa/odniesienia (0dB, oś zera, Back Line Color z
    /// oryginału — RGB 0xc0/0xc0/0xc0) — wspólna dla wszystkich ekranów wykresów
    /// (filtry, EQ, obwiednie, LevelScaler, Operator, Shaper, fale OscShpB/DoubleSaw).
    /// Wcześniej różne ekrany miały dwa niespójne warianty: prawie niewidoczny szary
    /// (`graphGrid`, 0.18) i żółty (stary `graphBaseline`) — teraz jeden, jaśniejszy ton.
    static let graphBaseline = Color(white: 0.75)
    /// Odcinek sustain-hold w obwiedniach ADSR (Sustain Color z oryginału —
    /// RGB 0xff/0xff/0x00, czysty żółty). Tylko rodzina ADSR ma ten trzeci kolor —
    /// AR/AHD/D i pozostałe wykresy używają wyłącznie `graphLine` + `graphBaseline`.
    static let graphSustain = Color(red: 1.0, green: 1.0, blue: 0.0)
    /// Etykiety w pływających oknach paneli (Parameter Pages, Parameter Overview).
    /// `textLabel` zostaje ciemny, bo leży na szarym panelu modułu — tu tłem jest
    /// tło okna systemu, więc w trybie nocnym napis musi być jasny.
    static let panelText = Color(nsColor: .labelColor)
    /// Wgłębienie pod grupą kontrolek panelu — ciemniejsze od tła w trybie dziennym,
    /// jaśniejsze w nocnym; `Color.black.opacity()` znikało na ciemnym tle.
    static let panelWell = Color.primary.opacity(0.07)
    /// Gałka w stylu Future: pasek wartości na czarnym pierścieniu i wskaźnik. Pasek
    /// w zieleni ekranów albo czerwony (Options ▸ Knob Style ▸ Range color).
    static let knobFutureRange = graphLine
    static let knobFutureRangeRed = Color(red: 0.92, green: 0.14, blue: 0.10)
    static let knobFuturePointer = Color(white: 0.08)
}

// MARK: - Blask (pasek gałki Future, diody)

/// Poświata świecącego elementu: rozmyta, szersza kopia pod nim. `amount` 0…1 z Setup ▸
/// Options ▸ Glow — rośnie szerokość, rozmycie i krycie; przy 0 nie rysuje nic.
enum Glow {
    static func stroke(_ ctx: GraphicsContext, _ path: Path, color: Color, lineWidth: CGFloat,
                       cap: CGLineCap, amount: Double)
    {
        guard amount > 0.001 else { return }
        let a = CGFloat(amount)
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: lineWidth * (0.6 + 1.0 * a)))
            layer.stroke(path, with: .color(color.opacity(0.5 + 0.5 * amount)),
                         style: StrokeStyle(lineWidth: lineWidth * (1.6 + 1.6 * a), lineCap: cap, lineJoin: .round))
        }
    }

    /// Diody: wszystkie zapalone w JEDNEJ warstwie z rozmyciem (klatka co 50 ms — osobna
    /// warstwa na każdą diodę kosztowałaby tyle razy więcej). `size` = typowy bok diody.
    static func fill(_ ctx: GraphicsContext, _ lights: [(rect: CGRect, color: Color)], size: CGFloat,
                     amount: Double)
    {
        guard amount > 0.001, !lights.isEmpty else { return }
        let a = CGFloat(amount)
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: size * (0.3 + 0.7 * a)))
            for light in lights {
                layer.fill(Path(roundedRect: light.rect.insetBy(dx: -size * 0.35 * a, dy: -size * 0.35 * a),
                                cornerRadius: size * 0.3),
                           with: .color(light.color.opacity(0.45 + 0.55 * amount)))
            }
        }
    }
}

// MARK: - Tarcza gałki (kanwa, Parameter Pages, Mutator)

/// Tarcza i wskaźnik gałki w wyglądzie z Setup ▸ Options ▸ Knob style. Kreseczki min/max
/// rysuje wołający — różnią się kolorem zależnie od tła pod gałką. Kolejność:
/// `draw` → kreseczki i zabarwienie morfu → `drawPointer`.
enum KnobFace {
    /// Rysuje tarczę i zwraca promień powierzchni, na której leżą wskaźnik i zabarwienie morfu.
    /// `fraction` (0…1, jak wskaźnik) potrzebuje tylko styl Future — pasek wartości.
    @discardableResult
    static func draw(_ ctx: GraphicsContext, center c: CGPoint, radius r: CGFloat,
                     style look: KnobLook, fraction: Double) -> CGFloat
    {
        let outer = circle(c, r)
        switch look.style {
        case .light:
            // Blik: jaśniej u lewej-góry, ciemniej u prawej-dołu — wypukłość. W środku
            // płaskie koło bez gradientu i bez obwódki (od 2026-09-27, jak Future).
            let face = r * 0.80
            ctx.fill(Path(ellipseIn: outer), with: gradient(0.36, 0.12, in: outer))
            ctx.fill(Path(ellipseIn: circle(c, face)), with: gradient(0.86, 0.44, in: circle(c, face)))
            ctx.fill(Path(ellipseIn: circle(c, face * 0.64)), with: .color(Color(white: 0.66)))
            return face
        case .dark:
            // Jak gałki wtyczki DAW: jedna ciemna tarcza z tym samym blikiem.
            ctx.fill(Path(ellipseIn: outer), with: gradient(0.34, 0.2, in: outer))
            ctx.stroke(Path(ellipseIn: outer), with: .color(.black.opacity(0.5)),
                       lineWidth: max(0.4, r * 0.08))
            return r * 0.80
        case .future:
            return drawFuture(ctx, center: c, radius: r, fraction: fraction, look: look)
        }
    }

    /// Wskaźnik wartości: kreska od środka ku brzegowi tarczy `face`.
    static func drawPointer(_ ctx: GraphicsContext, center c: CGPoint, radius r: CGFloat,
                            face: CGFloat, fraction: Double, style look: KnobLook, dimmed: Bool = false)
    {
        let future = look.style == .future
        let angle = CGFloat(135.0 + fraction * 270.0) * (.pi / 180.0)
        let length = face * (future ? 0.80 : 0.72)
        var pointer = Path()
        pointer.move(to: c)
        pointer.addLine(to: CGPoint(x: c.x + cos(angle) * length, y: c.y + sin(angle) * length))
        let color = look.blackPointer ? UIColor.knobFuturePointer : .white
        ctx.stroke(pointer, with: .color(color.opacity(dimmed ? 0.45 : look.blackPointer ? 1 : 0.9)),
                   style: StrokeStyle(lineWidth: max(future ? 0.6 : 0.5, r * (future ? 0.14 : 0.15)),
                                      lineCap: .round))
    }

    /// Future: czarny pierścień, w nim pasek od minimum do wartości — węższy od
    /// pierścienia, żeby czarny brzeg zostawał widoczny po obu stronach. Gradient
    /// tylko na jasnym okręgu; środek płaski, z cienkim uskokiem na brzegu.
    /// Pasek to ciągła linia albo 16/32 odcinki z przerwami (zapala się każdy odcinek,
    /// w który sięga wartość; zgaszonych nie widać) — kolor, podział i blask (`Glow`) z Options.
    private static func drawFuture(_ ctx: GraphicsContext, center c: CGPoint, radius r: CGFloat,
                                   fraction: Double, look: KnobLook) -> CGFloat
    {
        let face = r * 0.76
        ctx.fill(Path(ellipseIn: circle(c, r)), with: gradient(0.10, 0.02, in: circle(c, r)))
        let color = look.rangeColor == .red ? UIColor.knobFutureRangeRed : UIColor.knobFutureRange
        let lineWidth = (r - face) * 0.30
        let arcRadius = (r + face) / 2
        let segments = look.rangeSegments.rawValue
        var range = Path()
        if segments == 0, fraction > 0.001 {
            range.addArc(center: c, radius: arcRadius, startAngle: .degrees(135),
                         endAngle: .degrees(135 + fraction * 270), clockwise: false)
        } else if segments > 0 {
            let step = 270.0 / Double(segments)
            let gap = step * 0.42
            let lit = Int((fraction * Double(segments) - 0.001).rounded(.up))
            for i in 0 ..< min(lit, segments) {
                let start = 135 + Double(i) * step + gap / 2
                // Bez `move` addArc łączy odcinek z końcem poprzedniego — przerwy znikały.
                let radians = CGFloat(start * .pi / 180)
                range.move(to: CGPoint(x: c.x + cos(radians) * arcRadius, y: c.y + sin(radians) * arcRadius))
                range.addArc(center: c, radius: arcRadius, startAngle: .degrees(start),
                             endAngle: .degrees(start + step - gap), clockwise: false)
            }
        }
        if !range.isEmpty {
            let cap: CGLineCap = segments == 0 ? .round : .butt
            Glow.stroke(ctx, range, color: color, lineWidth: lineWidth, cap: cap, amount: look.glow)
            ctx.stroke(range, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: cap, lineJoin: .round))
            // Przy mocnym blasku środek paska jaśnieje — jak rozgrzany żarnik.
            if look.glow > 0.5 {
                ctx.stroke(range, with: .color(.white.opacity((look.glow - 0.5) * 1.1)),
                           style: StrokeStyle(lineWidth: lineWidth * 0.35, lineCap: cap, lineJoin: .round))
            }
        }
        ctx.fill(Path(ellipseIn: circle(c, face)), with: gradient(0.92, 0.44, in: circle(c, face)))
        let flat = circle(c, face * 0.64)
        ctx.fill(Path(ellipseIn: flat), with: .color(Color(white: 0.74)))
        ctx.stroke(Path(ellipseIn: flat), with: gradient(0.50, 0.95, in: flat), lineWidth: max(0.35, r * 0.035))
        return face
    }

    private static func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
        CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    }

    /// Gradient pod kątem 45°, od lewej-górnej krawędzi koła do prawej-dolnej — światło
    /// pada z lewej-góry, tak samo jak na przyciskach (`Bevel`). Do 2026-09-27 szedł
    /// z góry na dół i gałki kłóciły się z przyciskami obok (uwaga użytkownika).
    private static func gradient(_ lit: Double, _ shaded: Double,
                                 in rect: CGRect) -> GraphicsContext.Shading
    {
        let reach = rect.width / 2 * 0.5.squareRoot()
        return .linearGradient(Gradient(colors: [Color(white: lit), Color(white: shaded)]),
                               startPoint: CGPoint(x: rect.midX - reach, y: rect.midY - reach),
                               endPoint: CGPoint(x: rect.midX + reach, y: rect.midY + reach))
    }
}

// MARK: - Wypukłość i wgłębienie (przyciski, ekrany)

/// Światło pada z lewej-góry: przycisk ma jasną lewą i górną krawędź, a ciemną prawą i dolną;
/// ekran leży głębiej niż panel, więc u niego odwrotnie.
enum Bevel {
    static func recess(_ ctx: GraphicsContext, _ rect: CGRect, cornerRadius: CGFloat) {
        recess(ctx, Path(roundedRect: rect, cornerRadius: cornerRadius))
    }

    static func raise(_ ctx: GraphicsContext, _ rect: CGRect, cornerRadius: CGFloat) {
        raise(ctx, Path(roundedRect: rect, cornerRadius: cornerRadius))
    }

    /// Dowolny kształt, np. trójkąt resetu nad gałką.
    static func recess(_ ctx: GraphicsContext, _ shape: Path) {
        edges(ctx, shape, topLeft: .black, topLeftOpacity: 0.5,
              bottomRight: .white, bottomRightOpacity: 0.26)
    }

    static func raise(_ ctx: GraphicsContext, _ shape: Path) {
        edges(ctx, shape, topLeft: .white, topLeftOpacity: 0.5,
              bottomRight: .black, bottomRightOpacity: 0.26)
    }

    /// Pasek wzdłuż krawędzi od środka: obrys tego samego kształtu przesunięty o `d`
    /// i przycięty do kształtu zostawia tylko krawędzie po stronie przesunięcia.
    /// Kilka coraz szerszych, słabych pasków na sobie daje miękkie przejście — najciemniej
    /// (najjaśniej) przy samej krawędzi, zanika ku środkowi.
    private static func edges(_ ctx: GraphicsContext, _ shape: Path,
                              topLeft: Color, topLeftOpacity: Double,
                              bottomRight: Color, bottomRightOpacity: Double)
    {
        let layers = 4
        let bounds = shape.boundingRect
        let step = min(0.14, min(bounds.width, bounds.height) * 0.035)
        var inner = ctx
        inner.clip(to: shape)
        for layer in 1 ... layers {
            let d = step * CGFloat(layer)
            inner.stroke(shape.offsetBy(dx: d, dy: d),
                         with: .color(topLeft.opacity(topLeftOpacity / Double(layers))), lineWidth: d * 2)
            inner.stroke(shape.offsetBy(dx: -d, dy: -d),
                         with: .color(bottomRight.opacity(bottomRightOpacity / Double(layers))),
                         lineWidth: d * 2)
        }
    }
}

// MARK: - Przycisk i ekran jako całość (wypełnienie + obrys + cieniowanie)

/// Wszystko, co stoi w panelu, rysuje się tymi dwiema funkcjami: przycisk jest wypukły,
/// a ekran, dioda czy tor fadera wklęsły. `shaded` to opcja „3D Buttons and Screens";
/// jest wymagana, więc nowy element nie może po cichu zgubić cieniowania — do 2026-09-27
/// każde miejsce powtarzało te trzy kroki samo i kilka ekranów zostało płaskich.
enum PanelFace {
    static func raised(_ ctx: GraphicsContext, _ shape: Path, fill: Color,
                       border: Color = UIColor.buttonBorder, lineWidth: CGFloat = 0.4, shaded: Bool)
    {
        ctx.fill(shape, with: .color(fill))
        ctx.stroke(shape, with: .color(border), lineWidth: lineWidth)
        if shaded { Bevel.raise(ctx, shape) }
    }

    static func raised(_ ctx: GraphicsContext, _ rect: CGRect, cornerRadius: CGFloat, fill: Color,
                       border: Color = UIColor.buttonBorder, lineWidth: CGFloat = 0.4, shaded: Bool)
    {
        raised(ctx, Path(roundedRect: rect, cornerRadius: cornerRadius), fill: fill,
               border: border, lineWidth: lineWidth, shaded: shaded)
    }

    /// `fill: nil` — zawartość ekranu narysowano wcześniej, pod ramką (siatka SeqNote).
    static func recessed(_ ctx: GraphicsContext, _ shape: Path, fill: Color?,
                         border: Color = UIColor.screenBorder, lineWidth: CGFloat = 0.5, shaded: Bool)
    {
        if let fill { ctx.fill(shape, with: .color(fill)) }
        ctx.stroke(shape, with: .color(border), lineWidth: lineWidth)
        if shaded { Bevel.recess(ctx, shape) }
    }

    static func recessed(_ ctx: GraphicsContext, _ rect: CGRect, cornerRadius: CGFloat, fill: Color?,
                         border: Color = UIColor.screenBorder, lineWidth: CGFloat = 0.5, shaded: Bool)
    {
        recessed(ctx, Path(roundedRect: rect, cornerRadius: cornerRadius), fill: fill,
                 border: border, lineWidth: lineWidth, shaded: shaded)
    }
}

// MARK: - Metryki UI (rozmiary, promienie, grubości linii)

enum UIMetrics {
    // Przyciski
    static let buttonFlatHeight: CGFloat = 7.0
    static let buttonFlatCornerRadius: CGFloat = 1.5
    static let buttonTextHeight: CGFloat = 6.5
    static let buttonCornerRadius: CGFloat = 1.0
    static let buttonRadioHeight: CGFloat = 7.0
    static let buttonRadioMinWidth: CGFloat = 6.0
    /// Shared side length for compact square controls: sequencer steps and +/- buttons.
    static let compactSquareButtonSize: CGFloat = 10.0 * (140.0 / 256.0)
    static let incDecWidth: CGFloat = compactSquareButtonSize
    static let incDecHeight: CGFloat = compactSquareButtonSize
    static let incDecGap: CGFloat = 0.5
    // TextField (LCD)
    static let textFieldHeight: CGFloat = 6.5
    static let textFieldMinWidth: CGFloat = 12.0
    /// Gniazda kabli
    static let connectorHalf: CGFloat = 2.8 // połowa boku/promień = 5.6pt całość
    /// Zaokrąglenie rogów kwadratowego gniazda i przycisku Power — wspólne, bo oba
    /// elementy stoją w jednej kolumnie i mają wyglądać identycznie.
    static let socketCornerRadius: CGFloat = 1.0
    /// Bok kolorowego środka Power = bok kolorowego środka kwadratowego gniazda
    /// (bez ciemnej obwódki dookoła — tę dokłada się osobno, patrz socketOuterMargin).
    static let powerButtonSize: CGFloat = connectorHalf * 2
    /// Grubość ciemnej obwódki/cienia dookoła gniazda — Power dostaje tę samą, żeby
    /// oba elementy (kolor + obwódka razem) miały identyczny rozmiar całkowity.
    static let socketOuterMargin: CGFloat = 0.6
    /// Wykresy graficzne
    static let graphCornerRadius: CGFloat = 1.5
    /// Wspólna grubość krzywych fal, obwiedni i charakterystyk na ekranach.
    static let graphLineWidth: CGFloat = 0.65
    // MiniVU — wskaźnik jest większy niż oryginał BVerhue (szerokość ×4/5, wysokość
    // ×4/3), więc jego górna krawędź leży `miniVUTopShift` nad zapisanym YPos.
    // Wspólne z etykietami, które muszą trzymać odstęp od wskaźnika.
    static let miniVUWidth: CGFloat = 8 * (140.0 / 256.0) * (4.0 / 5.0)
    static let miniVUHeight: CGFloat = 15 * (140.0 / 256.0) * (4.0 / 3.0)
    static let miniVUTopShift: CGFloat = 2.0
    /// Liczba diod wskaźnika: 12, jak w oryginale (Peak Meter (Draw)) — 7 zielonych,
    /// 4 żółte i jedna czerwona dioda przesteru. Do 2026-09-27 było 15 (cztery czerwone),
    /// ale przester przychodzi znacznikiem `0x40`, nie poziomem 13–15, więc z czterech
    /// czerwonych zapalała się tylko najniższa i słupek nie sięgał góry → [[Docs/ui/widgets]].
    static let miniVUSegments = 12
    // Diody LED
    static let ledGreenSize: CGFloat = 3.0 // bok kwadratu LED (canvas pt)
    static let ledSeqWidth: CGFloat = 10.0 * (140.0 / 256.0) // ≈5.47 pt — wyrównany do szerokości slidera
    static let ledSeqHeight: CGFloat = 4.0 * (140.0 / 256.0) // ≈2.19 pt — 4 Gen1px
    /// Sekwencer fadery (SeqCtr / SeqLev / SeqNote)
    static let seqFaderWidth: CGFloat = compactSquareButtonSize // ≈5.47 pt — 10 Gen1px
    /// ▲/▼ pod faderem są KWADRATOWE i mają dokładnie ten sam bok co przyciski kroku
    /// pod nimi — a te rysowane są kwadratem o boku równym szerokości toru.
    static let seqFaderIncDecH: CGFloat = seqFaderWidth
    /// Szczelina między ▲ i ▼ = grubość magistrali, która biegnie przez oś pary —
    /// oba przyciski przylegają do niej ramkami, ale nie stykają się ze sobą.
    static let seqFaderGap: CGFloat = 0.5
    /// Odstęp między parą ▲/▼ a rzędem przycisków pod nią (moduły bez własnego
    /// gniazda w rzędzie ▲/▼, np. MixFader). 4 Gen1px — tyle trzyma BVerhue.
    static let faderGroupGap: CGFloat = 4.0 * (140.0 / 256.0)
    /// Prześwit nad torem i pod torem — jednakowy z obu stron, więc tor jest
    /// wyśrodkowany między diodą/ekranem a parą ▲/▼. Ciaśniejszy niż odstęp
    /// grupowy, żeby sam tor był możliwie długi.
    static let faderTrackGap: CGFloat = 1.4
    /// Wysokość toru — JEDNA dla wszystkich modułów z faderami (SeqCtr, SeqLev,
    /// MixFader), bo panele dają im różną ilość miejsca, a widżet ma wyglądać
    /// wszędzie tak samo. Tor jest w dostępnej przestrzeni wyśrodkowany.
    /// SeqNote jest wyjątkiem: tam „tor" to siatka nut, która korzysta z całej
    /// wysokości, jaką ma panel.
    static let faderTrackHeight: CGFloat = 21.6
    // Kable
    static let cableShadowWidth: CGFloat = 2.8
    static let cableWidth: CGFloat = 1.8
    /// Styl „Thin" z okna Options — sama linia, bez cienia, więc i cieńsza.
    static let cableThinWidth: CGFloat = 0.9
}

// MARK: - Knob drag state

struct KnobDragTarget {
    let moduleID: Int
    let paramIndex: Int
    let startValue: Int
    let startY: CGFloat // gesture.startLocation.y w układzie Canvas
    let fine: Bool // Shift trzymany przy starcie → 10× wolniejszy obrót
    let sensitivity: CGFloat // units/pt — wyższe dla sliderów (≈127/sliderH), niższe dla gałek (0.4)
    let readout: SliderReadout
    /// Początek gestu i środek tarczy w układzie canvasu — dla trybów „Horizontal"
    /// i „Circular" z okna Options (instrukcja, str. 125).
    var startPoint: CGPoint = .zero
    var center: CGPoint = .zero // z czego złożyć dymek z wartością
    /// Zakres morfu na starcie gestu — używane tylko, gdy `isMorph`.
    var startRange: Int = 0
    /// Option trzymany przy starcie → gest zmienia ZAKRES MORFU, nie wartość parametru.
    /// Tak samo rozpoznaje to oryginał: Control (ClickDragOnClickHandler) sprawdza
    /// `IsDragCopyKeyDown` (na Macu Option) i przechodzi w `gLockMode == 2`.
    var isMorph: Bool = false
}

/// Skąd wziąć tekst wartości suwaka. Te same dwa źródła co dymek po najechaniu:
/// powiązane pole tekstowe (jeśli suwak je ma) albo InfoFunc samego suwaka.
/// Trzymamy źródła, nie gotowy napis, żeby dymek podczas przeciągania odświeżał
/// się razem z parametrem.
struct SliderReadout {
    let moduleID: Int
    let paramIndex: Int
    let infoFunc: Int
    let textField: BVTextField?
}

// MARK: - Connector drag state

struct ConnectorEndpoint {
    let moduleID: Int
    let connIndex: Int
    let isOutput: Bool
    let center: CGPoint // logiczne pt (bez zoom)
    let signalType: BVSignalType
}

/// Nowy kabel — drag z pustego gniazda
struct ConnectorDragState {
    let source: ConnectorEndpoint
    var tipPt: CGPoint
}

/// Repatch — złapanie końcówki istniejącego kabla
struct RepatchDragState {
    let anchor: ConnectorEndpoint // koniec który zostaje
    let originalCable: G2Cable
    var tipPt: CGPoint // koniec który przeciągamy
}

/// Klucz cyklowania kabli na jednym gnieździe
struct ConnectorCycleKey: Hashable {
    let moduleID: Int
    let connIndex: Int
    let isOutput: Bool
}

// MARK: - Hover state

/// Element UI pod kursorem myszy (knob lub interaktywny przycisk).
struct ParamHoverHit {
    let moduleID: Int
    let paramIndex: Int
    let infoFunc: Int // dla knobów — indeks g2InfoFunction; -1 = brak
    let paramName: String // fallback gdy brak opcji
    let isKnob: Bool
    /// Opcje tekstowe do wyświetlenia aktualnej wartości (np. ["Off","On"], nazwy fal).
    /// Nil = brak listy, użyj paramName lub g2InfoFunction.
    let displayOptions: [String]?
    /// Pole tekstowe powiązane z tym knobem (może wyświetlać kilka wartości jednocześnie).
    /// Gdy ustawione — użyj g2TextFunction zamiast g2InfoFunction dla wiersza 1.
    let linkedTextField: BVTextField?
    /// Pozycja paska ▼▲ w pt kanwy (bez zoomu), nil gdy nie knob rotacyjny.
    let btnsRect: CGRect?
    /// Prawy dolny róg elementu w pt kanwy (bez zoomu). Lewy bok tooltipa wyrośnie
    /// stąd w prawo. Zoom mnoży się dopiero przy rysowaniu: do 2026-09-27 trafienie
    /// trzymało pozycje już przemnożone, więc przy zoomie bez ruchu myszy dymek i ▼▲
    /// zostawały w starym miejscu, z dala od gałki.
    let tooltipAnchor: CGPoint
    /// PartSelector bez własnego parametru (np. GateMode1/2, D/S FlipFlopa) trzyma
    /// bieżącą wartość w `module.modes[paramIndex]`, nie w `module.parameters` —
    /// bez tej flagi hover pokazywał zawsze surowe `parameters[0]` (najczęściej 0),
    /// niezależnie od faktycznie wybranego stanu.
    var usesModes: Bool = false
}

// MARK: - Module drag state

struct ModuleDragState {
    let moduleID: Int
    let startColumn: Int
    let startRow: Int
    let extraModules: [(id: Int, startColumn: Int, startRow: Int)]
    var dragOffset: CGSize // pt w przestrzeni canvas (bez zoom)
}

struct ModuleHit {
    let moduleID: Int
    let column: Int
    let row: Int
}

/// Stan rozwijanej listy dla ekranowego selektora parametrów.
struct SelectorPickerState: Identifiable {
    let id = UUID()
    let moduleID: Int
    let moduleTypeID: Int
    let codeRef: Int
    let usesParameter: Bool
    let infoFunc: Int
    let optionCount: Int
    let modeName: String
    let showsWaveOptions: Bool
    /// Selektor pokazuje na zamkniętym ekranie tekst LCD (np. Range w Delayach) —
    /// rozwinięta lista ma wyglądać jak ten ekran powielony w dół, nie jak menu systemowe.
    let showsLcdText: Bool
    /// Prostokąt w układzie Canvasu, bez aktualnego przybliżenia.
    /// Pozycja listy jest z niego wyliczana na nowo przy każdej zmianie zoomu.
    let canvasRect: CGRect
    let selectedValue: Int
}

/// Stan menu podmiany otwartego z kolorowego przycisku w nagłówku modułu.
struct ModuleReplacementPickerState: Identifiable {
    let id = UUID()
    let moduleID: Int
    let sourceTypeID: Int
    let canvasRect: CGRect
}

// MARK: - PatchCanvasView

struct PatchCanvasView: View {
    let patch: G2Patch
    let area: PatchArea
    let zoom: CGFloat
    var hiddenColors: Set<CableColor> = []
    var cableShakeSeed: UInt64 = 0
    /// Nakładka żółtych dymków (F5–F8) — patrz `PatchCanvasView+Overlays.swift`.
    var overlayMode: CanvasOverlayMode = .none
    /// Wygląd kabli i sposób kręcenia gałkami — okno „Setup ▸ Options" (str. 125).
    var cableStyle: CableStyle = .curved3D
    var knobControl: KnobControl = .vertical
    /// Wygląd tarcz gałek (styl, podział i kolor paska Future); podglądy modułów biorą zapisany wybór.
    var knobStyle: KnobLook = .stored
    /// Przyciski wypukłe, ekrany wgłębione (`Bevel`) — wyłącznik w menu View.
    var panelShading: Bool = PanelShading.stored
    /// Pod kanwą leży warstwa ze spektrogramem emulatora — wtedy kanwa NIE maluje
    /// swojego tła, bo zasłoniłaby obraz (patrz `SpectrogramPanel.swift`).
    var showsBackdrop: Bool = false
    /// Połączenie z urządzeniem — przekazywane WYŁĄCZNIE po to, żeby oddać je warstwie
    /// `LiveIndicatorLayer`. Ta kanwa nie czyta z niego żadnego pola i dzięki temu
    /// strumień wskaźników jej nie unieważnia (patrz `LiveIndicatorLayer`).
    var device: DeviceConnection?
    /// Slot pokazany w edytorze — warstwa wskaźników odrzuca strumień z innego slotu.
    var slot: Int = 0
    /// Zaznaczenie tej kanwy. Leży na zewnątrz, bo czyta je też menu Edit — patrz
    /// `CanvasSelection`. Podglądy (`ImageRenderer`) dostają własne, puste.
    var selection = CanvasSelection()
    /// Minimalny rozmiar canvasu — wypełnia widoczny obszar ScrollView (przekazywane z GeometryReader).
    var minSize: CGSize = .zero
    /// Tryb podglądu — wyłącza NSViewRepresentable overlay (DropTarget) i nakładki interakcji.
    /// Używany przez ImageRenderer przy generowaniu drag image.
    var isPreviewMode: Bool = false
    /// Callback wywoływany gdy użytkownik zmieni wartość parametru przeciągając knob.
    var onParameterChange: ((_ moduleID: Int, _ paramIndex: Int, _ newValue: Int) -> Void)?
    /// Zmiana chwilowa (przycisk Push) — wartość wraca sama, więc nie trafia na stos undo.
    var onMomentaryParameterChange: ((_ moduleID: Int, _ paramIndex: Int, _ newValue: Int) -> Void)?
    /// Morf, do którego przypisuje parametry Option-przeciąganie gałki (patrz `MorphBarView`).
    var focusedMorph: Int = 0
    /// Zmiana zakresu morfu gestem na gałce — `nil` w trybie podglądu.
    var onMorphRangeChange: ((_ moduleID: Int, _ paramIndex: Int, _ range: Int) -> Void)?
    /// ⌘-klik gałki: parametr na stronę parametrów z focusem (patrz `ParameterPagesPanel`).
    var onKnobAssign: ((_ moduleID: Int, _ paramIndex: Int) -> Void)?
    /// An overview display was dropped on a parameter control in this patch area.
    var onParameterPageKnobDrop: ((_ knob: Int, _ moduleID: Int, _ paramIndex: Int) -> Void)?
    /// Start gestu ciągłego (przeciąganie gałki/fadera, przytrzymany +/−) — wszystkie zmiany
    /// aż do `onParameterGestureEnded` mają się cofać jednym ⌘Z.
    var onParameterGestureBegan: (() -> Void)?
    /// Koniec gestu ciągłego.
    var onParameterGestureEnded: (() -> Void)?

    // Aktywny drag (nil gdy brak aktywnego gestu)
    @State var dragTarget: KnobDragTarget?
    @State var connectorDrag: ConnectorDragState?
    @State var repatchDrag: RepatchDragState?
    @State var moduleDrag: ModuleDragState?
    /// Multi-select — przechowalnią jest `selection`, tu zostaje sama nazwa, żeby
    /// kilkadziesiąt miejsc w rozszerzeniach kanwy nie musiało o tym wiedzieć.
    var selectedModuleIDs: Set<Int> {
        get { selection.moduleIDs }
        nonmutating set { selection.moduleIDs = newValue }
    }

    @State var rubberBandStart: CGPoint?
    @State var rubberBandCurrent: CGPoint?

    /// Indeks cyklowania kabli: który kabel podnieść przy kolejnym dragu z danego gniazda.
    @State var cycleIndex: [ConnectorCycleKey: Int] = [:]

    // Hover
    @State var hoverHit: ParamHoverHit?
    @State var hoverScreenPt: CGPoint = .zero

    /// Gotowe obrazki modułów — patrz `ModuleRasterCache`. Podglądy (`isPreviewMode`)
    /// rysują wektorowo i tej pamięci nie tykają.
    @State var rasters = ModuleRasterCache()
    /// Licznik przerysowań zamawianych przez `rasters` (świeże obrazki gotowe) — kanwa
    /// go czyta, więc każde podbicie ją odświeża.
    @State var rasterGeneration = 0
    @State private var rasterZoomCommit: Task<Void, Never>?

    // Slider tooltip (pokazuje się po kliknięciu ▲/▼ lub przeciąganiu)
    @State var seqSliderTooltip: (readout: SliderReadout, x: CGFloat, y: CGFloat)?
    @State var seqTooltipTask: Task<Void, Never>?

    // Chwilowe podświetlenie przycisku (Clr/Rnd) — gaśnie po 200ms
    @State var momentaryFlash: (moduleID: Int, codeRef: Int)?
    @State var momentaryFlashTask: Task<Void, Never>?

    // Vocoder: ostatnio wybrany preset pozostaje podświetlony jak aktywny przycisk.
    @State var vocoderSelectedPreset: [Int: Int] = [:]

    // SeqNote: poziom powiększenia klawiszy piano (0=3 oktawy, 1=2 oktawy, 2=1 oktawa)
    @State var seqNoteZoomLevel: [Int: Int] = [:]
    // SeqNote: scroll offset (⌥+scroll) — loNote widocznego okna nut; nil = auto-center na aktywnych nutach
    @State var seqNoteScrollOffset: [Int: Int] = [:]
    // SeqNote: mignięcie przycisku oktawy ▲▼ (zaświeca niebiesko przez 150ms)
    @State var octaveButtonFlash: (moduleID: Int, isUp: Bool)?
    @State var octaveButtonFlashTask: Task<Void, Never>?
    // Seq fader ▲▼: mignięcie przycisku per-krok (moduleID + codeRef + isUp)
    @State var faderButtonFlash: (moduleID: Int, codeRef: Int, isUp: Bool)?
    @State var faderButtonFlashTask: Task<Void, Never>?
    // BVButtonIncDec (+/-): przytrzymanie → auto-powtarzanie kroku (patrz incDecPressGesture)
    @State var incDecHold: IncDecHoldState?
    @State var incDecRepeatTask: Task<Void, Never>?
    /// Rozwijana lista wartości ekranowego selektora.
    @State var selectorPicker: SelectorPickerState?
    /// Wartość wiersza rozwiniętej listy aktualnie pod kursorem (podświetlenie).
    @State var selectorPickerHoveredValue: Int?
    @State var moduleReplacementPicker: ModuleReplacementPickerState?
    @State var moduleReplacementHoveredTypeID: Int?

    /// Aktywny moduł (ostatnio kliknięty) — dolna i prawa krawędź w kolorze canvasu.
    var activeModuleID: Int? {
        get { selection.activeID }
        nonmutating set { selection.activeID = newValue }
    }

    /// Kontrolka, której dotyczą strzałki — patrz `PatchCanvasView+KeyNavigation.swift`.
    @State var focusedParam: ParameterFocus?
    // Edycja nazwy modułu (double-click na pasek nagłówka)
    @State var editingModuleID: Int?
    @State var editingText: String = ""
    @FocusState var nameFieldFocused: Bool
    var onModeChange: ((_ moduleID: Int, _ modeIndex: Int, _ newValue: Int) -> Void)?
    var onAddCable: ((_ cable: G2Cable) -> Void)?
    var onRemoveCable: ((_ cable: G2Cable) -> Void)?
    /// Przepinanie kabla: wyrwanie i wpięcie mają być JEDNYM wpisem undo
    /// (patrz `PatchState.beginStructureGesture`).
    var onStructureGestureBegan: ((_ actionName: String) -> Void)?
    var onStructureGestureEnded: (() -> Void)?
    var onMoveModule: ((_ moduleID: Int, _ newColumn: Int, _ newRow: Int, _ push: G2Patch.PushDirection) -> Void)?
    var onRenameModule: ((_ moduleID: Int, _ label: String) -> Void)?
    var onDeleteModules: ((_ moduleIDs: Set<Int>) -> Void)?
    var onColorModule: ((_ moduleID: Int, _ color: UInt8) -> Void)?
    /// `Exclude From Mutations` z menu kontekstowego — Patch Mutator omija te moduły.
    var onExcludeFromMutation: ((_ moduleIDs: Set<Int>, _ excluded: Bool) -> Void)?
    /// Czy okno Patch Mutatora jest otwarte. Tylko wtedy oryginał obwodzi wyłączone
    /// moduły cienką czerwoną ramką (`CPanel::SetMutaLockVisible`).
    var mutatorVisible: Bool = false
    /// Czy obowiązuje „Only audible" (wysunięty panel „Mutation settings" i przycisk On).
    /// Wtedy moduły, których nie słychać (`G2AudibilityMap`), są przygaszone — „nic nie
    /// robi" odróżnione od „chroniony".
    var audibilityVisible: Bool = false
    var onReplaceModule: ((_ moduleID: Int, _ targetTypeID: Int) -> Void)?
    var onAddModuleAt: ((_ typeID: Int, _ column: Int, _ row: Int) -> Void)?
    /// Wklej moduły ze schowka (⌘V) — wywołuje G2PatchDocument.pasteModules
    var onPasteModules: ((_ content: G2ClipboardContent) -> Void)?
    /// Polecenia menu pod prawym przyciskiem, których kanwa nie wykona sama —
    /// przypisania gałek i CC, operacje na kablach, „Paste Params" (patrz
    /// `PatchCanvasCommands`). Puste w trybie podglądu.
    var commands = PatchCanvasCommands()
    /// Kontroler zoom/pan (CanvasZoomPanController) — ContentView woła przezeń zoom
    /// z przycisków/skrótów; nil w trybie podglądu (ImageRenderer).
    var zoomPanController: CanvasZoomPanController?
    /// Wywoływane przy każdej zmianie zoomu (pinch, ⌘scroll, przyciski) — synchronizuje
    /// zoom z powrotem do @State w ContentView.
    var onZoomChange: ((CGFloat) -> Void)?

    var modules: [G2Module] {
        patch.modules(in: area)
    }

    var cables: [G2Cable] {
        patch.cables(in: area)
    }

    private func def(_ typeID: Int) -> ModuleDef? {
        ModuleDatabase.module(id: typeID)
    }

    /// Wspólny punkt dostępu do definicji dla wydzielonych plików renderingu.
    func moduleDefinition(_ typeID: Int) -> ModuleDef? {
        def(typeID)
    }

    var rowOffset: Int {
        PatchLayout.minRow(modules: modules)
    }

    /// Canvas ma rozmiar treści (min. widoczny obszar) — bez zapasu przewijania.
    /// Rączka (SPACE+drag) działa więc tylko wtedy, gdy patch nie mieści się w oknie,
    /// i to jest zamierzone: pusty obszar do przewijania sugerowałby, że można w nim
    /// postawić moduł, a siatka G2 na to nie pozwala (patrz `PatchLayout.padding`).
    var canvasSize: CGSize {
        let base = PatchLayout.canvasSize(modules: modules, defs: def, rowOffset: rowOffset)
        return CGSize(
            width: max(base.width * zoom, minSize.width),
            height: max(base.height * zoom, minSize.height)
        )
    }

    // MARK: - Preview body (dla ImageRenderer)

    /// Minimalny widok do użycia przez ImageRenderer — tylko Canvas, bez NSViewRepresentable,
    /// gestów, keyboard shortcutów i contextMenu, które blokują ImageRenderer.
    /// Wywołuj przez: let pv = PatchCanvasView(...); pv.previewBody
    var previewBody: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero,
                                 size: CGSize(width: size.width / zoom, height: size.height / zoom))),
                     with: .color(UIColor.canvasBackground))
            ctx.scaleBy(x: zoom, y: zoom)
            drawModules(ctx)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    // MARK: - Obrazki modułów a zoom

    /// Ile ciszy po ostatnim kroku zoomu (pinch, ⌘scroll, przycisk) czekamy, zanim
    /// obrazki modułów powstaną na nowo w bieżącym powiększeniu.
    private static let rasterZoomSettleDelay: UInt64 = 150_000_000

    /// W trakcie gestu kanwa wkleja obrazki w starym powiększeniu, przeskalowane; po
    /// ustaniu gestu rysuje je na ostro jeden raz. Każdy kolejny krok przesuwa termin.
    func scheduleRasterZoomCommit() {
        guard !isPreviewMode else { return }
        rasterZoomCommit?.cancel()
        let target = zoom
        let owner = self
        rasterZoomCommit = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.rasterZoomSettleDelay)
            guard !Task.isCancelled else { return }
            rasters.setRasterZoom(target) { key, def in
                ModuleRasterView.render(owner: owner, key: key, def: def)
            }
            rasterGeneration += 1
        }
    }

    // MARK: - Interactive body

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                // Background — dark gray like the original G2 editor
                if !showsBackdrop {
                    ctx.fill(Path(CGRect(origin: .zero, size: CGSize(width: size.width / zoom, height: size.height / zoom))),
                             with: .color(UIColor.canvasBackground))
                }
                ctx.scaleBy(x: zoom, y: zoom)
                // Odczyt licznika wiąże kanwę ze świeżymi obrazkami modułów.
                _ = rasterGeneration
                drawModules(ctx)
            }
            .gesture(combinedDragGesture)
            // Rename tylko przez menu kontekstowe (brak double-tap — unikamy opóźnienia single-tap)
            .onTapGesture { location in
                let lp = CGPoint(x: location.x / zoom, y: location.y / zoom)
                // Zamknij edytor nazwy klikając poza nim; kontynuuj obsługę kliknięcia
                if editingModuleID != nil {
                    commitNameEdit()
                }
                if let module = modules.reversed().first(where: { candidate in
                    let rect = PatchLayout.moduleRect(
                        candidate,
                        def: moduleDefinition(candidate.typeID),
                        rowOffset: rowOffset,
                        allModules: modules
                    )
                    return candidate.typeID != 126 &&
                        PatchLayout.replacementIconRect(in: rect).contains(lp)
                }), ModuleReplacementDatabase.candidates(for: module.typeID).count > 1 {
                    let rect = PatchLayout.moduleRect(
                        module,
                        def: moduleDefinition(module.typeID),
                        rowOffset: rowOffset,
                        allModules: modules
                    )
                    selectorPicker = nil
                    moduleReplacementPicker = ModuleReplacementPickerState(
                        moduleID: module.id,
                        sourceTypeID: module.typeID,
                        canvasRect: PatchLayout.replacementIconRect(in: rect)
                    )
                    activeModuleID = module.id
                    return
                }
                // ⌘ + klik gałki → parametr ląduje na stronie parametrów z focusem.
                // Oryginał ma tu ⌘ + przeciągnięcie na okno gałek
                // (Control (TryKnobAssign)) → [[Docs/ui/parameter-pages]].
                if NSEvent.modifierFlags.contains(.command), let hit = findKnob(at: lp) {
                    onKnobAssign?(hit.moduleID, hit.paramIndex)
                    activeModuleID = hit.moduleID
                    return
                }
                // Ctrl + klik gałki → przypisanie do morfu z focusem. Instrukcja
                // (str. 93): „Then Ctrl-click on the knob, button or slider you wish
                // to assign to the selected Morph group." Powtórzony klik zdejmuje
                // przypisanie, jak „Morph assign" z menu pod prawym przyciskiem.
                if NSEvent.modifierFlags.contains(.control), let hit = findKnob(at: lp) {
                    let assigned = morphRange(moduleID: hit.moduleID, paramIndex: hit.paramIndex) != 0
                    onMorphRangeChange?(hit.moduleID, hit.paramIndex,
                                        assigned ? 0 : defaultMorphRange(moduleID: hit.moduleID,
                                                                         paramIndex: hit.paramIndex))
                    activeModuleID = hit.moduleID
                    return
                }
                let shiftHeld = NSEvent.modifierFlags.contains(.shift)
                if shiftHeld {
                    if let hit = findModuleBody(at: lp) {
                        if selectedModuleIDs.contains(hit.moduleID) {
                            selectedModuleIDs.remove(hit.moduleID)
                        } else {
                            selectedModuleIDs.insert(hit.moduleID)
                        }
                    }
                    return
                }
                if let reset = findKnobResetButton(at: lp) {
                    onParameterChange?(reset.moduleID, reset.paramIndex, reset.defaultValue)
                    activeModuleID = reset.moduleID
                    return
                }
                // Kliknięcie kontrolki daje jej focus — to ona odpowiada potem na strzałki
                // (instrukcja, str. 84: „Put a parameter in focus by clicking on it").
                if let hit = findKnob(at: lp) {
                    focusedParam = ParameterFocus(moduleID: hit.moduleID, paramIndex: hit.paramIndex)
                    activeModuleID = hit.moduleID
                }
                selectedModuleIDs.removeAll()
                if let hit = findModuleBody(at: lp),
                   let module = modules.first(where: { $0.id == hit.moduleID })
                {
                    let rect = PatchLayout.moduleRect(module, def: moduleDefinition(module.typeID),
                                                      rowOffset: rowOffset, allModules: modules)
                    // Kliknięcie w obszar nazwy już aktywnego modułu → rename (jak Finder)
                    if hit.moduleID == activeModuleID,
                       editingModuleID == nil,
                       isInNameArea(at: lp, module: module, rect: rect)
                    {
                        let isName = (module.typeID == 126)
                        let defLabel = isName ? "" : (ModuleDatabase.module(id: module.typeID)?.shortName ?? "")
                        editingText = module.label.isEmpty ? defLabel : module.label
                        editingModuleID = module.id
                        nameFieldFocused = true
                        return
                    }
                    activeModuleID = hit.moduleID
                } else {
                    activeModuleID = nil
                }
                handleButtonTap(at: lp, screenPos: location)
            }
            // Zero-distance drag dla +/- musi być dołączony PO tapie jako gest równoległy.
            // Umieszczenie go wewnątrz `.gesture(...)` przejmowało każdy mouseDown na Canvasie
            // i blokowało zwykłe przyciski, radio-buttony oraz inne elementy klikalne.
            .simultaneousGesture(incDecPressGesture)

            // Wskaźniki i diody na żywo — osobna, przezroczysta kanwa nad panelami.
            // Tylko ona czyta strumień z urządzenia, więc tylko ona przerysowuje się
            // 20×/s; kanwa modułów i menu kontekstowe zostają nietknięte.
            LiveIndicatorLayer(patch: patch, area: area, zoom: zoom, slot: slot,
                               canvasSize: canvasSize, device: device, panelShading: panelShading,
                               glow: knobStyle.glow)

            // Kable leżą NAD świecącymi wskaźnikami i diodami — kabel wychodzi z modułu,
            // więc zasłania to, co pod nim, tak jak zgaszony wskaźnik na kanwie modułów.
            // Do 2026-09-27 kable rysowała kanwa modułów i zapalone kreski Mini VU
            // wychodziły na wierzch kabla (uwaga użytkownika). Kanwa jest przezroczysta
            // dla myszy — gesty kabli obsługuje kanwa modułów pod spodem.
            Canvas { ctx, _ in
                ctx.scaleBy(x: zoom, y: zoom)
                drawCables(ctx)
                drawRubberBand(ctx)
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .allowsHitTesting(false)

            // Nakładka edytora nazwy modułu — pozycja obliczana live (skaluje razem z zoom)
            if let editID = editingModuleID,
               let editModule = modules.first(where: { $0.id == editID })
            {
                let ro = rowOffset
                let mods = modules
                let r = PatchLayout.moduleRect(editModule, def: moduleDefinition(editModule.typeID),
                                               rowOffset: ro, allModules: mods)
                // Pozycja i wymiary w screen-pt (uwzględnia aktualny zoom)
                let sh = PatchLayout.headerH * zoom
                let sx = r.minX * zoom
                let sy = r.minY * zoom
                // Font: canvas-pt * zoom → screen-pt (identyczny jak rysowany label)
                let fontSize = min(PatchLayout.headerH * 0.62, UIFont.moduleName) * zoom
                // X-start pola nazwy: za ikonką trójkąta (lub min padding dla typeID=126)
                let nameX: CGFloat = {
                    guard editModule.typeID != 126 else { return sx + 3.0 * zoom }
                    return PatchLayout.moduleNameStartX(in: r) * zoom
                }()
                // Szerokość pola = długość aktualnego tekstu + margines na kursor
                // (nie stałe 16 znaków — żeby nie zasłaniać kontrolek w headerze)
                let charW = fontSize * 0.62 // proporcja semibold condensed
                let textLen = max(4, editingText.count + 2) // min. 4 znaki + 2 na kursor
                let nameW = charW * CGFloat(textLen) + fontSize * 0.5
                let editH = sh * 0.82

                TextField("", text: $editingText)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(.black)
                    .tint(Color(red: 0.18, green: 0.50, blue: 0.95))
                    .padding(.horizontal, 2)
                    .frame(width: nameW, height: editH)
                    .background(Color.white)
                    .position(x: nameX + nameW / 2, y: sy + sh / 2)
                    .focused($nameFieldFocused)
                    .onSubmit { commitNameEdit() }
                    .onKeyPress(.escape) {
                        cancelNameEdit()
                        return .handled
                    }
                    .onChange(of: editingText) { _, new in
                        if new.count > 16 { editingText = String(new.prefix(16)) }
                    }
            }

            if let picker = selectorPicker {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selectorPicker = nil }

                selectorPickerView(picker)
            }

            if let picker = moduleReplacementPicker {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { moduleReplacementPicker = nil }

                moduleReplacementPickerView(picker)
            }

            if !isPreviewMode {
                hoverOverlayView
                // Tooltip po kliknięciu ▲/▼ lub przeciąganiu slidera sekwencera
                if let tip = seqSliderTooltip {
                    Text(sliderReadoutText(tip.readout))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.85)))
                        .position(x: tip.x + 22, y: tip.y - 12)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .onChange(of: zoom) { _, _ in scheduleRasterZoomCommit() }
        .onContinuousHover { phase in
            switch phase {
            case let .active(loc):
                hoverScreenPt = loc
                let lp = CGPoint(x: loc.x / zoom, y: loc.y / zoom)
                hoverHit = findHoverHit(at: lp)
            case .ended:
                hoverHit = nil
            }
        }
        .contextMenu { contextMenuItems }
        .background {
            // Delete / Backspace — usuwa całe zaznaczenie albo aktywny moduł.
            Button("") { deleteSelectedModules() }
                .keyboardShortcut(.delete, modifiers: [])
                .opacity(0).allowsHitTesting(false)

            Button("") { deleteSelectedModules() }
                .keyboardShortcut(.deleteForward, modifiers: [])
                .opacity(0).allowsHitTesting(false)

            // ⌘C — kopiuj zaznaczone moduły (lub aktywny jeśli brak zaznaczenia)
            Button("") { copySelectedModules() }
                .keyboardShortcut("c", modifiers: .command)
                .opacity(0).allowsHitTesting(false)

            // ⌘V — wklej ze schowka
            Button("") {
                if let content = G2ClipboardContent.readFromPasteboard() {
                    onPasteModules?(content)
                }
            }
            .keyboardShortcut("v", modifiers: .command)
            .opacity(0).allowsHitTesting(false)

            // ⌘A — zaznacz wszystkie moduły bieżącego obszaru (Voice/FX)
            Button("") { selectedModuleIDs = Set(modules.map(\.id)) }
                .keyboardShortcut("a", modifiers: .command)
                .opacity(0).allowsHitTesting(false)
        }
        // Drop obsługiwany przez DropTargetRepresentable (AppKit NSDraggingDestination).
        // Powód: SwiftUI .onDrop wywoływało updateDraggingItemsForDrop i zmniejszało
        // drag image wbrew naszym intencjom. Własny NSView daje pełną kontrolę.
        // Ghost preview (czarna ramka o canvas-zoom rozmiarze) renderowany dodatkowo
        // w SwiftUI — macOS skaluje OS drag image niezależnie i nie da się tego pewnie wyłączyć.
        // isPreviewMode: pomijamy NSViewRepresentable — ImageRenderer nie obsługuje AppKit views.
        .overlay(
            Group {
                if !isPreviewMode {
                    DropTargetRepresentable(
                        zoom: zoom,
                        rowOffset: rowOffset,
                        onDropModule: onAddModuleAt,
                        onDropParameterPageKnob: { knob, point in
                            guard let hit = findHoverHit(at: point), !hit.usesModes else { return false }
                            onParameterPageKnobDrop?(knob, hit.moduleID, hit.paramIndex)
                            return true
                        },
                        // Kwadracik z palety (Tools ▸ Colors) upuszczony na panel modułu.
                        onDropModuleColor: { color, point in
                            guard let id = findModuleBody(at: point)?.moduleID else { return false }
                            onColorModule?(id, color)
                            return true
                        }
                    )
                }
            }
        )
        // Zoom-do-kursora (pinch, ⌘scroll) + SPACE-drag pan ("rączka") — patrz
        // CanvasZoomPanNSView w PatchCanvasInteractionBridge.swift.
        .overlay(zoomPanOverlayView)
        .overlay(selectionOverlayView)
        .overlay(overlayLabelsView)
        .overlay(parameterFocusOverlay)
        .overlay(arrowKeysOverlayView)
        // ⌥+scroll nad SeqNote — scrolluje zakres widocznych nut (bez ingerencji w pan canvasu)
        .overlay(
            Group {
                if !isPreviewMode {
                    SeqScrollHandlerRepresentable(zoom, rowOffset, modules) { moduleID, steps in
                        let zl = seqNoteZoomLevel[moduleID] ?? 1
                        let octaves = [3, 2, 1][max(0, min(2, zl))]
                        // Jeśli nie ma jeszcze offset → oblicz auto-center jako punkt startowy
                        let curLo: Int
                        if let existing = seqNoteScrollOffset[moduleID] {
                            curLo = existing
                        } else if let m = modules.first(where: { $0.id == moduleID }),
                                  let uid = ModuleUIDatabase.shared.uiDef(forID: m.typeID)
                        {
                            let nk = uid.seqNoteKnobs
                            let np = nk.map { k in k.codeRef < m.parameters.count ? m.parameters[k.codeRef] : 60 }
                            let (lo, _) = noteViewRange(params: np, zoomLevel: zl)
                            curLo = lo
                        } else {
                            curLo = 48 // C3 fallback
                        }
                        seqNoteScrollOffset[moduleID] = max(0, min(127 - octaves * 12, curLo + steps))
                    }
                }
            }
        )
    }

    /// Animowane ramki zaznaczonych modułów, w osobnej warstwie nad głównym Canvasem.
    /// Montowana TYLKO gdy coś jest zaznaczone — `TimelineView(.animation)` odświeża się
    /// co klatkę, więc przy pustym zaznaczeniu nie ma jej wcale i nic nie kosztuje.
    @ViewBuilder
    private var selectionOverlayView: some View {
        if !isPreviewMode, !selectedModuleIDs.isEmpty {
            TimelineView(.animation) { timeline in
                Canvas { ctx, _ in
                    ctx.scaleBy(x: zoom, y: zoom)
                    // 5 = długość jednego cyklu wzoru (dash [3,2]); modulo trzyma fazę
                    // w małym zakresie zamiast pozwolić jej rosnąć w nieskończoność.
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    drawSelectionFrames(ctx, dashPhase: -CGFloat((t * 8).truncatingRemainder(dividingBy: 5)))
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Strzałki nad patchem — wartość, focus i zakres morfu (str. 132).
    @ViewBuilder
    private var arrowKeysOverlayView: some View {
        if !isPreviewMode {
            CanvasArrowKeysRepresentable { direction, modifiers in
                handleArrowKey(direction, modifiers: modifiers)
            }
        }
    }

    @ViewBuilder
    private var zoomPanOverlayView: some View {
        if !isPreviewMode, let controller = zoomPanController {
            CanvasZoomPanRepresentable(
                zoom: zoom,
                isEditingText: editingModuleID != nil,
                controller: controller,
                onZoomChange: { onZoomChange?($0) }
            )
        }
    }
}

// MARK: - Równość wejść kanwy

/// `ContentView` odświeża się przy każdej zmianie belki (status połączenia co 2 s,
/// zegar, obciążenie DSP) i za każdym razem buduje nową kanwę — a SwiftUI nie umie
/// porównać domknięć, więc przerysowywał WSZYSTKIE moduły, choć patch się nie zmienił
/// (zmierzone 2026-09-11: pełne przerysowanie co ~2 s przy bezczynnym edytorze).
/// Porównujemy więc sami — wyłącznie to, od czego zależy rysunek. Domknięcia pomijamy
/// celowo: łapią tylko referencje (`PatchState`, `DeviceConnection`, `CanvasViewState`)
/// i stały obszar, więc stare są równie dobre jak nowe. Obiekty obserwowane (`selection`,
/// `device`) porównujemy tożsamością — ich pola SwiftUI śledzi sam przez Observation.
extension PatchCanvasView: Equatable {
    static func == (lhs: PatchCanvasView, rhs: PatchCanvasView) -> Bool {
        lhs.area == rhs.area
            && lhs.zoom == rhs.zoom
            && lhs.slot == rhs.slot
            && lhs.minSize == rhs.minSize
            && lhs.isPreviewMode == rhs.isPreviewMode
            && lhs.hiddenColors == rhs.hiddenColors
            && lhs.cableShakeSeed == rhs.cableShakeSeed
            && lhs.overlayMode == rhs.overlayMode
            && lhs.cableStyle == rhs.cableStyle
            && lhs.knobControl == rhs.knobControl
            // Do 2026-09-27 tych trzech brakowało: Options ▸ Knob Style i View ▸ 3D Buttons
            // and Screens nie zmieniały modułów, dopóki nie ruszyło się patcha.
            && lhs.knobStyle == rhs.knobStyle
            && lhs.panelShading == rhs.panelShading
            && lhs.showsBackdrop == rhs.showsBackdrop
            && lhs.focusedMorph == rhs.focusedMorph
            && lhs.mutatorVisible == rhs.mutatorVisible
            && lhs.audibilityVisible == rhs.audibilityVisible
            && lhs.selection === rhs.selection
            && lhs.device === rhs.device
            && lhs.zoomPanController === rhs.zoomPanController
            && lhs.patch == rhs.patch
    }
}
