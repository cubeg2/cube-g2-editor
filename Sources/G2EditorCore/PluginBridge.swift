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
        /// Wejście MIDI (kabel do Norda), którym idą nuty tej wtyczki; puste = przez USB.
        public var midiPort = ""
        /// Grupa instancji: „Make this one active” w jednej aktywuje wszystkie z tą samą nazwą.
        public var group = ""
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
    /// Numer bieżącego kompletu obserwacji (`watch`) — starsze gasną przy odpaleniu.
    @ObservationIgnored private var watchGeneration = 0
    /// Obserwacja automatyki czeka na zmianę; `false` = odpaliła, odnowi ją paczka.
    @ObservationIgnored private var automationArmed = false
    /// Ile razy zapisano obserwację — test pilnuje, że nie rośnie z każdą zmianą patcha.
    @ObservationIgnored private(set) var observationRegistrations = 0
    /// Ostatnio wysłany bieżący krok sekwencerów (wskazówka w oknie wtyczki) i zadanie, które go ogranicza do ~20 razy na sekundę.
    @ObservationIgnored private var sentPlayheads: [ConnectionID: [Int: [Int]]] = [:]
    @ObservationIgnored private var playheadTask: Task<Void, Never>?
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
    /// Arpeggiator Patch Settings slotu (włącznik, Time, Direction, Octaves), który wtyczka ostatnio dostała.
    @ObservationIgnored private var sentArp: [ConnectionID: [Int: [Int]]] = [:]
    /// Ekranik wtyczki (nazwa, kategoria, miejsce w banku), który wtyczka ostatnio dostała.
    @ObservationIgnored private var sentDisplays: [ConnectionID: [Int: [String: String]]] = [:]
    /// Ostatni slot aktywny w edytorze, o którym wtyczka już wie (`focus`).
    @ObservationIgnored private var sentFocus: [ConnectionID: Int] = [:]
    /// Sloty, za którymi idzie klawiatura Norda (czerwona kreska nad przyciskiem slotu), o których wtyczka już wie.
    @ObservationIgnored private var sentKeyboard: [ConnectionID: [Bool]] = [:]
    /// Ustawienia performance'u, które wtyczka w trybie Performance ostatnio dostała.
    @ObservationIgnored private var sentPerformance: [ConnectionID: G2PerformanceSettings] = [:]
    /// Nazwa performance'u, którą wtyczka ostatnio dostała (zmienia się osobno od ustawień).
    @ObservationIgnored private var sentPerformanceName: [ConnectionID: String] = [:]
    /// Tagi pliku zmieniła wtyczka — panel Patches poprawia swoją listę (ma własną bibliotekę, nie ten skan).
    public var onTagsChanged: ((URL, [FinderTag]) -> Void)?
    /// Własne wzory sekwencji (Presets ▸ My patterns): aplikacja daje swoją bibliotekę, bez niej most trzyma ją w
    /// pamięci (testy nie dotykają pliku użytkownika).
    public var loadUserPatterns: (() -> SequenceUserLibrary)?
    public var saveUserPatterns: ((SequenceUserLibrary) -> Void)?
    @ObservationIgnored private var memoryPatterns = SequenceUserLibrary()
    @ObservationIgnored private var sentRhythmBank: Set<ConnectionID> = []
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
            case "add_sequencer": reply = try addSequencer(id, message)
            case "notes":
                // Bez odpowiedzi: nuty idą strumieniem, potwierdzenie tylko by je spowalniało.
                playNotes(id, message)
                return
            case "panic":
                // Bez odpowiedzi, jak nuty.
                if let client = clients[id] {
                    for slot in client.slots { device?.panic(slot: slot, port: client.midiPort) }
                }
                return
            case "midi_cc", "pitch_bend":
                // Bez odpowiedzi: kółka klawiatury z okna wtyczki.
                controller(id, type, message)
                return
            case "group":
                clients[id]?.group = message["group"] as? String ?? ""
                reply = ["type": "noted"]
            case "midi_ports":
                reply = ["type": "midi_ports", "ports": MidiNoteOutput.destinationNames()]
            case "midi_port":
                reply = midiPort(id, message)
            case "put_performance":
                reply = try putPerformance(id, message)
            case "automate":
                // Też bez odpowiedzi — nowy stan wraca zwykłą drogą, paczką `automation`.
                automate(id, message)
                return
            case "seq_draw":
                // Bez odpowiedzi — nowy stan wraca paczką `sequencers`.
                drawSequencer(id, message)
                return
            case "seq_arpeggio":
                // Bez odpowiedzi — nowe nuty wracają paczką `sequencers`.
                arpeggio(id, message)
                return
            case "seq_random":
                // Bez odpowiedzi — nowe nuty wracają paczką `sequencers`.
                randomNotes(id, message)
                return
            case "seq_preset":
                // Bez odpowiedzi — nowy wzór wraca paczką `sequencers`.
                preset(id, message)
                return
            case "seq_rhythm", "seq_pattern_save", "seq_pattern_load", "seq_pattern_delete":
                patterns(id, type, message)
                return
            case "seq_gates":
                // Bez odpowiedzi — nowe kroki wracają paczką `sequencers`.
                gates(id, message)
                return
            case "seq_curve":
                // Bez odpowiedzi — nowe wartości wracają paczką `sequencers`.
                curve(id, message)
                return
            case "seq_humanize":
                // Bez odpowiedzi — nowe wartości wracają paczką `sequencers`.
                humanize(id, message)
                return
            case "pages_select", "pages_global", "pages_knob", "pages_button":
                // Bez odpowiedzi — nowa strona wraca paczką `pages`.
                changePages(id, type, message)
                return
            case "arp_set":
                // Bez odpowiedzi — nowy stan wraca paczką `arp`.
                setArp(id, message)
                return
            case "browse":
                // Czytanie folderu trwa — odpowiedź przyjdzie osobno, z tym samym `id`.
                browse(id, message)
                return
            case "set_tag":
                // Tag Findera na pliku z listy (menu wiersza w przeglądarce wtyczki) — zapis robi edytor,
                // bo wtyczka w piaskownicy DAW-a plików nie zmienia. Odpowiedź `tag_set` z pełną listą kolorów.
                setTag(id, message)
                return
            case "navigate":
                // Jak `browse`: lista banków albo folderu może się jeszcze czytać.
                navigate(id, message)
                return
            case "patch_info":
                reply = try patchInfo(message)
            case "load_patch":
                reply = try loadPatch(id, message)
            case "focus_slot":
                // Klik slotu we wtyczce = ten sam ruch co w górnym pasku edytora: focus i aktywny slot Norda
                // (`onChange(of: selectedSlot)` w `ContentView` wysyła `SelectSlot`). Bez odpowiedzi.
                if let slot = try? Self.slot(message), let state, state.slots.indices.contains(slot),
                   state.selectedSlot != slot { state.selectedSlot = slot }
                return
            case "set_playing_slots":
                // Mute/Solo z wtyczki: które sloty grają (niebieskie przyciski), cztery wartości naraz. Co najmniej
                // jeden musi grać. Bez odpowiedzi — nowy stan wraca paczką `keyboard_slots` (pole `playing`).
                if let slots = message["slots"] as? [Bool], slots.count == 4 {
                    Task { await device?.setPlayingSlots(slots) }
                }
                return
            case "toggle_keyboard":
                // Jak CTRL+klik w pasku slotów: klawiatura Norda idzie za slotem albo przestaje. Bez odpowiedzi —
                // nowy stan wraca paczką `keyboard_slots`.
                if let slot = try? Self.slot(message) { Task { await device?.toggleKeyboardSlot(slot) } }
                return
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
                             slots: clients[id]?.slots ?? [], performance: clients[id]?.performance ?? false,
                             midiPort: clients[id]?.midiPort ?? "", group: clients[id]?.group ?? "")
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
        // Grupę zapamiętujemy także przy odmowie: czekająca instancja ma być obudzona razem z grupą.
        if let group = message["group"] as? String { clients[id]?.group = group }
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
            device?.clearDawNotes(slots: lost, port: clients[loser]?.midiPort)
            clients[loser]?.slots = []
            clients[loser]?.performance = false
            sentVersions[loser] = nil
            sentAutomation[loser] = nil
            sentSequencers[loser] = nil
            sentPages[loser] = nil
            sentArp[loser] = nil
            sentDisplays[loser] = nil
            sentFocus[loser] = nil
            sentKeyboard[loser] = nil
            sentPerformance[loser] = nil
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
        sentPlayheads[id] = nil
        sentPages[id] = nil
        sentArp[id] = nil
        sentDisplays[id] = nil
        sentFocus[id] = nil
        sentKeyboard[id] = nil
        sentPerformance[id] = nil
        scheduleAutomation()
        scheduleCheck()
        activateGroup(of: id, takeOver: takeOver, automatic: message["auto"] as? Bool == true)
        if performance {
            return ["type": "claimed", "performance": true, "slots": infos]
        }
        return infos[0].merging(["type": "claimed"]) { $1 }
    }

    /// Kółka klawiatury z okna wtyczki: `midi_cc {slot, cc, value}` (mod wheel = 1) i
    /// `pitch_bend {slot, value}` (−1…1). Idą kablem MIDI (albo do Virtual G2) na kanał slotu.
    private func controller(_ id: ConnectionID, _ type: String, _ message: [String: Any]) {
        guard let client = clients[id], let device, let slot = try? Self.slot(message),
              client.slots.contains(slot), let value = (message["value"] as? NSNumber)?.doubleValue,
              value.isFinite else { return }
        if type == "midi_cc", let cc = message["cc"] as? Int, (0 ... 127).contains(cc) {
            device.sendController(cc, value: Int(value.rounded()), slot: slot, port: client.midiPort)
        } else if type == "pitch_bend" {
            device.sendPitchBend(value, slot: slot, port: client.midiPort)
        }
    }

    /// „Make this one active” w jednej instancji grupy budzi pozostałe, które czekają na sloty
    /// (`activate`) — każda zajmuje swój slot jak po własnym kliknięciu. Instancja obudzona
    /// zgłasza się z `auto`, więc budzenie nie biegnie w kółko.
    private func activateGroup(of id: ConnectionID, takeOver: Bool, automatic: Bool) {
        guard takeOver, !automatic, let group = clients[id]?.group, !group.isEmpty else { return }
        for (other, client) in clients where other != id && client.group == group && client.slots.isEmpty {
            send(["type": "activate"], to: other)
        }
    }

    /// `midi_port {port}` — wybór kabla MIDI do Norda w oknie wtyczki. Odpowiedź niesie
    /// ostrzeżenia (brak wejścia, slot nie słucha MIDI, kanał globalny dubluje kanał slotu).
    private func midiPort(_ id: ConnectionID, _ message: [String: Any]) -> [String: Any] {
        let port = message["port"] as? String ?? ""
        clients[id]?.midiPort = port
        let warnings = device?.midiNotesWarnings(port: port, slots: clients[id]?.slots ?? []) ?? []
        return ["type": "midi_port", "port": port, "warnings": warnings]
    }

    private func release(_ id: ConnectionID) -> [String: Any] {
        let freed = clients[id]?.slots ?? []
        device?.clearDawNotes(slots: freed, port: clients[id]?.midiPort)
        clients[id]?.slots = []
        clients[id]?.performance = false
        sentVersions[id] = nil
        sentAutomation[id] = nil
        sentSequencers[id] = nil
        sentPlayheads[id] = nil
        sentPages[id] = nil
        sentArp[id] = nil
        sentDisplays[id] = nil
        sentFocus[id] = nil
        sentKeyboard[id] = nil
        sentPerformance[id] = nil
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

    /// `add_sequencer {slot}` → `sequencer_added {slot, result: added|no_sound_source|wont_fit, id?}`:
    /// to samo co przycisk „Add sequencer" w oknie Sequence Editor edytora (`PatchState.addSequencer`) — nuta i bramka
    /// idą z nowego SeqNote zamiast z klawiatury, jeden krok Undo, i dalej do Norda istniejącą drogą. Nowy sekwencer
    /// wraca do wtyczki zwykłą paczką `sequencers`. Tylko w slocie tej wtyczki; slot staje się aktywnym w edytorze.
    private func addSequencer(_ id: ConnectionID, _ message: [String: Any]) throws -> [String: Any] {
        let slot = try Self.slot(message)
        guard clients[id]?.slots.contains(slot) == true else {
            throw Refusal(code: "claim_first", message: "claim slot \(Self.letter(slot)) before adding a sequencer to it")
        }
        guard let state, state.slots.indices.contains(slot) else {
            throw Refusal(code: "no_slot", message: "the editor has no document yet")
        }
        if state.selectedSlot != slot { state.selectedSlot = slot }
        var reply: [String: Any] = ["type": "sequencer_added", "slot": Self.letter(slot)]
        switch state.addSequencer(slot: slot) {
        case let .added(sequencerID):
            reply["result"] = "added"
            reply["id"] = sequencerID
        case .noSoundSource: reply["result"] = "no_sound_source"
        case .wontFit: reply["result"] = "wont_fit"
        }
        return reply
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
        patch.upgradeLegacyModules()
        patch.fillMissingParameters()
        // Plik `.pch2` nie ma pola na nazwę patcha — przychodzi obok.
        if let name = message["name"] as? String {
            patch.name = String(name.prefix(G2PatchName.maxLength))
        }
        let host = clients[id]?.host ?? ""
        // Całość jedną komendą, nie różnicą modułów (#192); inaczej slot nieaktywny w ogóle nie trafiłby do Norda.
        state.replaceSlotWholeFromFile(slot: slot, patch: patch, fileData: nil,
                                       actionName: host.isEmpty ? "Patch from Plugin" : "Patch from \(host)")
        device?.sendWholeSlot(slot: slot, patch: state.slots[slot], fileData: nil)
        let version = SlotFingerprint.version(of: state.slots[slot])
        sentVersions[id, default: [:]][slot] = version
        return ["type": "stored", "slot": Self.letter(slot), "version": version]
    }

    /// Nuty z DAW-a → sloty tej wtyczki (droga: `DeviceConnection.playNotes`). Grać może tylko
    /// wtyczka, która trzyma slot; czekająca jest cicha.
    private func playNotes(_ id: ConnectionID, _ message: [String: Any]) {
        guard let client = clients[id], let device, let events = message["events"] as? [[Int]] else { return }
        for (slot, notes) in Self.route(events, client: client) {
            device.playNotes(notes, slot: slot, port: client.midiPort)
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

    /// Generator Arpeggio z okna wtyczki: `seq_arpeggio {slot, location, module, root, chord, direction, octaves, scale?}`.
    private func arpeggio(_ id: ConnectionID, _ message: [String: Any]) {
        guard let client = clients[id], let state, let slot = try? Self.slot(message),
              client.slots.contains(slot), let location = message["location"] as? Int,
              let module = message["module"] as? Int, let root = message["root"] as? Int,
              let chord = message["chord"] as? String, let direction = message["direction"] as? String,
              let octaves = message["octaves"] as? Int else { return }
        PluginSequencers.arpeggio(state, slot: slot, location: location, moduleID: module, root: root,
                                  chord: chord, direction: direction, octaves: octaves,
                                  scale: message["scale"] as? String ?? "major", locked: Self.locks(message))
    }

    /// Random / Mutate z okna wtyczki: `seq_random {slot, location, module, mode: random|mutate|walk|motif|markov, root, scale, low, high,
    /// percent}` (root = klasa wysokości 0–11, low/high = zakres MIDI, percent tylko dla mutate).
    private func randomNotes(_ id: ConnectionID, _ message: [String: Any]) {
        guard let client = clients[id], let state, let slot = try? Self.slot(message),
              client.slots.contains(slot), let location = message["location"] as? Int,
              let module = message["module"] as? Int, let mode = message["mode"] as? String,
              let root = message["root"] as? Int, let scale = message["scale"] as? String,
              let low = message["low"] as? Int, let high = message["high"] as? Int else { return }
        PluginSequencers.randomNotes(state, slot: slot, location: location, moduleID: module, mode: mode, root: root,
                                     scale: scale, range: min(low, high) ... max(low, high), percent: message["percent"] as? Int ?? 25,
                                     locked: Self.locks(message))
    }

    /// Zablokowane kroki z komendy generatora (`locks: [0…15]`) — generator ich nie rusza, jak blokady w oknie edytora.
    static func locks(_ message: [String: Any]) -> Set<Int> {
        Set((message["locks"] as? [Int] ?? []).filter { (0 ..< 16).contains($0) })
    }

    /// Presets z okna wtyczki: `seq_preset {slot, location, module, name, root}` (nazwy z pola `presets` paczki
    /// `sequencers`; root = nuta MIDI dla figur nutowych).
    private func preset(_ id: ConnectionID, _ message: [String: Any]) {
        guard let client = clients[id], let state, let slot = try? Self.slot(message),
              client.slots.contains(slot), let location = message["location"] as? Int,
              let module = message["module"] as? Int, let name = message["name"] as? String else { return }
        PluginSequencers.preset(state, slot: slot, location: location, moduleID: module, name: name,
                                root: message["root"] as? Int ?? 48, locked: Self.locks(message))
    }

    /// Losowe włączanie kroków: `seq_gates {slot, location, module, mode: random|mutate, density, percent, locks}` —
    /// SeqEvent oba tory, inne sekwencery tor Gate; `mutate` tylko dla SeqEvent.
    private func gates(_ id: ConnectionID, _ message: [String: Any]) {
        guard let client = clients[id], let state, let slot = try? Self.slot(message),
              client.slots.contains(slot), let location = message["location"] as? Int,
              let module = message["module"] as? Int, let mode = message["mode"] as? String else { return }
        PluginSequencers.gates(state, slot: slot, location: location, moduleID: module, mode: mode,
                               density: message["density"] as? Int ?? 50, percent: message["percent"] as? Int ?? 25,
                               locked: Self.locks(message))
    }

    /// Curve z okna wtyczki: `seq_curve {slot, location, module, shape, cycles, low, high}` (low/high = % zakresu).
    private func curve(_ id: ConnectionID, _ message: [String: Any]) {
        guard let client = clients[id], let state, let slot = try? Self.slot(message),
              client.slots.contains(slot), let location = message["location"] as? Int,
              let module = message["module"] as? Int, let shape = message["shape"] as? String,
              let cycles = message["cycles"] as? Int, let low = message["low"] as? Int,
              let high = message["high"] as? Int else { return }
        PluginSequencers.curve(state, slot: slot, location: location, moduleID: module, shape: shape, cycles: cycles,
                               low: low, high: high, locked: Self.locks(message))
    }

    /// Humanize z okna wtyczki: `seq_humanize {slot, location, module, amount}` (amount = % zakresu, 0–100).
    private func humanize(_ id: ConnectionID, _ message: [String: Any]) {
        guard let client = clients[id], let state, let slot = try? Self.slot(message),
              client.slots.contains(slot), let location = message["location"] as? Int,
              let module = message["module"] as? Int, let amount = message["amount"] as? Int else { return }
        PluginSequencers.humanize(state, slot: slot, location: location, moduleID: module, amount: amount,
                                  locked: Self.locks(message))
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
            // „performance" = same .prf2 (stare wtyczki), „all" = oba rodzaje (przyciski pch2 / prf2 we wtyczce).
            let kind = message["kind"] as? String
            let performances = kind == "performance" || kind == "all"
            let patches = kind != "performance"
            // Bez wyboru we wtyczce — kolejność z panelu Patches (zapisana w ustawieniach edytora).
            let sort = (message["sort"] as? String).flatMap(DiskBankSort.init) ?? library.sortOrder
            let reversed = message["reversed"] as? Bool ?? library.sortReversed
            let found = PluginBrowser.search(library.items, query: query, group: group, performances: performances,
                                             patches: patches, direct: message["direct"] as? Bool ?? false,
                                             sort: sort, reversed: reversed, category: message["category"] as? String)
            // Wiersze folderów pod bieżącym (wchodzenie piętro po piętrze); bez `path` — stara lista `groups`.
            if let path = message["path"] as? String {
                reply["folders"] = PluginBrowser.folders(library.items, under: path, performances: performances,
                                                         patches: patches).map { [$0.name, $0.count] as [Any] }
            }
            reply["folder"] = URL(fileURLWithPath: path).lastPathComponent
            reply["groups"] = PluginBrowser.groups(library.items, performances: performances, patches: patches)
            reply["categories"] = PluginBrowser.categories(library.items)
            reply["sort"] = sort.rawValue
            reply["reversed"] = reversed
            reply["items"] = found.prefix(PluginBrowser.resultLimit).map(PluginBrowser.json)
            reply["total"] = found.count
            if let note = library.message { reply["message"] = note }
            send(reply, to: id)
        }
    }

    /// Włącza albo zdejmuje tag koloru (1…7, numeracja Findera) z pliku z folderu panelu Banks.
    private func setTag(_ id: ConnectionID, _ message: [String: Any]) {
        guard let path = message["path"] as? String, let color = message["color"] as? Int, (1 ... 7).contains(color),
              let on = message["on"] as? Bool else { return }
        Task { @MainActor in
            var reply: [String: Any] = ["type": "tag_set", "path": path]
            guard let (library, _) = await diskLibrary(), let item = library.items.first(where: { $0.url.path == path }) else {
                send(["type": "error", "id": "browser", "message": "The file is not in the editor's patch folder"], to: id)
                return
            }
            var tags = item.tags.filter { $0.color != color }
            if on { tags.append(FinderTag(name: FinderTag.favouriteName(color: color), color: color)) }
            do {
                try library.setTags(tags, of: item)
            } catch {
                send(["type": "error", "id": "browser", "message": "The tags could not be saved"], to: id)
                return
            }
            onTagsChanged?(item.url, tags)
            reply["tags"] = tags.map(\.color).filter { $0 > 0 }
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
        if path.lowercased().hasSuffix(".prf2") {
            guard let loaded = try? PluginBrowser.performance(at: URL(fileURLWithPath: path)) else {
                throw Refusal(code: "bad_patch", message: "cannot read \(URL(fileURLWithPath: path).lastPathComponent)")
            }
            return PluginBrowser.performanceInfo(patches: loaded.patches, name: loaded.name)
                .merging(["type": "patch_info", "path": path]) { $1 }
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
        if let path = message["path"] as? String, path.lowercased().hasSuffix(".prf2") {
            return try loadPerformance(id, path: path)
        }
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
        let fileData = try? Data(contentsOf: URL(fileURLWithPath: path))
        state.replaceSlotWholeFromFile(slot: slot, patch: patch, fileData: fileData,
                                       actionName: host.isEmpty ? "Load Patch from Plugin" : "Load Patch from \(host)")
        device?.sendWholeSlot(slot: slot, patch: state.slots[slot], fileData: fileData)
        loadedFrom[slot] = (path, patch.name)
        return ["type": "loaded", "slot": Self.letter(slot), "name": patch.name]
    }

    /// `.prf2` z przeglądarki do wtyczki w trybie Performance: cztery patche do slotów A–D i ustawienia
    /// performance'u (zegar, zakresy klawiszy, Hold, nazwy slotów). Każdy patch to osobny krok Undo.
    private func loadPerformance(_ id: ConnectionID, path: String) throws -> [String: Any] {
        guard let client = clients[id], client.performance, client.slots.count == 4 else {
            throw Refusal(code: "claim_first", message: "a performance can only be loaded by a plugin in Performance mode that holds all four slots")
        }
        guard let state, state.slots.count >= 4 else {
            throw Refusal(code: "no_slot", message: "the editor has no performance open yet")
        }
        guard let loaded = try? PluginBrowser.performance(at: URL(fileURLWithPath: path)) else {
            throw Refusal(code: "bad_patch", message: "not a readable .prf2 file")
        }
        let action = client.host.isEmpty ? "Load Performance from Plugin" : "Load Performance from \(client.host)"
        // Cały performance jedną komendą, nie różnicą modułów ×4 (#192 — różnica zawieszała Norda).
        for (slot, patch) in loaded.patches.prefix(4).enumerated() {
            state.replaceSlotWholeFromFile(slot: slot, patch: patch, fileData: nil, actionName: action)
            loadedFrom[slot] = nil
        }
        if let settings = loaded.settings {
            state.applyPerformanceSettings(settings, name: loaded.name, actionName: action)
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                state.rememberPerformanceFile(data: data)
            }
        }
        if let device, let state = self.state {
            Task { await device.send(state) }
        }
        return ["type": "loaded", "slot": "A", "name": loaded.name]
    }

    /// `put_performance {data, name}` — ustawienia performance'u z piosenki (zegar, zakresy klawiszy,
    /// Hold…) wracają do edytora i Norda. `data` to plik `.prf2`, który edytor sam wcześniej wysłał
    /// (`performance`); wtyczka trzyma go jako czarną skrzynkę, ustawienia czyta z niego edytor.
    private func putPerformance(_ id: ConnectionID, _ message: [String: Any]) throws -> [String: Any] {
        guard let client = clients[id], client.performance, client.slots.count == 4 else {
            throw Refusal(code: "claim_first", message: "claim the performance before writing its settings")
        }
        guard let state, let base64 = message["data"] as? String, let data = Data(base64Encoded: base64),
              let settings = (try? PatchParser.parseFile(data: data))?.performance
        else {
            throw Refusal(code: "bad_patch", message: "\"data\" must be base64 of a .prf2 file with performance settings")
        }
        let action = client.host.isEmpty ? "Performance from Plugin" : "Performance from \(client.host)"
        state.applyPerformanceSettings(settings, name: message["name"] as? String, actionName: action)
        sentPerformance[id] = state.performance
        sentPerformanceName[id] = Self.performanceLabel(state)
        // Do Norda tą samą drogą co okno Performance Settings: nazwa, potem cała sekcja 0x11
        // (zegar, zakresy klawiszy, Hold, sloty grające). Szkielet sekcji bierzemy z pliku piosenki.
        // Bez Norda nic nie idzie — ustawienia czekają w edytorze do „Send to G2”.
        device?.queuePerformanceSettings(name: state.performanceName, performance: state.performance, fileData: data)
        return ["type": "stored_performance"]
    }

    /// `performance {name, version, data}` — ustawienia performance'u do piosenki. `version` to odcisk
    /// samych ustawień (bez patchy), po nim wtyczka widzi, czy się zmieniły.
    static func performanceMessage(_ state: PatchState) -> [String: Any]? {
        let template = PatchParser.emptyPerformanceFile
        guard !template.isEmpty,
              let data = try? PatchParser.saveAll(originalData: template, patches: state.slots,
                                                  performance: state.performance)
        else { return nil }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in Array("\(state.performanceName)\u{0}\(state.performance)".utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01B3
        }
        return ["type": "performance", "name": state.performanceName, "file": fileName(state),
                "version": String(format: "%016llx", hash), "data": data.base64EncodedString()]
    }

    /// Nazwa otwartego pliku `.prf2` (bez rozszerzenia); pusta, gdy performance nie ma pliku.
    private static func fileName(_ state: PatchState) -> String {
        state.performanceFileURL?.deletingPathExtension().lastPathComponent ?? ""
    }

    /// Nazwa i plik razem — wtyczka dostaje wiadomość ponownie, gdy zmieni się któreś z nich.
    private static func performanceLabel(_ state: PatchState) -> String {
        "\(state.performanceName)\u{0}\(fileName(state))"
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
        device?.clearDawNotes(slots: freed, port: clients[id]?.midiPort)
        clients[id] = nil
        sentPerformance[id] = nil
        sentVersions[id] = nil
        sentAutomation[id] = nil
        sentSequencers[id] = nil
        sentRhythmBank.remove(id)
        sentPages[id] = nil
        sentArp[id] = nil
        sentDisplays[id] = nil
        sentFocus[id] = nil
        sentKeyboard[id] = nil
        learnMaps[id] = nil
        learning[id] = nil
        waiting.remove(id)
        announceFree(freed)
    }

    // MARK: - Powiadomienia

    /// Uzbraja trzy obserwacje od nowa — przy podpięciu stanu albo urządzenia. Każda potem
    /// odnawia tylko SAMĄ SIEBIE; starsze (sprzed podpięcia) gasną przy pierwszym odpaleniu,
    /// bo ich numer (`watchGeneration`) jest już nieaktualny.
    ///
    /// Do 2026-11-25 odnowienie obserwacji slotów wołało też tę funkcję, czyli dokładało
    /// nowych obserwatorów automatyki i wskazówki sekwencera, a stare odnawiały się dalej:
    /// każdy ruch gałki przybywał po jednym. Po godzinie kręcenia edytor miał ich tysiące
    /// i budził wszystkie przy każdej zmianie patcha i każdej paczce diod z G2
    /// → [[Docs/ui/canvas-performance]].
    private func watch() {
        watchGeneration += 1
        automationArmed = false
        watchSlots(watchGeneration)
        watchAutomation()
        watchPlayhead(watchGeneration)
    }

    /// Śledzi sloty i stan urządzenia. Zmiany zbiera co najwyżej co 0,3 s — kręcenie gałką
    /// to dziesiątki zmian na sekundę, a wtyczce wystarczy wiedzieć, że slot jest inny.
    private func watchSlots(_ generation: Int) {
        observationRegistrations += 1
        withObservationTracking {
            _ = state?.slots
            _ = state?.performance
            _ = device?.status
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.watchGeneration else { return }
                self.watchSlots(generation)
                self.scheduleCheck()
            }
        }
    }

    /// Bieżący krok sekwencerów: ten sam strumień diod co wskazówka w oknie Sequence Editor.
    private func watchPlayhead(_ generation: Int) {
        observationRegistrations += 1
        withObservationTracking {
            _ = device?.ledGroups
            _ = device?.meterSlot
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.watchGeneration else { return }
                self.watchPlayhead(generation)
                self.schedulePlayhead()
            }
        }
    }

    private func schedulePlayhead() {
        guard playheadTask == nil else { return }
        playheadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            self?.playheadTask = nil
            self?.pushPlayheads()
        }
    }

    /// `playhead {slot, steps: [[location, module, step], …]}` — krok −1 = sekwencer stoi. Tylko slot, który
    /// strumieniuje Nord (jak w oknie edytora), i tylko gdy coś się zmieniło.
    func pushPlayheads() {
        guard let device, let state else { return }
        for (id, client) in clients where client.slots.contains(device.meterSlot) {
            let slot = device.meterSlot
            guard state.slots.indices.contains(slot) else { continue }
            let steps = PluginSequencers.playheads(state, slot: slot, ledGroups: device.status == .connected ? device.ledGroups : [])
            let flat = steps.flatMap { [$0.location, $0.module, $0.step] }
            guard sentPlayheads[id]?[slot] != flat else { continue }
            sentPlayheads[id, default: [:]][slot] = flat
            send(["type": "playhead", "slot": Self.letter(slot), "steps": steps.map { [$0.location, $0.module, $0.step] }],
                 to: id)
        }
    }

    /// To, z czego liczy się lista automatyki: sloty, strona parametrów i Patch Adjuster
    /// (ten działa na slocie na ekranie).
    ///
    /// Odpalona obserwacja nie odnawia się od razu, tylko razem z paczką
    /// (`scheduleAutomation`): paczka i tak czyta stan po odnowieniu, a gałka kręcona
    /// myszą nie płaci za ponowne zapisywanie dziesięciu obserwacji na każdy tick.
    private func watchAutomation() {
        let generation = watchGeneration
        automationArmed = true
        observationRegistrations += 1
        withObservationTracking {
            _ = state?.slots
            _ = state?.patchParameterPage
            _ = state?.focusedParameterPage
            _ = state?.showsGlobalParameterPages
            _ = state?.performance
            _ = state?.adjuster
            _ = state?.selectedSlot
            _ = device?.bankEntries
            _ = device?.keyboardSlots
            _ = device?.playingSlots
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.watchGeneration else { return }
                self.automationArmed = false
                self.scheduleAutomation()
            }
        }
    }

    private func scheduleAutomation() {
        guard automationTask == nil else { return }
        automationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.automationInterval)
            guard !Task.isCancelled, let self else { return }
            self.automationTask = nil
            if !self.automationArmed { self.watchAutomation() }
            self.pushAutomation()
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
                    if old?.name != entry.name || old?.module != entry.module,
                       before == nil ? !entry.name.isEmpty : true
                    {
                        names.append(entry.module.isEmpty ? [key, entry.name] : [key, entry.name, entry.module])
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
            pushArp(id, client: client, state: state)
            pushDisplays(id, client: client, state: state)
            pushFocus(id, state: state)
            pushKeyboard(id)
        }
    }

    /// `keyboard_slots {slots: [Bool × 4], playing: [Bool × 4]}` — za którymi slotami idzie klawiatura Norda
    /// i które sloty grają (niebieskie przyciski; wtyczka robi z tego Mute/Solo).
    private func pushKeyboard(_ id: ConnectionID) {
        guard let device else { return }
        let now = Array(device.keyboardSlots.prefix(4))
        let playing = Array(device.playingSlots.prefix(4))
        guard now.count == 4, sentKeyboard[id] != now + playing else { return }
        sentKeyboard[id] = now + playing
        var message: [String: Any] = ["type": "keyboard_slots", "slots": now]
        if playing.count == 4 { message["playing"] = playing }
        send(message, to: id)
    }

    /// `focus {slot}` — slot aktywny w edytorze i na Nordzie (klik w pasku, przycisk na froncie). Wtyczka w trybie
    /// Performance podświetla jego kafelek, także zaraz po otwarciu projektu.
    private func pushFocus(_ id: ConnectionID, state: PatchState) {
        let slot = state.selectedSlot
        guard sentFocus[id] != slot else { return }
        sentFocus[id] = slot
        send(["type": "focus", "slot": Self.letter(slot)], to: id)
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

    /// Pola arpeggiatora z Patch Settings w kolejności wysyłki: włącznik, Time, Direction, Octaves.
    private static let arpSettings: [G2PatchSetting] = [.arpeggiator, .arpTime, .arpType, .arpOctaves]
    private static let arpFields = ["on": 0, "time": 1, "type": 2, "octaves": 3]

    /// `arp {slot, values: [on, time, type, octaves]}` — arpeggiator Norda (Patch Settings) w aktywnej wariacji slotu,
    /// gdy cokolwiek się zmieniło (z edytora, z Norda albo z wtyczki).
    private func pushArp(_ id: ConnectionID, client: Client, state: PatchState) {
        for slot in client.slots where state.slots.indices.contains(slot) {
            let patch = state.slots[slot]
            guard patch.variationSettings.indices.contains(patch.activeVariation) else { continue }
            let settings = patch.variationSettings[patch.activeVariation]
            let now = Self.arpSettings.map { settings[keyPath: $0.keyPath] }
            guard sentArp[id]?[slot] != now else { continue }
            sentArp[id, default: [:]][slot] = now
            send(["type": "arp", "slot": Self.letter(slot), "values": now], to: id)
        }
    }

    /// `arp_set {slot, field: on|time|type|octaves, value}` — to samo co suwaki Patch Settings w edytorze (aktywna
    /// wariacja, idzie też do Norda, jeden krok Undo). Tylko w slotach tej wtyczki.
    private func setArp(_ id: ConnectionID, _ message: [String: Any]) {
        guard let owned = clients[id]?.slots, let state, state.isLoaded,
              let letter = message["slot"] as? String, let slot = ["A", "B", "C", "D"].firstIndex(of: letter),
              owned.contains(slot), let field = message["field"] as? String, let index = Self.arpFields[field],
              let value = message["value"] as? Int else { return }
        state.setPatchSetting(Self.arpSettings[index], value: value, slot: slot)
    }

    private var userLibrary: SequenceUserLibrary {
        loadUserPatterns?() ?? memoryPatterns
    }

    private func storeUserLibrary(_ library: SequenceUserLibrary) {
        if let saveUserPatterns { saveUserPatterns(library) } else { memoryPatterns = library }
    }

    /// Rhythm bank i My patterns z okna wtyczki: `seq_rhythm {slot, location, module, index, locks}`,
    /// `seq_pattern_save {…, name}`, `seq_pattern_load {…, id, locks}`, `seq_pattern_delete {id}`. Bez odpowiedzi —
    /// nowy stan i lista własnych wzorów wracają paczką `sequencers`.
    private func patterns(_ id: ConnectionID, _ type: String, _ message: [String: Any]) {
        guard let client = clients[id], let state else { return }
        if type == "seq_pattern_delete" {
            guard let uuid = (message["id"] as? String).flatMap(UUID.init) else { return }
            var library = userLibrary
            library.remove(id: uuid)
            storeUserLibrary(library)
            pushAutomation()
            return
        }
        guard let slot = try? Self.slot(message), client.slots.contains(slot), let location = message["location"] as? Int,
              let module = message["module"] as? Int else { return }
        switch type {
        case "seq_rhythm":
            guard let index = message["index"] as? Int else { return }
            PluginSequencers.rhythm(state, slot: slot, location: location, moduleID: module, index: index,
                                    locked: Self.locks(message))
        case "seq_pattern_save":
            guard let name = message["name"] as? String else { return }
            var library = userLibrary
            if PluginSequencers.saveUserPattern(state, slot: slot, location: location, moduleID: module, name: name,
                                                into: &library)
            {
                storeUserLibrary(library)
                pushAutomation()
            }
        default:
            guard let uuid = (message["id"] as? String).flatMap(UUID.init),
                  let pattern = userLibrary.patterns.first(where: { $0.id == uuid }) else { return }
            PluginSequencers.applyUserPattern(state, slot: slot, location: location, moduleID: module, pattern: pattern,
                                              locked: Self.locks(message))
        }
    }

    /// `sequencers {slot, list: [{location, module, kind, name, steps, texts, gates, length, bipolar}, …]}`
    /// — całe sekwencery slotu, gdy cokolwiek się w nich zmieniło.
    private func pushSequencers(_ id: ConnectionID, client: Client, state: PatchState) {
        for slot in client.slots where state.slots.indices.contains(slot) {
            let now = PluginSequencers.snapshot(state, slot: slot, library: userLibrary)
            if sentRhythmBank.insert(id).inserted {
                // Bank rytmów raz na połączenie: 122 wzory i ich role (menu Rhythm bank w oknie wtyczki).
                send(["type": "rhythm_bank", "patterns": SequenceRhythmBank.patterns,
                      "roles": SequenceRhythmBank.patterns.indices.map { SequenceRhythmBank.role(at: $0)?.title ?? "" }],
                     to: id)
            }
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
            if client.performance, client.slots.count == 4, let state, state.hasPerformanceSettings,
               sentPerformance[id] != state.performance || sentPerformanceName[id] != Self.performanceLabel(state),
               let message = Self.performanceMessage(state)
            {
                sentPerformance[id] = state.performance
                sentPerformanceName[id] = Self.performanceLabel(state)
                send(message, to: id)
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
