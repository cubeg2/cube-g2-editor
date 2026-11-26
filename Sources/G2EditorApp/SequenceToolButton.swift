// SequenceToolButton.swift
// Toolbar button of the Sequence Editor: a symbol, with its name beside it while "Labels" is on
// (mockup "Sequence Editor Tune-Up", user's choice 2026-11-26). The symbol takes the colour of its
// family: orange for the random tools, red for Clear, blue when a switch is on.
// → [[Docs/ui/sequence-editor-add-sequencer]]

import SwiftUI

/// Shown next to the icons in the Sequence Editor's toolbars; off = icons only for a narrow window.
enum SequenceToolLabels {
    static let key = "sequenceEditor.showLabels"
}

struct SeqToolButton: View {
    let icon: String
    let title: String
    var tint: Color?
    var isOn = false
    var onTint: Color = SeqColor.blue
    var isEnabled = true
    var outline: Color?
    let action: () -> Void

    @AppStorage(SequenceToolLabels.key) private var showLabels = true

    var body: some View {
        TopBarButton(content: showLabels ? .iconText(icon, title) : .icon(icon), isOn: isOn, tint: onTint,
                     isEnabled: isEnabled, outline: outline, iconTint: tint, action: action)
            .accessibilityLabel(title)
    }
}

/// The families of the toolbar, for `SeqToolButton.tint`.
extension SeqColor {
    /// Random, Mutate, Humanize, generators.
    static let generate = orange
    /// Clear and other destructive buttons.
    static let destructive = red
}
