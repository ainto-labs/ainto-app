import XCTest
#if SWIFT_PACKAGE
@testable import AintoApp
#else
@testable import Ainto
#endif

@MainActor
final class LauncherNavigationTests: XCTestCase {
    func testPendingSystemActionDoesNotSurviveHidingThePanel() {
        let viewModel = SearchViewModel()
        viewModel.page = .systemConfirmation
        viewModel.pendingSystemAction = .restart

        viewModel.prepareForPanelHide()

        // Reopening on a stale confirmation would leave Restart one Return away.
        XCTAssertEqual(viewModel.page, .main)
        XCTAssertNil(viewModel.pendingSystemAction)
    }

    func testConfirmationSurvivesWhileTheActionIsExecuting() {
        let viewModel = SearchViewModel()
        viewModel.page = .systemConfirmation
        viewModel.pendingSystemAction = .restart
        viewModel.isExecutingSystemAction = true

        viewModel.prepareForPanelHide()

        XCTAssertEqual(viewModel.page, .systemConfirmation)
        XCTAssertEqual(viewModel.pendingSystemAction, .restart)
    }

    func testUnaffectedPagesAreLeftAlone() {
        let viewModel = SearchViewModel()
        viewModel.page = .clipboard

        viewModel.prepareForPanelHide()

        XCTAssertEqual(viewModel.page, .clipboard)
    }

    func testFileSearchSurvivesHidingThePanel() {
        let viewModel = SearchViewModel()
        viewModel.page = .fileSearch

        viewModel.prepareForPanelHide()

        XCTAssertEqual(viewModel.page, .fileSearch)
    }
}
