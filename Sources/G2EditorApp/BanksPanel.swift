// BanksPanel.swift
// Zawartość zakładki „Banks" — dwa źródła patchy w jednym miejscu.
//
//   • **Nord** — co siedzi w pamięci urządzenia. Odczyt komendą `0x14`, ładowanie `0x0A`.
//   • **Disk** — folder z plikami `.pch2`/`.prf2`, działa bez podłączonego sprzętu.
//
// Rozdzielone przełącznikiem, bo to naprawdę dwie różne rzeczy: z Norda ładuje się
// patcha DO SLOTU (urządzenie robi to samo, co PATCH LOAD na froncie), a z dysku
// otwiera się plik W EDYTORZE.

import AppKit
import G2Core
import G2EditorCore
import SwiftUI

struct BanksPanel: View {
    let state: PatchState
    let device: DeviceConnection
    @Bindable var library: DiskBankLibrary
    /// Otwarcie pliku idzie tą samą drogą co File → Open, żeby nie było dwóch sposobów
    /// wczytania patcha, które mogą się rozjechać.
    let onOpenFile: (URL) -> Void

    private enum Source: String, CaseIterable {
        case nord = "Nord"
        case disk = "Disk"
    }

    @AppStorage("g2_banks_source") private var sourceRaw = Source.disk.rawValue
    @State private var query = ""
    /// Folder, po którym właśnie chodzimy — trzyma go biblioteka, żeby przetrwał
    /// ponowne uruchomienie.
    private var diskPath: String {
        get { library.currentPath }
        nonmutating set { library.currentPath = newValue }
    }

    /// Foldery rozwinięte w miejscu (trójkątem), ścieżki względne jak `diskPath`.
    @State private var expanded: Set<String> = []

    /// Ścieżka pliku otwartego na canvasie — jego wiersz jest podświetlony. Śledzona
    /// przez `onReceive`, a nie przez obserwację całego `PatchState`: lista plików nie
    /// musi się przerysowywać przy każdym ruchu gałki.
    @State private var openPath: String?
    /// Wiersz, do którego lista ma się przewinąć po ⌥↑/⌥↓.
    @State private var scrollTarget: String?

    /// Banki Norda: kolejność w banku, jej kierunek i rozwinięte banki (identyfikatory
    /// `G2BankGroup.id` po przecinku) przeżywają ponowne uruchomienie.
    @AppStorage("g2_nord_banks_sort") private var nordSortRaw = G2BankSort.location.rawValue
    @AppStorage("g2_nord_banks_reversed") private var nordSortReversed = false
    @AppStorage("g2_nord_banks_expanded") private var nordExpandedRaw = ""
    @State private var nordCategory: Int?

    private var source: Source {
        Source(rawValue: sourceRaw) ?? .disk
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $sourceRaw) {
                ForEach(Source.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.top, 8)

            searchField

            Divider()

            switch source {
            case .nord: nordList
            case .disk: diskList
            }
        }
        .onReceive(state.fileURLChanges) { openPath = $0?.standardizedFileURL.path }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Banki Norda

    /// Lista z urządzenia pocięta na banki — przy 128 miejscach w banku jedna długa lista
    /// była nie do czytania (prośba użytkownika 2026-09-26, po wgraniu banku fabrycznego).
    private var nordGroups: [G2BankGroup] {
        let shown = device.bankEntries.filter { library.showsKind(performance: $0.kind == .performance) }
        return G2BankGroup.grouped(shown, query: query, category: nordCategory,
                                   sort: nordSort, reversed: nordSortReversed)
    }

    private var nordKindFiltered: Bool {
        !library.showsPatches || !library.showsPerformances
    }

    private var nordSort: G2BankSort {
        G2BankSort(rawValue: nordSortRaw) ?? .location
    }

    @ViewBuilder
    private var nordList: some View {
        if device.status == .searching {
            hint("No G2 connected", "Connect the device to read what is in its memory.")
        } else if device.status == .connecting {
            hint("Connecting…", "The banks are read as soon as the G2 has connected.")
        } else if case let .error(message) = device.status {
            hint("The G2 reported an error", "\(message)\nThe editor reconnects on its own.")
        } else if device.bankEntries.isEmpty {
            VStack(spacing: 8) {
                Button {
                    Task { await device.refreshBankList() }
                } label: {
                    Label(device.isReadingBanks ? "Reading…" : "Read banks", systemImage: "arrow.clockwise")
                }
                .disabled(device.isReadingBanks || device.isBusy)
                Text("The banks are read when the G2 connects. Read them again if the list stayed empty.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
        } else {
            VStack(spacing: 0) {
                nordBar
                Divider()
                if let error = device.bankLoadError {
                    bankLoadErrorBar(error)
                    Divider()
                }
                List {
                    ForEach(nordGroups) { group in
                        DisclosureGroup(isExpanded: nordExpansion(of: group.id)) {
                            ForEach(group.entries) { nordRow($0) }
                        } label: {
                            nordBankRow(group)
                        }
                    }
                }
                // Póki poprzedni patch się ładuje, lista jest wyszarzona — kolejny klik
                // poszedłby w środek transferu (prośba użytkownika 2026-10-15).
                .disabled(!device.acceptsPatchChange)
                .listStyle(.plain)
            }
        }
    }

    private func bankLoadErrorBar(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                device.dismissBankLoadError()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .font(.system(size: 10))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    /// Litery slotów, do których ten wiersz załadował panel („A”, „AC”; performance = „ABCD”).
    private func loadedSlots(_ entry: G2BankEntry) -> String {
        if device.bankLoads[4] == entry.id { return "ABCD" }
        return device.bankLoads.filter { $0.value == entry.id && $0.key < 4 }.keys.sorted()
            .map { String(Character(UnicodeScalar(UInt8(65 + $0)))) }.joined()
    }

    private func nordRow(_ entry: G2BankEntry) -> some View {
        let slots = loadedSlots(entry)
        return Button {
            Task { await device.loadFromBank(entry, intoSlot: state.selectedSlot) }
        } label: {
            HStack(spacing: 6) {
                Text(entry.displayLocation)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
                Text(entry.name.isEmpty ? "—" : entry.name)
                    .font(.system(size: 11, weight: slots.isEmpty ? .regular : .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if entry.kind == .patch, nordSort == .category {
                    Text(G2PatchCategory.name(entry.category))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if !slots.isEmpty {
                    Text(slots)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                }
                PatchKindBadge(isPerformance: entry.kind == .performance)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Ten sam wygląd co otwarty plik w źródle „Disk”.
        .listRowBackground(slots.isEmpty ? nil : Color.accentColor.opacity(0.22))
        .help(slots.isEmpty ? "Load into the device" : "Loaded into slot \(slots) — click to load again")
    }

    /// Nagłówek banku — kliknięcie w całą szerokość rozwija i zwija, jak trójkąt obok.
    private func nordBankRow(_ group: G2BankGroup) -> some View {
        let expansion = nordExpansion(of: group.id)
        return Button {
            expansion.wrappedValue.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: group.kind == .patch ? "rectangle.stack.fill" : "square.grid.2x2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(group.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(group.entries.count)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Przy szukaniu i filtrze kategorii wszystkie banki stoją otwarte — trafienie
    /// schowane w zwiniętym banku wyglądałoby na brak wyników. Zapamiętane rozwinięcia
    /// wracają, gdy pole szukania się wyczyści.
    private func nordExpansion(of id: String) -> Binding<Bool> {
        Binding(
            get: { isSearching || nordCategory != nil || nordExpanded.contains(id) },
            set: { open in
                var ids = nordExpanded
                if open { ids.insert(id) } else { ids.remove(id) }
                nordExpandedRaw = ids.sorted().joined(separator: ",")
            }
        )
    }

    private var nordExpanded: Set<String> {
        Set(nordExpandedRaw.split(separator: ",").map(String.init))
    }

    /// Pasek nad bankami — ten sam układ co nad dyskiem: ile jest, filtr kategorii,
    /// kolejność, odświeżenie.
    private var nordBar: some View {
        HStack(spacing: 3) {
            Text(nordCount)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            nordCategoryMenu
            nordSortMenu
            barButton("arrow.clockwise", help: "Read the banks again") {
                Task { await device.refreshBankList() }
            }
            .disabled(device.isReadingBanks || device.isBusy)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(.bar)
    }

    private var nordCount: String {
        if device.isReadingBanks { return "reading…" }
        let total = device.bankEntries.count
        guard isSearching || nordCategory != nil || nordKindFiltered else { return "\(total) in memory" }
        return "\(nordGroups.reduce(0) { $0 + $1.entries.count }) of \(total)"
    }

    private var nordSortMenu: some View {
        Menu {
            Picker("Sort by", selection: $nordSortRaw) {
                ForEach(G2BankSort.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: $nordSortReversed) {
                Text(nordSort == .name ? "A to Z" : "Ascending").tag(false)
                Text(nordSort == .name ? "Z to A" : "Descending").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort each bank by: \(nordSort.title)")
    }

    private var nordCategoryMenu: some View {
        let active = nordCategory != nil
        let categories = Set(device.bankEntries.filter { $0.kind == .patch }.map(\.category)).sorted()
        return Menu {
            Picker("Category", selection: $nordCategory) {
                Text("All Patches").tag(Int?.none)
                Divider()
                ForEach(categories, id: \.self) { category in
                    Text(G2PatchCategory.name(category)).tag(Int?.some(category))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(nordCategory.map { "Showing only \(G2PatchCategory.name($0)) patches" }
            ?? "Show only patches of one category")
    }

    // MARK: - Banki z dysku

    @ViewBuilder
    private var diskList: some View {
        if library.folder == nil {
            VStack(spacing: 8) {
                Button("Choose folder…", action: chooseFolder)
                Text("Point at a folder of .pch2 files — subfolders are included.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
        } else {
            ScrollViewReader { proxy in
                diskContent
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation { proxy.scrollTo(target) }
                    }
            }
            .background(PatchStepKeys(step: stepPatch))
            // Powrót na szczyt przy zmianie folderu głównego robi `setFolder`, nie widok —
            // tu zerowanie kasowałoby też podfolder zapamiętany z poprzedniej sesji.
            .task(id: library.folder) {
                await library.scan()
            }
        }
    }

    private var diskContent: some View {
        VStack(spacing: 0) {
            // Pasek nawigacji stoi NAD listą — wybór folderu i wychodzenie piętro
            // wyżej to rzeczy, po które sięga się przed czytaniem listy, a nie po.
            diskBar
            Divider()
            if isSearching {
                // Szukanie przeszukuje CAŁĄ bibliotekę, nie tylko otwarty folder —
                // stąd płaska lista z podpisaną ścieżką.
                List(library.items(matching: query)) { item in
                    DiskFileRow(
                        library: library, item: item, showsFolder: true,
                        isOpen: item.isFile(atPath: openPath), onOpen: onOpenFile
                    )
                }
                .listStyle(.plain)
                .disabled(!device.acceptsPatchChange)
            } else {
                List {
                    // „Piętro wyżej" jako PIERWSZY WIERSZ listy, nie tylko ikonka w pasku:
                    // wiersz jest szeroki na cały panel i klika się tak samo jak wejście
                    // do folderu — patrz [[Docs/ui/side-panels]].
                    if canGoUp {
                        upRow
                    }
                    DiskFolderRows(
                        library: library, path: diskPath, expanded: $expanded,
                        diskPath: $library.currentPath, openPath: openPath, onOpenFile: onOpenFile
                    )
                }
                .listStyle(.plain)
                .disabled(!device.acceptsPatchChange)
            }
        }
    }

    // MARK: - Przesłuchiwanie strzałkami

    /// Pliki w kolejności, w jakiej stoją na ekranie: wyniki szukania albo zawartość
    /// folderu razem z folderami rozwiniętymi w miejscu (ich pliki przed plikami rodzica,
    /// jak w `DiskFolderRows`).
    private var visibleFiles: [DiskBankItem] {
        if isSearching { return library.items(matching: query) }
        func files(in path: String) -> [DiskBankItem] {
            let nested = library.subfolders(of: path).flatMap { name in
                let child = path.isEmpty ? name : path + "/" + name
                return expanded.contains(child) ? files(in: child) : []
            }
            return nested + library.files(in: path)
        }
        return files(in: diskPath)
    }

    /// ⌥↓ otwiera następny plik z listy, ⌥↑ poprzedni — przesłuchiwanie bez klikania.
    /// Bez otwartego pliku z tej listy ⌥↓ zaczyna od pierwszego, ⌥↑ od ostatniego.
    /// Na końcach listy stoi (bez zawijania), żeby nie przeskoczyć niechcący na początek.
    private func stepPatch(forward: Bool) {
        let files = visibleFiles
        guard !files.isEmpty, device.acceptsPatchChange else { return }
        let target: DiskBankItem
        if let index = files.firstIndex(where: { $0.isFile(atPath: openPath) }) {
            let next = index + (forward ? 1 : -1)
            guard files.indices.contains(next) else { return }
            target = files[next]
        } else {
            target = forward ? files[0] : files[files.count - 1]
        }
        onOpenFile(target.url)
        scrollTarget = target.id
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Jeden pasek nad listą: gdzie jestem, ile tu jest, jak wyjść wyżej, jak odświeżyć
    /// i jak wskazać inny folder.
    private var diskBar: some View {
        HStack(spacing: 3) {
            barButton("chevron.left", help: "Up one folder", action: goUp)
                .disabled(!canGoUp || isSearching)

            Text(location)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(library.folder?.appendingPathComponent(diskPath).path ?? "")

            Spacer(minLength: 4)

            Text(count)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            categoryMenu

            sortMenu

            barButton("arrow.clockwise", help: "Scan the folder again") {
                Task { await library.scan() }
            }
            .disabled(library.isScanning)

            barButton("folder", help: "Choose a different folder", action: chooseFolder)
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(.bar)
    }

    /// Ikonka w pasku dostaje WŁASNE pole trafienia. Bez tego przycisk kończy się
    /// dokładnie na obrysie glifu, a `chevron.left` to ok. 6 × 10 pt — trafienie
    /// w niego myszą było kwestią szczęścia i „piętro wyżej" wyglądało na zepsute.
    private func barButton(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Kolejność plików — jak w Finderze: nazwa, data, rozmiar, tagi, a do tego rodzaj
    /// (`.pch2`/`.prf2`) i kategoria patcha; każda w obu kierunkach. Foldery zawsze po
    /// nazwie, więc wybór dotyczy tylko plików.
    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $library.sortOrder) {
                ForEach(DiskBankSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: $library.sortReversed) {
                Text(library.sortOrder.directionTitles.natural).tag(false)
                Text(library.sortOrder.directionTitles.reversed).tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort by: \(library.sortOrder.title), \(sortDirectionTitle)")
    }

    /// Filtr kategorii — pokazuje tylko patche jednej kategorii (Bass, Lead…), w folderze
    /// i w wynikach szukania. Włączony filtr to wypełniona ikonka w kolorze akcentu, żeby
    /// krótsza lista nie wyglądała na zgubione pliki.
    private var categoryMenu: some View {
        let active = library.categoryFilter != nil
        return Menu {
            Picker("Category", selection: $library.categoryFilter) {
                Text("All Files").tag(Int?.none)
                Divider()
                ForEach(library.availableCategories, id: \.self) { category in
                    Text(G2PatchCategory.name(category)).tag(Int?.some(category))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(library.categoryFilter.map { "Showing only \(G2PatchCategory.name($0)) patches" }
            ?? "Show only patches of one category")
    }

    private var sortDirectionTitle: String {
        let titles = library.sortOrder.directionTitles
        return library.sortReversed ? titles.reversed : titles.natural
    }

    /// Nazwa miejsca, w którym stoimy: w katalogu głównym nazwa wskazanego folderu,
    /// niżej ścieżka względem niego.
    private var location: String {
        if isSearching { return "All folders" }
        if diskPath.isEmpty { return library.folder?.lastPathComponent ?? "" }
        return diskPath
    }

    private var count: String {
        if library.isScanning { return "scanning…" }
        if let message = library.message { return message }
        return "\(library.fileCount(under: isSearching ? "" : diskPath))"
    }

    /// Folder nad folderem głównym biblioteki; `nil` na szczycie dysku.
    private var folderAboveRoot: URL? {
        guard let folder = library.folder?.standardizedFileURL, folder.path != "/" else { return nil }
        return folder.deletingLastPathComponent()
    }

    /// „Wyżej" działa jak w Finderze — także PONAD folderem głównym. Użytkownik wskazał
    /// jako główny folder `…/Drum` i chciał wyjść do jego rodzica; wygaszona strzałka
    /// wyglądała na zepsutą (trzecie zgłoszenie, 2026-09-16). W folderze głównym „wyżej"
    /// przestawia więc bibliotekę na folder nadrzędny — `.task(id: library.folder)` wraca
    /// na jego szczyt i skanuje.
    private var canGoUp: Bool {
        !diskPath.isEmpty || folderAboveRoot != nil
    }

    private func goUp() {
        if let parent = DiskBankLibrary.parent(of: diskPath) {
            diskPath = parent
        } else if let above = folderAboveRoot {
            library.setFolder(above)
        }
    }

    /// Nazwa folderu, do którego prowadzi „wyżej".
    private var folderAboveName: String {
        if let parent = DiskBankLibrary.parent(of: diskPath) {
            return parent.isEmpty
                ? library.folder?.lastPathComponent ?? ""
                : String(parent.split(separator: "/").last ?? "")
        }
        return folderAboveRoot?.lastPathComponent ?? ""
    }

    /// Pierwszy wiersz listy: wyjście piętro wyżej z nazwą folderu, do którego się wraca.
    private var upRow: some View {
        Button(action: goUp) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.turn.left.up")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(folderAboveName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Up one folder")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            library.setFolder(url)
        }
    }

    private func hint(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }
}

// MARK: - Filtr rodzaju pliku w nagłówku panelu

/// Dwa przełączniki „pch2" / „prf2" w nagłówku panelu Patches (stawia je `PanelBody`).
/// Działają na obie listy — dysk i Norda. Zawsze co najmniej jeden włączony.
struct PatchKindToggles: View {
    let library: DiskBankLibrary

    var body: some View {
        // Ten sam przycisk co Voice / FX w belce (prośba użytkownika 2026-10-12),
        // zapalony kolorem rodzaju pliku jak znaczki w wierszach (2026-10-15).
        HStack(spacing: 4) {
            TopBarSmallButton(
                title: "pch2", width: 44, isOn: library.showsPatches,
                tint: PatchKindBadge.tint(performance: false)
            ) {
                library.toggleKind(performances: false)
            }
            .help("Show patches (.pch2)")
            TopBarSmallButton(
                title: "prf2", width: 44, isOn: library.showsPerformances,
                tint: PatchKindBadge.tint(performance: true)
            ) {
                library.toggleKind(performances: true)
            }
            .help("Show performances (.prf2)")
        }
    }
}

/// Znaczek „pch” / „prf” przy prawej krawędzi wiersza — mniejszy brat zapalonego
/// przełącznika z nagłówka, w tym samym kolorze. Stała szerokość, żeby znaczki stały
/// jedną kolumną.
struct PatchKindBadge: View {
    let isPerformance: Bool

    /// Patch zielony, performance pomarańczowy — kolory kropek kabli w belce
    /// (prośba użytkownika 2026-10-15).
    static func tint(performance: Bool) -> Color {
        (performance ? CableColor.orange : CableColor.green).swatch
    }

    var body: some View {
        let tint = Self.tint(performance: isPerformance)
        Text(isPerformance ? "prf" : "pch")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 26, height: 14)
            .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(tint, lineWidth: 1))
    }
}

// MARK: - Wiersze listy z dysku

/// Zawartość folderu `path`: podfoldery jako grupy rozwijane W MIEJSCU (systemowy
/// trójkąt, zawartość wcięta, dowolnie głęboko — jak lista w Finderze), potem pliki.
/// Osobny widok, bo rekurencja: funkcja zwracająca `some View` nie może wołać samej siebie.
private struct DiskFolderRows: View {
    let library: DiskBankLibrary
    let path: String
    @Binding var expanded: Set<String>
    @Binding var diskPath: String
    let openPath: String?
    let onOpenFile: (URL) -> Void

    var body: some View {
        ForEach(library.subfolders(of: path), id: \.self) { name in
            let child = path.isEmpty ? name : path + "/" + name
            DisclosureGroup(isExpanded: expansion(of: child)) {
                DiskFolderRows(
                    library: library, path: child, expanded: $expanded,
                    diskPath: $diskPath, openPath: openPath, onOpenFile: onOpenFile
                )
            } label: {
                folderRow(name, path: child)
            }
        }
        ForEach(library.files(in: path)) { item in
            DiskFileRow(
                library: library, item: item, showsFolder: false,
                isOpen: item.isFile(atPath: openPath), onOpen: onOpenFile
            )
        }
    }

    private func expansion(of path: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(path) },
            set: { open in
                if open { expanded.insert(path) } else { expanded.remove(path) }
            }
        )
    }

    /// Nazwa folderu — kliknięcie WCHODZI do środka (lista pokazuje wtedy tylko jego
    /// zawartość); rozwijanie w miejscu robi trójkąt obok.
    private func folderRow(_ name: String, path: String) -> some View {
        Button {
            diskPath = path
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(name).font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(library.fileCount(under: path))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open this folder — use the triangle to expand it in place")
    }
}

/// Jeden plik: nazwa, kropki tagów Findera, kategoria, znaczek „pch” / „prf” z prawej,
/// opcjonalnie folder pod spodem (w wynikach szukania, gdzie lista jest płaska). Prawy przycisk: to, co w Finderze —
/// tagi, zmiana nazwy, pokaż w Finderze, do Kosza.
private struct DiskFileRow: View {
    let library: DiskBankLibrary
    let item: DiskBankItem
    let showsFolder: Bool
    /// Ten plik jest właśnie otwarty na canvasie.
    let isOpen: Bool
    let onOpen: (URL) -> Void

    /// Liczba modułów i DSP do dymka — czytane dopiero, gdy kursor stanie nad wierszem
    /// (cały plik trzeba sparsować), i tylko raz.
    @State private var summary: DiskFileSummary?
    @State private var summaryRequested = false

    var body: some View {
        Button {
            onOpen(item.url)
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        // Przy wąskim panelu najpierw skraca się kategoria, potem nazwa.
                        Text(item.name)
                            .font(.system(size: 11, weight: isOpen ? .semibold : .regular))
                            .lineLimit(1)
                            .layoutPriority(1)
                        tagDots
                        if !item.isPerformance, item.category > 0 {
                            Text(G2PatchCategory.name(item.category))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    if showsFolder, !item.relativeFolder.isEmpty {
                        Text(item.relativeFolder)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                PatchKindBadge(isPerformance: item.isPerformance)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { inside in
            guard inside, !summaryRequested else { return }
            summaryRequested = true
            let url = item.url
            Task {
                summary = await Task.detached(priority: .userInitiated) {
                    DiskBankLibrary.summary(of: url)
                }.value
            }
        }
        .contextMenu { menu }
        .listRowBackground(isOpen ? Color.accentColor.opacity(0.22) : nil)
    }

    /// Tagi w kolejności tęczy z menu Findera. Nazwy z listy ulubionych tagów Findera
    /// użytkownika (`FavoriteTagNames`, ta sama kolejność; u użytkownika po polsku:
    /// „Czerwony"…), żeby nadany tu tag był TYM SAMYM tagiem co w Finderze, a nie nowym
    /// „Red" obok „Czerwony" — `NSWorkspace.fileLabels` daje angielskie nazwy nawet na
    /// polskim systemie (sprawdzone 2026-09-16). Ikon w menu nie ma (macOS 15 ich nie
    /// pokazuje) — kolor widać na wierszu zaraz po kliknięciu.
    @ViewBuilder
    private var menu: some View {
        Button("Rename…", action: rename)
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        Section("Tags") {
            ForEach(Self.rainbow, id: \.self) { color in
                let name = Self.tagName(color: color)
                Toggle(name, isOn: tagBinding(color: color, name: name))
            }
        }
        Section {
            Button("Move to Trash", role: .destructive) {
                attempt("The file could not be moved to the Trash.") { try library.trash(item) }
            }
        }
    }

    /// Numery kolorów Findera w kolejności jego menu: czerwony → szary.
    private static let rainbow = [6, 7, 5, 2, 4, 3, 1]

    private static func tagName(color: Int) -> String {
        let rank = FinderTag(name: "", color: color).rainbowRank
        if let favourites = UserDefaults(suiteName: "com.apple.finder")?.stringArray(forKey: "FavoriteTagNames"),
           favourites.count == 8, !favourites[rank + 1].isEmpty
        {
            return favourites[rank + 1]
        }
        let labels = NSWorkspace.shared.fileLabels
        return color < labels.count ? labels[color] : "Tag \(color)"
    }

    private func tagBinding(color: Int, name: String) -> Binding<Bool> {
        Binding(
            get: { item.tags.contains { $0.color == color } },
            set: { on in
                var tags = item.tags.filter { $0.color != color }
                if on { tags.append(FinderTag(name: name, color: color)) }
                attempt("The tags could not be saved.") { try library.setTags(tags, of: item) }
            }
        )
    }

    private func rename() {
        let alert = NSAlert()
        alert.messageText = "Rename \u{201C}\(item.name)\u{201D}"
        alert.informativeText = "The .\(item.url.pathExtension) extension stays."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = item.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        attempt("The file could not be renamed.") { try library.rename(item, to: field.stringValue) }
    }

    private func attempt(_ title: String, _ work: () throws -> Void) {
        do {
            try work()
        } catch {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Kolorowe kropki tagów Findera, nałożone na siebie jak w Finderze. Tag bez koloru
    /// kropki nie ma — jego nazwa jest w podpowiedzi.
    private var tagDots: some View {
        let colors = NSWorkspace.shared.fileLabelColors
        let coloured = item.tags.filter { $0.color > 0 && $0.color < colors.count }
        return HStack(spacing: -3) {
            ForEach(Array(coloured.enumerated()), id: \.offset) { _, tag in
                Circle()
                    .fill(Color(nsColor: colors[tag.color]))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
            }
        }
    }

    /// Najpierw to, co w pliku (kategoria, moduły, DSP), potem tagi i ścieżka.
    private var help: String {
        var lines: [String] = []
        if item.category > 0 {
            lines.append("Category: " + G2PatchCategory.name(item.category))
        }
        lines += summary?.lines ?? []
        if !item.tags.isEmpty {
            lines.append("Tags: " + item.tags.map(\.name).joined(separator: ", "))
        }
        lines.append(item.url.path)
        if isOpen {
            lines.append("Open in the editor — \u{2325}\u{2191} / \u{2325}\u{2193} open the previous / next file")
        }
        return lines.joined(separator: "\n")
    }
}

private extension DiskBankItem {
    /// Porównanie po ścieżce ujednoliconej tak samo jak `openPath` w `BanksPanel`.
    func isFile(atPath path: String?) -> Bool {
        path != nil && url.standardizedFileURL.path == path
    }
}

// MARK: - ⌥↑ / ⌥↓

/// Monitor ⌥↑/⌥↓ dla przeglądarki patchy. Działa w oknie, w którym wysunięta jest
/// szuflada, także gdy klawiaturę ma kanwa — same strzałki zostają kanwie (wartość gałki
/// z focusem), a pływające okna (Mutator: ⌥ + strzałki po drzewie) mają własne okno,
/// więc ich klawiszy ten monitor nie widzi. Pole szukania dostaje ⌥↑/⌥↓ dla siebie.
private struct PatchStepKeys: NSViewRepresentable {
    let step: (_ forward: Bool) -> Void

    func makeNSView(context _: Context) -> PatchStepKeysNSView {
        let view = PatchStepKeysNSView()
        view.step = step
        return view
    }

    func updateNSView(_ view: PatchStepKeysNSView, context _: Context) {
        view.step = step
    }
}

private final class PatchStepKeysNSView: NSView {
    var step: ((_ forward: Bool) -> Void)?
    private var monitor: Any?

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        } else if window == nil, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window,
              event.modifierFlags.intersection([.command, .control, .shift, .option]) == .option,
              let direction = ArrowDirection.from(keyCode: event.keyCode),
              direction == .up || direction == .down,
              !(window.firstResponder is NSText)
        else { return event }
        // Trzymany klawisz nie przewija: każdy krok wysyła do G2 cały patch.
        if !event.isARepeat { step?(direction == .down) }
        return nil
    }
}
