// FineAdjust.swift
// One rule for the whole app: hold Shift while dragging a value with the mouse and it moves ten
// times slower, so single steps are easy to hit. The canvas knobs have always done this (the
// original editor does too); this gives the same to the small knobs of the panels, the value
// fields of the top bar and the Sequence Editor (user's request 2026-11-16).
// Option is not used for it: on a canvas knob Option changes the morph range.

import AppKit

enum FineAdjust {
    /// Shift is held right now.
    @MainActor
    static var isHeld: Bool {
        NSEvent.modifierFlags.contains(.shift)
    }

    /// How much slower a drag is with Shift held.
    static let slowdown = 0.1
}
