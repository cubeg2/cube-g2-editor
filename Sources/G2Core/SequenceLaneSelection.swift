// SequenceLaneSelection.swift
// Which lanes are ticked in the Sequence Editor's All tab, selected the way files are in the Finder:
// a click selects one lane, ⌘-click adds or removes a single one, ⇧-click selects every lane between
// the last one clicked (the anchor) and this one, ⌘⇧-click adds that range to what is selected.
// → [[Docs/roadmap]] "Sequence Editor"

import Foundation

public struct SequenceLaneSelection: Equatable, Sendable {
    public private(set) var selected: Set<Int>
    /// The lane a ⇧-click counts from: the last one clicked.
    public private(set) var anchor: Int?

    public init(selected: Set<Int> = [], anchor: Int? = nil) {
        self.selected = selected
        self.anchor = anchor
    }

    /// A click on lane `id`. `order` is every lane in the order the list shows them.
    public mutating func click(_ id: Int, order: [Int], shift: Bool, command: Bool) {
        if shift, let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            let range = Set(order[min(from, to) ... max(from, to)])
            selected = command ? selected.union(range) : range
            return // the anchor stays, so the range can be moved by clicking another end
        }
        if shift || command {
            if selected.contains(id) {
                selected.remove(id)
            } else {
                selected.insert(id)
            }
            anchor = id
            return
        }
        // A plain click selects just this lane; clicking the only selected lane again clears.
        if selected == [id] {
            selected = []
            anchor = nil
        } else {
            selected = [id]
            anchor = id
        }
    }

    /// Selects exactly `ids` (the "Select group" button); the first becomes the anchor.
    public mutating func select(_ ids: [Int]) {
        selected = Set(ids)
        anchor = ids.first
    }
}
