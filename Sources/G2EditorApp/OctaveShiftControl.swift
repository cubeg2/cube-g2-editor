// OctaveShiftControl.swift
// "Oct" in the slot bar, between Variations and Morph Groups (user's choice 2026-11-26): the patch's Octave
// Shift as on the keyboard's front panel — − and + with five LEDs for −2…+2. For the G2 Engine, which has no
// such buttons; the same setting as Patch Settings ▸ Octave Shift, one ⌘Z, sent to the G2.
// → [[Docs/ui/sequence-editor-add-sequencer]] "Oct w belce dla G2 Engine"

import G2Core
import G2EditorCore
import SwiftUI

struct OctaveShiftControl: View {
    /// Settings ▸ Display: shown in the slot bar or not — hidden by default (user's choice 2026-11-26).
    static let storageKey = "showOctaveShiftInTopBar"

    let state: PatchState
    let slot: Int

    var body: some View {
        let value = state.header(slot: slot).octaveShift
        HStack(spacing: 5) {
            Text("Oct")
                .font(.system(size: TopBarMetrics.captionSize))
                .foregroundStyle(.secondary)
            TopBarButton(content: .icon("minus"), isEnabled: value > 0) { set(value - 1) }
                .help("Octave down")
                .accessibilityLabel("Octave down")
            HStack(spacing: 4) {
                ForEach(0 ..< 5, id: \.self) { index in
                    Circle()
                        .fill(index == value ? Color.red : Color.primary.opacity(0.18))
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(index == 2 ? 0.35 : 0), lineWidth: 1))
                        .shadow(color: index == value ? .red.opacity(0.7) : .clear, radius: 2)
                }
            }
            .help("Octave Shift: \(["−2", "−1", "0", "+1", "+2"][max(0, min(4, value))])")
            TopBarButton(content: .icon("plus"), isEnabled: value < 4) { set(value + 1) }
                .help("Octave up")
                .accessibilityLabel("Octave up")
        }
    }

    private func set(_ value: Int) {
        state.focusSlot(slot)
        state.setPatchSetting(.octaveShift, value: value, slot: slot)
    }
}
