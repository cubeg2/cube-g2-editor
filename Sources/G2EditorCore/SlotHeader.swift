// SlotHeader.swift
// To, co pas slotu pokazuje z patcha — bez parametrów modułów.
//
// Pod `@Observable` cały patch to jedna właściwość `slots`, więc każdy ruch gałki
// w module unieważniał pas slotu, osiem kolumn morfów z ich menu i pas wariacji —
// choć żadna z tych rzeczy się nie zmieniła (zmierzone 2026-09-21: ~2 ms na tick).
// `PatchState` przelicza nagłówki po każdej zmianie `slots`, ale podmienia je TYLKO
// wtedy, gdy któryś się różni — a pasy czytają nagłówek, nie `slots`
// → [[Docs/ui/canvas-performance]].

import G2Core

public struct SlotHeader: Equatable {
    public var name: String
    public var category: Int
    public var voiceModeIndex: Int
    public var activeVariation: Int
    public var patchVolume: Int
    public var activeMuted: Int
    /// Gałki i źródła ośmiu morfów w aktywnej wariacji.
    public var morphDials: [Int]
    public var morphModes: [Int]
    /// Czy do morfu jest w aktywnej wariacji przypisany jakikolwiek parametr.
    public var morphAssigned: [Bool]
    /// Nazwy ośmiu morfów z patcha (`G2Patch.morphName`).
    public var morphNames: [String]
    /// Czy na stronie gałek (0–14) siedzi jakiekolwiek przypisanie — menu
    /// „Assign to Knob" pisze wtedy „(used)".
    public var knobPageUsed: [Bool]

    public init(patch: G2Patch) {
        let variation = patch.activeVariation
        name = patch.name
        category = patch.description.category
        voiceModeIndex = G2VoiceMode.index(voices: patch.description.voices,
                                           monopoly: patch.description.monopoly)
        activeVariation = variation
        let settings = patch.variationSettings.indices.contains(variation)
            ? patch.variationSettings[variation] : nil
        patchVolume = settings?[keyPath: G2PatchSetting.patchVolume.keyPath] ?? 0
        activeMuted = settings?[keyPath: G2PatchSetting.activeMuted.keyPath] ?? 0
        morphDials = (0 ..< G2Morph.count).map { patch.morphDial($0, in: variation) }
        morphModes = (0 ..< G2Morph.count).map { patch.morphMode($0, in: variation) }
        let assignedMorphs = Set(patch.morphs(in: variation).map(\.morph))
        morphAssigned = (0 ..< G2Morph.count).map { assignedMorphs.contains($0) }
        morphNames = patch.morphNames
        knobPageUsed = (0 ..< G2KnobPages.pageCount).map { page in
            (0 ..< G2KnobPages.knobsPerPage).contains { patch.knobAssignment(page: page, slot: $0) != nil }
        }
    }

    public static let empty = SlotHeader(patch: G2Patch())
}
