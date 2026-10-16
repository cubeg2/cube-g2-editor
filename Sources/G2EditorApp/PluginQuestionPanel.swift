// PluginQuestionPanel.swift
// Pytanie wtyczki DAW (Etap 3), gdy jej okno jest zamknięte: patch zapisany w piosence różni
// się od tego, co gra G2. Wtyczka nie ma jak pokazać komunikatu bez swojego okna, więc pyta
// przez edytor — mały panel nad DAW-em, który nie zabiera mu klawiatury i pokazuje się także
// wtedy, gdy edytor działa w tle bez okna (życzenie użytkownika 2026-09-25).
// Plan: Docs/Plan projektu/05-wtyczka-funkcje.md §2.6.

import AppKit
import G2EditorCore
import SwiftUI

@MainActor
enum PluginQuestionPanel {
    private static var panel: NSPanel?
    private static let closer = Closer()
    /// Pytania, przy których użytkownik zamknął panel bez odpowiedzi — wraca dopiero przy innych.
    private static var dismissed: [PluginBridge.ConnectionID: [PluginBridge.Question]] = [:]

    static func watch(_ bridge: PluginBridge) {
        let asking = withObservationTracking {
            bridge.clients.compactMapValues { $0.questions.isEmpty ? nil : $0.questions }
        } onChange: {
            Task { @MainActor in watch(bridge) }
        }
        dismissed = dismissed.filter { asking[$0.key] == $0.value }
        guard asking.contains(where: { dismissed[$0.key] != $0.value }) else {
            panel?.orderOut(nil)
            return
        }
        show(bridge)
    }

    private static func show(_ bridge: PluginBridge) {
        let panel = panel ?? makePanel(bridge)
        self.panel = panel
        guard !panel.isVisible else { return }
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.maxY - 80))
        }
        panel.orderFrontRegardless()
    }

    private static func makePanel(_ bridge: PluginBridge) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 150),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "G2 VST"
        panel.level = .floating
        // Panel ma wisieć nad DAW-em, czyli właśnie wtedy, gdy edytor nie jest aktywny.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let controller = NSHostingController(rootView: PluginQuestionView(bridge: bridge))
        controller.sizingOptions = .preferredContentSize
        panel.contentViewController = controller
        closer.bridge = bridge
        panel.delegate = closer
        return panel
    }

    /// Zamknięcie krzyżykiem: pytanie zostaje we wtyczce, panel milknie do następnego.
    private final class Closer: NSObject, NSWindowDelegate {
        weak var bridge: PluginBridge?

        func windowWillClose(_: Notification) {
            MainActor.assumeIsolated {
                guard let bridge else { return }
                dismissed = bridge.clients.compactMapValues { $0.questions.isEmpty ? nil : $0.questions }
            }
        }
    }
}

private struct PluginQuestionView: View {
    let bridge: PluginBridge

    private static let letters = ["A", "B", "C", "D"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The song's patch differs from what the G2 plays. Nothing goes to the G2 until you choose.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(asking, id: \.key) { id, client in
                VStack(alignment: .leading, spacing: 6) {
                    Text(PluginBridge.title(of: client)).font(.headline)
                    ForEach(client.questions, id: \.slot) { question in
                        Text("Slot \(Self.letters[question.slot]): the song has “\(Self.shown(question.song))”, "
                            + "the G2 has “\(Self.shown(question.g2))”.")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    let many = client.questions.count > 1
                    HStack {
                        Button(many ? "Send the song's patches to G2" : "Send the song's patch to G2") {
                            bridge.answer(id, sendSongPatch: true)
                        }
                        Button(many ? "Keep the G2's patches" : "Keep the G2's patch") {
                            bridge.answer(id, sendSongPatch: false)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 480, alignment: .leading)
    }

    private var asking: [(key: PluginBridge.ConnectionID, value: PluginBridge.Client)] {
        bridge.clients.filter { !$0.value.questions.isEmpty }.sorted { $0.key < $1.key }
    }

    private static func shown(_ name: String) -> String {
        name.isEmpty ? "Untitled" : name
    }
}
