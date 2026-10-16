import Foundation

/// One MIDI Control Change assignment from section 0x60.
public struct G2MidiControllerAssignment: Equatable, Sendable {
    public var location: UInt8
    public var moduleID: Int
    public var paramIndex: Int

    public init(location: UInt8, moduleID: Int, paramIndex: Int) {
        self.location = location
        self.moduleID = moduleID
        self.paramIndex = paramIndex
    }
}

/// Controller-number rules used by Clavia's automatic assignment routine.
public enum G2MidiControllers {
    public static let count = 120

    private static let invalid: Set<Int> = [0, 1, 11, 18, 32, 64, 70, 96, 97]
    private static let preassigned: Set<Int> = [7, 17]

    public static func isValid(_ cc: Int) -> Bool {
        (0 ..< count).contains(cc) && !invalid.contains(cc)
    }

    public static func isPreassigned(_ cc: Int) -> Bool {
        preassigned.contains(cc)
    }

    public static func isAutoAssignable(_ cc: Int) -> Bool {
        isValid(cc) && !isPreassigned(cc)
    }
}

public extension G2Patch {
    func midiController(for location: UInt8, moduleID: Int, paramIndex: Int) -> Int? {
        midiControllerAssignments.firstIndex {
            $0?.location == location && $0?.moduleID == moduleID && $0?.paramIndex == paramIndex
        }
    }

    @discardableResult
    mutating func assignMidiController(cc: Int, location: UInt8,
                                       moduleID: Int, paramIndex: Int) -> [Int]
    {
        guard midiControllerAssignments.indices.contains(cc) else { return [] }
        var freed: [Int] = []
        if let previous = midiController(for: location, moduleID: moduleID, paramIndex: paramIndex),
           previous != cc
        {
            midiControllerAssignments[previous] = nil
            freed.append(previous)
        }
        if midiControllerAssignments[cc] != nil { freed.append(cc) }
        midiControllerAssignments[cc] = G2MidiControllerAssignment(
            location: location,
            moduleID: moduleID,
            paramIndex: paramIndex
        )
        return freed
    }

    @discardableResult
    mutating func clearMidiController(cc: Int) -> G2MidiControllerAssignment? {
        guard midiControllerAssignments.indices.contains(cc) else { return nil }
        let previous = midiControllerAssignments[cc]
        midiControllerAssignments[cc] = nil
        return previous
    }
}
