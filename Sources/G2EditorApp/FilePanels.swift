// FilePanels.swift
// Okno zapisu pliku dla poleceń „Save As", „Save From ▸ Slot X" i „Save InitPatch"
// z menu File (instrukcja Clavii, str. 116).
//
// `NSSavePanel` jest modalne i wołane wprost z akcji menu — SwiftUI ma `fileExporter`,
// ale ten wymaga typu dokumentu i bindingu w drzewie widoków, a polecenia menu żyją
// poza nim (patrz `MainMenuCommands`).

import AppKit
import UniformTypeIdentifiers

enum FilePanels {
    /// Okno wyboru jednego pliku o danym rozszerzeniu — `nil`, gdy użytkownik anulował.
    @MainActor
    static func openURL(extension fileExtension: String, directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = directory
        panel.allowedContentTypes = [contentType(for: fileExtension)]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Pokazuje okno zapisu i zwraca wybrany plik — `nil`, gdy użytkownik anulował.
    /// `directory` otwiera okno w tym folderze; bez niego macOS pokazuje ostatnio używany.
    @MainActor
    static func saveURL(name: String, extension fileExtension: String, directory: URL? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.directoryURL = directory
        // Sama nazwa, BEZ rozszerzenia: przy `allowedContentTypes` okno dokleja je samo.
        // Podane z rozszerzeniem dawało „Arpeggiaperc.pch2.pch2" (zgłoszenie 2026-09-26).
        panel.nameFieldStringValue = sanitized(name)
        panel.allowedContentTypes = [contentType(for: fileExtension)]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // Okno pozwala skasować rozszerzenie — dopisujemy je z powrotem, bo bez niego
        // ani edytor, ani oryginał pliku nie rozpozna.
        return url.pathExtension.lowercased() == fileExtension
            ? url
            : url.appendingPathExtension(fileExtension)
    }

    /// ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z w oknach Open i Save. Menu Edit jest nasze (SwiftUI —
    /// `EditPasteboardCommands`), a jego pozycje nie działają, gdy okno pliku trzyma aplikację
    /// w trybie modalnym: skrót ginął i pole nazwy kopiowało tylko z menu prawego przycisku
    /// (zgłoszenie 2026-09-26). Tu, zanim zobaczy go menu, skrót idzie wprost do pola okna —
    /// tą samą drogą, którą szłaby systemowa pozycja Edit ▸ Copy.
    @MainActor
    static func installEditShortcuts() {
        guard editMonitor == nil else { return }
        editMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.keyWindow is NSSavePanel,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                  || event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
                  let key = event.charactersIgnoringModifiers?.lowercased(),
                  let action = editAction(key: key, shift: event.modifierFlags.contains(.shift))
            else { return event }
            return NSApp.sendAction(action, to: nil, from: nil) ? nil : event
        }
    }

    private static var editMonitor: Any?

    private static func editAction(key: String, shift: Bool) -> Selector? {
        switch (key, shift) {
        case ("c", false): #selector(NSText.copy(_:))
        case ("v", false): #selector(NSText.paste(_:))
        case ("x", false): #selector(NSText.cut(_:))
        case ("a", false): #selector(NSText.selectAll(_:))
        case ("z", false): Selector(("undo:"))
        case ("z", true): Selector(("redo:"))
        default: nil
        }
    }

    /// `.pch2` i `.prf2` nie są zarejestrowane w systemie, więc typ tworzymy z rozszerzenia.
    private static func contentType(for fileExtension: String) -> UTType {
        UTType(filenameExtension: fileExtension) ?? .data
    }

    private static func sanitized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}
