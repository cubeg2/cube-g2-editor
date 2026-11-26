// ShortcutCommand.swift
// Every command whose keyboard shortcut can be changed, with the default it ships with, and
// the keys that stay fixed. The menus, the key monitors and Settings ▸ Shortcuts all read
// this list, so a command added here shows up in all of them.

import Foundation

/// Headings of Settings ▸ Shortcuts, in the order they are shown.
public enum ShortcutSection: String, CaseIterable, Identifiable, Sendable {
    case file, edit, view, patch, slots, canvas, performance, synth, tools
    case patchesPanel, mutator, notes, app

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .file: "File"
        case .edit: "Edit"
        case .view: "View"
        case .patch: "Patch"
        case .slots: "Slots and Variations"
        case .canvas: "Canvas"
        case .performance: "Performance"
        case .synth: "Synth"
        case .tools: "Tools"
        case .patchesPanel: "Patches Panel"
        case .mutator: "Patch Mutator"
        case .notes: "Playing Notes"
        case .app: "App and Windows"
        }
    }

    public var scope: ShortcutScope {
        switch self {
        case .slots, .canvas: .patch
        case .patchesPanel: .patchesPanel
        case .mutator: .mutator
        case .file, .edit, .view, .patch, .performance, .synth, .tools, .notes, .app: .menu
        }
    }
}

/// Where a shortcut works — it decides which two commands may share a key.
public enum ShortcutScope: Sendable {
    /// A menu command: works in every window of the editor.
    case menu
    /// A key on the patch: the editor window, never while a name is typed.
    case patch
    /// The Patches drawer, which sits in the editor window.
    case patchesPanel
    /// The Patch Mutator window.
    case mutator

    public func overlaps(_ other: ShortcutScope) -> Bool {
        self == .menu || other == .menu || (self == .mutator) == (other == .mutator)
    }
}

public struct ShortcutCommand: Hashable, Identifiable, Sendable {
    /// Stored in the user's settings: never rename.
    public let id: String
    public let section: ShortcutSection
    public let title: String
    public let defaultStroke: KeyStroke?

    public var scope: ShortcutScope {
        section.scope
    }

    private init(_ id: String, _ section: ShortcutSection, _ title: String, _ stroke: KeyStroke? = nil) {
        self.id = id
        self.section = section
        self.title = title
        defaultStroke = stroke
    }
}

// MARK: - Menu commands

public extension ShortcutCommand {
    static let newPatch = Self("file.newPatch", .file, "New Patch", KeyStroke("n", .command))
    static let openPatch = Self("file.openPatch", .file, "Open Patch", KeyStroke("o", .command))
    static let insertPatchFile = Self("file.insertPatchFile", .file, "Insert Patch File")
    static let save = Self("file.save", .file, "Save", KeyStroke("s", .command))
    static let saveAs = Self("file.saveAs", .file, "Save As", KeyStroke("s", [.shift, .command]))
    static let newPerformance = Self("file.newPerformance", .file, "New Performance",
                                     KeyStroke("n", [.shift, .command]))
    static let loadPerformance = Self("file.loadPerformance", .file, "Load Performance",
                                      KeyStroke("o", [.shift, .command]))
    static let savePerformance = Self("file.savePerformance", .file, "Save Performance")
    static let savePerformanceAs = Self("file.savePerformanceAs", .file, "Save Performance As")

    static let saveSelectionAsBlock = Self("edit.saveSelectionAsBlock", .edit, "Save Selection as Block")

    static let zoomIn = Self("view.zoomIn", .view, "Zoom In", KeyStroke("=", .command))
    static let zoomOut = Self("view.zoomOut", .view, "Zoom Out", KeyStroke("-", .command))
    static let actualSize = Self("view.actualSize", .view, "Actual Size", KeyStroke("0", .command))
    static let zoomToFit = Self("view.zoomToFit", .view, "Zoom to Fit", KeyStroke("0", [.shift, .command]))
    static let modulesPanel = Self("view.modules", .view, "Modules", KeyStroke("1", [.option, .command]))
    static let patchesPanel = Self("view.patches", .view, "Patches", KeyStroke("2", [.option, .command]))
    static let extendedToolbar = Self("view.extendedToolbar", .view, "Extended Toolbar",
                                      KeyStroke("t", .command))
    static let raisedButtons = Self("view.raisedButtons", .view, "3D Buttons and Screens")
    static let layoutSingleBar = Self("view.layoutSingleBar", .view, "Slot Layout: Single Bar",
                                      KeyStroke("s", [.option, .command]))
    static let layoutWindows = Self("view.layoutWindows", .view, "Slot Layout: Windows",
                                    KeyStroke("d", [.option, .command]))
    static let showAllCables = Self("view.showAllCables", .view, "Show All Cables")
    static let hideAllCables = Self("view.hideAllCables", .view, "Hide All Cables")

    static let patchSettings = Self("patch.settings", .patch, "Patch Settings", KeyStroke("p", .command))
    static let patchNotes = Self("patch.notes", .patch, "Notes (Textpad)", KeyStroke("j", .command))
    static let deleteUnusedModules = Self("patch.deleteUnused", .patch, "Delete Unused Modules")
    static let sequenceEditor = Self("patch.sequenceEditor", .patch, "Sequence Editor",
                                     KeyStroke("e", [.option, .command]))
    static let sendToSlot = Self("patch.sendToSlot", .patch, "Send to G2 Slot", KeyStroke("d", .command))

    static let performanceSettings = Self("performance.settings", .performance, "Performance Settings",
                                          KeyStroke("r", .command))
    static let performanceMode = Self("performance.mode", .performance, "Performance Mode")
    static let menuSlotA = Self("performance.slotA", .performance, "Slot: A", KeyStroke("1", .command))
    static let menuSlotB = Self("performance.slotB", .performance, "Slot: B", KeyStroke("2", .command))
    static let menuSlotC = Self("performance.slotC", .performance, "Slot: C", KeyStroke("3", .command))
    static let menuSlotD = Self("performance.slotD", .performance, "Slot: D", KeyStroke("4", .command))

    static let synthSettings = Self("synth.settings", .synth, "Synth Settings", KeyStroke("g", .command))
    static let getActiveSlot = Self("synth.getActiveSlot", .synth, "Get Active Slot from G2",
                                    KeyStroke("u", .command))
    static let saveInSynth = Self("synth.saveInSynth", .synth, "Save In Synth")
    static let downloadBanks = Self("synth.downloadBanks", .synth, "Download Banks from G2")
    static let uploadBanks = Self("synth.uploadBanks", .synth, "Upload Banks to G2")
    static let controllerSnapshot = Self("synth.controllerSnapshot", .synth, "Send Controller Snapshot")
    static let dumpOne = Self("synth.dumpOne", .synth, "Dump One", KeyStroke("1", [.shift, .command]))

    static let deassignAllMidi = Self("tools.deassignAllMidi", .tools, "Deassign All MIDI")
    static let parameterPages = Self("tools.parameterPages", .tools, "Parameter Pages",
                                     KeyStroke("5", [.option, .command]))
    static let parameterOverview = Self("tools.parameterOverview", .tools, "Parameter Overview",
                                        KeyStroke("7", [.option, .command]))
    static let patchAdjuster = Self("tools.patchAdjuster", .tools, "Patch Adjuster",
                                    KeyStroke("8", [.option, .command]))
    static let mutatorWindow = Self("tools.mutator", .tools, "Patch Mutator", KeyStroke("6", [.option, .command]))
    static let virtualKeyboard = Self("tools.keyboard", .tools, "Virtual Keyboard",
                                      KeyStroke("4", [.option, .command]))
    static let colors = Self("tools.colors", .tools, "Colors", KeyStroke("9", [.option, .command]))
    static let spectrum = Self("tools.spectrum", .tools, "Spectrum", KeyStroke("0", [.option, .command]))
    static let xyPlot = Self("tools.xyPlot", .tools, "X-Y Plot", KeyStroke("x", [.option, .command]))
    static let dspLoad = Self("tools.dspLoad", .tools, "DSP Load", KeyStroke("3", [.option, .command]))
}

// MARK: - Keys on the patch, the Patches drawer and the Mutator

public extension ShortcutCommand {
    static let slots: [ShortcutCommand] = ["A", "B", "C", "D"].map {
        Self("slot.\($0)", .slots, "Select Slot \($0)", KeyStroke($0))
    }

    static let variations: [ShortcutCommand] = (1 ... 8).map {
        Self("variation.\($0)", .slots, "Select Variation \($0)", KeyStroke("\($0)"))
    }

    static let viewVoice = Self("canvas.viewVoice", .canvas, "View Voice Area", KeyStroke("v"))
    static let viewFX = Self("canvas.viewFX", .canvas, "View FX Area", KeyStroke("f"))
    static let masterClock = Self("canvas.masterClock", .canvas, "Start or Stop Master Clock", KeyStroke("r"))
    static let shakeCables = Self("canvas.shakeCables", .canvas, "Shake Cables", KeyStroke("s"))
    static let showValues = Self("canvas.showValues", .canvas, "Show Parameter Values", KeyStroke("f5"))
    static let showMorphGroups = Self("canvas.showMorphGroups", .canvas, "Show Morph Groups", KeyStroke("f6"))
    static let showKnobs = Self("canvas.showKnobs", .canvas, "Show Knob Assignments", KeyStroke("f7"))
    static let showMidi = Self("canvas.showMidi", .canvas, "Show MIDI CC Assignments", KeyStroke("f8"))

    static let previousPatch = Self("patches.previous", .patchesPanel, "Load Previous Patch",
                                    KeyStroke("up", .option))
    static let nextPatch = Self("patches.next", .patchesPanel, "Load Next Patch", KeyStroke("down", .option))

    /// Mother, the six children and Father — the order of the number keys.
    static let mutatorBoxes: [ShortcutCommand] = (1 ... 8).map { key in
        let name = key == 1 ? "Mother" : key == 8 ? "Father" : "Child \(key - 1)"
        return Self("mutator.box\(key)", .mutator, "Focus \(name)", KeyStroke("\(key)"))
    }

    static let mutatorToMother = Self("mutator.toMother", .mutator, "Copy to Mother", KeyStroke("o"))
    static let mutatorToFather = Self("mutator.toFather", .mutator, "Copy to Father", KeyStroke("t"))
    static let mutatorMutateFocused = Self("mutator.mutateFocused", .mutator, "Mutate from Focused Box",
                                           KeyStroke("e"))
    static let mutatorMutate = Self("mutator.mutate", .mutator, "Mutate", KeyStroke("u"))
    static let mutatorRandomize = Self("mutator.randomize", .mutator, "Randomize", KeyStroke("n"))
    static let mutatorInterpolate = Self("mutator.interpolate", .mutator, "Interpolate", KeyStroke("i"))
    static let mutatorCross = Self("mutator.cross", .mutator, "Cross", KeyStroke("x"))
    static let mutatorStore = Self("mutator.store", .mutator, "Store", KeyStroke("s"))
}

// MARK: - The list

public extension ShortcutCommand {
    static let all: [ShortcutCommand] = [
        [newPatch, openPatch, insertPatchFile, save, saveAs, newPerformance, loadPerformance,
         savePerformance, savePerformanceAs],
        [saveSelectionAsBlock],
        [zoomIn, zoomOut, actualSize, zoomToFit, modulesPanel, patchesPanel, extendedToolbar,
         raisedButtons, layoutSingleBar, layoutWindows, showAllCables, hideAllCables],
        [patchSettings, patchNotes, deleteUnusedModules, sequenceEditor, sendToSlot],
        slots, variations,
        [viewVoice, viewFX, masterClock, shakeCables, showValues, showMorphGroups, showKnobs, showMidi],
        [performanceSettings, performanceMode, menuSlotA, menuSlotB, menuSlotC, menuSlotD],
        [synthSettings, getActiveSlot, saveInSynth, downloadBanks, uploadBanks, controllerSnapshot, dumpOne],
        [deassignAllMidi, parameterPages, parameterOverview, patchAdjuster, mutatorWindow, virtualKeyboard,
         colors, spectrum, xyPlot, dspLoad],
        [previousPatch, nextPatch],
        mutatorBoxes,
        [mutatorToMother, mutatorToFather, mutatorMutateFocused, mutatorMutate, mutatorRandomize,
         mutatorInterpolate, mutatorCross, mutatorStore],
    ].flatMap { $0 }
}

// MARK: - Fixed keys

/// A key or gesture that cannot be changed — listed so the page shows everything.
public struct FixedShortcut: Hashable, Identifiable, Sendable {
    public let section: ShortcutSection
    public let title: String
    public let keys: String

    public var id: String {
        section.rawValue + title
    }

    private init(_ section: ShortcutSection, _ title: String, _ keys: String) {
        self.section = section
        self.title = title
        self.keys = keys
    }

    public static let all: [FixedShortcut] = [
        Self(.edit, "Undo", "⌘Z"),
        Self(.edit, "Redo", "⇧⌘Z  or  ⌘Y"),
        Self(.edit, "Cut", "⌘X"),
        Self(.edit, "Copy", "⌘C"),
        Self(.edit, "Paste", "⌘V"),
        Self(.edit, "Select All", "⌘A"),
        Self(.edit, "Delete Selection", "⌫  or  ⌦"),
        Self(.canvas, "Change the Focused Value", "↑ ↓"),
        Self(.canvas, "Previous or Next Control", "← →"),
        Self(.canvas, "Morph Range of the Focused Control", "⌃↑ ⌃↓"),
        Self(.canvas, "Focus a Neighbouring Module", "⇧ + arrows"),
        Self(.canvas, "Cancel, End a Comparison, Close the Drawer", "Esc"),
        Self(.canvas, "Show All Variation Differences", "hold ⌥"),
        Self(.canvas, "Move the View", "Space + drag"),
        Self(.canvas, "Zoom", "⌘ + scroll"),
        Self(.canvas, "Fine Adjust", "⇧ + drag"),
        Self(.canvas, "Set a Morph Range with the Mouse", "⌥ + drag a knob"),
        Self(.canvas, "Assign a Knob to the Focused Morph", "⌃ + click"),
        Self(.canvas, "Add to the Selection", "⇧ + click"),
        Self(.mutator, "Move between Boxes", "arrows"),
        Self(.mutator, "Walk the Evolution Tree", "⌥ + arrows"),
        Self(.mutator, "Switch between the Compared Sounds", "Space"),
        Self(.mutator, "End a Comparison", "Esc"),
        Self(.notes, "Play Notes from the Computer Keyboard", "Caps Lock"),
        Self(.notes, "Notes (while Caps Lock is on)", "A W S E D F T G Y H U J K O L P ; '"),
        Self(.notes, "Octave Down or Up", "Z  X"),
        Self(.app, "Settings", "⌘,"),
        Self(.app, "Hide the Editor", "⌘H"),
        Self(.app, "Hide Other Apps", "⌥⌘H"),
        Self(.app, "Close Window", "⌘W"),
        Self(.app, "Close All Windows", "⌥⌘W"),
        Self(.app, "Minimize", "⌘M"),
        Self(.app, "Don't Save (in the save question)", "⌘D"),
        Self(.app, "Quit", "⌘Q"),
    ]
}
