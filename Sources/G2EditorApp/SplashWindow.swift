import AppKit
import SwiftUI

/// Karta powitalna: logo, zachęta do wsparcia na Ko-fi, atrybucja GPL i nota o znakach
/// towarowych. Sama pokazuje się tylko przy pierwszym uruchomieniu; potem jest pod
/// „About Cube G2 Editor" w menu aplikacji. Zostaje, dopóki użytkownik jej nie zamknie.
/// Edytor w tle (wtyczka DAW) jej nie pokazuje.
@MainActor
enum SplashWindow {
    static let kofiURL = URL(string: "https://ko-fi.com/cubeg2")!
    private static let shownKey = "g2_welcome_card_shown"
    private static var panel: NSPanel?

    /// `true`, gdy karta się pokazała (pierwsze uruchomienie).
    @discardableResult
    static func showOnFirstLaunch() -> Bool {
        guard !UserDefaults.standard.bool(forKey: shownKey) else { return false }
        UserDefaults.standard.set(true, forKey: shownKey)
        show()
        return true
    }

    static func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard let url = Bundle.app.url(forResource: "CubeG2LogoWhite", withExtension: "svg"),
              let logo = NSImage(contentsOf: url) else { return }
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: SplashCard.width, height: 400),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SplashCard(logo: logo) { dismiss() })
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    static func dismiss() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    /// Okno bez ramki domyślnie nie przyjmuje klawiatury — a Return/Esc mają je zamykać.
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}

struct SplashCard: View {
    static let width: CGFloat = 760
    /// Kolor tła karty. Kontury w białym logo mają dokładnie ten kolor — oddzielają litery.
    static let background = Color(red: 0.102, green: 0.102, blue: 0.102)
    let logo: NSImage
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PatchCables(cables: PatchCables.left).frame(width: 150, height: 150)
                VStack(spacing: 14) {
                    Image(nsImage: logo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 380, height: 101)
                    Text("A modern editor for the Nord Modular G2")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize()
                    // Numer wersji — testerzy podają go w zgłoszeniach (prośba użytkownika 2026-10-16).
                    Text(AppUpdates.versionText.map { "Version \($0)" } ?? "Development build")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize()
                }
                .frame(width: 400)
                PatchCables(cables: PatchCables.right).frame(width: 150, height: 150)
            }
            .padding(.top, 40)

            VStack(spacing: 12) {
                Text("Cube G2 Editor is free and open source, and every feature stays free for everyone. If it makes your G2 sessions better, you can buy me a coffee.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: SplashWindow.kofiURL) {
                    Label("Support on Ko-fi", systemImage: "cup.and.saucer.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color(red: 0.16, green: 0.67, blue: 0.94)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 90)
            .padding(.top, 22)

            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(height: 1)
                .padding(.horizontal, 40)
                .padding(.top, 28)

            VStack(spacing: 6) {
                Text("Licensed under GPL-3.0-or-later. Based in part on NMG2Editor by Bruno Verhue, g2ools by Matt Gerassimoff and G2-Edit by Chris Turner, used under the GPL.")
                Text("Nord, Nord Modular and Clavia are trademarks of Clavia DMI AB. Cube G2 Editor is an independent project and is not affiliated with, authorized or endorsed by Clavia DMI AB.")
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.55))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 60)
            .padding(.top, 14)

            Button(action: onClose) {
                Text("Continue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 20)
            .padding(.bottom, 26)
            Button("", action: onClose)
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
        }
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 18).fill(Self.background))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
    }
}

/// Kable patchowe jako ozdoba karty — ten sam układ co na okładce profilu Ko-fi.
private struct PatchCables: View {
    /// (x1, y1, x2, y2, kolor, zwis) w układzie 520 × 480; rysunek skaluje się do ramki.
    typealias Cable = (CGFloat, CGFloat, CGFloat, CGFloat, Color, CGFloat)

    static let left: [Cable] = [
        (60, 70, 380, 150, Color(red: 0.82, green: 0.24, blue: 0.24), 120),
        (150, 40, 470, 300, Color(red: 0.24, green: 0.43, blue: 0.86), 90),
        (40, 250, 300, 90, Color(red: 0.90, green: 0.78, blue: 0.24), 160),
        (230, 190, 480, 70, Color(red: 0.94, green: 0.55, blue: 0.20), 140),
        (90, 400, 420, 330, Color(red: 0.27, green: 0.71, blue: 0.27), 60),
    ]
    static let right: [Cable] = [
        (80, 60, 420, 170, Color(red: 0.63, green: 0.27, blue: 0.78), 110),
        (20, 330, 320, 90, Color(red: 0.24, green: 0.43, blue: 0.86), 150),
        (220, 40, 500, 300, Color(white: 0.91), 90),
        (120, 190, 480, 420, Color(red: 0.24, green: 0.43, blue: 0.86), 70),
        (40, 420, 380, 350, Color(red: 0.94, green: 0.55, blue: 0.20), 60),
    ]

    let cables: [Cable]

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 520, size.height / 480)
            for (x1, y1, x2, y2, color, sag) in cables {
                let start = CGPoint(x: x1 * scale, y: y1 * scale)
                let end = CGPoint(x: x2 * scale, y: y2 * scale)
                let midX = (start.x + end.x) / 2
                let lowY = max(start.y, end.y) + sag * scale
                var path = Path()
                path.move(to: start)
                path.addCurve(to: end,
                              control1: CGPoint(x: start.x + (midX - start.x) * 0.4, y: lowY),
                              control2: CGPoint(x: end.x - (end.x - midX) * 0.4, y: lowY))
                context.stroke(path, with: .color(color.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                for point in [start, end] {
                    let radius: CGFloat = 5.5
                    let jack = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                      width: 2 * radius, height: 2 * radius))
                    context.fill(jack, with: .color(SplashCard.background))
                    context.stroke(jack, with: .color(color), lineWidth: 2.4)
                }
            }
        }
    }
}
