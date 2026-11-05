// BankDownloadSheet.swift
// Okno „Synth ▸ Upload Banks to G2…” — folder z dysku do jednego banku Norda. U Clavii to
// „Bank Download (To Modular)” (instrukcja v1.4 s. 124); nazwy odwrócone jak przy
// Download Banks from G2 (decyzja użytkownika 2026-10-13). Folder z listą `.pchList`
// (kopia z Norda) wraca na te same miejsca, folder bez listy idzie po kolei od miejsca 1.
// Pętlę robi `DeviceConnection.downloadBank` → [[Docs/usb/bank-dump]].

import AppKit
import G2Core
import G2EditorCore
import SwiftUI

struct BankDownloadSheet: View {
    @Binding var isPresented: Bool
    let device: DeviceConnection

    @State private var kind: G2BankEntry.Kind = .patch
    /// Bank od 0, jak w `G2BankEntry`.
    @State private var bank = 0
    @AppStorage("g2_bank_download_folder") private var folderPath = ""
    @State private var plan: G2BankDump.UploadPlan?
    @State private var planError: String?
    @State private var task: Task<Void, Never>?
    @State private var result: DeviceConnection.BankUploadResult?

    private var folder: URL? {
        folderPath.isEmpty ? nil : URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    private var isRunning: Bool {
        task != nil
    }

    private var noun: String {
        kind == .patch ? "patches" : "performances"
    }

    private func used(inBank bank: Int) -> Int {
        device.bankEntries.filter { $0.kind == kind && $0.bank == bank }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Upload Banks to G2").font(.title2.bold()).padding()
            Divider()
            Group {
                if let progress = device.bankUpload, isRunning {
                    progressView(progress)
                } else if let result {
                    summary(result)
                } else {
                    settings
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            buttons.padding()
        }
        .frame(width: 480, height: 420)
        .interactiveDismissDisabled(isRunning)
        .onAppear { readFolder(pickKind: true) }
    }

    // MARK: - Ustawienia

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Writes a folder of files into one bank in the G2 memory. A folder with a bank list "
                + "(.pchList), such as one saved by Download Banks from G2, goes back to the same "
                + "locations; other folders fill the bank from location 1 in alphabetical order.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Folder")
                Text(folder?.path ?? "Not chosen")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(folder == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…", action: chooseFolder)
            }

            Picker("", selection: $kind) {
                Text("Patch Bank").tag(G2BankEntry.Kind.patch)
                Text("Performance Bank").tag(G2BankEntry.Kind.performance)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: kind) { _, _ in readFolder(pickKind: false) }

            Picker("Bank", selection: $bank) {
                ForEach(0 ..< G2BankGroup.bankCount(kind), id: \.self) { index in
                    let count = used(inBank: index)
                    Text("Bank \(index + 1) — " + (count == 0 ? "empty" : "\(count) \(noun)")).tag(index)
                }
            }

            planText

            if device.synthSettings?.memoryProtect == true {
                Label("Memory Protect is on in the G2, so it will refuse to save. "
                    + "Switch it off in Synth Settings first.", systemImage: "lock")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if used(inBank: bank) > 0 {
                Label("All \(used(inBank: bank)) \(noun) now in Bank \(bank + 1) will be erased.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Slot D (for performances all four slots) changes while the files are written, "
                + "and is put back when the upload ends.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var planText: some View {
        if let planError {
            Text(planError).foregroundStyle(.red)
        } else if let plan {
            VStack(alignment: .leading, spacing: 4) {
                if let first = plan.items.first, let last = plan.items.last {
                    let single = kind == .patch ? "patch" : "performance"
                    Text("\(plan.items.count) \(plan.items.count == 1 ? single : noun) "
                        + (plan.fromList ? "to the locations in the bank list"
                            : "to locations \(first.location + 1)–\(last.location + 1)") + ".")
                } else {
                    Text("This folder has no \(kind == .patch ? ".pch2" : ".prf2") files.")
                        .foregroundStyle(.secondary)
                }
                if plan.otherKindCount > 0 {
                    let other = kind == .patch ? "performances" : "patches"
                    Text("\(plan.otherKindCount) \(other) in this folder are not included — "
                        + "upload them to a \(kind == .patch ? "performance" : "patch") bank.")
                        .foregroundStyle(.secondary)
                }
                if !plan.leftOut.isEmpty {
                    Text("\(plan.leftOut.count) files are left out: "
                        + (plan.fromList ? "the bank list does not place them." : "a bank holds 128."))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder with the files for one bank"
        if let folder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderPath = url.path
        readFolder(pickKind: true)
    }

    /// Plan na nowo po zmianie folderu albo rodzaju. Przy nowym folderze rodzaj idzie za
    /// zawartością (same `.prf2` → bank performance'ów), a bank — pierwszy pusty, żeby
    /// okno nigdy samo nie podsuwało kasowania.
    private func readFolder(pickKind: Bool) {
        plan = nil
        planError = nil
        guard let folder else { return }
        do {
            var read = try G2BankDump.uploadPlan(folder: folder, kind: kind)
            if pickKind, read.items.isEmpty, read.otherKindCount > 0 {
                kind = kind == .patch ? .performance : .patch
                read = try G2BankDump.uploadPlan(folder: folder, kind: kind)
            }
            plan = read
        } catch {
            planError = "The folder could not be read (\(error.localizedDescription))."
        }
        bank = (0 ..< G2BankGroup.bankCount(kind)).first { used(inBank: $0) == 0 } ?? 0
    }

    // MARK: - Postęp i wynik

    private func progressView(_ progress: DeviceConnection.BankUploadProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(progress.bankTitle).font(.headline)
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            HStack {
                Text(progress.current).lineLimit(1)
                Spacer()
                Text("\(progress.done) of \(progress.total)").monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if task?.isCancelled == true {
                Text("Stopping — the G2 is being put back as it was…")
                    .font(.callout)
            }
        }
    }

    private func summary(_ result: DeviceConnection.BankUploadResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(result.cancelled ? "Upload stopped" : "Upload finished").font(.headline)
            Text("\(result.saved) written to Bank \(bank + 1)"
                + (result.failures.isEmpty ? "." : ", \(result.failures.count) failed."))
            if let problem = result.restoreProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !result.failures.isEmpty {
                ScrollView {
                    Text(result.failures.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Przyciski

    private var buttons: some View {
        HStack {
            Spacer()
            if isRunning {
                // Stop na miejscu Cancel, Upload wygaszony na swoim — jak w Download Banks.
                Button("Stop") { task?.cancel() }
                    .disabled(task?.isCancelled == true)
                Button("Upload") {}
                    .disabled(true)
            } else if result != nil {
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(used(inBank: bank) > 0 ? "Erase and Upload" : "Upload", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan?.items.isEmpty != false || device.status != .connected || device.isBusy)
            }
        }
    }

    private func start() {
        guard let plan else { return }
        let kind = kind
        let bank = bank
        task = Task {
            result = await device.downloadBank(plan, kind: kind, bank: bank)
            task = nil
        }
    }
}
