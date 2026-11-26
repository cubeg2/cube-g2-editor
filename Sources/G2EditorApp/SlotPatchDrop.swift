// SlotPatchDrop.swift
// A patch dropped on a slot button or on a slot's canvas: it loads into that slot. A slot
// button takes a row of the Patches panel (`SlotPatchDrag`) or a file from Finder; the
// canvas takes the row (Finder files open there as before, `FinderOpen`).

import AppKit
import G2Core
import G2EditorCore
import UniformTypeIdentifiers

@MainActor
enum SlotPatchDrop {
    static let types: [UTType] = [.fileURL, .plainText]

    static func accept(_ providers: [NSItemProvider], slot: Int, state: PatchState,
                       device: DeviceConnection) -> Bool
    {
        guard device.acceptsPatchChange, let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                afterDrag { open(url, slot: slot, state: state, device: device) }
            }
            return true
        }
        guard provider.canLoadObject(ofClass: NSString.self) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { string, _ in
            guard let string = string as? String, let drag = SlotPatchDrag(payload: string) else { return }
            afterDrag { perform(drag, slot: slot, state: state, device: device) }
        }
        return true
    }

    /// A drop on the canvas (`DropTargetNSView`), which has the payload at hand.
    static func load(_ drag: SlotPatchDrag, slot: Int, state: PatchState, device: DeviceConnection) {
        afterDrag { perform(drag, slot: slot, state: state, device: device) }
    }

    private static func perform(_ drag: SlotPatchDrag, slot: Int, state: PatchState, device: DeviceConnection) {
        guard device.acceptsPatchChange else { return }
        switch drag {
        case let .file(url): open(url, slot: slot, state: state, device: device)
        case let .bankEntry(id): load(bankEntry: id, slot: slot, state: state, device: device)
        }
    }

    /// The "Save changes?" question is modal: asked only after the drag session has ended.
    private nonisolated static func afterDrag(_ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated(action)
            }
        }
    }

    /// The same steps as File ▸ Open To. Anything that is not a single patch (a `.prf2`
    /// from Finder) opens as it did before: dropped anywhere in the window.
    private static func open(_ url: URL, slot: Int, state: PatchState, device: DeviceConnection) {
        guard url.pathExtension.lowercased() == "pch2" else {
            FinderOpen.shared.open(url)
            return
        }
        guard UnsavedChangesGuard.shared.confirmDiscard(slot: slot) else { return }
        state.load(url: url, intoSlot: slot)
        guard state.errorMessage == nil else { return }
        Task { await device.send(state, onlyFocusedSlot: true) }
    }

    /// The same as clicking the bank row with this slot focused.
    private static func load(bankEntry id: String, slot: Int, state: PatchState, device: DeviceConnection) {
        guard let entry = device.bankEntries.first(where: { $0.id == id }), entry.kind == .patch else { return }
        // Before the focus moves: ⌘Z has to know what played until now.
        state.expectBankLoad()
        state.focusSlot(slot)
        Task { await device.loadFromBank(entry, intoSlot: slot) }
    }
}
