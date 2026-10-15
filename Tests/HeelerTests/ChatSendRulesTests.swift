import Foundation
import Testing

@testable import Heeler

@Suite("Chat send rules")
struct ChatSendRulesTests {
    private static let skills = [
        AgentSkill(scope: .project, name: "review", description: "Review the diff"),
        AgentSkill(scope: .global, name: "compact", description: "A skill named like the command"),
        AgentSkill(scope: .global, name: "deploy", description: nil),
    ]

    /// How each program invokes a skill: Pi and Oh My Pi skills are
    /// `/skill:name`.
    private static func skillPrefix(_ program: ChatProgram) -> String {
        switch program {
        case .claude: "/"
        case .codex: "$"
        case .pi, .omp: "/skill:"
        }
    }

    private static func rules(
        _ program: ChatProgram, idle: Bool = true, prefix: String? = nil
    ) -> ChatSendRules {
        let skills = Self.skills.map {
            AgentSkill(
                scope: $0.scope, name: $0.name, description: $0.description,
                commandPrefix: prefix ?? skillPrefix(program))
        }
        return ChatSendRules(
            program: program, commands: ChatCommandMenu.commands(skills: skills, agentIsIdle: idle))
    }

    // MARK: Not sent

    @Test(arguments: ChatProgram.allCases, ["!ls", "  !rm -rf build", "!"])
    func aShellEscapeIsNeverSent(program: ChatProgram, draft: String) {
        guard case .unsafeText = Self.rules(program).validate(draft) else {
            Issue.record("\(draft) was not refused for \(program)")
            return
        }
    }

    @Test(arguments: ["exit", "quit", ":q", ":q!", ":wq", ":wq!", "  exit\n", "Quit"])
    func claudeExitWordsAreNeverSent(draft: String) {
        guard case .unsafeText = Self.rules(.claude).validate(draft) else {
            Issue.record("\(draft) was not refused")
            return
        }
    }

    @Test(arguments: ["exit", ":q"])
    func codexTakesExitWordsAsText(draft: String) {
        #expect(Self.rules(.codex).validate(draft) == nil)
    }

    @Test func claudeExitWordsInsideASentenceAreText() {
        #expect(Self.rules(.claude).validate("please exit the loop") == nil)
    }

    @Test(arguments: ["exit", " QUIT \n", "q", "Exit"])
    func ompRefusesBareExitWords(draft: String) {
        guard case .unsafeText = Self.rules(.omp).validate(draft) else {
            Issue.record("\(draft) was not refused")
            return
        }
    }

    @Test(arguments: ["$ ls", "$$ print(1)", "$\tx", "  $ import os\nos.listdir()"])
    func ompRefusesPythonPrefix(draft: String) {
        guard case .unsafeText = Self.rules(.omp).validate(draft) else {
            Issue.record("\(draft) was not refused")
            return
        }
    }

    @Test(arguments: [".", " c ", "C", "-> x", "=> after this", "->"])
    func ompRefusesContinueAndQueueShorthand(draft: String) {
        guard case .unsafeText = Self.rules(.omp).validate(draft) else {
            Issue.record("\(draft) was not refused")
            return
        }
    }

    @Test(arguments: ["quit smoking", "q?", "$HOME is set", "$5 total", "c'est", "..", "a -> b", "exit the loop"])
    func ompTakesLookalikesAsText(draft: String) {
        #expect(Self.rules(.omp).read(draft) == .text)
    }

    @Test func ompRefusesHundredLinePastes() {
        let rules = Self.rules(.omp)
        let lines = { (count: Int) in (1...count).map { "line \($0)" }.joined(separator: "\n") }

        #expect(rules.validate(lines(99)) == nil)
        #expect(rules.validate(lines(99) + "\n\n  \n") == nil)
        guard case .unsafeText = rules.validate(lines(100)) else {
            Issue.record("a 100-line paste was not refused")
            return
        }
        guard case .unsafeText = rules.validate(lines(100).replacingOccurrences(of: "\n", with: "\r\n")) else {
            Issue.record("a 100-line paste with CRLF breaks was not refused")
            return
        }
    }

    @Test(
        arguments: [
            "exit", "q", "$ ls", "$$ print(1)", ".", "c", "-> x", "=> x",
            (1...150).map { "line \($0)" }.joined(separator: "\n"),
        ])
    func piAcceptsWhatOMPRefuses(draft: String) {
        #expect(Self.rules(.pi).validate(draft) == nil)
    }

    @Test(arguments: ["q", "$ ls", ".", "-> x"])
    func claudeAndCodexTakeOMPShorthandsAsText(draft: String) {
        #expect(Self.rules(.claude).validate(draft) == nil)
        #expect(Self.rules(.codex).validate(draft) == nil)
    }

    @Test func claudeExitWordsUnchanged() {
        #expect(
            Self.rules(.claude).validate(":wq")
                == .unsafeText("Sending this would exit Claude Code. Open the terminal to exit."))
        #expect(Self.rules(.claude).validate("q") == nil)
    }

    @Test func controlBytesAreNeverSent() {
        guard case .unsafeText = Self.rules(.claude).validate("a\u{1B}[201~b") else {
            Issue.record("an escape sequence was not refused")
            return
        }
    }

    // MARK: Commands

    @Test func claudeSkillsAreSentAsTyped() {
        let rules = Self.rules(.claude)

        #expect(rules.validate("/review the diff") == nil)
        #expect(rules.outgoingText("/review the diff") == "/review the diff ")
        #expect(rules.outgoingText("  /deploy") == "/deploy ")
    }

    @Test func codexSkillsAreSentWithTheirDollarPrefix() {
        let rules = Self.rules(.codex)

        #expect(rules.outgoingText("/review the diff") == "$review the diff ")
        #expect(rules.outgoingText("/deploy") == "$deploy ")
    }

    @Test(arguments: ChatProgram.allCases)
    func aPickedSkillSendsInTheProgramsOwnForm(program: ChatProgram) {
        let skill = AgentSkill(
            scope: .project, name: "review", description: nil,
            commandPrefix: Self.skillPrefix(program))

        #expect(skill.chatInsertionText == "/review ")
        #expect(
            Self.rules(program).outgoingText(skill.chatInsertionText + "the diff")
                == "\(skill.command) the diff ")
    }

    @Test func compactIsOfferedOnlyWhileIdleAndBeatsASkillOfTheSameName() {
        let idle = Self.rules(.codex)
        let busy = Self.rules(.codex, idle: false)

        #expect(idle.commands.filter { $0.name == "compact" }.map(\.kind) == [.compact])
        #expect(idle.outgoingText("/compact") == "/compact ")
        guard case .commandUnavailable = busy.validate("/compact") else {
            Issue.record("/compact was sent while the Agent worked")
            return
        }
    }

    @Test func ompCompactIsSentWithoutATrailingSpace() {
        let rules = Self.rules(.omp)

        #expect(rules.outgoingText("/compact") == "/compact")
        #expect(rules.outgoingText("  /compact \n") == "/compact")
    }

    @Test func ompCompactWithFocusIsRefused() {
        guard case .commandUnavailable = Self.rules(.omp).validate("/compact keep the API notes") else {
            Issue.record("/compact with a focus was sent to Oh My Pi")
            return
        }
    }

    @Test func piCompactKeepsTrailingSpaceAndArguments() {
        let rules = Self.rules(.pi)

        #expect(rules.outgoingText("/compact") == "/compact ")
        #expect(rules.outgoingText("/compact keep the API notes") == "/compact keep the API notes ")
    }

    @Test(arguments: ["/usr/bin/env python3", "/tmp/a.txt is missing"])
    func aLeadingPathIsText(draft: String) {
        let rules = Self.rules(.claude)

        #expect(rules.read(draft) == .text)
        #expect(rules.outgoingText(draft) == draft + " ")
    }

    @Test(arguments: ["/model", "/", "/ review", "/Review"])
    func aCommandOutsideTheMenuIsNotSent(draft: String) {
        guard case .unknownCommand = Self.rules(.claude).validate(draft) else {
            Issue.record("\(draft) was not refused")
            return
        }
    }

    @Test func aSlashWordMidMessageIsText() {
        let rules = Self.rules(.codex)

        #expect(rules.read("please run /review later") == .text)
        #expect(rules.outgoingText("please run /review later") == "please run /review later ")
    }

    // MARK: Text

    @Test func exactlyOneTrailingSpaceIsSent() {
        let rules = Self.rules(.claude)

        #expect(rules.outgoingText("hello") == "hello ")
        #expect(rules.outgoingText("hello   \n\n") == "hello ")
        #expect(rules.outgoingText("line one\nline two") == "line one\nline two ")
    }

    @Test func invisibleCharactersAreRemoved() {
        let rules = Self.rules(.claude)
        let draft = "a\u{200B}b\u{202E}c\u{FE0F}d\u{E0041}e\u{FEFF}"

        #expect(rules.validate(draft) == nil)
        #expect(rules.outgoingText(draft) == "abcde ")
    }

    @Test(arguments: ChatProgram.allCases, ["@src/main.swift fix it", "$deploy now", "café ☕"])
    func mentionsAndDollarWordsPassThrough(program: ChatProgram, draft: String) {
        let rules = Self.rules(program)

        #expect(rules.validate(draft) == nil)
        #expect(rules.outgoingText(draft) == draft + " ")
    }

    @Test func carriageReturnsBecomeLineFeeds() {
        #expect(Self.rules(.claude).outgoingText("a\r\nb\rc") == "a\nb\nc ")
    }

    // MARK: Menu

    @Test func theMenuOpensOnlyOnALeadingSlashBeforeASpace() {
        let commands = Self.rules(.claude).commands

        #expect(ChatCommandMenu.suggestions(for: "/", in: commands)?.map(\.name) == ["compact", "review", "deploy"])
        #expect(ChatCommandMenu.suggestions(for: "/re", in: commands)?.map(\.name) == ["review"])
        #expect(ChatCommandMenu.suggestions(for: "/review ", in: commands) == nil)
        #expect(ChatCommandMenu.suggestions(for: " /re", in: commands) == nil)
        #expect(ChatCommandMenu.suggestions(for: "/usr/", in: commands) == nil)
        #expect(ChatCommandMenu.suggestions(for: "hello", in: commands) == nil)
    }
}
