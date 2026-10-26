// BanksPanel.swift
// Zawartość zakładki „Banks" — dwa źródła patchy w jednym miejscu.
//
//   • **Nord** — co siedzi w pamięci urządzenia. Odczyt komendą `0x14`, ładowanie `0x0A`.
//   • **Disk** — folder z plikami `.pch2`/`.prf2`, działa bez podłączonego sprzętu.
//   • **Blocks** — drugi folder, z Building Blocks: ta sama lista co Disk, a wiersz
//     `.pch2` przeciągnięty na kanwę wstawia cały blok → Docs/Plan projektu/08-building-blocks.md
//
// Rozdzielone przełącznikiem, bo to naprawdę dwie różne rzeczy: z Norda ładuje się
// patcha DO SLOTU (urządzenie robi to samo, co PATCH LOAD na froncie), a z dysku
// otwiera się plik W EDYTORZE.

import AppKit
import G2Core
import G2EditorCore
import SwiftUI

// MARK: - Biblioteki folderów

extension DiskBankLibrary {
    /// Folder patchy — panel Patches ▸ Disk i Settings ▸ General.
    static let patches = DiskBankLibrary()
    /// Folder Building Blocks — panel Patches ▸ Blocks i Settings ▸ General.
    static let blocks = DiskBankLibrary(keyPrefix: "g2_blocks")
}

/// Blok przeciągany z listy Blocks na kanwę: w schowku przeciągania ścieżka pliku.
enum BuildingBlockDragData {
    private static let prefix = "g2-building-block:"

    static func string(url: URL) -> String {
        prefix + url.path
    }

    static func parse(_ string: String) -> URL? {
        guard string.hasPrefix(prefix) else { return nil }
        return URL(fileURLWithPath: String(string.dropFirst(prefix.count)))
    }

    /// Blok spod kursora dla ducha na kanwie — czytany raz na przeciąganie, nie przy
    /// każdym ruchu myszy.
    @MainActor
    static func block(at url: URL) -> G2Patch? {
        if let cached, cached.url == url { return cached.block }
        let block = try? PatchParser.parse(url: url).first
        cached = (url, block)
        return block
    }

    @MainActor private static var cached: (url: URL, block: G2Patch?)?
}

/// Upuszczony blok: odczyt pliku i wstawka do slotu z focusem (jedno ⌘Z).
@MainActor
enum BuildingBlockInsert {
    /// Numery nowych modułów obszaru `area`; pusty zbiór, gdy pliku nie da się wczytać
    /// albo użytkownik zrezygnował w okienku przypisań.
    static func insert(_ url: URL, into state: PatchState, area: PatchArea,
                       column: Int, row: Int) -> Set<Int>
    {
        do {
            guard let block = try PatchParser.parse(url: url).first else { return [] }
            let name = url.deletingPathExtension().lastPathComponent
            guard let kinds = chooseAssignments(for: state.patch.blockAssignmentPreview(block), name: name)
            else { return [] }
            return state.insertBlock(block, area: area, column: column, row: row, carrying: kinds)[area] ?? []
        } catch {
            let alert = NSAlert()
            alert.messageText = "The block \u{201C}\(url.deletingPathExtension().lastPathComponent)\u{201D} could not be read."
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return []
        }
    }

    /// File ▸ Insert Patch File… — dowolny `.pch2` jako blok w slocie z focusem: obszar Voice,
    /// lewa krawędź, pod wszystkim, co już tam stoi, więc nic się nie przesuwa. Wstawione
    /// moduły zostają zaznaczone, jak po upuszczeniu.
    static func insertFile(into state: PatchState, selections: CanvasSelectionHub?) {
        let folder = DiskBankLibrary.blocks.folder ?? DiskBankLibrary.patches.folder
        guard let url = FilePanels.openURL(extension: "pch2", directory: folder) else { return }
        let ids = insert(url, into: state, area: .voice, column: 0, row: state.patch.bottomRow(in: .voice))
        guard !ids.isEmpty, let selection = selections?.voice else { return }
        selection.moduleIDs = ids
        selection.activeID = nil
    }
}

extension BuildingBlockInsert {
    /// Pola okienka, klucze, pod którymi pamiętają ostatni wybór, i wybór na start.
    /// Ustawienia patcha i gałki morfów nadpisują to, co patch już ma — stąd na start odznaczone.
    private static let fields: [(kind: G2BlockAssignmentKind, title: String, key: String, initial: Bool)] = [
        (.morphs, "Morphs", "g2_block_carry_morphs", true),
        (.knobs, "Knobs", "g2_block_carry_knobs", true),
        (.midiControllers, "MIDI CC", "g2_block_carry_midi", true),
        (.patchSettings, "Patch settings", "g2_block_carry_settings", false),
        (.morphKnobs, "Morph knobs", "g2_block_carry_morph_knobs", false),
        (.morphNames, "Morph names", "g2_block_carry_morph_names", false),
    ]

    /// Okienko „Morphs / Knobs / MIDI CC / Patch settings / Morph knobs" (decyzja D2): tylko
    /// pola, które blok faktycznie ma — ustawienia i gałki morfów tylko wtedy, gdy różnią się od patcha.
    /// Blok bez przypisań wstawia się bez pytania. `nil` = Cancel, nic się nie wstawia.
    static func chooseAssignments(for preview: G2BlockInsertion, name: String) -> Set<G2BlockAssignmentKind>? {
        let shown = fields.filter { (preview.offered[$0.kind] ?? 0) > 0 }
        guard !shown.isEmpty else { return [] }
        let defaults = UserDefaults.standard

        let boxes = shown.map { field in
            let box = NSButton(checkboxWithTitle: label(field.kind, field.title, preview), target: nil, action: nil)
            box.toolTip = tooltip(field.kind, preview)
            box.state = (defaults.object(forKey: field.key) as? Bool ?? field.initial) ? .on : .off
            return box
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: CGFloat(boxes.count) * 22)

        let alert = NSAlert()
        alert.messageText = "Insert \u{201C}\(name)\u{201D}"
        let replaces = shown.contains { [.patchSettings, .morphKnobs, .morphNames].contains($0.kind) }
        alert.informativeText = "This block has its own assignments and settings. Choose what comes with it."
            + (replaces ? " Patch settings and morphs replace the ones in this patch." : "")
        alert.accessoryView = stack
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        var kinds = Set<G2BlockAssignmentKind>()
        for (field, box) in zip(shown, boxes) {
            defaults.set(box.state == .on, forKey: field.key)
            if box.state == .on { kinds.insert(field.kind) }
        }
        return kinds
    }

    /// „Knobs — 6 (2 already used)", „Patch settings — Glide, Bend Range". Każda linijka musi się
    /// zmieścić w szerokości alertu — dłuższy powód („13 skipped: over the limit of 25 per
    /// variation") ucinał się w aplikacji (2026-10-23), więc pełne wyjaśnienie jest w dymku.
    private static func label(_ kind: G2BlockAssignmentKind, _ title: String, _ preview: G2BlockInsertion) -> String {
        switch kind {
        case .patchSettings:
            return "\(title) \u{2014} \(list(preview.settingNames))"
        case .morphKnobs:
            return "\(title) \u{2014} \(list(preview.morphKnobNames))"
        case .morphNames:
            return "\(title) \u{2014} \(list(preview.morphNames.sorted { $0.key < $1.key }.map(\.value)))"
        case .morphs, .knobs, .midiControllers:
            break
        }
        let offered = preview.offered[kind] ?? 0
        let skipped = preview.skipped[kind] ?? 0
        let unit = kind == .morphs ? (offered == 1 ? " parameter" : " parameters") : ""
        var text = "\(title) \u{2014} \(offered)\(unit)"
        if skipped > 0 {
            text += kind == .morphs ? " (\(skipped) won\u{2019}t fit)" : " (\(skipped) already used)"
        }
        return text
    }

    /// Najwyżej dwie nazwy, reszta jako „+4 more" — pole ma się zmieścić w jednej linijce
    /// alertu (przy trzech „Patch settings" ucinało się w aplikacji). Pełna lista jest w dymku.
    private static func list(_ names: [String]) -> String {
        let shown = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? shown + " +\(names.count - 2) more" : shown
    }

    private static func tooltip(_ kind: G2BlockAssignmentKind, _ preview: G2BlockInsertion) -> String? {
        switch kind {
        case .patchSettings: "Replaces in this patch: " + preview.settingNames.joined(separator: ", ")
        case .morphKnobs: "Knob position and source of: " + preview.morphKnobNames.joined(separator: ", ")
        case .morphNames:
            "Renames morphs in this patch: " + preview.morphNames.sorted { $0.key < $1.key }
                .map { "\(G2Morph.names[$0.key]) \u{2192} \($0.value)" }.joined(separator: ", ")
        case .morphs, .knobs, .midiControllers:
            skippedReason(kind, preview.skipped[kind] ?? 0)
        }
    }

    private static func skippedReason(_ kind: G2BlockAssignmentKind, _ skipped: Int) -> String? {
        guard skipped > 0 else { return nil }
        return switch kind {
        case .morphs: "\(skipped) parameters stay behind: a variation takes at most 25 morphed parameters."
        case .knobs: "\(skipped) knobs stay behind: this patch already uses them."
        case .midiControllers: "\(skipped) CC numbers stay behind: this patch already uses them."
        case .patchSettings, .morphKnobs, .morphNames: nil
        }
    }
}

/// Save Selection as Block… — zaznaczone moduły jako nowy `.pch2` w folderze bloków.
@MainActor
enum BuildingBlockSave {
    static func save(from state: PatchState, area: PatchArea, moduleIDs: Set<Int>) {
        guard let block = state.patch.block(from: area, moduleIDs: moduleIDs),
              let url = FilePanels.saveURL(name: "New Block", extension: "pch2",
                                           directory: DiskBankLibrary.blocks.folder)
        else { return }
        write(block, to: url)
    }

    /// Moduły wyciągnięte z kanwy na listę Blocks: okienko na nazwę, zapis do `folder`.
    static func save(_ block: G2Patch, into folder: URL) {
        let count = block.voiceModules.count + block.fxModules.count
        let alert = NSAlert()
        alert.messageText = "Save as Block"
        alert.informativeText = (count == 1 ? "1 module goes" : "\(count) modules go")
            + " into \u{201C}\(folder.lastPathComponent)\u{201D}."
        let field = NSTextField(string: "New Block")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let name = typed.isEmpty ? "New Block" : typed
        let url = folder.appendingPathComponent(name).appendingPathExtension("pch2")
        if FileManager.default.fileExists(atPath: url.path) {
            let replace = NSAlert()
            replace.messageText = "\u{201C}\(name)\u{201D} already exists. Do you want to replace it?"
            replace.informativeText = "The block in this folder will be overwritten."
            replace.alertStyle = .warning
            replace.addButton(withTitle: "Replace")
            replace.addButton(withTitle: "Cancel")
            guard replace.runModal() == .alertFirstButtonReturn else { return }
        }
        write(block, to: url)
    }

    private static func write(_ block: G2Patch, to url: URL) {
        var block = block
        block.name = url.deletingPathExtension().lastPathComponent
        do {
            let data = try PatchParser.saveAll(originalData: PatchParser.emptyPatchFile, patches: [block])
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = "The block \u{201C}\(block.name)\u{201D} could not be saved."
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        // Nowy plik od razu na liście Blocks, bez ręcznego odświeżania — i podświetlony.
        DiskBankLibrary.blocks.highlightedFile = url
        Task { await DiskBankLibrary.blocks.scan() }
    }
}

/// Moduły wyciągnięte z kanwy na listę Blocks. W schowku przeciągania jest tylko znacznik;
/// sam blok, zrobiony w chwili wyjazdu z kanwy, czeka tutaj.
@MainActor
enum BlockExportDragData {
    private static let prefix = "g2-module-selection:"
    private static var pending: (token: String, block: G2Patch)?

    static func begin(_ block: G2Patch) -> String {
        let token = UUID().uuidString
        pending = (token, block)
        return prefix + token
    }

    static func isExport(_ string: String) -> Bool {
        string.hasPrefix(prefix)
    }

    static func block(for string: String) -> G2Patch? {
        guard let pending, string == prefix + pending.token else { return nil }
        return pending.block
    }

    /// Upuszczenie na listę Blocks albo na jej folder — blok zapisuje się do `folder`.
    static func accept(_ providers: [NSItemProvider], into folder: URL) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { string, _ in
            guard let string = string as? String else { return }
            // Okienko z nazwą dopiero po zakończeniu przeciągania (pętla wraca do trybu
            // `.default`): otwarte w trakcie trzymało sesję przeciągania do swojego zamknięcia,
            // a pierwszy gest na kanwie po zapisie potrafił się nie złapać (sprawdzone 2026-10-23).
            DispatchQueue.main.async {
                RunLoop.main.perform(inModes: [.default]) {
                    MainActor.assumeIsolated {
                        guard let block = block(for: string) else { return }
                        BuildingBlockSave.save(block, into: folder)
                    }
                }
            }
        }
        return true
    }
}

struct BanksPanel: View {
    let state: PatchState
    let device: DeviceConnection
    let library: DiskBankLibrary
    /// Otwarcie pliku idzie tą samą drogą co File → Open, żeby nie było dwóch sposobów
    /// wczytania patcha, które mogą się rozjechać.
    let onOpenFile: (URL) -> Void

    private enum Source: String, CaseIterable {
        case nord = "Nord"
        case disk = "Disk"
        case blocks = "Blocks"
    }

    @AppStorage("g2_banks_source") private var sourceRaw = Source.disk.rawValue
    /// Ten sam przełącznik co miernik pod modułem z palety (View ▸ Show Load When Dragging).
    @AppStorage("g2_show_drag_load") private var showDragLoad: Bool = true
    @State private var query = ""
    /// Folder, po którym właśnie chodzimy — trzyma go biblioteka, żeby przetrwał
    /// ponowne uruchomienie.
    private var diskPath: String {
        get { folderLibrary.currentPath }
        nonmutating set { folderLibrary.currentPath = newValue }
    }

    /// Obciążenie obu obszarów slotu z focusem po wstawieniu bloku: raport Norda, bez niego
    /// szacunek z tabeli kosztów — tak samo jak pasek pod modułem z palety.
    private func blockLoadAfter(_ block: G2Patch) -> (voice: G2PatchLoad?, fx: G2PatchLoad?) {
        let slot = state.selectedSlot
        func load(_ area: PatchArea) -> G2PatchLoad {
            let now = device.patchLoad(slot: slot, area: area)
                ?? .estimate(area: area, modules: state.patch.modules(in: area))
            return now.adding(block.modules(in: area))
        }
        return (load(.voice), load(.fx))
    }

    /// Biblioteka listy folderów: Disk albo Blocks — obie chodzą tym samym kodem.
    private var folderLibrary: DiskBankLibrary {
        source == .blocks ? .blocks : library
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
            case .disk, .blocks: diskList
            }
        }
        .environment(\.blockLoadPreview, showDragLoad ? blockLoadAfter : nil)
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
        if folderLibrary.folder == nil {
            VStack(spacing: 8) {
                Button("Choose folder…", action: chooseFolder)
                Text(source == .blocks
                    ? "Point at a folder of building blocks (.pch2). Drag a block onto the patch to insert it."
                    : "Point at a folder of .pch2 files — subfolders are included.")
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
            .task(id: folderLibrary.folder) {
                await folderLibrary.scan()
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
                let highlightedPath = folderLibrary.highlightedFile?.standardizedFileURL.path
                List(folderLibrary.items(matching: query)) { item in
                    DiskFileRow(
                        library: folderLibrary, item: item, showsFolder: true,
                        isOpen: item.isFile(atPath: openPath), isHighlighted: item.isFile(atPath: highlightedPath),
                        onOpen: onOpenFile, onDropToFolder: source == .blocks ? acceptBlockExport : nil
                    )
                }
                .listStyle(.plain)
                .disabled(!device.acceptsPatchChange)
                .onDrop(of: source == .blocks ? [.text] : [], isTargeted: nil) { acceptBlockExport($0, path: diskPath) }
            } else {
                List {
                    // „Piętro wyżej" jako PIERWSZY WIERSZ listy, nie tylko ikonka w pasku:
                    // wiersz jest szeroki na cały panel i klika się tak samo jak wejście
                    // do folderu — patrz [[Docs/ui/side-panels]].
                    if canGoUp {
                        upRow
                    }
                    DiskFolderRows(
                        library: folderLibrary, path: diskPath, expanded: $expanded,
                        diskPath: Bindable(folderLibrary).currentPath, openPath: openPath, onOpenFile: onOpenFile,
                        onDropToFolder: source == .blocks ? acceptBlockExport : nil
                    )
                }
                .listStyle(.plain)
                .disabled(!device.acceptsPatchChange)
                // Moduły wyciągnięte z kanwy: upuszczone na pusty kawałek listy zapisują się
                // jako blok w oglądanym folderze, na plik — obok niego (także w rozwiniętym
                // podfolderze), na wiersz folderu — w tym folderze (decyzja użytkownika 2026-10-23).
                .onDrop(of: source == .blocks ? [.text] : [], isTargeted: nil) { acceptBlockExport($0, path: diskPath) }
            }
        }
    }

    /// `path` względem folderu bloków; pusty = sam folder bloków.
    private func acceptBlockExport(_ providers: [NSItemProvider], path: String) -> Bool {
        guard source == .blocks, let root = folderLibrary.folder else { return false }
        return BlockExportDragData.accept(providers, into: path.isEmpty ? root : root.appendingPathComponent(path))
    }

    // MARK: - Przesłuchiwanie strzałkami

    /// Pliki w kolejności, w jakiej stoją na ekranie: wyniki szukania albo zawartość
    /// folderu razem z folderami rozwiniętymi w miejscu (ich pliki przed plikami rodzica,
    /// jak w `DiskFolderRows`).
    private var visibleFiles: [DiskBankItem] {
        if isSearching { return folderLibrary.items(matching: query) }
        func files(in path: String) -> [DiskBankItem] {
            let nested = folderLibrary.subfolders(of: path).flatMap { name in
                let child = path.isEmpty ? name : path + "/" + name
                return expanded.contains(child) ? files(in: child) : []
            }
            return nested + folderLibrary.files(in: path)
        }
        return files(in: diskPath)
    }

    /// ⌥↓ otwiera następny plik z listy, ⌥↑ poprzedni — przesłuchiwanie bez klikania.
    /// Bez otwartego pliku z tej listy ⌥↓ zaczyna od pierwszego, ⌥↑ od ostatniego.
    /// Na końcach listy stoi (bez zawijania), żeby nie przeskoczyć niechcący na początek.
    private func stepPatch(forward: Bool) {
        let files = visibleFiles
        // Na liście Blocks nic się nie otwiera — także strzałkami.
        guard source != .blocks, !files.isEmpty, device.acceptsPatchChange else { return }
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
                .help(folderLibrary.folder?.appendingPathComponent(diskPath).path ?? "")

            Spacer(minLength: 4)

            Text(count)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            categoryMenu

            sortMenu

            barButton("arrow.clockwise", help: "Scan the folder again") {
                Task { await folderLibrary.scan() }
            }
            .disabled(folderLibrary.isScanning)

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
            Picker("Sort by", selection: Bindable(folderLibrary).sortOrder) {
                ForEach(DiskBankSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: Bindable(folderLibrary).sortReversed) {
                Text(folderLibrary.sortOrder.directionTitles.natural).tag(false)
                Text(folderLibrary.sortOrder.directionTitles.reversed).tag(true)
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
        .help("Sort by: \(folderLibrary.sortOrder.title), \(sortDirectionTitle)")
    }

    /// Filtr kategorii — pokazuje tylko patche jednej kategorii (Bass, Lead…), w folderze
    /// i w wynikach szukania. Włączony filtr to wypełniona ikonka w kolorze akcentu, żeby
    /// krótsza lista nie wyglądała na zgubione pliki.
    private var categoryMenu: some View {
        let active = folderLibrary.categoryFilter != nil
        return Menu {
            Picker("Category", selection: Bindable(folderLibrary).categoryFilter) {
                Text("All Files").tag(Int?.none)
                Divider()
                ForEach(folderLibrary.availableCategories, id: \.self) { category in
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
        .help(folderLibrary.categoryFilter.map { "Showing only \(G2PatchCategory.name($0)) patches" }
            ?? "Show only patches of one category")
    }

    private var sortDirectionTitle: String {
        let titles = folderLibrary.sortOrder.directionTitles
        return folderLibrary.sortReversed ? titles.reversed : titles.natural
    }

    /// Nazwa miejsca, w którym stoimy: w katalogu głównym nazwa wskazanego folderu,
    /// niżej ścieżka względem niego.
    private var location: String {
        if isSearching { return "All folders" }
        if diskPath.isEmpty { return folderLibrary.folder?.lastPathComponent ?? "" }
        return diskPath
    }

    private var count: String {
        if folderLibrary.isScanning { return "scanning…" }
        if let message = folderLibrary.message { return message }
        return "\(folderLibrary.fileCount(under: isSearching ? "" : diskPath))"
    }

    /// „Wyżej" kończy się na folderze wskazanym w Settings — wyżej nie wychodzi. Od 2026-09-16
    /// do 2026-10-23 wychodziło ponad nim i po cichu przestawiało ten folder w ustawieniach;
    /// użytkownik uznał, że lista ma się trzymać wskazanego folderu (inny = przycisk folderu).
    private var canGoUp: Bool {
        !diskPath.isEmpty
    }

    private func goUp() {
        if let parent = DiskBankLibrary.parent(of: diskPath) {
            diskPath = parent
        }
    }

    /// Nazwa folderu, do którego prowadzi „wyżej".
    private var folderAboveName: String {
        guard let parent = DiskBankLibrary.parent(of: diskPath) else { return "" }
        return parent.isEmpty
            ? folderLibrary.folder?.lastPathComponent ?? ""
            : String(parent.split(separator: "/").last ?? "")
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
            folderLibrary.setFolder(url)
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
    /// Lista Blocks: moduły z kanwy upuszczone na wiersz folderu zapisują się w nim.
    var onDropToFolder: ((_ providers: [NSItemProvider], _ path: String) -> Bool)?
    @State private var targetedFolder: String?

    var body: some View {
        // Podświetlenie czytane raz tutaj, nie w każdym wierszu (#155).
        let highlightedPath = library.highlightedFile?.standardizedFileURL.path
        ForEach(library.subfolders(of: path), id: \.self) { name in
            let child = path.isEmpty ? name : path + "/" + name
            DisclosureGroup(isExpanded: expansion(of: child)) {
                DiskFolderRows(
                    library: library, path: child, expanded: $expanded,
                    diskPath: $diskPath, openPath: openPath, onOpenFile: onOpenFile,
                    onDropToFolder: onDropToFolder
                )
            } label: {
                folderRow(name, path: child)
                    .background(targetedFolder == child ? Color.accentColor.opacity(0.3) : .clear)
                    .onDrop(of: onDropToFolder == nil ? [] : [.text], isTargeted: targeting(child)) {
                        onDropToFolder?($0, child) ?? false
                    }
            }
        }
        ForEach(library.files(in: path)) { item in
            DiskFileRow(
                library: library, item: item, showsFolder: false,
                isOpen: item.isFile(atPath: openPath), isHighlighted: item.isFile(atPath: highlightedPath),
                onOpen: onOpenFile, onDropToFolder: onDropToFolder
            )
        }
    }

    private func targeting(_ path: String) -> Binding<Bool> {
        Binding(
            get: { targetedFolder == path },
            set: { inside in
                if inside { targetedFolder = path } else if targetedFolder == path { targetedFolder = nil }
            }
        )
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
    /// Świeżo zapisany blok (`DiskBankLibrary.highlightedFile`). Podaje go rodzic: wiersz
    /// nie może czytać biblioteki sam — każdy odczyt obserwowanej własności rejestruje
    /// wiersz w SwiftUI, a przy 6 513 wierszach jedno kliknięcie gdziekolwiek w oknie
    /// zajmowało sekundy (#155).
    let isHighlighted: Bool
    let onOpen: (URL) -> Void
    /// Lista Blocks: moduły z kanwy upuszczone na plik zapisują się w jego folderze.
    var onDropToFolder: ((_ providers: [NSItemProvider], _ path: String) -> Bool)?

    /// Liczba modułów i DSP do dymka — czytane dopiero, gdy kursor stanie nad wierszem
    /// (cały plik trzeba sparsować), i tylko raz.
    @State private var summary: DiskFileSummary?
    @State private var summaryRequested = false
    @Environment(\.blockLoadPreview) private var blockLoadPreview

    var body: some View {
        // `row` to if/else: bez opakowania lista nie wie, że to zawsze jeden wiersz, i przy
        // każdej zmianie w oknie liczy wszystkie pliki folderu, nie tylko widoczne — przy
        // 6 513 patchach sekundy kółeczka po każdym kliknięciu (#155).
        HStack(spacing: 0) { row }
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
            .onDrop(of: onDropToFolder == nil ? [] : [.text], isTargeted: nil) {
                onDropToFolder?($0, item.relativeFolder) ?? false
            }
            .listRowBackground(isOpen ? Color.accentColor.opacity(0.22)
                : isHighlighted ? Color.accentColor.opacity(0.12) : nil)
    }

    /// Blok to nie przycisk: przycisk połyka gest przeciągania i blok nie dawał się
    /// wyciągnąć z listy (sprawdzone w aplikacji). Na liście Blocks plik się NIE otwiera —
    /// blok tylko się przeciąga i wstawia (decyzja użytkownika 2026-10-23); otwiera się go
    /// z listy Disk. `.prf2` w folderze bloków nie robi nic: performance'u nie da się wstawić.
    @ViewBuilder
    private var row: some View {
        if isBlock {
            label
                .onDrag {
                    NSItemProvider(object: BuildingBlockDragData.string(url: item.url) as NSString)
                } preview: {
                    BlockDragPreview(name: item.name,
                                     load: BuildingBlockDragData.block(at: item.url).flatMap { blockLoadPreview?($0) })
                }
        } else if inBlocks {
            label
        } else {
            Button {
                onOpen(item.url)
            } label: {
                label
            }
            .buttonStyle(.plain)
        }
    }

    private var label: some View {
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

    /// Wiersz listy Blocks — klik niczego nie otwiera.
    private var inBlocks: Bool {
        library === DiskBankLibrary.blocks
    }

    /// Patch z listy Blocks — przeciągnięty na kanwę wstawia się w całości.
    private var isBlock: Bool {
        inBlocks && !item.isPerformance
    }

    /// Tagi w kolejności tęczy z menu Findera. W menu angielska nazwa koloru (UI po
    /// angielsku), ale do pliku idzie nazwa z listy ulubionych tagów Findera użytkownika
    /// (`FavoriteTagNames`, ta sama kolejność; u użytkownika po polsku: „Czerwony"…), żeby
    /// nadany tu tag był TYM SAMYM tagiem co w Finderze, a nie nowym „Red" obok
    /// „Czerwony" — `NSWorkspace.fileLabels` daje angielskie nazwy nawet na polskim
    /// systemie (sprawdzone 2026-09-16). Przy nazwie kolorowa kropka jak w Finderze.
    @ViewBuilder
    private var menu: some View {
        Button("Rename…", action: rename)
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        Section("Tags") {
            ForEach(Self.rainbow, id: \.self) { color in
                Toggle(isOn: tagBinding(color: color, name: Self.tagName(color: color))) {
                    Label {
                        Text(FinderTag.colorNames[color])
                    } icon: {
                        Image(nsImage: Self.menuDot(color: color))
                    }
                    .labelStyle(.titleAndIcon)
                }
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

    /// Kropka koloru tagu do menu — gotowy obrazek, nie symbol SF: menu macOS rysuje
    /// symbole jednym kolorem tekstu, a obrazek z `isTemplate = false` zostaje kolorowy.
    private static func menuDot(color: Int) -> NSImage {
        let fill = NSWorkspace.shared.fileLabelColors[color]
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

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

    /// Tag koloru o nazwie z Findera („Czerwony") pokazany po angielsku; tag z własną
    /// nazwą użytkownika — pod tą nazwą.
    private static func displayName(_ tag: FinderTag) -> String {
        tag.colorName.isEmpty || tag.name != tagName(color: tag.color) ? tag.name : tag.colorName
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
            lines.append("Tags: " + item.tags.map(Self.displayName).joined(separator: ", "))
        }
        lines.append(item.url.path)
        if isBlock {
            lines.append("Drag onto the patch to insert this block")
        } else if inBlocks {
            lines.append("A performance can\u{2019}t be inserted as a block \u{2014} open it from Disk")
        }
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
