import XCTest
#if SWIFT_PACKAGE
@testable import AintoApp
#else
@testable import Ainto
#endif

final class AliasServiceTests: XCTestCase {
    func testNormalizationIsUnicodeCaseInsensitive() {
        XCTAssertEqual(AliasStore.normalize("  Straße  "), AliasStore.normalize("STRASSE"))
    }

    func testNormalizationCanonicalizesEquivalentUnicode() {
        XCTAssertEqual(AliasStore.normalize("café"), AliasStore.normalize("cafe\u{301}"))
    }

    func testValidationRejectsUnicodeEquivalentDuplicates() {
        let aliases = [
            LauncherAlias(alias: "Straße", targetType: .systemAction, targetID: "sleep"),
            LauncherAlias(alias: "STRASSE", targetType: .systemAction, targetID: "restart"),
        ]
        XCTAssertNotNil(AliasStore.validate(aliases))
    }

    func testAppTargetsDistinguishDuplicateBundleIDs() {
        let first = SearchViewModel.appTargetRef(
            bundleID: "com.example.app",
            path: "/Applications/Example.app"
        )
        let second = SearchViewModel.appTargetRef(
            bundleID: "com.example.app",
            path: "/Users/example/Example.app"
        )
        XCTAssertNotEqual(first, second)
    }
}
