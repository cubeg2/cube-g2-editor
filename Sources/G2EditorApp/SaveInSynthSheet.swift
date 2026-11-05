// SaveInSynthSheet.swift
// Okno „Synth ▸ Save In Synth…” — patch slotu z focusem albo cały performance do jednego
// miejsca w banku Norda. U Clavii dwie listy: bank i miejsce (instrukcja, „Save In Synth”).
// Lista pokazuje wszystkie 32 banki patchy (8 performance'ów) po 128 miejsc, także puste —
// panel Banks pokazuje tylko te z zawartością. Zapis robi `DeviceConnection.saveInSynth`
// → [[Docs/usb/bank-dump]].

import G2Core
import G2EditorCore
import SwiftUI

struct SaveInSynthSheet: View {
    @Binding var isPresented: Bool
    let state: PatchState
    let device: DeviceConnection

    private static let locations = G2BankGroup.locationsPerBank

    @State private var kind: G2BankEntry.Kind
    /// Bank wskazany w panelu Banks — ma pierwszeństwo przed zapamiętanym.
    private let requestedBank: Int?
    /// Bank i miejsce od 0, jak w `G2BankEntry`.
    @State private var bank = 0
    @State private var location = 0
    @State private var isSaving = false
    /// Nazwa, pod którą patch (performance) trafi do banku — wpisana też w slot edytora.
    @State private var name = ""
    /// Ostatnio użyty bank (od 0, -1 = jeszcze żaden) — zapisuje się zwykle do tego samego.
    @AppStorage("g2_save_in_synth_patch_bank") private var lastPatchBank = -1
    @AppStorage("g2_save_in_synth_performance_bank") private var lastPerformanceBank = -1
    @State private var failure: String?

    init(isPresented: Binding<Bool>, state: PatchState, device: DeviceConnection) {
        _isPresented = isPresented
        self.state = state
        self.device = device
        let requested = state.saveInSynthBank
        _kind = State(initialValue: requested?.kind
            ?? (device.performanceMode == true && state.hasPerformanceSettings ? .performance : .patch))
        requestedBank = requested?.bank
    }

    private var bankCount: Int {
        G2BankGroup.bankCount(kind)
    }

    private func entries(inBank bank: Int) -> [G2BankEntry] {
        device.bankEntries.filter { $0.kind == kind && $0.bank == bank }
    }

    private var occupant: G2BankEntry? {
        entries(inBank: bank).first { $0.patch == location }
    }

    private var slotLabel: String {
        ["A", "B", "C", "D"][min(max(state.selectedSlot, 0), 3)]
    }

    private var nameToSave: String {
        if kind == .performance { return state.performanceName }
        return state.slots.indices.contains(state.selectedSlot) ? state.slots[state.selectedSlot].name : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Save In Synth").font(.title2.bold()).padding()
            Divider()
            form
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            buttons.padding()
        }
        .frame(width: 440, height: 320)
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            state.saveInSynthBank = nil
            name = nameToSave
            pickDefaultPlace(preferred: requestedBank)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $kind) {
                Text("Patch (Slot \(slotLabel))").tag(G2BankEntry.Kind.patch)
                Text("Performance").tag(G2BankEntry.Kind.performance)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: kind) { _, _ in
                name = nameToSave
                pickDefaultPlace()
            }

            LabeledContent("Name") {
                TextField("Name", text: $name, prompt: Text("No name"))
                    .labelsHidden()
                    .onChange(of: name) { _, new in
                        let limit = kind == .patch ? G2PatchName.maxLength : G2UsbProtocol.performanceNameLength
                        if new.count > limit { name = String(new.prefix(limit)) }
                    }
            }

            Picker("Bank", selection: $bank) {
                ForEach(0 ..< bankCount, id: \.self) { index in
                    Text(bankTitle(index)).tag(index)
                }
            }
            .onChange(of: bank) { _, new in location = firstFreeLocation(inBank: new) }

            Picker("Location", selection: $location) {
                ForEach(0 ..< Self.locations, id: \.self) { index in
                    Text(locationTitle(index)).tag(index)
                }
            }

            if device.synthSettings?.memoryProtect == true {
                Label("Memory Protect is on in the G2, so it will refuse to save. "
                    + "Switch it off in Synth Settings first.", systemImage: "lock")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let occupant {
                Label("Replaces “\(occupant.name)” in the G2 memory.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttons: some View {
        HStack {
            if isSaving {
                ProgressView().controlSize(.small)
                Text("Saving…").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
            Button(occupant == nil ? "Save" : "Replace", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || device.status != .connected)
        }
    }

    private func bankTitle(_ index: Int) -> String {
        let count = entries(inBank: index).count
        return "Bank \(index + 1) — " + (count == 0 ? "empty" : "\(count) of \(Self.locations) used")
    }

    private func locationTitle(_ index: Int) -> String {
        let name = entries(inBank: bank).first { $0.patch == index }?.name
        return "\(index + 1) — \(name ?? "empty")"
    }

    /// Domyślne miejsce nigdy nie nadpisuje cudzego patcha: ostatnio użyty bank, a za
    /// pierwszym razem pierwszy bank z wolnym miejscem — i w nim pierwsze wolne miejsce.
    private func pickDefaultPlace(preferred: Int? = nil) {
        let remembered = preferred ?? (kind == .patch ? lastPatchBank : lastPerformanceBank)
        if (0 ..< bankCount).contains(remembered) {
            bank = remembered
        } else {
            bank = (0 ..< bankCount).first { entries(inBank: $0).count < Self.locations } ?? 0
        }
        location = firstFreeLocation(inBank: bank)
    }

    private func firstFreeLocation(inBank bank: Int) -> Int {
        let used = Set(entries(inBank: bank).map(\.patch))
        return (0 ..< Self.locations).first { !used.contains($0) } ?? 0
    }

    private func save() {
        failure = nil
        isSaving = true
        Task {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            let error = await device.saveInSynth(state, kind: kind, bank: bank, location: location,
                                                 name: trimmed.isEmpty ? nil : trimmed)
            isSaving = false
            if let error { failure = error } else {
                if kind == .patch { lastPatchBank = bank } else { lastPerformanceBank = bank }
                isPresented = false
            }
        }
    }
}
