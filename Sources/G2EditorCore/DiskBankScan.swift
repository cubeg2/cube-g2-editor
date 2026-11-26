// DiskBankScan.swift
// Szybki skan dużej biblioteki patchy (dziesiątki tysięcy plików) dla `DiskBankLibrary`:
// pamięć poprzedniego skanu na dysku i czytanie tagów oraz kategorii z pliku.
//
// Zmierzone 2026-11-25 na bibliotece Kuby (109 601 plików, Mac Studio): skan trwał ~22 s,
// bo tagi (2 × `getxattr` po ścieżce) i 4 KB nagłówka czytało NARAZ kilkanaście wątków
// (`concurrentPerform` po jednym pliku) — system plików blokował je nawzajem. Te same
// odczyty na czterech wątkach i przez JEDNO otwarcie pliku (`fgetxattr` + `pread`)
// trwają ~2,5 s. A pliku, który od poprzedniego skanu się nie zmienił (ta sama data
// zmiany treści, atrybutów i rozmiar), nie trzeba otwierać wcale — lista z pamięci
// pokazuje się od razu po starcie, a skan w tle tylko ją sprawdza → [[Docs/ui/side-panels]].

import Foundation
import G2Core

/// Lista plików z poprzedniego skanu, zapisana w `Caches` — jeden plik tekstowy na folder.
/// Wiersz: ścieżka względna, rodzaj, kategoria, daty (bity `Double`), rozmiar, tagi.
/// Plik, który się w tym nie zmieści (tabulator w nazwie), nie trafia do pamięci — skan
/// przeczyta go jak nowy.
public enum DiskBankScanCache {
    /// Gdzie aplikacja trzyma pamięć skanów (`~/Library/Caches/G2Editor/DiskLibrary`).
    public static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("G2Editor/DiskLibrary", isDirectory: true)
    }

    private static let header = "G2DiskLibrary 1"

    static func fileURL(for folder: URL, in directory: URL) -> URL {
        // FNV-1a ze ścieżki: stała między uruchomieniami (w przeciwieństwie do `hashValue`).
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in folder.standardizedFileURL.path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return directory.appendingPathComponent(String(hash, radix: 16) + ".tsv")
    }

    /// Pozycje w kolejności z zapisu; `nil` — brak pamięci albo plik nie do odczytania.
    static func load(folder: URL, directory: URL) -> [DiskBankItem]? {
        guard let data = try? Data(contentsOf: fileURL(for: folder, in: directory)),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        var lines = text.components(separatedBy: "\n")
        // Nagłówek: znacznik, wskazany folder i początek ścieżek tak, jak podaje je skan
        // (system rozwija dowiązania: `/var/…` przychodzi jako `/private/var/…`).
        let head = lines.first?.components(separatedBy: "\t") ?? []
        guard head.count == 3, head[0] == header, head[1] == folder.standardizedFileURL.path else { return nil }
        let base = head[2]
        lines.removeFirst()
        var items: [DiskBankItem] = []
        items.reserveCapacity(lines.count)
        for line in lines where !line.isEmpty {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 7,
                  let category = Int(fields[2]),
                  let modified = UInt64(fields[3], radix: 16),
                  let size = Int(fields[5])
            else { continue }
            let relative = String(fields[0])
            let url = URL(fileURLWithPath: base + "/" + relative, isDirectory: false)
            let parent = (relative as NSString).deletingLastPathComponent
            items.append(DiskBankItem(
                url: url,
                name: ((relative as NSString).lastPathComponent as NSString).deletingPathExtension,
                isPerformance: fields[1] == "1",
                modified: Date(timeIntervalSinceReferenceDate: Double(bitPattern: modified)),
                size: size,
                relativeFolder: parent,
                tags: tags(from: fields[6]),
                category: category,
                attributesChanged: UInt64(fields[4], radix: 16)
                    .map { Date(timeIntervalSinceReferenceDate: Double(bitPattern: $0)) }
            ))
        }
        return items
    }

    static func save(_ items: [DiskBankItem], folder: URL, directory: URL) {
        guard let first = items.first else { return }
        let firstRelative = relativePath(of: first)
        let base = String(first.url.path.dropLast(firstRelative.count + 1))
        var text = header + "\t" + folder.standardizedFileURL.path + "\t" + base + "\n"
        text.reserveCapacity(items.count * 96)
        for item in items {
            let relative = relativePath(of: item)
            guard item.url.path == base + "/" + relative else { continue }
            let tags = item.tags.map { $0.name + "\u{1F}" + String($0.color) }.joined(separator: "\u{1E}")
            // Nazwa z tabulatorem albo końcem wiersza rozbiłaby zapis — taki plik po prostu
            // nie trafia do pamięci (skan przeczyta go jak nowy).
            guard !(relative + tags).contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" }) else { continue }
            let changed = item.attributesChanged.map {
                String($0.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
            } ?? "-"
            text += relative + "\t" + (item.isPerformance ? "1" : "0") + "\t" + String(item.category) + "\t"
                + String(item.modified.timeIntervalSinceReferenceDate.bitPattern, radix: 16) + "\t"
                + changed + "\t" + String(item.size) + "\t" + tags + "\n"
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: fileURL(for: folder, in: directory), options: .atomic)
    }

    private static func relativePath(of item: DiskBankItem) -> String {
        item.relativeFolder.isEmpty
            ? item.url.lastPathComponent : item.relativeFolder + "/" + item.url.lastPathComponent
    }

    private static func tags(from field: Substring) -> [FinderTag] {
        guard !field.isEmpty else { return [] }
        return field.split(separator: "\u{1E}").map { entry in
            let parts = entry.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            return FinderTag(name: String(parts[0]), color: parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        }
    }
}

/// Tagi i kategoria jednego pliku przez JEDNO otwarcie: `fgetxattr` zamiast dwóch
/// `getxattr` po ścieżce i `pread` zamiast `FileHandle`.
enum DiskBankFileReader {
    struct Contents {
        var tags: [FinderTag]
        var category: Int
    }

    /// `readCategory` = plik `.pch2` leżący na dysku (nie w samej chmurze).
    static func read(_ url: URL, readCategory: Bool) -> Contents {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return Contents(tags: [], category: 0) }
        defer { close(fd) }
        let tags = DiskBankLibrary.finderTags(
            userTags: attribute("com.apple.metadata:_kMDItemUserTags", fd: fd),
            finderInfo: attribute("com.apple.FinderInfo", fd: fd)
        )
        guard readCategory else { return Contents(tags: tags, category: 0) }
        var head = Data(count: 4096)
        let count = head.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 4096, 0) }
        guard count > 0 else { return Contents(tags: tags, category: 0) }
        head.count = count
        return Contents(tags: tags, category: PatchParser.category(ofPatchFileHead: head) ?? 0)
    }

    private static func attribute(_ name: String, fd: Int32) -> Data? {
        let length = fgetxattr(fd, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, length, 0, 0) }
        return read == length ? data : nil
    }
}
