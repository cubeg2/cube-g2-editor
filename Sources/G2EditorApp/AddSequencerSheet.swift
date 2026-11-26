// AddSequencerSheet.swift
// Sequence Editor ▸ Add sequencer: a wide, low sheet in three columns — how it plays, its clock, and what it
// drives — with the DSP cost in the header (mockup "Sequence Editor Tune-Up" v2, user's notes 2026-11-26:
// no "what changes" list, horizontal rather than square). The wiring is `PatchState+AddSequencer`.
// → [[Docs/ui/sequence-editor-add-sequencer]]

import G2Core
import G2EditorCore
import SwiftUI

struct AddSequencerSheet: View {
    let state: PatchState
    let slot: Int
    let onAdded: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options: AddSequencerOptions?

    var body: some View {
        let choices = state.addSequencerChoices(slot: slot)
        let current = options ?? choices.defaultOptions
        VStack(alignment: .leading, spacing: 12) {
            header(choices, current)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                column(width: 250) { plays(choices, current) }
                Divider()
                column(width: 250) { clock(choices, current) }
                Divider()
                column(width: nil) { drives(choices, current) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            footer(current)
        }
        .padding(16)
        .frame(minWidth: 860)
        .onAppear { if options == nil { options = choices.defaultOptions } }
    }

    private func update(_ change: (inout AddSequencerOptions) -> Void) {
        var next = options ?? state.addSequencerChoices(slot: slot).defaultOptions
        change(&next)
        options = next
    }

    private func column(width: CGFloat?, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(.horizontal, 14)
            .frame(width: width, alignment: .topLeading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .topLeading)
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }

    // MARK: - Header

    private func header(_ choices: AddSequencerChoices, _ current: AddSequencerOptions) -> some View {
        let load = state.addSequencerLoad(slot: slot, options: current)
        let name = state.slots.indices.contains(slot) ? state.slots[slot].name : ""
        let letter = ["A", "B", "C", "D"][max(0, min(3, slot))]
        let clocks = choices.clocks.isEmpty ? "no clock yet" : choices.clocks.map(\.name).joined(separator: ", ")
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Add a note sequencer to Slot \(letter)").font(.system(size: 14, weight: .semibold))
                Text("“\(name)” · \(choices.isPoly ? "poly, \(choices.voiceModeLabel) voices" : choices.voiceModeLabel) · "
                    + "\(choices.oscillators.count) oscillators, \(choices.envelopes.count) envelopes, \(clocks)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                meter("Cycles", before: load.before.cyclesPercent, after: load.after.cyclesPercent)
                meter("Memory", before: load.before.memoryPercent, after: load.after.memoryPercent)
            }
            .frame(width: 300)
        }
    }

    private func meter(_ title: String, before: Double, after: Double) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.1))
                    RoundedRectangle(cornerRadius: 3).fill(after > 100 ? SeqColor.red : SeqColor.blue)
                        .frame(width: proxy.size.width * min(1, after / 100))
                    RoundedRectangle(cornerRadius: 3).fill(SeqColor.green.opacity(0.7))
                        .frame(width: proxy.size.width * min(1, before / 100))
                }
            }
            .frame(height: 8)
            Text(String(format: "%.1f → %.1f %%", before, after))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .frame(width: 104, alignment: .trailing)
        }
    }

    // MARK: - Columns

    private func plays(_ choices: AddSequencerChoices, _ current: AddSequencerOptions) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption("Plays")
            ForEach(SequencerPlayMode.offered) { mode in
                let chosen = current.mode == mode
                Button {
                    update { $0.mode = mode }
                } label: {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 15))
                            .foregroundStyle(chosen ? SeqColor.blue : .secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(mode.title).font(.system(size: 12, weight: .semibold))
                                if mode == choices.recommendedMode {
                                    Text("fits this patch")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(SeqColor.green)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(SeqColor.green.opacity(0.6)))
                                }
                            }
                            Text(mode.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? SeqColor.blue.opacity(0.14) : SeqColor.card))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(chosen ? SeqColor.blue : SeqColor.cardBorder, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func clock(_ choices: AddSequencerChoices, _ current: AddSequencerOptions) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("Clock")
            Picker("", selection: Binding(get: { current.clock }, set: { value in update { $0.clock = value } })) {
                ForEach(choices.clocks) { clock in
                    Text("\(clock.name) (in the patch)").tag(SequencerClockChoice.existing(clock.id))
                }
                Text("New, follows the top bar (Run, tempo)").tag(SequencerClockChoice.newFollowingTopBar)
                Text("New, own tempo (ignores Run)").tag(SequencerClockChoice.newOwnTempo)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .font(.system(size: 11.5))
            HStack(spacing: 8) {
                Text("Step").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { current.step }, set: { value in update { $0.step = value } })) {
                    ForEach(SequencerStep.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Toggle("Restart every bar",
                       isOn: Binding(get: { current.restartEveryBar }, set: { value in update { $0.restartEveryBar = value } }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
            }
            HStack(spacing: 8) {
                Text("Gate").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { current.wholeStepGate }, set: { value in update { $0.wholeStepGate = value } })) {
                    Text("Short").tag(false)
                    Text("Whole step").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Short: every step starts the envelope again. Whole step: steps in a row are tied into one long note.")
            }
        }
    }

    private func drives(_ choices: AddSequencerChoices, _ current: AddSequencerOptions) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("Drives")
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(current.mode == .rhythmOnKeys ? "Note to (keys play it)" : "Note to")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(choices.oscillators + choices.filters) { target in
                        targetToggle(target, isOn: current.pitchTargets.contains(target.id),
                                     enabled: current.mode != .rhythmOnKeys)
                        {
                            update { $0.pitchTargets.formSymmetricDifference([target.id]) }
                        }
                    }
                    if choices.oscillators.isEmpty, choices.filters.isEmpty {
                        Text("No oscillator the sequencer can reach.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Step to").font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(choices.envelopes) { target in
                        targetToggle(target, isOn: current.gateTargets.contains(target.id), enabled: true) {
                            update { $0.gateTargets.formSymmetricDifference([target.id]) }
                        }
                        if let slow = target.slowAttack, current.gateTargets.contains(target.id) {
                            Text("Opens in \(slow). Untick to keep it on the keys.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(SeqColor.orange)
                                .padding(.leading, 20)
                        }
                    }
                    if choices.envelopes.isEmpty {
                        Text("No envelope that follows the keys.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func targetToggle(_ target: AddSequencerTarget, isOn: Bool, enabled: Bool,
                              toggle: @escaping () -> Void) -> some View
    {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in toggle() })) {
            HStack(spacing: 4) {
                Text(target.name).font(.system(size: 11.5))
                Text(target.kind == .filter ? "\(target.detail) · filter" : target.detail)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!enabled)
    }

    // MARK: - Footer

    private func footer(_ current: AddSequencerOptions) -> some View {
        let obstacle = state.addSequencerObstacle(slot: slot, options: current)
        let note: String = switch obstacle {
        case .wontFit: "Not enough DSP left for these modules."
        case .noSoundSource: "Nothing in this patch the sequencer could drive."
        default: current.mode == .byItself && state.voiceModeIndex(slot: slot) >= 2
            ? "The patch becomes Mono: one copy of the pattern." : ""
        }
        return HStack(spacing: 8) {
            Text(note).font(.system(size: 11)).foregroundStyle(obstacle == nil ? Color.secondary : SeqColor.red)
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add sequencer") {
                if case let .added(id) = state.addSequencer(slot: slot, options: current) {
                    onAdded(id)
                }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(obstacle != nil)
        }
    }
}
