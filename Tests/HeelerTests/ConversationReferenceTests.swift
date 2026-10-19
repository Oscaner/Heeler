import Testing

@testable import Heeler

@Suite("Conversation reference")
struct ConversationReferenceTests {
    private static let claudeID = "E951205E-24AF-4A5E-BAA7-3CCBEBD2DE2C"
    private static let codexID = "01a10f87-e025-7fb1-8974-8dd09937767a"
    private static let openCodeID = "ses_0a1b2c3d4e5fK2mN8pQ4rT6vX9"

    private static func session(
        source: String, agent: String, kind: AgentSessionRefKind = .id, value: String
    ) -> AgentSessionInfo {
        AgentSessionInfo(agent: agent, kind: kind, source: source, value: value)
    }

    @Test func bindsOfficialPairsWithLowercasedIDs() {
        #expect(
            ConversationReference.resolve(
                Self.session(source: "herdr:claude", agent: "claude", value: Self.claudeID))
                == .bound(
                    ConversationReference(
                        program: .claude, sessionID: "e951205e-24af-4a5e-baa7-3ccbebd2de2c")))
        #expect(
            ConversationReference.resolve(
                Self.session(source: "herdr:codex", agent: "codex", value: Self.codexID))
                == .bound(ConversationReference(program: .codex, sessionID: Self.codexID)))
    }

    @Test func noSessionBeforeHerdrReportsOne() {
        #expect(ConversationReference.resolve(nil) == .noSession)
    }

    @Test(arguments: [
        ("herdr:pi", "omp", AgentSessionRefKind.id),
        ("herdr:claude", "codex", .id),
        ("custom", "claude", .id),
        ("herdr:claude", "claude", .path),
        ("herdr:codex", "codex", AgentSessionRefKind(rawValue: "name")),
    ])
    func otherPairsAndKindsAreUnsupported(source: String, agent: String, kind: AgentSessionRefKind) {
        #expect(
            ConversationReference.resolve(
                Self.session(source: source, agent: agent, kind: kind, value: Self.codexID))
                == .unsupported)
    }

    @Test(arguments: [
        "../x",
        "my-thread-name",
        "01a10f87e0257fb189748dd09937767a",
        "{01a10f87-e025-7fb1-8974-8dd09937767a}",
        "01a10f87-e025-7fb1-8974-8dd09937767a/../../etc",
        "",
    ])
    func valuesThatAreNotUUIDsCannotBeLocated(value: String) {
        #expect(
            ConversationReference.resolve(
                Self.session(source: "herdr:codex", agent: "codex", value: value))
                == .unidentified)
        #expect(
            ConversationReference.resolve(
                Self.session(source: "herdr:claude", agent: "claude", value: value))
                == .unidentified)
    }

    /// No pair is shared, and each one is claimed: a value that is not an id
    /// is the program's own unidentified session, not another program's.
    @Test func everyProgramClaimsItsOwnSessionPair() {
        let pairs = ChatProgram.allCases.map { [$0.sessionNaming.source, $0.sessionNaming.agent] }
        #expect(Set(pairs).count == pairs.count)
        for program in ChatProgram.allCases {
            let naming = program.sessionNaming
            #expect(
                ConversationReference.resolve(
                    Self.session(source: naming.source, agent: naming.agent, value: "not an id"))
                    == .unidentified,
                "\(program)")
        }
    }

    /// Only Pi and Oh My Pi report transcript paths. A path from any other
    /// program, Claude Code and Codex included, is a kind Chat cannot read.
    @Test func transcriptPathsBindOnlyForProgramsThatReportThem() {
        let path = "/home/dev/sessions/s.jsonl"
        let reportingPaths: Set<ChatProgram> = [.pi, .omp]
        for program in ChatProgram.allCases {
            let naming = program.sessionNaming
            let expected: ConversationReference.Resolution =
                reportingPaths.contains(program)
                ? .bound(ConversationReference(program: program, sessionID: path)) : .unsupported
            #expect(
                ConversationReference.resolve(
                    Self.session(source: naming.source, agent: naming.agent, kind: .path, value: path))
                    == expected,
                "\(program)")
        }
    }

    /// OpenCode ids are case-sensitive, so the id herdr reports binds as
    /// it is.
    @Test func openCodeBindsItsSessionIDAndKeepsItsCase() {
        #expect(
            ConversationReference.resolve(
                Self.session(source: "herdr:opencode", agent: "opencode", value: Self.openCodeID))
                == .bound(ConversationReference(program: .opencode, sessionID: Self.openCodeID)))
        #expect(OpenCodeSessionID(Self.openCodeID)?.description == Self.openCodeID)
    }

    @Test(arguments: [
        "ses_ABC", "ses_0a1b2c3d4e5fK2mN8pQ4rT6vX", "SES_0a1b2c3d4e5fK2mN8pQ4rT6vX9", "ses_0a1b2c3d4e5FK2mN8pQ4rT6vX9",
        "ses_0a1b2c3d4e5fK2mN8pQ4rT6vX9\n", "../ses_x",
    ])
    func openCodeRefusesIDsOutsideItsShape(value: String) {
        #expect(OpenCodeSessionID(value) == nil)
        #expect(
            ConversationReference.resolve(Self.session(source: "herdr:opencode", agent: "opencode", value: value))
                == .unidentified)
    }

    /// OpenCode keeps its conversations in a store, not in transcript
    /// files, so a path is a kind Chat cannot read for it.
    @Test func openCodeNeverBindsATranscriptPath() {
        for value in ["/home/dev/sessions/\(Self.openCodeID).jsonl", "/home/dev/.local/share/opencode/opencode.db"] {
            #expect(
                ConversationReference.resolve(
                    Self.session(source: "herdr:opencode", agent: "opencode", kind: .path, value: value))
                    == .unsupported)
        }
    }
}
