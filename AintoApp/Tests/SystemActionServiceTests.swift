import XCTest
#if SWIFT_PACKAGE
@testable import AintoApp
#else
@testable import Ainto
#endif

final class SystemActionServiceTests: XCTestCase {
    func testConfirmationPolicy() {
        XCTAssertFalse(SystemAction.sleep.requiresConfirmation)
        XCTAssertFalse(SystemAction.lockScreen.requiresConfirmation)
        XCTAssertFalse(SystemAction.emptyTrash.requiresConfirmation)
        XCTAssertTrue(SystemAction.logOut.requiresConfirmation)
        XCTAssertTrue(SystemAction.restart.requiresConfirmation)
        XCTAssertTrue(SystemAction.shutDown.requiresConfirmation)
    }
}
