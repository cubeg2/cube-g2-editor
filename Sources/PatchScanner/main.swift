// PatchScanner — analiza częstości modułów w kolekcji .pch2 / .prf2
//
// Użycie:
//   swift run PatchScanner <katalog>
//   swift run PatchScanner <katalog> --json
//   swift run PatchScanner <katalog> --top 20
//   swift run PatchScanner <katalog> --census <typeID> [--examples N]
//
// Przykład:
//   swift run PatchScanner ~/Documents/Patches
//   swift run PatchScanner ~/Documents/Patches --json > stats.json
//
// Historia: do 2026-08-28 scanner miał tymczasową flagę `--dump-type <typeID>`,
// która wypisywała z każdego patcha komplet parametrów i trybów wskazanego modułu.
// Zasilała empirię w `.codex/scripts/audit-param-ranges.py` przy audycie zakresów.
// Usunięta zgodnie z planem, gdy wszystkie 168 modułów zostało odhaczone ✅ —
// nie ma już czego porównywać. Gdyby wróciła potrzeba (Faza 2), zrobić z niej
// osobne podpolecenie, nie flagę „na chwilę".

import Foundation
import G2Core

// MARK: - Argument parsing

var args = CommandLine.arguments.dropFirst() // pomijamy nazwę programu

var searchPath: String = FileManager.default.currentDirectoryPath
var outputJSON = false
var topN: Int?
var verbose = false
var censusType: Int?
var exampleLimit = 10

var argIter = args.makeIterator()
while let arg = argIter.next() {
    switch arg {
    case "--json":
        outputJSON = true
    case "--verbose":
        verbose = true
    case "--top":
        if let n = argIter.next(), let i = Int(n) { topN = i }
    case "--census":
        if let n = argIter.next(), let i = Int(n) { censusType = i }
    case "--examples":
        if let n = argIter.next(), let i = Int(n) { exampleLimit = i }
    default:
        if !arg.hasPrefix("--") { searchPath = arg }
    }
}

// MARK: - Find patch files

let fm = FileManager.default
let rootURL = URL(fileURLWithPath: (searchPath as NSString).expandingTildeInPath)

guard fm.fileExists(atPath: rootURL.path) else {
    fputs("Error: path not found — \(rootURL.path)\n", stderr)
    exit(1)
}

var patchURLs: [URL] = []
if let enumerator = fm.enumerator(at: rootURL,
                                  includingPropertiesForKeys: [.isRegularFileKey],
                                  options: [.skipsHiddenFiles])
{
    for case let url as URL in enumerator {
        let ext = url.pathExtension.lowercased()
        if ext == "pch2" || ext == "prf2" { patchURLs.append(url) }
    }
}

guard !patchURLs.isEmpty else {
    fputs("No .pch2 / .prf2 files found in \(rootURL.path)\n", stderr)
    exit(1)
}

// Podpolecenie: pomiar jednego typu modułu zamiast statystyki całej kolekcji.
if let censusType {
    Census.run(typeID: censusType,
               files: patchURLs.sorted { $0.path < $1.path },
               exampleLimit: exampleLimit)
    exit(0)
}

// MARK: - Parse and count

struct ModuleStats {
    var count: Int = 0
    var inVoice: Int = 0
    var inFX: Int = 0
    var patches: Set<String> = [] // ile unikalnych patchy zawiera ten moduł
}

var moduleStats: [Int: ModuleStats] = [:] // typeID → stats
var categoryCount: [String: Int] = [:] // category → łączna liczba modułów
var parsedCount = 0
var errorCount = 0

let g2Header = Data("Version=Nord".utf8)

for url in patchURLs.sorted(by: { $0.path < $1.path }) {
    guard let data = try? Data(contentsOf: url) else {
        fputs("  skip (unreadable): \(url.lastPathComponent)\n", stderr)
        errorCount += 1
        continue
    }
    // Szybki pre-check: pomiń pliki które nie są formatem G2 (np. HTML, XML, katalogi)
    guard data.count > 16, data.prefix(g2Header.count).elementsEqual(g2Header) else {
        fputs("  skip (not G2 format): \(url.lastPathComponent)\n", stderr)
        errorCount += 1
        continue
    }
    let patches: [G2Patch]
    do {
        patches = try PatchParser.parse(data: data)
    } catch {
        let detail = verbose ? ": \(error)" : ""
        fputs("  skip (parse error): \(url.lastPathComponent)\(detail)\n", stderr)
        errorCount += 1
        continue
    }
    parsedCount += 1
    let patchName = url.deletingPathExtension().lastPathComponent

    for patch in patches {
        for m in patch.voiceModules {
            moduleStats[m.typeID, default: ModuleStats()].count += 1
            moduleStats[m.typeID, default: ModuleStats()].inVoice += 1
            moduleStats[m.typeID, default: ModuleStats()].patches.insert(patchName)
        }
        for m in patch.fxModules {
            moduleStats[m.typeID, default: ModuleStats()].count += 1
            moduleStats[m.typeID, default: ModuleStats()].inFX += 1
            moduleStats[m.typeID, default: ModuleStats()].patches.insert(patchName)
        }
    }
}

// MARK: - Enrich with ModuleDatabase

struct ModuleResult {
    let typeID: Int
    let shortName: String
    let longName: String
    let category: String
    let count: Int
    let inVoice: Int
    let inFX: Int
    let patchCount: Int
}

var results: [ModuleResult] = moduleStats.map { typeID, stats in
    let def = ModuleDatabase.module(id: typeID)
    return ModuleResult(
        typeID: typeID,
        shortName: def?.shortName ?? "typeID_\(typeID)",
        longName: def?.longName ?? "Unknown",
        category: def?.page ?? "Unknown",
        count: stats.count,
        inVoice: stats.inVoice,
        inFX: stats.inFX,
        patchCount: stats.patches.count
    )
}.sorted { $0.count > $1.count }

// Category totals (by unique-patch count, not raw placement count)
for r in results {
    categoryCount[r.category, default: 0] += r.count
}

let sortedCategories = categoryCount.sorted { $0.value > $1.value }

let displayResults = topN.map { Array(results.prefix($0)) } ?? results

// MARK: - Output

if outputJSON {
    struct JSONOutput: Encodable {
        struct ModuleEntry: Encodable {
            let rank: Int
            let typeID: Int
            let shortName: String
            let longName: String
            let category: String
            let totalPlacements: Int
            let inVoice: Int
            let inFX: Int
            let uniquePatches: Int
        }

        struct CategoryEntry: Encodable {
            let rank: Int
            let name: String
            let totalPlacements: Int
        }

        let scannedFiles: Int
        let parseErrors: Int
        let modules: [ModuleEntry]
        let categories: [CategoryEntry]
    }

    let out = JSONOutput(
        scannedFiles: parsedCount,
        parseErrors: errorCount,
        modules: displayResults.enumerated().map { idx, r in
            .init(rank: idx + 1, typeID: r.typeID, shortName: r.shortName,
                  longName: r.longName, category: r.category,
                  totalPlacements: r.count, inVoice: r.inVoice, inFX: r.inFX,
                  uniquePatches: r.patchCount)
        },
        categories: sortedCategories.enumerated().map { idx, kv in
            .init(rank: idx + 1, name: kv.key, totalPlacements: kv.value)
        }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(out) {
        print(String(decoding: data, as: UTF8.self))
    }

} else {
    // Human-readable output — używamy .padding() zamiast %s (bezpieczne ze Swift String)

    func pad(_ s: String, _ w: Int) -> String {
        String(s.prefix(w)).padding(toLength: w, withPad: " ", startingAt: 0)
    }
    func rpad(_ n: Int, _ w: Int) -> String {
        String(format: "%\(w)d", n)
    }

    let sep = String(repeating: "─", count: 72)

    print("\n\(sep)")
    print("  G2 Patch Scanner — Module Frequency Report")
    print("  Path:   \(rootURL.path)")
    print("  Parsed: \(parsedCount) files  ·  Errors: \(errorCount)")
    print(sep)

    let limitLabel = topN.map { "Top \($0)" } ?? "All"
    print("\n  \(limitLabel) modules by placement count:\n")

    let snW = 12
    let lnW = 26
    let catW = 10
    print("  \(pad("Rank", 4))  \(pad("Short", snW))  \(pad("Long name", lnW))  \(pad("Category", catW))  \(pad("Total", 6))  \(pad("Voice", 5))  \(pad("FX", 5))  \(pad("Patches", 7))")
    print("  " + String(repeating: "─", count: 72))

    for (idx, r) in displayResults.enumerated() {
        let line = "  \(rpad(idx + 1, 4))  \(pad(r.shortName, snW))  \(pad(r.longName, lnW))  \(pad(r.category, catW))  \(rpad(r.count, 6))  \(rpad(r.inVoice, 5))  \(rpad(r.inFX, 5))  \(rpad(r.patchCount, 7))"
        print(line)
    }

    print("\n\(sep)")
    print("\n  Categories by total placements:\n")
    print("  \(pad("Rank", 4))  \(pad("Category", 14))  Placements")
    print("  " + String(repeating: "─", count: 34))
    for (idx, kv) in sortedCategories.enumerated() {
        print("  \(rpad(idx + 1, 4))  \(pad(kv.key, 14))  \(kv.value)")
    }

    print("\n\(sep)\n")
}
