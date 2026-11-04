// VariationLockMemory.swift
// Kłódki `Lock Across Variations` zapamiętane przez edytor, nie w pliku patcha.
//
// `.pch2`/`.prf2` zostają takie, jakie zna Nord i oryginalny edytor — kłódki zapisujemy
// w `UserDefaults` pod nazwą pliku (dla `.prf2` także numerem slotu), w chwili zapisu
// patcha. Przy otwarciu kłódka wraca tylko tam, gdzie wciąż ma sens: ten sam moduł pod tym
// samym numerem i parametr równy we wszystkich ośmiu wariacjach. Plik zmieniony gdzie indziej
// (inny Mac, oryginalny edytor) po prostu traci nieaktualne kłódki. Przeniesienie pliku
// kłódki zachowuje, zmiana nazwy je gubi — decyzja użytkownika 2026-10-30.

import Foundation
import G2Core

public struct VariationLockMemory {
    struct Lock: Codable, Equatable {
        let area: UInt8
        let moduleID: Int
        let typeID: Int
        let paramIndex: Int
    }

    private let defaults: UserDefaults
    private static let key = "g2_variation_locks"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Klucz pliku `.pch2`, a z `slot` — jednego slotu `.prf2`. Sama nazwa pliku, bez folderu:
    /// przeniesiony plik zachowuje kłódki. Dwa różne patche o tej samej nazwie są bezpieczne,
    /// bo `restore` sprawdza moduł i równość wartości.
    public static func key(for url: URL, slot: Int? = nil) -> String {
        let name = url.lastPathComponent.lowercased()
        return slot.map { "\(name)#\($0)" } ?? name
    }

    /// Zapamiętuje kłódki patcha (albo zapomina, gdy żadnej nie ma).
    public func store(_ patch: G2Patch, key: String) {
        var all = load()
        let locks = PatchArea.allCases.flatMap { area in
            patch.modules(in: area).flatMap { module in
                module.variationLockedParameters.sorted().map {
                    Lock(area: area.rawValue, moduleID: module.id, typeID: module.typeID, paramIndex: $0)
                }
            }
        }
        guard all[key] != (locks.isEmpty ? nil : locks) else { return }
        all[key] = locks.isEmpty ? nil : locks
        save(all)
    }

    /// Zakłada na świeżo wczytany patch kłódki, które wciąż do niego pasują.
    public func restore(into patch: inout G2Patch, key: String) {
        guard let locks = load()[key] else { return }
        for lock in locks {
            guard let area = PatchArea(rawValue: lock.area),
                  let module = patch.modules(in: area).first(where: { $0.id == lock.moduleID }),
                  module.typeID == lock.typeID,
                  module.parameters.indices.contains(lock.paramIndex) else { continue }
            let values = (0 ..< G2Patch.initVariation).map { variation in
                module.parameterVariations.indices.contains(variation)
                    && module.parameterVariations[variation].indices.contains(lock.paramIndex)
                    ? module.parameterVariations[variation][lock.paramIndex]
                    : module.parameters[lock.paramIndex]
            }
            guard Set(values).count == 1 else { continue }
            patch.setVariationLock(moduleID: lock.moduleID, paramIndex: lock.paramIndex, locked: true, in: area)
        }
    }

    private func load() -> [String: [Lock]] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: [Lock]].self, from: data)) ?? [:]
    }

    private func save(_ all: [String: [Lock]]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
