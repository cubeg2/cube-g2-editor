// SequencePlayStrip.swift
// Edit tab of the Sequence Editor, above the tools: how a note sequencer plays (By itself, Follows held keys,
// Rhythm on held keys) and its clock (which ClkGen, top bar or own tempo, step length, restart every bar).
// Every change rewires the patch as one ⌘Z (`PatchState+AddSequencer`). Mockup "Sequence Editor Tune-Up"
// (2026-11-26) → [[Docs/ui/sequence-editor-add-sequencer]]

import G2Core
import G2EditorCore
import SwiftUI

struct SequencePlayStrip: View {
    let state: PatchState
    let target: SequenceTarget
    /// The mode waiting for "Switch": a change rewires cables, so it is confirmed first.
    @State private var pending: SequencerPlayMode?

    private var isNoteSequencer: Bool {
        target.area == .voice && state.slots.indices.contains(target.slot)
            && state.slots[target.slot].modules(in: .voice)
            .contains { $0.id == target.moduleID && $0.typeID == PatchState.noteSequencerTypeID }
    }

    var body: some View {
        if isNoteSequencer {
            let mode = state.sequencerPlayMode(slot: target.slot, area: target.area, sequencerID: target.moduleID)
            let clock = state.sequencerClock(slot: target.slot, area: target.area, sequencerID: target.moduleID)
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        if SequencerPlayMode.offered.count > 1 { plays(mode) }
                        if let clock { clockControls(clock) }
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if SequencerPlayMode.offered.count > 1 { plays(mode) }
                        if let clock { clockControls(clock) }
                    }
                }
                if let pending, let mode { confirmation(from: mode, to: pending) }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }

    private func plays(_ mode: SequencerPlayMode?) -> some View {
        HStack(spacing: 6) {
            caption("Plays")
            ForEach(SequencerPlayMode.offered) { item in
                TopBarButton(content: .iconText(item.systemImage, item.title), isOn: (pending ?? mode) == item,
                             tint: SeqColor.blue, isEnabled: mode != nil)
                {
                    pending = item == mode ? nil : item
                }
                .help(mode == nil
                    ? "This sequencer is wired by hand (Custom). Plays changes sequencers added with Add sequencer, or wired the same way."
                    : item.summary)
            }
            if mode == nil {
                Text("Custom").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }

    private func confirmation(from mode: SequencerPlayMode, to next: SequencerPlayMode) -> some View {
        HStack(spacing: 10) {
            Text(confirmationText(from: mode, to: next))
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            TopBarButton(content: .text("Switch"), isOn: true, tint: SeqColor.blue) {
                state.setSequencerPlayMode(next, slot: target.slot, sequencerID: target.moduleID)
                pending = nil
            }
            TopBarButton(content: .text("Cancel")) { pending = nil }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(SeqColor.blue.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SeqColor.blue.opacity(0.6), lineWidth: 1))
    }

    private func confirmationText(from mode: SequencerPlayMode, to next: SequencerPlayMode) -> String {
        var text = "Switch to “\(next.title)”? The cables are rewired"
        if next == .byItself, state.voiceModeIndex(slot: target.slot) >= 2 {
            text += " and the patch becomes Mono"
        } else if mode == .byItself, state.voiceModeIndex(slot: target.slot) == 1,
                  state.voiceModeBeforeSequencer[target.slot] != nil
        {
            text += " and the voices come back"
        }
        return text + ". One ⌘Z undoes it."
    }

    // MARK: - Clock

    private func clockModule(_ info: SequencerClockInfo) -> G2Module? {
        guard let id = info.clockID else { return nil }
        return state.slots[target.slot].modules(in: .voice).first { $0.id == id }
    }

    @ViewBuilder
    private func clockControls(_ info: SequencerClockInfo) -> some View {
        let clocks = state.slots[target.slot].modules(in: .voice).filter { $0.typeID == PatchState.clockGeneratorTypeID }
        HStack(spacing: 6) {
            caption("Clock")
            Menu(info.clockName) {
                ForEach(clocks, id: \.id) { clock in
                    let name = clock.label.isEmpty ? "ClkGen" : clock.label
                    Button(clock.id == info.clockID ? "✓ \(name)" : name) {
                        state.setSequencerClock(.existing(clock.id), slot: target.slot, sequencerID: target.moduleID)
                    }
                }
                Divider()
                Button("New clock that follows the top bar") {
                    state.setSequencerClock(.newFollowingTopBar, slot: target.slot, sequencerID: target.moduleID)
                }
                Button("New clock with its own tempo") {
                    state.setSequencerClock(.newOwnTempo, slot: target.slot, sequencerID: target.moduleID)
                }
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(info.clockID == nil)
            .help(info.clockID == nil
                ? "Clocked by \(info.clockName), not by a clock generator"
                : "The clock generator that drives this sequencer")
            if let module = clockModule(info), module.parameters.count > ClockGenSettings.swing {
                TopBarButton(content: .text("Top bar"), isOn: info.followsTopBar, tint: SeqColor.blue) {
                    write(module, ClockGenSettings.source, 1)
                }
                .help("Tempo and Run come from the top bar (Master Clock)")
                TopBarButton(content: .text("Own tempo"), isOn: !info.followsTopBar, tint: SeqColor.blue) {
                    write(module, ClockGenSettings.source, 0)
                }
                .help("The clock runs at its own tempo and ignores Run")
                if !info.followsTopBar {
                    SeqNumberControl(title: "Tempo", value: module.parameters[ClockGenSettings.rate], range: 0 ... 127,
                                     state: state, display: bpmText, valueWidth: 36)
                    {
                        write(module, ClockGenSettings.rate, $0)
                    }
                }
                Menu(info.step?.title ?? "Step") {
                    ForEach(SequencerStep.allCases) { step in
                        Button(step == info.step ? "✓ \(step.title)" : step.title) {
                            state.setSequencerStep(step, slot: target.slot, sequencerID: target.moduleID)
                        }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
                .help("Step length. 1/16 comes straight from the clock; the others add a clock divider.")
                TopBarButton(content: .iconText("arrow.counterclockwise", "Restart every bar"),
                             isOn: info.restartsEveryBar, tint: SeqColor.blue)
                {
                    state.setSequencerRestart(!info.restartsEveryBar, slot: target.slot, sequencerID: target.moduleID)
                }
                .help("The clock's Sync pulse sends the pattern back to step 1")
            }
        }
    }

    private func bpmText(_ value: Int) -> String {
        "\(ClockGenSettings.bpm(forRate: value))"
    }

    private func write(_ module: G2Module, _ index: Int, _ value: Int) {
        state.setParameter(slot: target.slot, moduleID: module.id, paramIndex: index, value: value, area: .voice)
    }
}
