// PluginNavigator.swift
// Navigator w oknie wtyczki DAW-a — jak pokrętło i przyciski przy ekranie Norda: strzałki idą
// po patchach po kolei, drugie strzałki skaczą o bank (albo kategorię), Sort Mode zmienia
// kolejność, a dopiero „Load" wgrywa wybrany patch do slotu. Samo przewijanie niczego nie wgrywa.
//
// Dwa źródła, jak w przeglądarce: banki G2 (`g2:<bank>:<miejsce>`) i folder panelu Banks
// (ścieżka pliku). Dysk nie zna kategorii bez czytania plików, więc tam kolejność to folder
// albo nazwa A–Z.

import Foundation
import G2Core

public enum PluginNavigator {
    /// `place` — w kolejności banków (dysk: folderów); `name` — banki G2 według kategorii,
    /// dysk według nazwy.
    public enum Sort: String {
        case place, name
    }

    /// Pozycja na liście Navigatora.
    public struct Item: Equatable {
        public var address: String
        public var name: String
        public var category: String
        /// „1:12" w banku G2, podfolder na dysku.
        public var location: String
        /// Na co skaczą drugie strzałki: bank, kategoria, folder albo pierwsza litera.
        public var group: String

        var json: [String: Any] {
            ["path": address, "name": name, "category": category, "location": location]
        }
    }

    public static func items(_ entries: [G2BankEntry], sort: Sort) -> [Item] {
        let patches = entries.filter { $0.kind == .patch && !$0.name.isEmpty }
        let ordered = switch sort {
        case .place:
            patches.sorted { ($0.bank, $0.patch) < ($1.bank, $1.patch) }
        case .name:
            patches.sorted {
                ($0.category, $0.name.lowercased(), $0.bank, $0.patch) < ($1.category, $1.name.lowercased(), $1.bank,
                                                                          $1.patch)
            }
        }
        return ordered.map { entry in
            let category = PluginBrowser.categoryName(entry.category)
            return Item(address: PluginBrowser.address(entry), name: entry.name, category: category,
                        location: entry.displayLocation,
                        group: sort == .place ? "bank \(entry.bank)" : category)
        }
    }

    public static func items(_ files: [DiskBankItem], sort: Sort) -> [Item] {
        let patches = files.filter { !$0.isPerformance }
        let ordered = switch sort {
        case .place:
            patches.sorted {
                $0.relativeFolder == $1.relativeFolder
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.relativeFolder.localizedStandardCompare($1.relativeFolder) == .orderedAscending
            }
        case .name:
            patches.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return ordered.map { file in
            Item(address: file.url.path, name: file.name, category: "", location: file.relativeFolder,
                 group: sort == .place ? file.relativeFolder : String(file.name.prefix(1)).uppercased())
        }
    }

    /// Następna pozycja od `from` (adres) — `step` ±1. `group: true` skacze do pierwszej pozycji
    /// następnej (albo poprzedniej) grupy. Lista zawija się na końcach. Bez punktu startu:
    /// naprzód = pierwsza pozycja, wstecz = ostatnia.
    public static func step(_ items: [Item], from: String?, by step: Int, group: Bool) -> Item? {
        guard !items.isEmpty else { return nil }
        guard let from, let index = items.firstIndex(where: { $0.address == from }) else {
            return step >= 0 ? items.first : items.last
        }
        guard group else {
            return items[(index + (step >= 0 ? 1 : -1) + items.count) % items.count]
        }
        // Pierwsze pozycje grup, po kolei.
        let starts = items.indices.filter { $0 == 0 || items[$0].group != items[$0 - 1].group }
        let current = starts.lastIndex { $0 <= index } ?? 0
        let target = (current + (step >= 0 ? 1 : -1) + starts.count) % starts.count
        return items[starts[target]]
    }
}
