// Census — pomiar JEDNEGO typu modułu na całej kolekcji plików.
//
// Po co osobne podpolecenie: `PatchCheck` zgłasza pojedyncze niespójności
// („moduł 7 ma 5 wartości parametrów, oczekiwano 4"), ale nie mówi, czy to
// reguła, czy wyjątek. Census liczy rozkłady na wszystkich plikach: ile modułów
// danego typu w ogóle jest w kolekcji, ile z nich ma jaką liczbę parametrów
// i trybów, których konektorów dotykają kable i jakie etykiety noszą. Dopiero
// to rozstrzyga, czy błąd siedzi w pliku, czy w naszej bazie modułów.
//
// Liczba parametrów i liczba trybów są w pliku ZAPISANE JAWNIE (`nParams` 7 bit
// w sekcji 0x4d, `nModes` 4 bity w sekcji 0x4a), więc census mierzy to, co
// naprawdę stoi w bajtach, a nie to, co dopisała nasza baza.
//
// Census rozbija każdy rozkład dodatkowo po WERSJI FORMATU I BUILDZIE edytora,
// które stoją w tekstowym nagłówku pliku (`Version=19`, `Info=BUILD 146`).
// Bez tego nie da się odróżnić uszkodzonego pliku od pliku zapisanego przez
// starszą wersję OS-u G2, w której moduł miał inną definicję.
//
// Użycie:
//   swift run PatchScanner <katalog> --census <typeID> [--examples N]

import Foundation
import G2Core

enum Census {
    private struct Variant: Hashable {
        let params: Int
        let modes: Int
    }

    /// Wersja formatu i build edytora z nagłówka tekstowego, np. „v19/b146".
    /// Nagłówek to zwykły ASCII przed strumieniem binarnym.
    private static func headerTag(_ data: Data) -> String {
        let head = String(decoding: data.prefix(160), as: UTF8.self)
        var version = "?"
        var build = "?"
        for line in head.components(separatedBy: "\r\n") {
            if line.hasPrefix("Version="), let n = Int(line.dropFirst("Version=".count)) {
                version = String(n)
            } else if line.hasPrefix("Info=BUILD "), let n = Int(line.dropFirst("Info=BUILD ".count)) {
                build = String(n)
            }
        }
        return "v\(version)/b\(build)"
    }

    static func run(typeID: Int, files: [URL], exampleLimit: Int) {
        var totalModules = 0
        var filesWithType: Set<String> = []
        var variantCount: [Variant: Int] = [:]
        var variantFiles: [Variant: [String]] = [:]
        var areaCount: [PatchArea: Int] = [:]
        var inputUse: [String: [Int: Int]] = [:]
        var outputUse: [String: [Int: Int]] = [:]
        var labels: [String: Int] = [:]
        var variantBuilds: [Variant: [String: Int]] = [:]
        var buildsAllFiles: [String: Int] = [:]
        var buildsWithType: [String: Int] = [:]
        var occurrences: [String] = [] // pojedyncze wystąpienia — tylko dla typów rzadkich
        var parsed = 0
        var skipped = 0

        let g2Header = Data("Version=Nord".utf8)

        for url in files {
            guard let data = try? Data(contentsOf: url),
                  data.count > 16, data.prefix(g2Header.count).elementsEqual(g2Header),
                  let patches = try? PatchParser.parse(data: data)
            else {
                skipped += 1
                continue
            }
            parsed += 1
            let shortPath = url.lastPathComponent
            let build = headerTag(data)
            buildsAllFiles[build, default: 0] += 1
            var fileHasType = false

            for patch in patches {
                for area in PatchArea.allCases {
                    let modules = patch.modules(in: area).filter { $0.typeID == typeID }
                    guard !modules.isEmpty else { continue }
                    let ids = Set(modules.map(\.id))

                    for module in modules {
                        totalModules += 1
                        filesWithType.insert(shortPath)
                        areaCount[area, default: 0] += 1
                        let variant = Variant(params: module.parameters.count,
                                              modes: module.modes.count)
                        variantCount[variant, default: 0] += 1
                        variantBuilds[variant, default: [:]][build, default: 0] += 1
                        fileHasType = true
                        if variantFiles[variant, default: []].count < exampleLimit,
                           !variantFiles[variant, default: []].contains(shortPath)
                        {
                            variantFiles[variant, default: []].append(shortPath)
                        }
                        if !module.label.isEmpty {
                            labels[module.label, default: 0] += 1
                        }
                        occurrences.append("\(shortPath) [\(area)] id \(module.id) "
                            + "col \(module.column) row \(module.row) color \(module.color) "
                            + "label \"\(module.label)\" params \(module.parameters)")
                    }

                    // Konektory: koniec docelowy kabla jest zawsze wejściem,
                    // o źródłowym decyduje `sourceIsOutput` (bit linkType).
                    for cable in patch.cables(in: area) {
                        if ids.contains(cable.fromModule) {
                            if cable.sourceIsOutput {
                                outputUse[build, default: [:]][cable.fromConnector, default: 0] += 1
                            } else {
                                inputUse[build, default: [:]][cable.fromConnector, default: 0] += 1
                            }
                        }
                        if ids.contains(cable.toModule) {
                            inputUse[build, default: [:]][cable.toConnector, default: 0] += 1
                        }
                    }
                }
            }
            if fileHasType { buildsWithType[build, default: 0] += 1 }
        }

        // MARK: - Raport

        let def = ModuleDatabase.module(id: typeID)
        let sep = String(repeating: "─", count: 72)
        print("\n\(sep)")
        if let def {
            print("Census — type \(typeID): \(def.shortName) (\(def.longName))")
            print("Database says: \(def.paramNames.count) parameters, \(def.modeNames.count) modes, "
                + "\(def.inputs.count) inputs, \(def.outputs.count) outputs")
        } else {
            print("Census — type \(typeID): NOT IN MODULE DATABASE")
        }
        print(sep)
        print("Files scanned: \(parsed)   skipped: \(skipped)")
        print("Modules found: \(totalModules) in \(filesWithType.count) files "
            + "(voice \(areaCount[.voice] ?? 0), fx \(areaCount[.fx] ?? 0))")

        guard totalModules > 0 else {
            print("\nNothing to measure — this type does not occur in the collection.\n")
            return
        }

        print("\nParameter / mode counts as written in the files:")
        for (variant, count) in variantCount.sorted(by: { $0.value > $1.value }) {
            let share = Double(count) * 100.0 / Double(totalModules)
            print(String(format: "  %3d params, %d modes — %5d modules (%5.1f%%)",
                         variant.params, variant.modes, count, share))
            let builds = (variantBuilds[variant] ?? [:]).sorted { $0.value > $1.value }
                .map { "\($0.key)×\($0.value)" }.joined(separator: "  ")
            print("      builds: \(builds)")
            for file in variantFiles[variant] ?? [] {
                print("      \(file)")
            }
        }

        if !inputUse.isEmpty || !outputUse.isEmpty {
            // Rozbicie po buildzie, bo konektor „poza zakresem" w starym pliku
            // znaczy co innego (inna definicja modułu) niż w nowym (uszkodzenie).
            print("\nConnectors touched by cables, per file build:")
            func list(_ use: [Int: Int]) -> String {
                use.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
            }
            func total(_ build: String) -> Int {
                let ins: Int = (inputUse[build] ?? [:]).values.reduce(0, +)
                let outs: Int = (outputUse[build] ?? [:]).values.reduce(0, +)
                return ins + outs
            }
            let builds = Set(inputUse.keys).union(outputUse.keys).sorted { total($0) > total($1) }
            for build in builds {
                print("  \(build.padding(toLength: 11, withPad: " ", startingAt: 0))"
                    + "in: \(list(inputUse[build] ?? [:]))   out: \(list(outputUse[build] ?? [:]))")
            }
        }

        // Przy typie rzadkim wypisujemy każde wystąpienie — przy 12 modułach
        // interesuje nas, czy to dwanaście niezależnych przypadków, czy jedna
        // kopiowana wielokrotnie łatka.
        if occurrences.count <= 20 {
            print("\nEvery occurrence:")
            for line in occurrences {
                print("  \(line)")
            }
        }

        print("\nFile header versions (files with this type / all scanned files):")
        for (build, count) in buildsAllFiles.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  %-14@ %5d / %5d", build as NSString,
                         buildsWithType[build] ?? 0, count))
        }

        if !labels.isEmpty {
            print("\nUser labels (top \(exampleLimit)):")
            for (label, count) in labels.sorted(by: { $0.value > $1.value }).prefix(exampleLimit) {
                print("  \(count)× \"\(label)\"")
            }
        }
        print("")
    }
}
