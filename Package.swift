// swift-tools-version: 5.9
import Foundation
import PackageDescription

/// Xcode (Explicit Module Build / Clang dependency scanner) ignoruje gołą flagę -I,
/// którą pkgConfig dodaje dla CLibUsb — wymaga -Xcc -I. `swift build` z terminala
/// działa bez tego (starsza ścieżka kompilacji), ale CMD+R w Xcode nie. Potrzebne w
/// każdym targecie zależnym od G2Core (transytywnie od CLibUsb), bo explicit module
/// build liczy to per-target. Ścieżka nieversionowana (/opt/homebrew/include), żeby
/// przetrwać update libusb.
let clibUsbHeaderFix: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I/opt/homebrew/include"])]

/// Flagi kompilacji prywatnego drzewa roboczego. W wersji publicznej lista jest pusta,
/// bo eksport wycina jej zawartość razem ze znacznikami — a wtedy kod, który tych flag
/// wymaga, nie ma prawa się skompilować nawet przez pomyłkę.
/// Paczka dla testerów (`Tools/build_app.sh`, `G2_PUBLIC_BUILD=1`) buduje się jak wersja
/// publiczna — bez prywatnych flag.
let privateSettings: [SwiftSetting] = ProcessInfo.processInfo.environment["G2_PUBLIC_BUILD"] != nil ? [] : [
]

let package = Package(
    name: "G2Editor",
    platforms: [.macOS(.v14)],
    // Biblioteki dostępne dla innych paczek Swift (zależność po ścieżce). Programy
    // (G2EditorApp, USBProbe, PatchCheck, PatchScanner) SwiftPM wystawia sam.
    products: [
        .library(name: "G2Core", targets: ["G2Core"]),
        .library(name: "G2EditorCore", targets: ["G2EditorCore"]),
    ],
    targets: [
        // libusb-1.0 (Homebrew), Faza 2 — USB komunikacja z G2
        .systemLibrary(
            name: "CLibUsb",
            path: "Sources/CLibUsb",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        // Core parsing library
        .target(
            name: "G2Core",
            dependencies: ["CLibUsb", "MutatorCore"],
            path: "Sources/G2Core",
            resources: [
                .copy("Resources/Modules"),
                .copy("Resources/BVerhue-LICENSE.txt"),
                .copy("Resources/InitPatch.pch2"),
            ],
            swiftSettings: clibUsbHeaderFix
        ),
        // Testowalny stan i logika edytora, bez zależności od SwiftUI/AppKit
        .target(
            name: "G2EditorCore",
            dependencies: ["G2Core"],
            path: "Sources/G2EditorCore",
            swiftSettings: clibUsbHeaderFix + privateSettings
        ),
        // SwiftUI macOS app
        .executableTarget(
            name: "G2EditorApp",
            dependencies: ["G2Core", "G2EditorCore"],
            path: "Sources/G2EditorApp",
            resources: [.process("Resources")],
            swiftSettings: clibUsbHeaderFix + privateSettings
        ),
        // Silnik poziomu Rozszerzonego Patch Mutatora — wyłącznie Foundation: zero SwiftUI,
        // zero USB, zero G2 → Docs/mutator/plan-architecture §3
        .target(
            name: "MutatorCore",
            path: "Sources/MutatorCore"
        ),
        // Patch scanner — analiza częstości modułów w kolekcji .pch2/.prf2
        .executableTarget(
            name: "PatchScanner",
            dependencies: ["G2Core"],
            path: "Sources/PatchScanner",
            swiftSettings: clibUsbHeaderFix
        ),
        // Kontrola strukturalna patchy — swift run PatchCheck <katalog>. Tylko raport.
        .executableTarget(
            name: "PatchCheck",
            dependencies: ["G2Core"],
            path: "Sources/PatchCheck",
            swiftSettings: clibUsbHeaderFix
        ),
        // Ręczna diagnostyka USB na żywym sprzęcie (Faza 2) — swift run USBProbe
        .executableTarget(
            name: "USBProbe",
            dependencies: ["G2Core"],
            path: "Sources/USBProbe",
            swiftSettings: clibUsbHeaderFix
        ),
        // Unit tests
        .testTarget(
            name: "G2CoreTests",
            dependencies: ["G2Core", "G2EditorCore"],
            path: "Tests/G2CoreTests",
            exclude: ["Fixtures"],
            swiftSettings: clibUsbHeaderFix
        ),
        // Testy silnika bez G2 — zależność tylko od MutatorCore pilnuje, że silnik jej nie ma
        .testTarget(
            name: "MutatorCoreTests",
            dependencies: ["MutatorCore"],
            path: "Tests/MutatorCoreTests"
        ),
    ]
)
