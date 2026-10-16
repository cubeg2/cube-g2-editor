// MutatorPanel.swift
// Patch Mutator — okno `⌘⌥6`, ułożone jak Muta dialog oryginału.
//
// Pięć pasów, z góry na dół — dokładnie tak, jak opisuje instrukcja „Nord Modular G2
// Patch Mutator" i jak układa je Muta Background dialog (PositionSubViews):
//
//   1. gałki Probability / Range z przyciskiem Link, cztery przyciski hodowli
//      (Mutate, Randomize „one parent"; Interpolate, Cross „both parents") i gałka
//      Probability krzyżowania;
//   2. Mother — sześcioro Children — Father;
//   3. Temporary Storage: trzy rzędy po osiem kratek, przy każdym rzędzie „x"
//      (Clear Row) i „v" (Copy to Variations);
//   4. osiem wariacji patcha na szarym pasie;
//   5. Quick Locks — siedem kategorii, pod każdą Solo.
//
// W kratce siedzi „chromosom": krzywa policzona żółwiem z wartości WSZYSTKICH
// patch parameters (Muta Box dialog (DrawChromosome)). The geometry and top-row
// relationships stay faithful to Clavia, while surfaces use the shared G2Editor
// module palette → [[Docs/ui/mutator]].

import AppKit
import G2Core
import G2EditorCore
import SwiftUI

enum MutatorMetrics {
    /// The floating window shows module controls at a legible scale while preserving
    /// their proportions, colours, and stroke weights from the patch canvas.
    static let controlScale: CGFloat = 2
    static let controlHeightScale = controlScale * 1.2
    static let lcdHeight = UIMetrics.textFieldHeight * controlHeightScale
    static let buttonHeight = UIMetrics.buttonFlatHeight * controlHeightScale
    static let lcdFont = UIFont.lcdDisplay(boxHeight: UIMetrics.textFieldHeight) * controlHeightScale
    static let labelFont = 9 * PatchLayout.bverhuePixelScale * controlScale
    static let groupFont = UIFont.moduleName * controlScale
    static let tileCornerRadius = UIMetrics.graphCornerRadius * controlScale
}

struct MutatorPanel: View {
    @Bindable var state: PatchState
    /// Trzyma stan wysuniętego panelu „Mutation settings" (zapamiętany jak inne panele).
    @Bindable var panels: PanelController

    /// Kratka chwycona myszą — źródło przeciągnięcia.
    @State private var dragSource: G2MutatorBox?

    /// Proporcje oryginału: kratka zajmuje ~10,6% szerokości okna, osiem kratek
    /// z odstępami wyznacza szerokość wszystkich pozostałych rzędów.
    private static let box: CGFloat = 52
    private static let gap: CGFloat = 4
    private static var gridWidth: CGFloat {
        box * 8 + gap * 7
    }

    /// Miejsce na kolumnę przycisków „x"/„v" z prawej strony magazynu.
    private static let rowButtons: CGFloat = 22

    /// Szerokość okna Standard — przy wysuniętym panelu stoi obok niego bez zmian.
    private static let standardWidth = PanelController.Panel.mutator.fixedWindowSize?.width ?? 496

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            standard
            if panels.mutatorSettingsOpen {
                MutatorSettingsPanel(state: state, panels: panels)
                    .frame(width: PanelController.mutatorSettingsWidth)
            }
        }
        .onChange(of: panels.effectiveMutatorSettings, initial: true) { _, settings in
            state.mutatorPanel = settings
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MutatorColor.panelBackground)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(action: handleKey)
    }

    private var standard: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            parentsRow
            storageSection
            variationsSection
            quickLocks
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 16)
        .frame(width: Self.standardWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Pas górny: gałki i przyciski hodowli

    private var controls: some View {
        ZStack(alignment: .topLeading) {
            MutatorControlConnections()

            controlCaption("Probability")
                .frame(width: 40, alignment: .leading)
                .position(x: 20, y: MutatorMetrics.labelFont / 2)
            controlCaption("Range").position(x: 87, y: MutatorMetrics.labelFont / 2)
            controlCaption("Probability")
                .frame(width: 40, alignment: .trailing)
                .position(x: 424, y: MutatorMetrics.labelFont / 2)
            // Podpisy rodziców stoją NAD swoją parą przycisków (decyzja użytkownika,
            // 2026-09-23). Zwolniony rząd pod przyciskami mieści gałki i oba nasze
            // przyciski w jednej linii — inaczej gałka „Not silent" nie miała gdzie stanąć.
            controlCaption("(one parent)").position(x: 187, y: MutatorMetrics.labelFont / 2)
            controlCaption("(both parents)").position(x: 320, y: MutatorMetrics.labelFont / 2)

            percentageDisplay(state.mutatorSettings.probability, width: 40)
                .position(x: 20, y: 20)
                .help("Mutation Probability — how many parameters move")
            percentageDisplay(state.mutatorSettings.range, prefix: "+/-", width: 50)
                .position(x: 87, y: 20)
                .help("Mutation Range — how far each parameter moves")
            percentageDisplay(state.mutatorSettings.crossProbability, width: 40)
                .position(x: 424, y: 20)
                .help("Cross Probability — how often the copying jumps between parents")

            moduleButton("Mutate", width: 52) { state.mutatorMutate() }
                .position(x: 150, y: 20)
                .help("Six children of the Mother sound")
            moduleButton("Randomize", width: 68) { state.mutatorRandomize() }
                .position(x: 216, y: 20)
                .help("Six children with values drawn from scratch")
            moduleButton("Interpolate", width: 72, enabled: state.mutatorHasBothParents) {
                state.mutatorInterpolate()
            }
            .position(x: 292, y: 20)
            .help("Six children stepping from Mother to Father")
            moduleButton("Cross", width: 52, enabled: state.mutatorHasBothParents) {
                state.mutatorCross()
            }
            .position(x: 358, y: 20)
            .help("Six children mixing the two parents at random")

            moduleButton("Mutation settings", width: 96, active: panels.mutatorSettingsOpen) {
                panels.mutatorSettingsOpen.toggle()
            }
            .position(x: 201, y: 46)
            .help("Show or hide more mutation settings")

            moduleButton("Not silent", width: 60, active: state.mutatorSettings.notSilent) {
                state.mutatorSettings.notSilent.toggle()
            }
            .position(x: 287, y: 46)
            .help("Lit = children that cannot play are bred again — no way from a sound source to the output, every path shut by a level, an amplifier or a closed lowpass")

            MutatorKnob(value: state.mutatorSettings.silenceSensitivity, maximum: 1) {
                state.mutatorSettings.silenceSensitivity = $0
            }
            .position(x: 340, y: 46)
            .help("Not silent sensitivity — how quiet counts as silent. Left = only a dead zero, right = anything near the bottom of the scale")

            MutatorKnob(value: state.mutatorSettings.probability, maximum: 1) {
                state.mutatorSettings.setProbability($0)
            }
            .position(x: 20, y: 46)
            .help("Mutation Probability — how many parameters move")

            MutatorKnob(value: state.mutatorSettings.range, maximum: G2MutatorSettings.maxRange) {
                state.mutatorSettings.setRange($0)
            }
            .position(x: 87, y: 46)
            .help("Mutation Range — how far each parameter moves")

            linkButton.position(x: 54, y: 47)

            MutatorKnob(value: state.mutatorSettings.crossProbability, maximum: 1) {
                state.mutatorSettings.crossProbability = $0
            }
            .position(x: 424, y: 46)
            .help("Cross Probability — how often the copying jumps between parents")
        }
        .frame(width: Self.gridWidth, height: 62)
    }

    private var linkButton: some View {
        moduleButton("Link", width: 34, active: state.mutatorSettings.link) {
            state.mutatorSettings.link.toggle()
            if state.mutatorSettings.link {
                state.mutatorSettings.setProbability(state.mutatorSettings.probability)
            }
        }
        .help("Move Probability and Range together")
    }

    private func percentageDisplay(_ value: Double, prefix: String = "", width: CGFloat) -> some View {
        MutatorPercentageDisplay(text: "\(prefix)\(G2MutatorSettings.percent(value))%", width: width)
    }

    private func controlCaption(_ title: String) -> some View {
        Text(title)
            .font(.system(size: MutatorMetrics.labelFont, weight: .regular))
            .fontWidth(.condensed)
            .foregroundStyle(UIColor.panelText)
            .fixedSize()
    }

    private func moduleButton(
        _ title: String,
        width: CGFloat,
        height: CGFloat = MutatorMetrics.buttonHeight,
        active: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .buttonStyle(PanelButtonStyle(width: width, height: height, active: active))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    // MARK: - Mother / Children / Father

    private var parentsRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            ParentGroupCaption(boxWidth: Self.box, gap: Self.gap)
                .frame(width: Self.gridWidth)

            HStack(spacing: 0) {
                box(.mother)
                Spacer(minLength: Self.gap)
                HStack(spacing: Self.gap) {
                    ForEach(0 ..< G2Mutator.childCount, id: \.self) { box(.child($0)) }
                }
                Spacer(minLength: Self.gap)
                box(.father)
            }
            .frame(width: Self.gridWidth, alignment: .leading)
        }
    }

    // MARK: - Temporary Storage

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            GroupCaption(title: "Temporary Storage")
                .frame(width: Self.gridWidth)
            ForEach(0 ..< 3, id: \.self) { row in
                HStack(spacing: Self.gap) {
                    ForEach(0 ..< 8, id: \.self) { column in
                        box(G2MutatorBox(.storage, row * 8 + column))
                    }
                    VStack(spacing: 2) {
                        rowButton("x", help: "Clear Row") { state.mutatorClearStorageRow(row) }
                        rowButton("v", help: "Copy to Variations") {
                            state.mutatorCopyStorageRowToVariations(row)
                        }
                    }
                    .padding(.leading, 2)
                }
            }
        }
    }

    private func rowButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        moduleButton(title, width: 16, action: action).help(help)
    }

    // MARK: - Wariacje

    private var variationsSection: some View {
        VStack(spacing: 3) {
            GroupCaption(title: "Variations")
                .padding(.vertical, 1)
            HStack(spacing: Self.gap) {
                ForEach(0 ..< 8, id: \.self) { box(G2MutatorBox(.variations, $0)) }
            }
        }
        .padding(4)
        .frame(width: Self.gridWidth + 8)
        .panelGroupBackground()
        .offset(x: -4)
    }

    // MARK: - Quick Locks

    private var quickLocks: some View {
        VStack(spacing: 3) {
            Text("Quick Locks during One Parent operations")
                .font(.system(size: MutatorMetrics.labelFont, weight: .regular))
                .fontWidth(.condensed)
                .foregroundStyle(UIColor.panelText)
            HStack(spacing: Self.gap) {
                ForEach(G2MutatorCategory.displayOrder, id: \.self) { category in
                    VStack(spacing: 2) {
                        lockButton(category)
                        soloButton(category)
                    }
                }
            }
        }
        .frame(width: Self.gridWidth)
    }

    private func lockButton(_ category: G2MutatorCategory) -> some View {
        let lit = state.mutatorLocks.isLocked(category)
        return moduleButton(
            category.title,
            width: (Self.gridWidth - Self.gap * 6) / 7,
            active: lit
        ) {
            state.mutatorLocks.toggleLock(category)
        }
        .help("Lit = \(category.help) — left unchanged by Mutate and Randomize")
    }

    private func soloButton(_ category: G2MutatorCategory) -> some View {
        let on = state.mutatorLocks.isSolo(category)
        return moduleButton("Solo", width: 30, active: on) {
            state.mutatorLocks.toggleSolo(category)
        }
        .help("Evolve only \(category.title) — everything else is left alone")
    }

    // MARK: - Kratka

    private func box(_ ref: G2MutatorBox) -> some View {
        MutatorBoxView(
            points: chromosome(of: ref),
            palette: palette(of: ref),
            focused: state.mutatorHighlight == ref,
            compare: state.mutatorCompare == ref,
            size: Self.box
        )
        .onTapGesture(count: 2) { state.mutatorMutate(from: ref) }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                state.mutatorSetCompare(ref)
            } else {
                state.mutatorSetFocus(ref)
            }
        }
        .onDrag {
            dragSource = ref
            MutatorTreeView.dragging = nil
            return NSItemProvider(object: "\(ref.kind.rawValue):\(ref.index)" as NSString)
        }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            drop(providers, on: ref)
        }
        .contextMenu { boxMenu(ref) }
        .help(helpText(for: ref))
    }

    @ViewBuilder
    private func boxMenu(_ ref: G2MutatorBox) -> some View {
        if ref.kind != .variations {
            Button("Delete") { state.mutatorDelete(ref) }
                .disabled(!state.mutatorHasData(at: ref))
        }
        if state.mutatorHasData(at: ref) {
            Button("Copy to Mother") { state.mutatorCopyToParent(ref, mother: true) }
            Button("Copy to Father") { state.mutatorCopyToParent(ref, mother: false) }
            Button("Save to Temporary Storage") { state.mutatorStore(ref) }
        }
    }

    private func helpText(for ref: G2MutatorBox) -> String {
        switch ref.kind {
        case .parents where ref.index == G2Mutator.motherIndex: "Mother — double-click to breed from it"
        case .parents where ref.index == G2Mutator.fatherIndex: "Father — second parent for Interpolate and Cross"
        case .parents: "Child \(ref.index + 1) — click to hear it, double-click to breed from it"
        case .storage: "Temporary storage — drag a sound here to keep it"
        case .variations: "Patch variation \(ref.index + 1) — click to select it on the G2"
        }
    }

    private func drop(_: [NSItemProvider], on destination: G2MutatorBox) -> Bool {
        let modifiers = NSEvent.modifierFlags
        // Kratka drzewa ewolucji — także z osobnego okna „Evolution Tree", które nie widzi
        // `dragSource` tego widoku, więc drzewo zostawia chwycony węzeł we wspólnym miejscu.
        if let node = MutatorTreeView.dragging {
            MutatorTreeView.dragging = nil
            if modifiers.contains(.shift) {
                state.mutatorInterpolate(node: node, with: destination)
            } else if modifiers.contains(.option) {
                state.mutatorCross(node: node, with: destination)
            } else {
                state.mutatorCopy(node: node, to: destination)
            }
            return true
        }
        guard let source = dragSource, source != destination else { return false }
        dragSource = nil
        if modifiers.contains(.shift) {
            state.mutatorInterpolate(source, destination)
        } else if modifiers.contains(.option) {
            state.mutatorCross(source, destination)
        } else {
            state.mutatorDrag(from: source, to: destination)
        }
        return true
    }

    private func chromosome(of ref: G2MutatorBox) -> [G2Mutator.ChromosomePoint] {
        let genome = state.mutatorGenome
        if ref.kind == .variations {
            guard ref.index < 8 else { return [] }
            return G2Mutator.chromosome(of: state.patch, variation: ref.index, genome: genome)
        }
        guard let individual = state.mutatorIndividual(at: ref) else { return [] }
        return G2Mutator.chromosome(of: individual, genome: genome)
    }

    /// All banks share the module display palette. Position and headings identify each
    /// tile group, while a separate fill identifies keyboard focus.
    private func palette(of _: G2MutatorBox) -> MutatorColor.Palette {
        .module
    }

    // MARK: - Klawiatura

    /// Skróty z rozdziału „Patch Mutator Shortcuts Overview" instrukcji.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let focus = state.mutatorFocus
        switch press.key {
        case "1": state.mutatorSetFocus(.mother)
        case "2", "3", "4", "5", "6", "7":
            state.mutatorSetFocus(.child(Int(String(press.key.character))! - 2))
        case "8": state.mutatorSetFocus(.father)
        case "o", "O": if let focus { state.mutatorCopyToParent(focus, mother: true) }
        case "t", "T": if let focus { state.mutatorCopyToParent(focus, mother: false) }
        case "e", "E": state.mutatorMutate(from: focus)
        case "u", "U": state.mutatorMutate()
        case "n", "N": state.mutatorRandomize()
        case "i", "I": state.mutatorInterpolate()
        case "x", "X": state.mutatorCross()
        case "s", "S": if let focus { state.mutatorStore(focus) }
        case .space:
            guard state.mutatorCompare != nil else { return .ignored }
            state.mutatorCompareToggle()
        case .upArrow, .downArrow, .leftArrow, .rightArrow:
            // ⌥ + strzałki chodzą po drzewie ewolucji, same strzałki po siatce kratek.
            if press.modifiers.contains(.option) {
                treeStep(press.key)
            } else {
                moveFocus(press.key)
            }
        default: return .ignored
        }
        return .handled
    }

    private func treeStep(_ key: KeyEquivalent) {
        switch key {
        case .upArrow: state.mutatorTreeStep(.up)
        case .downArrow: state.mutatorTreeStep(.down)
        case .leftArrow: state.mutatorTreeStep(.left)
        case .rightArrow: state.mutatorTreeStep(.right)
        default: break
        }
    }

    /// Strzałki chodzą po kratkach jak po siatce ośmiu kolumn: rząd rodziców,
    /// trzy rzędy magazynu, rząd wariacji.
    private func moveFocus(_ key: KeyEquivalent) {
        var (row, column) = gridPosition(of: state.mutatorHighlight) ?? (0, 0)
        switch key {
        case .upArrow: row -= 1
        case .downArrow: row += 1
        case .leftArrow: column -= 1
        case .rightArrow: column += 1
        default: return
        }
        guard (0 ... 4).contains(row), (0 ... 7).contains(column) else { return }
        state.mutatorSetFocus(boxAt(row: row, column: column))
    }

    private func gridPosition(of ref: G2MutatorBox?) -> (Int, Int)? {
        guard let ref else { return nil }
        switch ref.kind {
        case .parents:
            switch ref.index {
            case G2Mutator.motherIndex: return (0, 0)
            case G2Mutator.fatherIndex: return (0, 7)
            default: return (0, ref.index + 1)
            }
        case .storage: return (1 + ref.index / 8, ref.index % 8)
        case .variations: return (4, ref.index)
        }
    }

    private func boxAt(row: Int, column: Int) -> G2MutatorBox {
        switch row {
        case 0:
            switch column {
            case 0: .mother
            case 7: .father
            default: .child(column - 1)
            }
        case 4: G2MutatorBox(.variations, column)
        default: G2MutatorBox(.storage, (row - 1) * 8 + column)
        }
    }
}

// MARK: - G2Editor palette

enum MutatorColor {
    struct Palette {
        let background: Color
        let line: Color

        static let module = Palette(background: UIColor.lcdBackground, line: UIColor.graphLine)
    }

    /// `graphLine` at 30% over `lcdBackground` — the exact fill green used below filter
    /// curves, precomposed here as an opaque colour.
    static let selected = Color(red: 0.065, green: 0.411, blue: 0.161)
    /// Tło okna jak w Parameter Pages i Overview — jasne w dzień, ciemne w nocy.
    /// Do 2026-09-27 szary panel modułu, jasny także w trybie nocnym.
    static let panelBackground = Color(nsColor: .windowBackgroundColor)
    /// Kreski podpisów grup i łączniki gałek — kolor treści okna, żeby nie znikały nocą.
    static let line = Color.primary.opacity(0.4)
}

// MARK: - Kratka z chromosomem

/// Jedna kratka. Krzywa jest skalowana tak, żeby zmieściła się w 90% kratki i była
/// wyśrodkowana — `DrawChromosome` liczy to samo z prostokąta ramki.
struct MutatorBoxView: View {
    let points: [G2Mutator.ChromosomePoint]
    let palette: MutatorColor.Palette
    let focused: Bool
    /// Kratka „B" porównania A/B — mała litera w rogu, żeby nie zgubić jej wśród
    /// zwykłych kliknięć.
    var compare = false
    let size: CGFloat

    /// Poniżej tej wielkości kratka rysuje chromosom cieńszą kreską.
    static let thinLineBelow: CGFloat = 40

    var body: some View {
        // Kratka to ekran — wklęsła jak ekrany modułów i okien.
        Canvas { ctx, canvasSize in draw(ctx, canvasSize) }
            .frame(width: size, height: size)
            .panelScreen(fill: focused ? MutatorColor.selected : palette.background,
                         cornerRadius: MutatorMetrics.tileCornerRadius)
            .overlay(alignment: .topTrailing) {
                if compare {
                    Text("B")
                        .font(.system(size: MutatorMetrics.labelFont, weight: .bold))
                        .foregroundStyle(palette.line)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                }
            }
            .contentShape(Rectangle())
    }

    private func draw(_ ctx: GraphicsContext, _ canvasSize: CGSize) {
        guard points.count > 1 else { return }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let spanX = maxX - minX
        let spanY = maxY - minY
        let scale = min(spanX > 0 ? canvasSize.width / spanX : .greatestFiniteMagnitude,
                        spanY > 0 ? canvasSize.height / spanY : .greatestFiniteMagnitude)
        guard scale.isFinite else { return }
        let k = scale * G2Mutator.chromosomeFill
        let centreX = (minX + maxX) / 2
        let centreY = (minY + maxY) / 2
        let originX = canvasSize.width / 2
        let originY = canvasSize.height / 2

        var path = Path()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: originX + (point.x - centreX) * k,
                            y: originY + (point.y - centreY) * k)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        // Kratki drzewa ewolucji są o połowę mniejsze — pełna kreska zlałaby się w plamę.
        let lineScale = size < Self.thinLineBelow ? MutatorMetrics.controlScale / 2 : MutatorMetrics.controlScale
        ctx.stroke(
            path,
            with: .color(palette.line),
            style: StrokeStyle(
                lineWidth: UIMetrics.graphLineWidth * lineScale,
                lineCap: .round,
                lineJoin: .round
            )
        )
    }
}

// MARK: - Module display and knob

private struct MutatorPercentageDisplay: View {
    let text: String
    let width: CGFloat

    var body: some View {
        Text(text)
            .font(.custom("MatrixSansScreen-Regular", size: MutatorMetrics.lcdFont))
            .foregroundStyle(UIColor.lcdText)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(width: width, height: MutatorMetrics.lcdHeight)
            .panelScreen(cornerRadius: MutatorMetrics.tileCornerRadius)
    }
}

/// Poziomy suwak 0…100 % w barwach ekraników modułów; krok 5 % (fader Amount: 1 %).
private struct MutatorWeightSlider: View {
    let value: Double
    var steps = 20.0
    let onChange: (Double) -> Void
    var onEnded: () -> Void = {}

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(UIColor.graphLine.opacity(0.75))
                        .frame(width: geometry.size.width * CGFloat(value))
                }
                .panelScreen(cornerRadius: MutatorMetrics.tileCornerRadius)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let fraction = Double(drag.location.x / max(1, geometry.size.width))
                    onChange((min(1, max(0, fraction)) * steps).rounded() / steps)
                }.onEnded { _ in onEnded() })
        }
        .frame(height: MutatorMetrics.lcdHeight * 0.7)
    }
}

/// Ustawienia Mutatora są ułamkami 0…maximum, a wspólna `SmallKnob` chodzi po liczbach
/// całkowitych — gałka ma sto kroków, więc 100 pt ruchu to pełny obrót, jak wcześniej.
private struct MutatorKnob: View {
    let value: Double
    let maximum: Double
    let onChange: (Double) -> Void

    var body: some View {
        SmallKnob(value: Int((value / max(maximum, .ulpOfOne) * 100).rounded()),
                  range: 0 ... 100, size: SmallKnob.panelSize) { onChange(Double($0) / 100 * maximum) }
    }
}

// MARK: - Module buttons and caption connectors

/// Clavia's angled connector lines show which parameters belong to Mutate and Cross.
private struct MutatorControlConnections: View {
    var body: some View {
        Canvas { context, _ in
            var path = Path()
            path.move(to: CGPoint(x: 46, y: 5))
            path.addLine(to: CGPoint(x: 73, y: 5))
            path.move(to: CGPoint(x: 104, y: 5))
            path.addLine(to: CGPoint(x: 117, y: 5))
            path.addLine(to: CGPoint(x: 124, y: 12))
            path.move(to: CGPoint(x: 385, y: 12))
            path.addLine(to: CGPoint(x: 391, y: 5))
            path.addLine(to: CGPoint(x: 399, y: 5))
            context.stroke(path, with: .color(MutatorColor.line), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Wysuwany panel „Mutation settings"

/// Cztery zakładki panelu; każda zbiera sekcje planu (Docs/mutator/plan-ui §14).
private enum MutatorSettingsTab: String, CaseIterable {
    case generate = "Generate"
    case shape = "Shape"
    case protect = "Protect"
    case session = "Session"

    var sections: [String] {
        switch self {
        case .generate: ["Only audible", "Pool & Diversity", "Profile & Groups"]
        case .shape: ["Amount axis", "Family → Variations"]
        case .protect: ["Anchors"]
        case .session: ["Compare", "Tree", "Advanced"]
        }
    }
}

/// Panel z prawej strony okna. Zakładki działają od razu, żeby miejsce było zarezerwowane;
/// sekcje są wyszarzone, dopóki ich funkcje nie powstaną (wyjątek od reguły „bez
/// wyszarzonych obietnic" — decyzja użytkownika 2026-09-17).
private struct MutatorSettingsPanel: View {
    let state: PatchState
    @Bindable var panels: PanelController
    @AppStorage("g2_mutator_settings_tab") private var tab = MutatorSettingsTab.generate

    /// Sekcje, które już działają; reszta zostaje wyszarzonym nagłówkiem.
    private static let liveSections: Set<String> = [
        "Only audible", "Pool & Diversity", "Profile & Groups", "Anchors", "Amount axis",
        "Family → Variations", "Compare", "Tree",
    ]

    private static let gap: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupCaption(title: "Mutation settings")
            GeometryReader { geometry in
                HStack(spacing: Self.gap) {
                    ForEach(MutatorSettingsTab.allCases, id: \.self) { item in
                        Button { tab = item } label: {
                            Text(item.rawValue).lineLimit(1).minimumScaleFactor(0.72)
                        }
                        .buttonStyle(PanelButtonStyle(
                            width: (geometry.size.width - Self.gap * 3) / 4,
                            height: MutatorMetrics.buttonHeight,
                            active: tab == item
                        ))
                        .help(item.sections.joined(separator: " · "))
                    }
                }
            }
            .frame(height: MutatorMetrics.buttonHeight)
            ForEach(tab.sections, id: \.self) { section in
                if section == "Only audible" {
                    onlyAudibleSection
                } else if section == "Pool & Diversity" {
                    poolSection
                } else if section == "Anchors" {
                    anchorsSection
                } else if section == "Amount axis" {
                    axisSection
                } else if section == "Family → Variations" {
                    familySection
                } else if section == "Compare" {
                    compareSection
                } else if section == "Tree" {
                    MutatorTreeView(state: state, panels: panels, tile: 23, showsWindowButton: true)
                        .frame(maxHeight: .infinity)
                } else if Self.liveSections.contains(section) {
                    groupsSection
                } else {
                    sectionTitle(section)
                        .opacity(0.45)
                        .help("Not available yet")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(MutatorColor.line)
                .frame(width: 1)
                .padding(.vertical, 10)
        }
    }
}

extension MutatorSettingsPanel {
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: MutatorMetrics.groupFont, weight: .semibold))
            .fontWidth(.condensed)
            .foregroundStyle(UIColor.panelText)
    }

    /// „Only audible": przycisk i jedno zdanie, ile patcha nic nie robi. Moduły, których
    /// nie słychać, są przy wysuniętym panelu przygaszone na patchu.
    private var onlyAudibleSection: some View {
        let lit = panels.mutatorPanelSettings.onlyAudible
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Only audible")
            HStack(spacing: 8) {
                Button {
                    panels.mutatorPanelSettings.onlyAudible.toggle()
                } label: {
                    Text(lit ? "On" : "Off").lineLimit(1)
                }
                .buttonStyle(PanelButtonStyle(width: 40, height: MutatorMetrics.buttonHeight, active: lit))
                .help("Lit = Mutate and Randomize skip parameters you cannot hear")
                Text(audibilitySummary)
                    .font(.system(size: MutatorMetrics.labelFont))
                    .fontWidth(.condensed)
                    .foregroundStyle(UIColor.panelText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// „Pool & Diversity": wielkość puli, przyciski, które z niej losują, i jedno zdanie,
    /// co z tego wyjdzie.
    private var poolSection: some View {
        let settings = panels.mutatorPanelSettings
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Pool & Diversity")
            buttonRow(G2MutatorPanelSettings.poolSizes) { size, width in
                Button { panels.mutatorPanelSettings.poolSize = size } label: {
                    Text(size == 0 ? "Off" : "\(size)").lineLimit(1)
                }
                .buttonStyle(PanelButtonStyle(width: width, height: MutatorMetrics.buttonHeight,
                                              active: settings.poolSize == size))
                .help(size == 0 ? "Six children straight from the button, as in the original"
                    : "Breed \(size) candidates and keep the 6 most different")
            }
            buttonRow(G2MutatorPanelSettings.PoolOperation.allCases) { operation, width in
                let lit = settings.poolOperations.contains(operation)
                Button {
                    if lit {
                        panels.mutatorPanelSettings.poolOperations.remove(operation)
                    } else {
                        panels.mutatorPanelSettings.poolOperations.insert(operation)
                    }
                } label: {
                    Text(operation.rawValue).lineLimit(1).minimumScaleFactor(0.72)
                }
                .buttonStyle(PanelButtonStyle(width: width, height: MutatorMetrics.buttonHeight,
                                              active: lit && settings.poolSize > 0))
                .help("Lit = \(operation.rawValue) picks its children from the pool")
            }
            .opacity(settings.poolSize > 0 ? 1 : 0.45)
            Text(poolSummary)
                .font(.system(size: MutatorMetrics.labelFont))
                .fontWidth(.condensed)
                .foregroundStyle(UIColor.panelText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var poolSummary: String {
        let settings = panels.mutatorPanelSettings
        guard settings.poolSize > 0 else { return "Off: six children straight from the button." }
        guard !settings.poolOperations.isEmpty else { return "Light a button above to use the pool." }
        return "Picks the 6 most different of \(settings.poolSize) candidates."
    }

    /// „Profile & Groups": profile w dwóch rzędach po trzy i suwak „ile ruszać" na grupę.
    /// Profil świeci, gdy suwaki stoją dokładnie tak jak w nim.
    private var groupsSection: some View {
        let weights = panels.mutatorPanelSettings.groupWeights
        let profiles = G2MutatorProfile.allCases
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Profile & Groups")
            ForEach([Array(profiles.prefix(3)), Array(profiles.dropFirst(3))], id: \.self) { row in
                buttonRow(row) { profile, width in
                    Button { panels.mutatorPanelSettings.groupWeights = profile.weights } label: {
                        Text(profile.rawValue).lineLimit(1).minimumScaleFactor(0.72)
                    }
                    .buttonStyle(PanelButtonStyle(width: width, height: MutatorMetrics.buttonHeight,
                                                  active: weights == profile.weights))
                    .help(profile.help)
                }
            }
            ForEach(G2MutatorGroup.allCases, id: \.self) { group in
                HStack(spacing: 6) {
                    Text(group.rawValue)
                        .font(.system(size: MutatorMetrics.labelFont))
                        .fontWidth(.condensed)
                        .foregroundStyle(UIColor.panelText)
                        .frame(width: 44, alignment: .leading)
                    MutatorWeightSlider(value: weights[group]) {
                        panels.mutatorPanelSettings.groupWeights[group] = $0
                    }
                    .help("How much Mutate and Randomize move \(group.rawValue.lowercased()) parameters")
                    MutatorPercentageDisplay(text: "\(Int((weights[group] * 100).rounded()))%", width: 40)
                }
            }
            Text("Mutate and Randomize only. Quick Locks still win.")
                .font(.system(size: MutatorMetrics.labelFont))
                .fontWidth(.condensed)
                .foregroundStyle(UIColor.panelText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// „Anchors": cztery poprawki dziecka po wylosowaniu — gałki, strój, głośność, tempo.
    private var anchorsSection: some View {
        let anchors = panels.mutatorPanelSettings.anchors
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Anchors")
            anchorRow("Knobs") {
                anchorSwitch(anchors.knobAssigned, help: "Lit = parameters assigned to knobs stay as in Mother") {
                    panels.mutatorPanelSettings.anchors.knobAssigned.toggle()
                }
                anchorNote(knobSummary)
            }
            anchorRow("Pitch") {
                buttonRow([nil] + G2MutatorAnchors.pitchWindows) { window, width in
                    Button { panels.mutatorPanelSettings.anchors.rootPitch = window } label: {
                        Text(window.map { "±\($0)" } ?? "Off").lineLimit(1)
                    }
                    .buttonStyle(PanelButtonStyle(width: width, height: MutatorMetrics.buttonHeight,
                                                  active: anchors.rootPitch == window))
                    .help(window.map { "Oscillator tuning stays within \($0) steps of Mother" }
                        ?? "Oscillator tuning may go anywhere")
                }
            }
            anchorRow("Loudness") {
                buttonRow([nil] + G2MutatorAnchors.loudnessWindows) { window, width in
                    Button { panels.mutatorPanelSettings.anchors.loudness = window } label: {
                        Text(window.map { "\(Int(($0 * 100).rounded()))%" } ?? "Off").lineLimit(1)
                    }
                    .buttonStyle(PanelButtonStyle(width: width, height: MutatorMetrics.buttonHeight,
                                                  active: anchors.loudness == window))
                    .help(window.map { "Mixer levels together change by at most \(Int(($0 * 100).rounded()))%" }
                        ?? "Mixer levels may change freely")
                }
            }
            anchorRow("Tempo") {
                anchorSwitch(anchors.tempoGrid, help: "Lit = clock-synced LFOs and delays land on straight notes") {
                    panels.mutatorPanelSettings.anchors.tempoGrid.toggle()
                }
                anchorNote("Synced rates: no triplets or dotted notes.")
            }
            anchorNote("All four buttons, measured from Mother.")
        }
    }

    /// „Amount axis": skąd cel, fader Mother → cel i trzy przyciski pod nim.
    /// „Smooth": dwie grupy parametrów, które potrafią zmienić się tylko skokiem.
    /// Zapalone zostają na wartości Mother, więc oś da się przejechać stopniowo.
    struct SmoothGroup: Hashable {
        let title: String
        let set: G2SmoothAxis
        let help: String
    }

    static let smoothGroups = [
        SmoothGroup(title: "Switches", set: .switches,
                    help: "Lit = two-state buttons keep their Mother value (on/off, sequencer steps)"),
        SmoothGroup(title: "Selectors", set: .selectors,
                    help: "Lit = multi-state selectors keep their Mother value (waveforms, filter types)"),
    ]

    private var axisSection: some View {
        let smooth = panels.mutatorPanelSettings.smoothAxis
        let target = panels.mutatorPanelSettings.axisTarget
        let amount = state.mutatorAxisAmount
        let canMove = state.mutatorAxisHasTarget
        let moved = amount > 0 && state.mutatorAxis != nil
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Amount axis")
            anchorRow("Target") {
                buttonRow(G2MutationAxis.Target.allCases) { kind, width in
                    Button { panels.mutatorPanelSettings.axisTarget = kind } label: {
                        Text(kind.rawValue).lineLimit(1)
                    }
                    .buttonStyle(PanelButtonStyle(width: width, height: MutatorMetrics.buttonHeight,
                                                  active: target == kind))
                    .help(kind.help)
                }
            }
            anchorRow("Smooth") {
                buttonRow(Self.smoothGroups) { group, width in
                    let lit = smooth.contains(group.set)
                    Button { panels.mutatorPanelSettings.smoothAxis.formSymmetricDifference(group.set) } label: {
                        Text(group.title).lineLimit(1).minimumScaleFactor(0.72)
                    }
                    .buttonStyle(PanelButtonStyle(width: width, height: MutatorMetrics.buttonHeight,
                                                  active: lit))
                    .help(group.help)
                }
            }
            anchorRow("Amount") {
                MutatorWeightSlider(value: amount, steps: 100) {
                    state.mutatorAxisSetAmount($0)
                } onEnded: {
                    state.mutatorAxisEndGesture()
                }
                .help("0% = Mother, 100% = the target")
                MutatorPercentageDisplay(text: "\(Int((amount * 100).rounded()))%", width: 40)
            }
            .opacity(canMove ? 1 : 0.45)
            .allowsHitTesting(canMove)
            buttonRow(["New target", "Latch", "Store"]) { title, width in
                let enabled = title == "New target" ? target != .focus && canMove : moved
                Button {
                    switch title {
                    case "New target": state.mutatorAxisNewTarget()
                    case "Latch": state.mutatorAxisLatch()
                    default: state.mutatorAxisStore()
                    }
                } label: {
                    Text(title).lineLimit(1).minimumScaleFactor(0.72)
                }
                .buttonStyle(PanelButtonStyle(width: width, height: MutatorMetrics.buttonHeight,
                                              active: false))
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
                .help(Self.axisHelp[title] ?? "")
            }
            anchorNote(axisSummary)
        }
    }

    private static let axisHelp = [
        "New target": "Roll a new target; the fader stays where it is",
        "Latch": "Make this sound the new Mother; the fader goes back to 0%",
        "Store": "Save this sound to the first free Temporary Storage box",
    ]

    private var axisSummary: String {
        let target = panels.mutatorPanelSettings.axisTarget
        if target == .focus, !state.mutatorAxisHasTarget { return "Click a sound to slide from Mother towards it." }
        switch panels.mutatorPanelSettings.smoothAxis {
        case .all: return "Knobs only: every step is gradual, but no new waveforms or filter types."
        case .switches: return "Two-state buttons stay as in Mother; selectors may still jump."
        case .selectors: return "Selectors stay as in Mother; two-state buttons may still jump."
        default: return "0% is always Mother. Moving the fader never rolls new values."
        }
    }

    /// „Family → Variations": rozstaw ośmiu kratek i jeden przycisk. Rodzina ląduje w pustym
    /// rzędzie magazynu, a do V1–V8 idzie tym samym `v` co każdy rząd.
    private var familySection: some View {
        let spacing = panels.mutatorPanelSettings.familySpacing
        let row = state.mutatorFamilyRow
        let enabled = row != nil && state.mutatorAxisHasTarget
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Family → Variations")
            anchorRow("Spacing") {
                buttonRow(G2FamilySpacing.allCases) { kind, width in
                    Button { panels.mutatorPanelSettings.familySpacing = kind } label: {
                        Text(kind.rawValue).lineLimit(1).minimumScaleFactor(0.72)
                    }
                    .buttonStyle(PanelButtonStyle(width: width, height: MutatorMetrics.buttonHeight,
                                                  active: spacing == kind))
                    .help(kind.help)
                }
            }
            buttonRow(["Make family"]) { title, width in
                Button { state.mutatorMakeFamily() } label: {
                    Text(title).lineLimit(1)
                }
                .buttonStyle(PanelButtonStyle(width: width, height: MutatorMetrics.buttonHeight,
                                              active: false))
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
                .help("8 sounds from Mother to the target, into an empty Temporary Storage row")
            }
            anchorNote(familySummary(row: row))
        }
    }

    private func familySummary(row: Int?) -> String {
        guard state.mutatorAxisHasTarget else { return "Click a sound to slide from Mother towards it." }
        guard let row else { return "Clear a Temporary Storage row first (x)." }
        let target = panels.mutatorPanelSettings.axisTarget == .focus ? "" : " Each press rolls a new target."
        return "Box 1 is Mother, box 8 the target, into row \(row + 1). Press v to copy them to V1–V8.\(target)"
    }

    /// „Compare": A/B uchem. Przycisk A jest dwufunkcyjny: gra stronę A, a gdy Father ma
    /// dźwięk, każde kliknięcie przełącza A między Mother i Father (decyzja użytkownika).
    /// B to kratka z ⌘-kliku; świeci przycisk tego, co słychać.
    private var compareSection: some View {
        let compare = state.mutatorCompare
        let playing = state.mutatorComparePlaying
        let sideA = state.mutatorCompareA
        let hasFather = state.mutatorHasData(at: .father)
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Compare")
            buttonRow([PatchState.CompareSide.a, .b]) { side, _ in
                Text(side == .a ? (hasFather ? "A · Mother / Father" : "A · Mother") : "B · ⌘-click a sound")
                    .font(.system(size: MutatorMetrics.labelFont))
                    .fontWidth(.condensed)
                    .foregroundStyle(UIColor.panelText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: MutatorMetrics.labelFont)
            buttonRow([PatchState.CompareSide.a, .b]) { side, width in
                let name = side == .a ? "A · \(Self.boxName(sideA))" : compare.map { "B · \(Self.boxName($0))" } ?? "B"
                Button {
                    if side == .a { state.mutatorCompareSwitchA() } else { state.mutatorComparePlay(.b) }
                } label: {
                    Text(name).lineLimit(1).minimumScaleFactor(0.72)
                }
                .buttonStyle(PanelButtonStyle(width: width, height: MutatorMetrics.buttonHeight,
                                              active: playing == side))
                .disabled(compare == nil)
                .help(side == .a
                    ? (hasFather ? "Hear side A — each click switches it between Mother and Father" : "Hear Mother")
                    : "Hear the sound marked B")
            }
            .opacity(compare == nil ? 0.45 : 1)
            anchorNote(compare.map { "Space switches between \(Self.boxName(sideA)) (A) and \(Self.boxName($0)) (B)." }
                ?? "⌘-click a sound to compare it with \(Self.boxName(sideA)).")
        }
    }

    private static func boxName(_ box: G2MutatorBox) -> String {
        switch box.kind {
        case .parents where box.index == G2Mutator.motherIndex: "Mother"
        case .parents where box.index == G2Mutator.fatherIndex: "Father"
        case .parents: "Child \(box.index + 1)"
        case .storage: "Storage \(box.index / 8 + 1)-\(box.index % 8 + 1)"
        case .variations: "Variation \(box.index + 1)"
        }
    }

    private func anchorRow(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: MutatorMetrics.labelFont))
                .fontWidth(.condensed)
                .foregroundStyle(UIColor.panelText)
                .frame(width: 48, alignment: .leading)
            content()
        }
    }

    private func anchorSwitch(_ lit: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(lit ? "On" : "Off").lineLimit(1)
        }
        .buttonStyle(PanelButtonStyle(width: 40, height: MutatorMetrics.buttonHeight, active: lit))
        .help(help)
    }

    private func anchorNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: MutatorMetrics.labelFont))
            .fontWidth(.condensed)
            .foregroundStyle(UIColor.panelText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var knobSummary: String {
        let count = state.patch.knobAssignments.compactMap(\.self).count
        switch count {
        case 0: return "No knobs assigned in this patch."
        case 1: return "1 knob keeps its Mother value."
        default: return "\(count) knobs keep their Mother values."
        }
    }

    /// Rząd przycisków równej szerokości na całą szerokość panelu.
    private func buttonRow<Item: Hashable>(_ items: [Item],
                                           @ViewBuilder button: @escaping (Item, CGFloat) -> some View)
        -> some View
    {
        GeometryReader { geometry in
            let width = (geometry.size.width - Self.gap * CGFloat(items.count - 1)) / CGFloat(items.count)
            HStack(spacing: Self.gap) {
                ForEach(items, id: \.self) { button($0, width) }
            }
        }
        .frame(height: MutatorMetrics.buttonHeight)
    }

    private var audibilitySummary: String {
        let sound = state.mutatorParents[G2Mutator.motherIndex] ?? state.currentIndividual()
        let map = G2AudibilityMap(patch: state.patch, sound: sound)
        let modules = map.silentModules.count
        let knobs = map.deadParameters.count
        guard modules + knobs > 0 else { return "Everything in this patch can be heard." }
        var parts: [String] = []
        if modules > 0 { parts.append(modules == 1 ? "1 module" : "\(modules) modules") }
        if knobs > 0 { parts.append(knobs == 1 ? "1 modulation knob" : "\(knobs) modulation knobs") }
        let verb = modules + knobs == 1 ? "does" : "do"
        let note = panels.mutatorPanelSettings.onlyAudible ? " (dimmed on the patch)" : ""
        return parts.joined(separator: " and ") + " \(verb) nothing\(note)."
    }
}

// MARK: - Podpis grupy z kreskami

/// „──── Children ────" — podpis z cienkimi kreskami po bokach, jak grupa w oryginale.
private struct GroupCaption: View {
    let title: String
    var textColor: Color = UIColor.panelText
    var lineColor: Color = MutatorColor.line

    var body: some View {
        HStack(spacing: 5) {
            line
            Text(title)
                .font(.system(size: MutatorMetrics.groupFont, weight: .semibold))
                .fontWidth(.condensed)
                .foregroundStyle(textColor)
                .fixedSize()
            line
        }
    }

    private var line: some View {
        Rectangle()
            .fill(lineColor)
            .frame(height: 1)
    }
}

/// Aligns Mother and Father to their tile centres and confines the Children caption
/// and its lines to the six child columns.
private struct ParentGroupCaption: View {
    let boxWidth: CGFloat
    let gap: CGFloat

    var body: some View {
        HStack(spacing: gap) {
            label("Mother")
                .frame(width: boxWidth)
            GroupCaption(title: "Children")
                .frame(width: boxWidth * 6 + gap * 5)
            label("Father")
                .frame(width: boxWidth)
        }
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .font(.system(size: MutatorMetrics.groupFont, weight: .semibold))
            .fontWidth(.condensed)
            .foregroundStyle(UIColor.panelText)
            .fixedSize()
    }
}

private extension G2MutationAxis.Target {
    var help: String {
        switch self {
        case .random: "Target drawn like Randomize — far from Mother"
        case .mutate: "Target is one Mutate child from the Probability and Range knobs"
        case .focus: "Target is the sound you clicked last"
        }
    }
}

private extension G2FamilySpacing {
    var help: String {
        switch self {
        case .linear: "Equal fader steps: 0, 14, 29 … 100%"
        case .easeIn: "Dense near Mother — the first boxes barely differ"
        case .easeOut: "Dense near the target — it moves away fast, then settles"
        case .equalDistance: "Every neighbouring pair of boxes sounds equally far apart"
        }
    }
}
