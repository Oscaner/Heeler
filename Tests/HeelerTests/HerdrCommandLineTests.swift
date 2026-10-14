import Testing

@testable import Heeler

/// The herdr command lines Heeler shows for the user to run on a Host.
@Suite("herdr command line")
struct HerdrCommandLineTests {
    @Test func theDefaultSessionGetsTheShortForm() {
        #expect(
            HerdrCommandLine.render(session: "", arguments: ["plugin", "enable", "heeler"])
                == "herdr plugin enable heeler")
    }

    /// herdr reads `--session` anywhere before `--`.
    @Test func aNamedSessionIsNamedRightAfterHerdr() {
        #expect(
            HerdrCommandLine.render(session: "work", arguments: ["plugin", "enable", "heeler"])
                == "herdr --session work plugin enable heeler")
    }

    /// The names herdr and the app both accept, from the shared vectors.
    @Test(arguments: NotificationSessionVectorFile.shared.names.filter(\.valid))
    func everyValidSessionNameStaysBare(vector: NotificationSessionVectorFile.Name) {
        #expect(
            HerdrCommandLine.render(session: vector.name, arguments: ["plugin", "enable", "heeler"])
                == "herdr --session \(vector.name) plugin enable heeler")
    }

    /// herdr's own workspace, tab and pane ids.
    @Test func herdrsOwnIDsStayBare() {
        #expect(
            HerdrCommandLine.render(
                session: "work", arguments: ["worktree", "remove", "--workspace", "w1C", "--force"])
                == "herdr --session work worktree remove --workspace w1C --force")
        #expect(
            HerdrCommandLine.render(
                session: "",
                arguments: ["pane", "move", "w1:p1", "--tab", "w1:t2", "--split", "right"])
                == "herdr pane move w1:p1 --tab w1:t2 --split right")
    }

    /// `Host.socketLocation` trims a session name the same way, so a blank one
    /// means the default session here too.
    @Test(arguments: [
        ("   ", "herdr plugin enable heeler"),
        (" \t ", "herdr plugin enable heeler"),
        (" work\t", "herdr --session work plugin enable heeler"),
    ])
    func blankAndPaddedSessionNamesAreTrimmed(session: String, expected: String) {
        #expect(
            HerdrCommandLine.render(session: session, arguments: ["plugin", "enable", "heeler"])
                == expected)
    }

    /// Heeler treats herdr's ids as opaque strings, so it never trusts one to
    /// be shell-safe.
    @Test(arguments: [
        ("w 1", "'w 1'"),
        ("", "''"),
        ("=w1", "'=w1'"),
        ("~w1", "'~w1'"),
        ("$HOME", "'$HOME'"),
        ("w1;w2", "'w1;w2'"),
        ("w*", "'w*'"),
        ("#w1", "'#w1'"),
        ("wé", "'wé'"),
    ])
    func anArgumentOutsideTheShellSafeSetIsSingleQuoted(argument: String, quoted: String) {
        #expect(
            HerdrCommandLine.render(
                session: "", arguments: ["worktree", "remove", "--workspace", argument, "--force"])
                == "herdr worktree remove --workspace \(quoted) --force")
    }

    /// Inside single quotes fish reads `\'` and `\\` as escapes and POSIX
    /// shells read neither, so both characters go outside the quotes, where
    /// sh, bash, zsh and fish all read them the same way. The quote is found
    /// even when a combining mark follows it.
    @Test(arguments: [
        ("it's", #"'it'\''s'"#),
        (#"a\b"#, #"'a'\\'b'"#),
        ("'", #"\'"#),
        (#"a\'b"#, #"'a'\\\''b'"#),
        ("'\u{301}", "\\''\u{301}'"),
    ])
    func quotesAndBackslashesGoOutsideTheQuotes(argument: String, quoted: String) {
        #expect(
            HerdrCommandLine.render(
                session: "", arguments: ["worktree", "remove", "--workspace", argument, "--force"])
                == "herdr worktree remove --workspace \(quoted) --force")
    }

    /// A Host built in code skips the session name rule that decoding and the
    /// Host form apply.
    @Test func anInvalidSessionNameIsQuotedLikeAnyOtherWord() {
        #expect(
            HerdrCommandLine.render(session: "bad name", arguments: ["plugin", "enable", "heeler"])
                == "herdr --session 'bad name' plugin enable heeler")
    }
}
