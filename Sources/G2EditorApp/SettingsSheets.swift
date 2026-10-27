import AppKit
import G2Core
import G2EditorCore
import SwiftUI

// Zawartość zakładek okna Settings (`SettingsWindow`) i arkusz Notes.
//
// Do 2026-10-15 były to cztery osobne arkusze (Options, Patch, Performance i Synth
// Settings) z długimi listami do przewijania. Teraz jedno okno z zakładkami jak
// w Logic Pro, jednego stałego rozmiaru: szerokie i niskie, bez przewijania.
// Każda grupa ustawień siedzi w ramce (`SettingsCard`), jak karty zakładki Patch —
// użytkownik uznał je za najczytelniejsze (2026-10-15).

// MARK: - Shared chrome

/// Nagłówek z tytułem i przyciskiem Done — został tylko arkuszowi Notes.
private struct SheetChrome<Content: View>: View {
    let title: String
    var minWidth: CGFloat = 460
    let done: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            content
        }
        .frame(minWidth: minWidth, idealWidth: max(minWidth, 520),
               minHeight: 360, idealHeight: 460)
    }
}

/// Wartość w ramce i para strzałek ▲▼ — te same, co przy tempie w belce
/// (`TopBarValueField` + `TopBarStepper`). Systemowy `Stepper` odpada: jego strzałek nie
/// da się powiększyć, a w arkuszu były ledwo widoczne (zgłoszenie 2026-09-17).
private struct SheetStepperControl: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var text: (Int) -> String = { "\($0)" }
    var fieldWidth: CGFloat = 46
    var isEnabled = true

    var body: some View {
        HStack(spacing: 4) {
            TopBarValueField(text: text(value), width: fieldWidth, isEnabled: isEnabled)
            TopBarStepper(canIncrement: isEnabled && value < range.upperBound,
                          canDecrement: isEnabled && value > range.lowerBound,
                          onIncrement: { value = min(range.upperBound, value + 1) },
                          onDecrement: { value = max(range.lowerBound, value - 1) })
        }
    }
}

/// Pole liczbowe 0–127 w tabeli — zakres klawiszy wpisuje się z klawiatury, tak jak
/// w oryginale, a wartość spoza zakresu przycina się przy wpisaniu.
private struct RangeField: View {
    @Binding var value: Int

    var body: some View {
        TextField("", value: Binding(
            get: { value },
            set: { value = min(127, max(0, $0)) }
        ), format: .number)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 46)
    }
}

/// Wspólny rytm zakładek: ta sama szerokość i marginesy. Wysokość własna zakładki
/// (`--snapshot-settings` pilnuje, żeby nie przekroczyła `SettingsWindow.pageHeight`).
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(width: SettingsWindow.contentWidth, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Szerokość treści strony (bez marginesów) — z niej liczą się szerokości kart.
private let pageInnerWidth = SettingsWindow.contentWidth - 48
private let cardSpacing: CGFloat = 12

/// Szerokość jednej z `count` równych kart w rzędzie.
private func cardWidth(_ count: Int) -> CGFloat {
    (pageInnerWidth - cardSpacing * CGFloat(count - 1)) / CGFloat(count)
}

/// Ramka grupy ustawień — ta sama, co karty zakładki Patch. W rzędzie (`GridRow`)
/// karty dostają wspólną wysokość, więc dolne krawędzie stoją w jednej linii.
private struct SettingsCard<Content: View>: View {
    let title: String
    var caption: String?
    var width: CGFloat?
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                content
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(4)
        } label: {
            Text(title).font(.headline)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
    }
}

/// Mały podpis nad kontrolką w karcie.
private struct FieldLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

/// Wybór jednej z kilku wartości w przyciskach górnej belki (`TopBarButton`): wybrany
/// świeci kolorem, reszta ma szarą ramkę — jak Voice/FX czy Run w pasku (prośba
/// użytkownika 2026-10-15, zamiast systemowych segmentów). `tint` pozwala nadać
/// kolor o tym samym znaczeniu co w belce (Run zielony, wyciszenie czerwone, sloty zielone).
private struct BarChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    var tint: (Value) -> Color = { _ in .accentColor }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options.indices, id: \.self) { index in
                let value = options[index].0
                TopBarButton(content: .text(options[index].1), isOn: selection == value,
                             tint: tint(value)) { selection = value }
            }
        }
        .fixedSize()
    }
}

/// Lista opcji jedna pod drugą (radio). Długie opisy zawijają się w obrębie karty.
private struct RadioChoices<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options.indices, id: \.self) { index in
                Text(options[index].title)
                    .fixedSize(horizontal: false, vertical: true)
                    .tag(options[index].value)
            }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
    }
}

/// Pasek na dole zakładek Synth i Performance: zmiany nie jadą do Norda od razu, więc
/// pasek mówi to wprost i daje przycisk wysyłki, który świeci, gdy coś czeka (prośba
/// użytkownika 2026-10-15 — drobny dopisek pod kartami łatwo było przeoczyć).
private struct SendToDeviceBar: View {
    let connected: Bool
    let pending: Bool
    let note: String
    let send: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: pending ? "exclamationmark.circle.fill" : "checkmark.circle")
                .foregroundStyle(pending ? Color.orange : .secondary)
            Text(status)
            Text(note).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            // Zielony jak „On” w belce, gdy jest co wysłać (prośba użytkownika 2026-10-15).
            TopBarButton(content: .text("Send to G2"), isOn: pending, tint: .green, isEnabled: pending,
                         action: send)
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 4)
    }

    private var status: String {
        if !connected { return "No G2 connected." }
        return pending ? "Changes not sent to the G2 yet." : "The G2 has these settings."
    }
}

// MARK: - Kawa

/// Prośba o wsparcie — na czterech zakładkach edytora (General, Display, Connection,
/// Shortcuts; prośba użytkownika 2026-10-15). Na zakładkach, na których się pracuje
/// (Synth, Patch, Performance), jej nie ma. Darowizna niczego nie odblokowuje
/// → [[Docs/Plan projektu/04-plan-wsparcia-i-spolecznosci]]. Przycisk zielony i tej
/// samej wysokości co Run w belce i przyciski wyboru w oknie (`TopBarButton`).
/// `compact` = jedna linijka, gdy pod kartami nie ma miejsca na cały blok (Shortcuts).
private struct SupportPrompt: View {
    var compact = false

    /// Druga linijka (prośba użytkownika 2026-10-23).
    private static let thanks = "Building this editor has cost me a lot of time and money \u{2014} "
        + "I\u{2019}ll be truly grateful for any support."

    var body: some View {
        if compact {
            HStack(spacing: 10) {
                Image(systemName: "cup.and.saucer").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cube G2 Editor is free and open source. If it helps your music, you can buy me a coffee.")
                    Text(Self.thanks)
                }
                .foregroundStyle(.secondary)
                button
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "cup.and.saucer")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Cube G2 Editor is free and open source.")
                    .font(.headline)
                Text("If it helps your music, you can buy me a coffee.")
                    .foregroundStyle(.secondary)
                Text(Self.thanks)
                    .foregroundStyle(.secondary)
                button.padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var button: some View {
        TopBarButton(content: .text("Support on Ko-fi"), isOn: true, tint: .green) {
            NSWorkspace.shared.open(SplashWindow.kofiURL)
        }
        .supportPulse(.green)
    }
}

/// Zachęta do kawy: od przycisku rozchodzi się poświata w jego kolorze — **bez końca**
/// (prośba użytkownika 2026-10-23; do tego dnia trzy błyski po otwarciu strony i spokój).
/// Przerwa między błyskami dłuższa od samego błysku, żeby przycisk przyciągał wzrok,
/// a nie migał.
private struct SupportPulse: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: 0.0, repeating: true) { view, glow in
                view
                    .shadow(color: color.opacity(0.9 * glow), radius: 9 * glow)
                    .scaleEffect(1 + 0.05 * glow)
            } keyframes: { _ in
                CubicKeyframe(1, duration: 0.45)
                CubicKeyframe(0, duration: 0.65)
                CubicKeyframe(0, duration: 1.1)
            }
    }
}

extension View {
    func supportPulse(_ color: Color) -> some View {
        modifier(SupportPulse(color: color))
    }
}

/// Karty u góry w swojej naturalnej wysokości, kawa na środku wolnego miejsca pod
/// nimi — strona zajmuje całą (stałą) wysokość okna.
private struct CardsWithSupport<Content: View>: View {
    /// Jedna linijka kawy zamiast bloku — gdy karty zajmują prawie całą stronę (General).
    var compactSupport = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            SupportPrompt(compact: compactSupport)
            Spacer(minLength: 0)
        }
        .frame(height: SettingsWindow.pageHeight - 40)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @AppStorage(KnobControl.storageKey) private var knobControl = KnobControl.vertical.rawValue
    @AppStorage(SilentSlotClick.storageKey) private var silentSlotClick = SilentSlotClick.addToPlaying.rawValue
    @AppStorage(UnsavedChangesGuard.askOnReplaceKey) private var askOnReplace = true
    @AppStorage(UnsavedChangesGuard.askOnInitPatchKey) private var askOnInitPatch = true

    var body: some View {
        SettingsPage {
            CardsWithSupport(compactSupport: true) {
                Grid(horizontalSpacing: cardSpacing, verticalSpacing: cardSpacing) {
                    GridRow {
                        SettingsCard(title: "Knobs", width: cardWidth(3)) {
                            FieldLabel("Knob Control")
                            BarChoice(selection: $knobControl,
                                      options: KnobControl.allCases.map { ($0.rawValue, $0.title) })
                            Text("How knobs and sliders follow the mouse. Circular jumps from "
                                + "maximum to minimum past the 6 o'clock position.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            FieldLabel("Morph Assign").padding(.top, 4)
                            Text("Ctrl-click a knob to assign it to the focused morph group, "
                                + "or use Morph Assign in its right-click menu.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SettingsCard(title: "Clicking a Silent Slot",
                                     caption: "What a plain click on a slot button does when that slot is not "
                                         + "playing. A playing slot is only taken for editing. Shift-click still "
                                         + "plays or mutes a slot.",
                                     width: cardWidth(3))
                        {
                            RadioChoices(selection: $silentSlotClick,
                                         options: SilentSlotClick.allCases.map { ($0.rawValue, $0.title) })
                        }
                        SettingsCard(title: "Unsaved Changes",
                                     caption: "When off, an edited patch is replaced without asking and the "
                                         + "changes are lost. Quitting the editor always asks.",
                                     width: cardWidth(3))
                        {
                            Toggle("Ask to save before opening another patch", isOn: $askOnReplace)
                            Toggle("Ask to save before Init 1 / Init 2", isOn: $askOnInitPatch)
                        }
                    }
                    GridRow {
                        SettingsCard(title: "Folders",
                                     caption: "Both show up in the Patches drawer (Disk and Blocks). "
                                         + "Drag a block from the Blocks list onto the patch to insert it.",
                                     width: pageInnerWidth)
                        {
                            FolderChoice(title: "Patches", library: .patches)
                            FolderChoice(title: "Building Blocks", library: .blocks)
                        }
                        .gridCellColumns(3)
                    }
                }
            }
        }
    }
}

/// Jeden folder biblioteki: nazwa, ścieżka i przycisk wyboru.
private struct FolderChoice: View {
    let title: String
    let library: DiskBankLibrary

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 120, alignment: .leading)
            Text(library.folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Not chosen")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(library.folder?.path ?? "")
            Spacer(minLength: 8)
            TopBarButton(content: .text("Choose…"), fixedWidth: 90, action: choose)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = library.folder
        if panel.runModal() == .OK, let url = panel.url {
            library.setFolder(url)
        }
    }
}

// MARK: - Updates

/// Sprawdzanie aktualizacji (`AppUpdates`): numer wersji, przycisk i przełącznik
/// sprawdzania przy starcie, pod nimi historia zmian wszystkich wersji (prośba
/// użytkownika 2026-10-22: widać też, co poprawiła poprzednia wersja).
struct UpdatesSettingsTab: View {
    @AppStorage(AppUpdates.autoKey) private var checkAutomatically = true
    @AppStorage(AppUpdates.lastCheckedKey) private var lastChecked = 0.0

    /// Z paczki aplikacji (`Resources/ReleaseNotes.md`); ta sama treść idzie w opis
    /// wydania na GitHubie, więc okno aktualizacji pokazuje też starsze wersje.
    private static let releaseNotes: AttributedString = {
        let text = Bundle.app.url(forResource: "ReleaseNotes", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return UpdateView.notes(text)
    }()

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: cardSpacing) {
                Grid(horizontalSpacing: cardSpacing, verticalSpacing: cardSpacing) {
                    GridRow {
                        SettingsCard(title: "Version", width: cardWidth(3)) {
                            Text("Cube G2 Editor \(AppUpdates.versionLabel)")
                                .font(.title3.monospacedDigit())
                        }
                        SettingsCard(title: "Check for Updates",
                                     caption: "New versions are published on GitHub. The editor only checks "
                                         + "and tells you; it never downloads or installs anything by itself.",
                                     width: cardWidth(3) * 2 + cardSpacing)
                        {
                            HStack(spacing: 12) {
                                TopBarButton(content: .text(AppUpdates.shared.isChecking
                                                 ? "Checking…" : "Check for Updates Now"),
                                isEnabled: !AppUpdates.shared.isChecking,
                                fixedWidth: 170) { AppUpdates.shared.checkNow() }
                                Text("Last checked: \(lastCheckedText)")
                                    .foregroundStyle(.secondary)
                            }
                            Toggle("Check automatically at launch (once a day)", isOn: $checkAutomatically)
                                .padding(.top, 4)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                SettingsCard(title: "What's New", width: pageInnerWidth) {
                    ScrollView {
                        Text(Self.releaseNotes)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 8)
                    }
                    .frame(height: 150)
                }
                .fixedSize(horizontal: false, vertical: true)
                SupportPrompt(compact: true).padding(.top, 4)
            }
        }
    }

    private var lastCheckedText: String {
        guard lastChecked > 0 else { return "Never" }
        return Date(timeIntervalSince1970: lastChecked).formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Feedback

/// Zgłaszanie błędów i pomysłów (prośba użytkownika 2026-10-16): link do serwera
/// Discord bety, co dołączyć do zgłoszenia i jak zebrać log USB — teksty jak
/// w przypiętych wpisach `#bug-reports` (Docs/Plan projektu/discord-serwer.md).
struct FeedbackSettingsTab: View {
    /// Zaproszenie „nigdy nie wygasa” na serwer `Cube G2` (od użytkownika 2026-10-16).
    static let discordURL = URL(string: "https://discord.gg/2kUhfYRa2t")
    private static let crashReports = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports")

    let device: DeviceConnection

    var body: some View {
        @Bindable var device = device
        SettingsPage {
            Grid(horizontalSpacing: cardSpacing, verticalSpacing: cardSpacing) {
                GridRow {
                    SettingsCard(title: "Report a Bug or an Idea", width: cardWidth(3)) {
                        Text("Bugs and ideas go to the Cube G2 server on Discord: problems in #bug-reports "
                            + "(one bug per message), ideas and wishes in #feedback.")
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = Self.discordURL {
                            TopBarButton(content: .text("Open Discord"), isOn: true, tint: .green) {
                                NSWorkspace.shared.open(url)
                            }
                            .padding(.top, 4)
                        } else {
                            Text("Use the invite link you received with the beta.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        FieldLabel("Your Version").padding(.top, 8)
                        Text(Self.versionInfo)
                            .font(.callout.monospacedDigit())
                            .textSelection(.enabled)
                        TopBarButton(content: .text("Copy Version Info")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.versionInfo, forType: .string)
                        }
                    }
                    SettingsCard(title: "What to Include", width: cardWidth(3)) {
                        VStack(alignment: .leading, spacing: 6) {
                            bullet("What you did, step by step.")
                            bullet("What you expected, and what happened instead.")
                            bullet("A screenshot, if something looks wrong.")
                            bullet("The .pch2 or .prf2 file, if a patch is involved.")
                            bullet("The USB log, if the G2 was connected.")
                            bullet("Your version info (copy it on the left).")
                        }
                    }
                    SettingsCard(title: "USB Log", width: cardWidth(3)) {
                        Text("The editor always remembers the last 10–15 minutes of USB traffic, so you can "
                            + "switch the log on after the problem happened.")
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle("Write USB log to file", isOn: $device.usbLogEnabled)
                        Toggle("Include LED and meter data", isOn: $device.usbLogIncludesVisuals)
                            .help("Also log the LED and meter stream from the G2 (about 80 lines per second). "
                                + "Switch it on before the problem happens.")
                        Button("Reveal USB Log in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: device.usbLogPath)])
                        }
                        .disabled(!device.usbLogEnabled)
                        Text("Attach usb.log to your report. The same switch is in the G2 status menu "
                            + "in the toolbar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        FieldLabel("If the Editor Crashed").padding(.top, 6)
                        Button("Reveal Crash Reports in Finder") {
                            NSWorkspace.shared.open(Self.crashReports)
                        }
                        Text("Attach the newest file with the editor's name. It may contain your macOS user name.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Wersja edytora, macOS i model Maca — jedna linia do wklejenia w zgłoszenie.
    static var versionInfo: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var model = [CChar](repeating: 0, count: 64)
        var size = model.count
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return "Cube G2 Editor \(AppUpdates.versionLabel), macOS \(os.majorVersion).\(os.minorVersion)."
            + "\(os.patchVersion), \(String(cString: model))"
    }
}

// MARK: - Display

struct DisplaySettingsTab: View {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @AppStorage(CableStyle.storageKey) private var cableStyle = CableStyle.curved3D.rawValue
    @AppStorage(KnobStyle.storageKey) private var knobStyle = KnobStyle.light.rawValue
    @AppStorage(KnobRangeSegments.storageKey) private var rangeSegments = KnobRangeSegments.line.rawValue
    @AppStorage(KnobRangeColor.storageKey) private var rangeColor = KnobRangeColor.green.rawValue
    @AppStorage(GlowAmount.storageKey) private var glow = 0.0
    @AppStorage(KnobPointerColor.storageKey) private var pointerColor = KnobPointerColor.white.rawValue
    @AppStorage(KnobMorphRange.storageKey) private var morphRange = KnobMorphRange.full.rawValue
    @AppStorage(PanelShading.storageKey) private var panelShading = true

    private static let widths: [CGFloat] = [250, 250, pageInnerWidth - 500 - 2 * cardSpacing]

    var body: some View {
        SettingsPage {
            CardsWithSupport {
                Grid(horizontalSpacing: cardSpacing, verticalSpacing: cardSpacing) {
                    GridRow {
                        SettingsCard(title: "Appearance",
                                     caption: "System follows the light or dark mode set in macOS.",
                                     width: Self.widths[0])
                        {
                            choice($appearance, AppAppearance.allCases.map { ($0.rawValue, $0.title) })
                                .onChange(of: appearance) { SettingsWindow.applyAppearance(appearance) }
                        }
                        SettingsCard(title: "Patch",
                                     caption: "Changes show on the patch right away.",
                                     width: Self.widths[1])
                        {
                            FieldLabel("Cables")
                            Picker("", selection: $cableStyle) {
                                ForEach(CableStyle.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Toggle("3D buttons and screens", isOn: $panelShading)
                                .onChange(of: panelShading) { ModulePreviewCache.shared.redraw() }
                                .padding(.top, 4)
                        }
                        SettingsCard(title: "Knobs", width: Self.widths[2]) {
                            knobs
                        }
                    }
                }
            }
        }
    }

    private var knobs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    label("Style")
                    choice($knobStyle, KnobStyle.allCases.map { ($0.rawValue, $0.title) })
                }
                // Pokazujemy tylko opcje, które działają przy wybranym stylu —
                // zamiast szarych pól: kolor wskaźnika ma tylko Light, wycinka
                // morfu nie ma Dark, pasek wartości ma tylko Future.
                if knobStyle == KnobStyle.light.rawValue {
                    GridRow {
                        label("Pointer")
                        choice($pointerColor, KnobPointerColor.allCases.map { ($0.rawValue, $0.title) })
                    }
                }
                if knobStyle != KnobStyle.dark.rawValue {
                    GridRow {
                        label("Morph Range")
                        choice($morphRange, KnobMorphRange.allCases.map { ($0.rawValue, $0.title) })
                    }
                }
                if knobStyle == KnobStyle.future.rawValue {
                    GridRow {
                        label("Range")
                        choice($rangeSegments, KnobRangeSegments.allCases.map { ($0.rawValue, $0.title) })
                    }
                    GridRow {
                        label("Range Color")
                        choice($rangeColor, KnobRangeColor.allCases.map { ($0.rawValue, $0.title) })
                    }
                }
                GridRow {
                    label("Glow")
                    // Podglądy modułów przerysowujemy po puszczeniu suwaka.
                    Slider(value: $glow, in: GlowAmount.range, step: 0.05) {
                        Text("Glow")
                    } minimumValueLabel: {
                        Text("Off").font(.caption)
                    } maximumValueLabel: {
                        Text("Max").font(.caption)
                    } onEditingChanged: { editing in
                        if !editing { ModulePreviewCache.shared.redraw() }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
            Text("Glow lights up knob ranges (Future style) and LEDs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: knobStyle) { ModulePreviewCache.shared.redraw() }
        .onChange(of: pointerColor) { ModulePreviewCache.shared.redraw() }
        .onChange(of: morphRange) { ModulePreviewCache.shared.redraw() }
        .onChange(of: rangeSegments) { ModulePreviewCache.shared.redraw() }
        .onChange(of: rangeColor) { ModulePreviewCache.shared.redraw() }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    private func choice<Value: Hashable>(_ selection: Binding<Value>,
                                         _ options: [(Value, String)]) -> some View
    {
        BarChoice(selection: selection, options: options)
    }
}

// MARK: - Connection

struct ConnectionSettingsTab: View {
    let device: DeviceConnection

    @AppStorage(PatchOpenMode.storageKey) private var patchOpenMode = PatchOpenMode.switchToPatch.rawValue
    @AppStorage(ConnectContentMode.storageKey) private var connectContentMode = ConnectContentMode.sendToDevice.rawValue

    var body: some View {
        @Bindable var device = device
        SettingsPage {
            CardsWithSupport {
                Grid(horizontalSpacing: cardSpacing, verticalSpacing: cardSpacing) {
                    GridRow {
                        SettingsCard(title: "When the G2 Connects",
                                     caption: "What happens when the G2 is connected or switched on while the editor "
                                         + "already has its own patch open. Sending replaces only the G2's current "
                                         + "slots, not its memory banks. To see what the G2 really holds, choose "
                                         + "Load and reconnect the cable.",
                                     width: cardWidth(3))
                        {
                            RadioChoices(selection: $connectContentMode,
                                         options: ConnectContentMode.allCases.map { ($0.rawValue, $0.title) })
                        }
                        SettingsCard(title: "Opening a Single Patch",
                                     caption: "What happens when you open a .pch2 file while the G2 is in Performance "
                                         + "mode. New Patch follows the same choice for the G2's mode. A performance "
                                         + "(.prf2) always switches the G2 to Performance mode.",
                                     width: cardWidth(3))
                        {
                            RadioChoices(selection: $patchOpenMode,
                                         options: PatchOpenMode.allCases.map { ($0.rawValue, $0.title) })
                        }
                        SettingsCard(title: "Diagnostics",
                                     caption: "The USB log also contains what happened before you switched it on. "
                                         + "Attach it to a bug report.",
                                     width: cardWidth(3))
                        {
                            Toggle("Write USB log to file", isOn: $device.usbLogEnabled)
                            Toggle("Include LED and meter data", isOn: $device.usbLogIncludesVisuals)
                                .help("Also log the LED and meter stream from the G2 (about 80 lines per second). "
                                    + "Switch it on before the problem happens.")
                            Button("Reveal USB Log in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: device.usbLogPath)])
                            }
                            .disabled(!device.usbLogEnabled)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shortcuts

/// Skróty czytane z PRAWDZIWEGO paska menu w chwili otwarcia zakładki — lista nie może
/// rozjechać się z menu. Skróty jednoklawiszowe kanwy (`EditorKeyboardShortcuts`)
/// nie mają pozycji w menu, więc stoją tu na sztywno.
struct ShortcutsSettingsTab: View {
    struct Entry: Hashable {
        let title: String
        let keys: String
    }

    @State private var group = "File"
    @State private var search = ""
    @State private var groups: [(name: String, entries: [Entry])] = []

    /// Pole listy i ile wierszy mieści jedna kolumna (wiersz ≈ 22 pt).
    private static let listHeight: CGFloat = 270
    private static let rowsPerColumn = 12

    private static let canvasGroup: [Entry] = [
        Entry(title: "Select Variation 1–8", keys: "1 – 8"),
        Entry(title: "Select Slot A–D", keys: "A – D"),
        Entry(title: "View Voice Area", keys: "V"),
        Entry(title: "View FX Area", keys: "F"),
        Entry(title: "Start / Stop Master Clock", keys: "R"),
        Entry(title: "Shake Cables", keys: "S"),
        Entry(title: "Show Values, Morphs, Knobs, MIDI CC", keys: "F5 – F8"),
        Entry(title: "Move the view", keys: "Space + drag"),
        Entry(title: "Play notes from the computer keyboard", keys: "Caps Lock"),
        Entry(title: "Close the side drawer", keys: "Esc"),
    ]

    private var shownEntries: [Entry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            return (groups.first { $0.name == group } ?? groups.first)?.entries ?? []
        }
        return groups.flatMap(\.entries).filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        SettingsPage {
            SettingsCard(title: "Keyboard Shortcuts",
                         caption: "Single keys work on the patch only, never while you type a name.")
            {
                HStack {
                    BarChoice(selection: $group, options: groups.map { ($0.name, $0.name) })
                        .disabled(!search.isEmpty)
                    Spacer()
                    TextField("Search", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
                .padding(.bottom, 6)
                // Jedna kolumna; druga dopiero wtedy, gdy skróty się w niej nie mieszczą
                // (uwaga użytkownika 2026-10-15: File z ośmioma skrótami nie potrzebuje dwóch).
                let entries = shownEntries
                let split = entries.count > Self.rowsPerColumn
                let half = split ? (entries.count + 1) / 2 : entries.count
                // Stałe pole listy: wyniki szukania potrafią być długie, a okno ma
                // jedną wysokość — przewija się tylko lista, nigdy całe okno.
                ScrollView {
                    HStack(alignment: .top, spacing: 40) {
                        column(Array(entries.prefix(half)))
                        if split { column(Array(entries.dropFirst(half))) }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(height: Self.listHeight)
            }
        }
        .onAppear {
            groups = Self.readMenu() + [("Canvas", Self.canvasGroup)]
            if !groups.contains(where: { $0.name == group }), let first = groups.first { group = first.name }
        }
    }

    private func column(_ entries: [Entry]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            ForEach(entries, id: \.self) { entry in
                GridRow {
                    Text(entry.title)
                    Text(entry.keys)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private static func readMenu() -> [(name: String, entries: [Entry])] {
        guard let menu = NSApp.mainMenu else { return [] }
        return menu.items.dropFirst().compactMap { top in
            guard let submenu = top.submenu else { return nil }
            let entries = collect(submenu)
            return entries.isEmpty ? nil : (top.title, entries)
        }
    }

    private static func collect(_ menu: NSMenu) -> [Entry] {
        menu.items.flatMap { item -> [Entry] in
            if let submenu = item.submenu { return collect(submenu) }
            guard !item.keyEquivalent.isEmpty, !item.isHidden else { return [] }
            return [Entry(title: item.title, keys: keys(of: item))]
        }
    }

    private static func keys(of item: NSMenuItem) -> String {
        let flags = item.keyEquivalentModifierMask
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        // Wielka litera w `keyEquivalent` sama oznacza Shift.
        let key = item.keyEquivalent
        if flags.contains(.shift) || key != key.lowercased() { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key.uppercased()
    }
}

// MARK: - Synth

/// Ustawienia SAMEGO URZĄDZENIA (Synth Settings dialog w oryginale). Nie ma ich
/// w żadnym pliku, więc bez podłączonego Norda zakładka nie ma czego pokazać.
/// W szerokim oknie mieści się wszystko naraz — bez podzakładek General / MIDI.
///
/// Zmiany jadą do Norda **przy wyjściu z zakładki albo zamknięciu okna i tylko wtedy,
/// gdy coś się zmieniło** — jak Synth Settings dialog (TrySendData) → [[Docs/usb/synth-settings]].
struct SynthSettingsTab: View {
    let device: DeviceConnection

    @State private var draft = G2SynthSettings()
    @State private var loaded = false

    /// Tylko dla `--snapshot-settings`: ustawienia zamiast podłączonego Norda.
    static var snapshotSettings: G2SynthSettings?

    private var settings: G2SynthSettings? {
        device.synthSettings ?? Self.snapshotSettings
    }

    private let slotLabels = ["A", "B", "C", "D"]

    var body: some View {
        SettingsPage {
            if settings == nil {
                Text("Connect a G2 to change its settings.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Grid(horizontalSpacing: cardSpacing, verticalSpacing: cardSpacing) {
                        GridRow {
                            synthCard
                            tuneCard
                            pedalCard
                        }
                        GridRow {
                            slotChannelsCard
                            midiCard
                            controllersCard
                        }
                    }
                    SendToDeviceBar(connected: device.synthSettings != nil, pending: pending,
                                    note: "They are also sent when you switch tabs or close this window.",
                                    send: send)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: device.synthSettings) { if !loaded { load() } }
        .onDisappear(perform: send)
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindow.willClose)) { _ in send() }
    }

    private var synthCard: some View {
        SettingsCard(title: "Synth", width: cardWidth(3)) {
            // Nazwa urządzenia — ta, którą Nord pokazuje na swoim wyświetlaczu.
            FieldLabel("Name")
            TextField("Name", text: Binding(
                get: { draft.name },
                set: { draft.name = String($0.prefix(G2UsbProtocol.synthNameLength)) }
            ))
            .labelsHidden()
            .frame(width: 200)
            Toggle("Memory protect", isOn: $draft.memoryProtect)
                .padding(.top, 4)
        }
    }

    private var tuneCard: some View {
        SettingsCard(title: "Tune", width: cardWidth(3)) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Master Tune").foregroundStyle(.secondary)
                    Text(String(format: "%.2f Hz", draft.masterTuneHz)).monospacedDigit()
                }
                GridRow {
                    Text("Semi").foregroundStyle(.secondary)
                    SheetStepperControl(value: $draft.tuneSemi, range: -6 ... 6)
                }
                GridRow {
                    Text("Cent").foregroundStyle(.secondary)
                    SheetStepperControl(value: $draft.tuneCent, range: -100 ... 100)
                }
                GridRow {
                    Toggle("Octave Shift", isOn: $draft.globalOctaveShiftEnabled)
                    SheetStepperControl(value: $draft.globalOctaveShift, range: -2 ... 2,
                                        isEnabled: draft.globalOctaveShiftEnabled)
                }
            }
        }
    }

    private var pedalCard: some View {
        SettingsCard(title: "Pedal", width: cardWidth(3)) {
            FieldLabel("Polarity")
            BarChoice(selection: $draft.pedalPolarityClosed,
                      options: [(false, "Open"), (true, "Closed")])
            FieldLabel("Control Pedal Gain").padding(.top, 4)
            SheetStepperControl(value: $draft.controlPedalGain, range: 0 ... 32,
                                text: { _ in draft.controlPedalGainLabel }, fieldWidth: 56)
        }
    }

    private var slotChannelsCard: some View {
        SettingsCard(title: "Slot Channels",
                     caption: "An unchecked slot does not listen to MIDI.",
                     width: cardWidth(3))
        {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(draft.slots.indices, id: \.self) { index in
                    GridRow {
                        Text("Slot \(slotLabels[index])")
                        SheetStepperControl(value: $draft.slots[index].channel,
                                            range: 1 ... 16, fieldWidth: 34)
                        Toggle("Active", isOn: $draft.slots[index].active)
                    }
                }
            }
        }
    }

    private var midiCard: some View {
        SettingsCard(title: "MIDI", width: cardWidth(3)) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Global Channel").foregroundStyle(.secondary)
                    Picker("", selection: $draft.globalChannel) {
                        ForEach(1 ... 16, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                        Text("Off").tag(Int?.none)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("SysEx ID").foregroundStyle(.secondary)
                    Picker("", selection: $draft.sysExID) {
                        ForEach(1 ... 16, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                        Text("All").tag(Int?.none)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Toggle("Local on", isOn: $draft.localOn).padding(.top, 4)
            Toggle("Send clock", isOn: $draft.sendClock)
            Toggle("Ignore external clock", isOn: $draft.ignoreExternalClock)
        }
    }

    /// Dwie kolumny przełączników, jak w oryginale: Controllers i Program Change,
    /// każde osobno na odbiór i na wysyłkę.
    private var controllersCard: some View {
        SettingsCard(title: "Controllers and Program Change", width: cardWidth(3)) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("Controllers")
                    Text("Program Change")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                GridRow {
                    Text("Receive")
                    Toggle("", isOn: $draft.controllersReceive).labelsHidden()
                    Toggle("", isOn: $draft.programChangeReceive).labelsHidden()
                }
                GridRow {
                    Text("Send")
                    Toggle("", isOn: $draft.controllersSend).labelsHidden()
                    Toggle("", isOn: $draft.programChangeSend).labelsHidden()
                }
            }
        }
    }

    private func load() {
        guard let settings else { return }
        draft = settings
        loaded = true
    }

    private var pending: Bool {
        loaded && device.synthSettings.map { draft != $0 } == true
    }

    private func send() {
        guard loaded, let current = device.synthSettings, draft != current else { return }
        let settings = draft
        Task { await device.sendSynthSettings(settings) }
    }
}

// MARK: - Patch

/// Ustawienia patcha (sekcja `0x4d`, obszar 2) — osobne dla każdej wariacji. Przyciski
/// 1–8 przełączają grającą wariację, tak jak pasek wariacji: wartości dotyczą zawsze
/// tej, która gra (decyzja użytkownika 2026-10-15). Przy performance przyciski A–D
/// wybierają edytowany slot — jak przyciski slotów w belce.
struct PatchSettingsTab: View {
    @Bindable var state: PatchState

    /// Dwa rzędy kart: krótkie ustawienia po cztery, Vibrato i Arpeggiator po dwa.
    /// Szerokości z pomiaru najdłuższych rzędów przycisków (Octave Shift, Direction).
    private static let topRow: [CGFloat] = {
        let fixed: [CGFloat] = [230, 270, 220]
        return fixed + [pageInnerWidth - fixed.reduce(0, +) - 3 * cardSpacing]
    }()

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 16) {
                header
                HStack(spacing: 10) {
                    Text("Variation").foregroundStyle(.secondary)
                    BarChoice(selection: Binding(get: { state.patch.activeVariation },
                                                 set: { state.selectVariation($0) }),
                              options: (0 ..< 8).map { ($0, "\($0 + 1)") })
                    if !(0 ... 7).contains(state.patch.activeVariation) {
                        Text("The Mutator buffer is playing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Grid(horizontalSpacing: cardSpacing, verticalSpacing: cardSpacing) {
                    GridRow {
                        SettingsCard(title: "Volume", width: Self.topRow[0]) {
                            slider(.patchVolume)
                            choice(.activeMuted, label: "Output")
                        }
                        SettingsCard(title: "Glide", width: Self.topRow[1]) {
                            choice(.glide)
                            slider(.glideTime, label: "Time")
                        }
                        SettingsCard(title: "Bend", width: Self.topRow[2]) {
                            choice(.bend)
                            stepper(.semitone, label: "Range")
                        }
                        SettingsCard(title: "Keyboard", width: Self.topRow[3]) {
                            choice(.octaveShift, label: "Octave Shift")
                            choice(.sustain, label: "Sustain Pedal")
                        }
                    }
                }
                Grid(horizontalSpacing: cardSpacing, verticalSpacing: cardSpacing) {
                    GridRow {
                        SettingsCard(title: "Vibrato", width: cardWidth(2)) {
                            choice(.vibrato)
                            HStack(spacing: 24) {
                                slider(.vibratoCents, label: "Depth")
                                slider(.vibratoRate, label: "Rate")
                            }
                        }
                        SettingsCard(title: "Arpeggiator", width: cardWidth(2)) {
                            HStack(alignment: .top, spacing: 24) {
                                choice(.arpeggiator)
                                choice(.arpOctaves, label: "Octaves")
                            }
                            HStack(alignment: .top, spacing: 24) {
                                choice(.arpTime, label: "Time")
                                choice(.arpType, label: "Direction")
                            }
                        }
                    }
                }
            }
        }
    }

    /// Slot, nazwa, kategoria i tryb głosów — jedną drogą przez `PatchState`, żeby
    /// zmiana była cofalna i trafiała do Norda.
    private var header: some View {
        HStack(spacing: 12) {
            if state.slots.count > 1 {
                Text("Slot").foregroundStyle(.secondary)
                // Zielone jak przyciski slotów w belce (prośba użytkownika 2026-10-15:
                // nazwę dało się zmienić tylko w slocie A).
                BarChoice(selection: Binding(get: { state.selectedSlot },
                                             set: { state.selectedSlot = $0 }),
                          options: state.slots.indices.map { ($0, ["A", "B", "C", "D"][min($0, 3)]) },
                          tint: { _ in .green })
            }
            TextField("Name", text: Binding(
                get: { state.patch.name },
                set: { state.setPatchName($0) }
            ))
            .frame(width: 200)
            Picker("Category", selection: Binding(
                get: { min(state.patch.description.category, G2PatchCategory.names.count - 1) },
                set: { state.setCategory($0) }
            )) {
                ForEach(G2PatchCategory.names.indices, id: \.self) { Text(G2PatchCategory.names[$0]).tag($0) }
            }
            .fixedSize()
            HStack(spacing: 6) {
                Text("Voices").foregroundStyle(.secondary)
                SheetStepperControl(value: Binding(get: { state.voiceModeIndex },
                                                   set: { state.setVoiceMode(index: $0) }),
                                    range: G2VoiceMode.minIndex ... G2VoiceMode.maxIndex,
                                    text: { G2VoiceMode.label(index: $0) }, fieldWidth: 60)
            }
        }
    }

    private func binding(_ setting: G2PatchSetting) -> Binding<Int> {
        Binding(get: { state.patchSetting(setting) },
                set: { state.setPatchSetting(setting, value: $0) })
    }

    /// Wybór z kilku nazwanych wartości — etykieta nad przyciskami.
    private func choice(_ setting: G2PatchSetting, label: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label { FieldLabel(label) }
            BarChoice(selection: binding(setting),
                      options: setting.range.map { ($0, setting.valueText($0)) },
                      tint: { value in
                          // Wyciszony patch na czerwono, grający na zielono — jak Off/On
                          // przy Vol w pasku slotu.
                          guard setting == .activeMuted else { return .accentColor }
                          return value == 0 ? .red : .green
                      })
        }
    }

    /// Suwak 0–127. Przeciągnięcie to jeden krok cofania (`beginParameterGesture`).
    private func slider(_ setting: G2PatchSetting, label: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label { FieldLabel(label) }
            HStack {
                Slider(value: Binding(get: { Double(state.patchSetting(setting)) },
                                      set: { state.setPatchSetting(setting, value: Int($0.rounded())) }),
                       in: Double(setting.range.lowerBound) ... Double(setting.range.upperBound))
                { editing in
                    if editing { state.beginParameterGesture() } else { state.endParameterGesture() }
                }
                Text(setting.valueText(state.patchSetting(setting)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
    }

    private func stepper(_ setting: G2PatchSetting, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            FieldLabel(label)
            SheetStepperControl(value: binding(setting), range: setting.range,
                                text: { setting.valueText($0) }, fieldWidth: 64)
        }
    }
}

// MARK: - Notes (Textpad)

struct PatchNotesSheet: View {
    @Bindable var state: PatchState

    var body: some View {
        SheetChrome(title: "Notes", done: { state.showPatchNotes = false }, content: {
            TextEditor(text: $state.patch.notes)
                .font(.system(.body, design: .monospaced))
                .padding(8)
        })
    }
}

// MARK: - Performance

struct PerformanceSettingsTab: View {
    @Bindable var state: PatchState
    /// Połączenie z Nordem — „Enable" i „Keyboard" to jedyne pola, które urządzenie
    /// potrafi przyjąć na żywo (`0x07` + `0x0F`), więc idą do niego od razu.
    /// Reszta (Hold, zakresy, tempo) zostaje w pliku do wyjścia z zakładki → [[Docs/usb/slots]].
    let device: DeviceConnection

    private let slotLabels = ["A", "B", "C", "D"]

    var body: some View {
        SettingsPage {
            if !state.hasPerformanceSettings {
                Text("Open a performance (.prf2) to change its settings.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                content
            }
        }
        .onDisappear(perform: send)
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindow.willClose)) { _ in send() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: cardSpacing) {
            SettingsCard(title: "Performance", width: pageInnerWidth) {
                HStack(spacing: 14) {
                    // Plik .prf2 nie ma pola nazwy — startowo jest nią nazwa pliku, ale
                    // urządzenie trzyma własną i stąd się ją przestawia → [[Docs/usb/slots]].
                    Text("Name").foregroundStyle(.secondary)
                    TextField("Name", text: $state.performanceName)
                        .onSubmit { sendName() }
                        .labelsHidden()
                        .frame(width: 200)
                    Text("Master Clock").foregroundStyle(.secondary)
                        .padding(.leading, 10)
                    SheetStepperControl(value: $state.performance.masterClock, range: 30 ... 240)
                    Text("BPM").foregroundStyle(.secondary)
                    // Run na zielono, jak przycisk Run przy zegarze w górnej belce.
                    BarChoice(selection: $state.performance.masterClockRunning,
                              options: [(false, "Stop"), (true, "Run")],
                              tint: { $0 ? .green : .accentColor })
                    Spacer()
                    Toggle("Keyboard range", isOn: $state.performance.keyboardRangeEnabled)
                }
            }
            SettingsCard(title: "Slots", width: pageInnerWidth) {
                slotsTable
            }
            SendToDeviceBar(connected: device.status == .connected,
                            pending: device.performanceDiffersFromDevice(state.performance,
                                                                         name: state.performanceName,
                                                                         fileData: state.performanceFileData),
                            note: "Enable and Keyboard go right away. The rest also goes when you switch tabs "
                                + "or close this window.",
                            send: send)
        }
    }

    /// Cztery sloty naraz, kolumnami — jak w oryginale.
    private var slotsTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
            GridRow {
                Text("")
                Text("Patch")
                Text("Enable")
                Text("Keyboard")
                Text("Hold")
                Text("Lower").gridColumnAlignment(.trailing)
                Text("Upper").gridColumnAlignment(.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(Array(state.performance.slots.indices), id: \.self) { index in
                GridRow {
                    Text(slotLabels[index]).bold()
                    Text(state.performance.slots[index].name.isEmpty
                        ? "—" : state.performance.slots[index].name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 200, alignment: .leading)
                    Toggle("", isOn: slotFlag(index, keyPath: \.enabled)).labelsHidden()
                    Toggle("", isOn: slotFlag(index, keyPath: \.keyboard)).labelsHidden()
                    Toggle("", isOn: $state.performance.slots[index].hold).labelsHidden()
                    keyField($state.performance.slots[index].keyRangeLow)
                    keyField($state.performance.slots[index].keyRangeHigh)
                }
            }
        }
    }

    /// Numer klawisza do wpisania i nazwa nuty obok (nuta 60 = C4, jak w reszcie edytora).
    private func keyField(_ value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(MusicalPitch.name(ofMidiNote: value.wrappedValue))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            RangeField(value: value)
        }
    }

    private func send() {
        sendName()
        sendHeader()
    }

    /// Nazwa jedzie do Norda po zatwierdzeniu pola i przy wyjściu z zakładki — jak
    /// `TrySendData` na wyjściu z dialogu oryginału. `sendPerformanceName` sam odsiewa
    /// nazwę, którą urządzenie już ma.
    private func sendName() {
        guard state.hasPerformanceSettings else { return }
        let name = state.performanceName
        Task { await device.sendPerformanceName(name) }
    }

    /// Reszta — Hold, zakresy klawiszy, zakres klawiatury, tempo — jedną sekcją `0x11`,
    /// jak Performance dialog (TrySendData). `sendPerformanceHeader` sam odsiewa sekcję,
    /// którą urządzenie już ma.
    private func sendHeader() {
        guard state.hasPerformanceSettings else { return }
        let performance = state.performance
        let fileData = state.performanceFileData
        Task { await device.sendPerformanceHeader(performance, fileData: fileData) }
    }

    /// Przełącznik, który zapisuje do modelu i od razu wysyła całą selekcję czterech
    /// slotów — urządzenie przyjmuje ją tylko w komplecie, nie slot po slocie.
    private func slotFlag(_ index: Int,
                          keyPath: WritableKeyPath<G2PerformanceSlot, Bool>) -> Binding<Bool>
    {
        Binding(
            get: { state.performance.slots[index][keyPath: keyPath] },
            set: { newValue in
                state.performance.slots[index][keyPath: keyPath] = newValue
                let enabled = state.performance.slots.map(\.enabled)
                let keyboard = state.performance.slots.map(\.keyboard)
                Task { await device.sendSlotSelection(enabled: enabled, keyboard: keyboard) }
            }
        )
    }
}
