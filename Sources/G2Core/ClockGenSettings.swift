// ClockGenSettings.swift
// The few ClkGen parameters the Sequence Editor shows next to the sequencers it clocks, and how
// their values are written as the module's display does (Tempo in BPM, Swing in percent).
// → [[Docs/roadmap]] "Sequence Editor"

import Foundation

public enum ClockGenSettings {
    /// ClkGen module type and parameter indices (Rate, Active, Source, BeatSync, Swing).
    public static let typeID = 68
    public static let rate = 0
    public static let active = 1
    public static let source = 2
    public static let swing = 4

    /// Tempo for a Rate value 0…127 — the module's own table: steps of 2 BPM up to 88, then 1 BPM
    /// up to 152, then 2 BPM again (24 … 214 BPM). From `G2BPM` of the original editor.
    public static func bpm(forRate value: Int) -> Int {
        if value <= 32 { return 24 + 2 * value }
        if value <= 96 { return 88 + value - 32 }
        return 152 + (value - 96) * 2
    }

    /// Swing 0…127 → "50.0%" … "75.0%".
    public static func swingText(_ value: Int) -> String {
        String(format: "%.1f%%", 50 + Double(value) * 25 / 127)
    }
}
