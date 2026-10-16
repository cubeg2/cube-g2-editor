// InitPatchLibrary.swift
// Dwa patche startowe — „Save InitPatch1 & 2" z menu File i przyciski „Init 1"/„Init 2"
// w pasku narzędzi (instrukcja Clavii, str. 60 i 116).
//
// „An InitPatch can be used as a 'template' Patch to recall instantly by pressing the
// Init buttons in the Toolbar. You can save two InitPatches."
//
// Oryginał trzyma je jako pliki obok programu; u nas idą do katalogu wsparcia
// aplikacji, bo to jedyne miejsce, do którego na macOS wolno pisać bez pytania.

import Foundation

public enum InitPatchLibrary {
    /// Numery, których używa instrukcja — 1 i 2.
    public static let slots = [1, 2]

    /// Plik danego patcha startowego. Katalog powstaje przy pierwszym zapisie.
    public static func url(_ slot: Int) -> URL? {
        guard slots.contains(slot) else { return nil }
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil,
                                                         create: true) else { return nil }
        return support
            .appendingPathComponent("G2Editor", isDirectory: true)
            .appendingPathComponent("InitPatch\(slot).pch2")
    }

    public static func exists(_ slot: Int) -> Bool {
        guard let url = url(slot) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Zapisuje gotowe bajty `.pch2` jako patch startowy.
    @discardableResult
    public static func store(_ data: Data, slot: Int) -> Bool {
        guard let url = url(slot) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
