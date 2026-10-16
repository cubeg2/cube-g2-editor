// PluginBrowser.swift
// Przeglądarka patchy w oknie wtyczki DAW-a (Etap 6b, plan: Docs/Plan projektu/
// 05-wtyczka-funkcje.md §2.3).
//
// Pliki czyta edytor, nie wtyczka: wtyczka w Logicu siedzi w piaskownicy i folderów użytkownika
// nie widzi. Folder jest ten sam co w panelu Banks (`DiskBankLibrary`, jedno ustawienie). Szukanie
// po nazwie i ścieżce; o zawartości (kategoria, moduły, DSP) edytor mówi dopiero dla wybranego
// pliku — czytanie tysięcy patchy przy każdym szukaniu byłoby za wolne, a indeksu na dysku
// jeszcze nie ma.

import Foundation
import G2Core

public enum PluginBrowser {
    /// Tyle wyników dostaje okno — więcej i tak nikt nie przewinie; zawęża się szukaniem.
    public static let resultLimit = 300

    /// Pliki `.pch2` pasujące do szukania: każde słowo ma wystąpić w nazwie albo ścieżce.
    /// Performance'y (`.prf2`) odpadają — wtyczka wgrywa patch do swojego slotu. `group` = podfolder
    /// (z jego podfolderami); `nil` = cały folder.
    public static func search(_ items: [DiskBankItem], query: String, group: String? = nil) -> [DiskBankItem] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let matching = items.filter { item in
            guard !item.isPerformance else { return false }
            if let group, item.relativeFolder != group, !item.relativeFolder.hasPrefix(group + "/") { return false }
            let haystack = (item.relativeFolder + "/" + item.name).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Podfoldery z patchami — kolumna filtra w przeglądarce. Pusty napis = pliki wprost w folderze.
    public static func groups(_ items: [DiskBankItem]) -> [String] {
        Set(items.filter { !$0.isPerformance }.map(\.relativeFolder))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Banki G2

    /// Adres miejsca w banku G2 zamiast ścieżki pliku: `g2:<bank>:<miejsce>` (od zera).
    public static func address(_ entry: G2BankEntry) -> String {
        "g2:\(entry.bank):\(entry.patch)"
    }

    public static func entry(address: String, in entries: [G2BankEntry]) -> G2BankEntry? {
        let parts = address.split(separator: ":")
        guard parts.count == 3, parts[0] == "g2", let bank = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        return entries.first { $0.kind == .patch && $0.bank == bank && $0.patch == patch }
    }

    /// Patche z banków G2 pasujące do szukania (nazwa, kategoria, „bank 3"); puste miejsca odpadają.
    /// `group` = nazwa kategorii.
    public static func search(_ entries: [G2BankEntry], query: String, group: String? = nil) -> [G2BankEntry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return entries.filter { entry in
            guard entry.kind == .patch, !entry.name.isEmpty else { return false }
            if let group, categoryName(entry.category) != group { return false }
            let haystack = "\(entry.name) \(categoryName(entry.category)) bank \(entry.bank + 1)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// Kategorie, które mają patche w bankach G2 — w kolejności Clavii.
    public static func groups(_ entries: [G2BankEntry]) -> [String] {
        let used = Set(entries.filter { $0.kind == .patch && !$0.name.isEmpty }.map(\.category))
        return G2PatchCategory.names.indices.filter { used.contains($0) }.map(categoryName).filter { !$0.isEmpty }
    }

    static func json(_ entry: G2BankEntry) -> [Any] {
        [address(entry), entry.name, "Bank \(entry.bank + 1) · \(entry.patch + 1)", 0, categoryName(entry.category)]
    }

    /// Opis miejsca w banku — zawartości patcha nie znamy, dopóki nie trafi do slotu.
    static func info(_ entry: G2BankEntry) -> [String: Any] {
        ["name": entry.name, "category": categoryName(entry.category), "location": entry.displayLocation]
    }

    static func categoryName(_ category: Int) -> String {
        category > 0 && G2PatchCategory.names.indices.contains(category) ? G2PatchCategory.names[category] : ""
    }

    static func json(_ item: DiskBankItem) -> [Any] {
        [item.url.path, item.name, item.relativeFolder, item.tags.first?.color ?? 0]
    }

    /// Patch z pliku, z nazwą pliku, gdy `.pch2` nie niesie własnej (tak robi Open To).
    public static func patch(at url: URL) throws -> G2Patch {
        let data = try Data(contentsOf: url)
        guard var patch = try PatchParser.parseFile(data: data).patches.first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        patch.fillMissingParameters()
        if patch.name.isEmpty {
            patch.name = String(url.deletingPathExtension().lastPathComponent.prefix(G2PatchName.maxLength))
        }
        return patch
    }

    /// Opis wybranego pliku: kategoria, liczba modułów i obciążenie DSP z tabeli kosztów
    /// (`G2PatchLoad.estimate`) — moc i pamięć w procentach, osobno dla głosów i efektów.
    /// Ponad 100% w którejkolwiek = patch nie wejdzie do slotu.
    public static func info(_ patch: G2Patch) -> [String: Any] {
        let category = G2PatchCategory.names.indices.contains(patch.description.category)
            ? G2PatchCategory.names[patch.description.category] : ""
        func load(_ area: PatchArea) -> [Double] {
            let estimate = G2PatchLoad.estimate(area: area, modules: patch.modules(in: area))
            return [(estimate.cyclesPercent * 10).rounded() / 10, (estimate.memoryPercent * 10).rounded() / 10]
        }
        return ["name": patch.name, "category": category,
                "modules": patch.voiceModules.count + patch.fxModules.count,
                "voice": load(.voice), "fx": load(.fx)]
    }
}
