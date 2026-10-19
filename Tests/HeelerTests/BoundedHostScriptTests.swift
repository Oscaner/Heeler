import Foundation
import Testing

@testable import Heeler

/// The wrapper every bounded Host script runs in: a remote watchdog that ends
/// the exec's process group and reports its feature's timeout marker. Nothing
/// here runs a shell; the fixture end-to-end tests do that.
@Suite("Bounded host script")
struct BoundedHostScriptTests {
    private static func text(_ script: Data) -> String {
        String(decoding: script, as: UTF8.self)
    }

    /// The Changes wrapper's source text from before Chat shared it, with a
    /// fixed script, bound and marker filled in. Changes keeps sending
    /// exactly these bytes.
    @Test func changesWrapsItsScriptExactlyAsBefore() {
        let wrapped = HeelerSSHTransport.boundedScript(
            Data("printf 'body'\n".utf8), remoteSeconds: 10,
            timeoutMarker: "__HEELER_GIT_TIMEOUT_F00D__")
        let expected = """
            {
            (
                sleep 10 3>&-
                printf '\\n%s\\n' '__HEELER_GIT_TIMEOUT_F00D__' >&3
                kill -KILL 0
            ) </dev/null >/dev/null 3>&2 2>/dev/null &
            __heeler_git_watchdog=$!
            (
            printf 'body'

            ) </dev/null
            __heeler_git_status=$?
            {
                kill -KILL "$__heeler_git_watchdog"
                wait "$__heeler_git_watchdog"
            } >/dev/null 2>&1
            exit "$__heeler_git_status"
            } </dev/null

            """
        #expect(Self.text(wrapped) == expected)
        #expect(wrapped == Data(expected.utf8))
    }

    /// Only the watchdog prints a marker, and it prints the one its caller
    /// passed, so a Changes timeout and a Chat timeout each read as their
    /// own error.
    @Test func eachFeatureNamesItsOwnTimeoutMarker() {
        let script = Data("true\n".utf8)
        let changesMarker = "__HEELER_GIT_TIMEOUT_A__"
        let chatMarker = "__HEELER_OC_TIMEOUT_B__"
        let changes = Self.text(HeelerSSHTransport.boundedScript(
            script, remoteSeconds: 10, timeoutMarker: changesMarker))
        let chat = Self.text(HeelerSSHTransport.boundedScript(
            script, remoteSeconds: 8, timeoutMarker: chatMarker))

        #expect(changes.contains("""
                sleep 10 3>&-
                printf '\\n%s\\n' '\(changesMarker)' >&3

            """))
        #expect(chat.contains("""
                sleep 8 3>&-
                printf '\\n%s\\n' '\(chatMarker)' >&3

            """))
        #expect(changes.ranges(of: changesMarker).count == 1)
        #expect(chat.ranges(of: chatMarker).count == 1)
        #expect(!changes.contains("_OC_TIMEOUT_"))
        #expect(!chat.contains("_GIT_TIMEOUT_"))
    }
}
