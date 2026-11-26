// DiskBankLibraryTagUpdateTests.swift
// Tag nadany z wtyczki DAW dochodzi do panelu Patches bez ponownego skanu: biblioteka panelu poprawia
// wpis w miejscu (`updateTags`), nie dotykając pliku.

@testable import G2EditorCore
import XCTest

@MainActor
final class DiskBankLibraryTagUpdateTests: XCTestCase {
    func testUpdateTagsChangesTheListInMemoryOnly() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("g2tag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/simplesynth001-20240802.pch2")
        let file = folder.appendingPathComponent("Tagged.pch2")
        try FileManager.default.copyItem(at: fixture, to: file)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "g2tag-\(UUID().uuidString)"))
        defaults.set(folder.path, forKey: "g2_disk_bank_folder")

        let library = DiskBankLibrary(defaults: defaults)
        await library.scan()
        let item = try XCTUnwrap(library.items.first)
        XCTAssertTrue(item.tags.isEmpty)

        let red = FinderTag(name: "Red", color: 6)
        library.updateTags([red], at: item.url)
        XCTAssertEqual(library.items.first?.tags.map(\.color), [6], "the panel's list shows the tag at once")
        XCTAssertTrue(DiskBankLibrary.finderTags(at: item.url).isEmpty, "the file is not written again")

        // Plik spoza listy i te same tagi nic nie zmieniają.
        library.updateTags([], at: folder.appendingPathComponent("Other.pch2"))
        library.updateTags([red], at: item.url)
        XCTAssertEqual(library.items.count, 1)
        XCTAssertEqual(library.items.first?.tags.map(\.color), [6])
    }
}
