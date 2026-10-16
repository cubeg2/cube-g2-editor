// ColorsPanel.swift
// Paleta kolorów modułu (Tools ▸ Colors, przycisk z wiaderkiem w górnej belce).
//
// Te same dwadzieścia cztery kolory, które są w menu „Color" pod prawym przyciskiem —
// tylko że stąd bierze się je myszą i upuszcza wprost na moduł. Kolor jedzie tą samą
// drogą co z menu (`PatchState.setModuleColor`), więc cofa się jednym ⌘Z i tak samo
// poleci do Norda, gdy komenda `0x31` będzie sprawdzona na sprzęcie.

import G2Core
import G2EditorCore
import SwiftUI

struct ColorsPanel: View {
    let state: PatchState

    private static let swatchSize = CGSize(width: 28, height: 22)
    private static let columnCount = 6
    private static let columnGap: CGFloat = 5
    private static let columns = Array(
        repeating: GridItem(.fixed(swatchSize.width), spacing: columnGap), count: columnCount
    )
    /// Dokładna szerokość sześciu kolumn z przerwami — tyle samo ma pasek „bez koloru"
    /// pod spodem, żeby siatka i pasek kończyły się w tej samej pionowej linii.
    private static let gridWidth = CGFloat(columnCount) * swatchSize.width
        + CGFloat(columnCount - 1) * columnGap

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Drag a colour onto a module")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                // Stała wysokość wiersza: z niej i z siatki liczony jest rozmiar okna
                // (`PanelController.Panel.fixedWindowSize`), żeby margines był równy dookoła.
                .frame(height: 13)

            LazyVGrid(columns: Self.columns, spacing: Self.columnGap) {
                ForEach(ModuleColorPalette.all, id: \.self) { color in
                    swatch(color)
                        .frame(width: Self.swatchSize.width, height: Self.swatchSize.height)
                }
            }
            .frame(width: Self.gridWidth)

            // Zerowy numer to „bez koloru użytkownika" — moduł wraca do szarego panelu
            // z kolorem swojej kategorii. Pasek jest szeroki na całą siatkę, żeby nie
            // dało się go pomylić z którymś z dwudziestu czterech.
            swatch(0)
                .frame(width: Self.gridWidth, height: Self.swatchSize.height)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func swatch(_ color: UInt8) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        return shape
            .fill(ModuleColorPalette.color(color))
            .overlay(shape.strokeBorder(Color.black.opacity(0.55), lineWidth: 1))
            .help(ModuleColorPalette.name(color))
            .onDrag {
                NSItemProvider(object: ModuleColorDragData.string(color: color) as NSString)
            } preview: {
                shape
                    .fill(ModuleColorPalette.color(color))
                    .overlay(shape.strokeBorder(Color.black.opacity(0.55), lineWidth: 1))
                    .frame(width: Self.swatchSize.width, height: Self.swatchSize.height)
            }
    }
}

/// Ładunek przeciągania koloru — ten sam wzór co `ParameterPageDragData`: przedrostek,
/// po którym kanwa pozna, że to nie jest numer typu modułu z biblioteki.
enum ModuleColorDragData {
    private static let prefix = "g2-module-color:"

    static func string(color: UInt8) -> String {
        "\(prefix)\(color)"
    }

    static func parse(_ string: String) -> UInt8? {
        guard string.hasPrefix(prefix), let value = UInt8(string.dropFirst(prefix.count)),
              value <= 24 else { return nil }
        return value
    }
}
