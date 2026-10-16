// PanelTypography.swift
// Jeden rozmiar liter dla wszystkich pływających paneli oraz wspólny generator
// „rozciągniętej" nazwy modułu.
//
// Powód: Parameter Pages, Parameter Overview i Patch Mutator miały każdy własne
// stałe (9, 10, 11, 11.8 pt), przez co ta sama etykieta w dwóch oknach wyglądała
// inaczej i w Overview była nieczytelna. Tu jest jedno źródło prawdy.

import AppKit
import SwiftUI

enum PanelTypography {
    /// Etykiety panelu: nazwa modułu nad ekranem, nazwa przycisku pod gałką,
    /// numer rzędu w Overview.
    static let label: CGFloat = 12.5
    /// Napis na przycisku.
    static let button: CGFloat = 11
    /// Nagłówek grupy stron („A Osc").
    static let heading: CGFloat = 13.5

    /// `NSFont` odpowiadający `.system(size:weight:.semibold).fontWidth(.condensed)` —
    /// potrzebny, żeby zmierzyć tekst tak, jak narysuje go SwiftUI.
    static func labelFont(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .semibold, width: .condensed)
    }
}

/// Nazwa modułu rozciągnięta myślnikami na całą serię gałek, które do niego należą,
/// zakończona `|` — tak, jak pisze to górna linia wyświetlacza Norda.
///
/// Sam edytor Clavii tego nie robi (w Knob Floater* nie ma ani jednego `'-'`);
/// nie ma tego też w pliku patcha, gdzie w nazwie modułu siedzi wyłącznie sama
/// nazwa. Myślniki generujemy więc u siebie, dopasowując ich liczbę do zmierzonej
/// szerokości — na życzenie użytkownika → [[Docs/ui/parameter-pages]].
@MainActor
enum ModuleRunLabel {
    private struct Key: Hashable {
        let name: String
        let width: CGFloat
        let size: CGFloat
    }

    private static var cache: [Key: String] = [:]

    /// Zwraca `name` bez zmian, gdy myślniki nie mają gdzie się zmieścić.
    static func text(_ name: String, width: CGFloat, size: CGFloat) -> String {
        let base = trimmedName(name)
        guard !base.isEmpty else { return "" }
        let key = Key(name: base, width: width, size: size)
        if let cached = cache[key] { return cached }
        let value = build(base, width: width, size: size)
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[key] = value
        return value
    }

    /// Autorzy patchów sami dopisują do nazw ozdobniki („LFO1------", „MST-OSC --|").
    /// Ucinamy je, żeby nie zdublować własnych myślników.
    private static func trimmedName(_ name: String) -> String {
        var text = Substring(name)
        while let last = text.last, "-–—_| ".contains(last) {
            text = text.dropLast()
        }
        return String(text)
    }

    private static func build(_ name: String, width: CGFloat, size: CGFloat) -> String {
        let font = PanelTypography.labelFont(size: size)
        let measure = { (text: String) in
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        let dash = measure("-")
        guard dash > 0 else { return name }
        let free = width - measure(name + " ") - measure("|")
        let count = Int((free / dash).rounded(.down))
        guard count >= 2 else { return name }
        return name + " " + String(repeating: "-", count: count) + "|"
    }
}
