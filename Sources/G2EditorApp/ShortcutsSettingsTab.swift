// ShortcutsSettingsTab.swift
// Settings ▸ Shortcuts: every command of `ShortcutCommand` with its key, in one list that can
// be searched by name or by pressing a key; a click on a key records a new one. Fixed keys
// are listed too, with a lock. The window stands at the top of the screen on this page
// (`SettingsWindow.fit`), so the list gets the whole height.

import AppKit
import G2EditorCore
import SwiftUI

/// Catches key presses in the settings window before the menus and the monitors see them.
@MainActor
final class ShortcutRecorder {
    /// Monitors that would eat the key (`MusicalTyping`) stand aside while this is on.
    private(set) static var isCapturing = false

    private var monitor: Any?

    /// `received(nil)` = Esc, nothing to record.
    func start(_ received: @escaping (KeyStroke?) -> Void) {
        stop()
        Self.isCapturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.identifier == SettingsWindow.identifier else { return event }
            // A key without a name (dead keys, media keys) is swallowed: still recording.
            guard let stroke = KeyStroke(event: event) else { return nil }
            let cancels = stroke.key == "escape"
                && stroke.modifiers.isDisjoint(with: [.command, .option, .control])
            received(cancels ? nil : stroke)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        Self.isCapturing = false
    }
}

struct ShortcutsSettingsTab: View {
    let height: CGFloat

    private enum Filter: String, CaseIterable {
        case all = "All"
        case changed = "Changed"
        case unassigned = "No Shortcut"
    }

    private enum Recording: Equatable {
        case command(ShortcutCommand)
        case find
    }

    /// A key that needs an answer before (or instead of) being assigned.
    private struct Question: Equatable {
        let command: ShortcutCommand
        let stroke: KeyStroke
        let verdict: ShortcutStore.Verdict
        /// Asked by the restore arrow: „Replace” restores the default.
        var restores = false
    }

    @State private var recorder = ShortcutRecorder()
    @State private var recording: Recording?
    @State private var question: Question?
    @State private var search = ""
    @State private var filter = Filter.all
    @State private var keyFilter: KeyStroke?
    /// The section at the top of the list: the sidebar lights it and scrolls to it.
    @State private var section: ShortcutSection? = .file
    @State private var confirmsRestore = false

    private var store: ShortcutStore {
        .shared
    }

    private static let sidebarWidth: CGFloat = 180
    private static let keyWidth: CGFloat = 120
    private static let iconWidth: CGFloat = 24

    var body: some View {
        let sections = ShortcutSection.allCases.filter { !commands(in: $0).isEmpty || !fixed(in: $0).isEmpty }
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            HStack(alignment: .top, spacing: 14) {
                sidebar(sections)
                list(sections)
            }
            footer
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(width: SettingsWindow.contentWidth, height: height, alignment: .top)
        .onDisappear(perform: stopRecording)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stopRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindow.willClose)) { _ in
            stopRecording()
        }
        .alert("Restore all default shortcuts?", isPresented: $confirmsRestore) {
            Button("Restore", role: .destructive) { store.resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your own shortcuts are removed.")
        }
    }

    // MARK: Chrome

    private var toolbar: some View {
        HStack(spacing: 8) {
            TextField("Search commands", text: $search)
                .textFieldStyle(.roundedBorder)
            TopBarButton(content: .iconText("keyboard", recording == .find ? "Press keys…" : "Find by Key"),
                         isOn: recording == .find)
            {
                recording == .find ? stopRecording() : record(.find)
            }
            .help("Press a key combination to see what it does")
            if let key = keyFilter {
                TopBarButton(content: .iconText("xmark", "Key: \(key.display)"), isOn: true) { keyFilter = nil }
            }
            HStack(spacing: 3) {
                ForEach(Filter.allCases, id: \.self) { value in
                    TopBarButton(content: .text(value.rawValue), isOn: filter == value) { filter = value }
                }
            }
            .padding(.leading, 6)
        }
    }

    private func sidebar(_ sections: [ShortcutSection]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(sections) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { section = item }
                } label: {
                    Text(item.title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(section == item ? Color.accentColor : Color.primary)
                        .background(RoundedRectangle(cornerRadius: TopBarMetrics.cornerRadius)
                            .fill(section == item ? Color.accentColor.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: Self.sidebarWidth)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Click a key to change it. While Caps Lock is on, letter keys play notes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            TopBarButton(content: .text("Restore All Defaults"), isEnabled: store.hasChanges) {
                stopRecording()
                confirmsRestore = true
            }
        }
    }

    // MARK: List

    private func list(_ sections: [ShortcutSection]) -> some View {
        ScrollView {
            // Not lazy: the sidebar jumps to sections far down the list.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { item in
                    VStack(alignment: .leading, spacing: 0) {
                        header(item)
                        ForEach(commands(in: item)) { command in
                            row(command)
                            if let question, question.command == command { banner(question) }
                            Divider()
                        }
                        ForEach(fixed(in: item)) { entry in
                            fixedRow(entry)
                            Divider()
                        }
                    }
                    .id(item)
                }
                if sections.isEmpty {
                    Text("No commands match.")
                        .foregroundStyle(.secondary)
                        .padding(20)
                }
            }
            .scrollTargetLayout()
            .padding(.trailing, 14)
        }
        .scrollPosition(id: $section, anchor: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.03)))
    }

    private func header(_ item: ShortcutSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.title).font(.headline)
            if let note = Self.note(item) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private static func note(_ section: ShortcutSection) -> String? {
        switch section {
        case .slots, .canvas: "On the patch, never while you type a name."
        case .patchesPanel: "While the Patches drawer shows the Disk list."
        case .mutator: "In the Patch Mutator window."
        default: nil
        }
    }

    private func row(_ command: ShortcutCommand) -> some View {
        let stroke = store.stroke(for: command)
        let isRecording = recording == .command(command)
        return HStack(spacing: 6) {
            Text(command.title)
            Spacer(minLength: 8)
            if store.isChanged(command) {
                iconButton("arrow.uturn.backward",
                           help: "Restore the default" + (command.defaultStroke.map { " (\($0.display))" } ?? ""))
                {
                    restore(command)
                }
            }
            TopBarButton(content: .text(isRecording ? "Press keys…" : stroke?.display ?? "Add"),
                         isOn: isRecording, fixedWidth: Self.keyWidth)
            {
                isRecording ? stopRecording() : record(.command(command))
            }
            if stroke != nil {
                iconButton("xmark", help: "Remove the shortcut") {
                    stopRecording()
                    store.remove(from: command)
                }
            } else {
                Color.clear.frame(width: Self.iconWidth, height: 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private func fixedRow(_ entry: FixedShortcut) -> some View {
        HStack(spacing: 6) {
            Text(entry.title)
            Spacer(minLength: 8)
            Text(entry.keys)
                .font(.system(size: TopBarMetrics.labelSize, weight: .medium))
                .padding(.horizontal, TopBarMetrics.labelPadding)
                .frame(minWidth: Self.keyWidth, minHeight: TopBarMetrics.controlSide)
                .overlay(RoundedRectangle(cornerRadius: TopBarMetrics.cornerRadius)
                    .strokeBorder(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .frame(width: Self.iconWidth)
                .help("This key cannot be changed")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: Self.iconWidth, height: TopBarMetrics.controlSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func banner(_ question: Question) -> some View {
        let key = question.stroke.display
        let text: String
        var replaces = false
        switch question.verdict {
        case let .taken(holders):
            let names = holders.map { "“\($0.title)” (\($0.section.title))" }.joined(separator: " and ")
            text = "\(key) is used by \(names)."
            replaces = true
        case .fixed: text = "\(key) is a fixed key and can’t be used."
        case .needsModifier: text = "\(key) won’t work for a menu command: add ⌘ or ⌃, or use an F key."
        case .free: text = ""
        }
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(text)
            Spacer(minLength: 8)
            if replaces {
                TopBarButton(content: .text("Replace"), isOn: true, tint: .orange) {
                    if question.restores {
                        store.reset(question.command)
                    } else {
                        store.assign(question.stroke, to: question.command)
                    }
                    self.question = nil
                }
            }
            TopBarButton(content: .text(replaces ? "Cancel" : "OK")) { self.question = nil }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.14)))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    // MARK: Filtering

    private func commands(in section: ShortcutSection) -> [ShortcutCommand] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return ShortcutCommand.all.filter { command in
            guard command.section == section else { return false }
            let stroke = store.stroke(for: command)
            switch filter {
            case .all: break
            case .changed: guard store.isChanged(command) else { return false }
            case .unassigned: guard stroke == nil else { return false }
            }
            if let keyFilter, stroke != keyFilter { return false }
            guard !query.isEmpty else { return true }
            return command.title.localizedCaseInsensitiveContains(query)
                || stroke?.display.localizedCaseInsensitiveContains(query) == true
        }
    }

    private func fixed(in section: ShortcutSection) -> [FixedShortcut] {
        guard filter == .all else { return [] }
        let query = search.trimmingCharacters(in: .whitespaces)
        return FixedShortcut.all.filter { entry in
            guard entry.section == section else { return false }
            if let keyFilter, !entry.keys.components(separatedBy: " ").contains(keyFilter.display) {
                return false
            }
            guard !query.isEmpty else { return true }
            return entry.title.localizedCaseInsensitiveContains(query)
                || entry.keys.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: Recording

    private func record(_ target: Recording) {
        question = nil
        recording = target
        recorder.start { stroke in
            stopRecording()
            guard let stroke else { return }
            switch target {
            case .find:
                // The key says what to show; a name typed before would hide it.
                search = ""
                filter = .all
                keyFilter = stroke
            case let .command(command):
                let verdict = store.verdict(stroke, for: command)
                if verdict == .free {
                    store.assign(stroke, to: command)
                } else {
                    question = Question(command: command, stroke: stroke, verdict: verdict)
                }
            }
        }
    }

    private func stopRecording() {
        recorder.stop()
        recording = nil
    }

    private func restore(_ command: ShortcutCommand) {
        stopRecording()
        if let stroke = command.defaultStroke, case .taken = store.verdict(stroke, for: command) {
            question = Question(command: command, stroke: stroke,
                                verdict: store.verdict(stroke, for: command), restores: true)
        } else {
            question = nil
            store.reset(command)
        }
    }
}
