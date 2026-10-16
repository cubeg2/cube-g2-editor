// ParameterPagesPanel.swift
// Strony parametrów — to, co panel Norda ma pod swoimi ośmioma gałkami.
//
// Urządzenie ma osiem gałek i piętnaście stron: pięć grup (Osc, LFO, Env, Filter,
// Effect — u Clavii litery A…E) po trzy strony. Widok odtwarza poziomy układ
// Knob Floater: osiem gałek bieżącej strony oraz wybór A…E / 1…3 po prawej.
// Osobny `ParameterOverviewPanel` pokazuje wszystkie 120 przypisań naraz;
// ten widok pozostaje szybkim edytorem jednej strony → [[Docs/ui/parameter-pages]].
//
// Przypisanie: **⌘ + klik gałki w patchu** kładzie parametr na pierwszej wolnej
// gałce strony z focusem. Oryginał ma tu ⌘ + przeciągnięcie na okno gałek
// (Control (TryKnobAssign)) — ten sam modyfikator, ten sam punkt wyjścia.
// Drugi kierunek jest źródłowy: ekran nad gałką przeciąga się na parametr modułu
// w patchu albo na inny ekran (instrukcja str. 126, Knob Floater View (Drop)).

import G2Core
import G2EditorCore
import SwiftUI

private enum ParameterPageMetrics {
    static let controlScale: CGFloat = 2
    static let controlHeightScale = controlScale * 1.2
    static let contentSize = CGSize(width: 530, height: 144)
    /// Osiem kolumn o równym rozstawie wypełnia całe pole na lewo od panelu wyboru —
    /// ekrany dzieli już tylko `slotSpacing`, żeby były możliwie duże.
    static let knobOrigins: [CGFloat] = [4, 59.5, 115, 170.5, 226, 281.5, 337, 392.5]
    static let slotOriginY: CGFloat = 4
    static let slotWidth: CGFloat = 52.5
    static let slotSpacing: CGFloat = 3
    static let slotHeight: CGFloat = 130
    static let knobBankWidth: CGFloat = 447
    static let displayWidth = slotWidth
    static let moduleNameHeight: CGFloat = 18
    static let displayHeight: CGFloat = 31.5
    static let knobCanvasSize = SmallKnob.panelSize
    static let knobY: CGFloat = 56
    static let buttonLabelY: CGFloat = 96
    static let buttonY: CGFloat = 113
    static let labelHeight: CGFloat = 17
    static let labelFont = PanelTypography.label
    static let lcdFont = UIFont.lcdDisplay(boxHeight: UIMetrics.textFieldHeight) * controlHeightScale
    /// Nazwa parametru i wartość dobrane tak, żeby najdłuższe napisy (`InputType`,
    /// `-12.000`) mieściły się w ekranie bez skracania kropkami.
    static let lcdNameFont = lcdFont * 0.72
    static let lcdValueFont = lcdFont * 0.85
    /// Grupa Global Pages / A…E / 1…3 jest dosunięta do prawej krawędzi okna,
    /// a przycisk Global Pages ma dokładnie szerokość rzędu 1…3 (3 × 24).
    static let selectorX: CGFloat = 452
    static let selectorWidth = selectorButtonWidth * 3
    static let selectorWellX: CGFloat = 447
    static let selectorButtonWidth: CGFloat = 24
    static let selectorButtonHeight: CGFloat = 17
}

struct ParameterPagesPanel: View {
    @Bindable var state: PatchState

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            knobBank
            selectorBackground
            pageSelector
        }
        .frame(width: ParameterPageMetrics.contentSize.width,
               height: ParameterPageMetrics.contentSize.height,
               alignment: .topLeading)
        .clipped()
    }

    // MARK: - Osiem gałek bieżącej strony

    private var knobBank: some View {
        let items = (0 ..< G2KnobPages.knobsPerPage).map { slot in
            ParameterPagePresentationResolver.presentation(
                at: G2KnobPages.knobIndex(page: state.focusedParameterPage, slot: slot),
                state: state
            )
        }
        return ZStack(alignment: .topLeading) {
            ForEach(0 ..< G2KnobPages.knobsPerPage, id: \.self) { slot in
                knobSlot(slot, items: items)
                    .offset(x: ParameterPageMetrics.knobOrigins[slot],
                            y: ParameterPageMetrics.slotOriginY)
            }
        }
        .frame(width: ParameterPageMetrics.knobBankWidth,
               height: ParameterPageMetrics.contentSize.height,
               alignment: .topLeading)
    }

    /// Nazwa modułu zajmuje **całą serię** gałek tego modułu. Oryginał rozciąga ją
    /// najwyżej na dwie kolumny (`SetSize(0x37|0x6e, 13)`); u nas idzie do końca serii,
    /// bo dopiero wtedy myślniki `ModuleRunLabel` pokazują jej prawdziwy zasięg.
    private func moduleNameWidth(_ slot: Int, items: [ParameterPagePresentation]) -> CGFloat {
        let run = CGFloat(ParameterPagePresentation.moduleRunLength(from: slot, in: items))
        return run * ParameterPageMetrics.slotWidth
            + (run - 1) * ParameterPageMetrics.slotSpacing
    }

    private func knobSlot(_ slot: Int, items: [ParameterPagePresentation]) -> some View {
        let index = G2KnobPages.knobIndex(page: state.focusedParameterPage, slot: slot)
        let item = items[slot]
        let nameWidth = moduleNameWidth(slot, items: items)
        let moduleName = ParameterPagePresentation.showsModuleName(at: slot, in: items)
            ? ModuleRunLabel.text(item.moduleName, width: nameWidth,
                                  size: ParameterPageMetrics.labelFont)
            : ""

        return ZStack(alignment: .topLeading) {
            // Wewnętrzna ramka obejmuje całą serię gałek modułu i centruje w niej
            // nazwę; zewnętrzna rezerwuje w layoucie tylko własną kolumnę, więc
            // nadmiar wchodzi na puste pola sąsiadów.
            Text(moduleName)
                .font(.system(size: ParameterPageMetrics.labelFont, weight: .semibold))
                .fontWidth(.condensed)
                .foregroundStyle(UIColor.panelText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: nameWidth, height: ParameterPageMetrics.moduleNameHeight)
                .frame(width: ParameterPageMetrics.slotWidth, alignment: .leading)

            ParameterPageDisplay(name: item.parameterName, value: item.valueText)
                .offset(y: ParameterPageMetrics.moduleNameHeight)
                .modifier(ParameterPageDragSource(index: index, state: state))

            SmallKnob(
                value: item.value ?? 0,
                range: 0 ... ParameterPagePresentationResolver.knobMaxValue(item),
                size: ParameterPageMetrics.knobCanvasSize,
                morph: ParameterPagePresentationResolver.morphTint(item, state: state),
                enabled: item.knobParamIndex != nil,
                stepsPerPoint: 0.4,
                onBegin: { state.beginParameterGesture() },
                onChange: { value in
                    ParameterPagePresentationResolver.setKnobValue(item, value: value, state: state)
                },
                onEnd: { state.endParameterGesture() }
            )
            .offset(x: (ParameterPageMetrics.slotWidth - ParameterPageMetrics.knobCanvasSize) / 2,
                    y: ParameterPageMetrics.knobY)

            Text(item.buttonName)
                .font(.system(size: ParameterPageMetrics.labelFont, weight: .semibold))
                .fontWidth(.condensed)
                .foregroundStyle(UIColor.panelText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: ParameterPageMetrics.slotWidth,
                       height: ParameterPageMetrics.labelHeight)
                .offset(y: ParameterPageMetrics.buttonLabelY)

            Button {
                ParameterPagePresentationResolver.cycleLinkedButton(item, state: state)
            } label: {
                Text(item.buttonValueText)
            }
            .buttonStyle(PanelButtonStyle(
                width: ParameterPageMetrics.displayWidth,
                height: ParameterPageMetrics.selectorButtonHeight,
                active: item.buttonIsActive
            ))
            .disabled(item.buttonParamIndex == nil)
            .offset(y: ParameterPageMetrics.buttonY)
            .help(item.buttonName.isEmpty ? "No linked button" : item.buttonName)
        }
        .frame(width: ParameterPageMetrics.slotWidth,
               height: ParameterPageMetrics.slotHeight,
               alignment: .topLeading)
        .contextMenu {
            if !state.showsGlobalParameterPages, item.knobParamIndex != nil {
                Button("Clear Assignment") { state.clearKnob(index: index) }
            }
        }
    }

    // MARK: - Wybór grupy i strony

    private var selectorBackground: some View {
        Rectangle()
            .fill(UIColor.panelWell)
            .frame(width: ParameterPageMetrics.contentSize.width
                - ParameterPageMetrics.selectorWellX,
                height: ParameterPageMetrics.contentSize.height)
            .offset(x: ParameterPageMetrics.selectorWellX)
    }

    private var pageSelector: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                state.showsGlobalParameterPages.toggle()
                focusFirstVisiblePage()
            } label: {
                Text("Global Pages")
            }
            .buttonStyle(PanelButtonStyle(
                width: ParameterPageMetrics.selectorWidth,
                height: ParameterPageMetrics.selectorButtonHeight,
                active: state.showsGlobalParameterPages
            ))
            .help("Show the performance-wide parameter pages")

            VStack(alignment: .leading, spacing: 0) {
                ForEach(0 ..< G2KnobPages.groupNames.count, id: \.self) { group in
                    HStack(spacing: 4) {
                        selectorButton(String(UnicodeScalar(UInt8(65 + group))),
                                       selected: state.focusedParameterPage / 3 == group)
                        {
                            state.focusedParameterPage = group * 3 + state.focusedParameterPage % 3
                        }
                        Text(G2KnobPages.groupNames[group])
                            .font(.system(size: ParameterPageMetrics.labelFont, weight: .semibold))
                            .fontWidth(.condensed)
                            .foregroundStyle(UIColor.panelText)
                    }
                }
            }

            HStack(spacing: 0) {
                ForEach(0 ..< 3, id: \.self) { column in
                    selectorButton(String(column + 1),
                                   selected: state.focusedParameterPage % 3 == column)
                    {
                        state.focusedParameterPage = state.focusedParameterPage / 3 * 3 + column
                    }
                }
            }
        }
        .offset(x: ParameterPageMetrics.selectorX, y: 5)
    }

    private func focusFirstVisiblePage() {
        let first: Int? = if state.showsGlobalParameterPages {
            state.performance.globalKnobAssignments.firstIndex { $0 != nil }
        } else if state.slots.indices.contains(state.selectedSlot) {
            state.patch.knobAssignments.firstIndex { $0 != nil }
        } else {
            nil
        }
        state.focusedParameterPage = (first ?? 0) / G2KnobPages.knobsPerPage
    }

    private func selectorButton(_ title: String, selected: Bool,
                                action: @escaping () -> Void) -> some View
    {
        Button(action: action) { Text(title) }
            .buttonStyle(PanelButtonStyle(
                width: ParameterPageMetrics.selectorButtonWidth,
                height: ParameterPageMetrics.selectorButtonHeight,
                active: selected
            ))
    }
}

struct ParameterPageAssignment {
    let slot: Int
    let location: UInt8
    let moduleID: Int
    let paramIndex: Int

    var area: PatchArea? {
        PatchArea(rawValue: location)
    }
}

/// Cel przypisania wskazujący obszar USTAWIEŃ patcha (2) — gałkę morfu, jego źródło
/// albo pole arkusza Patch Settings. Oryginał nie ma dla tego osobnej gałęzi:
/// Knob Floater Container (GetActualControl) oddaje przez `CPatch::GetControllerFromParamSpec`
/// PRAWDZIWĄ kontrolkę, a okno pyta ją o nazwę, wartość i zmianę. My musimy to rozpisać,
/// bo `PatchArea` zna tylko voice i fx → [[Docs/ui/parameter-pages]].
enum ParameterPageSettingTarget: Equatable {
    case morphDial(Int)
    case morphSource(Int)
    case patchSetting(G2PatchSetting)
}

/// Tożsamość modułu, po której oryginał poznaje, że sąsiednia gałka należy do tego
/// samego modułu i nazwy nie trzeba powtarzać (Knob Floater Module Ref (operator)!=).
struct ParameterPageModuleRef: Equatable {
    let slot: Int
    let location: UInt8
    let moduleID: Int
}

struct ParameterPagePresentation {
    let moduleName: String
    let parameterName: String
    var value: Int?
    var valueText: String
    var targetSlot: Int?
    var area: PatchArea?
    var moduleID: Int?
    var moduleTypeID: Int?
    var moduleRef: ParameterPageModuleRef?
    var knobParamIndex: Int?
    /// Ustawiony, gdy gałka wskazuje obszar 2 — wtedy `area` jest `nil`.
    var settingTarget: ParameterPageSettingTarget?
    var buttonParamIndex: Int?
    var buttonName: String
    var buttonValueText: String
    var buttonValue: Int?
    var buttonValueCount: Int
    var buttonIsActive: Bool

    init(moduleName: String, parameterName: String, value: Int? = nil,
         valueText: String = "", targetSlot: Int? = nil, area: PatchArea? = nil,
         moduleID: Int? = nil, moduleTypeID: Int? = nil,
         moduleRef: ParameterPageModuleRef? = nil, knobParamIndex: Int? = nil,
         settingTarget: ParameterPageSettingTarget? = nil,
         buttonParamIndex: Int? = nil, buttonName: String = "",
         buttonValueText: String = "", buttonValue: Int? = nil,
         buttonValueCount: Int = 0, buttonIsActive: Bool = false)
    {
        self.moduleName = moduleName
        self.parameterName = parameterName
        self.value = value
        self.valueText = valueText
        self.targetSlot = targetSlot
        self.area = area
        self.moduleID = moduleID
        self.moduleTypeID = moduleTypeID
        self.moduleRef = moduleRef
        self.knobParamIndex = knobParamIndex
        self.settingTarget = settingTarget
        self.buttonParamIndex = buttonParamIndex
        self.buttonName = buttonName
        self.buttonValueText = buttonValueText
        self.buttonValue = buttonValue
        self.buttonValueCount = buttonValueCount
        self.buttonIsActive = buttonIsActive
    }

    static let empty = ParameterPagePresentation(moduleName: "", parameterName: "")

    /// Nazwę modułu pisze tylko pierwsza gałka z serii należącej do tego samego
    /// modułu; kolejne zostawiają puste pole, żeby nazwa miała gdzie się rozlać.
    static func showsModuleName(at slot: Int, in row: [ParameterPagePresentation]) -> Bool {
        guard row.indices.contains(slot), let ref = row[slot].moduleRef else { return false }
        guard slot > 0 else { return true }
        return row[slot - 1].moduleRef != ref
    }

    /// Na ile kolumn rozciąga się nazwa modułu i jej myślniki: własna seria gałek
    /// tego modułu plus następujące po niej wolne pola. Oryginał sięga tak samo
    /// (nazwa wchodzi na sąsiada, który własnej nie pisze), tylko zatrzymuje się
    /// po drugiej kolumnie.
    static func moduleRunLength(from slot: Int, in row: [ParameterPagePresentation]) -> Int {
        guard row.indices.contains(slot), let ref = row[slot].moduleRef else { return 1 }
        var length = 1
        while row.indices.contains(slot + length) {
            let next = row[slot + length].moduleRef
            guard next == ref || next == nil else { break }
            length += 1
        }
        return length
    }
}

/// Wspólny opis przypisania dla pojedynczej strony i okna całego przeglądu.
/// Oba widoki muszą podawać identyczne nazwy, wartości i powiązane przyciski.
@MainActor
enum ParameterPagePresentationResolver {
    static func visibleAssignment(at index: Int, state: PatchState) -> ParameterPageAssignment? {
        if state.showsGlobalParameterPages {
            guard state.performance.globalKnobAssignments.indices.contains(index),
                  let assignment = state.performance.globalKnobAssignments[index] else { return nil }
            return ParameterPageAssignment(slot: assignment.slot,
                                           location: assignment.location,
                                           moduleID: assignment.moduleID,
                                           paramIndex: assignment.paramIndex)
        }
        guard let assignment = state.patch.knobAssignment(at: index) else { return nil }
        return ParameterPageAssignment(slot: state.selectedSlot,
                                       location: assignment.location,
                                       moduleID: assignment.moduleID,
                                       paramIndex: assignment.paramIndex)
    }

    static func presentation(at index: Int, state: PatchState) -> ParameterPagePresentation {
        presentation(for: visibleAssignment(at: index, state: state), state: state)
    }

    static func presentation(for assignment: ParameterPageAssignment?,
                             state: PatchState) -> ParameterPagePresentation
    {
        guard let assignment, state.slots.indices.contains(assignment.slot) else { return .empty }
        guard let area = assignment.area else {
            return settingsPresentation(for: assignment, state: state)
        }
        let patch = state.slots[assignment.slot]
        guard let module = patch.modules(in: area).first(where: { $0.id == assignment.moduleID }) else {
            return ParameterPagePresentation(moduleName: "Module \(assignment.moduleID)",
                                             parameterName: "Param \(assignment.paramIndex)")
        }

        let definition = ModuleDatabase.module(id: module.typeID)
        let ui = ModuleUIDatabase.shared.uiDef(forID: module.typeID)
        let baseName = module.label.isEmpty
            ? (definition?.shortName ?? "Module \(module.id)") : module.label
        let moduleName = state.showsGlobalParameterPages
            ? "\(slotLetter(assignment.slot)) \(baseName)" : baseName
        let knobName = parameterName(at: assignment.paramIndex, moduleTypeID: module.typeID,
                                     definition: definition)
        let knobValue = module.parameters.indices.contains(assignment.paramIndex)
            ? module.parameters[assignment.paramIndex] : nil
        let knobValueText = knobValue.map {
            formattedValue(paramIndex: assignment.paramIndex, value: $0, module: module, ui: ui)
        } ?? ""
        let ref = ParameterPageModuleRef(slot: assignment.slot, location: assignment.location,
                                         moduleID: module.id)

        var item = ParameterPagePresentation(
            moduleName: moduleName,
            parameterName: knobName,
            value: knobValue,
            valueText: knobValueText,
            targetSlot: assignment.slot,
            area: area,
            moduleID: module.id,
            moduleTypeID: module.typeID,
            moduleRef: ref,
            knobParamIndex: assignment.paramIndex
        )

        guard let buttonParam = ModuleParameterLinks.buttonParameter(
            moduleTypeID: module.typeID,
            knobParameter: assignment.paramIndex
        ), module.parameters.indices.contains(buttonParam) else { return item }

        let buttonValue = module.parameters[buttonParam]
        let button = buttonDetails(paramIndex: buttonParam, value: buttonValue,
                                   moduleTypeID: module.typeID, definition: definition, ui: ui)
        item.buttonParamIndex = buttonParam
        item.buttonName = parameterName(at: buttonParam, moduleTypeID: module.typeID,
                                        definition: definition)
        item.buttonValueText = button.text
        item.buttonValue = buttonValue
        item.buttonValueCount = button.valueCount
        item.buttonIsActive = buttonValue != 0
        return item
    }

    /// Gałka wskazująca obszar USTAWIEŃ patcha. Nazwy biorą się stąd, skąd bierze je
    /// kontrolka, którą oryginał w tym miejscu podstawia: gałka morfu ma nazwę morfu
    /// (Morph Knob), pole arkusza — swoją etykietę.
    private static func settingsPresentation(for assignment: ParameterPageAssignment,
                                             state: PatchState) -> ParameterPagePresentation
    {
        let patch = state.slots[assignment.slot]
        let variation = patch.activeVariation
        let ref = ParameterPageModuleRef(slot: assignment.slot, location: assignment.location,
                                         moduleID: assignment.moduleID)
        let prefix = state.showsGlobalParameterPages ? "\(slotLetter(assignment.slot)) " : ""

        func item(_ moduleName: String, _ parameterName: String, value: Int,
                  valueText: String, target: ParameterPageSettingTarget) -> ParameterPagePresentation
        {
            ParameterPagePresentation(moduleName: prefix + moduleName,
                                      parameterName: parameterName,
                                      value: value,
                                      valueText: valueText,
                                      targetSlot: assignment.slot,
                                      moduleID: assignment.moduleID,
                                      moduleRef: ref,
                                      knobParamIndex: assignment.paramIndex,
                                      settingTarget: target)
        }

        if assignment.moduleID == morphSettingsModule {
            let morph = assignment.paramIndex % G2Morph.count
            guard G2Morph.names.indices.contains(morph) else { return .empty }
            if assignment.paramIndex < G2Morph.count {
                let value = patch.morphDial(morph, in: variation)
                return item("Morph", G2Morph.names[morph], value: value,
                            valueText: "\(value)", target: .morphDial(morph))
            }
            guard assignment.paramIndex < G2Morph.count * 2 else { return .empty }
            let options = G2Morph.sourceOptions(morph: morph)
            let value = min(patch.morphMode(morph, in: variation), options.count - 1)
            return item("Morph", "\(G2Morph.names[morph]) Src", value: value,
                        valueText: options[value], target: .morphSource(morph))
        }

        guard let setting = G2PatchSetting.allCases.first(where: {
            $0.module == assignment.moduleID && $0.param == assignment.paramIndex
        }) else { return .empty }
        let value = state.patchSetting(setting, slot: assignment.slot)
        return item("Patch", setting.label, value: value,
                    valueText: setting.valueText(value), target: .patchSetting(setting))
    }

    /// Numer modułu, pod którym w obszarze ustawień siedzą morfy (`PATCH_MORPH`).
    private static let morphSettingsModule = 1

    static func cycleLinkedButton(_ item: ParameterPagePresentation, state: PatchState) {
        guard let targetSlot = item.targetSlot,
              let area = item.area,
              let moduleID = item.moduleID,
              let paramIndex = item.buttonParamIndex,
              let value = item.buttonValue else { return }
        let count = max(2, item.buttonValueCount)
        state.setParameter(slot: targetSlot, moduleID: moduleID, paramIndex: paramIndex,
                           value: (value + 1) % count, area: area)
    }

    /// Gałka okna działa tak samo jak gałka modułu — instrukcja str. 126:
    /// „Click-hold an assigned knob in the Parameter Pages window and change its value".
    static func setKnobValue(_ item: ParameterPagePresentation, value: Int, state: PatchState) {
        guard let targetSlot = item.targetSlot else { return }
        let clamped = max(0, min(knobMaxValue(item), value))
        if let target = item.settingTarget {
            switch target {
            case let .morphDial(morph):
                state.setMorphDial(morph, value: clamped, slot: targetSlot)
            case let .morphSource(morph):
                state.setMorphMode(morph, value: clamped, slot: targetSlot)
            case let .patchSetting(setting):
                state.setPatchSetting(setting, value: clamped, slot: targetSlot)
            }
            return
        }
        guard let area = item.area,
              let moduleID = item.moduleID,
              let paramIndex = item.knobParamIndex else { return }
        state.setParameter(slot: targetSlot, moduleID: moduleID, paramIndex: paramIndex,
                           value: clamped, area: area)
    }

    static func knobMaxValue(_ item: ParameterPagePresentation) -> Int {
        if case let .morphSource(morph) = item.settingTarget {
            return max(0, G2Morph.sourceOptions(morph: morph).count - 1)
        }
        guard let typeID = item.moduleTypeID, let paramIndex = item.knobParamIndex else { return 127 }
        return ParameterRangeDatabase.range(moduleTypeID: typeID, codeRef: paramIndex)?
            .upperBound ?? 127
    }

    /// Zakres morfu dla gałki okna — ta sama informacja i te same kolory co na gałce
    /// w patchu (czerwony = morf z focusem, niebieski = pozostałe). Patch bierzemy
    /// ze slotu przypisania, bo Global Pages potrafią wskazać moduł w innym slocie.
    static func morphTint(_ item: ParameterPagePresentation,
                          state: PatchState) -> MorphIndicator.Tint?
    {
        guard let ref = item.moduleRef, let paramIndex = item.knobParamIndex,
              state.slots.indices.contains(ref.slot) else { return nil }
        let patch = state.slots[ref.slot]
        let assignments = patch.morphs(variation: patch.activeVariation,
                                       location: ref.location,
                                       moduleID: ref.moduleID, paramIndex: paramIndex)
        return MorphIndicator.tint(for: assignments, focusedMorph: state.focusedMorph,
                                   value: item.value ?? 0, maxValue: knobMaxValue(item))
    }

    /// Nazwa parametru tak, jak wpisuje ją oryginał — reguła siedzi w `G2ParameterText`,
    /// wspólna dla okna, przeglądu i narzędzi bez okna.
    static func parameterName(at index: Int, moduleTypeID: Int,
                              definition _: ModuleDef?) -> String
    {
        G2ParameterText.name(moduleTypeID: moduleTypeID, paramIndex: index)
    }

    private static func formattedValue(paramIndex: Int, value: Int, module: G2Module,
                                       ui _: ModuleUIDef?) -> String
    {
        G2ParameterText.value(paramIndex: paramIndex, value: value, module: module)
    }

    private static func buttonDetails(paramIndex: Int, value: Int, moduleTypeID: Int,
                                      definition: ModuleDef?, ui _: ModuleUIDef?)
        -> (text: String, valueCount: Int)
    {
        if let options = G2ParameterText.buttonOptions(moduleTypeID: moduleTypeID, paramIndex: paramIndex) {
            return (options.text(for: value), options.count)
        }
        return (parameterName(at: paramIndex, moduleTypeID: moduleTypeID, definition: definition), 2)
    }

    private static func slotLetter(_ slot: Int) -> String {
        guard (0 ..< 4).contains(slot) else { return "?" }
        return String(UnicodeScalar(UInt8(65 + slot)))
    }
}

/// Ekran gałki jest źródłem przeciągania: na parametr modułu w patchu (przypisz)
/// albo na inny ekran (przenieś). Knob Floater Overview (Click) startuje drag
/// z każdego pola — także pustego — więc nowy przydział robi się tak samo jak
/// przeniesienie istniejącego.
struct ParameterPageDragSource: ViewModifier {
    let index: Int
    let state: PatchState

    func body(content: Content) -> some View {
        content
            .onDrag {
                NSItemProvider(object: ParameterPageDragData.string(
                    index: index,
                    global: state.showsGlobalParameterPages
                ) as NSString)
            } preview: {
                ParameterAssignDragPreview()
            }
            .onDrop(of: [.text], isTargeted: nil) { providers in
                acceptParameterPageDrop(providers, target: index, state: state)
            }
    }
}

/// Za kursorem nie idzie cały ekran, tylko znak „przypisz parametr" — inaczej
/// wielki prostokąt zasłaniał gałkę modułu, na którą się celuje.
struct ParameterAssignDragPreview: View {
    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 13, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(UIColor.buttonActive))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.2))
    }
}

@discardableResult
func acceptParameterPageDrop(_ providers: [NSItemProvider], target: Int,
                             state: PatchState) -> Bool
{
    guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
        return false
    }
    provider.loadObject(ofClass: NSString.self) { object, _ in
        guard let text = object as? String,
              let payload = ParameterPageDragData.parse(text) else { return }
        Task { @MainActor in
            guard payload.global == state.showsGlobalParameterPages else { return }
            state.moveParameterPageKnob(from: payload.index, to: target)
        }
    }
    return true
}

private struct ParameterPageDisplay: View {
    let name: String
    let value: String

    var body: some View {
        // Oryginał nie zmniejsza fontu — `DrawCentredAbbreviatedText` skraca napis
        // i dokleja kropki, dopóki się nie zmieści. Stąd `truncationMode`, a nie
        // `minimumScaleFactor`, przez który długie nazwy robiły się nieczytelne.
        VStack(spacing: -1) {
            Text(name)
                .font(.custom("MatrixSansScreen-Regular", size: ParameterPageMetrics.lcdNameFont))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(value)
                .font(.custom("MatrixSansScreen-Regular", size: ParameterPageMetrics.lcdValueFont))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(UIColor.lcdText)
        .frame(width: ParameterPageMetrics.displayWidth,
               height: ParameterPageMetrics.displayHeight)
        .panelScreen()
    }
}
