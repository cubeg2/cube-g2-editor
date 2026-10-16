// ParamSemanticsTests.swift
// Krok 3.4 planu Mutatora: klasa parametru G2 → semantyka `MutatorCore` na modułach z §12.

import G2Core
import MutatorCore
import XCTest

final class ParamSemanticsTests: XCTestCase {
    private func semantics(_ module: String, _ parameter: String,
                           file: StaticString = #filePath, line: UInt = #line) throws -> ParameterSemantics
    {
        let def = try XCTUnwrap(ModuleDatabase.module(shortName: module), module, file: file, line: line)
        let index = try XCTUnwrap(def.paramNames.firstIndex(of: parameter), "\(module).\(parameter)",
                                  file: file, line: line)
        return try XCTUnwrap(G2ParamClass.semantics(moduleTypeID: def.id, paramIndex: index, maxRaw: 127),
                             file: file, line: line)
    }

    private func assert(_ module: String, _ parameter: String, _ kind: ParameterKind, _ group: SemanticGroup?,
                        file: StaticString = #filePath, line: UInt = #line) throws
    {
        let value = try semantics(module, parameter, file: file, line: line)
        XCTAssertEqual(value.kind, kind, "\(module).\(parameter)", file: file, line: line)
        XCTAssertEqual(value.group, group, "\(module).\(parameter)", file: file, line: line)
        XCTAssertFalse(value.critical, "\(module).\(parameter)", file: file, line: line)
    }

    func testOscillators() throws {
        for module in ["OscA", "OscB"] {
            try assert(module, "Waveform", .categorical, .timbre)
            try assert(module, "FreqCoarse", .pitchSemitone, .pitch)
            try assert(module, "FreqFine", .bipolar, .pitch)
            try assert(module, "PitchMod", .continuousLinear, .pitch)
        }
        try assert("OscB", "FmAmount", .continuousLog, .timbre)
        try assert("OscB", "Shape", .continuousLinear, .timbre)
    }

    func testFilters() throws {
        for module in ["FltLP", "FltMulti", "FltNord"] {
            try assert(module, "Freq", .continuousLinear, .timbre)
        }
        try assert("FltMulti", "Res", .resonance, .timbre)
        try assert("FltNord", "Res", .resonance, .timbre)
        try assert("FltNord", "FilterType", .categorical, .timbre)
        try assert("FltMulti", "Slope", .categorical, .timbre)
        XCTAssertGreaterThan(try semantics("FltLP", "Freq").weight, try semantics("OscA", "FreqFine").weight)
    }

    func testEnvelopesLfoMixerDelay() throws {
        for parameter in ["Attack", "Decay", "Release"] {
            try assert("EnvADSR", parameter, .timeMs, .envelope)
        }
        try assert("EnvADSR", "Sustain", .continuousLinear, .envelope)
        try assert("EnvAHD", "Hold", .timeMs, .envelope)
        try assert("LfoA", "Rate", .continuousLinear, .motion)
        try assert("LfoA", "Waveform", .categorical, .motion)
        try assert("Mix4-1B", "Lev1", .level, .timbre)
        try assert("DlySingleA", "Time", .timeMs, .space)
    }

    /// To, czego Standard nie rusza, jest krytyczne i bez wagi — te same klasy, jedno źródło.
    func testUntouchedClassesAreCriticalSwitches() throws {
        for (module, parameter) in [("OscA", "Kbt"), ("OscA", "Active"), ("OscA", "FreqMode"),
                                    ("EnvADSR", "OutputType"), ("Mix4-1B", "ExpLin"), ("LfoA", "Range")]
        {
            let value = try semantics(module, parameter)
            XCTAssertTrue(value.critical, "\(module).\(parameter)")
            XCTAssertEqual(value.weight, 0, "\(module).\(parameter)")
        }
    }

    /// Leniwy default: klasa bez ręcznego opisu mutuje się liniowo z wagą 0,5.
    func testUndescribedClassFallsBackToSafeDefault() throws {
        let value = try semantics("Reverb", "Brightness")
        XCTAssertEqual(value, ParameterSemantics(maxRaw: 127))
    }

    /// Każdy parametr każdego modułu, który oryginał zna, dostaje semantykę zgodną z krzywą.
    func testEveryKnownParameterHasSemanticsConsistentWithStandard() {
        for def in ModuleDatabase.all {
            for index in def.paramNames.indices {
                guard let paramClass = G2ParamClass.of(moduleTypeID: def.id, paramIndex: index) else { continue }
                let value = paramClass.semantics(maxRaw: 127)
                XCTAssertEqual(value.critical, paramClass.curve == .none, "\(def.shortName).\(def.paramNames[index])")
            }
        }
    }
}
