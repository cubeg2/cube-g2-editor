// ModuleColorPalette.swift
// Dwadzieścia cztery kolory modułu — JEDNO miejsce dla wszystkich, które je pokazują:
// nagłówek modułu na kanwie, kwadraciki w menu „Color" i okno palety (Tools ▸ Colors).
//
// Źródło: `ModuleColors[0..24]` z `BVE.NMG2Types.pas` (format Delphi `$00BBGGRR`).
// Indeks 0 = „bez koloru użytkownika" i nie należy do palety — moduł bierze wtedy
// kolor swojej kategorii.

import AppKit
import SwiftUI

enum ModuleColorPalette {
    /// Numery kolorów w kolejności z pliku patcha (`G2Module.color`).
    static let all: [UInt8] = Array(1 ... 24)

    static func color(_ index: UInt8) -> Color {
        switch index {
        case 1: Color(red: 0.800, green: 0.729, blue: 0.729) // red4    (pale pink)
        case 2: Color(red: 0.729, green: 0.800, blue: 0.729) // green4  (pale green)
        case 3: Color(red: 0.690, green: 0.729, blue: 0.800) // blue4   (pale blue)
        case 4: Color(red: 0.816, green: 0.796, blue: 0.667) // yellow4 (pale yellow)
        case 5: Color(red: 0.455, green: 0.627, blue: 0.831) // blue1   (medium blue)
        case 6: Color(red: 0.898, green: 0.467, blue: 0.478) // red1    (medium red)
        case 7: Color(red: 0.482, green: 0.757, blue: 0.741) // cyan2   (teal)
        case 8: Color(red: 0.510, green: 0.725, blue: 0.502) // green2  (medium green)
        case 9: Color(red: 0.906, green: 0.820, blue: 0.282) // yellow1 (bright yellow)
        case 10: Color(red: 0.576, green: 0.820, blue: 0.384) // green1  (bright green)
        case 11: Color(red: 0.871, green: 0.780, blue: 0.490) // yellow2 (gold/amber)
        case 12: Color(red: 0.561, green: 0.604, blue: 0.761) // blue3   (steel blue)
        case 13: Color(red: 0.729, green: 0.490, blue: 0.506) // red2    (mauve)
        case 14: Color(red: 0.792, green: 0.553, blue: 0.553) // red3    (pale red)
        case 15: Color(red: 0.871, green: 0.820, blue: 0.647) // yellow3 (cream)
        case 16: Color(red: 0.580, green: 0.812, blue: 0.612) // green3  (light green)
        case 17: Color(red: 0.412, green: 0.839, blue: 0.780) // cyan1   (turquoise)
        case 18: Color(red: 0.627, green: 0.824, blue: 0.784) // cyan3   (mint)
        case 19: Color(red: 0.745, green: 0.824, blue: 0.824) // cyan4   (pale cyan)
        case 20: Color(red: 0.502, green: 0.549, blue: 0.753) // blue2   (cornflower)
        case 21: Color(red: 0.839, green: 0.451, blue: 0.780) // magenta1 (orchid)
        case 22: Color(red: 0.745, green: 0.510, blue: 0.745) // magenta2 (medium orchid)
        case 23: Color(red: 0.804, green: 0.627, blue: 0.824) // magenta3 (light orchid)
        case 24: Color(red: 0.824, green: 0.745, blue: 0.824) // magenta4 (pale orchid)
        default: UIColor.modulePanelGray
        }
    }

    /// Nazwa w menu i w dymku palety.
    static func name(_ index: UInt8) -> String {
        switch index {
        case 1: "Pale Pink"
        case 2: "Pale Green"
        case 3: "Pale Blue"
        case 4: "Pale Yellow"
        case 5: "Medium Blue"
        case 6: "Medium Red"
        case 7: "Teal"
        case 8: "Medium Green"
        case 9: "Bright Yellow"
        case 10: "Bright Green"
        case 11: "Gold"
        case 12: "Steel Blue"
        case 13: "Mauve"
        case 14: "Pale Red"
        case 15: "Cream"
        case 16: "Light Green"
        case 17: "Turquoise"
        case 18: "Mint"
        case 19: "Pale Cyan"
        case 20: "Cornflower"
        case 21: "Orchid"
        case 22: "Medium Orchid"
        case 23: "Light Orchid"
        case 24: "Pale Orchid"
        default: "Default (Category)"
        }
    }

    // MARK: - Kwadracik do menu

    /// `NSMenu` (a to ono stoi za menu kontekstowym SwiftUI) nie rysuje ikon `Label`
    /// zbudowanych z kształtów SwiftUI — trzeba mu dać gotowy `NSImage`.
    ///
    /// ⚠️ Rysujemy przez `NSImage(size:flipped:drawingHandler:)`, a **nie** przez
    /// `lockFocus()`. `lockFocus` jest wycofane od macOS 14 i rysuje w kontekście
    /// bieżącego ekranu w chwili wywołania — obrazek zbudowany raz na sesję (w leniwej
    /// stałej typu) potrafił wyjść pusty i menu zostawało bez kwadracików. Handler jest
    /// wołany dopiero wtedy, gdy obrazek naprawdę się rysuje, i tyle razy, ile trzeba —
    /// więc wychodzi tak samo na każdym Macu i przy każdej rozdzielczości.
    static func swatchImage(_ index: UInt8) -> NSImage {
        let size = NSSize(width: 19, height: 19)
        let fill = NSColor(color(index))
        let image = NSImage(size: size, flipped: false) { _ in
            let rect = NSRect(origin: .zero, size: size).insetBy(dx: 1.0, dy: 1.0)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            fill.setFill()
            path.fill()
            // Ciemniejsza ramka, żeby jasne kolory (Pale Yellow) nie zlewały się z tłem menu.
            NSColor.black.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1.25
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
