// ShortcutKeys.swift
// Bridges between `KeyStroke` and the app: key events from AppKit, menu shortcuts of SwiftUI.

import AppKit
import G2EditorCore
import SwiftUI

extension KeyStroke {
    /// Keys named by their position: they type no character.
    private static let namedKeyCodes: [UInt16: String] = [
        126: "up", 125: "down", 123: "left", 124: "right",
        49: "space", 36: "return", 76: "return", 48: "tab", 53: "escape",
        51: "delete", 117: "forwarddelete",
        115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12",
        105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17", 79: "f18", 80: "f19",
    ]

    /// The stroke of a `keyDown`; `nil` for a key that types nothing we can name.
    init?(event: NSEvent) {
        var modifiers: Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }

        if let name = Self.namedKeyCodes[event.keyCode] {
            self.init(name, modifiers)
            return
        }
        // Without modifiers: ⇧1 is „1” held with Shift, ⌥A is „a” held with Option.
        guard let characters = event.characters(byApplyingModifiers: []),
              let first = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(first), !CharacterSet.whitespaces.contains(first),
              first.value < 0xF700 || first.value > 0xF8FF
        else { return nil }
        self.init(String(characters.prefix(1)), modifiers)
    }

    /// For a menu item.
    var keyboardShortcut: KeyboardShortcut? {
        guard let equivalent = keyEquivalent else { return nil }
        var flags: EventModifiers = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return KeyboardShortcut(equivalent, modifiers: flags)
    }

    private var keyEquivalent: KeyEquivalent? {
        switch key {
        case "up": return .upArrow
        case "down": return .downArrow
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "space": return .space
        case "return": return .return
        case "tab": return .tab
        case "escape": return .escape
        case "delete": return .delete
        case "forwarddelete": return .deleteForward
        case "home": return .home
        case "end": return .end
        case "pageup": return .pageUp
        case "pagedown": return .pageDown
        default:
            if isFunctionKey, let number = Int(key.dropFirst()),
               let scalar = Unicode.Scalar(NSF1FunctionKey + number - 1)
            {
                return KeyEquivalent(Character(scalar))
            }
            guard key.count == 1, let character = key.first else { return nil }
            return KeyEquivalent(character)
        }
    }
}

/// Gives a menu item the shortcut the user has for the command.
private struct CommandShortcut: ViewModifier {
    let command: ShortcutCommand?

    func body(content: Content) -> some View {
        content.keyboardShortcut(command.flatMap { ShortcutStore.shared.stroke(for: $0) }?.keyboardShortcut)
    }
}

extension View {
    func shortcut(_ command: ShortcutCommand?) -> some View {
        modifier(CommandShortcut(command: command))
    }
}

extension ShortcutCommand {
    /// The menu command that opens and closes a panel.
    static func panel(_ panel: PanelController.Panel) -> ShortcutCommand? {
        switch panel {
        case .modules: .modulesPanel
        case .banks: .patchesPanel
        case .dsp: .dspLoad
        case .keyboard: .virtualKeyboard
        case .parameterPages: .parameterPages
        case .mutator: .mutatorWindow
        case .parameterOverview: .parameterOverview
        case .patchAdjuster: .patchAdjuster
        case .colors: .colors
        case .spectrogram: .spectrum
        case .xyPlot: .xyPlot
        case .sequenceEditor: .sequenceEditor
        // Opened from the Mutator window only.
        case .mutatorTree: nil
        }
    }

    static func layout(_ layout: SlotLayout) -> ShortcutCommand? {
        switch layout {
        case .single: .layoutSingleBar
        case .windows: .layoutWindows
        case .fourRows: nil
        }
    }

    static func overlay(_ mode: CanvasOverlayMode) -> ShortcutCommand? {
        switch mode {
        case .none: nil
        case .values: .showValues
        case .morphGroups: .showMorphGroups
        case .knobAssignments: .showKnobs
        case .midiControllers: .showMidi
        }
    }
}
