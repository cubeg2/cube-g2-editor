// PatchCanvasView+ValueEntry.swift
// Wartość gałki z klawiatury i dymek wartości po strzałkach.
//
// Dwuklik na gałce (albo „Enter Value…" z menu) otwiera pole w miejscu paska ▼▲
// — wygląda jak dymek wartości, więc nie przynosi na kanwę nowego rodzaju okienka.
// Enter ustawia najbliższą pozycję (`G2ValueEntry`), Esc i kliknięcie obok zamykają
// bez zmian. Wynik pokazuje ten sam dymek, co strzałki.
// Życzenie z forum electro-music, wątek 6195.

import AppKit
import G2Core
import G2EditorCore
import SwiftUI

/// Otwarte pole wpisywania wartości.
struct ValueEntryState: Equatable {
    let moduleID: Int
    let paramIndex: Int
    /// Pasek ▼▲ gałki obrotowej (albo pas tej samej wysokości pod suwakiem) w pt kanwy.
    let strip: CGRect
}

extension PatchCanvasView {
    /// Jak długo dymek stoi po ostatnim naciśnięciu strzałki.
    private static let keyHintDuration: UInt64 = 1_500_000_000

    // MARK: - Dymek po strzałkach

    /// Ten sam dymek co pod kursorem, przy kontrolce z focusem. Przytrzymana strzałka
    /// przesuwa termin zgaszenia, więc dymek stoi przez cały ruch.
    func showKeyHint(_ focus: ParameterFocus) {
        guard let rect = focusRect(focus),
              let hit = findHoverHit(at: CGPoint(x: rect.midX, y: rect.midY)),
              hit.moduleID == focus.moduleID, hit.paramIndex == focus.paramIndex
        else { return }
        keyHint = hit
        keyHintTask?.cancel()
        keyHintTask = Task {
            try? await Task.sleep(nanoseconds: Self.keyHintDuration)
            guard !Task.isCancelled else { return }
            await MainActor.run { keyHint = nil }
        }
    }

    // MARK: - Pole wpisywania

    func beginValueEntry(moduleID: Int, paramIndex: Int) {
        let focus = ParameterFocus(moduleID: moduleID, paramIndex: paramIndex)
        guard let rect = focusRect(focus),
              let hit = findHoverHit(at: CGPoint(x: rect.midX, y: rect.midY)),
              let module = modules.first(where: { $0.id == moduleID }),
              module.parameters.indices.contains(paramIndex)
        else { return }
        let strip = hit.btnsRect ?? CGRect(x: rect.minX, y: rect.maxY + 0.5,
                                           width: rect.width, height: UIMetrics.textFieldHeight)
        focusedParam = focus
        activeModuleID = moduleID
        keyHint = nil
        let current = module.parameters[paramIndex]
        let text = hintValueText(hit, params: module.parameters, value: current)
        valueEntryText = text.isEmpty ? String(current) : text
        valueEntry = ValueEntryState(moduleID: moduleID, paramIndex: paramIndex, strip: strip)
    }

    private func commitValueEntry() {
        guard let entry = valueEntry,
              let module = modules.first(where: { $0.id == entry.moduleID }),
              module.parameters.indices.contains(entry.paramIndex),
              let rect = focusRect(ParameterFocus(moduleID: entry.moduleID, paramIndex: entry.paramIndex)),
              let hit = findHoverHit(at: CGPoint(x: rect.midX, y: rect.midY))
        else {
            valueEntry = nil
            return
        }
        let range = ParameterRangeDatabase.range(moduleTypeID: module.typeID,
                                                 codeRef: entry.paramIndex) ?? 0 ... 127
        let current = module.parameters[entry.paramIndex]
        guard let value = G2ValueEntry.value(for: valueEntryText, current: current, in: range, text: {
            let text = hintValueText(hit, params: module.parameters, value: $0)
            return text.isEmpty ? String($0) : text
        }) else {
            // Tekst nie pasuje do żadnej pozycji — pole zostaje, żeby dało się poprawić.
            NSSound.beep()
            return
        }
        valueEntry = nil
        if value != current {
            onParameterChange?(entry.moduleID, entry.paramIndex, value)
        }
        showKeyHint(ParameterFocus(moduleID: entry.moduleID, paramIndex: entry.paramIndex))
    }

    /// Ekranik w miejscu paska ▼▲: wysokość, tło, font i kolor jak ekrany modułów,
    /// Ekranik jak na modułach (tło, font, wysokość) z obwódką w kolorze ramki focusu,
    /// ale napis biały jak w dymku — to pole do pisania, nie odczyt. Leży nad ramką
    /// focusu: montowane jako nakładka po niej. Szerszy niż pasek, żeby zmieścił „1.48kHz".
    @ViewBuilder
    var valueEntryOverlay: some View {
        if let entry = valueEntry {
            let height = UIMetrics.textFieldHeight
            let fontSize = UIFont.lcdDisplay(boxHeight: height)
            let width = max(entry.strip.width * 1.7, fontSize * 0.62 * CGFloat(valueEntryText.count + 1))
            let corner = UIMetrics.socketCornerRadius * zoom
            ValueEntryTextField(text: $valueEntryText, fontSize: fontSize * zoom,
                                onCommit: { commitValueEntry() },
                                onCancel: { valueEntry = nil })
                .padding(.horizontal, zoom)
                .frame(width: width * zoom, height: height * zoom)
                .background(RoundedRectangle(cornerRadius: corner).fill(UIColor.lcdBackground))
                .overlay(RoundedRectangle(cornerRadius: corner)
                    .stroke(Color.accentColor.opacity(0.9), lineWidth: 0.6 * zoom))
                .position(x: entry.strip.midX * zoom, y: entry.strip.midY * zoom)
        }
    }
}

// MARK: - Pole tekstowe AppKit

/// `TextField` SwiftUI nie pozwala ustawić koloru zaznaczenia, a pole ma je w negatywie
/// (białe tło, napis w kolorze tła ekranu) i biały kursor. Wygląd zaznaczenia należy
/// do edytora pola, wspólnego dla całego okna, więc po edycji wraca poprzedni.
struct ValueEntryTextField: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .white
        field.alignment = .center
        field.font = font
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        // Pole trafia do okna dopiero po tym wywołaniu.
        DispatchQueue.main.async {
            guard let window = field.window, window.makeFirstResponder(field),
                  let editor = field.currentEditor() as? NSTextView else { return }
            context.coordinator.styleEditor(editor)
            editor.selectAll(nil)
        }
        return field
    }

    /// Font ekranów modułów w rozmiarze z bieżącym zoomem.
    private var font: NSFont {
        NSFont(name: "MatrixSansScreen-Regular", size: fontSize)
            ?? .monospacedSystemFont(ofSize: fontSize, weight: .medium)
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
        // Zoom w trakcie pisania: pole rośnie razem z kanwą, więc napis też. Tekst
        // w edycji rysuje edytor pola, nie samo pole — jemu też trzeba podać font.
        if field.font?.pointSize != fontSize {
            field.font = font
            (field.currentEditor() as? NSTextView)?.font = font
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ValueEntryTextField
        private var saved: (attributes: [NSAttributedString.Key: Any], caret: NSColor)?
        private weak var editor: NSTextView?

        init(_ parent: ValueEntryTextField) {
            self.parent = parent
        }

        func styleEditor(_ editor: NSTextView) {
            saved = (editor.selectedTextAttributes, editor.insertionPointColor)
            self.editor = editor
            editor.selectedTextAttributes = [.backgroundColor: NSColor.white,
                                             .foregroundColor: NSColor(UIColor.lcdBackground)]
            editor.insertionPointColor = .white
        }

        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }

        /// Kursor wyszedł z pola (klik obok, Tab, inne okno) — zamykamy bez zmian.
        func controlTextDidEndEditing(_: Notification) {
            if let editor, let saved {
                editor.selectedTextAttributes = saved.attributes
                editor.insertionPointColor = saved.caret
            }
            saved = nil
            parent.onCancel()
        }
    }
}
