// PluginBridge.swift
// Most dla wtyczek DAW — strona edytora (plan: Docs/Plan projektu/05-wtyczka-daw.md, Etap 2).
//
// Wtyczka jest pilotem jednego slotu — albo, w trybie Performance (Multi-timbral w DAW-ie),
// wszystkich czterech: zajmuje je (`claim`), pobiera i odsyła patche, a edytor sam mówi jej,
// kiedy slot się zmienił. USB zostaje w edytorze. Most jest
// publiczny (w odróżnieniu od mostu Claude'a) — opis protokołu: Docs/Plan projektu/05-wtyczka-most.md.

import Foundation
import G2Core
import Observation

@MainActor
@Observable
public final class PluginBridge {
    public typealias ConnectionID = PluginBridgeServer.ConnectionID

    public static let protocolVersion = 1

    public struct Client: Equatable {
        public var name: String
        public var format: String
        public var host: String
        /// Zajęte sloty (0 = A): jeden w trybie Slot, cztery w trybie Performance.
        public var slots: [Int] = []
        /// Tryb Performance: kanał MIDI nuty wybiera slot (1 → A … 4 → D).
        public var performance = false
        /// Pytania Etapu 3, które wtyczka zgłasza, bo jej okno jest zamknięte (`questions`).
        public var questions: [Question] = []
    }

    /// Patch zapisany w piosence różni się od tego, co gra G2 (Etap 3). Wtyczka pyta w swoim
    /// oknie; gdy okno jest zamknięte, pyta przez edytor — odpowiedź wraca jako `answer`.
    public struct Question: Equatable {
        public var slot: Int
        public var song: String
        public var g2: String
    }

    /// Przywitane wtyczki. Obserwowane — edytor liczy po nich, czy ktoś go jeszcze potrzebuje.
    public private(set) var clients: [ConnectionID: Client] = [:]

    @ObservationIgnored public weak var state: PatchState? {
        didSet { watch() }
    }

    @ObservationIgnored public weak var device: DeviceConnection? {
        didSet { watch() }
    }

    /// Nazwa, którą wtyczka pokazuje przy zielonej kropce.
    @ObservationIgnored public var editorName = "G2 Editor"
    /// „Open in Editor" we wtyczce: pokaż okno edytora uruchomionego w tle.
    @ObservationIgnored public var onShowEditor: (() -> Void)?
    /// Drugi edytor prosi ten o ustąpienie. `true` = ten się zamyka (był tylko w tle).
    @ObservationIgnored public var onQuitRequest: (() -> Bool)?

    @ObservationIgnored private let server: PluginBridgeServer
    /// Wersje slotów, które dana wtyczka ostatnio od nas dostała — powiadamiamy tylko o różnicy.
    @ObservationIgnored private var sentVersions: [ConnectionID: [Int: String]] = [:]
    @ObservationIgnored private var sentDevice: [String: String]?
    /// Wtyczki czekające na slot: odmówiono im (`slot_taken`) albo go im odebrano (`taken_over`).
    /// Tylko one słyszą o zwolnionych slotach.
    @ObservationIgnored private var waiting = Set<ConnectionID>()
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    /// Lista automatyki (`PluginAutomation`), którą dana wtyczka ostatnio od nas dostała, slot po
    /// slocie — wysyłamy tylko różnice. Brak slotu = jeszcze nic nie dostała (wyślemy całość).
    @ObservationIgnored private var sentAutomation: [ConnectionID: [Int: [Int: PluginAutomation.Entry]]] = [:]
    @ObservationIgnored private var automationTask: Task<Void, Never>?
    /// Parametry przypisane ruchem (Learn), slot po slocie: numer listy 300…331 → parametr.
    /// Mapa należy do piosenki — trzyma ją wtyczka i przysyła po zajęciu slotu (`learn_map`).
    @ObservationIgnored private var learnMaps: [ConnectionID: [Int: [Int: G2KnobAssignment]]] = [:]
    /// Wtyczki w trybie Learn: stan slotów z chwili włączenia — pierwszy parametr, który się
    /// od niego oddali, zostaje przypisany (`learned`).
    @ObservationIgnored private var learning: [ConnectionID: [Int: G2Patch]] = [:]
    /// Sekwencery slotów (Etap 5, ołówek w oknie wtyczki), które wtyczka ostatnio dostała.
    @ObservationIgnored private var sentSequencers: [ConnectionID: [Int: [PluginSequencers.Sequencer]]] = [:]
    /// Strona parametrów (ekraniki, gałki, przyciski), którą wtyczka ostatnio dostała, slot po slocie.
    @ObservationIgnored private var sentPages: [ConnectionID: [Int: PluginPages.Page]] = [:]
    /// Ekranik wtyczki (nazwa, kategoria, miejsce w banku), który wtyczka ostatnio dostała.
    @ObservationIgnored private var sentDisplays: [ConnectionID: [Int: [String: String]]] = [:]
    /// Skąd wtyczka ostatnio wgrała patch do slotu (adres banku G2 albo ścieżka) i pod jaką nazwą —
    /// ekranik pokazuje to miejsce, dopóki slot ma ten patch.
    @ObservationIgnored private var loadedFrom: [Int: (address: String, name: String)] = [:]
    /// Pliki folderu z panelu Banks dla przeglądarki wtyczek (Etap 6b) i kiedy je przeczytano.
    @ObservationIgnored private var browserLibrary: DiskBankLibrary?
    @ObservationIgnored private var browserScanned: Date?
    /// Po tylu sekundach przeglądarka czyta folder od nowa — nowe pliki pojawiają się same.
    static let browserRescan: TimeInterval = 60
    /// Skąd przeglądarka bierze folder panelu Banks — w testach osobne ustawienia.
    @ObservationIgnored var browserDefaults = UserDefaults.standard
    /// Co najwyżej 50 paczek automatyki na sekundę — nagrywanie ruchu gałki w DAW-ie nie
    /// potrzebuje gęściej, a każda paczka to przeliczenie 120 gałek.
    @ObservationIgnored static let automationInterval: UInt64 = 20_000_000

    public init(path: String = PluginBridge.defaultSocketPath) {
        server = PluginBridgeServer(path: path)
        server.onLine = { [weak self] id, line in
            Task { @MainActor in self?.handle(id, line) }
        }
        server.onDisconnect = { [weak self] id in
            Task { @MainActor in self?.disconnected(id) }
        }
    }

    /// `~/Library/Application Support/G2Editor/plugin.sock` — tę samą ścieżkę składa wtyczka.
    public nonisolated static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/G2Editor/plugin.sock").path
    }

    public func start() throws {
        let directory = URL(fileURLWithPath: server.path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try server.start()
    }

    public func stop() {
        server.stop()
        checkTask?.cancel()
        checkTask = nil
        automationTask?.cancel()
        automationTask = nil
    }

    // MARK: - Polecenia

    struct Refusal: Error {
        let code: String
        let message: String
    }

    func handle(_ id: ConnectionID, _ line: String) {
        guard let data = line.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = message["type"] as? String
        else {
            send(["type": "error", "code": "bad_request", "message": "not a JSON object with a \"type\" field"], to: id)
            return
        }
        var reply: [String: Any]
        do {
            if type != "hello", clients[id] == nil {
                throw Refusal(code: "hello_first", message: "say hello first")
            }
            switch type {
            case "hello": reply = hello(id, message)
            case "claim": reply = try claim(id, message)
            case "release": reply = release(id)
            case "get_slot": reply = try getSlot(message)
            case "put_slot": reply = try putSlot(id, message)
            case "notes":
                // Bez odpowiedzi: nuty idą strumieniem, potwierdzenie tylko by je spowalniało.
                playNotes(id, message)
                return
            case "panic":
                // Bez odpowiedzi, jak nuty.
                if let slots = clients[id]?.slots {
                    for slot in slots { device?.panic(slot: slot) }
                }
                return
            case "automate":
                // Też bez odpowiedzi — nowy stan wraca zwykłą drogą, paczką `automation`.
                automate(id, message)
                return
            case "seq_draw":
                // Bez odpowiedzi — nowy stan wraca paczką `sequencers`.
                drawSequencer(id, message)
                return
            case "pages_select", "pages_global", "pages_knob", "pages_button":
                // Bez odpowiedzi — nowa strona wraca paczką `pages`.
                changePages(id, type, message)
                return
            case "browse":
                // Czytanie folderu trwa — odpowiedź przyjdzie osobno, z tym samym `id`.
                browse(id, message)
                return
            case "navigate":
                // Jak `browse`: lista banków albo folderu może się jeszcze czytać.
                navigate(id, message)
                return
            case "patch_info":
                reply = try patchInfo(message)
            case "load_patch":
                reply = try loadPatch(id, message)
            case "transport":
                // Bez odpowiedzi — przychodzi przy każdej zmianie tempa albo Play/Stop w DAW-ie.
                followTransport(id, message)
                return
            case "learn_map":
                reply = try learnMap(id, message)
            case "learn":
                reply = learn(id, message)
            case "questions":
                clients[id]?.questions = Self.questions(message)
                reply = ["type": "noted"]
            case "show_editor":
                onShowEditor?()
                reply = ["type": "shown"]
            case "quit_if_background":
                guard onQuitRequest?() == true else {
                    throw Refusal(code: "editor_in_use", message: "the running editor has its window open")
                }
                reply = ["type": "quitting"]
            default:
                throw Refusal(code: "unknown_type", message: "unknown message type \"\(type)\"")
            }
        } catch let refusal as Refusal {
            reply = ["type": "error", "code": refusal.code, "message": refusal.message]
        } catch {
            reply = ["type": "error", "code": "failed", "message": "\(error)"]
        }
        if let requestID = message["id"] { reply["id"] = requestID }
        send(reply, to: id)
    }

    private func hello(_ id: ConnectionID, _ message: [String: Any]) -> [String: Any] {
        clients[id] = Client(name: message["client"] as? String ?? "plugin",
                             format: message["format"] as? String ?? "",
                             host: message["host"] as? String ?? "",
                             slots: clients[id]?.slots ?? [], performance: clients[id]?.performance ?? false)
        let device = deviceInfo()
        // Stan urządzenia jedzie w powitaniu — pierwsze sprawdzenie zmian nie powtarza go.
        if sentDevice == nil { sentDevice = device }
        return ["type": "hello", "protocol": Self.protocolVersion, "editor": editorName, "device": device]
    }

    /// Slot może trzymać tylko jedna wtyczka — druga na tym samym slocie biłaby się z pierwszą
    /// o patch i automatykę. Zajęcie innego slotu zwalnia poprzedni. `performance: true` zajmuje
    /// wszystkie cztery (jedna instancja na ścieżce Multi-timbral) — tylko gdy żaden nie jest zajęty.
    ///
    /// `take: true` — „Make this one active" (Etap 3, 05-wtyczka-funkcje §2.6): poprzedni
    /// właściciel oddaje WSZYSTKIE swoje sloty, dostaje `taken_over` i czeka, aż któryś się
    /// zwolni (`slots_free`). Jedna aktywna wtyczka na slot, reszta cicha.
    private func claim(_ id: ConnectionID, _ message: [String: Any]) throws -> [String: Any] {
        let performance = message["performance"] as? Bool == true
        let wanted = try performance ? Array(0 ..< 4) : [Self.slot(message)]
        let takeOver = message["take"] as? Bool == true
        var losers: [ConnectionID] = []
        for slot in wanted {
            if let (ownerID, owner) = clients.first(where: { $0.key != id && $0.value.slots.contains(slot) }) {
                guard takeOver else {
                    waiting.insert(id)
                    throw Refusal(code: "slot_taken",
                                  message: "Slot \(Self.letter(slot)) is already used by \(Self.who(owner))")
                }
                if !losers.contains(ownerID) { losers.append(ownerID) }
            }
        }
        let taker = clients[id].map(Self.who) ?? "another plugin"
        for loser in losers {
            let lost = clients[loser]?.slots ?? []
            device?.clearDawNotes(slots: lost)
            clients[loser]?.slots = []
            clients[loser]?.performance = false
            sentVersions[loser] = nil
            sentAutomation[loser] = nil
            sentSequencers[loser] = nil
            sentPages[loser] = nil
            sentDisplays[loser] = nil
            learning[loser] = nil
            waiting.insert(loser)
            send(["type": "taken_over", "slots": lost.map(Self.letter),
                  "message": "\(Self.slotList(lost)) now used by \(taker)"], to: loser)
        }
        let freed = (clients[id]?.slots ?? []).filter { !wanted.contains($0) }
        waiting.remove(id)
        clients[id]?.slots = wanted
        clients[id]?.performance = performance
        announceFree(freed)
        let infos = wanted.map(slotInfo)
        sentVersions[id] = Dictionary(uniqueKeysWithValues: zip(wanted, infos.map { $0["version"] as? String ?? "" }))
        // Pełna lista automatyki i sekwencery pójdą zaraz po odpowiedzi na zajęcie.
        sentAutomation[id] = nil
        sentSequencers[id] = nil
        sentPages[id] = nil
        sentDisplays[id] = nil
        scheduleAutomation()
        if performance {
            return ["type": "claimed", "performance": true, "slots": infos]
        }
        return infos[0].merging(["type": "claimed"]) { $1 }
    }

    private func release(_ id: ConnectionID) -> [String: Any] {
        let freed = clients[id]?.slots ?? []
        device?.clearDawNotes(slots: freed)
        clients[id]?.slots = []
        clients[id]?.performance = false
        sentVersions[id] = nil
        sentAutomation[id] = nil
        sentSequencers[id] = nil
        sentPages[id] = nil
        sentDisplays[id] = nil
        learning[id] = nil
        waiting.remove(id)
        announceFree(freed)
        return ["type": "released"]
    }

    /// Odpowiedź użytkownika z edytora na pytania wtyczki: `send` = patch(e) piosenki do G2,
    /// inaczej piosenka przyjmuje to, co gra G2. Wtyczka zrobi to sama, jak z własnego okna.
    public func answer(_ id: ConnectionID, sendSongPatch: Bool) {
        guard clients[id]?.questions.isEmpty == false else { return }
        clients[id]?.questions = []
        send(["type": "answer", "send": sendSongPatch], to: id)
    }

    static func questions(_ message: [String: Any]) -> [Question] {
        let list = message["questions"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let letter = item["slot"] as? String,
                  let slot = ["A", "B", "C", "D"].firstIndex(of: letter) else { return nil }
            return Question(slot: slot, song: item["song"] as? String ?? "", g2: item["g2"] as? String ?? "")
        }
    }

    /// „G2 VST in Logic Pro" — nagłówek pytania w edytorze.
    public static func title(of client: Client) -> String {
        who(client)
    }

    /// Zwolnione sloty — wtyczkom, które czekają. Same zajmą swój slot z powrotem, jeśli jest
    /// wśród wolnych.
    private func announceFree(_ slots: [Int]) {
        guard !slots.isEmpty else { return }
        for other in waiting where clients[other] != nil {
            send(["type": "slots_free", "slots": slots.sorted().map(Self.letter)], to: other)
        }
    }

    /// „G2 VST in Logic Pro" — kto trzyma slot, w komunikatach dla użytkownika.
    private static func who(_ client: Client) -> String {
        client.host.isEmpty ? client.name : "\(client.name) in \(client.host)"
    }

    private static func slotList(_ slots: [Int]) -> String {
        slots.count == 1 ? "Slot \(letter(slots[0])) is" : "Slots \(slots.map(letter).joined(separator: ", ")) are"
    }

    private func getSlot(_ message: [String: Any]) throws -> [String: Any] {
        let slot = try Self.slot(message)
        let patch = try existingPatch(slot)
        return try ["type": "slot", "slot": Self.letter(slot), "name": patch.name,
                    "version": SlotFingerprint.version(of: patch),
                    "patch": SlotFingerprint.patchFile(patch).base64EncodedString()]
    }

    /// Cały patch do slotu jako jeden krok Undo — i dalej do Norda istniejącą drogą
    /// (`onLiveStructureChange`). Pisać wolno tylko do własnego slotu. `expect_version`
    /// chroni zmianę zrobioną w edytorze, której wtyczka jeszcze nie widziała.
    private func putSlot(_ id: ConnectionID, _ message: [String: Any]) throws -> [String: Any] {
        let slot = try Self.slot(message)
        guard clients[id]?.slots.contains(slot) == true else {
            throw Refusal(code: "claim_first", message: "claim slot \(Self.letter(slot)) before writing to it")
        }
        guard let state else { throw Refusal(code: "no_slot", message: "the editor has no document yet") }
        let current = try SlotFingerprint.version(of: existingPatch(slot))
        if let expected = message["expect_version"] as? String {
            guard expected == current else {
                throw Refusal(code: "version_changed", message: "slot \(Self.letter(slot)) changed in the editor")
            }
        } else if message["replace"] as? Bool != true {
            throw Refusal(code: "bad_request", message: "pass expect_version or replace: true")
        }
        guard let base64 = message["patch"] as? String, let data = Data(base64Encoded: base64),
              var patch = try? PatchParser.parseFile(data: data).patches.first
        else {
            throw Refusal(code: "bad_patch", message: "\"patch\" must be base64 of a .pch2 file")
        }
        patch.fillMissingParameters()
        // Plik `.pch2` nie ma pola na nazwę patcha — przychodzi obok.
        if let name = message["name"] as? String {
            patch.name = String(name.prefix(G2PatchName.maxLength))
        }
        let host = clients[id]?.host ?? ""
        state.replaceSlot(slot: slot, patch: patch, actionName: host.isEmpty ? "Patch from Plugin" : "Patch from \(host)")
        let version = SlotFingerprint.version(of: state.slots[slot])
        sentVersions[id, default: [:]][slot] = version
        return ["type": "stored", "slot": Self.letter(slot), "version": version]
    }

    /// Nuty z DAW-a → sloty tej wtyczki (droga: `DeviceConnection.playNotes`). Grać może tylko
    /// wtyczka, która trzyma slot; czekająca jest cicha.
    private func playNotes(_ id: ConnectionID, _ message: [String: Any]) {
        guard let client = clients[id], let device, let events = message["events"] as? [[Int]] else { return }
        for (slot, notes) in Self.route(events, client: client) {
            device.playNotes(notes, slot: slot)
        }
    }

    /// Automatyka z DAW-a: `values` = `[[slot, id, value], …]` albo — przy jednym slocie —
    /// `slot` obok i `[[id, value], …]`. Tylko do slotów tej wtyczki; czekająca jest cicha.
    private func automate(_ id: ConnectionID, _ message: [String: Any]) {
        guard let client = clients[id], let state, state.isLoaded,
              let values = message["values"] as? [[Any]] else { return }
        let slot = try? Self.slot(message)
        for item in values {
            let numbers = item.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard numbers.count == item.count else { continue }
            let (target, parameter, value): (Int?, Int, Double) = switch numbers.count {
            case 2: (slot, Int(numbers[0]), numbers[1])
            case 3: (Int(numbers[0]), Int(numbers[1]), numbers[2])
            default: (nil, -1, 0)
            }
            guard let target, client.slots.contains(target) else { continue }
            PluginAutomation.apply(state, slot: target, id: parameter, value: value,
                                   learn: learnMaps[id]?[target] ?? [:])
            // Ruch z DAW-a to nie ruch ręki — Learn go nie przypisuje.
            if learning[id]?[target] != nil { learning[id]?[target] = state.slots[target] }
        }
    }

    /// Ołówek w oknie wtyczki: `seq_draw {slot, gesture, values: [[location, module, param, value], …]}`.
    /// `gesture` begin/end skleja jedno pociągnięcie w jeden krok Undo. To zwykła edycja patcha.
    private func drawSequencer(_ id: ConnectionID, _ message: [String: Any]) {
        guard let client = clients[id], let state, let slot = try? Self.slot(message),
              client.slots.contains(slot) else { return }
        let gesture = message["gesture"] as? String
        if gesture == "begin" { state.beginParameterGesture() }
        for item in message["values"] as? [[Int]] ?? [] where item.count == 4 {
            PluginSequencers.draw(state, slot: slot, location: item[0], moduleID: item[1], param: item[2],
                                  value: item[3])
        }
        if gesture == "end" { state.endParameterGesture() }
    }

    /// Strony parametrów z okna wtyczki: `pages_select {page}` i `pages_global {on}` — to samo co
    /// wybór w oknie Parameter Pages edytora (idzie też do Norda); `pages_knob {knob, value, gesture}`
    /// — gałka Global Pages (0…1, zwykła edycja, begin/end = jeden krok Undo); `pages_button {slot, knob}`
    /// — przycisk pod gałką. Parametry tylko w slotach tej wtyczki.
    private func changePages(_ id: ConnectionID, _ type: String, _ message: [String: Any]) {
        guard let owned = clients[id]?.slots, !owned.isEmpty, let state, state.isLoaded else { return }
        switch type {
        case "pages_select":
            guard let page = message["page"] as? Int, (0 ..< G2KnobPages.pageCount).contains(page) else { return }
            state.focusedParameterPage = page
        case "pages_global":
            guard let on = message["on"] as? Bool else { return }
            state.showsGlobalParameterPages = on
        case "pages_knob":
            guard let knob = message["knob"] as? Int, let value = (message["value"] as? NSNumber)?.doubleValue,
                  value.isFinite else { return }
            let gesture = message["gesture"] as? String
            if gesture == "begin" { state.beginParameterGesture() }
            PluginPages.setGlobalKnob(state, knob: knob, value: value, owned: Set(owned))
            if gesture == "end" { state.endParameterGesture() }
        default:
            guard let slot = try? Self.slot(message), let knob = message["knob"] as? Int else { return }
            PluginPages.pressButton(state, slot: slot, knob: knob, owned: Set(owned))
        }
    }

    // MARK: - Przeglądarka patchy (Etap 6b)

    /// `browse {id, query, group?}` → `browse_result {id, folder, groups, items: [[path, name, folder,
    /// tagColor], …], total, message?}`. Folder z panelu Banks; bez niego — komunikat, co zrobić.
    /// `groups` = podfoldery (banki G2: kategorie) do kolumny filtra, `group` wybiera jeden.
    private func browse(_ id: ConnectionID, _ message: [String: Any]) {
        let query = message["query"] as? String ?? ""
        let group = message["group"] as? String
        let requestID = message["id"]
        if message["source"] as? String == "g2" {
            browseBanks(id, query: query, group: group, requestID: requestID)
            return
        }
        Task { @MainActor in
            var reply: [String: Any] = ["type": "browse_result"]
            if let requestID { reply["id"] = requestID }
            guard let (library, path) = await diskLibrary() else {
                reply["items"] = [[Any]]()
                reply["total"] = 0
                reply["message"] = Self.noFolder
                send(reply, to: id)
                return
            }
            let found = PluginBrowser.search(library.items, query: query, group: group)
            reply["folder"] = URL(fileURLWithPath: path).lastPathComponent
            reply["groups"] = PluginBrowser.groups(library.items)
            reply["items"] = found.prefix(PluginBrowser.resultLimit).map(PluginBrowser.json)
            reply["total"] = found.count
            if let note = library.message { reply["message"] = note }
            send(reply, to: id)
        }
    }

    static let noFolder = "Choose a patch folder in the editor: Banks ▸ Disk"

    /// Folder panelu Banks, przeczytany (i co minutę czytany od nowa). `nil` = nie wybrano folderu.
    private func diskLibrary() async -> (DiskBankLibrary, String)? {
        guard let path = DiskBankLibrary.savedFolderPath(defaults: browserDefaults) else { return nil }
        if browserLibrary?.folder?.path != path {
            browserLibrary = DiskBankLibrary(defaults: browserDefaults)
            browserScanned = nil
        }
        guard let library = browserLibrary else { return nil }
        if browserScanned.map({ Date().timeIntervalSince($0) > Self.browserRescan }) ?? true {
            await library.scan()
            browserScanned = Date()
        }
        return (library, path)
    }

    /// Navigator: `navigate {id, slot, source: "g2"|"disk", sort: "place"|"name", from?, step, group}`
    /// → `navigated {id, path, name, category, location}` — następny patch do pokazania na ekraniku,
    /// bez wgrywania (wgrywa `load_patch`). Bez `from` liczy od patcha, który slot ma teraz.
    /// Pusta lista → `navigated {id, message}`.
    private func navigate(_ id: ConnectionID, _ message: [String: Any]) {
        let requestID = message["id"]
        let slot = (try? Self.slot(message)) ?? 0
        let sort = PluginNavigator.Sort(rawValue: message["sort"] as? String ?? "") ?? .place
        let step = message["step"] as? Int ?? 1
        let group = message["group"] as? Bool == true
        let from = message["from"] as? String
        Task { @MainActor in
            var reply: [String: Any] = ["type": "navigated"]
            if let requestID { reply["id"] = requestID }
            let items: [PluginNavigator.Item]
            if message["source"] as? String == "disk" {
                guard let (library, _) = await diskLibrary() else {
                    reply["message"] = Self.noFolder
                    send(reply, to: id)
                    return
                }
                items = PluginNavigator.items(library.items, sort: sort)
            } else {
                guard let device, device.status == .connected else {
                    reply["message"] = "No G2 is connected to the editor"
                    send(reply, to: id)
                    return
                }
                if device.bankEntries.isEmpty { await device.refreshBankList() }
                items = PluginNavigator.items(device.bankEntries, sort: sort)
            }
            let start = from ?? currentAddress(slot: slot, in: items)
            guard var item = PluginNavigator.step(items, from: start, by: step, group: group) else {
                reply["message"] = message["source"] as? String == "disk"
                    ? "No patches in the editor's patch folder" : "The G2's banks have no patches"
                send(reply, to: id)
                return
            }
            // Dysk: kategorię zna dopiero plik — czytamy tylko ten jeden.
            if item.category.isEmpty, let patch = try? PluginBrowser.patch(at: URL(fileURLWithPath: item.address)) {
                item.category = PluginBrowser.categoryName(patch.description.category)
            }
            send(reply.merging(item.json) { $1 }, to: id)
        }
    }

    /// Adres patcha, który slot ma teraz: to, co wtyczka tam wgrała, a bez tego — miejsce
    /// w liście o tej samej nazwie.
    private func currentAddress(slot: Int, in items: [PluginNavigator.Item]) -> String? {
        guard let state, state.slots.indices.contains(slot) else { return nil }
        let name = state.slots[slot].name
        if let loaded = loadedFrom[slot], loaded.name == name, items.contains(where: { $0.address == loaded.address }) {
            return loaded.address
        }
        return items.first { $0.name == name }?.address
    }

    /// Banki G2 (`source: "g2"`): lista z urządzenia, czytana przy pierwszym szukaniu (trwa kilka
    /// sekund i wstrzymuje wskaźniki — tak samo jak w panelu Banks).
    private func browseBanks(_ id: ConnectionID, query: String, group: String?, requestID: Any?) {
        Task { @MainActor in
            var reply: [String: Any] = ["type": "browse_result", "folder": "G2 banks"]
            if let requestID { reply["id"] = requestID }
            guard let device, device.status == .connected else {
                reply["items"] = [[Any]]()
                reply["total"] = 0
                reply["message"] = "No G2 is connected to the editor"
                send(reply, to: id)
                return
            }
            if device.bankEntries.isEmpty { await device.refreshBankList() }
            let found = PluginBrowser.search(device.bankEntries, query: query, group: group)
            reply["groups"] = PluginBrowser.groups(device.bankEntries)
            reply["items"] = found.prefix(PluginBrowser.resultLimit).map(PluginBrowser.json)
            reply["total"] = found.count
            if device.bankEntries.isEmpty { reply["message"] = "The G2 did not send its banks" }
            send(reply, to: id)
        }
    }

    /// `patch_info {path}` → kategoria, liczba modułów, obciążenie DSP głosów i efektów.
    /// Miejsce w banku G2 (`g2:…`) — tylko nazwa, kategoria i numer.
    private func patchInfo(_ message: [String: Any]) throws -> [String: Any] {
        guard let path = message["path"] as? String else {
            throw Refusal(code: "bad_request", message: "pass \"path\"")
        }
        if path.hasPrefix("g2:") {
            guard let entry = PluginBrowser.entry(address: path, in: device?.bankEntries ?? []) else {
                throw Refusal(code: "bad_patch", message: "that bank place is empty")
            }
            return PluginBrowser.info(entry).merging(["type": "patch_info", "path": path]) { $1 }
        }
        do {
            let patch = try PluginBrowser.patch(at: URL(fileURLWithPath: path))
            return PluginBrowser.info(patch).merging(["type": "patch_info", "path": path]) { $1 }
        } catch {
            throw Refusal(code: "bad_patch", message: "cannot read \(URL(fileURLWithPath: path).lastPathComponent)")
        }
    }

    /// `load_patch {slot, path}` — patch z przeglądarki do slotu wtyczki, jeden krok Undo
    /// „Load Patch from <host>", do Norda istniejącą drogą. Piosenka dowie się zwykłym
    /// `slot_changed` i przyjmie nowy patch (Etap 3).
    private func loadPatch(_ id: ConnectionID, _ message: [String: Any]) throws -> [String: Any] {
        let slot = try Self.slot(message)
        guard clients[id]?.slots.contains(slot) == true else {
            throw Refusal(code: "claim_first", message: "claim slot \(Self.letter(slot)) before loading into it")
        }
        guard let state, state.slots.indices.contains(slot) else {
            throw Refusal(code: "no_slot", message: "the editor has no document yet")
        }
        // Z banku G2 ładuje samo urządzenie (`0x0A`) i ogłasza zmianę — edytor idzie za nim.
        if let path = message["path"] as? String, path.hasPrefix("g2:") {
            guard let device, let entry = PluginBrowser.entry(address: path, in: device.bankEntries) else {
                throw Refusal(code: "bad_patch", message: "that bank place is empty")
            }
            Task { await device.loadFromBank(entry, intoSlot: slot) }
            loadedFrom[slot] = (path, entry.name)
            return ["type": "loaded", "slot": Self.letter(slot), "name": entry.name]
        }
        guard let path = message["path"] as? String, path.lowercased().hasSuffix(".pch2"),
              let patch = try? PluginBrowser.patch(at: URL(fileURLWithPath: path))
        else {
            throw Refusal(code: "bad_patch", message: "not a readable .pch2 file")
        }
        let host = clients[id]?.host ?? ""
        state.replaceSlot(slot: slot, patch: patch,
                          actionName: host.isEmpty ? "Load Patch from Plugin" : "Load Patch from \(host)")
        loadedFrom[slot] = (path, patch.name)
        return ["type": "loaded", "slot": Self.letter(slot), "name": patch.name]
    }

    /// Etap 6a: tempo i Play/Stop DAW-a prowadzą zegar G2 (`transport {bpm, playing}`). Tylko od
    /// wtyczki, która trzyma slot; wysyłamy tylko to, co się różni od stanu Norda — kilka ścieżek
    /// z wtyczką przysyła to samo. Zegar zewnętrzny (MIDI) blokuje tempo, jak pasek edytora.
    private func followTransport(_ id: ConnectionID, _ message: [String: Any]) {
        guard clients[id]?.slots.isEmpty == false, let device, device.status == .connected else { return }
        if let bpm = message["bpm"] as? Int, device.clockBPM != G2UsbProtocol.clampedBPM(bpm) {
            Task { await device.setMasterClock(bpm) }
        }
        if let playing = message["playing"] as? Bool, device.clockRunning != playing {
            Task { await device.setClockRunning(playing) }
        }
    }

    /// Mapa Learn jednego slotu: `learn_map {slot, map: [[id, location, module, param], …]}`.
    /// Cała naraz — wtyczka przysyła ją po zajęciu slotu i po każdej zmianie.
    private func learnMap(_ id: ConnectionID, _ message: [String: Any]) throws -> [String: Any] {
        let slot = try Self.slot(message)
        var map: [Int: G2KnobAssignment] = [:]
        for item in message["map"] as? [[Int]] ?? [] where item.count == 4 {
            guard PluginAutomation.learned.contains(item[0]), (0 ... 1).contains(item[1]) else { continue }
            map[item[0]] = G2KnobAssignment(location: UInt8(item[1]), moduleID: item[2], paramIndex: item[3])
        }
        learnMaps[id, default: [:]][slot] = map
        scheduleAutomation()
        return ["type": "noted"]
    }

    /// `learn {on}` — następny parametr modułu, którym ktoś ruszy w slocie tej wtyczki (w edytorze
    /// albo na Nordzie), wraca jako `learned {slot, location, module, param, name}`.
    private func learn(_ id: ConnectionID, _ message: [String: Any]) -> [String: Any] {
        guard message["on"] as? Bool == true, let state, let slots = clients[id]?.slots else {
            learning[id] = nil
            return ["type": "learning", "on": false]
        }
        learning[id] = Dictionary(uniqueKeysWithValues: slots.filter { state.slots.indices.contains($0) }
            .map { ($0, state.slots[$0]) })
        return ["type": "learning", "on": true]
    }

    /// Szuka ruszonego parametru w slotach wtyczek, które uczą się (Learn).
    private func checkLearning() {
        guard let state, !learning.isEmpty else { return }
        for (id, baselines) in learning {
            for (slot, before) in baselines.sorted(by: { $0.key < $1.key }) where state.slots.indices.contains(slot) {
                let now = state.slots[slot]
                guard let touched = PluginAutomation.touchedParameter(before: before, after: now) else {
                    // Inna wariacja albo inny patch — od tej chwili liczymy od nowa.
                    if before.activeVariation != now.activeVariation { learning[id]?[slot] = now }
                    continue
                }
                learning[id] = nil
                let name = PluginAutomation.target(state, slot: slot, assignment: touched)?.name ?? ""
                send(["type": "learned", "slot": Self.letter(slot), "location": Int(touched.location),
                      "module": touched.moduleID, "param": touched.paramIndex, "name": name], to: id)
                break
            }
        }
    }

    typealias Note = (key: UInt8, velocity: UInt8, on: Bool)

    /// `events` = `[[on, key, velocity, channel], …]`, kanał 0…15. Tryb Slot: kanał z DAW-a
    /// pomijamy — o kanale decyduje slot. Tryb Performance: kanał 0…3 wybiera slot A…D,
    /// wyższe odpadają (G2 ma cztery sloty). Kolejność w obrębie slotu zostaje.
    static func route(_ events: [[Int]], client: Client) -> [(slot: Int, notes: [Note])] {
        var groups: [(slot: Int, notes: [Note])] = []
        for event in events {
            guard event.count >= 2, (0 ... 127).contains(event[1]) else { continue }
            let channel = event.count >= 4 ? event[3] : 0
            let slot = client.performance ? channel : client.slots.first ?? -1
            guard client.slots.contains(slot) else { continue }
            let velocity = event.count >= 3 ? UInt8(min(max(event[2], 0), 127)) : 100
            let note = (key: UInt8(event[1]), velocity: velocity, on: event[0] != 0)
            if let index = groups.firstIndex(where: { $0.slot == slot }) {
                groups[index].notes.append(note)
            } else {
                groups.append((slot, [note]))
            }
        }
        return groups
    }

    private func disconnected(_ id: ConnectionID) {
        let freed = clients[id]?.slots ?? []
        device?.clearDawNotes(slots: freed)
        clients[id] = nil
        sentVersions[id] = nil
        sentAutomation[id] = nil
        sentSequencers[id] = nil
        sentPages[id] = nil
        sentDisplays[id] = nil
        learnMaps[id] = nil
        learning[id] = nil
        waiting.remove(id)
        announceFree(freed)
    }

    // MARK: - Powiadomienia

    /// Śledzi sloty i stan urządzenia. Zmiany zbiera co najwyżej co 0,3 s — kręcenie gałką
    /// to dziesiątki zmian na sekundę, a wtyczce wystarczy wiedzieć, że slot jest inny.
    private func watch() {
        withObservationTracking {
            _ = state?.slots
            _ = device?.status
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.watch()
                self?.scheduleCheck()
            }
        }
        watchAutomation()
    }

    /// To, z czego liczy się lista automatyki: sloty, strona parametrów i Patch Adjuster
    /// (ten działa na slocie na ekranie).
    private func watchAutomation() {
        withObservationTracking {
            _ = state?.slots
            _ = state?.patchParameterPage
            _ = state?.focusedParameterPage
            _ = state?.showsGlobalParameterPages
            _ = state?.performance
            _ = state?.adjuster
            _ = state?.selectedSlot
            _ = device?.bankEntries
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.watchAutomation()
                self?.scheduleAutomation()
            }
        }
    }

    private func scheduleAutomation() {
        guard automationTask == nil else { return }
        automationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.automationInterval)
            guard !Task.isCancelled else { return }
            self?.automationTask = nil
            self?.pushAutomation()
        }
    }

    /// Różnice listy automatyki do każdej wtyczki, slot po slocie:
    /// `automation {slot, page, values: [[id, value, text], …], names?: [[id, name], …], touch}`.
    /// `touch` = ktoś kręci gałką (na Nordzie albo w edytorze) i DAW może to nagrać. Zmiana
    /// wariacji, strony albo patcha rusza naraz wieloma wartościami, ale to nie ruch gałki —
    /// wtedy `touch: false` i DAW tylko odświeża wartości.
    func pushAutomation() {
        guard let state, state.isLoaded else { return }
        checkLearning()
        for (id, client) in clients {
            for slot in client.slots where state.slots.indices.contains(slot) {
                let now = PluginAutomation.snapshot(state, slot: slot, learn: learnMaps[id]?[slot] ?? [:])
                let before = sentAutomation[id]?[slot]
                var values: [[Any]] = []
                var names: [[Any]] = []
                for key in PluginAutomation.ids {
                    guard let entry = now[key] else { continue }
                    let old = before?[key]
                    if old?.value != entry.value || old?.text != entry.text {
                        values.append([key, entry.value, entry.text])
                    }
                    if old?.name != entry.name, before == nil ? !entry.name.isEmpty : true {
                        names.append([key, entry.name])
                    }
                }
                guard !values.isEmpty || !names.isEmpty else { continue }
                sentAutomation[id, default: [:]][slot] = now
                let variationMoved = before?[PluginAutomation.variation] != now[PluginAutomation.variation]
                var message: [String: Any] = ["type": "automation", "slot": Self.letter(slot), "values": values,
                                              "page": state.patchParameterPage,
                                              "touch": before != nil && names.isEmpty && !variationMoved]
                if !names.isEmpty { message["names"] = names }
                send(message, to: id)
            }
            pushSequencers(id, client: client, state: state)
            pushPages(id, client: client, state: state)
            pushDisplays(id, client: client, state: state)
        }
    }

    /// `display {slot, name, category, location}` — ekranik wtyczki jak na froncie Norda: miejsce
    /// („1:12" w banku G2 albo folder na dysku, puste = nie wiadomo), kategoria i nazwa patcha.
    private func pushDisplays(_ id: ConnectionID, client: Client, state: PatchState) {
        for slot in client.slots where state.slots.indices.contains(slot) {
            let now = display(slot: slot, state: state)
            guard sentDisplays[id]?[slot] != now else { continue }
            sentDisplays[id, default: [:]][slot] = now
            send(now.merging(["type": "display", "slot": Self.letter(slot)]) { $1 }, to: id)
        }
    }

    private func display(slot: Int, state: PatchState) -> [String: String] {
        let patch = state.slots[slot]
        var location = ""
        if let loaded = loadedFrom[slot], loaded.name == patch.name {
            location = loaded.address.hasPrefix("g2:")
                ? PluginBrowser.entry(address: loaded.address, in: device?.bankEntries ?? [])?.displayLocation ?? ""
                : URL(fileURLWithPath: loaded.address).deletingLastPathComponent().lastPathComponent
        } else if let entry = device?.bankEntries.first(where: { $0.kind == .patch && $0.name == patch.name }) {
            location = entry.displayLocation
        }
        return ["name": patch.name, "category": PluginBrowser.categoryName(patch.description.category),
                "location": location]
    }

    /// `pages {slot, page, global, knobs: [{module, param, text, value, assigned, editable, button?}, …]}`
    /// — widoczna strona parametrów slotu, gdy cokolwiek na niej się zmieniło.
    private func pushPages(_ id: ConnectionID, client: Client, state: PatchState) {
        for slot in client.slots where state.slots.indices.contains(slot) {
            let now = PluginPages.snapshot(state, slot: slot, owned: Set(client.slots))
            guard sentPages[id]?[slot] != now else { continue }
            sentPages[id, default: [:]][slot] = now
            send(now.json.merging(["type": "pages", "slot": Self.letter(slot)]) { $1 }, to: id)
        }
    }

    /// `sequencers {slot, list: [{location, module, kind, name, steps, texts, gates, length, bipolar}, …]}`
    /// — całe sekwencery slotu, gdy cokolwiek się w nich zmieniło.
    private func pushSequencers(_ id: ConnectionID, client: Client, state: PatchState) {
        for slot in client.slots where state.slots.indices.contains(slot) {
            let now = PluginSequencers.snapshot(state, slot: slot)
            guard sentSequencers[id]?[slot] != now else { continue }
            sentSequencers[id, default: [:]][slot] = now
            send(["type": "sequencers", "slot": Self.letter(slot), "list": now.map(\.json)], to: id)
        }
    }

    private func scheduleCheck() {
        guard checkTask == nil else { return }
        checkTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.checkTask = nil
            self?.pushChanges()
        }
    }

    func pushChanges() {
        let device = deviceInfo()
        if device != sentDevice {
            sentDevice = device
            for id in clients.keys {
                send(["type": "device", "device": device], to: id)
            }
        }
        for (id, client) in clients {
            for slot in client.slots {
                let info = slotInfo(slot)
                let version = info["version"] as? String ?? ""
                guard version != sentVersions[id]?[slot] else { continue }
                sentVersions[id, default: [:]][slot] = version
                send(info.merging(["type": "slot_changed"]) { $1 }, to: id)
            }
        }
    }

    // MARK: - Pomocniki

    private func send(_ object: [String: Any], to id: ConnectionID) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        server.send(String(decoding: data, as: UTF8.self), to: id)
    }

    private func deviceInfo() -> [String: String] {
        guard let device, device.status == .connected else { return ["connected": "no"] }
        return ["connected": "yes", "kind": device.isVirtualDevice ? "virtual" : "hardware"]
    }

    /// Slot w odpowiedzi: nazwa i wersja, albo `available: false`, gdy edytor go nie ma
    /// (bez Norda i bez otwartej performance jest tylko slot A).
    private func slotInfo(_ slot: Int) -> [String: Any] {
        guard let patch = try? existingPatch(slot) else {
            return ["slot": Self.letter(slot), "available": false]
        }
        return ["slot": Self.letter(slot), "available": true, "name": patch.name,
                "version": SlotFingerprint.version(of: patch)]
    }

    private func existingPatch(_ slot: Int) throws -> G2Patch {
        guard let state, state.isLoaded, state.slots.indices.contains(slot) else {
            throw Refusal(code: "no_slot", message: "slot \(Self.letter(slot)) is not open in the editor — is the G2 connected?")
        }
        return state.slots[slot]
    }

    static func slot(_ message: [String: Any]) throws -> Int {
        guard let letter = message["slot"] as? String, let scalar = letter.uppercased().unicodeScalars.first,
              letter.count == 1, ("A" ... "D").contains(Character(scalar))
        else {
            throw Refusal(code: "bad_request", message: "\"slot\" must be A, B, C or D")
        }
        return Int(scalar.value - 65)
    }

    static func letter(_ slot: Int) -> String {
        String(UnicodeScalar(UInt8(65 + max(0, min(slot, 3)))))
    }
}

/// Odcisk slotu: bajty `.pch2` **i nazwa** (plik nie ma na nią pola). Zmienia się przy każdej
/// zmianie patcha, także zrobionej ręką — bez licznika wersji w edytorze. Wspólne dla mostów.
public enum SlotFingerprint {
    public struct MissingTemplate: Error {}

    public static func version(of patch: G2Patch) -> String {
        guard let data = try? patchFile(patch) else { return "?" }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in Array(patch.name.utf8) + [0] + Array(data) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }

    public static func patchFile(_ patch: G2Patch) throws -> Data {
        let skeleton = PatchParser.emptyPatchFile
        guard !skeleton.isEmpty else { throw MissingTemplate() }
        return try PatchParser.saveAll(originalData: skeleton, patches: [patch])
    }
}
