// ModuleSnapshotTool.swift
// Strażnik wyglądu modułów — regresja wizualna wszystkich 168 podglądów.
//
// Użycie:
//   swift run G2EditorApp --snapshot-modules      # zdjęcie odniesienia (przed zmianą)
//   swift run G2EditorApp --check-modules         # porównanie z odniesieniem (po zmianie)
//   swift run G2EditorApp --check-modules --snapshot-dir <katalog>
//
// Sens: 168 modułów rysują wspólne klocki (knoby, przyciski, selektory, ramki).
// Poprawka jednego klocka dotyka wszystkich modułów, które go używają — bez
// porównania nikt tego nie zauważy. Narzędzie NIE ocenia, czy moduł wygląda
// dobrze; mówi tylko, które moduły wyglądają INACZEJ niż przed zmianą.
//
// Dlaczego tryb aplikacji, a nie osobny executable: rysowanie to `PatchCanvasView`
// + `ModulePreviewCache.render`, oba w tym targecie, a SwiftPM nie pozwala
// importować targetu wykonywalnego z innego targetu.
//
// Odniesienie jest LOKALNE (katalog w .gitignore) i związane z tym Makiem —
// rozmiar bitmapy zależy od skali ekranu, więc baseline z jednego Maca nie
// pasuje do drugiego. To narzędzie „przed zmianą / po zmianie" w jednej sesji.

import AppKit
import CryptoKit
import Foundation
import G2Core
import SwiftUI

enum ModuleSnapshot {
    /// Podbij, gdy zmienia się układ katalogu odniesienia albo sposób liczenia skrótu.
    private static let formatVersion = 1
    private static let defaultDirName = ".module-snapshots"

    private enum Mode {
        case snapshot
        case check
    }

    // MARK: - Manifest

    private struct Entry: Codable {
        let id: Int
        let name: String
        let width: Int
        let height: Int
        let sha256: String
    }

    private struct Manifest: Codable {
        let formatVersion: Int
        let zoom: Double
        let createdAt: String
        let entries: [Entry]
    }

    // MARK: - Wejście z wiersza poleceń

    /// Zwraca kod wyjścia, gdy rozpoznał swój tryb; `nil` = zwykły start aplikacji.
    static func handleCommandLine(_ args: [String]) -> Int32? {
        var mode: Mode?
        var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(defaultDirName, isDirectory: true)

        var it = args.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--snapshot-modules": mode = .snapshot
            case "--check-modules": mode = .check
            case "--snapshot-dir":
                if let path = it.next() {
                    root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                }
            default: break
            }
        }

        guard let mode else { return nil }

        // Aplikacja bez ikony w Docku i bez okien — renderowanie i tak idzie
        // przez okno poza ekranem, ale AppKit musi mieć zainicjowany NSApp.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        AppFonts.register()
        app.finishLaunching()

        return MainActor.assumeIsolated {
            switch mode {
            case .snapshot: makeBaseline(root: root)
            case .check: compareWithBaseline(root: root)
            }
        }
    }

    // MARK: - Tryb: zdjęcie odniesienia

    @MainActor
    private static func makeBaseline(root: URL) -> Int32 {
        let shots = renderAll()
        guard reportFailures(shots.failed) else { return 2 }

        let fm = FileManager.default
        let dir = root.appendingPathComponent("baseline", isDirectory: true)
        try? fm.removeItem(at: dir)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else {
            print("❌ Nie mogę utworzyć katalogu \(dir.path)")
            return 2
        }

        var entries: [Entry] = []
        for def in ModuleDatabase.all {
            guard let rep = shots.reps[def.id] else { continue }
            guard let png = rep.representation(using: .png, properties: [:]),
                  (try? png.write(to: dir.appendingPathComponent("\(def.id).png"), options: .atomic)) != nil
            else {
                print("❌ Nie mogę zapisać podglądu modułu \(def.shortName) (#\(def.id))")
                return 2
            }
            entries.append(Entry(
                id: def.id, name: def.shortName,
                width: rep.pixelsWide, height: rep.pixelsHigh,
                sha256: digest(of: rep)
            ))
        }

        // Manifest na SAMYM KOŃCU — tak samo jak znacznik ważności w cache
        // podglądów: przerwany zapis zostawia odniesienie nieważne, a nie po
        // cichu wybrakowane.
        let manifest = Manifest(
            formatVersion: formatVersion,
            zoom: Double(ModulePreviewCache.previewZoom),
            createdAt: ISO8601DateFormatter().string(from: Date()),
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(manifest),
              (try? data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)) != nil
        else {
            print("❌ Nie mogę zapisać manifestu")
            return 2
        }

        print("✅ Odniesienie zapisane: \(entries.count) modułów → \(dir.path)")
        print("   Teraz zmieniaj kod rysujący, a potem: swift run G2EditorApp --check-modules")
        return 0
    }

    // MARK: - Tryb: porównanie

    @MainActor
    private static func compareWithBaseline(root: URL) -> Int32 {
        let dir = root.appendingPathComponent("baseline", isDirectory: true)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else {
            print("❌ Brak odniesienia w \(dir.path)")
            print("   Zrób je najpierw: swift run G2EditorApp --snapshot-modules")
            return 2
        }
        guard manifest.formatVersion == formatVersion,
              manifest.zoom == Double(ModulePreviewCache.previewZoom)
        else {
            print("❌ Odniesienie pochodzi z innej wersji narzędzia — zrób je od nowa")
            return 2
        }

        let shots = renderAll()
        guard reportFailures(shots.failed) else { return 2 }

        let baseline = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.id, $0) })
        let diffDir = root.appendingPathComponent("diff", isDirectory: true)
        try? FileManager.default.removeItem(at: diffDir)

        var changed: [(def: ModuleDef, pixels: Int, total: Int, note: String?)] = []
        var added: [ModuleDef] = []

        for def in ModuleDatabase.all {
            guard let rep = shots.reps[def.id] else { continue }
            guard let old = baseline[def.id] else {
                added.append(def)
                continue
            }
            guard old.sha256 != digest(of: rep) else { continue }

            let oldRep = loadCanonical(dir.appendingPathComponent("\(def.id).png"))
            let mask = oldRep.flatMap { changeMask(before: $0, after: rep) }
            let note = oldRep == nil
                ? "brak pliku odniesienia"
                : (mask == nil ? "zmienił się rozmiar: \(old.width)×\(old.height) → \(rep.pixelsWide)×\(rep.pixelsHigh)" : nil)
            changed.append((
                def, mask?.changed ?? 0, rep.pixelsWide * rep.pixelsHigh, note
            ))

            if let oldRep {
                writeDiffSheet(
                    def: def, before: oldRep, after: rep, mask: mask?.rep,
                    changed: mask?.changed ?? 0, into: diffDir
                )
            }
        }

        let removed = manifest.entries.filter { shots.reps[$0.id] == nil && ModuleDatabase.module(id: $0.id) == nil }
        return printReport(changed: changed, added: added, removed: removed, diffDir: diffDir)
    }

    private static func printReport(
        changed: [(def: ModuleDef, pixels: Int, total: Int, note: String?)],
        added: [ModuleDef],
        removed: [Entry],
        diffDir: URL
    ) -> Int32 {
        print("")
        if changed.isEmpty, added.isEmpty, removed.isEmpty {
            print("✅ Bez zmian — wszystkie \(ModuleDatabase.all.count) modułów wygląda tak samo jak w odniesieniu.")
            return 0
        }

        if !changed.isEmpty {
            print("⚠️  Zmieniony wygląd — \(changed.count) z \(ModuleDatabase.all.count) modułów:")
            for item in changed.sorted(by: { $0.pixels > $1.pixels }) {
                let pct = item.total > 0 ? Double(item.pixels) * 100 / Double(item.total) : 0
                let scale = String(format: "%.2f%%", pct)
                let detail = item.note.map { " — \($0)" } ?? " — \(item.pixels) px (\(scale))"
                print("   #\(item.def.id) \(item.def.shortName)\(detail)")
            }
            print("")
            print("   Obrazki „przed / po / co się zmieniło\": \(diffDir.path)")
        }
        for def in added {
            print("➕ Nowy moduł, nie ma go w odniesieniu: #\(def.id) \(def.shortName)")
        }
        for entry in removed {
            print("➖ Moduł zniknął z bazy: #\(entry.id) \(entry.name)")
        }
        print("")
        print("   Jeśli te zmiany są zamierzone: swift run G2EditorApp --snapshot-modules")
        return 1
    }

    // MARK: - Renderowanie

    @MainActor
    private static func renderAll() -> (reps: [Int: NSBitmapImageRep], failed: [ModuleDef]) {
        let all = ModuleDatabase.all
        print("Renderuję \(all.count) podglądów…")
        var reps: [Int: NSBitmapImageRep] = [:]
        var failed: [ModuleDef] = []
        for (index, def) in all.enumerated() {
            let image = ModulePreviewCache.render(typeID: def.id, zoom: ModulePreviewCache.previewZoom)
            // Awaryjna ścieżka rysowania w `render` ma inną geometrię — takiego
            // obrazu nie wolno porównywać, bo dałby fałszywą różnicę.
            let expected = ModulePreviewCache.previewPointSize(typeID: def.id, zoom: ModulePreviewCache.previewZoom)
            if image.size == expected, let rep = canonical(image) {
                reps[def.id] = rep
            } else {
                failed.append(def)
            }
            if (index + 1) % 40 == 0 { print("   \(index + 1)/\(all.count)") }
        }
        return (reps, failed)
    }

    /// Wypisuje moduły, których nie udało się wyrenderować. `false` = przerwij.
    private static func reportFailures(_ failed: [ModuleDef]) -> Bool {
        guard !failed.isEmpty else { return true }
        print("❌ Nie udało się wyrenderować \(failed.count) modułów (rysowanie awaryjne):")
        for def in failed.prefix(10) {
            print("   #\(def.id) \(def.shortName)")
        }
        print("   Porównanie byłoby niewiarygodne — przerywam.")
        return false
    }

    // MARK: - Piksele

    /// Przerysowuje obraz do bitmapy o znanym, ciasno upakowanym układzie RGBA.
    /// Bez tego bajty zależą od wyrównania wierszy i metadanych kodera PNG,
    /// więc identyczne obrazy potrafiłyby dać różne skróty.
    @MainActor
    private static func canonical(_ image: NSImage) -> NSBitmapImageRep? {
        guard let source = image.representations.first else { return nil }
        return canonical(source)
    }

    @MainActor
    private static func canonical(_ source: NSImageRep) -> NSBitmapImageRep? {
        let width = source.pixelsWide
        let height = source.pixelsHigh
        guard width > 0, height > 0 else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        ) else { return nil }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @MainActor
    private static func loadCanonical(_ url: URL) -> NSBitmapImageRep? {
        guard let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data) else { return nil }
        return canonical(rep)
    }

    private static func pixels(_ rep: NSBitmapImageRep) -> Data? {
        guard let bytes = rep.bitmapData else { return nil }
        return Data(bytes: bytes, count: rep.pixelsWide * rep.pixelsHigh * 4)
    }

    private static func digest(of rep: NSBitmapImageRep) -> String {
        guard let data = pixels(rep) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Maska zmian: czerwony piksel tam, gdzie obrazy się różnią, przygaszony
    /// obraz „po" w tle. `nil` = różne rozmiary, nie ma czego nakładać.
    @MainActor
    private static func changeMask(
        before: NSBitmapImageRep, after: NSBitmapImageRep
    ) -> (rep: NSBitmapImageRep, changed: Int)? {
        let width = after.pixelsWide
        let height = after.pixelsHigh
        guard before.pixelsWide == width, before.pixelsHigh == height,
              let oldPixels = before.bitmapData, let newPixels = after.bitmapData,
              let mask = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
              ), let out = mask.bitmapData
        else { return nil }
        mask.size = NSSize(width: width, height: height)

        var changed = 0
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let differs = oldPixels[index] != newPixels[index]
                || oldPixels[index + 1] != newPixels[index + 1]
                || oldPixels[index + 2] != newPixels[index + 2]
                || oldPixels[index + 3] != newPixels[index + 3]
            if differs {
                changed += 1
                out[index] = 255
                out[index + 1] = 60
                out[index + 2] = 60
                out[index + 3] = 255
            } else {
                // Przygaszony obraz „po" — widać, w którym miejscu modułu jesteśmy.
                let luma = (Int(newPixels[index]) + Int(newPixels[index + 1]) + Int(newPixels[index + 2])) / 3
                let dim = UInt8(luma / 4)
                out[index] = dim
                out[index + 1] = dim
                out[index + 2] = dim
                out[index + 3] = 255
            }
        }
        return (mask, changed)
    }

    // MARK: - Obrazek „przed / po / co się zmieniło"

    @MainActor
    private static func writeDiffSheet(
        def: ModuleDef, before: NSBitmapImageRep, after: NSBitmapImageRep,
        mask: NSBitmapImageRep?, changed: Int, into dir: URL
    ) {
        let panels: [(String, NSBitmapImageRep)] = [
            ("BEFORE", before), ("AFTER", after),
        ] + (mask.map { [("CHANGES", $0)] } ?? [])

        let margin: CGFloat = 12
        let gap: CGFloat = 12
        let captionH: CGFloat = 20
        let labelH: CGFloat = 16
        let panelH = panels.map { CGFloat($0.1.pixelsHigh) }.max() ?? 0
        let width = margin * 2 + panels.reduce(0) { $0 + CGFloat($1.1.pixelsWide) }
            + gap * CGFloat(max(panels.count - 1, 0))
        let height = margin * 2 + captionH + panelH + labelH

        guard let sheet = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: Int(width) * 4, bitsPerPixel: 32
        ) else { return }
        sheet.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)

        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        // Kontekst bitmapy nie jest odwrócony — liczymy y od dołu.
        var x = margin
        for (label, rep) in panels {
            let panelW = CGFloat(rep.pixelsWide)
            rep.draw(in: NSRect(x: x, y: margin + labelH, width: panelW, height: CGFloat(rep.pixelsHigh)))
            draw(label, at: NSPoint(x: x, y: margin), size: 10, color: NSColor(calibratedWhite: 0.55, alpha: 1))
            x += panelW + gap
        }

        let pct = String(format: "%.2f%%", Double(changed) * 100 / Double(max(after.pixelsWide * after.pixelsHigh, 1)))
        let caption = mask == nil
            ? "#\(def.id) \(def.shortName) — rozmiar podglądu się zmienił"
            : "#\(def.id) \(def.shortName) — \(changed) px (\(pct))"
        draw(caption, at: NSPoint(x: margin, y: margin + labelH + panelH + 4), size: 12, color: .white)

        NSGraphicsContext.restoreGraphicsState()

        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = def.shortName.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "_")
        if let png = sheet.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(def.id)-\(safeName).png"), options: .atomic)
        }
    }

    @MainActor
    private static func draw(_ text: String, at point: NSPoint, size: CGFloat, color: NSColor) {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
        ]).draw(at: point)
    }
}
