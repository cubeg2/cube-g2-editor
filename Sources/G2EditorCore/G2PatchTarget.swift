// G2PatchTarget.swift
// Otwarty patch jako cel silnika `MutatorCore` — odczyt i zapis warstw.
//
// Warstwa = zestaw parametrów patcha: 0…7 to wariacje, 9 — bufor odsłuchu mutatora
// (`G2Patch.mutatorVariation`). Warstwy 8 (Init) silnik nie zapisuje nigdy.
// Zapis idzie tymi samymi drogami co okno Standard, więc urządzenie dostaje to samo:
// bufor odsłuchu — same różnice, wariacja — cały slot.
//
// Cel pamięta odcisk patcha z chwili utworzenia. Gdy w międzyczasie zmienią się moduły,
// zapis jest odrzucany zamiast wpisać wartości w cudze adresy.

import G2Core
import MutatorCore

public enum G2PatchTargetError: Error, Equatable {
    /// Warstwa 8 to Init, a poza 0…9 warstw nie ma.
    case layerNotWritable(UInt8)
    case patchClosed
}

@MainActor
public final class G2PatchTarget: ParameterTarget {
    public nonisolated let fingerprint: TargetFingerprint
    public nonisolated let space: [ParameterAddress: ParameterSemantics]
    private let engineSpace: G2EngineSpace
    private weak var state: PatchState?

    public init(state: PatchState) {
        engineSpace = G2EngineSpace(patch: state.patch, genome: state.mutatorGenome)
        fingerprint = engineSpace.fingerprint
        space = engineSpace.space
        self.state = state
    }

    public func snapshot(layer: UInt8) async throws -> [ParameterAddress: UInt8] {
        try engineSpace.genome(of: sound(layer: layer)).values
    }

    public func write(_ diff: [ParameterAddress: UInt8], layer: UInt8) async throws {
        guard layer < 8 || Int(layer) == G2Patch.mutatorVariation else {
            throw G2PatchTargetError.layerNotWritable(layer)
        }
        let base = try sound(layer: layer)
        guard let state else { throw G2PatchTargetError.patchClosed }
        let current = G2EngineSpace(patch: state.patch, genome: state.mutatorGenome).fingerprint
        guard current == fingerprint else { throw GenomeError.fingerprintMismatch(fingerprint, current) }
        let before = engineSpace.genome(of: base)
        var genome = before
        for (address, raw) in diff where genome.genes[address] != nil {
            genome.genes[address]?.raw = raw
        }
        // Bez faktycznej zmiany nic nie idzie do urządzenia i nie powstaje krok Undo.
        guard !genome.diff(from: before).isEmpty else { return }
        let sound = engineSpace.individual(genome, base: base)
        if Int(layer) == G2Patch.mutatorVariation {
            state.audition(sound)
        } else {
            state.writeIndividualToVariation(sound, variation: Int(layer))
        }
    }

    private func sound(layer: UInt8) throws -> G2Individual {
        guard let state else { throw G2PatchTargetError.patchClosed }
        guard layer <= 9 else { throw G2PatchTargetError.layerNotWritable(layer) }
        return G2Mutator.individual(from: state.patch, variation: Int(layer), genome: state.mutatorGenome)
    }
}
