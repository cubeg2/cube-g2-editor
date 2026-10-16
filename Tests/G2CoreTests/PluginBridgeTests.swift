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

        var structureSent = 0
        state.onLiveStructureChange = { _, _ in structureSent += 1 }
        let stored = try await plugin.ask(["type": "put_slot", "slot": "B", "patch": XCTUnwrap(slot["patch"]),
                                           "name": "From Song", "expect_version": XCTUnwrap(claimed["version"])])
        XCTAssertEqual(stored["type"] as? String, "stored")
        XCTAssertEqual(state.slots[1].name, "From Song")
        XCTAssertEqual(structureSent, 1)
        XCTAssertEqual(state.undoManager.undoActionName, "Patch from Logic Pro")
        state.undoManager.undo()
        XCTAssertEqual(state.slots[1].name, "Two")
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

        try plugin.send(["type": "automate", "slot": "A", "values": [[109, 1.0]]])
        try await waitUntil { self.state.slots[0].voiceModules.first { $0.id == module.id }?.parameters[0] == maxValue }
        try plugin.send(["type": "automate", "slot": "A", "values": [[22, 0.0]]])
        try await waitUntil { self.state.slots[0].voiceModules.first { $0.id == module.id }?.parameters[0] == 0 }
        XCTAssertFalse(state.undoManager.canUndo)
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

        try plugin.send(["type": "seq_draw", "slot": "A", "gesture": "begin", "values": [[1, 90, 0, 10]]])
        try plugin.send(["type": "seq_draw", "slot": "A", "gesture": "move", "values": [[1, 90, 1, 20], [1, 90, 2, 30]]])
        try plugin.send(["type": "seq_draw", "slot": "A", "gesture": "end", "values": [[1, 90, 34, 1]]])
        try await waitUntil { self.state.slots[0].voiceModules.last?.parameters[2] == 30 }
        XCTAssertEqual(state.slots[0].voiceModules.last?.parameters[34], 0, "only steps and length can be drawn")
        state.undoManager.undo()
        XCTAssertEqual(Array(state.slots[0].voiceModules.last?.parameters[0 ..< 3] ?? []), [64, 64, 64],
                       "one stroke is one Undo step")
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
        let loaded = try await plugin.ask(["type": "load_patch", "slot": "B", "path": file.path])
        XCTAssertEqual(loaded["type"] as? String, "loaded")
        XCTAssertEqual(state.slots[1].name, "Deep Sub")
        state.undoManager.undo()
        XCTAssertEqual(state.slots[1].name, "Two")
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

    /// Następna wiadomość, z pominięciem list automatyki — te przychodzą same po każdym
    /// zajęciu slotu i testom innych rzeczy tylko by przeszkadzały.
    func next() async throws -> [String: Any] {
        while true {
            let message = try await any()
            if !["automation", "sequencers", "pages", "display"].contains(message["type"] as? String) { return message }
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
