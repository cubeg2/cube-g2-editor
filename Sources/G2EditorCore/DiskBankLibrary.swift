// DiskBankLibrary.swift
// Banki na dysku: folder z plikami `.pch2`/`.prf2` pokazany jako lista, po której da się
// szukać. To druga połowa panelu Banks — działa BEZ podłączonego Norda i jest jedyną,
// która działa, gdy sprzętu nie ma pod ręką.
//
// Świadomie proste: żadnej bazy, żadnego indeksu na dysku. Nazwa, rozmiar, data, ścieżka
// i tagi Findera wystarczą, żeby plik znaleźć, posortować i otworzyć. Z zawartości czytamy
// tylko kategorię patcha — z pierwszych bajtów pliku (od 2026-09-25, sortowanie i filtr
// „Category"). Liczbę modułów i obciążenie DSP liczymy dla JEDNEGO pliku, dopiero gdy
// kursor stanie nad wierszem (`summary(of:)`) — dla całego folderu byłoby to parsowanie
// dziesiątek tysięcy plików. Wyszukiwanie po zawartości to osobne zadanie z planu.

import Foundation
import G2Core
import Observation

/// Tag nadany plikowi w Finderze. Finder trzyma tagi w atrybucie rozszerzonym
/// `com.apple.metadata:_kMDItemUserTags` jako listę napisów `Nazwa\nKolor` — nazwa jest
/// w języku systemu („Czerwony", „Red"), więc do kropki liczy się wyłącznie numer koloru.
public struct FinderTag: Sendable, Equatable, Hashable {
    public let name: String
    /// Numeracja Findera: 0 bez koloru, 1 szary, 2 zielony, 3 fioletowy, 4 niebieski,
    /// 5 żółty, 6 czerwony, 7 pomarańczowy. Ta sama kolejność co w
    /// `NSWorkspace.fileLabelColors`.
    public let color: Int

    public init(name: String, color: Int) {
        self.name = name
        self.color = color
    }

    /// Pozycja w tęczy z menu Findera (czerwony → szary), bez koloru na końcu — po tym
    /// sortuje „by tags", bo alfabet nazw dałby kolejność zależną od języka systemu.
    public var rainbowRank: Int {
        switch color {
        case 6: 0
        case 7: 1
        case 5: 2
        case 2: 3
        case 4: 4
        case 3: 5
        case 1: 6
        default: 7
        }
    }
}

/// Jeden plik patcha albo performance'u znaleziony w folderze.
public struct DiskBankItem: Sendable, Equatable, Identifiable {
    public let url: URL
    public let name: String
    public let isPerformance: Bool
    public let modified: Date
    /// W bajtach; 0 gdy system nie podał (np. plik z iCloud, którego nie ma na dysku).
    public let size: Int
    /// Ścieżka względem folderu głównego — bez niej dwa pliki o tej samej nazwie
    /// w różnych podfolderach wyglądają identycznie.
    public let relativeFolder: String
    /// Tagi z Findera, w kolejności, w jakiej nadał je użytkownik.
    public let tags: [FinderTag]
    /// Kategoria patcha z pliku (`G2PatchCategory`); 0 = brak albo nieznana
    /// (performance, plik z iCloud, którego nie ma na dysku).
    public let category: Int

    public var id: String {
        url.path
    }

    public init(
        url: URL, name: String, isPerformance: Bool, modified: Date, size: Int = 0,
        relativeFolder: String, tags: [FinderTag] = [], category: Int = 0
    ) {
        self.category = category
        self.url = url
        self.name = name
        self.isPerformance = isPerformance
        self.modified = modified
        self.size = size
        self.relativeFolder = relativeFolder
        self.tags = tags
    }
}

/// Zawartość pliku w liczbach — to, co pokazuje dymek nad wierszem przeglądarki.
public struct DiskFileSummary: Sendable, Equatable {
    /// Jeden patch: cały `.pch2` albo jeden zajęty slot `.prf2`.
    public struct Slot: Sendable, Equatable {
        /// „A"…„D" w performance, `nil` w zwykłym patchu.
        public let label: String?
        public let name: String?
        public let modules: Int
        /// Obciążenie obszarów w procentach — wyższe z mocy i pamięci DSP, jak w panelu DSP.
        public let voiceLoad: Double
        public let fxLoad: Double

        public var line: String {
            let load = "\(modules) modules · DSP Voice \(Int(voiceLoad.rounded()))% · FX \(Int(fxLoad.rounded()))%"
            guard let label else { return load }
            let title = (name ?? "").isEmpty ? "Slot \(label)" : "Slot \(label) \u{201C}\(name ?? "")\u{201D}"
            return title + ": " + load
        }
    }

    public let slots: [Slot]

    public init(slots: [Slot]) {
        self.slots = slots
    }

    public var lines: [String] {
        slots.map(\.line)
    }
}

/// Kolejność listy plików — domyślnie jak w Finderze: nazwa rosnąco, data i rozmiar od
/// największych, tagi w kolejności tęczy z menu Findera, pliki bez tagu na końcu. Każdą da się
/// odwrócić (`DiskBankLibrary.sortReversed`). Foldery zawsze po nazwie.
public enum DiskBankSort: String, CaseIterable, Sendable {
    case name
    case date
    case size
    case tags
    /// Najpierw patche, potem performance (`.pch2` / `.prf2`).
    case kind
    /// Kategoria zapisana w patchu, alfabetycznie; bez kategorii na końcu.
    case category

    public var title: String {
        switch self {
        case .name: "Name"
        case .date: "Date Modified"
        case .size: "Size"
        case .tags: "Tags"
        case .kind: "Kind"
        case .category: "Category"
        }
    }

    /// Opis kierunku w menu: najpierw domyślny, potem odwrócony. Słowami zależnymi od
    /// klucza, bo „Ascending" przy dacie nie mówi, czy najnowsze są na górze.
    public var directionTitles: (natural: String, reversed: String) {
        switch self {
        case .name: ("A to Z", "Z to A")
        case .date: ("Newest First", "Oldest First")
        case .size: ("Largest First", "Smallest First")
        case .tags: ("Red First", "Gray First")
        case .kind: ("Patches First", "Performances First")
        case .category: ("A to Z", "Z to A")
        }
    }
}

@MainActor
@Observable
public final class DiskBankLibrary {
    /// Folder wskazany przez użytkownika. Zapamiętany między uruchomieniami — biblioteka
    /// patchy z 2006 roku leży zwykle w jednym miejscu i nie przenosi się co sesję.
    public private(set) var folder: URL?
    public private(set) var items: [DiskBankItem] = [] {
        didSet { rebuildTree() }
    }

    public private(set) var isScanning = false

    /// Plik podświetlony na liście — świeżo zapisany blok, żeby było widać, gdzie wylądował.
    public var highlightedFile: URL?

    /// Pokazuj tylko patche tej kategorii (`G2PatchCategory`); `nil` = wszystkie pliki.
    /// Performance kategorii nie mają, więc przy włączonym filtrze znikają. Nie jest
    /// zapamiętywany — po ponownym uruchomieniu lista bez filtra nie wygląda na „zgubioną".
    public var categoryFilter: Int? {
        didSet {
            guard categoryFilter != oldValue else { return }
            rebuildTree()
        }
    }

    /// Które rodzaje plików widać: patche (`.pch2`) i/lub performance (`.prf2`). Przyciski
    /// stoją w nagłówku panelu Patches i działają też na listę z Norda. Zawsze co najmniej
    /// jeden włączony — pusta lista wyglądałaby na zgubioną bibliotekę. Nie jest
    /// zapamiętywany: po starcie zawsze oba (decyzja użytkownika 2026-10-12).
    public private(set) var showsPatches = true
    public private(set) var showsPerformances = true

    /// Przełącza jeden rodzaj; wyłączenie ostatniego włączonego nic nie robi.
    public func toggleKind(performances: Bool) {
        if performances {
            guard !showsPerformances || showsPatches else { return }
            showsPerformances.toggle()
        } else {
            guard !showsPatches || showsPerformances else { return }
            showsPatches.toggle()
        }
        rebuildTree()
    }

    /// Czy plik danego rodzaju przechodzi przez filtr — to samo pytanie zadaje lista Norda.
    public func showsKind(performance: Bool) -> Bool {
        performance ? showsPerformances : showsPatches
    }

    /// Kategorie, które mają w bibliotece choć jeden plik, po nazwie — pozycje menu filtra.
    public private(set) var availableCategories: [Int] = []
    /// Czemu lista jest pusta — inaczej „brak wyników" i „nie wybrano folderu" wyglądają
    /// tak samo.
    public private(set) var message: String?

    /// Kolejność listy plików. Zapamiętana jak folder — kto sortuje po dacie, chce tak
    /// zawsze.
    public var sortOrder: DiskBankSort {
        didSet {
            defaults.set(sortOrder.rawValue, forKey: keys.sort)
            // Nowy klucz zaczyna od swojego domyślnego kierunku — jak kolumna w Finderze.
            if sortOrder != oldValue, sortReversed {
                sortReversed = false
            } else {
                rebuildTree()
            }
        }
    }

    /// Kierunek odwrotny do domyślnego dla `sortOrder` (np. rozmiar od najmniejszych).
    /// Zapamiętany razem z kolejnością.
    public var sortReversed: Bool {
        didSet {
            defaults.set(sortReversed, forKey: keys.reversed)
            rebuildTree()
        }
    }

    /// Folder, po którym użytkownik chodził — ścieżka względem `folder`, pusta = katalog
    /// główny. Zapamiętana, żeby po ponownym uruchomieniu wrócić tam, gdzie się skończyło.
    public var currentPath: String {
        didSet { defaults.set(currentPath, forKey: keys.path) }
    }

    private let defaults: UserDefaults
    /// Klucze w `UserDefaults` — osobne dla każdej biblioteki, żeby folder patchy
    /// i folder Building Blocks pamiętały się niezależnie.
    private let keys: (folder: String, sort: String, reversed: String, path: String)
    private nonisolated static let folderKey = "g2_disk_bank_folder"
    /// Ile plików wchodzi do listy. Bezpiecznik na katalog wskazany przez pomyłkę
    /// (cały dysk), nie sposób na krótszą listę — po liście i tak chodzi się folderami
    /// i szuka po nazwie. Musi mieścić prawdziwą bibliotekę z sieci: sam pakiet
    /// „Nord Modular G1 G2" to ponad 35 000 plików, a przy limicie 5 000 z panelu
    /// znikało wszystko, co enumerator odwiedził później → #102.
    public nonisolated static let scanLimit = 200_000

    private let scanLimit: Int

    /// `keyPrefix` rozdziela zapamiętane ustawienia bibliotek; domyślny to folder patchy.
    public init(defaults: UserDefaults = .standard, scanLimit: Int = DiskBankLibrary.scanLimit,
                keyPrefix: String = "g2_disk_bank")
    {
        self.defaults = defaults
        self.scanLimit = scanLimit
        keys = (keyPrefix + "_folder", keyPrefix + "_sort", keyPrefix + "_sort_reversed", keyPrefix + "_path")
        sortOrder = defaults.string(forKey: keys.sort).flatMap(DiskBankSort.init) ?? .name
        sortReversed = defaults.bool(forKey: keys.reversed)
        currentPath = defaults.string(forKey: keys.path) ?? ""
        if let path = defaults.string(forKey: keys.folder), !path.isEmpty {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    /// Folder zapamiętany przez panel Banks — przeglądarka wtyczki (`PluginBrowser`) czyta ten sam.
    public nonisolated static func savedFolderPath(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: folderKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Nowy folder główny = wracamy na jego szczyt; ścieżka ze starego nic tu nie znaczy.
    public func setFolder(_ url: URL) {
        folder = url
        currentPath = ""
        defaults.set(url.path, forKey: keys.folder)
        Task { await scan() }
    }

    public func forgetFolder() {
        folder = nil
        currentPath = ""
        items = []
        message = nil
        defaults.removeObject(forKey: keys.folder)
    }

    /// Przegląda folder rekurencyjnie. Skan idzie poza głównym wątkiem — katalog
    /// z kilkoma tysiącami plików na wolnym dysku potrafi zająć sekundy, a panel
    /// ma w tym czasie zostać klikalny.
    public func scan() async {
        guard let folder, !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        // Na listę czeka użytkownik, więc priorytet jak dla jego akcji — przy `.utility`
        // skan dostaje słabsze rdzenie. Sortowanie też poza głównym wątkiem.
        items = await Task.detached(priority: .userInitiated) { [limit = scanLimit] in
            Self.scanFolder(folder, limit: limit).sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }.value
        // Urwany skan musi być widoczny: lista wygląda tak samo jak kompletna, a brakuje
        // w niej całych folderów — tych, do których enumerator doszedł za późno (#102).
        if items.count >= scanLimit {
            message = "Showing the first \(scanLimit) files — this folder holds more."
        } else {
            message = items.isEmpty ? "No .pch2 or .prf2 files in this folder." : nil
        }
        // Zapamiętany podfolder mógł w międzyczasie zniknąć albo opustoszeć.
        if !currentPath.isEmpty, fileCount(under: currentPath) == 0 {
            currentPath = ""
        }
    }

    /// Czysty przegląd katalogu — bez stanu, więc może biec poza głównym wątkiem.
    ///
    /// Zmierzone na 45 643 plikach (2026-10-25, #156): pytanie o iCloud przy KAŻDYM pliku
    /// brało 3,4 s z 5,2 s, więc zadajemy je tylko w folderze, który sam leży w iCloud — poza
    /// nim pliki są na dysku. Tagi i 4 KB nagłówka czytamy na wszystkich rdzeniach naraz.
    private nonisolated static func scanFolder(_ folder: URL, limit: Int) -> [DiskBankItem] {
        let inCloud = (try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
        var keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
        if inCloud {
            keys += [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        }
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in walker {
            guard urls.count < limit else { break }
            let ext = url.pathExtension.lowercased()
            if ext == "pch2" || ext == "prf2" { urls.append(url) }
        }

        let base = folder.standardizedFileURL.path
        var found = [DiskBankItem?](repeating: nil, count: urls.count)
        found.withUnsafeMutableBufferPointer { buffer in
            let slots = ScanSlots(buffer: buffer)
            DispatchQueue.concurrentPerform(iterations: urls.count) { index in
                slots.buffer[index] = item(at: urls[index], base: base, keys: keys)
            }
        }
        return found.compactMap { $0 }
    }

    /// Wyniki skanu zapisywane z wielu wątków naraz — każdy pisze wyłącznie do swojej
    /// komórki, więc bufor bez zamka jest bezpieczny.
    private struct ScanSlots: @unchecked Sendable {
        let buffer: UnsafeMutableBufferPointer<DiskBankItem?>
    }

    /// Jeden plik z dysku jako pozycja listy; `nil` dla czegoś, co tylko nazywa się `.pch2`.
    private nonisolated static func item(at url: URL, base: String, keys: [URLResourceKey]) -> DiskBankItem? {
        let values = try? url.resourceValues(forKeys: Set(keys))
        guard values?.isRegularFile != false else { return nil }
        let ext = url.pathExtension.lowercased()
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let relative = parent.hasPrefix(base) ? String(parent.dropFirst(base.count)) : parent
        return DiskBankItem(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            isPerformance: ext == "prf2",
            modified: values?.contentModificationDate ?? .distantPast,
            size: values?.fileSize ?? 0,
            relativeFolder: relative.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            tags: finderTags(at: url),
            category: ext == "pch2" && isLocal(values) ? patchCategory(at: url) : 0
        )
    }

    /// Plik z iCloud, którego nie ma na dysku, zostaje w chmurze: czytanie kategorii
    /// ściągałoby cały folder, plik po pliku.
    private nonisolated static func isLocal(_ values: URLResourceValues?) -> Bool {
        guard values?.isUbiquitousItem == true else { return true }
        return values?.ubiquitousItemDownloadingStatus == .current
    }

    /// Kategoria z początku pliku — sekcja opisu leży zaraz za nagłówkiem tekstowym,
    /// więc 4 KB wystarcza z zapasem.
    private nonisolated static func patchCategory(at url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096) else { return 0 }
        return PatchParser.category(ofPatchFileHead: head) ?? 0
    }

    /// Tagi Findera. Dwie drogi, bo na dysku bywają obie:
    ///   • `com.apple.metadata:_kMDItemUserTags` — lista `Nazwa\nKolor`, tak zapisuje
    ///     Finder od Mavericks; `URLResourceKey.tagNamesKey` dałby same nazwy, bez koloru;
    ///   • `com.apple.FinderInfo` — stara etykieta w bitach 1–3 flag (bajt 9). Pliki
    ///     z biblioteki zsynchronizowanej przez iCloud mają TYLKO ją (sprawdzone
    ///     2026-09-16 na `Ptches pch2 i prf2/…/Drum`), numeracja kolorów ta sama.
    nonisolated static func finderTags(at url: URL) -> [FinderTag] {
        if let data = extendedAttribute("com.apple.metadata:_kMDItemUserTags", at: url),
           let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String],
           !entries.isEmpty
        {
            return entries.map { entry in
                let parts = entry.split(separator: "\n", maxSplits: 1)
                let color = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                return FinderTag(name: parts.first.map(String.init) ?? entry, color: color)
            }
        }
        if let info = extendedAttribute("com.apple.FinderInfo", at: url), info.count >= 10 {
            let color = Int(info[9] >> 1) & 7
            if color > 0 {
                return [FinderTag(name: Self.labelNames[color], color: color)]
            }
        }
        return []
    }

    /// Nazwy starych etykiet — Finder nie trzyma ich przy pliku, więc angielskie na stałe.
    private nonisolated static let labelNames = ["", "Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"]

    private nonisolated static func extendedAttribute(_ name: String, at url: URL) -> Data? {
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, length, 0, 0) }
        return read == length ? data : nil
    }

    /// Zapisuje tagi tak, jak robi to Finder — w OBU miejscach naraz, żeby Finder, Spotlight
    /// i nasz czytnik widziały to samo: lista `Nazwa\nKolor` w `_kMDItemUserTags` i stara
    /// etykieta w `FinderInfo` (pierwszy kolorowy tag; reszta 32 bajtów zostaje). Pusta lista
    /// zdejmuje oba.
    nonisolated static func writeFinderTags(_ tags: [FinderTag], at url: URL) throws {
        let userTags = "com.apple.metadata:_kMDItemUserTags"
        let finderInfo = "com.apple.FinderInfo"
        if tags.isEmpty {
            removexattr(url.path, userTags, 0)
        } else {
            let entries = tags.map { "\($0.name)\n\($0.color)" }
            let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
            try setExtendedAttribute(userTags, data, at: url)
        }
        var info = extendedAttribute(finderInfo, at: url) ?? Data(count: 32)
        if info.count < 32 { info.append(Data(count: 32 - info.count)) }
        let color = tags.first { $0.color > 0 }?.color ?? 0
        info[9] = (info[9] & ~0x0E) | UInt8(color << 1)
        if info.allSatisfy({ $0 == 0 }) {
            removexattr(url.path, finderInfo, 0)
        } else {
            try setExtendedAttribute(finderInfo, info, at: url)
        }
    }

    private nonisolated static func setExtendedAttribute(_ name: String, _ data: Data, at url: URL) throws {
        let result = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, 0) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    // MARK: - Dymek przy pliku

    /// Ile modułów i ile DSP zjada plik — dymek w przeglądarce. Parsuje CAŁY plik, więc
    /// woła się to dla jednego pliku naraz, poza głównym wątkiem. `nil`, gdy pliku nie da
    /// się przeczytać albo leży w iCloud i nie ma go na dysku (czytanie by go ściągało).
    public nonisolated static func summary(of url: URL) -> DiskFileSummary? {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard isLocal(try? url.resourceValues(forKeys: keys)),
              let data = try? Data(contentsOf: url),
              let file = try? PatchParser.parseFile(data: data)
        else { return nil }
        let isPerformance = url.pathExtension.lowercased() == "prf2"
        let slots = file.patches.enumerated().compactMap { index, patch -> DiskFileSummary.Slot? in
            let voice = patch.modules(in: .voice)
            let fx = patch.modules(in: .fx)
            // Pusty slot performance'u nic nie mówi — w patchu zostaje, bo to cały plik.
            guard !isPerformance || !voice.isEmpty || !fx.isEmpty else { return nil }
            return DiskFileSummary.Slot(
                label: isPerformance ? "ABCD".map(String.init)[min(index, 3)] : nil,
                name: isPerformance ? patch.name : nil,
                modules: voice.count + fx.count,
                voiceLoad: G2PatchLoad.estimate(area: .voice, modules: voice).dspPercent,
                fxLoad: G2PatchLoad.estimate(area: .fx, modules: fx).dspPercent
            )
        }
        return DiskFileSummary(slots: slots)
    }

    // MARK: - Zmiany na dysku z przeglądarki

    //
    // Po każdej zmianie lista jest poprawiana W MIEJSCU, nie skanowana od nowa — skan
    // kilku tysięcy plików trwa sekundy, a użytkownik zmienił jeden.

    /// Nadaje plikowi tagi Findera (zastępuje dotychczasowe).
    public func setTags(_ tags: [FinderTag], of item: DiskBankItem) throws {
        try Self.writeFinderTags(tags, at: item.url)
        replace(item, with: DiskBankItem(
            url: item.url, name: item.name, isPerformance: item.isPerformance, modified: item.modified,
            size: item.size, relativeFolder: item.relativeFolder, tags: tags, category: item.category
        ))
    }

    /// Zmienia nazwę pliku (bez rozszerzenia — to zostaje). Ukośnik w nazwie zrobiłby folder.
    public func rename(_ item: DiskBankItem, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        let target = item.url.deletingLastPathComponent()
            .appendingPathComponent(trimmed).appendingPathExtension(item.url.pathExtension)
        try FileManager.default.moveItem(at: item.url, to: target)
        replace(item, with: DiskBankItem(
            url: target, name: trimmed, isPerformance: item.isPerformance, modified: item.modified,
            size: item.size, relativeFolder: item.relativeFolder, tags: item.tags, category: item.category
        ))
    }

    /// Przenosi plik do Kosza — odwracalne, w przeciwieństwie do usunięcia.
    public func trash(_ item: DiskBankItem) throws {
        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        items.removeAll { $0.id == item.id }
    }

    private func replace(_ old: DiskBankItem, with new: DiskBankItem) {
        guard let index = items.firstIndex(where: { $0.id == old.id }) else { return }
        items[index] = new
    }

    // MARK: - Sortowanie

    /// Ta sama kolejność dla listy folderu i dla wyników szukania. Remisy zawsze po nazwie
    /// rosnąco (także w kierunku odwróconym), żeby lista nie skakała między skanami.
    public nonisolated static func sorted(
        _ items: [DiskBankItem], by order: DiskBankSort, reversed: Bool = false
    ) -> [DiskBankItem] {
        func byName(_ lhs: DiskBankItem, _ rhs: DiskBankItem) -> Bool {
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        switch order {
        case .name:
            return reversed ? items.sorted { byName($1, $0) } : items.sorted(by: byName)
        case .date:
            return items.sorted {
                $0.modified != $1.modified ? ($0.modified > $1.modified) != reversed : byName($0, $1)
            }
        case .size:
            return items.sorted { $0.size != $1.size ? ($0.size > $1.size) != reversed : byName($0, $1) }
        case .tags:
            /// Bez tagu = za tęczą w OBU kierunkach — odwrócona jest tylko tęcza; w obrębie
            /// koloru remis rozstrzyga nazwa tagu, potem pliku.
            func key(_ item: DiskBankItem) -> (Int, String) {
                guard let tag = item.tags.first else { return (Int.max, "") }
                return (tag.rainbowRank, tag.name)
            }
            return items.sorted {
                let (lhs, rhs) = (key($0), key($1))
                if lhs.0 != rhs.0 {
                    if lhs.0 == Int.max || rhs.0 == Int.max { return lhs.0 < rhs.0 }
                    return (lhs.0 < rhs.0) != reversed
                }
                let names = lhs.1.localizedStandardCompare(rhs.1)
                return names != .orderedSame ? names == .orderedAscending : byName($0, $1)
            }
        case .kind:
            return items.sorted {
                $0.isPerformance != $1.isPerformance ? ($1.isPerformance != reversed) : byName($0, $1)
            }
        case .category:
            /// Jak tagi: bez kategorii na końcu w OBU kierunkach, remis po nazwie pliku.
            func key(_ item: DiskBankItem) -> String? {
                item.category > 0 ? G2PatchCategory.name(item.category) : nil
            }
            return items.sorted {
                switch (key($0), key($1)) {
                case let (lhs?, rhs?):
                    let order = lhs.localizedStandardCompare(rhs)
                    return order != .orderedSame ? (order == .orderedAscending) != reversed : byName($0, $1)
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return byName($0, $1)
                }
            }
        }
    }

    // MARK: - Chodzenie po folderach

    //
    // Skan jest i zostaje REKURENCYJNY — szukanie ma przeszukiwać wszystko, co pod
    // wybranym folderem leży. Drzewa nie trzymamy osobno: `relativeFolder` każdego pliku
    // wystarczy, żeby odtworzyć je w locie, a przy okazji folder bez ani jednego patcha
    // (na żadnym poziomie) sam się nie pokazuje — nie ma po co do niego wchodzić.

    /// Drzewo policzone RAZ po skanie, nie przy każdym pytaniu. Bez tego wiersz folderu
    /// przeglądał całą listę, żeby podać liczbę przy nazwie, a wejście do folderu
    /// filtrowało i sortowało wszystko od nowa — SwiftUI woła to przy KAŻDYM
    /// przerysowaniu panelu, więc koszt mnożył się przez liczbę folderów. Zmierzone na
    /// 20 000 plików: 221 ms na przerysowanie, czyli kółeczko bez końca → #103.
    private struct FolderTree {
        var children: [String: [String]] = [:]
        var files: [String: [DiskBankItem]] = [:]
        var counts: [String: Int] = [:]
    }

    private var tree = FolderTree()

    /// Ścieżka i wszystkie jej nadrzędne, od katalogu głównego: `A/B` → `["", "A", "A/B"]`.
    private static func ancestry(of path: String) -> [String] {
        guard !path.isEmpty else { return [""] }
        var result = [""]
        var current = ""
        for part in path.split(separator: "/") {
            current = current.isEmpty ? String(part) : current + "/" + part
            result.append(current)
        }
        return result
    }

    private func rebuildTree() {
        var tree = FolderTree()
        var children: [String: Set<String>] = [:]
        availableCategories = Set(items.map(\.category)).filter { $0 > 0 }.sorted {
            G2PatchCategory.name($0).localizedStandardCompare(G2PatchCategory.name($1)) == .orderedAscending
        }
        // Filtr działa już na drzewie: foldery bez pasującego pliku znikają, a liczby przy
        // nazwach liczą tylko to, co widać.
        for item in items where passesFilter(item) {
            tree.files[item.relativeFolder, default: []].append(item)
            let chain = Self.ancestry(of: item.relativeFolder)
            for (depth, folder) in chain.enumerated() {
                tree.counts[folder, default: 0] += 1
                if depth + 1 < chain.count {
                    let child = chain[depth + 1]
                    let name = folder.isEmpty ? child : String(child.dropFirst(folder.count + 1))
                    children[folder, default: []].insert(name)
                }
            }
        }
        for (folder, names) in children {
            tree.children[folder] = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        for (folder, files) in tree.files {
            tree.files[folder] = Self.sorted(files, by: sortOrder, reversed: sortReversed)
        }
        self.tree = tree
    }

    private func passesFilter(_ item: DiskBankItem) -> Bool {
        showsKind(performance: item.isPerformance) && (categoryFilter.map { item.category == $0 } ?? true)
    }

    /// Podfoldery leżące BEZPOŚREDNIO w `path`, po nazwie.
    public func subfolders(of path: String) -> [String] {
        tree.children[path] ?? []
    }

    /// Pliki leżące BEZPOŚREDNIO w `path` — bez tych z podfolderów, w bieżącej kolejności.
    public func files(in path: String) -> [DiskBankItem] {
        tree.files[path] ?? []
    }

    /// Ile plików leży w `path` i we wszystkim pod nim — liczba przy nazwie folderu,
    /// żeby było widać, czy warto tam wchodzić.
    public func fileCount(under path: String) -> Int {
        tree.counts[path] ?? 0
    }

    /// Folder o poziom wyżej; `nil` w katalogu głównym.
    public nonisolated static func parent(of path: String) -> String? {
        guard !path.isEmpty else { return nil }
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex ..< slash])
    }

    /// Filtr po nazwie, folderze i nazwie tagu — bez rozróżniania wielkości liter i znaków
    /// diakrytycznych. Wynik w bieżącej kolejności.
    public func items(matching query: String) -> [DiskBankItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let shown = items.filter(passesFilter)
        guard !trimmed.isEmpty else { return Self.sorted(shown, by: sortOrder, reversed: sortReversed) }
        return Self.sorted(shown.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.relativeFolder.localizedCaseInsensitiveContains(trimmed)
                || $0.tags.contains { $0.name.localizedCaseInsensitiveContains(trimmed) }
                || ($0.category > 0 && G2PatchCategory.name($0.category).localizedCaseInsensitiveContains(trimmed))
        }, by: sortOrder, reversed: sortReversed)
    }
}

private extension G2PatchLoad {
    /// Jedna liczba na obszar do dymka: bliższy limitu z dwóch zasobów (moc albo pamięć) —
    /// to on decyduje, czy patch się zmieści.
    var dspPercent: Double {
        max(cyclesPercent, memoryPercent)
    }
}
