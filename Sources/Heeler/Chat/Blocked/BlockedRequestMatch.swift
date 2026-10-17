import Foundation

/// Finds the transcript's request behind a dialog on screen. The screen
/// decides what a card offers; the request fills in what a narrow or tall
/// dialog cuts short, and gives a Claude card the call whose result
/// confirms an answer. Ties go to the oldest request, since dialogs follow
/// call order.
enum BlockedRequestMatch {
    static func request(for dialog: BlockedDialog, in requests: [ChatPendingRequest]) -> ChatPendingRequest? {
        requests.first { matches($0, dialog) }
    }

    private static func matches(_ request: ChatPendingRequest, _ dialog: BlockedDialog) -> Bool {
        let subject = dialog.subject
        switch dialog.kind {
        case .claudeBash:
            return ["Bash", "PowerShell"].contains(request.toolName) && begins(request.summary, with: subject.command)
        case .claudeFileEdit, .claudeFileCreate:
            return ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(request.toolName)
                && sameFile(request.summary, subject.filePath)
        case .claudeFetch:
            return request.toolName == "WebFetch" && sameURL(request.summary, subject.url)
        case .claudePlan:
            return request.toolName == "ExitPlanMode"
        case .claudeQuestion:
            return request.toolName == "AskUserQuestion" && asks(request, subject.question ?? dialog.title)
        case .claudeQuestionReview:
            return request.toolName == "AskUserQuestion"
        case .codexExec:
            return request.kind == .command && overlaps(request.summary, subject.command)
        case .codexPatch:
            return request.kind == .fileEdit || request.kind == .fileWrite
        case .codexQuestion:
            return request.toolName == "request_user_input" && asks(request, subject.question ?? dialog.title)
        case .codexAsyncCollapsed:
            return request.toolName == "request_user_input_async"
        case .codexAsyncQuestion:
            return request.toolName == "request_user_input_async" && asks(request, dialog.title)
        case .ompApproval:
            // A tool without a `Command:` row matches by its name alone.
            guard request.toolName == subject.toolName else { return false }
            return subject.command == nil || begins(request.summary, with: subject.command)
        case .ompQuestion:
            return request.toolName == "ask" && asks(request, subject.question ?? dialog.title)
        case .ompQuestionReview:
            return request.toolName == "ask"
        case .claudeWorkspaceTrust, .codexNetwork:
            return false
        }
    }

    /// The plan a Claude card shows: the call's Markdown when it agrees
    /// with the plan rows on screen, else those rows. Claude Code 2.1.301
    /// records `input.plan` from the plan file as it stood before a Write
    /// sent in the same message, so the call can hold the previous plan
    /// while the dialog asks about the new one. Rows compare by letters and
    /// digits only, so Markdown, wrapping and bullets don't count; a table
    /// row compares cell by cell, since a wrapped table puts pieces of
    /// several cells on one line, and a list item without its number, since
    /// the terminal renumbers a list.
    static func claudePlanText(call: String?, shownRows: [String]) -> String {
        let shown = shownRows.joined(separator: "\n")
        guard let call, !call.isEmpty else { return shown }
        let recorded = lettersAndDigits(call)
        let disagrees = shownRows.contains { row in
            row.split(whereSeparator: { "│|┃".contains($0) }).contains { cell in
                let text = lettersAndDigits(String(droppingListNumber(String(cell))))
                return text.count >= 8 && !recorded.contains(text)
            }
        }
        return disagrees ? shown : call
    }

    /// `text` without a leading `12.` or `12)`.
    private static func droppingListNumber(_ text: String) -> Substring {
        let trimmed = text.drop(while: \.isWhitespace)
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, let marker = trimmed.dropFirst(digits.count).first, marker == "." || marker == ")" else {
            return trimmed
        }
        return trimmed.dropFirst(digits.count + 1)
    }

    private static func lettersAndDigits(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    /// The screen's text is the request's, or its start where the dialog
    /// was cut off. Wrapping moves spaces, so they do not count.
    private static func begins(_ full: String, with shown: String?) -> Bool {
        let start = DialogRowScanner.comparable(shown ?? "")
        return !start.isEmpty && DialogRowScanner.comparable(full).hasPrefix(start)
    }

    /// The dialog shows the URL Claude Code normalized, which ends a bare
    /// host with `/` (`https://example.com/` for `https://example.com`). A
    /// URL the dialog cut off matches the call it starts, but once the
    /// screen shows where the host ends, the call's host must be the same:
    /// `https://example.com/` never matches `https://example.com.au`.
    private static func sameURL(_ full: String, _ shown: String?) -> Bool {
        let screen = DialogRowScanner.comparable(shown ?? "")
        let call = DialogRowScanner.comparable(full)
        guard !screen.isEmpty else { return false }
        if let screenHost = host(of: screen, complete: true), host(of: call, complete: false) != screenHost {
            return false
        }
        func trimmed(_ url: String) -> String { url.hasSuffix("/") ? String(url.dropLast()) : url }
        return trimmed(call).hasPrefix(trimmed(screen))
    }

    /// The scheme and host of `url`, up to the first `/`, `?` or `#` after
    /// `://`. With `complete`, nil when the text ends before one.
    private static func host(of url: String, complete: Bool) -> Substring? {
        guard let scheme = url.range(of: "://") else { return nil }
        guard let end = url[scheme.upperBound...].firstIndex(where: { "/?#".contains($0) }) else {
            return complete ? nil : url[...]
        }
        return url[..<end]
    }

    /// Codex code mode runs a command inside a script, so either text may
    /// hold the other.
    private static func overlaps(_ full: String, _ shown: String?) -> Bool {
        let screen = DialogRowScanner.comparable(shown ?? "")
        let call = DialogRowScanner.comparable(full)
        return !screen.isEmpty && !call.isEmpty && (call.contains(screen) || screen.contains(call))
    }

    /// Dialogs name a file relative to the project; calls use full paths.
    private static func sameFile(_ path: String, _ shown: String?) -> Bool {
        guard let shown else { return false }
        let name = (shown as NSString).lastPathComponent
        return !name.isEmpty && name == (path as NSString).lastPathComponent
    }

    private static func asks(_ request: ChatPendingRequest, _ question: String) -> Bool {
        let shown = DialogRowScanner.comparable(question)
        guard !shown.isEmpty else { return false }
        let asked = request.questions.map(\.text) + [request.summary]
        return asked.contains { DialogRowScanner.comparable($0) == shown }
    }
}
