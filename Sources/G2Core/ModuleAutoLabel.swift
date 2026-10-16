// ModuleAutoLabel.swift
// Domyślne etykiety nowych modułów: `<shortName><N>`, N rośnie osobno dla
// każdego typu modułu (zgodnie z zachowaniem edytora Clavii).

import Foundation

public enum ModuleAutoLabel {
    /// Kolejna wolna etykieta dla `shortName` — najwyższy użyty numer wśród
    /// `existingLabels` + 1. Ręcznie nadane etykiety (bez wzorca `shortName<N>`)
    /// nie wchodzą do puli i nie wpływają na numerację.
    public static func next(shortName: String, existingLabels: [String]) -> String {
        let numbers = existingLabels.compactMap { suffixNumber($0, shortName: shortName) }
        return "\(shortName)\((numbers.max() ?? 0) + 1)"
    }

    /// `true`, gdy `label` to nietknięta domyślna etykieta (`shortName` samo
    /// albo `shortName` + numer) — moduł Name nie pokazuje takiej etykiety na
    /// panelu, dopóki użytkownik nie wpisze czegoś innego.
    public static func isUntouchedDefault(_ label: String, shortName: String) -> Bool {
        label == shortName || suffixNumber(label, shortName: shortName) != nil
    }

    private static func suffixNumber(_ label: String, shortName: String) -> Int? {
        guard label.hasPrefix(shortName) else { return nil }
        let suffix = label.dropFirst(shortName.count)
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
        return Int(suffix)
    }
}
