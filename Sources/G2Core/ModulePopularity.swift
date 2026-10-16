// ModulePopularity.swift
// Popularity rankings z analizy 4648 patchy Nord G2 (reference/patch_stats.json).
// Używane do sortowania sidebaru wg częstości użycia zamiast alfabetycznie.

import Foundation

public enum ModulePopularity {
    // MARK: - Dane (inicjalizacja przy pierwszym użyciu)

    private static let data: (cats: [String: Int], mods: [Int: Int]) = load()

    // MARK: - Public API

    public static func categoryRank(_ name: String) -> Int {
        data.cats[name] ?? 999
    }

    public static func moduleRank(typeID: Int) -> Int {
        data.mods[typeID] ?? 999
    }

    // MARK: - Ładowanie JSON

    private static let statsURL: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            url = url.deletingLastPathComponent()
        }
        return url.appendingPathComponent("reference/patch_stats.json")
    }()

    private static func load() -> (cats: [String: Int], mods: [Int: Int]) {
        guard
            let raw = try? Data(contentsOf: statsURL),
            let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return ([:], [:]) }

        var cats: [String: Int] = [:]
        if let arr = json["categories"] as? [[String: Any]] {
            for item in arr {
                if let n = item["name"] as? String, let r = item["rank"] as? Int { cats[n] = r }
            }
        }

        var mods: [Int: Int] = [:]
        if let arr = json["modules"] as? [[String: Any]] {
            for item in arr {
                if let tid = item["typeID"] as? Int, let r = item["rank"] as? Int { mods[tid] = r }
            }
        }

        return (cats, mods)
    }
}
