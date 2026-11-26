// ShortcutStoreTests.swift
// The shipped shortcuts and what changing them does.

@testable import G2EditorCore
import XCTest

@MainActor
final class ShortcutStoreTests: XCTestCase {
    private var suite = ""

    private func makeStore() -> (ShortcutStore, UserDefaults) {
        suite = "shortcut-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        addTeardownBlock { [suite] in UserDefaults().removePersistentDomain(forName: suite) }
        return (ShortcutStore(defaults: defaults), defaults)
    }

    func testShippedShortcutsAreTheOnesTheEditorAlwaysHad() {
        let (store, _) = makeStore()
        let expected: [(ShortcutCommand, String)] = [
            (.save, "⌘S"), (.saveAs, "⇧⌘S"), (.zoomIn, "⌘="), (.zoomToFit, "⇧⌘0"),
            (.modulesPanel, "⌥⌘1"), (.sequenceEditor, "⌥⌘E"), (.menuSlotA, "⌘1"), (.dumpOne, "⇧⌘1"),
            (ShortcutCommand.slots[0], "A"), (ShortcutCommand.variations[7], "8"),
            (.viewVoice, "V"), (.showValues, "F5"), (.nextPatch, "⌥↓"),
            (ShortcutCommand.mutatorBoxes[0], "1"), (.mutatorStore, "S"),
        ]
        for (command, keys) in expected {
            XCTAssertEqual(store.stroke(for: command)?.display, keys, command.id)
        }
        XCTAssertNil(store.stroke(for: .insertPatchFile))
        XCTAssertFalse(store.hasChanges)
    }

    func testEveryCommandIsListedOnceAndShipsWithoutConflicts() {
        let (store, _) = makeStore()
        XCTAssertEqual(Set(ShortcutCommand.all.map(\.id)).count, ShortcutCommand.all.count)
        for command in ShortcutCommand.all {
            guard let stroke = command.defaultStroke else { continue }
            XCTAssertEqual(store.verdict(stroke, for: command), .free, command.id)
        }
    }

    func testAKeyTakenFromAnotherCommandMovesOver() {
        let (store, _) = makeStore()
        let slotA = ShortcutCommand.slots[0]
        let one = KeyStroke("1")
        XCTAssertEqual(store.verdict(one, for: slotA), .taken([ShortcutCommand.variations[0]]))

        store.assign(one, to: slotA)

        XCTAssertEqual(store.stroke(for: slotA), one)
        XCTAssertNil(store.stroke(for: ShortcutCommand.variations[0]))
        XCTAssertEqual(store.command(for: one, in: .patch), slotA)
        XCTAssertNil(store.command(for: KeyStroke("a"), in: .patch))
        // The Mutator is a window of its own: its 1 stays.
        XCTAssertEqual(store.command(for: one, in: .mutator), ShortcutCommand.mutatorBoxes[0])
    }

    func testMenuShortcutsAreSharedWithEveryWindow() {
        let (store, _) = makeStore()
        let stroke = KeyStroke("s", .command)
        XCTAssertEqual(store.verdict(stroke, for: .mutatorStore), .taken([.save]))
        XCTAssertEqual(store.verdict(KeyStroke("v"), for: .mutatorStore), .free)
    }

    func testFixedKeysAndPlainMenuKeysAreRefused() {
        let (store, _) = makeStore()
        for stroke in [KeyStroke("q", .command), KeyStroke("c", .command), KeyStroke("escape"),
                       KeyStroke("up"), KeyStroke("down", .control), KeyStroke("space")]
        {
            XCTAssertEqual(store.verdict(stroke, for: .viewVoice), .fixed, stroke.display)
        }
        XCTAssertEqual(store.verdict(KeyStroke("down", .option), for: .mutatorMutate), .fixed)
        XCTAssertEqual(store.verdict(KeyStroke("k"), for: .patchSettings), .needsModifier)
        // ⌥ + a letter types characters such as „ą”.
        XCTAssertEqual(store.verdict(KeyStroke("a", .option), for: .patchSettings), .needsModifier)
        XCTAssertEqual(store.verdict(KeyStroke("f2"), for: .patchSettings), .free)

        store.assign(KeyStroke("k"), to: .patchSettings)
        XCTAssertEqual(store.stroke(for: .patchSettings), ShortcutCommand.patchSettings.defaultStroke)
    }

    func testShiftCountsOnlyWhenItHasNoCommandOfItsOwn() {
        let (store, _) = makeStore()
        let shifted = KeyStroke("f5", .shift)
        XCTAssertEqual(store.command(for: shifted, in: .patch), .showValues)

        store.assign(shifted, to: .viewFX)

        XCTAssertEqual(store.command(for: shifted, in: .patch), .viewFX)
        XCTAssertEqual(store.command(for: KeyStroke("f5"), in: .patch), .showValues)
    }

    func testChangesSurviveARestartAndCanBeUndone() {
        let (store, defaults) = makeStore()
        store.assign(KeyStroke("k", .command), to: .patchSettings)
        store.remove(from: .patchNotes)

        let reopened = ShortcutStore(defaults: defaults)
        XCTAssertEqual(reopened.stroke(for: .patchSettings)?.display, "⌘K")
        XCTAssertNil(reopened.stroke(for: .patchNotes))
        XCTAssertTrue(reopened.isChanged(.patchNotes))
        XCTAssertEqual(reopened.hint(.patchSettings), " (⌘K)")
        XCTAssertEqual(reopened.hint(.patchNotes), "")

        reopened.reset(.patchNotes)
        XCTAssertEqual(reopened.stroke(for: .patchNotes)?.display, "⌘J")
        XCTAssertFalse(reopened.isChanged(.patchNotes))

        reopened.resetAll()
        XCTAssertFalse(reopened.hasChanges)
        XCTAssertNil(defaults.data(forKey: ShortcutStore.storageKey))
    }

    func testResettingTakesTheDefaultBack() {
        let (store, _) = makeStore()
        let slotA = ShortcutCommand.slots[0]
        let first = ShortcutCommand.variations[0]
        store.assign(KeyStroke("1"), to: slotA)

        store.reset(first)

        XCTAssertEqual(store.stroke(for: first), KeyStroke("1"))
        XCTAssertNil(store.stroke(for: slotA))
    }

    func testAStoredKeyWinsOverADefault() throws {
        let (_, defaults) = makeStore()
        // As if a later version shipped ⌘S for „Save” after the user had given it away.
        let stored = #"{"patch.settings":{"stroke":{"key":"s","modifiers":8}}}"#
        try defaults.set(XCTUnwrap(stored.data(using: .utf8)), forKey: ShortcutStore.storageKey)

        let store = ShortcutStore(defaults: defaults)

        XCTAssertEqual(store.stroke(for: .patchSettings)?.display, "⌘S")
        XCTAssertNil(store.stroke(for: .save))
    }
}
