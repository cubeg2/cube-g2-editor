// G2Clipboard.swift
// Typy do kopiowania/wklejania modułów (⌘C / ⌘V).
// G2ClipboardContent jest Codable i trafia na NSPasteboard jako JSON.

import AppKit
import G2Core
import G2EditorCore

// MARK: - NSPasteboard helpers

extension G2ClipboardContent {
    private static let pasteboardType = NSPasteboard.PasteboardType("com.g2editor.modules")

    /// Zapisuje zawartość na systemowy schowek.
    func writeToPasteboard() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
    }

    /// Czy na schowku w ogóle są nasze moduły — samo sprawdzenie typu, bez dekodowania
    /// JSON-a. Tyle wystarczy, żeby włączyć albo wygasić „Paste" w menu, a menu pyta o to
    /// wielokrotnie, dopóki jest otwarte.
    static var hasModulesOnPasteboard: Bool {
        NSPasteboard.general.availableType(from: [pasteboardType]) != nil
    }

    /// Czyta zawartość ze schowka. Zwraca nil jeśli brak danych G2.
    static func readFromPasteboard() -> G2ClipboardContent? {
        guard let data = NSPasteboard.general.data(forType: pasteboardType),
              let content = try? JSONDecoder().decode(G2ClipboardContent.self, from: data)
        else { return nil }
        return content
    }
}

// MARK: - Budowa zawartości schowka

extension G2ClipboardContent {
    /// Moduły o podanych numerach wraz z kablami, które biegną WYŁĄCZNIE między nimi —
    /// kabel wychodzący poza kopiowaną grupę nie miałby po wklejeniu drugiego końca.
    ///
    /// Jedno miejsce dla obu dróg kopiowania: menu pod prawym przyciskiem nad modułem
    /// i pozycja Edit ▸ Copy w menu głównym.
    /// `labels` — sekcja 0x5B obszaru: podpisy kopiowanych modułów jadą z nimi.
    static func make(modules: [G2Module], cables: [G2Cable], ids: Set<Int>,
                     labels: G2ModuleLabelSection? = nil) -> G2ClipboardContent?
    {
        let picked = modules.filter { ids.contains($0.id) }
        guard !picked.isEmpty else { return nil }

        let inner = cables.filter { ids.contains($0.fromModule) && ids.contains($0.toModule) }
        let labelData = Dictionary((labels?.entries ?? []).map { ($0.moduleID, $0.content) },
                                   uniquingKeysWith: { first, _ in first })
        return G2ClipboardContent(
            modules: picked.map { module in
                ClipModule(typeID: module.typeID,
                           column: module.column,
                           row: module.row,
                           parameters: module.parameters,
                           parameterVariations: module.parameterVariations,
                           modes: module.modes,
                           label: module.label,
                           color: module.color,
                           originalID: module.id,
                           labelData: labelData[module.id])
            },
            cables: inner.map { cable in
                ClipCable(fromModule: cable.fromModule,
                          fromConnector: cable.fromConnector,
                          toModule: cable.toModule,
                          toConnector: cable.toConnector,
                          cableColor: Int(cable.color.rawValue),
                          sourceIsOutput: cable.sourceIsOutput)
            }
        )
    }
}

// MARK: - Duch wklejenia

extension G2ClipboardContent {
    /// Moduły ze schowka jako obrysy dla `BlockDropGhost` — typ, pozycja i nazwa.
    func ghostModules(in area: PatchArea) -> [G2Module] {
        modules.enumerated().map { index, clip in
            var module = G2Module(id: index + 1, typeID: clip.typeID, area: area)
            module.column = clip.column
            module.row = clip.row
            module.label = clip.label
            return module
        }
    }
}
