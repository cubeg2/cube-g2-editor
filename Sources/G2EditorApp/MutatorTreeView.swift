// MutatorTreeView.swift
// Drzewo ewolucji Mutatora — rodowód grającego dźwięku (krok 4.10).
//
// Nie rysujemy całego lasu: widać JEDNĄ drogę od patcha do dźwięku, który gra, a w każdym
// pokoleniu całą miotkę (rodzeństwo). Kliknięcie w rodzeństwo przełącza drogę na jego gałąź.
// Rzędy siedzą w `LazyVStack`, więc z tysięcy węzłów rysuje się kilkadziesiąt kratek —
// to jest „wirtualizacja" z Docs/mutator/plan-ui §14. Ten sam widok stoi w zakładce Session
// panelu (małe kratki) i w osobnym oknie „Evolution Tree" (większe).

import AppKit
import G2Core
import G2EditorCore
import SwiftUI

struct MutatorTreeView: View {
    let state: PatchState
    @Bindable var panels: PanelController
    /// Najmniejszy bok kratki: 23 pt w panelu, 36 pt w oknie. Kratka rośnie ponad niego,
    /// aż miotka (sześcioro dzieci) wypełni szerokość — patrz `tileSize(width:)`.
    let tile: CGFloat
    /// Przycisk „Window" ma sens tylko w panelu — okno nie otwiera samego siebie.
    let showsWindowButton: Bool

    /// Kratka drzewa chwycona myszą. Wspólne miejsce, bo kratki okna Mutatora (`MutatorPanel.drop`)
    /// przyjmują ją także z osobnego okna drzewa.
    @MainActor static var dragging: G2MutatorTree.NodeID?

    /// Droga korzeń → … → koniec gałęzi, której miotki są na ekranie.
    @State private var chain: [G2MutatorTree.NodeID] = []
    @Environment(\.mutatorSnapshot) private var snapshot

    private static let gap: CGFloat = 3
    private static let labelWidth: CGFloat = 46
    private static let trailing: CGFloat = 2
    /// Kratka nie rośnie bez końca — w szerokim oknie drzewa zostałyby same cztery w rzędzie.
    private static let maxGrowth: CGFloat = 2.5
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        let tree = state.mutatorTree
        let playing = state.mutatorTreePlaying
        let badges = badges(tree: tree)
        // Zanim `onAppear` ustawi drogę (i w renderze do pliku, gdzie nie ustawi nigdy),
        // droga wynika z tego, co gra.
        let shown = chain.isEmpty ? defaultChain(tree: tree, playing: playing) : chain
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                header(tree: tree, playing: playing, proxy: proxy)
                GeometryReader { geometry in
                    let size = tileSize(width: geometry.size.width)
                    let columns = max(1, Int((geometry.size.width - Self.labelWidth - Self.gap - Self.trailing
                            + Self.gap) / (size + Self.gap)))
                    let list = LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(rows(tree: tree, chain: shown)) { row in
                            rowView(row, tree: tree, chain: shown, playing: playing, badges: badges,
                                    columns: columns, size: size)
                                .id(row.id)
                        }
                    }
                    .padding(.trailing, Self.trailing)
                    Group {
                        if snapshot {
                            list.frame(maxHeight: .infinity, alignment: .top).clipped()
                        } else {
                            ScrollView(.vertical) { list }
                        }
                    }
                    .onChange(of: playing) { _, now in
                        refreshChain(playing: now, grew: false)
                        scroll(to: now, proxy: proxy)
                    }
                    .onChange(of: tree.count) { before, after in
                        if after < before { chain = [] }
                        refreshChain(playing: state.mutatorTreePlaying, grew: after > before)
                        scroll(to: state.mutatorTreePlaying, proxy: proxy)
                    }
                    .onAppear {
                        refreshChain(playing: playing, grew: false)
                        scroll(to: playing, proxy: proxy)
                    }
                }
            }
            note(tree: tree)
        }
    }

    // MARK: - Nagłówek i nota

    private func header(tree: G2MutatorTree, playing: G2MutatorTree.NodeID?,
                        proxy: ScrollViewProxy) -> some View
    {
        HStack(spacing: Self.gap) {
            Text("Tree")
                .font(.system(size: MutatorMetrics.groupFont, weight: .semibold))
                .fontWidth(.condensed)
                .foregroundStyle(UIColor.panelText)
                .help("Every sound bred in this session, with its parents — nothing is lost")
            Spacer(minLength: 0)
            headerButton("Root", width: 36, enabled: !tree.isEmpty, help: "Hear the sound this branch started from") {
                if let root = chain.first ?? tree.roots.first { state.mutatorPlay(node: root) }
            }
            headerButton("Now", width: 36, enabled: playing != nil, help: "Scroll to the sound that is playing") {
                scroll(to: playing, proxy: proxy)
            }
            if showsWindowButton {
                headerButton("Window", width: 50, active: panels.isOpen(.mutatorTree),
                             help: "Show the tree in its own, larger window")
                {
                    panels.toggle(.mutatorTree)
                }
            }
        }
        .frame(height: MutatorMetrics.buttonHeight)
    }

    private func headerButton(_ title: String, width: CGFloat, active: Bool = false, enabled: Bool = true,
                              help: String, action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            Text(title).lineLimit(1).minimumScaleFactor(0.72)
        }
        .buttonStyle(PanelButtonStyle(width: width, height: MutatorMetrics.buttonHeight, active: active))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(help)
    }

    private func note(tree: G2MutatorTree) -> some View {
        let text = tree.isEmpty
            ? "Nothing bred yet — press Mutate."
            : "\(tree.count) sounds in \(tree.generations) generations. Click to hear, double-click to breed, "
            + "drag into a box, ⌥ + arrows to walk."
        return Text(text)
            .font(.system(size: MutatorMetrics.labelFont))
            .fontWidth(.condensed)
            .foregroundStyle(UIColor.panelText)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Rzędy

    /// Jeden rząd: korzenie albo jedna miotka.
    private struct Row: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let help: String
        let members: [G2MutatorTree.NodeID]
    }

    private func rows(tree: G2MutatorTree, chain: [G2MutatorTree.NodeID]) -> [Row] {
        guard !tree.isEmpty else { return [] }
        var rows = [Row(id: "roots", title: G2MutatorTree.Origin.patch.rawValue,
                        subtitle: tree.roots.count == 1 ? "G0" : "G0 · \(tree.roots.count)",
                        help: "Sounds taken from the patch — where the breeding started", members: tree.roots)]
        for node in chain where tree.contains(node) {
            for batch in tree.batches(of: node) {
                let generation = tree[batch.members[0]].generation
                var help = "\(batch.origin.title) at \(Self.time.string(from: batch.createdAt))"
                if let other = batch.otherParent {
                    help += " — the second parent was a generation-\(tree[other].generation) sound"
                }
                rows.append(Row(id: "b\(batch.breed)", title: batch.origin.rawValue,
                                subtitle: "G\(generation) \(Self.time.string(from: batch.createdAt))",
                                help: help, members: batch.members))
            }
        }
        return rows
    }

    private func rowView(_ row: Row, tree: G2MutatorTree, chain: [G2MutatorTree.NodeID],
                         playing: G2MutatorTree.NodeID?, badges: [G2MutatorTree.NodeID: String],
                         columns: Int, size: CGFloat) -> some View
    {
        HStack(alignment: .top, spacing: Self.gap) {
            VStack(alignment: .leading, spacing: 1) {
                label(row.title, weight: .semibold)
                label(row.subtitle, weight: .regular)
            }
            .frame(width: Self.labelWidth, alignment: .leading)
            .help(row.help)
            VStack(alignment: .leading, spacing: Self.gap) {
                ForEach(Array(stride(from: 0, to: row.members.count, by: columns)), id: \.self) { start in
                    HStack(spacing: Self.gap) {
                        ForEach(row.members[start ..< min(row.members.count, start + columns)], id: \.raw) { id in
                            tileView(id, tree: tree, onPath: chain.contains(id), playing: playing == id,
                                     badge: badges[id], size: size)
                        }
                    }
                }
            }
        }
    }

    private func label(_ text: String, weight: Font.Weight) -> some View {
        Text(text)
            .font(.system(size: MutatorMetrics.labelFont, weight: weight))
            .fontWidth(.condensed)
            .foregroundStyle(UIColor.panelText)
            .lineLimit(1)
    }

    // MARK: - Kratka

    /// Bok kratki dobrany tak, żeby miotka wypełniła rząd do prawej krawędzi — przy stałych
    /// 23 pt w panelu zostawał z prawej pusty pas (zgłoszenie użytkownika 2026-09-24).
    private func tileSize(width: CGFloat) -> CGFloat {
        let count = CGFloat(G2Mutator.childCount)
        let available = width - Self.labelWidth - Self.gap - Self.trailing
        let fitted = ((available - Self.gap * (count - 1)) / count).rounded(.down)
        return max(tile, min(fitted, tile * Self.maxGrowth))
    }

    private func tileView(_ id: G2MutatorTree.NodeID, tree: G2MutatorTree, onPath: Bool, playing: Bool,
                          badge: String?, size: CGFloat) -> some View
    {
        let shape = RoundedRectangle(cornerRadius: MutatorMetrics.tileCornerRadius)
        let hasBranch = !onPath && !tree[id].children.isEmpty
        return MutatorBoxView(points: tree.chromosome(of: id, genome: state.mutatorGenome), palette: .module,
                              focused: onPath, size: size)
            .overlay {
                if playing { shape.stroke(UIColor.graphLine, lineWidth: 2) }
            }
            .overlay(alignment: .topLeading) {
                if let badge {
                    Text(badge)
                        .font(.system(size: MutatorMetrics.labelFont * 0.8, weight: .bold))
                        .foregroundStyle(UIColor.graphLine)
                        .padding(.horizontal, 2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if hasBranch {
                    Circle().fill(UIColor.graphLine).frame(width: 4, height: 4).padding(3)
                }
            }
            .onTapGesture(count: 2) { state.mutatorMutate(from: id) }
            .onTapGesture { state.mutatorPlay(node: id) }
            .onDrag {
                Self.dragging = id
                return NSItemProvider(object: "node:\(id.raw)" as NSString)
            }
            .contextMenu {
                Button("Copy to Mother") { state.mutatorCopy(node: id, to: .mother) }
                Button("Copy to Father") { state.mutatorCopy(node: id, to: .father) }
                Button("Save to Temporary Storage") { state.mutatorStore(node: id) }
                Button("Breed from here") { state.mutatorMutate(from: id) }
            }
            .help(help(for: id, tree: tree, badge: badge))
    }

    private func help(for id: G2MutatorTree.NodeID, tree: G2MutatorTree, badge: String?) -> String {
        let node = tree[id]
        var parts = ["Generation \(node.generation)"]
        switch node.origin {
        case .patch: parts.append("taken from the patch")
        case .family: parts.append("Make family, box \(node.ordinal + 1)")
        case .amount: parts.append("Amount axis")
        default: parts.append("\(node.origin.title), child \(node.ordinal + 1)")
        }
        parts.append(Self.time.string(from: node.createdAt))
        if let badge { parts.append("in \(Self.badgeName(badge))") }
        let descendants = tree.descendantCount(of: id)
        if descendants > 0 { parts.append(descendants == 1 ? "1 descendant" : "\(descendants) descendants") }
        return parts.joined(separator: " · ")
    }

    private static func badgeName(_ badge: String) -> String {
        switch badge {
        case "M": "Mother"
        case "F": "Father"
        case "S": "Temporary Storage"
        default: "Child \(badge)"
        }
    }

    /// Znaczek kratki okna, w której dźwięk siedzi teraz — liczony raz na rysowanie,
    /// bo szukanie po treści kosztuje.
    private func badges(tree: G2MutatorTree) -> [G2MutatorTree.NodeID: String] {
        var badges: [G2MutatorTree.NodeID: String] = [:]
        for (index, sound) in state.mutatorParents.enumerated() {
            guard let sound, let id = tree.node(of: sound) else { continue }
            switch index {
            case G2Mutator.motherIndex: badges[id] = "M"
            case G2Mutator.fatherIndex: badges[id] = badges[id] ?? "F"
            default: badges[id] = badges[id] ?? "\(index + 1)"
            }
        }
        for sound in state.mutatorStorage {
            guard let sound, let id = tree.node(of: sound), badges[id] == nil else { continue }
            badges[id] = "S"
        }
        return badges
    }

    // MARK: - Droga

    /// Droga zostaje, gdy gra coś, co już na niej jest (klik w przodka nie chowa rzędów
    /// poniżej). Spoza drogi: przodkowie grającego i w dół po najnowszych potomkach.
    /// Po hodowli droga kończy się na nowej miotce.
    private func refreshChain(playing: G2MutatorTree.NodeID?, grew: Bool) {
        let tree = state.mutatorTree
        if chain.contains(where: { !tree.contains($0) }) { chain = [] }
        guard let playing else {
            if chain.isEmpty { chain = defaultChain(tree: tree, playing: nil) }
            return
        }
        if grew {
            chain = tree.ancestors(of: playing)
        } else if !chain.contains(playing) {
            chain = descend(from: playing, tree: tree)
        }
    }

    /// Droga bez pamięci: od grającego (albo ostatniego korzenia) w dół po najnowszych potomkach.
    private func defaultChain(tree: G2MutatorTree, playing: G2MutatorTree.NodeID?) -> [G2MutatorTree.NodeID] {
        guard let start = playing ?? tree.roots.last, tree.contains(start) else { return [] }
        return descend(from: start, tree: tree)
    }

    private func descend(from node: G2MutatorTree.NodeID, tree: G2MutatorTree) -> [G2MutatorTree.NodeID] {
        var path = tree.ancestors(of: node)
        var tail = node
        while let next = tree.latestChild(of: tail) {
            path.append(next)
            tail = next
        }
        return path
    }

    private func scroll(to playing: G2MutatorTree.NodeID?, proxy: ScrollViewProxy) {
        let tree = state.mutatorTree
        guard let playing, tree.contains(playing) else { return }
        let node = tree[playing]
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(node.parents.isEmpty ? "roots" : "b\(node.breed)", anchor: .center)
        }
    }
}
