import Foundation
import Sparkle

/// Takes over Sparkle's scheduled update alerts and reports the pending
/// version, so the search panel and menu bar can show it instead.
///
/// For a background app, Sparkle shows a scheduled update alert behind every
/// other window unless the app launched moments ago. Ainto stays running for
/// weeks without a Dock icon, so that alert is effectively never seen.
@MainActor
final class UpdateReminder: NSObject {
    var onChange: ((String?) -> Void)?

    private(set) var pendingVersion: String? {
        didSet { onChange?(pendingVersion) }
    }
}

extension UpdateReminder: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Near launch Sparkle proposes immediate focus, which the user will see,
    /// so only alerts that would land in the background are taken over.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        pendingVersion = update.displayVersionString
    }

    /// Cleared only when the session ends, not when the alert first gets
    /// focus: an alert the user glances at and leaves open can fall behind
    /// other windows again, and Sparkle won't remind about it a second time.
    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}
