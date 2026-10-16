import Foundation

// Zasoby z paczek SwiftPM także z wnętrza `.app`.
//
// Wygenerowane `Bundle.module` szuka paczki obok pliku wykonywalnego (`Bundle.main.bundleURL`),
// a w drugiej kolejności pod ścieżką katalogu budowania z Maca, na którym kompilowano.
// W `Cube G2 Editor.app` paczki muszą leżeć w `Contents/Resources` — w korzeniu `.app`
// psułyby podpis — więc tam patrzymy najpierw (Tools/build_app.sh).

public extension Bundle {
    /// Paczka zasobów `name` z `Contents/Resources` aplikacji; `nil`, gdy jej tam nie ma.
    static func appResourceBundle(_ name: String) -> Bundle? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(name + ".bundle") else { return nil }
        return Bundle(url: url)
    }
}

extension Bundle {
    static let g2Core = appResourceBundle("G2Editor_G2Core") ?? .module
}
