// packaging_art.swift — obrazki do paczki, rysowane AppKitem (bez dodatkowych programów).
// Wywołuje je Tools/build_app.sh:
//   swift Tools/packaging_art.swift icon <AppIcon.svg> <katalog.iconset>
//   swift Tools/packaging_art.swift background <katalog>   → background.png + background@2x.png
//
// Tło okna DMG niesie instrukcję pierwszego uruchomienia — aplikacja bez podpisu Apple
// nie może jej pokazać sama, bo macOS nie wpuści jej za pierwszym razem. Tekst
// zaakceptowany przez użytkownika 2026-10-16 (bez wzmianki o pieniądzach).

import AppKit

/// Rozmiar okna DMG w punktach; pozycje ikon ustawia build_app.sh (te same liczby).
let windowSize = NSSize(width: 640, height: 460)

func writePNG(_ size: NSSize, scale: CGFloat, to path: String, draw: () -> Void) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                     pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("bitmap") }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    try? data.write(to: URL(fileURLWithPath: path))
}

func icon(svg: String, iconset: String) {
    guard let image = NSImage(contentsOfFile: svg) else { fatalError("Brak \(svg)") }
    try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
    for side in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(side)x\(side).png" : "icon_\(side)x\(side)@2x.png"
            let size = NSSize(width: side, height: side)
            writePNG(size, scale: CGFloat(scale), to: iconset + "/" + name) {
                image.draw(in: NSRect(origin: .zero, size: size))
            }
        }
    }
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular,
          color: NSColor = NSColor(white: 0.15, alpha: 1)) -> NSAttributedString
{
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 2
    return NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ])
}

func background(directory: String) {
    let steps = [
        "Drag Cube G2 Editor to Applications and open it.",
        "macOS says it can't check the app for malware. Click Done.",
        "Open System Settings ▸ Privacy & Security, scroll down and click Open Anyway.",
    ]
    let draw = {
        NSColor(white: 0.965, alpha: 1).setFill()
        NSRect(origin: .zero, size: windowSize).fill()

        // Strzałka od aplikacji do Applications (ikony stoją na y = 130 od góry).
        let arrowY = windowSize.height - 130
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 255, y: arrowY))
        arrow.line(to: NSPoint(x: 380, y: arrowY))
        arrow.move(to: NSPoint(x: 366, y: arrowY + 10))
        arrow.line(to: NSPoint(x: 382, y: arrowY))
        arrow.line(to: NSPoint(x: 366, y: arrowY - 10))
        arrow.lineWidth = 4
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        NSColor(white: 0.55, alpha: 1).setStroke()
        arrow.stroke()

        // Instrukcja pod ikonami (podpisy ikon kończą się ok. 215 pt od góry).
        let left: CGFloat = 60
        var top: CGFloat = 248
        func put(_ string: NSAttributedString, indent: CGFloat = 0, width: CGFloat = 520) {
            let rect = string.boundingRect(with: NSSize(width: width - indent, height: 200),
                                           options: [.usesLineFragmentOrigin])
            string.draw(with: NSRect(x: left + indent, y: windowSize.height - top - rect.height,
                                     width: width - indent, height: rect.height),
                        options: [.usesLineFragmentOrigin])
            top += ceil(rect.height)
        }
        put(text("First launch", size: 15, weight: .semibold))
        top += 8
        for (index, step) in steps.enumerated() {
            let lineTop = top // numer i zdanie w jednym wierszu
            put(text("\(index + 1).", size: 13, weight: .medium, color: NSColor(white: 0.45, alpha: 1)))
            top = lineTop
            put(text(step, size: 13), indent: 20)
            top += 5
        }
        top += 4
        put(text("You only need to do this once for every new version.", size: 13))
        top += 16
        put(text("Why? Cube G2 Editor is an independent app that isn't registered with Apple, so macOS "
                + "can't verify it automatically. This is common for free, independent software.",
            size: 10.5, color: NSColor(white: 0.45, alpha: 1)))
    }
    writePNG(windowSize, scale: 1, to: directory + "/background.png", draw: draw)
    writePNG(windowSize, scale: 2, to: directory + "/background@2x.png", draw: draw)
}

let args = CommandLine.arguments
switch args.dropFirst().first {
case "icon" where args.count == 4: icon(svg: args[2], iconset: args[3])
case "background" where args.count == 3: background(directory: args[2])
default:
    print("Użycie: packaging_art.swift icon <svg> <iconset> | background <katalog>")
    exit(2)
}
