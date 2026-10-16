// PatchCheck — kontrola strukturalna kolekcji patchy. TYLKO RAPORT: nie zapisuje
// ani nie zmienia żadnego pliku.
//
// Użycie:
//   swift run PatchCheck <plik.pch2 | katalog>
//   swift run PatchCheck <katalog> --examples 20
//   swift run PatchCheck <katalog> --all          # wypisz każde znalezisko
//   swift run PatchCheck <katalog> --roundtrip    # czy zapis oddaje plik bajt w bajt
//
// Sens: zanim cokolwiek zaczniemy naprawiać automatycznie, chcemy wiedzieć, ile
// i jakich uszkodzeń faktycznie występuje w prawdziwych plikach. Kolekcja
// referencyjna (kilka tysięcy patchy) jest do tego materiałem dowodowym.

import Foundation
import G2Core

// MARK: - Argumenty

var searchPath = FileManager.default.currentDirectoryPath
var exampleLimit = 10
var showAll = false
var checkRoundTrip = false

var argIter = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIter.next() {
    switch arg {
    case "--all":
        showAll = true
    case "--roundtrip":
        checkRoundTrip = true
    case "--examples":
        if let n = argIter.next(), let i = Int(n) { exampleLimit = i }
    default:
        if !arg.hasPrefix("--") { searchPath = arg }
    }
}

// MARK: - Lista plików

let fm = FileManager.default
let rootURL = URL(fileURLWithPath: (searchPath as NSString).expandingTildeInPath)

var isDirectory: ObjCBool = false
guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
    fputs("Error: path not found — \(rootURL.path)\n", stderr)
    exit(1)
}

func isPatchFile(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return ext == "pch2" || ext == "prf2"
}

var patchURLs: [URL] = []
if isDirectory.boolValue {
    if let enumerator = fm.enumerator(at: rootURL,
                                      includingPropertiesForKeys: [.isRegularFileKey],
                                      options: [.skipsHiddenFiles])
    {
        for case let url as URL in enumerator where isPatchFile(url) {
            patchURLs.append(url)
        }
    }
    patchURLs.sort { $0.path < $1.path }
} else {
    patchURLs = [rootURL]
}

guard !patchURLs.isEmpty else {
    fputs("No .pch2 / .prf2 files found in \(rootURL.path)\n", stderr)
    exit(1)
}

/// Opisuje bajt pliku jako „sekcja 0xNN, bajt K ciała" — bez tego pierwsza różnica
/// w round-tripie jest samą liczbą i nie mówi, która sekcja się rozjechała.
func describeOffset(_ offset: Int, in data: Data) -> String {
    let bytes = [UInt8](data)
    guard let headerEnd = bytes.firstIndex(of: 0) else { return "bajt @\(offset)" }
    var position = headerEnd + 1 + 2 // \0 + 2 bajty wersji
    while position + 3 <= bytes.count {
        let type = bytes[position]
        let length = Int(bytes[position + 1]) << 8 | Int(bytes[position + 2])
        if offset < position + 3 + length {
            return String(format: "sekcja 0x%02x", type) + ", bajt \(offset - position - 3) ciała"
        }
        position += 3 + length
    }
    return "bajt @\(offset) (poza sekcjami — nagłówek albo CRC)"
}

// MARK: - Sprawdzanie

struct KindStats {
    var count = 0
    var files: Set<String> = []
    var severity: PatchIssueSeverity = .warning
    var examples: [String] = []
}

var stats: [PatchIssueKind: KindStats] = [:]
var scanned = 0
var parseErrors = 0
var notG2 = 0
var filesWithErrors = 0
var filesWithWarningsOnly = 0
var cleanFiles = 0
var roundTripChecked = 0
var roundTripIdentical = 0
var roundTripDiffs: [String] = []

let g2Header = Data("Version=Nord".utf8)

for url in patchURLs {
    guard let data = try? Data(contentsOf: url) else {
        fputs("  skip (unreadable): \(url.lastPathComponent)\n", stderr)
        parseErrors += 1
        continue
    }
    guard data.count > 16, data.prefix(g2Header.count).elementsEqual(g2Header) else {
        notG2 += 1
        continue
    }
    let patches: [G2Patch]
    let performance: G2PerformanceSettings?
    do {
        let parsed = try PatchParser.parseFile(data: data)
        patches = parsed.patches
        performance = parsed.performance
    } catch {
        fputs("  parse error: \(url.lastPathComponent): \(error)\n", stderr)
        parseErrors += 1
        continue
    }
    scanned += 1

    // Kontrola zapisu: wczytać i zapisać bez zmian musi dać ten sam plik co do bajtu.
    // Wykryłaby każdą pomyłkę pokroju #58/#59 — sekcję gubioną albo wpisaną nie tam.
    if checkRoundTrip {
        roundTripChecked += 1
        if let saved = try? PatchParser.saveAll(originalData: data,
                                                patches: patches,
                                                performance: performance)
        {
            if saved == data {
                roundTripIdentical += 1
            } else if let offset = zip(saved, data).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
                roundTripDiffs.append("\(url.lastPathComponent): \(describeOffset(offset, in: data)), "
                    + String(format: "0x%02x → 0x%02x", data[offset], saved[offset]))
            } else {
                roundTripDiffs.append("\(url.lastPathComponent): inna długość (\(data.count) B → \(saved.count) B)")
            }
        } else {
            roundTripDiffs.append("\(url.lastPathComponent): zapis rzucił błędem")
        }
    }

    var fileIssues: [PatchIssue] = []
    for (slot, patch) in patches.enumerated() {
        let label = patches.count > 1 ? "\(url.lastPathComponent) slot \(slot)" : url.lastPathComponent
        for issue in PatchValidator.issues(in: patch) {
            fileIssues.append(issue)
            var entry = stats[issue.kind] ?? KindStats()
            entry.count += 1
            entry.severity = issue.severity
            entry.files.insert(url.path)
            if showAll || entry.examples.count < exampleLimit {
                entry.examples.append("\(label) [\(issue.area)]: \(issue.message)")
            }
            stats[issue.kind] = entry
        }
    }

    if fileIssues.contains(where: { $0.severity == .error }) {
        filesWithErrors += 1
    } else if fileIssues.isEmpty {
        cleanFiles += 1
    } else {
        filesWithWarningsOnly += 1
    }
}

// MARK: - Raport

func pad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s.padding(toLength: w, withPad: " ", startingAt: 0)
}

func rpad(_ n: Int, _ w: Int) -> String {
    String(format: "%\(w)d", n)
}

let sep = String(repeating: "─", count: 78)

print("\n\(sep)")
print("  G2 Patch Check — structural report (read-only, nothing is modified)")
print("  Path:     \(rootURL.path)")
print("  Files:    \(scanned) checked  ·  \(parseErrors) parse errors  ·  \(notG2) skipped (not G2)")
print("  Verdict:  \(cleanFiles) clean  ·  \(filesWithErrors) with errors  ·  \(filesWithWarningsOnly) with warnings only")
if checkRoundTrip {
    print("  Roundtrip: \(roundTripIdentical)/\(roundTripChecked) plików zapisuje się bajt w bajt")
}

print(sep)

if !roundTripDiffs.isEmpty {
    print("\n  Pliki, których zapis zmienia bajty:\n")
    for line in showAll ? roundTripDiffs : Array(roundTripDiffs.prefix(exampleLimit)) {
        print("    \(line)")
    }
    if !showAll, roundTripDiffs.count > exampleLimit {
        print("    … i \(roundTripDiffs.count - exampleLimit) więcej (użyj --all)")
    }
}

if stats.isEmpty {
    print("\n  No issues found.\n")
    exit(0)
}

print("\n  Findings by kind:\n")
print("  \(pad("Severity", 9))  \(pad("Kind", 32))  \(pad("Count", 7))  Files")
print("  " + String(repeating: "─", count: 62))

let ordered = stats.sorted { lhs, rhs in
    if lhs.value.severity != rhs.value.severity { return lhs.value.severity == .error }
    return lhs.value.count > rhs.value.count
}

for (kind, entry) in ordered {
    print("  \(pad(entry.severity.rawValue, 9))  \(pad(kind.rawValue, 32))  \(rpad(entry.count, 7))  \(entry.files.count)")
}

print("\n\(sep)")
let exampleHeader = showAll ? "All findings" : "Examples (up to \(exampleLimit) per kind)"
print("\n  \(exampleHeader):")
for (kind, entry) in ordered {
    print("\n  [\(kind.rawValue)]")
    for example in entry.examples {
        print("    \(example)")
    }
    if !showAll, entry.count > entry.examples.count {
        print("    … and \(entry.count - entry.examples.count) more (use --all)")
    }
}

print("\n\(sep)\n")
