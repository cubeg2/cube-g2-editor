// ClaviaParameterNamesTests.swift
// Krótkie nazwy parametrów pokazywane w Parameter Pages / Overview.
// Skąd pochodzą i dlaczego moduł 35 jest wyjątkiem → [[Docs/ui/parameter-pages]].

import G2Core
import XCTest

final class ClaviaParameterNamesTests: XCTestCase {
    /// Nazwy z panelu są krótsze niż kodowe nazwy g2ools w `ModuleDatabase`.
    func testShortNamesReplaceTheLongG2oolsOnes() {
        XCTAssertEqual(ClaviaParameterNames.name(moduleTypeID: 7, paramIndex: 0), "Coarse")
        XCTAssertEqual(ClaviaParameterNames.name(moduleTypeID: 7, paramIndex: 3), "Pitch M")
        XCTAssertEqual(ClaviaParameterNames.name(moduleTypeID: 20, paramIndex: 5), "OutType")
        XCTAssertEqual(ModuleDatabase.module(id: 7)?.paramNames[0], "FreqCoarse")
        XCTAssertEqual(ModuleDatabase.module(id: 20)?.paramNames[5], "OutputType")
    }

    /// Driver: `ModuleDef.xml` (i przepisana z niego tabela BVerhue) podaje Embouch
    /// jako parametr 0, ale oryginalny panel Clavii kładzie gałkę `CodeRef 0` pod napisem
    /// „Stiffness". Kanwa rysuje z panelu, więc nazwy też muszą iść za panelem — inaczej
    /// okno parametrów przeczyłoby napisowi na module obok. → [[Docs/ui/parameter-pages]]
    func testDriverKeepsTheOrderFromThePanelInsteadOfTheXml() {
        XCTAssertEqual(ClaviaParameterNames.name(moduleTypeID: 35, paramIndex: 0), "Stiffn")
        XCTAssertEqual(ClaviaParameterNames.name(moduleTypeID: 35, paramIndex: 1), "Embouch")
        XCTAssertEqual(ModuleDatabase.module(id: 35)?.paramNames[0], "Stiffness")
    }

    /// `ModuleDef.xml` pisze w Resonatorze „Course" — to literówka Clavii.
    /// Chodzi o strojenie zgrubne, czyli `Coarse`, parę dla `Fine`.
    func testResonatorSpellsCoarseCorrectly() {
        XCTAssertEqual(ClaviaParameterNames.name(moduleTypeID: 56, paramIndex: 0), "Coarse")
        XCTAssertEqual(ClaviaParameterNames.name(moduleTypeID: 56, paramIndex: 1), "Fine")
    }

    func testUnknownModuleOrIndexFallsBack() {
        XCTAssertNil(ClaviaParameterNames.name(moduleTypeID: 20, paramIndex: 99))
        XCTAssertNil(ClaviaParameterNames.name(moduleTypeID: 9999, paramIndex: 0))
    }
}
