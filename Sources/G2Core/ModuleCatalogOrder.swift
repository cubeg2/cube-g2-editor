// ModuleCatalogOrder.swift
// Kanoniczna kolejność kategorii, modułów i wizualnych grup z edytora Clavia G2.

import Foundation

/// Układ katalogu modułów odtworzony z Module Factory.
///
/// Clavia przydziela modułom rosnący `ToolbarIndex`, a `RegisterSpacing()`
/// zostawia pusty indeks. Puste indeksy są tutaj granicami grup wizualnych.
/// Nie należy utożsamiać ich z grupami bezpiecznej podmiany z
/// `ModuleReplacementDatabase`, ponieważ te dwie struktury nie zawsze są identyczne.
public enum ModuleCatalogOrder {
    /// Oryginalna kolejność kart Clavii. PM jest rozszerzeniem firmware G2,
    /// którego nie ma w pasku oryginalnego edytora, więc pozostaje na końcu.
    public static let categories: [String] = [
        "In/Out", "Note", "Osc", "LFO", "Rnd", "Env", "Filter",
        "FX", "Delay", "Shaper", "Level", "Mixer", "Switch", "Logic", "Seq", "MIDI", "PM",
    ]

    /// Typy modułów pogrupowane według pustych pozycji oryginalnego paska.
    public static let visualGroups: [String: [[Int]]] = [
        "In/Out": [[4, 3], [170, 171], [127], [1, 199, 30], [197], [156], [126]],
        "Note": [[75, 152, 22], [72, 158], [198, 160], [115]],
        "Osc": [[97, 7, 9, 96], [183], [163, 8], [164], [106, 31, 29], [196, 58], [13], [180, 165], [27]],
        "LFO": [[26, 190, 24], [25], [68]],
        "Rnd": [[200, 202], [204, 206], [205], [208]],
        "Env": [[20], [41, 55, 84, 46], [119, 52], [169, 23]],
        "Filter": [[87, 134], [51, 92, 49, 54], [102, 162], [125, 45, 108], [103, 32, 33]],
        "FX": [[94, 192, 89], [118], [98, 167, 63], [12], [150]],
        "Delay": [[172, 173, 174, 175, 181, 179, 178], [176, 177, 182]],
        "Shaper": [[61, 62, 28, 34], [74], [83, 82]],
        "Level": [[43, 188, 50], [112, 157], [81, 44, 117], [71, 189, 59, 159, 128], [195]],
        "Mixer": [[184, 185], [194, 66, 193, 19, 123, 140], [116, 40, 161], [48], [47, 18, 113, 114]],
        "Switch": [[36, 76], [187, 100, 79, 15], [186, 90, 88, 78], [105, 17, 85], [124, 21, 60], [53, 139]],
        "Logic": [[64, 5], [91], [69], [38, 42], [86, 130, 131, 132]],
        "Seq": [[144, 145, 146, 121], [154]],
        "MIDI": [[141, 142, 143], [147, 148], [149, 57]],
        "PM": [[35, 56]],
    ]

    /// Zwraca kategorie w kolejności Clavii, a nieznane przyszłe kategorie
    /// dopisuje alfabetycznie na końcu, żeby nie ukrywać ich w interfejsie.
    public static func orderedCategories(from definitions: [ModuleDef]) -> [String] {
        let available = Set(definitions.map(\.page))
        let known = categories.filter { available.contains($0) }
        return known + available.subtracting(Set(categories)).sorted()
    }

    /// Zwraca moduły kategorii w kolejności paska Clavii.
    /// Nieznane moduły są dopisywane alfabetycznie na końcu.
    public static func orderedModules(in category: String, from definitions: [ModuleDef]) -> [ModuleDef] {
        let matching = definitions.filter { $0.page == category }
        let rank = moduleRanks[category] ?? [:]
        return matching.sorted { lhs, rhs in
            let lhsRank = rank[lhs.id] ?? Int.max
            let rhsRank = rank[rhs.id] ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.shortName.localizedCaseInsensitiveCompare(rhs.shortName) == .orderedAscending
        }
    }

    /// Zwraca wszystkie definicje w kanonicznej kolejności katalogu.
    public static func orderedModules(from definitions: [ModuleDef]) -> [ModuleDef] {
        orderedCategories(from: definitions).flatMap { orderedModules(in: $0, from: definitions) }
    }

    /// `true` dla pierwszego modułu każdej grupy wizualnej poza pierwszą.
    public static func startsSeparatedVisualGroup(typeID: Int, in category: String) -> Bool {
        guard let groups = visualGroups[category] else { return false }
        return groups.dropFirst().contains { $0.first == typeID }
    }

    private static let moduleRanks: [String: [Int: Int]] = visualGroups.mapValues { groups in
        Dictionary(uniqueKeysWithValues: groups.flatMap { $0 }.enumerated().map { ($1, $0) })
    }
}
