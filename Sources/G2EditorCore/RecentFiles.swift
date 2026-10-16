// RecentFiles.swift
// „Recent files — here you can choose to open any of the most recently opened
// Patches" (instrukcja Clavii, str. 116).
//
// Lista żyje w `UserDefaults`, nie w `PatchState`: przeżywa zamknięcie programu
// i nie należy do żadnego otwartego dokumentu.

import Foundation

public enum RecentFiles {
    /// Tyle pozycji pokazuje menu oryginału.
    public static let limit = 10

    private static let key = "g2_recent_files"

    /// Pliki od ostatnio otwartego. Te, których już nie ma na dysku, wypadają
    /// przy odczycie — menu nie ma pokazywać martwych pozycji.
    public static var urls: [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        return paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func remember(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > limit { paths = Array(paths.prefix(limit)) }
        UserDefaults.standard.set(paths, forKey: key)
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
