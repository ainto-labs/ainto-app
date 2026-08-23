import AppKit
import Foundation

extension SearchViewModel {
    func fileSearchCommandResult(score: Int) -> SearchResult {
        SearchResult(
            title: "File Search",
            subtitle: "Search files and folders with Spotlight",
            icon: nil,
            systemIcon: "doc.text.magnifyingglass",
            score: score
        ) { [weak self] in
            self?.goToFileSearch()
        }
    }

    func systemActionResult(_ action: SystemAction, score: Int) -> SearchResult {
        SearchResult(
            title: action.title,
            subtitle: action.requiresConfirmation ? "System Action • Confirmation required" : "System Action",
            icon: nil,
            systemIcon: action.icon,
            score: score
        ) { [weak self] in
            self?.requestSystemAction(action)
        }
    }

    func requestSystemAction(_ action: SystemAction) {
        systemActionError = nil
        pendingSystemAction = action
        if action.requiresConfirmation {
            page = .systemConfirmation
        } else {
            // Keep the panel visible so failures from immediate actions are shown.
            page = .systemConfirmation
            executeSystemAction(action)
        }
    }

    func confirmSystemAction() {
        guard let action = pendingSystemAction else {
            goBack()
            return
        }
        executeSystemAction(action)
    }

    func cancelSystemAction() {
        guard !isExecutingSystemAction else { return }
        pendingSystemAction = nil
        systemActionError = nil
        page = .main
        focusFilterField()
    }

    private func executeSystemAction(_ action: SystemAction) {
        guard !isExecutingSystemAction else { return }
        isExecutingSystemAction = true
        systemActionError = nil
        Task { [weak self] in
            let errorMessage = await Task.detached { () -> String? in
                do {
                    try SystemActionService.execute(action)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            isExecutingSystemAction = false
            if let errorMessage {
                pendingSystemAction = action
                systemActionError = errorMessage
                page = .systemConfirmation
            } else {
                pendingSystemAction = nil
                page = .main
                onSystemActionCompleted?()
            }
        }
    }
}
