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

    /// Pliki pasujące do szukania: każde słowo ma wystąpić w nazwie albo ścieżce. Domyślnie tylko
    /// `.pch2` — wtyczka wgrywa patch do swojego slotu; w trybie Performance wtyczka dokłada `.prf2`
    /// (`performances`) i może wyłączyć patche (`patches`), jak przyciski pch2 / prf2 w panelu Patches.
    /// `group` = podfolder (z jego podfolderami); `nil` = cały folder.
    ///
    /// Szukanie i kolejność jak w panelu Patches edytora: słowa trafiają w nazwę, folder, nazwę tagu,
    /// angielską nazwę jego koloru i kategorię; kolejność to `DiskBankSort` (ta sama funkcja co w panelu);
    /// `category` zawęża do jednej kategorii patchy (jak lejek w panelu).
    public static func search(_ items: [DiskBankItem], query: String, group: String? = nil,
                              performances: Bool = false, patches: Bool = true,
                              direct: Bool = false, sort: DiskBankSort = .name, reversed: Bool = false,
                              category: String? = nil) -> [DiskBankItem]
    {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let matching = items.filter { item in
            guard item.isPerformance ? performances : patches else { return false }
            // `direct` = tylko pliki leżące wprost w `group` (wchodzenie piętro po piętrze, jak w panelu Patches).
            if direct, let group, item.relativeFolder != group { return false }
            if let group, item.relativeFolder != group, !item.relativeFolder.hasPrefix(group + "/") { return false }
            if let category, categoryName(item.category) != category { return false }
            let tags = item.tags.map { "\($0.name) \($0.colorName)" }.joined(separator: " ")
            let haystack = (item.relativeFolder + "/" + item.name + " " + tags + " " + categoryName(item.category))
                .lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        return DiskBankLibrary.sorted(matching, by: sort, reversed: reversed)
    }

    /// Kategorie, które mają w bibliotece choć jeden patch — pozycje menu filtra (kolejność Clavii).
    public static func categories(_ items: [DiskBankItem]) -> [String] {
        let used = Set(items.filter { !$0.isPerformance }.map(\.category))
        return G2PatchCategory.names.indices.filter { used.contains($0) }.map(categoryName).filter { !$0.isEmpty }
    }

    /// Podfoldery z patchami — kolumna filtra w przeglądarce. Pusty napis = pliki wprost w folderze.
    public static func groups(_ items: [DiskBankItem], performances: Bool = false, patches: Bool = true) -> [String] {
        Set(items.filter { $0.isPerformance ? performances : patches }.map(\.relativeFolder))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Podfoldery wprost pod `group` (pusty = główny folder) z liczbą plików w nich i niżej — wiersze folderów
    /// przeglądarki, jak w panelu Patches. Foldery bez plików odpadają (edytor ich nie widzi).
    public static func folders(_ items: [DiskBankItem], under group: String, performances: Bool = false,
                               patches: Bool = true) -> [(name: String, count: Int)]
    {
        let prefix = group.isEmpty ? "" : group + "/"
        var counts: [String: Int] = [:]
        for item in items where item.isPerformance ? performances : patches {
            guard item.relativeFolder.hasPrefix(prefix) else { continue }
            let rest = item.relativeFolder.dropFirst(prefix.count)
            guard let child = rest.split(separator: "/").first else { continue }
            counts[String(child), default: 0] += 1
        }
        return counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ($0, counts[$0] ?? 0) }
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
        [item.url.path, item.name, item.relativeFolder, item.tags.first?.color ?? 0, categoryName(item.category),
         item.tags.map(\.color).filter { $0 > 0 }]
    }

    /// Patch z pliku, z nazwą pliku, gdy `.pch2` nie niesie własnej (tak robi Open To).
    /// Plik `.pch2` nie zawiera nazwy patcha — bierzemy ją z nazwy pliku. Pliki ściągnięte z internetu
    /// mają ozdobniki „Nazwa — Autor [5dde484d]”, które po obcięciu do 16 znaków dawały „Nazwa — ”,
    /// więc przed obcięciem zostaje sama nazwa.
    static func nameFromFile(_ url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        var name = base
        if let hash = name.range(of: #" \[[0-9A-Fa-f]{6,}\]$"#, options: .regularExpression) {
            name.removeSubrange(hash)
        }
        if let dash = name.range(of: " — ") {
            name.removeSubrange(dash.lowerBound...)
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return String((name.isEmpty ? base : name).prefix(G2PatchName.maxLength))
    }

    public static func patch(at url: URL) throws -> G2Patch {
        let data = try Data(contentsOf: url)
        guard var patch = try PatchParser.parseFile(data: data).patches.first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        patch.upgradeLegacyModules()
        patch.fillMissingParameters()
        patch.recomputeUprates()
        if patch.name.isEmpty {
            patch.name = nameFromFile(url)
        }
        return patch
    }

    /// Performance z pliku: patche czterech slotów i ustawienia (zegar, zakresy klawiszy, Hold…),
    /// po tych samych poprawkach co przy otwarciu `.prf2` w edytorze.
    public static func performance(at url: URL) throws -> (patches: [G2Patch], settings: G2PerformanceSettings?, name: String) {
        let parsed = try PatchParser.parseFile(data: Data(contentsOf: url))
        guard !parsed.patches.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let patches = parsed.patches.map { patch -> G2Patch in
            var patch = patch
            patch.upgradeLegacyModules()
            patch.fillMissingParameters()
            patch.recomputeUprates()
            return patch
        }
        var settings = parsed.performance
        settings?.shiftGlobalKnobsOfReshapedParameters(original: parsed.patches)
        settings?.dropGlobalKnobs(removedFrom: parsed.patches, upgraded: patches)
        settings?.swapMorphGlobalKnobs(original: parsed.patches)
        return (patches, settings, url.deletingPathExtension().lastPathComponent)
    }

    /// Opis performance'u: nazwy czterech patchy i obciążenie DSP **sumą** — cztery sloty dzielą
    /// jeden procesor G2, więc „wejdzie” znaczy, że suma nie przekracza 100%.
    public static func performanceInfo(patches: [G2Patch], name: String) -> [String: Any] {
        func total(_ area: PatchArea) -> [Double] {
            let parts = patches.map { G2PatchLoad.estimate(area: area, patch: $0) }
            return [(parts.reduce(0) { $0 + $1.cyclesPercent } * 10).rounded() / 10,
                    (parts.reduce(0) { $0 + $1.memoryPercent } * 10).rounded() / 10]
        }
        return ["name": name, "category": "Performance", "slots": patches.map(\.name),
                "modules": patches.reduce(0) { $0 + $1.voiceModules.count + $1.fxModules.count },
                "voice": total(.voice), "fx": total(.fx)]
    }

    /// Opis wybranego pliku: kategoria, liczba modułów i obciążenie DSP z tabeli kosztów
    /// (`G2PatchLoad.estimate`) — moc i pamięć w procentach, osobno dla głosów i efektów.
    /// Ponad 100% w którejkolwiek = patch nie wejdzie do slotu.
    public static func info(_ patch: G2Patch) -> [String: Any] {
        let category = G2PatchCategory.names.indices.contains(patch.description.category)
            ? G2PatchCategory.names[patch.description.category] : ""
        func load(_ area: PatchArea) -> [Double] {
            let estimate = G2PatchLoad.estimate(area: area, patch: patch)
            return [(estimate.cyclesPercent * 10).rounded() / 10, (estimate.memoryPercent * 10).rounded() / 10]
        }
        return ["name": patch.name, "category": category,
                "modules": patch.voiceModules.count + patch.fxModules.count,
                "voice": load(.voice), "fx": load(.fx)]
    }
}
