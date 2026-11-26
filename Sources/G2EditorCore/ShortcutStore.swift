// ShortcutStore.swift
// The user's keyboard shortcuts: the defaults of `ShortcutCommand` plus what was changed in
// Settings ▸ Shortcuts. Only the changes are stored.

import Foundation
import Observation

@MainActor
@Observable
public final class ShortcutStore {
    public static let shared = ShortcutStore()
    public static let storageKey = "g2_keyboard_shortcuts"

    /// What a stroke would do if it were given to a command.
    public enum Verdict: Equatable, Sendable {
        case free
        /// Held by these commands; assigning takes it from them.
        case taken([ShortcutCommand])
        /// Belongs to macOS or to a fixed editor key.
        case fixed
        /// A menu command on a plain key would swallow typing.
        case needsModifier
    }

    /// A changed command; `stroke == nil` means its shortcut was removed.
    private struct Change: Codable, Equatable {
        var stroke: KeyStroke?
    }

    private var changes: [String: Change]
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        changes = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: Change].self, from: $0) } ?? [:]
    }

    // MARK: Reading

    public func stroke(for command: ShortcutCommand) -> KeyStroke? {
        if let change = changes[command.id] { return change.stroke }
        guard let stroke = command.defaultStroke else { return nil }
        // A key the user gave to another command wins over a default — also over one that
        // a later version of the editor adds.
        let claimed = ShortcutCommand.all.contains {
            changes[$0.id]?.stroke == stroke && $0.scope.overlaps(command.scope)
        }
        return claimed ? nil : stroke
    }

    /// The command a key press runs among those of one scope. A letter or function key held
    /// with Shift alone also counts without it, unless Shift has a command of its own.
    public func command(for stroke: KeyStroke, in scope: ShortcutScope) -> ShortcutCommand? {
        let candidates = ShortcutCommand.all.filter { $0.scope == scope }
        if let exact = candidates.first(where: { self.stroke(for: $0) == stroke }) { return exact }
        guard stroke.modifiers == .shift else { return nil }
        let plain = KeyStroke(stroke.key)
        return candidates.first { self.stroke(for: $0) == plain }
    }

    /// " (⌘O)" for a tooltip, empty when the command has no shortcut.
    public func hint(_ command: ShortcutCommand) -> String {
        stroke(for: command).map { " (\($0.display))" } ?? ""
    }

    public func isChanged(_ command: ShortcutCommand) -> Bool {
        stroke(for: command) != command.defaultStroke
    }

    public var hasChanges: Bool {
        !changes.isEmpty
    }

    // MARK: Changing

    public func verdict(_ stroke: KeyStroke, for command: ShortcutCommand) -> Verdict {
        if Self.isFixed(stroke, in: command.scope) { return .fixed }
        if command.scope == .menu, !stroke.isFunctionKey,
           stroke.modifiers.isDisjoint(with: [.command, .control])
        {
            return .needsModifier
        }
        let holders = ShortcutCommand.all.filter {
            $0 != command && $0.scope.overlaps(command.scope) && self.stroke(for: $0) == stroke
        }
        return holders.isEmpty ? .free : .taken(holders)
    }

    /// Gives `stroke` to `command` and takes it from whoever held it. Ignores a stroke that
    /// is fixed or that a menu command cannot use.
    public func assign(_ stroke: KeyStroke, to command: ShortcutCommand) {
        switch verdict(stroke, for: command) {
        case .fixed, .needsModifier: return
        case .free: break
        case let .taken(holders):
            for holder in holders {
                set(nil, for: holder)
            }
        }
        set(stroke, for: command)
        save()
    }

    public func remove(from command: ShortcutCommand) {
        set(nil, for: command)
        save()
    }

    /// Back to the shipped shortcut, taking it back from another command if need be.
    public func reset(_ command: ShortcutCommand) {
        if let stroke = command.defaultStroke {
            assign(stroke, to: command)
        }
        changes[command.id] = nil
        save()
    }

    public func resetAll() {
        changes = [:]
        save()
    }

    private func set(_ stroke: KeyStroke?, for command: ShortcutCommand) {
        changes[command.id] = stroke == command.defaultStroke ? nil : Change(stroke: stroke)
    }

    private func save() {
        guard !changes.isEmpty, let data = try? JSONEncoder().encode(changes) else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    // MARK: Fixed keys

    private static let fixedStrokes: Set<KeyStroke> = {
        var strokes: Set<KeyStroke> = [
            KeyStroke(",", .command), KeyStroke("q", .command), KeyStroke("h", .command),
            KeyStroke("h", [.option, .command]), KeyStroke("w", .command),
            KeyStroke("w", [.option, .command]), KeyStroke("m", .command),
            KeyStroke("x", .command), KeyStroke("c", .command), KeyStroke("v", .command),
            KeyStroke("a", .command), KeyStroke("z", .command), KeyStroke("z", [.shift, .command]),
            KeyStroke("y", .command), KeyStroke("tab", .command), KeyStroke("space", .command),
        ]
        for modifiers: KeyStroke.Modifiers in [[], .shift] {
            for key in ["space", "return", "tab", "delete", "forwarddelete"] {
                strokes.insert(KeyStroke(key, modifiers))
            }
        }
        for modifiers: KeyStroke.Modifiers in [[], .shift, .control, [.control, .shift]] {
            for key in ["up", "down", "left", "right"] {
                strokes.insert(KeyStroke(key, modifiers))
            }
        }
        return strokes
    }()

    private static func isFixed(_ stroke: KeyStroke, in scope: ShortcutScope) -> Bool {
        if stroke.key == "escape" || fixedStrokes.contains(stroke) { return true }
        // ⌥ + arrows walk the evolution tree of the Mutator.
        return scope == .mutator && stroke.isArrow && stroke.modifiers == .option
    }
}
