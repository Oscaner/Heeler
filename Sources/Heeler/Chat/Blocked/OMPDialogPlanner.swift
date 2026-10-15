import Foundation

/// Oh My Pi's keys for a card action. OMP binds no digits to its panels, so
/// no plan sends one.
struct OMPDialogPlanner {
    let dialog: BlockedDialog

    func plan(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch dialog.kind {
        case .ompApproval:
            try approval(action)
        case .claudeBash, .claudeFileEdit, .claudeFileCreate, .claudeFetch, .claudePlan, .claudeQuestion,
            .claudeQuestionReview, .claudeWorkspaceTrust, .codexExec, .codexPatch, .codexNetwork, .codexQuestion,
            .codexAsyncCollapsed, .codexAsyncQuestion:
            throw .unsupported("Not an Oh My Pi dialog.")
        }
    }

    /// ctrl+q approves; plain Enter does nothing, and ctrl+enter reads as
    /// Enter without kitty keys. Esc denies, and OMP goes on with the turn,
    /// so the Composer keeps its focus. Leaving Blocked confirms either.
    private func approval(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch action {
        case .choose(let ordinal):
            guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
            switch option.role {
            case .approve:
                return DialogActionPlan(steps: [.keys(["ctrl+q"])], confirmation: .fingerprintChangeOrUnblocked)
            case .decline:
                return Self.deny
            default:
                throw .noSuchOption(ordinal)
            }
        case .dismiss:
            return Self.deny
        case .amend, .respond, .approvePlan:
            throw .unsupported("Oh My Pi takes no note with an approval.")
        case .submitSelection, .expandQuestions, .skipQuestion:
            throw .unsupported("The approval has no such action.")
        }
    }

    private static let deny = DialogActionPlan(steps: [.keys(["esc"])], confirmation: .fingerprintChangeOrUnblocked)
}
