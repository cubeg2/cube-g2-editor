// SlotPatchDrag.swift
// A patch dragged from the Patches panel onto one of the slot buttons A–D: it loads into
// that slot, whatever the "Opening a Single Patch" option says (like File ▸ Open To).
// The drag pasteboard carries plain text with a prefix of its own, so the patch canvas
// and the other drop targets leave it alone.

import Foundation

public enum SlotPatchDrag: Equatable, Sendable {
    /// A `.pch2` file from the Disk list.
    case file(URL)
    /// A patch in the G2 banks, by `G2BankEntry.id`.
    case bankEntry(id: String)

    private static let filePrefix = "g2-slot-file:"
    private static let bankPrefix = "g2-slot-bank:"

    public var payload: String {
        switch self {
        case let .file(url): Self.filePrefix + url.path
        case let .bankEntry(id): Self.bankPrefix + id
        }
    }

    public init?(payload: String) {
        if payload.hasPrefix(Self.filePrefix) {
            self = .file(URL(fileURLWithPath: String(payload.dropFirst(Self.filePrefix.count))))
        } else if payload.hasPrefix(Self.bankPrefix) {
            self = .bankEntry(id: String(payload.dropFirst(Self.bankPrefix.count)))
        } else {
            return nil
        }
    }
}
