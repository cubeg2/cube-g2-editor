// ParameterOverviewPanel.swift
// Wszystkie 120 przypisań stron parametrów w jednym pływającym oknie.
// Układ i przełączniki są oparte na Knob Floater Overview oryginalnej Clavii;
// kontrolki zachowują współczesną optykę `ParameterPagesPanel`.
//
// Pole = Knob Floater Overview Group: nazwa modułu (55 × 15, u nas wyśrodkowana
// względem ekranu — oryginał pisze ją do lewej) i pod nią
// ekran Knob Floater Knob View w trybie `EDisplay = 1`, czyli **sama nazwa
// parametru, bez wartości**. Wartość widać w oknie Parameter Pages.

import G2Core
import G2EditorCore
import SwiftUI
import UniformTypeIdentifiers

private enum ParameterOverviewMetrics {
    static let contentSize = CGSize(width: 530, height: 765)
    static let groupSpacing: CGFloat = 4
    static let groupPadding: CGFloat = 3
    static let rowSpacing: CGFloat = 2
    /// Osiem kolumn plus numer rzędu wypełnia dokładnie 504 pt wnętrza grupy;
    /// ekran zajmuje całą kolumnę, więc odstęp między ekranami to same `cellSpacing`.
    static let cellWidth: CGFloat = 58.375
    static let cellSpacing: CGFloat = 3
    static let cellHeight: CGFloat = 38
    static let displayWidth = cellWidth
    static let displayHeight: CGFloat = 21
    static let moduleNameHeight: CGFloat = 16
    static let labelWidth: CGFloat = 13
    static let labelFont = PanelTypography.label
    static let displayFont: CGFloat = 10
    static let buttonHeight: CGFloat = 18
}

/// Pełna mapa piętnastu stron i 120 gałek. Kliknięcie pola ustawia tę stronę jako
/// aktywną w zwykłym oknie Parameter Pages, tak aby oba okna zawsze wskazywały ten sam cel.
struct ParameterOverviewPanel: View {
    @Bindable var state: PatchState
    @State private var showsButtons = false
    @State private var showsMidi = false

    var body: some View {
        VStack(spacing: ParameterOverviewMetrics.groupSpacing) {
            controls
            ForEach(0 ..< G2KnobPages.groupNames.count, id: \.self) { group in
                groupSection(group)
            }
        }
        .padding(8)
        .frame(width: ParameterOverviewMetrics.contentSize.width,
               height: ParameterOverviewMetrics.contentSize.height,
               alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Clavia control row

    private var controls: some View {
        HStack(spacing: 5) {
            Button {
                state.autoAssignMidiControllersFromParameterPages()
            } label: {
                Text("Assign MIDI")
            }
            .buttonStyle(PanelButtonStyle(width: 88, height: ParameterOverviewMetrics.buttonHeight, active: false))
            .disabled(state.showsGlobalParameterPages)
            .opacity(state.showsGlobalParameterPages ? 0 : 1)
            .help("Assign the first available MIDI controllers to the visible local knob map")

            Button {
                state.clearMidiControllersFromParameterPages()
            } label: {
                Text("Clear MIDI")
            }
            .buttonStyle(PanelButtonStyle(width: 84, height: ParameterOverviewMetrics.buttonHeight, active: false))
            .disabled(state.showsGlobalParameterPages)
            .opacity(state.showsGlobalParameterPages ? 0 : 1)
            .help("Clear MIDI controllers assigned through the local knob map")

            Button {
                showsMidi.toggle()
            } label: {
                Text("View MIDI")
            }
            .buttonStyle(PanelButtonStyle(width: 78, height: ParameterOverviewMetrics.buttonHeight, active: showsMidi))
            .help(showsMidi ? "Show parameter names" : "Show MIDI controller numbers")

            Button {
                showsButtons.toggle()
            } label: {
                Text("View Buttons")
            }
            .buttonStyle(PanelButtonStyle(width: 96, height: ParameterOverviewMetrics.buttonHeight, active: showsButtons))
            .help(showsButtons ? "Show linked button assignments" : "Show parameter assignments")

            Button {
                state.showsGlobalParameterPages.toggle()
            } label: {
                Text("Global Pages")
            }
            .buttonStyle(PanelButtonStyle(width: 100, height: ParameterOverviewMetrics.buttonHeight,
                                          active: state.showsGlobalParameterPages))
            .help("Show performance-wide parameter pages")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Fifteen pages

    private func groupSection(_ group: Int) -> some View {
        VStack(alignment: .leading, spacing: ParameterOverviewMetrics.rowSpacing) {
            Text("\(String(UnicodeScalar(UInt8(65 + group))))  \(G2KnobPages.groupNames[group])")
                .font(.system(size: PanelTypography.heading, weight: .semibold))
                .fontWidth(.condensed)
                .foregroundStyle(UIColor.panelText)

            ForEach(0 ..< 3, id: \.self) { row in
                overviewRow(page: group * 3 + row, row: row)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, ParameterOverviewMetrics.groupPadding)
        .panelGroupBackground()
    }

    private func overviewRow(page: Int, row: Int) -> some View {
        let items = (0 ..< G2KnobPages.knobsPerPage).map { slot in
            ParameterPagePresentationResolver.presentation(
                at: G2KnobPages.knobIndex(page: page, slot: slot), state: state
            )
        }
        return HStack(spacing: ParameterOverviewMetrics.cellSpacing) {
            Text("\(row + 1)")
                .font(.system(size: ParameterOverviewMetrics.labelFont, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: ParameterOverviewMetrics.labelWidth,
                       height: ParameterOverviewMetrics.cellHeight)

            ForEach(0 ..< G2KnobPages.knobsPerPage, id: \.self) { slot in
                overviewCell(page: page, slot: slot, items: items)
            }
        }
    }

    /// Nazwa modułu zajmuje całą serię jego gałek — oryginał rozciąga ją najwyżej na
    /// dwie kolumny (`SetSize(0x6e, 13)` w Knob Floater Overview (SetupState)), ale
    /// dopiero pełna seria daje myślnikom `ModuleRunLabel` prawdziwy zasięg.
    private func moduleNameWidth(_ slot: Int, items: [ParameterPagePresentation]) -> CGFloat {
        let run = CGFloat(ParameterPagePresentation.moduleRunLength(from: slot, in: items))
        return run * ParameterOverviewMetrics.cellWidth
            + (run - 1) * ParameterOverviewMetrics.cellSpacing
    }

    private func overviewCell(page: Int, slot: Int,
                              items: [ParameterPagePresentation]) -> some View
    {
        let index = G2KnobPages.knobIndex(page: page, slot: slot)
        let item = items[slot]
        let nameWidth = moduleNameWidth(slot, items: items)
        let moduleName = ParameterPagePresentation.showsModuleName(at: slot, in: items)
            ? ModuleRunLabel.text(item.moduleName, width: nameWidth,
                                  size: ParameterOverviewMetrics.labelFont)
            : ""
        let displayedParam = showsButtons && item.buttonParamIndex != nil
            ? item.buttonParamIndex : item.knobParamIndex
        let name = displayName(item, paramIndex: displayedParam)

        let cell = VStack(spacing: 1) {
            Text(moduleName)
                .font(.system(size: ParameterOverviewMetrics.labelFont, weight: .semibold))
                .fontWidth(.condensed)
                .foregroundStyle(UIColor.panelText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: nameWidth, height: ParameterOverviewMetrics.moduleNameHeight)
                .frame(width: ParameterOverviewMetrics.displayWidth, alignment: .leading)

            ParameterOverviewDisplay(name: name)
        }
        .frame(width: ParameterOverviewMetrics.cellWidth,
               height: ParameterOverviewMetrics.cellHeight)
        .contentShape(Rectangle())
        .onTapGesture { state.focusedParameterPage = page }
        .help("\(G2KnobPages.pageLabel(page)) — open in Parameter Pages")

        return parameterPageDragInteraction(cell, index: index)
    }

    /// Co pokazuje ekran: nazwę parametru, nazwę powiązanego przycisku („--", gdy
    /// parametr żadnego nie ma) albo numer kontrolera MIDI — dokładnie te trzy
    /// gałęzie ma Knob Floater Overview (SetupState).
    private func displayName(_ item: ParameterPagePresentation, paramIndex: Int?) -> String {
        guard item.knobParamIndex != nil else { return "" }
        guard showsMidi else {
            guard showsButtons else { return item.parameterName }
            return item.buttonParamIndex == nil ? "--" : item.buttonName
        }
        guard !showsButtons || item.buttonParamIndex != nil else { return "" }
        return midiController(for: item, paramIndex: paramIndex).map { "CC# \($0)" } ?? ""
    }

    private func midiController(for item: ParameterPagePresentation, paramIndex: Int?) -> Int? {
        // Adres bierzemy z `moduleRef`, nie z `area` — obszar USTAWIEŃ patcha (2) też ma
        // wpisy w tablicy kontrolerów, a `PatchArea` nie umie go wyrazić.
        guard let slot = item.targetSlot, let moduleID = item.moduleID,
              let location = item.moduleRef?.location, let paramIndex,
              state.slots.indices.contains(slot) else { return nil }
        return state.slots[slot].midiController(
            for: location,
            moduleID: moduleID,
            paramIndex: paramIndex
        )
    }

    /// W trybach View MIDI i View Buttons oryginalny `Click` nie zaczyna dragowania.
    /// Poza nimi ciągnie się **każde** pole — także puste, bo tak właśnie robi się
    /// nowe przypisanie (upuszczenie na parametr modułu w patchu).
    @ViewBuilder
    private func parameterPageDragInteraction(_ content: some View, index: Int) -> some View {
        if showsButtons || showsMidi {
            content
        } else {
            content.modifier(ParameterPageDragSource(index: index, state: state))
        }
    }
}

enum ParameterPageDragData {
    private static let prefix = "g2-parameter-page:"

    static func string(index: Int, global: Bool) -> String {
        "\(prefix)\(global ? 1 : 0):\(index)"
    }

    static func parse(_ string: String) -> (global: Bool, index: Int)? {
        guard string.hasPrefix(prefix) else { return nil }
        let fields = string.dropFirst(prefix.count).split(separator: ":")
        guard fields.count == 2, let mode = Int(fields[0]), let index = Int(fields[1]),
              (0 ..< G2KnobPages.knobCount).contains(index) else { return nil }
        return (mode == 1, index)
    }
}

private struct ParameterOverviewDisplay: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.custom("MatrixSansScreen-Regular", size: ParameterOverviewMetrics.displayFont))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(UIColor.lcdText)
            .frame(width: ParameterOverviewMetrics.displayWidth,
                   height: ParameterOverviewMetrics.displayHeight)
            .panelScreen()
    }
}
