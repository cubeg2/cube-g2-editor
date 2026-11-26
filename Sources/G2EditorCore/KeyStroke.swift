// KeyStroke.swift
// A key with its modifiers: what the editor stores and shows as a keyboard shortcut.
// The AppKit and SwiftUI bridges live in the app target (`ShortcutKeys.swift`).

import Foundation

public struct KeyStroke: Hashable, Codable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Codable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// The character the key types without modifiers ("a", "1", "="), or the name of a key
    /// that types none (`specialKeys`, "f1"…"f19").
    public let key: String
    public let modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// Keys without a character of their own, with the sign the macOS menus show.
    private static let specialKeys: [String: String] = [
        "up": "↑", "down": "↓", "left": "←", "right": "→",
        "space": "Space", "return": "↩", "tab": "⇥", "escape": "Esc",
        "delete": "⌫", "forwarddelete": "⌦",
        "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
    ]

    public var isFunctionKey: Bool {
        key.count > 1 && key.hasPrefix("f") && Int(key.dropFirst()) != nil
    }

    public var isArrow: Bool {
        ["up", "down", "left", "right"].contains(key)
    }

    /// As in the macOS menus: ⌃⌥⇧⌘ and the key.
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (Self.specialKeys[key] ?? key.uppercased())
    }
}
