// MenuDump.swift
// `swift run G2EditorApp --dump-menu` — wypisuje cały pasek menu jako tekst i kończy
// proces. **Jedyny sposób, żeby obejrzeć menu bez zgody na nagrywanie ekranu.**
//
// Przy każdej pozycji widać to, czego na zrzucie ekranu i tak nie da się rozstrzygnąć:
// czy `NSMenuItem` ma OBRAZEK (`image`), czy tylko tytuł. SwiftUI nie obiecuje, że
// ikona `Label` przejdzie do `NSMenuItem.image`, a bez tej informacji „nie widzę
// kwadracików" jest nie do zdiagnozowania.

import AppKit

enum MenuDump {
    /// Zrzut leci po chwili od startu — SwiftUI składa pasek menu dopiero wtedy, gdy
    /// scena już stoi, więc odczyt w `applicationDidFinishLaunching` trafiłby w pustkę.
    static func scheduleDump(after delay: TimeInterval = 1.5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let menu = NSApp.mainMenu else {
                print("BRAK mainMenu")
                exit(1)
            }
            print(describe(menu, depth: 0))
            exit(0)
        }
    }

    static func describe(_ menu: NSMenu, depth: Int) -> String {
        var lines: [String] = []
        let indent = String(repeating: "  ", count: depth)
        for item in menu.items {
            if item.isSeparatorItem {
                lines.append("\(indent)———")
                continue
            }
            var marks: [String] = []
            if let image = item.image {
                marks.append("IMG \(Int(image.size.width))×\(Int(image.size.height))"
                    + (image.isTemplate ? " template" : ""))
            }
            if item.attributedTitle != nil { marks.append("attributed") }
            if item.state == .on { marks.append("✓") }
            if !item.isEnabled { marks.append("disabled") }
            let suffix = marks.isEmpty ? "" : "   [\(marks.joined(separator: ", "))]"
            lines.append("\(indent)\(item.title)\(suffix)")
            if let submenu = item.submenu {
                lines.append(describe(submenu, depth: depth + 1))
            }
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
