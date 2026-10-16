// ModuleUIDatabase.swift
// G2Core — module UI database loaded from bundled Bruno Verhue Gen1 files.
//
// Loads 192 bundled panel files on first access. The app therefore does not depend on
// the development-only `reference/` tree.
// Reference source: panel structures from the original Nord Modular G2 Editor by Clavia.
// Design intent: preserve a familiar panel layout for users accustomed to the original editor.
//
// Lookup:
//   uiDef(forName:)  → module shortName (matches Name: in the panel file)
//   uiDef(forID:)    → G2Module typeID (through ModuleDatabase.module(id:))

import Foundation

public final class ModuleUIDatabase {
    // MARK: - Singleton

    public static let shared = ModuleUIDatabase()

    // MARK: - Zasoby paneli

    private static var bundledModulesURL: URL {
        guard let url = Bundle.g2Core.url(forResource: "Modules", withExtension: nil) else {
            preconditionFailure("Brak dołączonego katalogu paneli BVerhue Gen1")
        }
        return url
    }

    // MARK: - Wewnętrzne słowniki

    // byNameMulti: klucz lowercase Name: z .txt → wszystkie pasujące UIDef
    // Powód: kilka plików .txt może mieć tę samą wartość Name: (np. Delay.txt i Delay_Unknown.txt
    // mają Name:"Delay"). Zbieramy wszystkie kandydatów zamiast nadpisywać.
    private var byNameMulti: [String: [ModuleUIDef]] = [:]
    private var byID: [Int: ModuleUIDef] = [:] // klucz: typeID
    private var fileNameToTypeID: [String: Int] = [:] // FileName: z .txt → typeID (do ładowania PNG)

    // MARK: - Inicjalizacja

    private init() {
        loadAll(from: Self.bundledModulesURL)
    }

    private func loadAll(from dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else {
            preconditionFailure("Nie można odczytać dołączonych paneli z \(dir.path)")
        }

        for file in files
            .filter({ $0.pathExtension.lowercased() == "txt" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let uiDef = BVerhueParser.parse(text: text),
                  !uiDef.name.isEmpty
            else { continue }

            let key = uiDef.name.lowercased()
            byNameMulti[key, default: []].append(uiDef)
        }

        // Zbuduj słownik ID → UIDef oraz FileName → typeID.
        // Gdy kilka .txt ma tę samą Name: (np. "Delay"), wybieramy UIDef której
        // height pasuje do ModuleDef.height — unikamy przypisania złego pliku.
        for moduleDef in ModuleDatabase.all {
            let candidates = byNameMulti[moduleDef.shortName.lowercased()] ?? []
            guard !candidates.isEmpty else { continue }
            let uiDef = candidates.first(where: { $0.height == moduleDef.height })
                ?? candidates[0]
            byID[moduleDef.id] = ModuleUILayout.aligned(uiDef, def: moduleDef)
            // Mapuj FileName z .txt → typeID (kluczowe dla prawidłowego ładowania PNG)
            if !uiDef.fileName.isEmpty {
                fileNameToTypeID[uiDef.fileName.lowercased()] = moduleDef.id
            }
        }
    }

    // MARK: - API

    /// Zwraca definicję UI po shortName (np. "OscA", "LfoA").
    /// Gdy kilka .txt pasuje do tej nazwy, zwraca pierwszego kandydata.
    public func uiDef(forName name: String) -> ModuleUIDef? {
        byNameMulti[name.lowercased()]?.first
    }

    /// Zwraca definicję UI po typeID z G2Module.
    public func uiDef(forID id: Int) -> ModuleUIDef? {
        byID[id]
    }

    /// Liczba załadowanych modułów (do diagnostyki).
    public var count: Int {
        byNameMulti.count
    }

    /// Czy dane dla danego ID są dostępne.
    public func hasData(forID id: Int) -> Bool {
        byID[id] != nil
    }

    /// Zwraca typeID dla podanego FileName z .txt (np. "LfoA" → 26).
    /// Używane do diagnostyki mapowania FileName → typeID.
    public func typeID(forFileName fn: String) -> Int? {
        fileNameToTypeID[fn.lowercased()]
    }
}
