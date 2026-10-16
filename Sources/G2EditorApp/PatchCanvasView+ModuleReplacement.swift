import G2Core
import SwiftUI

extension PatchCanvasView {
    @ViewBuilder
    func moduleReplacementPickerView(_ picker: ModuleReplacementPickerState) -> some View {
        let candidates = ModuleReplacementDatabase.candidates(for: picker.sourceTypeID)
        let screenRect = CGRect(
            x: picker.canvasRect.minX * zoom,
            y: picker.canvasRect.minY * zoom,
            width: picker.canvasRect.width * zoom,
            height: picker.canvasRect.height * zoom
        )
        let menuWidth: CGFloat = 176
        let rowHeight: CGFloat = 25
        let requestedHeight = CGFloat(candidates.count) * rowHeight + 8
        let menuHeight = min(requestedHeight, max(36, canvasSize.height - 8))
        let rightEdge = max(4, canvasSize.width - menuWidth - 4)
        let bottomEdge = max(4, canvasSize.height - menuHeight - 4)
        let x = min(max(4, screenRect.minX), rightEdge)
        let y = min(max(4, screenRect.maxY + 2), bottomEdge)

        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(candidates, id: \.self) { typeID in
                    if let definition = ModuleDatabase.module(id: typeID) {
                        let isCurrent = typeID == picker.sourceTypeID
                        let isHovered = moduleReplacementHoveredTypeID == typeID
                        Button {
                            if !isCurrent {
                                onReplaceModule?(picker.moduleID, typeID)
                            }
                            moduleReplacementPicker = nil
                        } label: {
                            HStack(spacing: 7) {
                                replacementMenuIcon(color: pageColor(definition.page))
                                Text(definition.longName)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if isCurrent {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                }
                            }
                            .foregroundStyle(isCurrent || isHovered ? Color.white : UIColor.lcdText)
                            .padding(.horizontal, 8)
                            .frame(width: menuWidth - 8, height: rowHeight)
                            .background(
                                isCurrent
                                    ? UIColor.buttonBlue.opacity(0.90)
                                    : isHovered
                                    ? UIColor.powerButtonOn.opacity(0.78)
                                    : UIColor.lcdBackground
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            moduleReplacementHoveredTypeID = hovering ? typeID : nil
                        }
                        .help("Replace with \(definition.longName)")
                    }
                }
            }
        }
        .padding(4)
        .frame(width: menuWidth, height: menuHeight, alignment: .top)
        .background(UIColor.lcdBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.black.opacity(0.65), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        .position(x: x + menuWidth / 2, y: y + menuHeight / 2)
        .onKeyPress(.escape) {
            moduleReplacementPicker = nil
            return .handled
        }
    }

    private func replacementMenuIcon(color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1.5)
                .stroke(color, lineWidth: 1)
            Path { path in
                path.move(to: CGPoint(x: 2.5, y: 3.5))
                path.addLine(to: CGPoint(x: 9.5, y: 3.5))
                path.addLine(to: CGPoint(x: 6, y: 9))
                path.closeSubpath()
            }
            .fill(color)
        }
        .frame(width: 12, height: 12)
    }
}
