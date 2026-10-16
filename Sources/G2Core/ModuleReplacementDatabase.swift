// ModuleReplacementDatabase.swift
// Reguły bezpiecznej podmiany modułów zgodne z oryginalnym edytorem Clavii.

import Foundation

struct ModuleReplacementRawGroup {
    let name: String
    let modules: [Int]
    let parameterGroups: [[[Int]]]
    let inputGroups: [[[Int]]]
    let outputGroups: [[[Int]]]
}

/// Mapa przeniesienia stanu podczas zmiany typu istniejącego modułu.
public struct ModuleReplacementPlan: Sendable, Equatable {
    public let sourceTypeID: Int
    public let targetTypeID: Int
    public let parameterMap: [Int: Int]
    public let inputMap: [Int: Int]
    public let outputMap: [Int: Int]
}

/// Baza podgrup i odpowiedników z oryginalnego edytora Clavia G2.
public enum ModuleReplacementDatabase {
    /// Typy, na które można podmienić dany moduł. Kolejność pochodzi z Clavii.
    public static func candidates(for typeID: Int) -> [Int] {
        rawGroups.first { $0.modules.contains(typeID) }?.modules ?? []
    }

    /// Buduje mapę kabli i parametrów z modułu źródłowego do docelowego.
    public static func plan(
        from sourceTypeID: Int,
        to targetTypeID: Int,
        connectedInputs: Set<Int>,
        connectedOutputs: Set<Int>
    ) -> ModuleReplacementPlan? {
        guard sourceTypeID != targetTypeID,
              let raw = rawGroups.first(where: {
                  $0.modules.contains(sourceTypeID) && $0.modules.contains(targetTypeID)
              }),
              let sourceDefinition = ModuleDatabase.module(id: sourceTypeID)
        else { return nil }

        var inputGroups = filteredGroups(
            raw.inputGroups,
            sourceTypeID: sourceTypeID,
            targetTypeID: targetTypeID
        )
        var parameterMap: [Int: Int] = [:]
        var inputMap: [Int: Int] = [:]

        for sourceIndex in connectedInputs.sorted() {
            guard let pair = consumePair(
                sourceIndex: sourceIndex,
                sourceTypeID: sourceTypeID,
                targetTypeID: targetTypeID,
                groups: &inputGroups
            ) else { continue }
            inputMap[sourceIndex] = pair.target[1]
            mapRelatedParameter(source: pair.source[2], target: pair.target[2], into: &parameterMap)
            mapRelatedParameter(source: pair.source[3], target: pair.target[3], into: &parameterMap)
        }

        var parameterGroups = filteredGroups(
            raw.parameterGroups,
            sourceTypeID: sourceTypeID,
            targetTypeID: targetTypeID
        )
        parameterGroups += relatedParameterGroups(from: inputGroups, descriptorIndex: 2)
        parameterGroups += relatedParameterGroups(from: inputGroups, descriptorIndex: 3)

        for sourceIndex in sourceDefinition.paramNames.indices where parameterMap[sourceIndex] == nil {
            if let pair = consumePair(
                sourceIndex: sourceIndex,
                sourceTypeID: sourceTypeID,
                targetTypeID: targetTypeID,
                groups: &parameterGroups
            ) {
                parameterMap[sourceIndex] = pair.target[1]
            }
        }

        var outputGroups = filteredGroups(
            raw.outputGroups,
            sourceTypeID: sourceTypeID,
            targetTypeID: targetTypeID
        )
        var outputMap: [Int: Int] = [:]
        for sourceIndex in connectedOutputs.sorted() {
            if let pair = consumePair(
                sourceIndex: sourceIndex,
                sourceTypeID: sourceTypeID,
                targetTypeID: targetTypeID,
                groups: &outputGroups
            ) {
                outputMap[sourceIndex] = pair.target[1]
            }
        }

        return ModuleReplacementPlan(
            sourceTypeID: sourceTypeID,
            targetTypeID: targetTypeID,
            parameterMap: parameterMap,
            inputMap: inputMap,
            outputMap: outputMap
        )
    }

    private static func filteredGroups(
        _ groups: [[[Int]]],
        sourceTypeID: Int,
        targetTypeID: Int
    ) -> [[[Int]]] {
        groups.compactMap { group in
            let filtered = group.filter { descriptor in
                descriptor.first == sourceTypeID || descriptor.first == targetTypeID
            }
            return filtered.isEmpty ? nil : filtered
        }
    }

    private static func consumePair(
        sourceIndex: Int,
        sourceTypeID: Int,
        targetTypeID: Int,
        groups: inout [[[Int]]]
    ) -> (source: [Int], target: [Int])? {
        guard let groupIndex = groups.firstIndex(where: { group in
            group.contains { $0[0] == sourceTypeID && $0[1] == sourceIndex }
        }),
            let sourceDescriptorIndex = groups[groupIndex].firstIndex(where: {
                $0[0] == sourceTypeID && $0[1] == sourceIndex
            }),
            let targetDescriptorIndex = groups[groupIndex].firstIndex(where: { $0[0] == targetTypeID })
        else { return nil }

        let source = groups[groupIndex][sourceDescriptorIndex]
        let target = groups[groupIndex][targetDescriptorIndex]
        for index in [sourceDescriptorIndex, targetDescriptorIndex].sorted(by: >) {
            groups[groupIndex].remove(at: index)
        }
        return (source, target)
    }

    private static func mapRelatedParameter(source: Int, target: Int, into map: inout [Int: Int]) {
        guard source != 255, target != 255 else { return }
        map[source] = target
    }

    /// A socket can carry a knob or two with it - a mixer channel's level and its
    /// on/off switch belong to the channel, not to the cable. Once the cables have
    /// been routed, whatever is left over still has to move: an unpatched channel
    /// keeps its level and its switch across a swap.
    ///
    /// This runs on the groups *after* the cable pass has consumed its entries, so
    /// it only ever offers the knobs of channels that were not matched by a cable.
    /// Load-bearing: without it, swapping a mixer would silently reset the levels of
    /// every channel that happened to be unpatched. Verified against the original
    /// editor on 2026-09-02.
    private static func relatedParameterGroups(
        from inputGroups: [[[Int]]],
        descriptorIndex: Int
    ) -> [[[Int]]] {
        inputGroups.compactMap { group in
            let parameters = group.compactMap { descriptor -> [Int]? in
                guard descriptor.indices.contains(descriptorIndex), descriptor[descriptorIndex] != 255 else {
                    return nil
                }
                return [descriptor[0], descriptor[descriptorIndex]]
            }
            return parameters.isEmpty ? nil : parameters
        }
    }
}
