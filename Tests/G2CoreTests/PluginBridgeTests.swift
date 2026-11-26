// PluginBridgeTests.swift
// Most dla wtyczek DAW bez Norda i bez DAW-a: prawdziwe gniazdo, klienci jak wtyczki.
// Bramka Etapu 2: dwie instancje na dwóch slotach, trzecia na zajętym dostaje czytelny komunikat.

import G2Core
@testable import G2EditorCore
import XCTest

@MainActor
final class PluginBridgeTests: XCTestCase {
    private var path = ""
    private var bridge: PluginBridge!
    private var state: PatchState!

    override func setUp() async throws {
        path = "/tmp/g2pb-\(UUID().uuidString.prefix(8)).sock"
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/simplesynth001-20240802.pch2")
        let patch = try XCTUnwrap(PatchParser.parse(data: Data(contentsOf: url)).first)
        state = PatchState()
        state.loadFromDevice(patches: ["One", "Two", "Three", "Four"].map { name in
            var copy = patch
            copy.name = name
            return copy
        })
        bridge = PluginBridge(path: path)
        bridge.editorName = "test editor"
        bridge.state = state
        try bridge.start()
    }

    override func tearDown() async throws {
        bridge.stop()
    }

    func testHelloAnswersWithProtocolAndEditorName() async throws {
        let plugin = try TestPlugin(path)
        let reply = try await plugin.ask(["type": "hello", "protocol": 1, "client": "G2 VST"])
        XCTAssertEqual(reply["type"] as? String, "hello")
        XCTAssertEqual(reply["protocol"] as? Int, 1)
        XCTAssertEqual(reply["editor"] as? String, "test editor")
    }

    func testCommandsBeforeHelloAreRefused() async throws {
        let plugin = try TestPlugin(path)
        let reply = try await plugin.ask(["type": "claim", "slot": "A"])
        XCTAssertEqual(reply["code"] as? String, "hello_first")
    }

    func testRequestIDComesBack() async throws {
        let plugin = try TestPlugin(path)
        let reply = try await plugin.ask(["type": "hello", "id": 7])
        XCTAssertEqual(reply["id"] as? Int, 7)
    }

    func testTwoPluginsOnTwoSlotsAndThirdOnTakenSlot() async throws {
        let first = try await TestPlugin.greeted(path, host: "Logic Pro")
        let second = try await TestPlugin.greeted(path, host: "Bitwig Studio")
        let third = try await TestPlugin.greeted(path, host: "Bitwig Studio")

        let a = try await first.ask(["type": "claim", "slot": "A"])
        XCTAssertEqual(a["type"] as? String, "claimed")
        XCTAssertEqual(a["name"] as? String, "One")
        let b = try await second.ask(["type": "claim", "slot": "b"])
        XCTAssertEqual(b["type"] as? String, "claimed")
        XCTAssertEqual(b["name"] as? String, "Two")

        let taken = try await third.ask(["type": "claim", "slot": "A"])
        XCTAssertEqual(taken["code"] as? String, "slot_taken")
        XCTAssertEqual(taken["message"] as? String, "Slot A is already used by G2 VST in Logic Pro")

        // Zamknięty projekt zwalnia slot — czekająca wtyczka dostaje o tym wiadomość.
        first.close()
        try await waitUntil { self.bridge.clients.count == 2 }
        let freed = try await third.next()
        XCTAssertEqual(freed["type"] as? String, "slots_free")
        XCTAssertEqual(freed["slots"] as? [String], ["A"])
        let retry = try await third.ask(["type": "claim", "slot": "A"])
        XCTAssertEqual(retry["type"] as? String, "claimed")
    }

    func testClaimingAnotherSlotReleasesTheFirst() async throws {
        let first = try await TestPlugin.greeted(path)
        let second = try await TestPlugin.greeted(path)
        _ = try await first.ask(["type": "claim", "slot": "C"])
        _ = try await first.ask(["type": "claim", "slot": "D"])
        let reply = try await second.ask(["type": "claim", "slot": "C"])
        XCTAssertEqual(reply["type"] as? String, "claimed")
    }

    /// „Make this one active" (Etap 3): przejęcie zajętego slotu. Poprzedni właściciel oddaje
    /// wszystko, dostaje `taken_over` z czytelnym komunikatem i czeka — a gdy nowy odda slot,
    /// dowiaduje się o tym (`slots_free`) i może go wziąć z powrotem.
    func testTakeOverMovesTheSlotAndTheFormerOwnerWaits() async throws {
        let first = try await TestPlugin.greeted(path, host: "Logic Pro")
        let second = try await TestPlugin.greeted(path, host: "Bitwig Studio")
        _ = try await first.ask(["type": "claim", "slot": "A"])

        let taken = try await second.ask(["type": "claim", "slot": "A", "take": true])
        XCTAssertEqual(taken["type"] as? String, "claimed")
        XCTAssertEqual(taken["name"] as? String, "One")
        let told = try await first.next()
        XCTAssertEqual(told["type"] as? String, "taken_over")
        XCTAssertEqual(told["slots"] as? [String], ["A"])
        XCTAssertEqual(told["message"] as? String, "Slot A is now used by G2 VST in Bitwig Studio")
        XCTAssertEqual(bridge.clients.values.filter { $0.slots == [0] }.count, 1)

        // Czekająca nie gra: jej nuty nie mają już slotu.
        _ = try await second.ask(["type": "release"])
        let freed = try await first.next()
        XCTAssertEqual(freed["type"] as? String, "slots_free")
        let back = try await first.ask(["type": "claim", "slot": "A"])
        XCTAssertEqual(back["type"] as? String, "claimed")
    }

    /// Przejęcie przez wtyczkę Performance zabiera sloty wszystkim, którzy je trzymali.
    func testPerformanceTakeOverDisplacesEverySlotOwner() async throws {
        let a = try await TestPlugin.greeted(path)
        let c = try await TestPlugin.greeted(path)
        let multi = try await TestPlugin.greeted(path, host: "Logic Pro")
        _ = try await a.ask(["type": "claim", "slot": "A"])
        _ = try await c.ask(["type": "claim", "slot": "C"])
        let claimed = try await multi.ask(["type": "claim", "performance": true, "take": true])
        XCTAssertEqual(claimed["performance"] as? Bool, true)
        let toldA = try await a.next()
        let toldC = try await c.next()
        XCTAssertEqual(toldA["type"] as? String, "taken_over")
        XCTAssertEqual(toldC["message"] as? String, "Slot C is now used by G2 VST in Logic Pro")
    }

    /// Tryb Performance: jedna instancja z Multi-timbral w DAW-ie zajmuje cztery sloty naraz.
    func testPerformanceClaimTakesAllFourSlots() async throws {
        let multi = try await TestPlugin.greeted(path, host: "Logic Pro")
        let single = try await TestPlugin.greeted(path)
        let claimed = try await multi.ask(["type": "claim", "performance": true])
        XCTAssertEqual(claimed["type"] as? String, "claimed")
        XCTAssertEqual(claimed["performance"] as? Bool, true)
        let slots = try XCTUnwrap(claimed["slots"] as? [[String: Any]])
        XCTAssertEqual(slots.compactMap { $0["name"] as? String }, ["One", "Two", "Three", "Four"])

        let taken = try await single.ask(["type": "claim", "slot": "C"])
        XCTAssertEqual(taken["message"] as? String, "Slot C is already used by G2 VST in Logic Pro")

        state.slots[2].name = "Changed"
        let pushed = try await multi.next()
        XCTAssertEqual(pushed["type"] as? String, "slot_changed")
        XCTAssertEqual(pushed["slot"] as? String, "C")
    }

    func testPerformanceClaimNeedsEverySlotFree() async throws {
        let single = try await TestPlugin.greeted(path, host: "Bitwig Studio")
        let multi = try await TestPlugin.greeted(path)
        _ = try await single.ask(["type": "claim", "slot": "B"])
        let refused = try await multi.ask(["type": "claim", "performance": true])
        XCTAssertEqual(refused["message"] as? String, "Slot B is already used by G2 VST in Bitwig Studio")
        XCTAssertEqual(bridge.clients.values.map(\.slots).sorted { $0.count > $1.count }, [[1], []])
    }

    /// „Make this one active” w jednej instancji grupy budzi czekające z tej samej grupy; obudzone
    /// (`auto`) nie budzą dalej, więc dwie instancje na tym samym slocie nie przerzucają się w kółko.
    func testGroupActivationWakesWaitingMembersWithoutLooping() async throws {
        let lead1 = try await TestPlugin.greeted(path, host: "Logic Pro")
        let lead2 = try await TestPlugin.greeted(path, host: "Logic Pro")
        let lead3 = try await TestPlugin.greeted(path, host: "Logic Pro")
        let pad1 = try await TestPlugin.greeted(path, host: "Logic Pro")
        let pad2 = try await TestPlugin.greeted(path, host: "Logic Pro")
        _ = try await lead1.ask(["type": "claim", "slot": "A", "group": "Lead"])
        _ = try await lead2.ask(["type": "claim", "slot": "B", "group": "Lead"])
        let refused = try await lead3.ask(["type": "claim", "slot": "A", "group": "Lead"])
        XCTAssertEqual(refused["code"] as? String, "slot_taken")
        _ = try await pad1.ask(["type": "claim", "slot": "A", "take": true, "group": "Pad"])
        _ = try await pad2.ask(["type": "claim", "slot": "B", "take": true, "group": "Pad"])
        let lead1Message1 = try await lead1.next()
        XCTAssertEqual(lead1Message1["type"] as? String, "taken_over")
        let lead2Message1 = try await lead2.next()
        XCTAssertEqual(lead2Message1["type"] as? String, "taken_over")

        // Lead 1 wraca: Lead 2 i Lead 3 (czekają, ta sama grupa) dostają `activate`, Pad nie.
        _ = try await lead1.ask(["type": "claim", "slot": "A", "take": true, "group": "Lead"])
        let lead2Message2 = try await lead2.next()
        XCTAssertEqual(lead2Message2["type"] as? String, "activate")
        let lead3Message1 = try await lead3.next()
        XCTAssertEqual(lead3Message1["type"] as? String, "activate")
        let pad1Message1 = try await pad1.next()
        XCTAssertEqual(pad1Message1["type"] as? String, "taken_over")

        // Lead 2 zajmuje swój slot jako obudzony: nie budzi nikogo, Pad 2 oddaje slot B.
        _ = try await lead2.ask(["type": "claim", "slot": "B", "take": true, "auto": true, "group": "Lead"])
        let pad2Message1 = try await pad2.next()
        XCTAssertEqual(pad2Message1["type"] as? String, "taken_over")
        let ping = try await lead3.ask(["type": "midi_ports"])
        XCTAssertEqual(ping["type"] as? String, "midi_ports", "an automatic claim must not wake the group again")
        XCTAssertEqual(bridge.clients.values.filter { $0.group == "Lead" && !$0.slots.isEmpty }.count, 2)
    }

    /// Kabel MIDI do Norda: lista wejść w odpowiedzi, wybór zapamiętany przy wtyczce, nuty kierowane
    /// do wybranego portu (bez urządzenia w teście — sprawdzamy to, co edytor trzyma o kliencie).
    func testMidiPortChoiceIsKeptAndListed() async throws {
        let plugin = try await TestPlugin.greeted(path)
        let ports = try await plugin.ask(["type": "midi_ports"])
        XCTAssertEqual(ports["type"] as? String, "midi_ports")
        XCTAssertNotNil(ports["ports"] as? [String])
        XCTAssertFalse((ports["ports"] as? [String] ?? []).contains(MidiNoteOutput.virtualG2))
        let chosen = try await plugin.ask(["type": "midi_port", "port": "Test Interface"])
        XCTAssertEqual(chosen["type"] as? String, "midi_port")
        XCTAssertEqual(chosen["port"] as? String, "Test Interface")
        XCTAssertEqual(bridge.clients.values.first?.midiPort, "Test Interface")
        _ = try await plugin.ask(["type": "midi_port", "port": ""])
        XCTAssertEqual(bridge.clients.values.first?.midiPort, "")
    }

    /// Ustawienia performance'u jadą do piosenki (`performance`) i wracają z niej (`put_performance`).
    func testPerformanceSettingsTravelToTheSongAndBack() async throws {
        var settings = G2PerformanceSettings()
        settings.masterClock = 93
        state.applyPerformanceSettings(settings, name: "Song Perf", actionName: "Test")
        let multi = try await TestPlugin.greeted(path, host: "Logic Pro")
        let claimed = try await multi.ask(["type": "claim", "performance": true])
        XCTAssertEqual(claimed["performance"] as? Bool, true)
        let sent = try await multi.next(of: "performance")
        XCTAssertEqual(sent["name"] as? String, "Song Perf")
        let data = try XCTUnwrap(sent["data"] as? String)
        XCTAssertNotNil(sent["version"] as? String)

        // Ktoś zmienił zegar w edytorze — piosenka dostaje nowy plik z innym odciskiem.
        state.performance.masterClock = 120
        let changed = try await multi.next(of: "performance")
        XCTAssertNotEqual(changed["version"] as? String, sent["version"] as? String)

        // Piosenka odsyła swoje ustawienia: edytor je przyjmuje jednym krokiem Undo.
        let stored = try await multi.ask(["type": "put_performance", "name": "Song Perf", "data": data])
        XCTAssertEqual(stored["type"] as? String, "stored_performance")
        XCTAssertEqual(state.performance.masterClock, 93)
        state.undoManager.undo()
        XCTAssertEqual(state.performance.masterClock, 120)

        // Plugin w trybie Slot nie ma prawa pisać ustawień performance'u.
        let single = try await TestPlugin.greeted(path)
        let refused = try await single.ask(["type": "put_performance", "data": data])
        XCTAssertEqual(refused["code"] as? String, "claim_first")
    }

    /// Arpeggiator z Patch Settings: wtyczka dostaje jego stan (`arp`) i zmienia go (`arp_set`) jak suwaki edytora.
    func testPluginReadsAndChangesTheArpeggiatorOfItsSlot() async throws {
        let plugin = try await TestPlugin.greeted(path, host: "Logic Pro")
        try plugin.send(["type": "claim", "slot": "A"])
        let first = try await plugin.next(of: "arp")
        XCTAssertEqual(first["slot"] as? String, "A")
        let variation = state.slots[0].activeVariation
        let initial = state.slots[0].variationSettings[variation]
        XCTAssertEqual(first["values"] as? [Int], [initial.arpeggiator, initial.arpTime, initial.arpType, initial.arpOctaves],
                       "the plugin gets what the editor has")

        try plugin.send(["type": "arp_set", "slot": "A", "field": "on", "value": 1])
        try plugin.send(["type": "arp_set", "slot": "A", "field": "type", "value": 3])
        // Bez odpowiedzi: stan wraca paczką `arp`.
        let changed = try await plugin.next(of: "arp")
        XCTAssertEqual(state.slots[0].variationSettings[variation].arpeggiator, 1)
        XCTAssertEqual(changed["slot"] as? String, "A")

        // Poza zakresem wartość jest ucinana, a cudzy slot nie przyjmuje zmian.
        try plugin.send(["type": "arp_set", "slot": "A", "field": "octaves", "value": 99])
        try plugin.send(["type": "arp_set", "slot": "B", "field": "on", "value": 1])
        _ = try await plugin.next(of: "arp")
        XCTAssertEqual(state.slots[0].variationSettings[variation].arpOctaves, 3)
        XCTAssertNotEqual(state.slots[1].variationSettings[state.slots[1].activeVariation].arpeggiator, 1,
                          "a slot the plugin does not hold is left alone")

        state.undoManager.undo()
        XCTAssertNotEqual(state.slots[0].variationSettings[variation].arpOctaves, 3, "one Undo step per change")
    }

    /// „Add sequencer" z wtyczki: patch bez sekwencera dostaje SeqNote w miejscu klawiatury; bez klawiatury — odmowa.
    func testPluginAddsASequencerToItsSlot() async throws {
        var patch = G2Patch()
        patch.voiceModules = [G2Module(id: 1, typeID: 1, area: .voice), G2Module(id: 2, typeID: 20, area: .voice)]
        patch.voiceCables = [G2Cable(fromModule: 1, fromConnector: 1, toModule: 2, toConnector: 1, color: .yellow, area: .voice)]
        state.loadFromDevice(patches: [patch, patch, patch, patch])
        let plugin = try await TestPlugin.greeted(path, host: "Logic Pro")
        _ = try await plugin.ask(["type": "claim", "slot": "B"])

        let refused = try await plugin.ask(["type": "add_sequencer", "slot": "A"])
        XCTAssertEqual(refused["code"] as? String, "claim_first")

        let added = try await plugin.ask(["type": "add_sequencer", "slot": "B"])
        XCTAssertEqual(added["type"] as? String, "sequencer_added")
        XCTAssertEqual(added["result"] as? String, "added")
        let sequencerID = try XCTUnwrap(added["id"] as? Int)
        XCTAssertTrue(state.slots[1].modules(in: .voice).contains { $0.id == sequencerID && $0.typeID == PatchState.noteSequencerTypeID })
        XCTAssertFalse(state.slots[0].modules(in: .voice).contains { $0.typeID == PatchState.noteSequencerTypeID },
                       "other slots are left alone")
        // Nowy sekwencer wraca do wtyczki zwykłą paczką.
        let list = try await plugin.nextSequencers()
        XCTAssertEqual((list["list"] as? [[String: Any]])?.count, 1)
    }

    /// `.prf2` z przeglądarki: cztery sloty i ustawienia; opis sumuje DSP czterech patchy.
    func testBrowserLoadsAPerformanceFileIntoAllFourSlots() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("g2pb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var settings = G2PerformanceSettings()
        settings.masterClock = 111
        for index in 0 ..< 4 { settings.slots[index].name = "P\(index + 1)" }
        let source = PatchState()
        source.loadFromDevice(patches: ["P1", "P2", "P3", "P4"].map { name in
            var patch = state.slots[0]
            patch.name = name
            return patch
        })
        source.applyPerformanceSettings(settings, name: nil, actionName: "Test")
        let file = folder.appendingPathComponent("Big Sound.prf2")
        source.savePerformance(as: file)
        try FileManager.default.copyItem(at: folder.appendingPathComponent("Big Sound.prf2"),
                                         to: folder.appendingPathComponent("Other.prf2"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "g2pb-\(UUID().uuidString)"))
        defaults.set(folder.path, forKey: "g2_disk_bank_folder")
        bridge.browserDefaults = defaults

        let multi = try await TestPlugin.greeted(path)
        let patches = try await multi.ask(["type": "browse", "id": 1, "query": ""])
        XCTAssertEqual(patches["total"] as? Int, 0, "patch listing must not show performances")
        let performances = try await multi.ask(["type": "browse", "id": 2, "query": "big", "kind": "performance"])
        XCTAssertEqual(performances["total"] as? Int, 1)
        // Przyciski pch2 / prf2 we wtyczce: „all" miesza oba rodzaje (w folderze są tylko dwa .prf2).
        let both = try await multi.ask(["type": "browse", "id": 3, "query": "", "kind": "all"])
        XCTAssertEqual(both["total"] as? Int, 2)

        // Tag Findera z menu wiersza przeglądarki wtyczki: zapisuje edytor, odpowiedź niesie listę kolorów.
        // Ścieżka z listy (po rozwiązaniu dowiązań /var → /private/var), taka, jaką widzi wtyczka.
        let listedPath = try XCTUnwrap((performances["items"] as? [[Any]])?.first?[0] as? String)
        var reported: [(URL, [Int])] = []
        bridge.onTagsChanged = { url, tags in reported.append((url, tags.map(\.color))) }
        let tagged = try await multi.ask(["type": "set_tag", "path": listedPath, "color": 6, "on": true])
        XCTAssertEqual(reported.count, 1, "the Patches panel is told about the tag")
        XCTAssertEqual(reported.first?.0.path, listedPath)
        XCTAssertEqual(reported.first?.1, [6])
        XCTAssertEqual(tagged["type"] as? String, "tag_set")
        XCTAssertEqual(tagged["tags"] as? [Int], [6])
        let listed = try await multi.ask(["type": "browse", "id": 4, "query": "big", "kind": "performance"])
        XCTAssertEqual((listed["items"] as? [[Any]])?.first?[5] as? [Int], [6])
        let untagged = try await multi.ask(["type": "set_tag", "path": listedPath, "color": 6, "on": false])
        XCTAssertEqual(untagged["tags"] as? [Int], [])

        let info = try await multi.ask(["type": "patch_info", "path": file.path])
        XCTAssertEqual(info["slots"] as? [String], ["P1", "P2", "P3", "P4"])
        XCTAssertEqual(info["category"] as? String, "Performance")

        let early = try await multi.ask(["type": "load_patch", "slot": "A", "path": file.path])
        XCTAssertEqual(early["code"] as? String, "claim_first")
        _ = try await multi.ask(["type": "claim", "performance": true])
        let loaded = try await multi.ask(["type": "load_patch", "slot": "A", "path": file.path])
        XCTAssertEqual(loaded["type"] as? String, "loaded")
        XCTAssertEqual(state.slots.prefix(4).map(\.name), ["P1", "P2", "P3", "P4"])
        XCTAssertEqual(state.performance.masterClock, 111)
        XCTAssertEqual(state.performanceName, "Big Sound")
    }

    func testNotesFollowTheSlotOrTheChannel() {
        let events = [[1, 60, 90, 0], [1, 62, 80, 1], [1, 64, 70, 3], [1, 65, 60, 4], [0, 60, 0, 0]]
        let single = PluginBridge.Client(name: "", format: "", host: "", slots: [2])
        let slotRoute = PluginBridge.route(events, client: single)
        XCTAssertEqual(slotRoute.map(\.slot), [2])
        XCTAssertEqual(slotRoute[0].notes.map(\.key), [60, 62, 64, 65, 60])

        let multi = PluginBridge.Client(name: "", format: "", host: "", slots: [0, 1, 2, 3], performance: true)
        let performanceRoute = PluginBridge.route(events, client: multi)
        XCTAssertEqual(performanceRoute.map(\.slot), [0, 1, 3]) // kanał 5 odpada
        XCTAssertEqual(performanceRoute[0].notes.map(\.key), [60, 60])
        XCTAssertEqual(performanceRoute[1].notes.first?.velocity, 80)
    }

    /// Etap 3, okno wtyczki zamknięte: pytanie idzie przez edytor, odpowiedź wraca do wtyczki.
    func testQuestionFromPluginIsAnsweredInTheEditor() async throws {
        let plugin = try await TestPlugin.greeted(path, host: "Logic Pro")
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        let noted = try await plugin.ask(["type": "questions",
                                          "questions": [["slot": "A", "song": "Old Pad", "g2": "One"]]])
        XCTAssertEqual(noted["type"] as? String, "noted")
        let (id, client) = try XCTUnwrap(bridge.clients.first)
        XCTAssertEqual(client.questions, [PluginBridge.Question(slot: 0, song: "Old Pad", g2: "One")])
        XCTAssertEqual(PluginBridge.title(of: client), "G2 VST in Logic Pro")

        bridge.answer(id, sendSongPatch: true)

        let answer = try await plugin.next()
        XCTAssertEqual(answer["type"] as? String, "answer")
        XCTAssertEqual(answer["send"] as? Bool, true)
        XCTAssertEqual(bridge.clients[id]?.questions, [])
    }

    func testGetSlotGivesReadablePatch() async throws {
        let plugin = try await TestPlugin.greeted(path)
        let reply = try await plugin.ask(["type": "get_slot", "slot": "C"])
        XCTAssertEqual(reply["name"] as? String, "Three")
        let data = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(reply["patch"] as? String)))
        let patch = try XCTUnwrap(PatchParser.parseFile(data: data).patches.first)
        XCTAssertEqual(patch.voiceModules.count, state.slots[2].voiceModules.count)
    }

    func testPutSlotReplacesThePatchAsOneUndoStep() async throws {
        let plugin = try await TestPlugin.greeted(path, host: "Logic Pro")
        let slot = try await plugin.ask(["type": "get_slot", "slot": "B"])
        var patch = try await plugin.ask(["type": "put_slot", "slot": "B", "patch": XCTUnwrap(slot["patch"]), "replace": true])
        XCTAssertEqual(patch["code"] as? String, "claim_first")

        let claimed = try await plugin.ask(["type": "claim", "slot": "B"])
        patch = try await plugin.ask(["type": "put_slot", "slot": "B", "patch": XCTUnwrap(slot["patch"]),
                                      "name": "From Song", "expect_version": "0000"])
        XCTAssertEqual(patch["code"] as? String, "version_changed")

        // #191: cały slot idzie do Norda jedną komendą (`sendWholeSlot`), nie różnicą modułów.
        var structureSent = 0
        state.onLiveStructureChange = { _, _ in structureSent += 1 }
        let stored = try await plugin.ask(["type": "put_slot", "slot": "B", "patch": XCTUnwrap(slot["patch"]),
                                           "name": "From Song", "expect_version": XCTUnwrap(claimed["version"])])
        XCTAssertEqual(stored["type"] as? String, "stored")
        XCTAssertEqual(state.slots[1].name, "From Song")
        XCTAssertEqual(structureSent, 0)
        XCTAssertEqual(state.undoManager.undoActionName, "Patch from Logic Pro")
        state.undoManager.undo()
        XCTAssertEqual(state.slots[1].name, "Two")
    }

    /// Klik slotu we wtyczce = ten sam ruch co w górnym pasku edytora (focus → `SelectSlot` do Norda).
    func testFocusSlotFromThePluginSelectsTheSlotInTheEditor() async throws {
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "C"])
        let before = state.selectedSlot
        XCTAssertNotEqual(before, 2)
        try plugin.send(["type": "focus_slot", "slot": "C"])
        _ = try await plugin.ask(["type": "get_slot", "slot": "C"]) // odpowiedź = focus już przetworzony
        XCTAssertEqual(state.selectedSlot, 2)
        try plugin.send(["type": "focus_slot", "slot": "Z"])
        _ = try await plugin.ask(["type": "get_slot", "slot": "C"])
        XCTAssertEqual(state.selectedSlot, 2, "an unknown slot is ignored")
    }

    /// Odwrotny kierunek: slot aktywny w edytorze (klik w pasku, przycisk na froncie Norda) dochodzi do wtyczki —
    /// także zaraz po otwarciu projektu, żeby okno pokazało slot, który Nord ma teraz wybrany.
    func testActiveSlotIsPushedToThePlugin() async throws {
        state.selectedSlot = 1
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        let first = try await plugin.next(of: "focus")
        XCTAssertEqual(first["slot"] as? String, "B")
        state.selectedSlot = 3
        let second = try await plugin.next(of: "focus")
        XCTAssertEqual(second["slot"] as? String, "D")
    }

    func testEditorChangeIsPushedToTheClaimingPlugin() async throws {
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "D"])
        state.slots[3].name = "Renamed"
        let pushed = try await plugin.next()
        XCTAssertEqual(pushed["type"] as? String, "slot_changed")
        XCTAssertEqual(pushed["slot"] as? String, "D")
        XCTAssertEqual(pushed["name"] as? String, "Renamed")
    }

    func testMissingSlotIsReportedAsUnavailable() async throws {
        state.slots = [state.slots[0]]
        let plugin = try await TestPlugin.greeted(path)
        let claimed = try await plugin.ask(["type": "claim", "slot": "C"])
        XCTAssertEqual(claimed["type"] as? String, "claimed")
        XCTAssertEqual(claimed["available"] as? Bool, false)
        let get = try await plugin.ask(["type": "get_slot", "slot": "C"])
        XCTAssertEqual(get["code"] as? String, "no_slot")
    }

    // MARK: - Automatyka (Etap 4)

    func testClaimSendsTheWholeAutomationList() async throws {
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        let list = try await plugin.nextAutomation()
        XCTAssertEqual(list["slot"] as? String, "A")
        XCTAssertEqual(list["touch"] as? Bool, false)
        let values = try XCTUnwrap(list["values"] as? [[Any]])
        XCTAssertEqual(values.count, PluginAutomation.ids.count)
        XCTAssertEqual(values.first?[0] as? Int, PluginAutomation.variation)
        XCTAssertEqual(values.first?[2] as? String, "\(state.slots[0].activeVariation + 1)")
    }

    func testDAWMovesMorphAndVariationWithoutUndoOrUnsavedChanges() async throws {
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        _ = try await plugin.nextAutomation()
        try plugin.send(["type": "automate", "slot": "A", "values": [[0, 3], [2, 100]]])
        try await waitUntil { self.state.slots[0].activeVariation == 3 }
        XCTAssertEqual(state.slots[0].morphDial(1, in: 3), 100)
        XCTAssertFalse(state.undoManager.canUndo)
        XCTAssertFalse(state.hasUnsavedChanges)
    }

    func testDAWMovesAKnobOfTheParameterPages() async throws {
        let module = try XCTUnwrap(state.slots[0].voiceModules.first { !$0.parameters.isEmpty })
        state.slots[0].assignKnob(index: 9, location: PatchArea.voice.rawValue, moduleID: module.id, paramIndex: 0)
        state.focusedParameterPage = 1
        let maxValue = G2ParameterText.maxValue(moduleTypeID: module.typeID, paramIndex: 0)
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        let list = try await plugin.nextAutomation()
        let names = try XCTUnwrap(list["names"] as? [[Any]])
        XCTAssertTrue(names.contains { $0[0] as? Int == 22 }, "page knob 2 of page A2 is named")
        XCTAssertTrue(names.contains { $0[0] as? Int == 109 }, "knob A2-2 is named")
        // Moduł idzie osobno: wtyczka nie dzieli „Moduł Parametr” na spacji („Osc Mix” + „Lev1”).
        let named = try XCTUnwrap(names.first { $0[0] as? Int == 109 })
        XCTAssertEqual(named.count, 3)
        let moduleName = try XCTUnwrap(named[2] as? String)
        XCTAssertTrue((named[1] as? String ?? "").hasPrefix(moduleName + " "))

        try plugin.send(["type": "automate", "slot": "A", "values": [[109, 1.0]]])
        try await waitUntil { self.state.slots[0].voiceModules.first { $0.id == module.id }?.parameters[0] == maxValue }
        try plugin.send(["type": "automate", "slot": "A", "values": [[22, 0.0]]])
        try await waitUntil { self.state.slots[0].voiceModules.first { $0.id == module.id }?.parameters[0] == 0 }
        XCTAssertFalse(state.undoManager.canUndo)
    }

    /// Regresja z 2026-11-25: każda zmiana patcha dokładała obserwatorów automatyki
    /// i wskazówki sekwencera, a stare odnawiały się dalej — po godzinie kręcenia gałką
    /// edytor budził ich tysiące przy każdym ruchu. Zmiana ma kosztować stałą liczbę zapisów.
    func testObserversDoNotPileUpWithEveryPatchChange() async throws {
        for value in 1 ... 30 {
            state.setMorphDial(0, value: value, slot: 0)
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let before = bridge.observationRegistrations
        for value in 31 ... 40 {
            state.setMorphDial(0, value: value, slot: 0)
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let perChange = Double(bridge.observationRegistrations - before) / 10
        XCTAssertLessThanOrEqual(perChange, 2.5, "observers keep piling up: \(perChange) per change")
    }

    func testEditorKnobMoveIsPushedAsTouch() async throws {
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        _ = try await plugin.nextAutomation()
        state.setMorphDial(0, value: 64, slot: 0)
        let change = try await plugin.nextAutomation()
        XCTAssertEqual(change["touch"] as? Bool, true)
        let values = try XCTUnwrap(change["values"] as? [[Any]])
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?[0] as? Int, 1)
        XCTAssertEqual(values.first?[1] as? Int, 64)
    }

    func testAutomationOfAnotherPluginsSlotIsIgnored() async throws {
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        try plugin.send(["type": "automate", "slot": "B", "values": [[0, 5]]])
        // Postać, której używa wtyczka: slot przy każdej wartości (tryb Performance ma cztery).
        try plugin.send(["type": "automate", "values": [[1, 0, 6], [0, 0, 2]]])
        try await waitUntil { self.state.slots[0].activeVariation == 2 }
        XCTAssertNotEqual(state.slots[1].activeVariation, 5)
    }

    func testLearnAssignsTheNextMovedParameter() async throws {
        let module = try XCTUnwrap(state.slots[0].voiceModules.first { $0.parameters.count > 1 })
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        let on = try await plugin.ask(["type": "learn", "on": true])
        XCTAssertEqual(on["on"] as? Bool, true)
        // Ruch z DAW-a się nie liczy — dopiero ruch ręki.
        try plugin.send(["type": "automate", "slot": "A", "values": [[1, 30]]])
        try await waitUntil { self.state.slots[0].morphDial(0, in: self.state.slots[0].activeVariation) == 30 }
        let old = module.parameters[1]
        state.setParameter(slot: 0, moduleID: module.id, paramIndex: 1, value: old == 0 ? 5 : 0, area: .voice)
        let learned = try await plugin.next()
        XCTAssertEqual(learned["type"] as? String, "learned")
        XCTAssertEqual(learned["slot"] as? String, "A")
        XCTAssertEqual(learned["location"] as? Int, Int(PatchArea.voice.rawValue))
        XCTAssertEqual(learned["module"] as? Int, module.id)
        XCTAssertEqual(learned["param"] as? Int, 1)
        XCTAssertFalse((learned["name"] as? String ?? "").isEmpty)

        let noted = try await plugin.ask(["type": "learn_map", "slot": "A",
                                          "map": [[300, Int(PatchArea.voice.rawValue), module.id, 1]]])
        XCTAssertEqual(noted["type"] as? String, "noted")
        var named = false
        for _ in 0 ..< 5 where !named {
            let list = try await plugin.nextAutomation()
            named = (list["names"] as? [[Any]] ?? []).contains { $0[0] as? Int == 300 }
        }
        XCTAssertTrue(named, "Learn 1 gets the parameter's name")
        try plugin.send(["type": "automate", "slot": "A", "values": [[300, 0.0]]])
        try await waitUntil { self.state.slots[0].voiceModules.first { $0.id == module.id }?.parameters[1] == 0 }
    }

    func testPluginArpeggioWritesTheNotesAsOneUndoStep() async throws {
        var seq = G2Module(id: 91, typeID: 121, area: .voice)
        seq.parameters = Array(repeating: 64, count: 16) + Array(repeating: 1, count: 16) + [1, 15, 0, 0, 0, 0]
        state.slots[0].voiceModules.append(seq)
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        _ = try await plugin.nextSequencers()

        try plugin.send(["type": "seq_arpeggio", "slot": "A", "location": 1, "module": 91, "root": 48,
                         "chord": "major", "direction": "up", "octaves": 1])
        try await waitUntil { self.state.slots[0].voiceModules.last?.parameters[15] == 48 }
        let notes = Array(state.slots[0].voiceModules.last?.parameters[0 ..< 16] ?? [])
        XCTAssertEqual(notes, (0 ..< 16).map { [48, 52, 55][$0 % 3] }, "C major up, repeated over 16 steps")
        XCTAssertEqual(Array(state.slots[0].voiceModules.last?.parameters[16 ..< 32] ?? []),
                       Array(repeating: 1, count: 16), "the gates are not touched")
        state.undoManager.undo()
        XCTAssertEqual(Array(state.slots[0].voiceModules.last?.parameters[0 ..< 3] ?? []), [64, 64, 64], "one Undo step")

        // A sequencer that is not a SeqNote has no notes to write.
        try plugin.send(["type": "seq_arpeggio", "slot": "A", "location": 1, "module": 91, "root": 48,
                         "chord": "nonsense", "direction": "up", "octaves": 1])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(state.slots[0].voiceModules.last?.parameters[0], 64, "an unknown chord changes nothing")
    }

    func testPluginRandomAndMutateStayInTheScale() async throws {
        var seq = G2Module(id: 92, typeID: 121, area: .voice)
        seq.parameters = Array(repeating: 60, count: 16) + Array(repeating: 1, count: 16) + [1, 7, 0, 0, 0, 0]
        state.slots[0].voiceModules.append(seq)
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        _ = try await plugin.nextSequencers()
        let cMajor: Set = [0, 2, 4, 5, 7, 9, 11]

        try plugin.send(["type": "seq_random", "slot": "A", "location": 1, "module": 92, "mode": "random", "root": 0,
                         "scale": "major", "low": 48, "high": 72, "percent": 0])
        try await waitUntil { (self.state.slots[0].voiceModules.last?.parameters[0 ..< 16] ?? []).contains { $0 != 60 } }
        var notes = Array(state.slots[0].voiceModules.last?.parameters[0 ..< 16] ?? [])
        XCTAssertTrue(notes.allSatisfy { (48 ... 72).contains($0) && cMajor.contains($0 % 12) }, "random stays in C major, 48…72")
        XCTAssertEqual(Array(state.slots[0].voiceModules.last?.parameters[16 ..< 32] ?? []), Array(repeating: 1, count: 16))

        // Mutate 25 % of a 8-step sequencer = 2 steps; steps after the length stay.
        let before = notes
        try plugin.send(["type": "seq_random", "slot": "A", "location": 1, "module": 92, "mode": "mutate", "root": 0,
                         "scale": "major", "low": 48, "high": 72, "percent": 25])
        try await Task.sleep(nanoseconds: 300_000_000)
        notes = Array(state.slots[0].voiceModules.last?.parameters[0 ..< 16] ?? [])
        XCTAssertLessThanOrEqual(zip(before, notes).filter { $0 != $1 }.count, 2, "at most 25 % of 8 steps change")
        XCTAssertEqual(Array(notes[8...]), Array(before[8...]), "steps after Length are left alone")
        XCTAssertTrue(notes.allSatisfy { cMajor.contains($0 % 12) })

        try plugin.send(["type": "seq_random", "slot": "A", "location": 1, "module": 92, "mode": "random", "root": 0,
                         "scale": "nonsense", "low": 48, "high": 72, "percent": 0])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(Array(state.slots[0].voiceModules.last?.parameters[0 ..< 16] ?? []), notes, "an unknown scale changes nothing")
    }

    func testPluginWalkMovesInSmallStepsAndHumanizeNudgesPlayedSteps() async throws {
        var notes = G2Module(id: 93, typeID: 121, area: .voice)
        notes.parameters = Array(repeating: 60, count: 16) + Array(repeating: 1, count: 16) + [1, 15, 0, 0, 0, 0]
        var levels = G2Module(id: 94, typeID: 146, area: .voice)
        // Steps 0–3 play, 4–7 rest; length 8.
        levels.parameters = Array(repeating: 64, count: 16) + [1, 1, 1, 1] + Array(repeating: 0, count: 12) + [1, 7, 0, 0, 0, 0]
        state.slots[0].voiceModules.append(contentsOf: [notes, levels])
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        _ = try await plugin.nextSequencers()

        try plugin.send(["type": "seq_random", "slot": "A", "location": 1, "module": 93, "mode": "walk", "root": 0,
                         "scale": "major", "low": 48, "high": 72, "percent": 0])
        try await waitUntil { (self.state.slots[0].voiceModules[self.state.slots[0].voiceModules.count - 2].parameters[0 ..< 16]).contains { $0 != 60 } }
        let walk = Array(state.slots[0].voiceModules[state.slots[0].voiceModules.count - 2].parameters[0 ..< 16])
        XCTAssertTrue(walk.allSatisfy { (48 ... 72).contains($0) && [0, 2, 4, 5, 7, 9, 11].contains($0 % 12) }, "walk stays in the scale")
        XCTAssertTrue(zip(walk, walk.dropFirst()).allSatisfy { abs($0 - $1) <= 12 }, "walk moves in small steps")

        try plugin.send(["type": "seq_humanize", "slot": "A", "location": 1, "module": 94, "amount": 100])
        try await waitUntil { (self.state.slots[0].voiceModules.last?.parameters[0 ..< 4] ?? []).contains { $0 != 64 } }
        let values = Array(state.slots[0].voiceModules.last?.parameters[0 ..< 16] ?? [])
        XCTAssertEqual(Array(values[4...]), Array(repeating: 64, count: 12), "resting steps and steps after Length stay")
        state.undoManager.undo()
        XCTAssertEqual(Array(state.slots[0].voiceModules.last?.parameters[0 ..< 4] ?? []), [64, 64, 64, 64], "one Undo step")

        // A note sequencer has no values to humanize.
        try plugin.send(["type": "seq_humanize", "slot": "A", "location": 1, "module": 93, "amount": 100])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(Array(state.slots[0].voiceModules[state.slots[0].voiceModules.count - 2].parameters[0 ..< 16]), walk)
    }

    func testPluginMotifAndArpeggioFromThePattern() async throws {
        var seq = G2Module(id: 95, typeID: 121, area: .voice)
        // The pattern plays C, E, G, E over 4 steps (Length 3 = 4 steps); the rest is far away from them.
        seq.parameters = [60, 64, 67, 64] + Array(repeating: 100, count: 12) + Array(repeating: 1, count: 16) + [1, 3, 0, 0, 0, 0]
        state.slots[0].voiceModules.append(seq)
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        _ = try await plugin.nextSequencers()

        try plugin.send(["type": "seq_arpeggio", "slot": "A", "location": 1, "module": 95, "root": 0,
                         "chord": "pattern", "direction": "up", "octaves": 1])
        try await waitUntil { self.state.slots[0].voiceModules.last?.parameters[15] != 100 }
        let arp = Array(state.slots[0].voiceModules.last?.parameters[0 ..< 16] ?? [])
        XCTAssertEqual(arp, (0 ..< 16).map { [60, 64, 67][$0 % 3] }, "the pattern's own notes, up, over 16 steps")

        try plugin.send(["type": "seq_random", "slot": "A", "location": 1, "module": 95, "mode": "motif", "root": 0,
                         "scale": "major", "low": 48, "high": 72, "percent": 0])
        try await waitUntil { Array(self.state.slots[0].voiceModules.last?.parameters[0 ..< 16] ?? []) != arp }
        let motif = Array(state.slots[0].voiceModules.last?.parameters[0 ..< 16] ?? [])
        XCTAssertTrue(motif.allSatisfy { (48 ... 72).contains($0) && [0, 2, 4, 5, 7, 9, 11].contains($0 % 12) }, "motif stays in the scale")
    }

    func testPluginMarkovUsesThePatternsNotesAndCurveFillsAValueSequencer() async throws {
        var notes = G2Module(id: 96, typeID: 121, area: .voice)
        // The pattern uses only C4, E4, G4 over 4 steps; the Markov melody may use nothing else.
        notes.parameters = [60, 64, 67, 64] + Array(repeating: 100, count: 12) + Array(repeating: 1, count: 16) + [1, 3, 0, 0, 0, 0]
        var levels = G2Module(id: 97, typeID: 146, area: .voice)
        levels.parameters = Array(repeating: 64, count: 16) + Array(repeating: 1, count: 16) + [1, 7, 0, 0, 0, 0]
        state.slots[0].voiceModules.append(contentsOf: [notes, levels])
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        _ = try await plugin.nextSequencers()

        try plugin.send(["type": "seq_random", "slot": "A", "location": 1, "module": 96, "mode": "markov", "root": 0,
                         "scale": "chromatic", "low": 48, "high": 84, "percent": 0])
        try await waitUntil { Array(self.state.slots[0].voiceModules[self.state.slots[0].voiceModules.count - 2].parameters[4 ..< 16]) != Array(repeating: 100, count: 12) }
        let markov = Array(state.slots[0].voiceModules[state.slots[0].voiceModules.count - 2].parameters[0 ..< 16])
        XCTAssertTrue(markov.allSatisfy { [60, 64, 67].contains($0) }, "Markov learns only the notes it was given")

        // Saw up over the first 8 steps (Length 8), full range: rises from the bottom to the top.
        try plugin.send(["type": "seq_curve", "slot": "A", "location": 1, "module": 97, "shape": "sawUp", "cycles": 1,
                         "low": 0, "high": 100])
        try await waitUntil { self.state.slots[0].voiceModules.last?.parameters[7] != 64 }
        let curve = Array(state.slots[0].voiceModules.last?.parameters[0 ..< 8] ?? [])
        XCTAssertEqual(curve, curve.sorted(), "saw up rises")
        XCTAssertLessThan(curve[0], 10)
        XCTAssertGreaterThan(curve[7], 100)
        state.undoManager.undo()
        XCTAssertEqual(state.slots[0].voiceModules.last?.parameters[7], 64, "one Undo step")

        // A note sequencer has no values for a curve.
        try plugin.send(["type": "seq_curve", "slot": "A", "location": 1, "module": 96, "shape": "sawUp", "cycles": 1,
                         "low": 0, "high": 100])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(Array(state.slots[0].voiceModules[state.slots[0].voiceModules.count - 2].parameters[0 ..< 16]), markov)
    }

    func testPluginPresetsAndScaleDegreeChords() async throws {
        var notes = G2Module(id: 98, typeID: 121, area: .voice)
        notes.parameters = Array(repeating: 100, count: 16) + Array(repeating: 1, count: 16) + [1, 15, 0, 0, 0, 0]
        var events = G2Module(id: 99, typeID: 144, area: .voice)
        events.parameters = Array(repeating: 0, count: 32) + [1, 15, 0, 0, 0, 0]
        state.slots[0].voiceModules.append(contentsOf: [notes, events])
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        let list = try await plugin.nextSequencers()["list"] as? [[String: Any]] ?? []
        XCTAssertEqual((list.first { $0["module"] as? Int == 98 }?["presets"] as? [String])?.first, "Major arpeggio")
        XCTAssertFalse((list.first { $0["module"] as? Int == 99 }?["presets"] as? [String] ?? []).isEmpty, "rhythms for SeqEvent")

        // The figure "Fifths" (0, 7) from C3 (48), repeated over the steps.
        try plugin.send(["type": "seq_preset", "slot": "A", "location": 1, "module": 98, "name": "Fifths", "root": 48])
        try await waitUntil { self.state.slots[0].voiceModules[self.state.slots[0].voiceModules.count - 2].parameters[0] == 48 }
        XCTAssertEqual(Array(state.slots[0].voiceModules[state.slots[0].voiceModules.count - 2].parameters[0 ..< 4]),
                       [48, 55, 48, 55])

        // A rhythm writes both rows of the SeqEvent.
        let rhythm = try XCTUnwrap(SequencePresets.rhythms.first)
        try plugin.send(["type": "seq_preset", "slot": "A", "location": 1, "module": 99, "name": rhythm.name, "root": 48])
        try await waitUntil { Array(self.state.slots[0].voiceModules.last?.parameters[0 ..< 16] ?? []) == rhythm.steps }
        XCTAssertEqual(Array(state.slots[0].voiceModules.last?.parameters[16 ..< 32] ?? []), rhythm.second)
        state.undoManager.undo()
        XCTAssertEqual(Array(state.slots[0].voiceModules.last?.parameters[0 ..< 32] ?? []), Array(repeating: 0, count: 32), "one Undo step")

        // Third degree of C major (E minor: E G B), up, one octave, from C3.
        try plugin.send(["type": "seq_arpeggio", "slot": "A", "location": 1, "module": 98, "root": 48,
                         "chord": "degree:2", "direction": "up", "octaves": 1, "scale": "major"])
        try await waitUntil { self.state.slots[0].voiceModules[self.state.slots[0].voiceModules.count - 2].parameters[0] == 52 }
        XCTAssertEqual(Array(state.slots[0].voiceModules[state.slots[0].voiceModules.count - 2].parameters[0 ..< 6]),
                       [52, 55, 59, 52, 55, 59])
    }

    func testLockedStepsKeepTheirNotesInEveryGenerator() async throws {
        var seq = G2Module(id: 100, typeID: 121, area: .voice)
        seq.parameters = Array(repeating: 100, count: 16) + Array(repeating: 1, count: 16) + [1, 15, 0, 0, 0, 0]
        state.slots[0].voiceModules.append(seq)
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        _ = try await plugin.nextSequencers()

        // Steps 0 and 15 are locked: an arpeggio over the rest leaves them at 100.
        try plugin.send(["type": "seq_arpeggio", "slot": "A", "location": 1, "module": 100, "root": 48,
                         "chord": "major", "direction": "up", "octaves": 1, "locks": [0, 15]])
        try await waitUntil { self.state.slots[0].voiceModules.last?.parameters[1] == 52 }
        var notes = Array(state.slots[0].voiceModules.last?.parameters[0 ..< 16] ?? [])
        XCTAssertEqual(notes[0], 100)
        XCTAssertEqual(notes[15], 100)
        XCTAssertEqual(notes[1 ..< 15].map { $0 }, (1 ..< 15).map { [48, 52, 55][$0 % 3] })

        // Random with the same locks.
        try plugin.send(["type": "seq_random", "slot": "A", "location": 1, "module": 100, "mode": "random", "root": 0,
                         "scale": "major", "low": 48, "high": 72, "percent": 0, "locks": [0, 15]])
        try await Task.sleep(nanoseconds: 300_000_000)
        notes = Array(state.slots[0].voiceModules.last?.parameters[0 ..< 16] ?? [])
        XCTAssertEqual([notes[0], notes[15]], [100, 100], "locked steps are not drawn over")

        // Mutate 100 % with every step but one locked changes only that one.
        try plugin.send(["type": "seq_random", "slot": "A", "location": 1, "module": 100, "mode": "mutate", "root": 0,
                         "scale": "major", "low": 48, "high": 72, "percent": 100, "locks": Array(1 ..< 16)])
        try await Task.sleep(nanoseconds: 300_000_000)
        let after = Array(state.slots[0].voiceModules.last?.parameters[0 ..< 16] ?? [])
        XCTAssertEqual(Array(after[1...]), Array(notes[1...]), "everything but step 1 is locked")
    }

    func testRandomStepsForSeqEventAndGateRowOfOtherSequencers() async throws {
        var events = G2Module(id: 101, typeID: 144, area: .voice)
        events.parameters = Array(repeating: 0, count: 32) + [1, 15, 0, 0, 0, 0]
        var notes = G2Module(id: 102, typeID: 121, area: .voice)
        notes.parameters = Array(repeating: 60, count: 16) + Array(repeating: 1, count: 16) + [1, 15, 0, 0, 0, 0]
        state.slots[0].voiceModules.append(contentsOf: [events, notes])
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        _ = try await plugin.nextSequencers()
        func eventParams() -> [Int] {
            Array(state.slots[0].voiceModules[state.slots[0].voiceModules.count - 2].parameters[0 ..< 32])
        }

        // Density 100 % switches every step of both rows on — except the locked step 3.
        try plugin.send(["type": "seq_gates", "slot": "A", "location": 1, "module": 101, "mode": "random",
                         "density": 100, "percent": 0, "locks": [3]])
        try await waitUntil { eventParams()[0] == 1 }
        var params = eventParams()
        XCTAssertEqual(params[0 ..< 16].filter { $0 == 1 }.count, 15, "row 1: all on but the locked step")
        XCTAssertEqual(params[16 ..< 32].filter { $0 == 1 }.count, 15, "row 2: all on but the locked step")
        XCTAssertEqual([params[3], params[19]], [0, 0])

        // Mutate 100 % flips every unlocked step of both rows.
        try plugin.send(["type": "seq_gates", "slot": "A", "location": 1, "module": 101, "mode": "mutate",
                         "density": 0, "percent": 100, "locks": [3]])
        try await waitUntil { eventParams()[0] == 0 }
        params = eventParams()
        XCTAssertEqual(Array(params[0 ..< 16]).enumerated().filter { $0.element == 1 }.map(\.offset), [], "step 3 stayed off, the rest flipped off")
        state.undoManager.undo()
        XCTAssertEqual(eventParams()[0], 1, "one Undo step")

        // A SeqNote: density 0 % switches its gate row off, the notes stay; Mutate is for SeqEvent only.
        try plugin.send(["type": "seq_gates", "slot": "A", "location": 1, "module": 102, "mode": "random",
                         "density": 0, "percent": 0])
        try await waitUntil { self.state.slots[0].voiceModules.last?.parameters[16] == 0 }
        XCTAssertEqual(Array(state.slots[0].voiceModules.last?.parameters[16 ..< 32] ?? []), Array(repeating: 0, count: 16))
        XCTAssertEqual(Array(state.slots[0].voiceModules.last?.parameters[0 ..< 16] ?? []), Array(repeating: 60, count: 16))
        try plugin.send(["type": "seq_gates", "slot": "A", "location": 1, "module": 102, "mode": "mutate",
                         "density": 0, "percent": 100])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(Array(state.slots[0].voiceModules.last?.parameters[16 ..< 32] ?? []), Array(repeating: 0, count: 16))
    }

    func testRhythmBankAndMyPatterns() async throws {
        var events = G2Module(id: 103, typeID: 144, area: .voice)
        events.parameters = Array(repeating: 0, count: 32) + [1, 15, 0, 0, 0, 0]
        var notes = G2Module(id: 104, typeID: 121, area: .voice)
        notes.parameters = [60, 64, 67, 72] + Array(repeating: 60, count: 12) + Array(repeating: 1, count: 16) + [1, 7, 0, 0, 0, 0]
        state.slots[0].voiceModules.append(contentsOf: [events, notes])
        let plugin = try await TestPlugin.greeted(path)
        try plugin.send(["type": "claim", "slot": "A"])
        // The bank comes once per connection; the roles are the menu's submenus.
        let bank = try await plugin.next(of: "rhythm_bank")
        XCTAssertEqual((bank["patterns"] as? [String])?.count, SequenceRhythmBank.patterns.count)
        XCTAssertEqual((bank["roles"] as? [String])?.count, SequenceRhythmBank.patterns.count)

        // Rhythm 0 into the SeqEvent's Trig 1 (step 0 locked), into the SeqNote's gate row only.
        let flags = SequenceRhythmBank.flags(at: 0)
        func eventParams() -> [Int] {
            Array(state.slots[0].voiceModules[state.slots[0].voiceModules.count - 2].parameters[0 ..< 32])
        }
        try plugin.send(["type": "seq_rhythm", "slot": "A", "location": 1, "module": 103, "index": 0, "locks": [0]])
        try await waitUntil { Array(eventParams()[1 ..< 16]) == Array(flags[1...]) }
        XCTAssertEqual(eventParams()[0], 0, "locked")
        try plugin.send(["type": "seq_rhythm", "slot": "A", "location": 1, "module": 104, "index": 0])
        try await waitUntil { Array(self.state.slots[0].voiceModules.last?.parameters[16 ..< 32] ?? []) == flags }
        XCTAssertEqual(Array(state.slots[0].voiceModules.last?.parameters[0 ..< 4] ?? []), [60, 64, 67, 72], "notes stay")

        // Save the SeqNote's pattern as "Test line", change it, load it back; the list reaches the plugin.
        try plugin.send(["type": "seq_pattern_save", "slot": "A", "location": 1, "module": 104, "name": "Test line"])
        var mine: [[String: Any]] = []
        for _ in 0 ..< 8 where mine.isEmpty {
            let message = try await plugin.nextSequencers()
            let sequencer = (message["list"] as? [[String: Any]])?.first { $0["module"] as? Int == 104 }
            mine = sequencer?["mine"] as? [[String: Any]] ?? []
        }
        XCTAssertEqual(mine.first?["name"] as? String, "Test line")
        let id = try XCTUnwrap(mine.first?["id"] as? String)
        try plugin.send(["type": "seq_draw", "slot": "A", "gesture": "end", "values": [[1, 104, 0, 10]]])
        try await waitUntil { self.state.slots[0].voiceModules.last?.parameters[0] == 10 }
        try plugin.send(["type": "seq_pattern_load", "slot": "A", "location": 1, "module": 104, "id": id])
        try await waitUntil { self.state.slots[0].voiceModules.last?.parameters[0] == 60 }
        XCTAssertEqual(Array(state.slots[0].voiceModules.last?.parameters[0 ..< 4] ?? []), [60, 64, 67, 72])

        // A note pattern is not loaded into a SeqEvent.
        let before = eventParams()
        try plugin.send(["type": "seq_pattern_load", "slot": "A", "location": 1, "module": 103, "id": id])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(eventParams(), before)

        // Delete.
        try plugin.send(["type": "seq_pattern_delete", "id": id])
        var left = 1
        for _ in 0 ..< 8 where left != 0 {
            let message = try await plugin.nextSequencers()
            let sequencer = (message["list"] as? [[String: Any]])?.first { $0["module"] as? Int == 104 }
            left = (sequencer?["mine"] as? [[String: Any]])?.count ?? 1
        }
        XCTAssertEqual(left, 0)
    }

    func testSequencerIsSentAndDrawnWithOneUndoStep() async throws {
        var seq = G2Module(id: 90, typeID: 146, area: .voice)
        seq.parameters = Array(repeating: 64, count: 16) + Array(repeating: 1, count: 16) + [1, 7, 0, 0, 0, 0]
        state.slots[0].voiceModules.append(seq)
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        let list = try await plugin.nextSequencers()["list"] as? [[String: Any]] ?? []
        let sequencer = try XCTUnwrap(list.first { $0["module"] as? Int == 90 })
        XCTAssertEqual(sequencer["kind"] as? String, "level")
        XCTAssertEqual(sequencer["length"] as? Int, 8)
        XCTAssertEqual(sequencer["bipolar"] as? Bool, true)
        XCTAssertEqual((sequencer["steps"] as? [Int])?.count, 16)
        XCTAssertEqual(sequencer["loop"] as? Int, 1, "Loop is sent for the All view")
        XCTAssertEqual(sequencer["clock"] as? String, "No clock")
        XCTAssertEqual(sequencer["target"] as? String, "")

        // Wiadomości jednego pociągnięcia przychodzą w odstępach, jak przy prawdziwym
        // rysowaniu — każda trafia w inny obieg pętli zdarzeń (na wolnym CI GitHuba
        // pierwsza kratka wpadała do osobnego kroku Undo, 2026-10-16).
        try plugin.send(["type": "seq_draw", "slot": "A", "gesture": "begin", "values": [[1, 90, 0, 10]]])
        try await waitUntil { self.state.slots[0].voiceModules.last?.parameters[0] == 10 }
        try plugin.send(["type": "seq_draw", "slot": "A", "gesture": "move", "values": [[1, 90, 1, 20], [1, 90, 2, 30]]])
        try await waitUntil { self.state.slots[0].voiceModules.last?.parameters[2] == 30 }
        try plugin.send(["type": "seq_draw", "slot": "A", "gesture": "end", "values": [[1, 90, 34, 1]]])
        try await waitUntil { self.state.undoManager.canUndo }
        XCTAssertEqual(state.slots[0].voiceModules.last?.parameters[34], 0, "only steps, length and loop can be drawn")
        try plugin.send(["type": "seq_draw", "slot": "A", "gesture": "begin", "values": [[1, 90, 32, 0]]])
        try await waitUntil { self.state.slots[0].voiceModules.last?.parameters[32] == 0 }
        state.undoManager.undo()
        XCTAssertEqual(Array(state.slots[0].voiceModules.last?.parameters[0 ..< 3] ?? []), [64, 64, 64],
                       "one stroke is one Undo step")
    }

    func testPlayheadIsTheLedGroupStepWithinLength() {
        var seq = G2Module(id: 90, typeID: 146, area: .voice)
        seq.parameters = Array(repeating: 64, count: 16) + Array(repeating: 1, count: 16) + [1, 7, 0, 0, 0, 0]
        state.slots[0].voiceModules.append(seq)
        func step(_ value: Int?) -> Int? {
            let groups = value.map { [G2LedGroupReading(area: .voice, moduleID: 90, value: $0)] } ?? []
            return PluginSequencers.playheads(state, slot: 0, ledGroups: groups).first { $0.module == 90 }?.step
        }
        XCTAssertEqual(step(3), 3)
        XCTAssertEqual(step(7), 7, "the last step of Length 8")
        XCTAssertEqual(step(8), -1, "beyond Length = parked")
        XCTAssertEqual(step(16), -1, "16 or more = parked")
        XCTAssertEqual(step(nil), -1, "no stream = stopped")
    }

    func testBrowserFindsLoadsAndDescribesPatches() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("g2pb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Bass"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/simplesynth001-20240802.pch2")
        let file = folder.appendingPathComponent("Bass/Deep Sub.pch2")
        try FileManager.default.copyItem(at: fixture, to: file)
        try FileManager.default.copyItem(at: fixture, to: folder.appendingPathComponent("Lead One.pch2"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "g2pb-\(UUID().uuidString)"))
        bridge.browserDefaults = defaults

        let plugin = try await TestPlugin.greeted(path)
        let none = try await plugin.ask(["type": "browse", "id": 1, "query": ""])
        XCTAssertEqual(none["total"] as? Int, 0)
        XCTAssertNotNil(none["message"])

        defaults.set(folder.path, forKey: "g2_disk_bank_folder")
        let found = try await plugin.ask(["type": "browse", "id": 2, "query": "bass sub"])
        XCTAssertEqual(found["id"] as? Int, 2)
        XCTAssertEqual(found["total"] as? Int, 1)
        let item = try XCTUnwrap((found["items"] as? [[Any]])?.first)
        XCTAssertEqual(item[1] as? String, "Deep Sub")

        let info = try await plugin.ask(["type": "patch_info", "path": file.path])
        XCTAssertEqual(info["type"] as? String, "patch_info")
        XCTAssertEqual(info["modules"] as? Int, state.slots[0].voiceModules.count + state.slots[0].fxModules.count)
        XCTAssertEqual((info["voice"] as? [Double])?.count, 2)

        let refused = try await plugin.ask(["type": "load_patch", "slot": "B", "path": file.path])
        XCTAssertEqual(refused["code"] as? String, "claim_first")
        _ = try await plugin.ask(["type": "claim", "slot": "B"])
        // #192: patch z przeglądarki idzie do Norda CAŁY jedną komendą (potrzebne bajty pliku), a nie
        // różnicą modułów — przy dużej zmianie różnica zamrażała Norda.
        var wholeSlotSends: [Int] = []
        state.onSlotRestore = { slot, _ in wholeSlotSends.append(slot) }
        var structureDiffs = 0
        state.onLiveStructureChange = { _, _ in structureDiffs += 1 }
        let loaded = try await plugin.ask(["type": "load_patch", "slot": "B", "path": file.path])
        XCTAssertEqual(loaded["type"] as? String, "loaded")
        XCTAssertEqual(state.slots[1].name, "Deep Sub")
        XCTAssertEqual(structureDiffs, 0, "no module diff")
        XCTAssertTrue(wholeSlotSends.isEmpty, "the bridge sends the slot itself (sendWholeSlot), not via restore")
        XCTAssertNotNil(state.slotFileData[1])
        state.undoManager.undo()
        XCTAssertEqual(state.slots[1].name, "Two")
        XCTAssertEqual(wholeSlotSends, [1], "undo sends the whole slot")
    }

    /// Szukanie i kolejność jak w panelu Patches: ta sama funkcja sortowania, kategoria i nazwa tagu w szukaniu.
    func testBrowserSortsAndSearchesLikeThePatchesPanel() {
        let now = Date()
        func item(_ name: String, age: Double, category: Int, tags: [FinderTag] = []) -> DiskBankItem {
            DiskBankItem(url: URL(fileURLWithPath: "/p/\(name).pch2"), name: name, isPerformance: false,
                         modified: now.addingTimeInterval(-age), size: 100, relativeFolder: "",
                         tags: tags, category: category)
        }
        let bass = G2PatchCategory.names.firstIndex(of: "Bass") ?? 1
        let lead = G2PatchCategory.names.firstIndex(of: "Lead") ?? 2
        let items = [item("Alpha", age: 300, category: bass), item("Bravo", age: 100, category: lead),
                     item("Charlie", age: 200, category: bass)]
        XCTAssertEqual(PluginBrowser.search(items, query: "").map(\.name), ["Alpha", "Bravo", "Charlie"])
        XCTAssertEqual(PluginBrowser.search(items, query: "", sort: .date).map(\.name), ["Bravo", "Charlie", "Alpha"],
                       "date sorts newest first, like the panel")
        XCTAssertEqual(PluginBrowser.search(items, query: "", sort: .date, reversed: true).map(\.name),
                       ["Alpha", "Charlie", "Bravo"])
        XCTAssertEqual(PluginBrowser.search(items, query: "", category: "Bass").map(\.name), ["Alpha", "Charlie"])
        XCTAssertEqual(PluginBrowser.search(items, query: "lead").map(\.name), ["Bravo"], "the category is searchable")
        XCTAssertEqual(PluginBrowser.categories(items), ["Bass", "Lead"])
    }

    func testBrowserSearchesTheG2Banks() {
        let entries = [G2BankEntry(kind: .patch, bank: 2, patch: 11, name: "Deep Sub", category: 3),
                       G2BankEntry(kind: .patch, bank: 0, patch: 0, name: "", category: 0),
                       G2BankEntry(kind: .performance, bank: 0, patch: 1, name: "Deep Perf", category: 0)]
        let found = PluginBrowser.search(entries, query: "deep bank 3")
        XCTAssertEqual(found.map(\.name), ["Deep Sub"], "patches only, empty places left out")
        XCTAssertEqual(PluginBrowser.address(found[0]), "g2:2:11")
        XCTAssertEqual(PluginBrowser.entry(address: "g2:2:11", in: entries)?.name, "Deep Sub")
        XCTAssertNil(PluginBrowser.entry(address: "g2:0:1", in: entries), "a performance is not a patch")
    }

    func testBrowserFiltersBySubfolderAndCategory() {
        let folder = URL(fileURLWithPath: "/p")
        let items = ["Bass/Deep Sub", "Bass/Analog/Fat", "Leads/One", "Top"].map { path in
            DiskBankItem(url: folder.appendingPathComponent(path + ".pch2"), name: URL(fileURLWithPath: path).lastPathComponent,
                         isPerformance: false, modified: Date(),
                         relativeFolder: path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) : "")
        }
        XCTAssertEqual(PluginBrowser.groups(items), ["", "Bass", "Bass/Analog", "Leads"])
        XCTAssertEqual(PluginBrowser.search(items, query: "", group: "Bass").map(\.name), ["Deep Sub", "Fat"],
                       "a folder includes its subfolders")
        XCTAssertEqual(PluginBrowser.search(items, query: "", group: "").map(\.name), ["Top"])
        // Wchodzenie piętro po piętrze: folder wprost, bez podfolderów, plus wiersze podfolderów z liczbą plików.
        XCTAssertEqual(PluginBrowser.search(items, query: "", group: "Bass", direct: true).map(\.name), ["Deep Sub"])
        let root = PluginBrowser.folders(items, under: "")
        XCTAssertEqual(root.map(\.name), ["Bass", "Leads"])
        XCTAssertEqual(root.map(\.count), [2, 1], "Bass counts its subfolder too")
        XCTAssertEqual(PluginBrowser.folders(items, under: "Bass").map(\.name), ["Analog"])
        XCTAssertTrue(PluginBrowser.folders(items, under: "Leads").isEmpty)

        let entries = [G2BankEntry(kind: .patch, bank: 0, patch: 0, name: "Deep Sub", category: 3),
                       G2BankEntry(kind: .patch, bank: 0, patch: 1, name: "Lead", category: 5)]
        let bass = PluginBrowser.categoryName(3)
        XCTAssertEqual(PluginBrowser.groups(entries), [bass, PluginBrowser.categoryName(5)])
        XCTAssertEqual(PluginBrowser.search(entries, query: "", group: bass).map(\.name), ["Deep Sub"])
    }

    func testParameterPagesAreSentAndDrivenFromThePlugin() async throws {
        // Moduł, którego gałka ma powiązany przycisk (jak w oknie Parameter Pages).
        let linked = state.slots[0].voiceModules.lazy.compactMap { module -> (G2Module, Int, Int)? in
            for knob in module.parameters.indices {
                if let button = ModuleParameterLinks.buttonParameter(moduleTypeID: module.typeID, knobParameter: knob),
                   module.parameters.indices.contains(button) { return (module, knob, button) }
            }
            return nil
        }.first
        let (module, knob, button) = try XCTUnwrap(linked, "the fixture has a knob with a linked button")
        state.slots[0].assignKnob(index: 3 * 8 + 2, location: PatchArea.voice.rawValue, moduleID: module.id,
                                  paramIndex: knob)
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        _ = try await plugin.next(of: "pages")

        try plugin.send(["type": "pages_select", "page": 3])
        try await waitUntil { self.state.focusedParameterPage == 3 }
        let pages = try await plugin.next(of: "pages")
        XCTAssertEqual(pages["page"] as? Int, 3)
        XCTAssertEqual(pages["adjuster"] as? Bool, true, "slot A is the one shown in the editor")
        let shown = try XCTUnwrap((pages["knobs"] as? [[String: Any]])?[2])
        XCTAssertEqual(shown["param"] as? String, G2ParameterText.name(moduleTypeID: module.typeID, paramIndex: knob))
        XCTAssertEqual(shown["editable"] as? Bool, true)
        XCTAssertNotNil(shown["button"], "the linked button comes along")

        let before = module.parameters[button]
        try plugin.send(["type": "pages_button", "slot": "A", "knob": 2])
        try await waitUntil {
            self.state.slots[0].voiceModules.first { $0.id == module.id }?.parameters[button] != before
        }
        XCTAssertTrue(state.undoManager.canUndo, "the button is an ordinary edit")

        try plugin.send(["type": "pages_global", "on": true])
        try await waitUntil { self.state.showsGlobalParameterPages }
    }

    func testNavigatorStepsByPatchBankAndCategory() {
        let entries = [G2BankEntry(kind: .patch, bank: 1, patch: 0, name: "Bass B", category: 3),
                       G2BankEntry(kind: .patch, bank: 0, patch: 1, name: "Lead", category: 5),
                       G2BankEntry(kind: .patch, bank: 0, patch: 0, name: "Bass A", category: 3),
                       G2BankEntry(kind: .patch, bank: 0, patch: 2, name: "", category: 0)]
        let byPlace = PluginNavigator.items(entries, sort: .place)
        XCTAssertEqual(byPlace.map(\.name), ["Bass A", "Lead", "Bass B"], "bank order, empty places left out")
        XCTAssertEqual(byPlace[0].location, "1:1")
        XCTAssertEqual(PluginNavigator.step(byPlace, from: "g2:0:0", by: 1, group: false)?.name, "Lead")
        XCTAssertEqual(PluginNavigator.step(byPlace, from: "g2:0:0", by: -1, group: false)?.name, "Bass B",
                       "the list wraps around")
        XCTAssertEqual(PluginNavigator.step(byPlace, from: "g2:0:1", by: 1, group: true)?.name, "Bass B",
                       "next bank")
        XCTAssertEqual(PluginNavigator.step(byPlace, from: nil, by: 1, group: false)?.name, "Bass A")

        let byCategory = PluginNavigator.items(entries, sort: .name)
        XCTAssertEqual(byCategory.map(\.name), ["Bass A", "Bass B", "Lead"])
        XCTAssertEqual(PluginNavigator.step(byCategory, from: "g2:0:0", by: 1, group: true)?.name, "Lead",
                       "next category")
    }

    func testNavigatorWalksTheDiskFolderAndTheDisplayFollows() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("g2pb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Bass"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/simplesynth001-20240802.pch2")
        try FileManager.default.copyItem(at: fixture, to: folder.appendingPathComponent("Bass/Deep Sub.pch2"))
        try FileManager.default.copyItem(at: fixture, to: folder.appendingPathComponent("Bass/Fat Mono.pch2"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "g2pb-\(UUID().uuidString)"))
        defaults.set(folder.path, forKey: "g2_disk_bank_folder")
        bridge.browserDefaults = defaults

        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        let first = try await plugin.ask(["type": "navigate", "id": 1, "slot": "A", "source": "disk", "step": 1])
        XCTAssertEqual(first["type"] as? String, "navigated")
        XCTAssertEqual(first["name"] as? String, "Deep Sub")
        XCTAssertEqual(first["location"] as? String, "Bass")
        XCTAssertEqual(state.slots[0].name, "One", "browsing does not load")
        let next = try await plugin.ask(["type": "navigate", "id": 2, "slot": "A", "source": "disk", "step": 1,
                                         "from": first["path"] as? String ?? ""])
        XCTAssertEqual(next["name"] as? String, "Fat Mono")

        _ = try await plugin.ask(["type": "load_patch", "slot": "A", "path": next["path"] as? String ?? ""])
        var shown: [String: Any] = [:]
        for _ in 0 ..< 5 where shown["name"] as? String != "Fat Mono" {
            shown = try await plugin.next(of: "display")
        }
        XCTAssertEqual(shown["name"] as? String, "Fat Mono")
        XCTAssertEqual(shown["location"] as? String, "Bass")
        // Bez `from` Navigator liczy od patcha w slocie.
        let after = try await plugin.ask(["type": "navigate", "id": 3, "slot": "A", "source": "disk", "step": 1])
        XCTAssertEqual(after["name"] as? String, "Deep Sub", "wraps after the last patch")
    }

    func testPanicNeedsNoReply() async throws {
        let plugin = try await TestPlugin.greeted(path)
        _ = try await plugin.ask(["type": "claim", "slot": "A"])
        try plugin.send(["type": "panic"])
        let next = try await plugin.ask(["type": "get_slot", "slot": "A"])
        XCTAssertEqual(next["type"] as? String, "slot", "panic sends nothing back")
    }

    func testSecondEditorSeesTheFirstListening() {
        XCTAssertTrue(PluginBridgeServer.isListening(at: path))
        XCTAssertFalse(PluginBridgeServer.isListening(at: path + ".none"))
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0 ..< 100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not met in 2 s")
    }
}

/// Klient jak wtyczka: JSON po linii. Czyta poza głównym wątkiem, bo most odpowiada z głównego.
private final class TestPlugin: @unchecked Sendable {
    private let fd: Int32
    private var pending = Data()

    init(_ path: String) throws {
        fd = try XCTUnwrap(PluginBridgeServer.connectSocket(path))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close() }

    static func greeted(_ path: String, host: String = "") async throws -> TestPlugin {
        let plugin = try TestPlugin(path)
        _ = try await plugin.ask(["type": "hello", "protocol": 1, "client": "G2 VST", "host": host])
        return plugin
    }

    func close() {
        shutdown(fd, SHUT_RDWR)
    }

    func ask(_ message: [String: Any]) async throws -> [String: Any] {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return try await next()
    }

    /// Następna wiadomość, z pominięciem list automatyki i ogłoszeń slotu aktywnego — te przychodzą same po
    /// każdym zajęciu slotu i testom innych rzeczy tylko by przeszkadzały.
    func next() async throws -> [String: Any] {
        while true {
            let message = try await any()
            if !["automation", "sequencers", "pages", "display", "focus", "keyboard_slots", "arp", "rhythm_bank", "playhead"].contains(message["type"] as? String) { return message }
        }
    }

    func nextSequencers() async throws -> [String: Any] {
        try await next(of: "sequencers")
    }

    func next(of type: String) async throws -> [String: Any] {
        while true {
            let message = try await any()
            if message["type"] as? String == type { return message }
        }
    }

    func nextAutomation() async throws -> [String: Any] {
        while true {
            let message = try await any()
            if message["type"] as? String == "automation" { return message }
        }
    }

    func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    private func any() async throws -> [String: Any] {
        let line = await Task.detached { self.readLine() }.value
        let data = try XCTUnwrap(line, "no reply within 3 s")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func readLine() -> Data? {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex ..< newline]
                pending.removeSubrange(pending.startIndex ... newline)
                return Data(line)
            }
            let got = read(fd, &buffer, buffer.count)
            if got <= 0 { return nil }
            pending.append(contentsOf: buffer[0 ..< got])
        }
    }
}
