// BlockDropGhost.swift
// Duch Building Blocku nad kanwą: obrysy jego modułów dokładnie tam, gdzie wylądują.
// Odpowiednik ducha modułu z biblioteki (ContentView), tylko że pozycję podaje cel
// upuszczenia na kanwie — wiersz bloku to `.onDrag` SwiftUI, który ruchów myszy nie zgłasza.
// Miernik DSP „po wstawieniu" jedzie w obrazku przeciąganego wiersza (`BlockDragPreview`),
// więc widać go nad listą, a nad kanwą znika razem z obrazkiem — jak w bibliotece modułów
// (decyzja użytkownika 2026-10-23: nad kanwą zasłaniał patch).
// Plan → Docs/Plan projektu/08-building-blocks.md

import G2Core
import G2EditorCore
import SwiftUI

/// Gdzie nad kanwą wisi przeciągany blok: plik i lewy górny róg w siatce.
struct BlockDropHover: Equatable {
    var url: URL
    var column: Int
    var row: Int
}

struct BlockDropGhost: View {
    let block: G2Patch
    let hover: BlockDropHover
    let area: PatchArea
    let rowOffset: Int
    let zoom: CGFloat

    var body: some View {
        let rects = moduleRects
        ZStack(alignment: .topLeading) {
            ForEach(rects.indices, id: \.self) { index in
                moduleGhost(rects[index].name, rect: rects[index].rect)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Moduły bloku z tego obszaru, przesunięte tak jak zrobi to `insertBlock`.
    private var moduleRects: [(name: String, rect: CGRect)] {
        let modules = block.modules(in: area)
        let left = modules.map(\.column).min() ?? 0
        let top = modules.map(\.row).min() ?? 0
        return modules.map { module in
            var placed = module
            placed.column = hover.column + module.column - left
            placed.row = hover.row + module.row - top
            let def = ModuleDatabase.module(id: module.typeID)
            let rect = PatchLayout.moduleRect(placed, def: def, rowOffset: rowOffset)
            let name = module.label.isEmpty ? (def?.shortName ?? "") : module.label
            return (name, CGRect(x: rect.minX * zoom, y: rect.minY * zoom,
                                 width: rect.width * zoom, height: rect.height * zoom))
        }
    }

    private func moduleGhost(_ name: String, rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.55)
            Text(name)
                .font(.system(size: max(min(rect.height * 0.28, 12), 8), weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.leading, 6)
                .padding(.top, 2)
        }
        .frame(width: rect.width, height: rect.height)
        .overlay(Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 1))
        .offset(x: rect.minX, y: rect.minY)
    }
}

/// Obrazek przeciąganego wiersza bloku: nazwa i pasek obciążenia po wstawieniu — ten sam
/// co pod podglądem modułu w palecie. Nad kanwą system go chowa (`DropTargetNSView`).
struct BlockDragPreview: View {
    let name: String
    let load: (voice: G2PatchLoad?, fx: G2PatchLoad?)?

    private static let width: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let load {
                let scale = PatchLoadMetrics.previewScale(fittingWidth: Self.width - 12)
                PatchLoadReadout(voice: load.voice, fx: load.fx, layout: .preview, scale: scale, labelColor: .white)
                    .frame(height: PatchLoadMetrics.previewHeight * scale)
            }
        }
        .padding(6)
        .frame(width: Self.width, alignment: .leading)
        .background(Color.black.opacity(0.80))
    }
}

/// Obciążenie obu obszarów po wstawieniu bloku — dla `BlockDragPreview`. Ustawia je
/// panel Patches (zna patch i Norda), czyta wiersz bloku; `nil` = miernik wyłączony.
private struct BlockLoadPreviewKey: EnvironmentKey {
    static let defaultValue: ((G2Patch) -> (voice: G2PatchLoad?, fx: G2PatchLoad?))? = nil
}

extension EnvironmentValues {
    var blockLoadPreview: ((G2Patch) -> (voice: G2PatchLoad?, fx: G2PatchLoad?))? {
        get { self[BlockLoadPreviewKey.self] }
        set { self[BlockLoadPreviewKey.self] = newValue }
    }
}

extension G2PatchLoad {
    /// Odczyt powiększony o wszystkie moduły bloku z tego obszaru.
    func adding(_ modules: [G2Module]) -> G2PatchLoad {
        modules.reduce(self) { $0.adding(typeID: $1.typeID) }
    }
}
