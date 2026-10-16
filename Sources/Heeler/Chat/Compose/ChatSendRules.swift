import Foundation

/// One entry of Chat's `/` menu: a skill the Host offers, or the program's
/// `/compact`.
struct ChatCommand: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case compact
        /// A skill, invoked with `prefix`: `/` for Claude Code, `$` for
        /// Codex, whose prompts take skills as `$name`.
        case skill(prefix: String)
    }

    let name: String
    let summary: String?
    let kind: Kind
    /// False when the command needs another state: `/compact` while the
    /// Agent works.
    var isEnabled: Bool

    var id: String { name }
}

/// Chat's `/` menu for every program (ADR 0023): the Host's skills plus
/// `/compact`. Commands that open pickers or end sessions are left out;
/// the terminal still runs them.
enum ChatCommandMenu {
    /// The prefix Pi and Oh My Pi invoke a skill with.
    static let skillCommandPrefix = "/skill:"

    /// Whether Chat offers a skill to a program. Pi and Oh My Pi get only
    /// their `/skill:` skills: a prompt template is a plain `/name`, which
    /// runs the built-in command instead when one shares its name.
    static func offers(_ skill: AgentSkill, for program: ChatProgram) -> Bool {
        switch program {
        case .pi, .omp: skill.commandPrefix == skillCommandPrefix
        case .claude, .codex: true
        }
    }

    static func commands(skills: [AgentSkill], agentIsIdle: Bool, program: ChatProgram) -> [ChatCommand] {
        var commands = [
            ChatCommand(
                name: "compact", summary: "Summarize the conversation to free up context",
                kind: .compact, isEnabled: agentIsIdle)
        ]
        var names: Set<String> = ["compact"]
        // Filtered before the dedupe, so a template listed first cannot
        // hide the skill of the same name.
        for skill in skills where offers(skill, for: program) && names.insert(skill.name).inserted {
            commands.append(
                ChatCommand(
                    name: skill.name, summary: skill.description,
                    kind: .skill(prefix: skill.commandPrefix), isEnabled: true))
        }
        return commands
    }

    /// The entries to suggest for a draft, or nil when the menu stays
    /// closed: it opens only while a leading `/` is followed by a partial
    /// name, before any space. A `/skill:` skill also matches when typed in
    /// that form.
    static func suggestions(for draft: String, in commands: [ChatCommand]) -> [ChatCommand]? {
        guard draft.hasPrefix("/") else { return nil }
        let query = draft.dropFirst()
        guard !query.contains(where: \.isWhitespace), !query.contains("/") else { return nil }
        let needle = query.lowercased()
        return commands.filter { command in
            let typed = skillFormName(needle, of: command) ?? needle
            return typed.isEmpty || command.name.lowercased().hasPrefix(typed)
        }
    }

    /// The command `name` names: its own entry, or a `/skill:` skill typed
    /// with the prefix.
    static func command(named name: String, in commands: [ChatCommand]) -> ChatCommand? {
        commands.first { $0.name == name }
            ?? commands.first { skillFormName(name, of: $0) == $0.name }
    }

    /// `name` without the `skill:` it was typed with, when `command` is a
    /// skill invoked that way.
    private static func skillFormName(_ name: String, of command: ChatCommand) -> String? {
        let typedPrefix = skillCommandPrefix.dropFirst()
        guard command.kind == .skill(prefix: skillCommandPrefix), name.hasPrefix(typedPrefix) else {
            return nil
        }
        return String(name.dropFirst(typedPrefix.count))
    }
}

extension AgentSkill {
    /// A skill as Chat's Composer takes it: `/name` for both programs,
    /// which the send turns into the program's own form when it leads the
    /// message.
    var chatInsertionText: String { "/\(name) " }
}

/// What a Chat draft sends to the Agent's input box (ADR 0023).
///
/// The text arrives as one bracketed paste and Enter, exactly as if typed,
/// so anything the program's input box would treat as more than a message
/// is refused rather than sent: a `!` shell escape, Claude Code's and Oh My
/// Pi's bare exit words, Oh My Pi's other input shorthands, control bytes,
/// and `/` commands the menu does not offer.
struct ChatSendRules: Sendable {
    let program: ChatProgram
    let commands: [ChatCommand]

    /// Claude Code runs `/exit` for these whole inputs.
    private static let claudeExitWords: Set<String> = ["exit", "quit", ":q", ":q!", ":wq", ":wq!"]

    /// Oh My Pi quits for these whole inputs, in any case, before the
    /// conversation's first message; Chat cannot tell whether it has one.
    private static let ompExitWords: Set<String> = ["exit", "quit", "q"]

    /// Oh My Pi offers a paste of this many lines as an attachment menu,
    /// whose Enter picks an entry instead of submitting.
    private static let ompLargePasteLines = 100

    enum Reading: Equatable {
        case text
        case command(ChatCommand, arguments: String)
        case refused(ComposerRefusal)
    }

    func validate(_ draft: String) -> ComposerRefusal? {
        if case .refused(let refusal) = read(draft) { return refusal }
        return nil
    }

    /// The text to send for a draft `validate` accepted: invisible
    /// characters removed, a menu command in the program's own form, and
    /// exactly one trailing space, which keeps a final `/name` or `@path`
    /// from leaving a completion popup open when Enter arrives.
    func outgoingText(_ draft: String) -> String {
        let clean = TerminalTextSafety.normalizingNewlines(Self.removingInvisibles(draft))
        let body: String
        switch read(draft) {
        case .command(let command, _) where program == .omp && command.kind == .compact:
            // Oh My Pi completes `/compact ` to `/compact soft ` rather than
            // running it; without the space, Enter runs it at once.
            return "/compact"
        case .command(let command, let arguments):
            let prefix =
                switch command.kind {
                case .compact: "/"
                case .skill(let prefix): prefix
                }
            body = arguments.isEmpty ? prefix + command.name : "\(prefix)\(command.name) \(arguments)"
        case .text, .refused:
            body = clean
        }
        return Self.trimmingTrailingWhitespace(body) + " "
    }

    func read(_ draft: String) -> Reading {
        let clean = Self.removingInvisibles(draft)
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TerminalTextSafety.containsOnlySafeScalars(clean) else {
            return .refused(.unsafeText("The message contains terminal control characters."))
        }
        if trimmed.hasPrefix("!") {
            return .refused(
                .unsafeText("A message starting with ! runs a shell command. Open the terminal to run one."))
        }
        switch program {
        case .claude:
            if Self.claudeExitWords.contains(trimmed.lowercased()) {
                return .refused(.unsafeText("Sending this would exit Claude Code. Open the terminal to exit."))
            }
        case .omp:
            if let refusal = Self.ompRefusal(clean, trimmed: trimmed) { return .refused(refusal) }
        case .codex, .pi:
            break
        }
        guard trimmed.hasPrefix("/") else { return .text }
        let afterSlash = trimmed.dropFirst()
        let name = String(afterSlash.prefix { !$0.isWhitespace })
        // `/usr/bin/env` is a path in prose, not a command.
        if name.contains("/") { return .text }
        guard let command = ChatCommandMenu.command(named: name, in: commands) else {
            return .refused(.unknownCommand(name))
        }
        guard command.isEnabled else {
            return .refused(.commandAwaitsIdle(name))
        }
        let arguments = afterSlash.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        if program == .omp, command.kind == .compact, !arguments.isEmpty {
            // Oh My Pi's `/compact` offers its modes as completions once a
            // space follows, so a focus would not reach it as typed.
            return .refused(.commandUnavailable("Add compaction focus in the Agent terminal."))
        }
        return .command(command, arguments: arguments)
    }

    /// What Oh My Pi's input box reads as more than a message.
    private static func ompRefusal(_ clean: String, trimmed: String) -> ComposerRefusal? {
        let lowered = trimmed.lowercased()
        if ompExitWords.contains(lowered) {
            return .unsafeText("Sending this would exit Oh My Pi. Open the terminal to exit.")
        }
        if runsPython(trimmed) {
            return .unsafeText("A message starting with $ runs Python in Oh My Pi. Open the terminal to run it.")
        }
        if trimmed == "." || lowered == "c" {
            return .unsafeText("Oh My Pi reads this as Continue. Open the terminal to continue.")
        }
        if trimmed.hasPrefix("->") || trimmed.hasPrefix("=>") {
            return .unsafeText(
                "Oh My Pi queues a message starting with -> or => for later. Open the terminal to queue one.")
        }
        let lines = trimmingTrailingWhitespace(TerminalTextSafety.normalizingNewlines(clean))
            .split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count >= ompLargePasteLines {
            return .unsafeText(
                "Oh My Pi opens a menu for pastes of 100 lines or more. "
                    + "Shorten the message or paste it in the terminal.")
        }
        return nil
    }

    /// Oh My Pi runs `$ code` and `$$ code` as Python, without asking;
    /// `$HOME` and `$5` stay text.
    private static func runsPython(_ trimmed: String) -> Bool {
        guard trimmed.first == "$" else { return false }
        var rest = trimmed.dropFirst()
        if rest.first == "$" { rest = rest.dropFirst() }
        return rest.first?.isWhitespace == true
    }

    /// Removes the characters Claude Code strips before it submits, where
    /// any removal cancels the submit: tag characters, bidirectional
    /// controls, zero-width characters and variation selectors.
    static func removingInvisibles(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !isInvisible($0) })
        return String(scalars)
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xE0000...0xE007F,  // tags
            0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C,  // bidi controls
            0x200B...0x200D, 0x2060, 0xFEFF,  // zero width
            0xFE00...0xFE0F, 0xE0100...0xE01EF:  // variation selectors
            true
        default:
            false
        }
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var text = text
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text
    }
}
