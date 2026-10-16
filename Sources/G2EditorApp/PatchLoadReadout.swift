// PatchLoadReadout.swift
// Cztery liczby obciążenia — Voice i FX, moc i pamięć — w dwóch miejscach naraz.
//
//   • `.toolbar` — dwie grupy OBOK SIEBIE w górnym pasku: najpierw `VA`, potem `FX`,
//     w każdej `Cycles` i `Memory`. Do 2026-09-10 była to tabelka 2 × 2 (obszary jeden
//     pod drugim) i to ona mierzyła wysokość całej belki — układ poziomy ścina ją o
//     jakieś 25 pt, a przy okazji pozwala powiększyć same cyfry.
//   • `.preview` — pod podglądem modułu chwyconego z palety, w stylu ekranów na modułach
//     (`UIColor.lcdBackground` / `lcdText`, font `MatrixSansScreen-Regular`, etykiety białe).
//     Pokazuje, ile będzie PO puszczeniu modułu. Znika, gdy podgląd zamienia się w ghosta
//     nad canvasem — tam liczby zasłaniałyby to, na co użytkownik właśnie celuje.
//
// Progi kolorów w obu trybach bierze `DSPLoadLevel`, wspólny z panelem „DSP Load";
// inaczej to samo 99% świeciłoby w trzech miejscach na trzy sposoby.

import G2Core
import G2EditorCore
import SwiftUI

enum PatchLoadMetrics {
    // Tryb `.preview` — wymiary bazowe przy skali 1.
    static let screenWidth: CGFloat = 38
    static let screenHeight: CGFloat = 13
    static let barHeight: CGFloat = 3
    static let valueFont: CGFloat = 9.5
    static let labelFont: CGFloat = 7.5
    static let cellGap: CGFloat = 3
    static let rowLabelWidth: CGFloat = 15

    /// Szerokość paska `.preview` przy skali 1 — policzona, nie zmierzona, bo każdy
    /// element ma tu sztywną szerokość. Z niej bierze się skala dopasowująca pasek
    /// do szerokości modułu w palecie.
    static var previewWidth: CGFloat {
        let group = rowLabelWidth + cellGap + screenWidth + cellGap + screenWidth
        return 2 * group + cellGap * 3
    }

    static var previewHeight: CGFloat {
        labelFont + 1 + screenHeight + 1 + barHeight
    }

    /// Skala, przy której pasek ma dokładnie szerokość `width`.
    static func previewScale(fittingWidth width: CGFloat) -> CGFloat {
        width / previewWidth
    }
}

/// Dwa wyglądy tej samej liczby.
///
///   • `.lcd` — zielone cyfry na ciemnym ekranie, jak wyświetlacze na modułach. Ma sens
///     tam, gdzie tłem jest sam patch: pod podglądem modułu chwyconego z palety.
///   • `.plain` — ta sama ramka co przyciski belki (`TopBarMetrics`), cyfry krojem
///     systemowym. W górnym pasku ciemne ekrany były jedyną taką plamą i wybijały się
///     z całości; kolor niesie tam już tylko pasek postępu, czyli to, co coś znaczy.
enum PatchLoadCellStyle {
    case lcd
    case plain
}

/// Jeden odczyt: wartość i pasek pod spodem.
struct PatchLoadCell: View {
    let percent: Double?
    var scale: CGFloat = 1
    var style: PatchLoadCellStyle = .lcd

    var body: some View {
        VStack(alignment: .leading, spacing: 1 * scale) {
            ZStack {
                background
                Text(PatchLoadFormat.text(percent))
                    .font(valueFont)
                    .foregroundStyle(style == .lcd ? UIColor.lcdText : Color.primary)
            }
            .frame(width: PatchLoadMetrics.screenWidth * scale,
                   height: PatchLoadMetrics.screenHeight * scale)
            PatchLoadBar(percent: percent,
                         width: PatchLoadMetrics.screenWidth * scale,
                         height: PatchLoadMetrics.barHeight * scale,
                         style: style)
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .lcd:
            Rectangle().fill(UIColor.lcdBackground)
        case .plain:
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                )
        }
    }

    private var valueFont: Font {
        switch style {
        case .lcd:
            .custom("MatrixSansScreen-Regular", size: PatchLoadMetrics.valueFont * scale)
        case .plain:
            .system(size: PatchLoadMetrics.valueFont * scale, weight: .medium).monospacedDigit()
        }
    }
}

/// Pasek obcina się na 100%, ale liczba obok nie — patch potrafi zażądać więcej,
/// niż G2 ma (raport `0x72` mówi o żądaniu, nie o przydziale).
struct PatchLoadBar: View {
    let percent: Double?
    let width: CGFloat
    let height: CGFloat
    var style: PatchLoadCellStyle = .lcd

    var body: some View {
        ZStack(alignment: .leading) {
            // Czarne tło paska jest częścią ekranu LCD; w belce byłoby drugą ciemną
            // plamą, więc rowek jest tam tylko przygaszonym tłem.
            Rectangle().fill(style == .lcd ? Color.black : Color.primary.opacity(0.15))
            Rectangle()
                .fill(PatchLoadFormat.color(percent))
                .frame(width: width * min(max(percent ?? 0, 0), 100) / 100)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: style == .lcd ? 0 : 1.5))
    }
}

enum PatchLoadFormat {
    static func text(_ percent: Double?) -> String {
        guard let percent else { return "--" }
        return String(format: "%.1f", percent)
    }

    static func color(_ percent: Double?) -> Color {
        switch DSPLoadLevel(percent: percent ?? 0) {
        case .critical: Color(red: 0.95, green: 0.1, blue: 0.1)
        case .warning: Color(red: 0.95, green: 0.6, blue: 0.0)
        case .safe: Color(red: 0.35, green: 0.85, blue: 0.35)
        }
    }
}

struct PatchLoadReadout: View {
    enum Layout {
        case toolbar
        case preview
    }

    let voice: G2PatchLoad?
    let fx: G2PatchLoad?
    let layout: Layout
    var scale: CGFloat = 1

    /// Ghost i podgląd leżą na ciemnym tle — tam etykiety są białe; w belce muszą
    /// iść za motywem systemu, bo pasek bywa jasny.
    var labelColor: Color = .primary

    var body: some View {
        switch layout {
        case .toolbar:
            HStack(alignment: .top, spacing: PatchLoadMetrics.cellGap * 2 * scale) {
                group("VA", load: voice)
                // Kreska rozdziela obszary, skoro nie rozdziela ich już wiersz.
                Rectangle()
                    .fill(Color.primary.opacity(0.30))
                    .frame(width: 1)
                group("FX", load: fx)
            }
            .fixedSize()
            .help("Patch load — cycles and memory for the Voice and FX areas (⌘⌥3 for the full picture)")
        case .preview:
            HStack(alignment: .bottom, spacing: PatchLoadMetrics.cellGap * 3 * scale) {
                group("VA", load: voice)
                group("FX", load: fx)
            }
        }
    }

    /// Ta sama para kolumn ustawiona pionowo — dla paska pod podglądem modułu,
    /// gdzie miejsca w poziomie jest dużo, a w pionie mało.
    private func group(_ name: String, load: G2PatchLoad?) -> some View {
        HStack(alignment: .top, spacing: PatchLoadMetrics.cellGap * scale) {
            // Nazwa obszaru stoi w jednej linii z LICZBĄ, nie z dolną krawędzią kolumny:
            // zejście o wysokość nagłówka i własna ramka wysokości ekranu ustawiają ją
            // dokładnie na wysokości wartości.
            label(name)
                .frame(width: PatchLoadMetrics.rowLabelWidth * scale,
                       height: PatchLoadMetrics.screenHeight * scale,
                       alignment: .leading)
                .padding(.top, (PatchLoadMetrics.labelFont + 1) * scale)
            column("Cycles", percent: load?.cyclesPercent)
            column("Memory", percent: load?.memoryPercent)
        }
    }

    /// Wygląd wartości: w belce ta sama ramka co przyciski, w palecie ekran modułu.
    private var cellStyle: PatchLoadCellStyle {
        layout == .toolbar ? .plain : .lcd
    }

    private func column(_ title: String, percent: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1 * scale) {
            header(title)
            PatchLoadCell(percent: percent, scale: scale, style: cellStyle)
        }
    }

    private func header(_ text: String) -> some View {
        label(text).frame(width: PatchLoadMetrics.screenWidth * scale, alignment: .center)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(cellStyle == .lcd
                ? .custom("MatrixSansScreen-Regular", size: PatchLoadMetrics.labelFont * scale)
                : .system(size: PatchLoadMetrics.labelFont * scale, weight: .medium))
            .foregroundStyle(labelColor)
    }
}
