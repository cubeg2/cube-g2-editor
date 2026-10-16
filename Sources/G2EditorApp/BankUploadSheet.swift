// BankUploadSheet.swift
// Okno „Synth ▸ Download Banks from G2…” — banki z Norda na dysk. U Clavii to
// „Bank Upload (From Modular)” (instrukcja v1.4 s. 123); nazwę odwrócił użytkownik
// 2026-10-13, bo „upload” na komputer myli: jeden bank albo wszystkie naraz, każdy bank do własnego
// folderu z listą `.pchList`. Pętlę robi `DeviceConnection.uploadBanks` → [[Docs/usb/bank-dump]].

import AppKit
import G2Core
import G2EditorCore
import SwiftUI

struct BankUploadSheet: View {
    @Binding var isPresented: Bool
    let device: DeviceConnection

    private enum Scope: String, CaseIterable {
        case single = "Single Bank"
        case all = "All Banks"
    }

    @State private var scope: Scope = .single
    /// Wybrany bank jako `G2BankGroup.id` („0-2” = Patch Bank 3).
    @State private var selectedBank = ""
    /// Folder przeżywa ponowne uruchomienie — kopie robi się zwykle w to samo miejsce.
    @AppStorage("g2_bank_upload_folder") private var folderPath = ""
    @State private var task: Task<Void, Never>?
    @State private var result: DeviceConnection.BankUploadResult?

    private var banks: [G2BankGroup] {
        G2BankGroup.grouped(device.bankEntries)
    }

    private var chosen: [G2BankGroup] {
        scope == .all ? banks : banks.filter { $0.id == selectedBank }
    }

    private var folder: URL? {
        folderPath.isEmpty ? nil : URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    private var isRunning: Bool {
        task != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Download Banks from G2").font(.title2.bold()).padding()
            Divider()
            Group {
                if let progress = device.bankUpload {
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
        .frame(width: 480, height: 360)
        .interactiveDismissDisabled(isRunning)
        .onAppear { if selectedBank.isEmpty { selectedBank = banks.first?.id ?? "" } }
    }

    // MARK: - Ustawienia

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Saves banks from the G2 memory to disk: one file per patch or performance, "
                + "plus a bank list (.pchList) that remembers where each one was. "
                + "Every bank goes into its own folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $scope) {
                ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if scope == .single {
                Picker("Bank", selection: $selectedBank) {
                    ForEach(banks) { group in
                        Text("\(group.title) — \(count(group))").tag(group.id)
                    }
                }
            } else {
                Text(allBanksText)
                    .font(.callout)
            }

            HStack {
                Text("Folder")
                Text(folder?.path ?? "Not chosen")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(folder == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…", action: chooseFolder)
            }

            Text("Slot D (and for performances all four slots) changes while the banks are read, "
                + "and is put back when the download ends. Nothing in the G2 memory is changed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func count(_ group: G2BankGroup) -> String {
        let noun = group.kind == .patch ? "patch" : "performance"
        return "\(group.entries.count) \(noun)\(group.entries.count == 1 ? "" : (group.kind == .patch ? "es" : "s"))"
    }

    private var allBanksText: String {
        let patches = banks.filter { $0.kind == .patch }
        let performances = banks.filter { $0.kind == .performance }
        let patchCount = patches.reduce(0) { $0 + $1.entries.count }
        let performanceCount = performances.reduce(0) { $0 + $1.entries.count }
        return "\(patches.count) patch banks (\(patchCount) patches) and \(performances.count) "
            + "performance banks (\(performanceCount) performances). Empty banks are skipped."
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where the bank folders will be saved"
        if let folder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderPath = url.path
    }

    // MARK: - Postęp i wynik

    private func progressView(_ progress: DeviceConnection.BankUploadProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if progress.bankNumber > 0 {
                Text("\(progress.bankTitle) — bank \(progress.bankNumber) of \(progress.bankCount)")
                    .font(.headline)
            }
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
            Text(result.cancelled ? "Download stopped" : "Download finished").font(.headline)
            Text("\(result.saved) saved" + (result.failures.isEmpty ? "." : ", \(result.failures.count) failed."))
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
            if result != nil, let folder {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
            Spacer()
            if isRunning {
                // Stop stoi tam, gdzie był Cancel, a Download zostaje wygaszony na swoim
                // miejscu — inaczej drugi klik dwukliku w Download trafiał w Stop.
                Button("Stop") { task?.cancel() }
                    .disabled(task?.isCancelled == true)
                Button("Download") {}
                    .disabled(true)
            } else if result != nil {
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Download", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(folder == nil || chosen.isEmpty || device.status != .connected || device.isBusy)
            }
        }
    }

    private func start() {
        guard let folder else { return }
        let keys = chosen.map { (kind: $0.kind, bank: $0.bank) }
        task = Task {
            let outcome = await device.uploadBanks(keys, to: folder)
            result = outcome
            task = nil
        }
    }
}
