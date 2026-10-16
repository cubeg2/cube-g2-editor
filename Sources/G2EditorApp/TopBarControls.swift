// TopBarControls.swift
// Wspólne klocki górnej belki: jedna ramka, jeden rozmiar, jedna para strzałek.
//
// Punktem wyjścia jest przycisk `Run` — kwadratowa ramka z zaokrąglonymi rogami,
// na tyle duża, żeby napis miał oddech. Wszystkie pozostałe przyciski belki
// (szuflady, panele, `Hide`, shake, skala) biorą z niej wysokość, zaokrąglenie
// i kolory, więc belka wygląda jak jeden zestaw, a nie jak zlepek kontrolek
// systemowych w trzech rozmiarach.

import G2Core
import SwiftUI

extension CableColor {
    /// Kolor kropki kabla w belce. Zielony i pomarańczowy niosą też rodzaj pliku
    /// w przeglądarce patchy (`PatchKind`).
    var swatch: Color {
        switch self {
        case .red: Color(red: 0.92, green: 0.18, blue: 0.18)
        case .blue: Color(red: 0.20, green: 0.50, blue: 1.00)
        case .yellow: Color(red: 0.95, green: 0.88, blue: 0.10)
        case .orange: Color(red: 0.98, green: 0.55, blue: 0.08)
        case .green: Color(red: 0.18, green: 0.78, blue: 0.28)
        case .purple: Color(red: 0.62, green: 0.22, blue: 0.88)
        case .white: Color(red: 0.90, green: 0.90, blue: 0.90)
        }
    }
}

enum TopBarMetrics {
    /// Bok kwadratowego przycisku — i zarazem wysokość każdego przycisku z napisem.
    static let controlSide: CGFloat = 24
    static let cornerRadius: CGFloat = 5
    /// Niższy przycisk — dwa takie stoją jeden na drugim w miejscu jednego zwykłego
    /// (Voice / FX), więc bierze go też wszystko, co ma z nimi trzymać wysokość.
    static let smallControlHeight: CGFloat = 17
    static let smallCornerRadius: CGFloat = 4
    /// Piktogramy są większe niż w systemowym pasku: ramka daje im miejsce.
    static let iconSize: CGFloat = 14
    static let labelSize: CGFloat = 11.5
    /// **Jeden rozmiar dla wszystkich podpisów w OBU pasach** — „Master Clock", „Area",
    /// „Cables:", „VA"/„FX", „Cycles"/„Memory", licznik modułów, „Patch:", „Variations:",
    /// „Vol:", „Voices:", „Morph Groups". Wcześniej było ich pięć (9, 10, 10.5, 11,
    /// `.caption`) i pas wyglądał jak składany z trzech różnych programów.
    static let captionSize: CGFloat = 11
    /// Oddech po bokach napisu w ramce.
    static let labelPadding: CGFloat = 7
    /// Kreski między sekcjami — wyraźniejsze i wyższe niż systemowy `Divider`.
    static let dividerHeight: CGFloat = 36
    static let dividerWidth: CGFloat = 1.5
    static let stepperWidth: CGFloat = 18
    /// Dwie połówki + szczelina składają się na wysokość przycisku.
    static let stepperHalfHeight: CGFloat = 11.5
    /// Kropki kolorów kabli — na tyle duże, żeby dało się w nie trafić myszą.
    static let colorDotSize: CGFloat = 15
    /// Przycisk slotu A–D. Węższy od kwadratu, bo niesie jedną literę, ale kreska
    /// klawiatury nad nim ma być DOKŁADNIE tej szerokości — stąd jedna liczba na oba.
    static let slotButtonWidth: CGFloat = 24
    /// Wysokość jak On/Off i okienko Voices (2026-09-27) — dawne 21 pt plus kreski
    /// w stosie spychały literę poniżej osi pasa.
    static let slotButtonHeight: CGFloat = controlSide
    /// Czerwona kreska „ten slot słucha klawiatury" — 2 pt ginęły na ekranie Retina.
    static let slotKeyboardBarHeight: CGFloat = 3
    /// Gałki morfów w pasie — jeden rozmiar (Vol niżej). Ramka jest większa od tarczy,
    /// bo mieści jeszcze kreseczki min/max sterczące poza nią — dokładnie jak przy
    /// gałkach w modułach. Stan morfu pokazuje ramka całej kolumny (`MorphBarView`).
    static let knobSize: CGFloat = 24
    static let knobRingWidth: CGFloat = 1.5
    /// Gałki w kafelkach Morph Groups — większe od `knobSize`, bo przy 24 pt ciężko
    /// było w nie trafić myszą (prośba użytkownika 2026-09-27). Ten sam rozmiar mają
    /// gałki okien: Parameter Pages, Patch Adjuster, Patch Mutator.
    static let morphKnobSize = SmallKnob.panelSize
    /// Vol dwa razy większy od morfów — to najczęściej kręcona gałka pasa
    /// (prośba użytkownika 2026-09-25).
    static let volumeKnobSize: CGFloat = knobSize * 2
    /// Wieniec diod wokół Vol zamiast obwódki — jak gałka Wheel w oryginale.
    static let volumeKnobLeds = 16
    /// Powiększenie odczytu Cycles / Memory. Dobrane tak, żeby jego etykiety wyszły
    /// dokładnie na `captionSize` — cała geometria odczytu liczy się od `labelFont`,
    /// więc podpisy zgadzają się z resztą pasa BEZ rozjeżdżania układu.
    static let readoutScale: CGFloat = captionSize / PatchLoadMetrics.labelFont
}

/// Przycisk belki — piktogram albo napis w tej samej ramce. `isOn` zapala go
/// kolorem `tint` (zielony dla `Run`, akcent dla przełączników).
struct TopBarButton: View {
    enum Content {
        case icon(String)
        case text(String)
    }

    let content: Content
    var isOn: Bool = false
    var tint: Color = .accentColor
    var isEnabled: Bool = true
    /// Wymuszona szerokość — dla przycisków, które zmieniają napis („Hide" ⇄ „Show").
    /// Bez niej pasek przeskakiwał w bok przy każdym kliknięciu.
    var fixedWidth: CGFloat?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            face
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var face: some View {
        shape
            .foregroundStyle(labelColor)
            .background(
                RoundedRectangle(cornerRadius: TopBarMetrics.cornerRadius)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TopBarMetrics.cornerRadius)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: TopBarMetrics.cornerRadius))
    }

    // Przycisk nieczynny ("Init 1" bez zapisanego szablonu, "Run" bez zegara) rysuje się
    // WŁASNYMI kolorami, a nie przez przygaszenie całości. Pierwsza wersja robiła
    // `.opacity(0.35)` na gotowym przycisku i wtedy razem z napisem znikała też ramka —
    // w pasku zostawał ślad, o którym nie było wiadomo, że jest przyciskiem.
    // Teraz ramka trzyma pełną siłę, gaśnie tylko napis i wypełnienie.

    private var labelColor: Color {
        guard isEnabled else { return .secondary }
        return isOn ? tint : .primary
    }

    private var fillColor: Color {
        guard isEnabled else { return Color.primary.opacity(0.03) }
        return isOn ? tint.opacity(0.18) : Color.primary.opacity(0.06)
    }

    private var borderColor: Color {
        guard isEnabled else { return Color.primary.opacity(0.22) }
        return isOn ? tint : Color.primary.opacity(0.25)
    }

    @ViewBuilder
    private var shape: some View {
        switch content {
        case let .icon(name):
            Image(systemName: name)
                .font(.system(size: TopBarMetrics.iconSize))
                .frame(width: TopBarMetrics.controlSide, height: TopBarMetrics.controlSide)
        case let .text(title):
            // `fixedSize` na napisie jest konieczne: bez niego krótkie etykiety („Init")
            // dostawały propozycję szerokości równą `controlSide` i skracały się do „…".
            Text(title)
                .font(.system(size: TopBarMetrics.labelSize, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, TopBarMetrics.labelPadding)
                .frame(minWidth: TopBarMetrics.controlSide, minHeight: TopBarMetrics.controlSide)
                .frame(width: fixedWidth)
        }
    }
}

/// Niższy brat `TopBarButton` — dwa takie mieszczą się na wysokość jednego zwykłego.
/// Stąd biorą wygląd przyciski Voice / FX (On/Off patcha od 2026-09-27 jest pełnej wysokości).
struct TopBarSmallButton: View {
    let title: String
    var width: CGFloat
    var isOn: Bool = false
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .frame(width: width, height: TopBarMetrics.smallControlHeight)
                .foregroundStyle(isOn ? tint : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: TopBarMetrics.smallCornerRadius)
                        .fill(isOn ? tint.opacity(0.18) : Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TopBarMetrics.smallCornerRadius)
                        .strokeBorder(isOn ? tint : Color.primary.opacity(0.25), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Odczyt wartości w ramce przycisku — żeby liczba w pasku wyglądała tak samo
/// niezależnie od tego, czy jest to tempo, skala, obciążenie czy liczba głosów.
struct TopBarValueField: View {
    let text: String
    var width: CGFloat
    var isEnabled: Bool = true

    var body: some View {
        Text(text)
            .font(.system(size: TopBarMetrics.labelSize, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: width, height: TopBarMetrics.controlSide)
            .background(
                RoundedRectangle(cornerRadius: TopBarMetrics.smallCornerRadius)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: TopBarMetrics.smallCornerRadius)
                    .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Przeciąganie myszą po okienku wartości: w górę więcej, w dół mniej — jak gałką
/// (prośba użytkownika 2026-10-13: Master Clock i Voices dało się ruszać tylko strzałkami).
/// `onChange` dostaje każdą nową wartość w trakcie ruchu, `onEnd` woła się po puszczeniu.
private struct TopBarDragAdjust: ViewModifier {
    let value: Int?
    let range: ClosedRange<Int>
    /// Ile punktów ruchu myszy na jeden krok wartości.
    let pointsPerStep: CGFloat
    let isEnabled: Bool
    let onChange: (Int) -> Void
    let onEnd: () -> Void

    @State private var startValue: Int?
    @State private var lastValue: Int?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        guard isEnabled, let start = startValue ?? value else { return }
                        startValue = start
                        let steps = Int((-drag.translation.height / pointsPerStep).rounded(.towardZero))
                        let next = min(max(start + steps, range.lowerBound), range.upperBound)
                        guard next != lastValue else { return }
                        lastValue = next
                        if next != value { onChange(next) }
                    }
                    .onEnded { _ in
                        let moved = startValue != nil
                        startValue = nil
                        lastValue = nil
                        if moved { onEnd() }
                    }
            )
    }
}

extension View {
    func topBarDragAdjust(value: Int?, range: ClosedRange<Int>, pointsPerStep: CGFloat,
                          isEnabled: Bool = true, onChange: @escaping (Int) -> Void,
                          onEnd: @escaping () -> Void = {}) -> some View
    {
        modifier(TopBarDragAdjust(value: value, range: range, pointsPerStep: pointsPerStep,
                                  isEnabled: isEnabled, onChange: onChange, onEnd: onEnd))
    }
}

/// Para strzałek ▲▼ — wszędzie w belce ta sama: przy tempie i przy skali.
/// Systemowy `Stepper` odpada, bo jego rozmiaru nie da się zmienić.
struct TopBarStepper: View {
    var canIncrement: Bool = true
    var canDecrement: Bool = true
    let onIncrement: () -> Void
    let onDecrement: () -> Void

    var body: some View {
        VStack(spacing: 1) {
            half(symbol: "chevron.up", enabled: canIncrement, action: onIncrement)
            half(symbol: "chevron.down", enabled: canDecrement, action: onDecrement)
        }
    }

    private func half(symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: TopBarMetrics.stepperWidth, height: TopBarMetrics.stepperHalfHeight)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

// MARK: - Zawijanie pasa

/// Znacznik „to jest kreska sekcji, nie treść" — czyta go `TopBarFlowLayout`.
private struct TopBarSeparatorKey: LayoutValueKey {
    static let defaultValue: Bool = false
}

/// Kreska sekcji w pasie zawijanym. Funkcja, a nie osobny `View`, bo znacznik układu
/// musi wisieć na widoku, który `TopBarFlowLayout` widzi jako swój bezpośredni element —
/// schowany w `body` własnego typu byłby dla układu niewidoczny.
///
/// Kreska umie zniknąć: przy propozycji szerokości 0 zwija się do zera i nie zostawia
/// dyndającej krechy na końcu rzędu.
func topBarFlowDivider() -> some View {
    Rectangle()
        .fill(Color.primary.opacity(0.30))
        .frame(minWidth: 0,
               idealWidth: TopBarMetrics.dividerWidth,
               maxWidth: TopBarMetrics.dividerWidth,
               minHeight: 0,
               idealHeight: TopBarMetrics.dividerHeight,
               maxHeight: TopBarMetrics.dividerHeight)
        .layoutValue(key: TopBarSeparatorKey.self, value: true)
}

/// Pas, który przy wąskim oknie zawija się na kolejny rząd.
///
/// Belka jest jednym rzędem dopóki starcza szerokości. Gdy nie starcza, grupa, która się
/// nie mieści, przechodzi W CAŁOŚCI niżej (TopBar 1A / TopBar 2A) — zamiast ściskać się
/// do zera albo wyjeżdżać poza krawędź okna. Tak właśnie znikały „Init 1"/„Init 2":
/// `HStack` ściska najbardziej ustępliwe dziecko, a nie chowa całą grupę.
///
/// Kreska sekcji należy do grupy PO NIEJ: wchodzą do rzędu razem albo wcale, a kreska,
/// która wypadłaby na początku rzędu, zwija się do zera.
struct TopBarFlowLayout: Layout {
    var spacing: CGFloat = 10
    /// Odstęp między rzędami — na tyle mały, żeby zawinięty pas nadal czytał się
    /// jako jedna belka, a nie dwie.
    var rowSpacing: CGFloat = 5

    private struct Row {
        var items: [Int] = []
        /// Kreski zwinięte do zera — trzeba je mimo wszystko rozmieścić.
        var hidden: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = rows(sizes: sizes, subviews: subviews, maxWidth: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height }
            + rowSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? (rows.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache _: inout ())
    {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = rows(sizes: sizes, subviews: subviews,
                        maxWidth: proposal.width ?? bounds.width)
        var y = bounds.minY
        for row in rows {
            for index in row.hidden {
                subviews[index].place(at: CGPoint(x: bounds.minX, y: y + row.height / 2),
                                      anchor: .leading,
                                      proposal: ProposedViewSize(width: 0, height: row.height))
            }
            var x = bounds.minX
            for index in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y + row.height / 2),
                                      anchor: .leading,
                                      proposal: ProposedViewSize(sizes[index]))
                x += sizes[index].width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private func rows(sizes: [CGSize], subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()

        func closeRow() {
            guard !row.items.isEmpty || !row.hidden.isEmpty else { return }
            rows.append(row)
            row = Row()
        }

        func append(_ index: Int) {
            row.width += (row.items.isEmpty ? 0 : spacing) + sizes[index].width
            row.height = max(row.height, sizes[index].height)
            row.items.append(index)
        }

        var index = 0
        while index < subviews.count {
            let isSeparator = subviews[index][TopBarSeparatorKey.self]
            // Kreska i grupa po niej mierzone razem — inaczej rząd kończyłby się kreską,
            // a grupa spadałaby niżej.
            let unit = isSeparator && index + 1 < subviews.count ? [index, index + 1] : [index]
            let unitWidth = unit.reduce(0) { $0 + sizes[$1].width }
                + spacing * CGFloat(unit.count - 1)
            if !row.items.isEmpty, row.width + spacing + unitWidth > maxWidth {
                closeRow()
            }
            if isSeparator, row.items.isEmpty {
                row.hidden.append(index)
                index += 1
                continue
            }
            for member in unit {
                append(member)
            }
            index += unit.count
        }
        closeRow()
        return rows
    }
}

/// Podpis („Cables:", „Area", „Vol:") — **jedyny** dozwolony krój podpisów w obu pasach.
struct TopBarCaption: View {
    let text: String
    /// Podpis łamany na dwa wiersze („Master Clock", „Morph Groups") — węższy niż
    /// jednowierszowy, a pas i tak ma tę wysokość.
    var secondLine: String?

    var body: some View {
        VStack(alignment: .leading, spacing: -1) {
            Text(text)
            if let secondLine { Text(secondLine) }
        }
        .font(.system(size: TopBarMetrics.captionSize, weight: .medium))
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}

extension View {
    /// Podpis NAD kontrolką zamiast przed nią (życzenie użytkownika 2026-09-27: po dojściu
    /// „Edit all" morfy nie mieściły się w rzędzie). Nakładka nie bierze miejsca w układzie,
    /// więc kontrolka zostaje tam, gdzie była, a pas się nie poszerza — napis wchodzi
    /// w wolne pole nad kontrolką, które i tak zostawia wysoka gałka Vol.
    func topBarCaptionAbove(_ text: String) -> some View {
        overlay(alignment: .topLeading) {
            TopBarCaption(text: text)
                .alignmentGuide(.top) { $0[.bottom] + 1 }
        }
    }
}
